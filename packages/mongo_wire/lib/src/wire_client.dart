import 'dart:async';
import 'dart:math';

import 'bson/types.dart';
import 'cancel.dart';
import 'client.dart';
import 'errors.dart';
import 'wire/connection.dart';
import 'wire/connection_string.dart';
import 'wire/handshake.dart';
import 'wire/pool.dart';
import 'wire/srv.dart';
import 'wire/topology.dart';

/// Opens [WireMongoClient]s.
class WireConnector implements MongoConnector {
  const WireConnector({this.dns});

  /// Resolver for `mongodb+srv` names. Defaults to DNS-over-HTTPS.
  final DnsResolver? dns;

  @override
  Future<MongoClient> connect(
    String uri, [
    ConnectOptions options = const ConnectOptions(),
  ]) => WireMongoClient.connect(uri, options: options, dns: dns);
}

/// [MongoClient] over the MongoDB wire protocol (OP_MSG), on TCP or TLS.
class WireMongoClient implements MongoClient {
  WireMongoClient._(
    this._cs,
    this._options,
    this._dns,
    this._handshake,
    this._selected,
    this._server,
  );

  /// Connects to the deployment in [uri] and returns once a usable server
  /// has been found and authenticated.
  static Future<WireMongoClient> connect(
    String uri, {
    ConnectOptions options = const ConnectOptions(),
    DnsResolver? dns,
  }) async {
    final cs = ConnectionString.parse(uri);
    final resolver = dns ?? DohResolver();
    // Resolve SRV first: its TXT record can set authSource.
    final resolved = await resolveConnectionString(cs, resolver);
    final ho = HandshakeOptions(
      username: resolved.username,
      password: resolved.password,
      authSource: resolved.authSource,
      authMechanism: resolved.authMechanism,
      appName: resolved.appName ?? options.appName,
    );
    if (cs.authMechanism == 'MONGODB-X509' ||
        cs.authMechanism == 'GSSAPI' ||
        cs.authMechanism == 'MONGODB-AWS' ||
        cs.authMechanism == 'MONGODB-OIDC') {
      throw MongoConfigError(
        'authMechanism=${cs.authMechanism} is not supported yet',
      );
    }
    final selected = await _discover(resolved, options, resolver, ho);
    final server = await _serverInfo(selected);
    return WireMongoClient._(cs, options, resolver, ho, selected, server);
  }

  static Future<SelectedServer> _discover(
    ConnectionString cs,
    ConnectOptions options,
    DnsResolver dns,
    HandshakeOptions ho,
  ) => selectServer(
    cs,
    tlsFor: (resolved) => TlsOptions(
      enabled: resolved.tls,
      allowInvalidCertificates:
          resolved.tlsAllowInvalidCertificates ||
          options.allowInvalidCertificates,
      caCertificatePem: options.caCertificatePem,
    ),
    handshakeOptions: ho,
    dns: dns,
    poolSize: options.poolSize,
  );

  static Future<ServerInfo> _serverInfo(SelectedServer s) async {
    var version = 'unknown';
    try {
      final info = await s.pool.use(
        (c) => c.send('admin', {
          'buildInfo': 1,
        }, timeout: const Duration(seconds: 10)),
      );
      version = '${info.document['version'] ?? 'unknown'}';
    } on MongoServerError {
      // Some hosted services restrict buildInfo; the version is cosmetic.
    }
    final d = s.description;
    return ServerInfo(
      address: d.address.toString(),
      version: version,
      kind: d.kind,
      isWritable: d.isWritablePrimary || d.isMongos,
      maxWireVersion: d.maxWireVersion,
      setName: d.setName,
      members: d.members,
      roundTrip: d.roundTrip,
    );
  }

  final ConnectionString _cs;
  final ConnectOptions _options;
  final DnsResolver _dns;
  final HandshakeOptions _handshake;
  SelectedServer _selected;
  ServerInfo _server;
  Future<void>? _rediscovering;
  bool _closed = false;

  @override
  ServerInfo get server => _server;

  ConnectionPool get _pool => _selected.pool;

  /// Server 4.4+ accepts `comment` on every command we send; it lets a
  /// cancelled operation be found and killed.
  bool get _supportsComment => _server.maxWireVersion >= 9;

  /// How long to wait locally beyond the server's own time limit.
  static const _grace = Duration(seconds: 15);
  static const _defaultSocketTimeout = Duration(seconds: 60);

  Duration _localTimeout(Duration? maxTime) => maxTime != null
      ? maxTime + _grace
      : (_cs.socketTimeout ?? _defaultSocketTimeout);

  static final Random _random = Random();

  String _newTag() =>
      'mongomobile-${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(1 << 30)}';

  /// Runs [action] on a pooled connection with the shared error handling:
  /// reads are retried once on a fresh connection after a network error,
  /// and a lost primary triggers rediscovery.
  Future<T> _withConnection<T>(
    Future<T> Function(WireConnection conn) action, {
    CancelToken? cancel,
    bool retryable = true,
    String? tag,
  }) async {
    if (_closed) throw MongoNetworkError('The connection is closed');
    var attempt = 0;
    while (true) {
      attempt++;
      try {
        return await _pool.use(action, cancel: cancel);
      } on MongoCancelledError {
        if (tag != null) unawaited(_killByComment(tag));
        rethrow;
      } on MongoServerError catch (e) {
        if (!e.isNotPrimary || attempt > 1) rethrow;
        await _rediscover();
        if (!retryable) rethrow;
      } on MongoNetworkError {
        if (cancel?.isCancelled ?? false) throw MongoCancelledError();
        if (!retryable || attempt > 1) rethrow;
        if (_server.setName != null || _cs.isSrv) await _rediscover();
      }
    }
  }

  Future<void> _rediscover() {
    return _rediscovering ??= () async {
      try {
        final next = await _discover(_cs, _options, _dns, _handshake);
        final old = _selected;
        _selected = next;
        _server = await _serverInfo(next);
        old.pool.close();
      } finally {
        _rediscovering = null;
      }
    }();
  }

  /// Best effort: find our operation by its comment and kill it, so a
  /// cancelled query stops using server resources.
  Future<void> _killByComment(String tag) async {
    try {
      await _pool.use((c) async {
        final reply = await c.send('admin', {
          'aggregate': 1,
          'pipeline': [
            {
              r'$currentOp': {'allUsers': false, 'idleConnections': false},
            },
            {
              r'$match': {'command.comment': tag},
            },
            {
              r'$project': {'opid': 1},
            },
          ],
          'cursor': <String, dynamic>{},
        }, timeout: const Duration(seconds: 5));
        final ops = _firstBatch(reply.document);
        for (final op in ops) {
          await c.send('admin', {
            'killOp': 1,
            'op': op['opid'],
          }, timeout: const Duration(seconds: 5));
        }
      });
    } on Object {
      // The operation may have ended already, or the user may lack the
      // privilege; closing the socket was the main part of cancelling.
    }
  }

  Map<String, dynamic> _withCommon(
    Map<String, dynamic> cmd, {
    Duration? maxTime,
    String? tag,
  }) {
    return {
      ...cmd,
      if (maxTime != null) 'maxTimeMS': maxTime.inMilliseconds,
      'comment': ?tag,
    };
  }

  @override
  Future<Map<String, dynamic>> runCommand(
    String db,
    Map<String, dynamic> command, {
    CancelToken? cancel,
    Duration? maxTime,
  }) {
    final tag = cancel != null && _supportsComment ? _newTag() : null;
    return _withConnection(
      (c) async => (await c.send(
        db,
        _withCommon(command, maxTime: maxTime, tag: tag),
        cancel: cancel,
        timeout: _localTimeout(maxTime),
      )).document,
      cancel: cancel,
      retryable: false,
      tag: tag,
    );
  }

  Future<Map<String, dynamic>> _read(
    String db,
    Map<String, dynamic> command, {
    CancelToken? cancel,
    Duration? maxTime,
  }) {
    final tag = cancel != null && _supportsComment ? _newTag() : null;
    return _withConnection(
      (c) async => (await c.send(
        db,
        _withCommon(command, maxTime: maxTime, tag: tag),
        cancel: cancel,
        timeout: _localTimeout(maxTime),
      )).document,
      cancel: cancel,
      tag: tag,
    );
  }

  static List<Map<String, dynamic>> _firstBatch(Map<String, dynamic> reply) {
    final cursor = reply['cursor'] as Map<String, dynamic>?;
    return ((cursor?['firstBatch'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
  }

  static int _cursorId(Map<String, dynamic> reply) {
    final id = (reply['cursor'] as Map<String, dynamic>?)?['id'];
    return switch (id) {
      BsonLong() => id.value,
      int() => id,
      _ => 0,
    };
  }

  static int _toInt(Object? v) => switch (v) {
    int() => v,
    BsonLong() => v.value,
    double() => v.toInt(),
    Decimal128() => v.toDouble().toInt(),
    _ => 0,
  };

  /// Reads every batch of a command cursor.
  Future<List<Map<String, dynamic>>> _readCursor(
    String db,
    String collection,
    Map<String, dynamic> command, {
    CancelToken? cancel,
  }) {
    return _withConnection((c) async {
      final timeout = _localTimeout(null);
      var reply = (await c.send(
        db,
        command,
        cancel: cancel,
        timeout: timeout,
      )).document;
      final out = [..._firstBatch(reply)];
      var id = _cursorId(reply);
      while (id != 0) {
        reply = (await c.send(
          db,
          {'getMore': BsonLong(id), 'collection': collection},
          cancel: cancel,
          timeout: timeout,
        )).document;
        out.addAll(
          ((reply['cursor'] as Map)['nextBatch'] as List)
              .cast<Map<String, dynamic>>(),
        );
        id = _cursorId(reply);
      }
      return out;
    }, cancel: cancel);
  }

  @override
  Future<List<DatabaseInfo>> listDatabases({CancelToken? cancel}) async {
    try {
      final reply = await _read('admin', {
        'listDatabases': 1,
        'nameOnly': false,
      }, cancel: cancel);
      final dbs =
          ((reply['databases'] as List?) ?? const [])
              .cast<Map<String, dynamic>>()
              .map(
                (d) => DatabaseInfo(
                  '${d['name']}',
                  sizeOnDisk: d['sizeOnDisk'] == null
                      ? null
                      : _toInt(d['sizeOnDisk']),
                  empty: d['empty'] == true,
                ),
              )
              .toList()
            ..sort((a, b) => a.name.compareTo(b.name));
      return dbs;
    } on MongoServerError catch (e) {
      // Users without listDatabases can still browse their default database.
      final db = _cs.database;
      if (e.code == 13 && db != null) return [DatabaseInfo(db)];
      rethrow;
    }
  }

  @override
  Future<List<CollectionInfo>> listCollections(
    String db, {
    CancelToken? cancel,
  }) async {
    final docs = await _readCursor(db, r'$cmd.listCollections', {
      'listCollections': 1,
      'cursor': <String, dynamic>{},
      'nameOnly': false,
      'authorizedCollections': true,
    }, cancel: cancel);
    return docs
        .map(
          (d) => CollectionInfo(
            '${d['name']}',
            type: '${d['type'] ?? 'collection'}',
            readOnly: (d['info'] as Map?)?['readOnly'] == true,
            options: (d['options'] as Map<String, dynamic>?) ?? const {},
          ),
        )
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  @override
  Future<CollectionStats?> collectionStats(
    Namespace ns, {
    CancelToken? cancel,
  }) async {
    try {
      final docs = await _readCursor(ns.db, ns.collection, {
        'aggregate': ns.collection,
        'pipeline': [
          {
            r'$collStats': {'storageStats': <String, dynamic>{}},
          },
        ],
        'cursor': <String, dynamic>{},
      }, cancel: cancel);
      if (docs.isEmpty) return null;
      var count = 0, size = 0, storage = 0, indexes = 0;
      final indexSizes = <String, int>{};
      // Sharded collections report one document per shard.
      for (final d in docs) {
        final s = d['storageStats'] as Map<String, dynamic>? ?? const {};
        count += _toInt(s['count']);
        size += _toInt(s['size']);
        storage += _toInt(s['storageSize']);
        indexes += _toInt(s['totalIndexSize']);
        final sizes = s['indexSizes'] as Map<String, dynamic>? ?? const {};
        sizes.forEach(
          (k, v) => indexSizes[k] = (indexSizes[k] ?? 0) + _toInt(v),
        );
      }
      return CollectionStats(
        count: count,
        size: size,
        storageSize: storage,
        totalIndexSize: indexes,
        indexSizes: indexSizes,
      );
    } on MongoServerError {
      return null;
    }
  }

  @override
  Future<FindResult> find(Namespace ns, FindRequest r, {CancelToken? cancel}) {
    if (r.limit <= 0) throw ArgumentError.value(r.limit, 'limit');
    final tag = cancel != null && _supportsComment ? _newTag() : null;
    final timeout = _localTimeout(r.maxTime);
    return _withConnection(
      (c) async {
        final sw = Stopwatch()..start();
        final firstBatch = min(r.limit, 25);
        final cmd = _withCommon(
          {
            'find': ns.collection,
            'filter': r.filter,
            if (r.sort != null && r.sort!.isNotEmpty) 'sort': r.sort,
            if (r.projection != null && r.projection!.isNotEmpty)
              'projection': r.projection,
            if (r.skip > 0) 'skip': r.skip,
            'limit': r.limit,
            'batchSize': firstBatch,
            if (r.hint != null) 'hint': r.hint,
          },
          maxTime: r.maxTime,
          tag: tag,
        );
        var reply = await c.send(ns.db, cmd, cancel: cancel, timeout: timeout);
        final docs = [..._firstBatch(reply.document)];
        var bytes = reply.byteLength;
        var id = _cursorId(reply.document);
        var truncated = false;
        while (id != 0 && docs.length < r.limit) {
          if (bytes >= r.maxBytes) {
            truncated = true;
            break;
          }
          final remaining = r.limit - docs.length;
          final average = docs.isEmpty ? 1024 : max(1, bytes ~/ docs.length);
          final batch = ((r.maxBytes - bytes) ~/ average).clamp(1, remaining);
          // No maxTimeMS here: servers only accept it on getMore for
          // tailable awaitData cursors. The time limit set on find already
          // covers the cursor's later batches.
          reply = await c.send(
            ns.db,
            {
              'getMore': BsonLong(id),
              'collection': ns.collection,
              'batchSize': batch,
            },
            cancel: cancel,
            timeout: timeout,
          );
          final cursor = reply.document['cursor'] as Map<String, dynamic>;
          docs.addAll(
            (cursor['nextBatch'] as List).cast<Map<String, dynamic>>(),
          );
          bytes += reply.byteLength;
          id = _cursorId(reply.document);
        }
        if (id != 0) {
          unawaited(
            c
                .send(ns.db, {
                  'killCursors': ns.collection,
                  'cursors': [BsonLong(id)],
                }, timeout: const Duration(seconds: 5))
                .then((_) {}, onError: (_) {}),
          );
        }
        if (docs.length > r.limit) docs.removeRange(r.limit, docs.length);
        return FindResult(
          docs,
          byteLength: bytes,
          truncated: truncated,
          elapsed: sw.elapsed,
        );
      },
      cancel: cancel,
      tag: tag,
    );
  }

  @override
  Future<int> estimatedDocumentCount(
    Namespace ns, {
    Duration? maxTime,
    CancelToken? cancel,
  }) async {
    final reply = await _read(
      ns.db,
      {'count': ns.collection},
      maxTime: maxTime,
      cancel: cancel,
    );
    return _toInt(reply['n']);
  }

  @override
  Future<int> countDocuments(
    Namespace ns,
    Map<String, dynamic> filter, {
    int skip = 0,
    int? limit,
    Duration? maxTime,
    CancelToken? cancel,
  }) async {
    final reply = await _read(
      ns.db,
      {
        'aggregate': ns.collection,
        'pipeline': [
          {r'$match': filter},
          if (skip > 0) {r'$skip': skip},
          if (limit != null) {r'$limit': limit},
          {
            r'$group': {
              '_id': 1,
              'n': {r'$sum': 1},
            },
          },
        ],
        'cursor': <String, dynamic>{},
      },
      maxTime: maxTime,
      cancel: cancel,
    );
    final batch = _firstBatch(reply);
    return batch.isEmpty ? 0 : _toInt(batch.first['n']);
  }

  static void _checkWrite(Map<String, dynamic> reply) {
    final errors = reply['writeErrors'];
    if (errors is List && errors.isNotEmpty) {
      final e = errors.first as Map<String, dynamic>;
      final code = e['code'] is int ? e['code'] as int : null;
      throw MongoWriteError('${e['errmsg'] ?? 'Write failed'}', code: code);
    }
    final wce = reply['writeConcernError'];
    if (wce is Map) {
      throw MongoWriteError(
        'Write concern error: ${wce['errmsg']}',
        code: wce['code'] is int ? wce['code'] as int : null,
      );
    }
  }

  Future<Map<String, dynamic>> _write(String db, Map<String, dynamic> cmd) {
    return _withConnection((c) async {
      final reply = (await c.send(
        db,
        cmd,
        timeout: _localTimeout(null),
      )).document;
      _checkWrite(reply);
      return reply;
    }, retryable: false);
  }

  @override
  Future<Object?> insertOne(Namespace ns, Map<String, dynamic> document) async {
    final doc = document.containsKey('_id')
        ? document
        : <String, dynamic>{'_id': ObjectId(), ...document};
    await _write(ns.db, {
      'insert': ns.collection,
      'documents': [doc],
    });
    return doc['_id'];
  }

  @override
  Future<UpdateResult> replaceOne(
    Namespace ns,
    Map<String, dynamic> filter,
    Map<String, dynamic> replacement,
  ) async {
    final reply = await _write(ns.db, {
      'update': ns.collection,
      'updates': [
        {'q': filter, 'u': replacement, 'upsert': false, 'multi': false},
      ],
    });
    return UpdateResult(_toInt(reply['n']), _toInt(reply['nModified']));
  }

  @override
  Future<int> deleteOne(Namespace ns, Map<String, dynamic> filter) async {
    final reply = await _write(ns.db, {
      'delete': ns.collection,
      'deletes': [
        {'q': filter, 'limit': 1},
      ],
    });
    return _toInt(reply['n']);
  }

  @override
  Future<List<Map<String, dynamic>>> listIndexes(
    Namespace ns, {
    CancelToken? cancel,
  }) {
    return _readCursor(ns.db, ns.collection, {
      'listIndexes': ns.collection,
      'cursor': <String, dynamic>{},
    }, cancel: cancel);
  }

  /// The default index name drivers generate, e.g. `name_1_age_-1`.
  static String defaultIndexName(Map<String, dynamic> keys) => keys.entries
      .map(
        (e) =>
            '${e.key}_${switch (e.value) {
              double v when v == v.truncateToDouble() => v.toInt(),
              final Object? v => v,
            }}',
      )
      .join('_');

  @override
  Future<String> createIndex(
    Namespace ns,
    Map<String, dynamic> keys, [
    IndexOptions options = const IndexOptions(),
  ]) async {
    if (keys.isEmpty) throw MongoConfigError('An index needs at least one key');
    final name = (options.name?.trim().isNotEmpty ?? false)
        ? options.name!.trim()
        : defaultIndexName(keys);
    await _write(ns.db, {
      'createIndexes': ns.collection,
      'indexes': [
        {
          'key': keys,
          'name': name,
          if (options.unique) 'unique': true,
          if (options.sparse) 'sparse': true,
          if (options.hidden) 'hidden': true,
          if (options.expireAfter != null)
            'expireAfterSeconds': options.expireAfter!.inSeconds,
          if (options.partialFilterExpression != null)
            'partialFilterExpression': options.partialFilterExpression,
        },
      ],
    });
    return name;
  }

  @override
  Future<void> dropIndex(Namespace ns, String name) async {
    await _write(ns.db, {'dropIndexes': ns.collection, 'index': name});
  }

  @override
  Future<void> close() async {
    _closed = true;
    _pool.close();
  }
}
