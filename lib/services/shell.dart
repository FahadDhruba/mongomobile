import 'dart:convert';

import 'package:mongo_wire/mongo_wire.dart';

/// One piece of shell output.
sealed class ShellOutput {
  const ShellOutput();
}

class ShellText extends ShellOutput {
  const ShellText(this.text, {this.kind = ShellTextKind.result});
  final String text;
  final ShellTextKind kind;
}

enum ShellTextKind { input, result, info, error }

/// A thrown error with a message for the user.
class ShellError implements Exception {
  ShellError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A mongosh-style shell for MongoDB commands. It understands `show`,
/// `use`, `it`, `db.<method>(…)`, `db.<collection>.<method>(…)` with
/// cursor methods such as `.sort()` and `.limit()`, and arguments in
/// shell syntax (`ObjectId('…')`, `ISODate('…')`, unquoted keys). It does
/// not run JavaScript: there are no variables, functions or loops.
class ShellSession {
  ShellSession({
    required this.client,
    required this.db,
    required this.canWrite,
    this.maxTime = const Duration(seconds: 60),
  });

  final MongoClient client;
  String db;

  /// Whether writes are allowed (the app's write mode).
  final bool Function() canWrite;
  final Duration maxTime;

  static const batch = 20;

  /// Fetches the next batch for `it`, when a cursor has more.
  Future<String> Function()? _more;

  static const help = '''
Commands
  show dbs | show collections | show users | show profile
  use <database>
  it                                   more results from the last cursor
  db.getName() · db.stats() · db.version() · db.serverStatus()
  db.getCollectionNames() · db.getCollectionInfos()
  db.runCommand({…}) · db.adminCommand({…})
  db.createCollection('name', {…}) · db.dropDatabase()
  db.currentOp() · db.killOp(opid) · db.getProfilingStatus()
  db.setProfilingLevel(level, slowms)
  db.getSiblingDB('name').<…> · db.getCollection('name').<…>

Collections: db.<name>.<method>(…)
  find(filter, projection) .sort() .limit() .skip() .projection()
     .hint() .collation() .count() .toArray() .explain()
  findOne · countDocuments · estimatedDocumentCount · distinct(field, filter)
  aggregate([…]) · insertOne · insertMany · updateOne · updateMany
  replaceOne · deleteOne · deleteMany · findOneAndUpdate
  findOneAndReplace · findOneAndDelete · createIndex(keys, options)
  getIndexes · dropIndex(name) · drop · renameCollection(name) · stats

Writes need write mode. This shell runs MongoDB commands, not
JavaScript: there are no variables, functions or loops.''';

  /// Runs one statement and returns its output text.
  Future<String> run(String input) async {
    final line = input.trim().replaceFirst(RegExp(r';+\s*$'), '').trim();
    if (line.isEmpty) return '';
    if (line == 'help' || line == 'help()') return help;
    if (line == 'it') {
      final more = _more;
      if (more == null) throw ShellError('There is no cursor to iterate');
      return more();
    }
    final words = line.split(RegExp(r'\s+'));
    if (words.first == 'use') {
      if (words.length != 2) throw ShellError('Usage: use <database>');
      final name = words[1];
      if (RegExp(r'[/\\. "$*<>:|?]').hasMatch(name)) {
        throw ShellError('Invalid database name "$name"');
      }
      db = name;
      return 'switched to db $name';
    }
    if (words.first == 'show') return _show(words.skip(1).join(' '));
    if (words.first == 'exit' || words.first == 'quit') {
      throw ShellError('Close the shell with the back button');
    }
    if (!line.startsWith('db')) {
      throw ShellError(
        'Unknown command. Start with db., show, use or it; type help for '
        'a list. This shell runs MongoDB commands, not JavaScript.',
      );
    }
    return _evaluate(parseChain(line));
  }

  Future<String> _show(String what) async {
    switch (what) {
      case 'dbs' || 'databases':
        final dbs = await client.listDatabases();
        final width = dbs.fold<int>(
          0,
          (w, d) => d.name.length > w ? d.name.length : w,
        );
        return dbs
            .map((d) => '${d.name.padRight(width)}  ${_size(d.sizeOnDisk)}')
            .join('\n');
      case 'collections' || 'tables':
        final colls = await client.listCollections(db);
        return (colls.map((c) => c.name).toList()..sort()).join('\n');
      case 'users':
        return formatShell(await _command(db, {'usersInfo': 1}));
      case 'profile':
        final r = await client.find(
          Namespace(db, 'system.profile'),
          FindRequest(sort: const {'ts': -1}, limit: 5, maxTime: maxTime),
        );
        return r.documents.isEmpty
            ? 'No profiled operations in $db'
            : r.documents.map(formatShell).join('\n');
      default:
        throw ShellError(
          'Use show dbs, show collections, show users or show profile',
        );
    }
  }

  static String _size(int? bytes) {
    if (bytes == null) return '';
    const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(i == 0 ? 0 : 2)} ${units[i]}';
  }

  Future<Map<String, dynamic>> _command(
    String database,
    Map<String, dynamic> cmd,
  ) => client.runCommand(database, cmd, maxTime: maxTime);

  void _needWrites() {
    if (!canWrite()) {
      throw ShellError(
        'Writes are off. Turn on write mode (the Read-only chip) first.',
      );
    }
  }

  Future<String> _evaluate(List<ChainPart> parts) async {
    if (parts.first.name != 'db' || parts.first.args != null) {
      throw ShellError('Statements start with db');
    }
    var database = db;
    String? collection;
    var i = 1;
    while (i < parts.length) {
      final p = parts[i];
      if (collection == null) {
        if (p.args == null) {
          collection = p.name;
          i++;
          continue;
        }
        if (p.name == 'getSiblingDB' || p.name == 'getSisterDB') {
          database = _string(p, 0, 'a database name');
          i++;
          continue;
        }
        if (p.name == 'getCollection') {
          collection = _string(p, 0, 'a collection name');
          i++;
          continue;
        }
        if (i != parts.length - 1) {
          throw ShellError('${p.name}() can\'t be followed by more calls');
        }
        return _dbMethod(database, p);
      }
      if (p.args == null) {
        // db.system.profile: names with dots.
        collection = '$collection.${p.name}';
        i++;
        continue;
      }
      return _collectionMethod(
        Namespace(database, collection),
        p,
        parts.sublist(i + 1),
      );
    }
    if (collection != null) return '$database.$collection';
    return database;
  }

  Future<String> _dbMethod(String database, ChainPart p) async {
    final a = p.args!;
    switch (p.name) {
      case 'getName':
        return database;
      case 'getCollectionNames':
        final colls = await client.listCollections(database);
        return formatShell((colls.map((c) => c.name).toList()..sort()));
      case 'getCollectionInfos':
        final colls = await client.listCollections(database);
        return formatShell([
          for (final c in colls)
            {'name': c.name, 'type': c.type, 'options': c.options},
        ]);
      case 'stats':
        return formatShell(await _command(database, {'dbStats': 1}));
      case 'version':
        return client.server.version;
      case 'serverStatus':
        return formatShell(await _command('admin', {'serverStatus': 1}));
      case 'hello' || 'isMaster':
        return formatShell(await _command('admin', {'hello': 1}));
      case 'runCommand':
        final cmd = _doc(p, 0, 'a command document');
        if (_isWriteCommand(cmd)) _needWrites();
        return formatShell(await _command(database, cmd));
      case 'adminCommand':
        final cmd = _doc(p, 0, 'a command document');
        if (_isWriteCommand(cmd)) _needWrites();
        return formatShell(await _command('admin', cmd));
      case 'createCollection':
        _needWrites();
        await client.createCollection(
          Namespace(database, _string(p, 0, 'a collection name')),
          a.length > 1 ? _doc(p, 1, 'options') : const {},
        );
        return '{ ok: 1 }';
      case 'createView':
        _needWrites();
        await client.createCollection(
          Namespace(database, _string(p, 0, 'a view name')),
          {
            'viewOn': _string(p, 1, 'the source collection'),
            'pipeline': _pipeline(p, 2),
          },
        );
        return '{ ok: 1 }';
      case 'dropDatabase':
        _needWrites();
        await client.dropDatabase(database);
        return "{ ok: 1, dropped: '$database' }";
      case 'currentOp':
        final r = await _command('admin', {
          'aggregate': 1,
          'pipeline': [
            {
              r'$currentOp': {'allUsers': true},
            },
            if (a.isNotEmpty) {r'$match': _doc(p, 0, 'a filter')},
          ],
          'cursor': {'batchSize': 1000},
        });
        return formatShell({
          'inprog': (r['cursor'] as Map?)?['firstBatch'] ?? const [],
        });
      case 'killOp':
        _needWrites();
        if (a.isEmpty) throw ShellError('killOp needs an operation id');
        return formatShell(
          await _command('admin', {'killOp': 1, 'op': a.first}),
        );
      case 'getProfilingStatus':
        return formatShell(await _command(database, {'profile': -1}));
      case 'setProfilingLevel':
        _needWrites();
        return formatShell(
          await _command(database, {
            'profile': _int(p, 0, 'a level (0, 1 or 2)'),
            if (a.length > 1 && a[1] is num) 'slowms': a[1],
            if (a.length > 1 && a[1] is Map)
              ...(a[1] as Map).cast<String, dynamic>(),
          }),
        );
      case 'help':
        return help;
      default:
        throw ShellError(
          'db.${p.name}() is not supported here; db.runCommand({…}) runs any '
          'command',
        );
    }
  }

  static const _writeCommands = {
    'insert',
    'update',
    'delete',
    'findandmodify',
    'create',
    'createindexes',
    'drop',
    'dropdatabase',
    'dropindexes',
    'renamecollection',
    'collmod',
    'createuser',
    'dropuser',
    'updateuser',
    'grantrolestouser',
    'revokerolesfromuser',
    'killop',
    'killcursors',
    'shutdown',
    'compact',
    'profile',
    'setparameter',
    'applyops',
    'clonecollectionascapped',
    'converttocapped',
  };

  bool _isWriteCommand(Map<String, dynamic> cmd) {
    if (cmd.isEmpty) return false;
    final name = cmd.keys.first.toLowerCase();
    if (name == 'profile') return cmd['profile'] != -1;
    if (name == 'aggregate') {
      final pipeline = cmd['pipeline'];
      return pipeline is List &&
          pipeline.any(
            (s) =>
                s is Map &&
                (s.containsKey(r'$out') || s.containsKey(r'$merge')),
          );
    }
    return _writeCommands.contains(name);
  }

  Future<String> _collectionMethod(
    Namespace ns,
    ChainPart p,
    List<ChainPart> rest,
  ) async {
    final a = p.args!;
    void noChain() {
      if (rest.isNotEmpty) {
        throw ShellError(
          '${p.name}() can\'t be followed by .${rest.first.name}()',
        );
      }
    }

    switch (p.name) {
      case 'find':
        return _find(
          ns,
          filter: a.isNotEmpty ? _doc(p, 0, 'a filter') : const {},
          projection: a.length > 1 ? _doc(p, 1, 'a projection') : null,
          modifiers: rest,
        );
      case 'findOne':
        noChain();
        final r = await client.find(
          ns,
          FindRequest(
            filter: a.isNotEmpty ? _doc(p, 0, 'a filter') : const {},
            projection: a.length > 1 ? _doc(p, 1, 'a projection') : null,
            limit: 1,
            maxTime: maxTime,
          ),
        );
        return r.documents.isEmpty ? 'null' : formatShell(r.documents.single);
      case 'countDocuments' || 'count':
        noChain();
        return '${await client.countDocuments(ns, a.isNotEmpty ? _doc(p, 0, 'a filter') : const {}, maxTime: maxTime)}';
      case 'estimatedDocumentCount':
        noChain();
        return '${await client.estimatedDocumentCount(ns, maxTime: maxTime)}';
      case 'distinct':
        noChain();
        final r = await _command(ns.db, {
          'distinct': ns.collection,
          'key': _string(p, 0, 'a field name'),
          if (a.length > 1) 'query': _doc(p, 1, 'a filter'),
        });
        return formatShell(r['values']);
      case 'aggregate':
        final pipeline = _pipeline(p, 0);
        final writes = pipeline.any(
          (s) => s.containsKey(r'$out') || s.containsKey(r'$merge'),
        );
        if (writes) _needWrites();
        for (final m in rest) {
          if (m.name != 'toArray' && m.name != 'pretty') {
            throw ShellError('aggregate() can be followed by .toArray() only');
          }
        }
        final options = a.length > 1
            ? _doc(p, 1, 'options')
            : const <String, dynamic>{};
        return _aggregate(ns, pipeline, options);
      case 'insertOne':
        noChain();
        _needWrites();
        final id = await client.insertOne(ns, _doc(p, 0, 'a document'));
        return formatShell({'acknowledged': true, 'insertedId': id});
      case 'insertMany':
        noChain();
        _needWrites();
        final docs = a.isNotEmpty && a.first is List
            ? (a.first as List).cast<Map<String, dynamic>>()
            : throw ShellError('insertMany needs an array of documents');
        final r = await client.insertMany(ns, docs, ordered: true);
        if (r.errors.isNotEmpty) {
          throw ShellError(
            'Inserted ${r.inserted}; document ${r.errors.first.index + 1}: '
            '${r.errors.first.message}',
          );
        }
        return formatShell({
          'acknowledged': true,
          'insertedIds': {
            for (var i = 0; i < docs.length; i++) '$i': docs[i]['_id'],
          },
        });
      case 'updateOne' || 'updateMany':
        noChain();
        _needWrites();
        final filter = _doc(p, 0, 'a filter');
        if (a.length < 2 || (a[1] is! Map && a[1] is! List)) {
          throw ShellError('${p.name} needs a filter and an update');
        }
        final r = p.name == 'updateOne'
            ? await client.updateOne(ns, filter, a[1]!)
            : await client.updateMany(ns, filter, a[1]!);
        return formatShell({
          'acknowledged': true,
          'matchedCount': r.matched,
          'modifiedCount': r.modified,
        });
      case 'replaceOne':
        noChain();
        _needWrites();
        final r = await client.replaceOne(
          ns,
          _doc(p, 0, 'a filter'),
          _doc(p, 1, 'a replacement document'),
        );
        return formatShell({
          'acknowledged': true,
          'matchedCount': r.matched,
          'modifiedCount': r.modified,
        });
      case 'deleteOne':
        noChain();
        _needWrites();
        final n = await client.deleteOne(ns, _doc(p, 0, 'a filter'));
        return formatShell({'acknowledged': true, 'deletedCount': n});
      case 'deleteMany' || 'remove':
        noChain();
        _needWrites();
        final n = await client.deleteMany(ns, _doc(p, 0, 'a filter'));
        return formatShell({'acknowledged': true, 'deletedCount': n});
      case 'findOneAndUpdate' || 'findOneAndReplace' || 'findOneAndDelete':
        noChain();
        _needWrites();
        final options = (p.name == 'findOneAndDelete'
            ? (a.length > 1 ? _doc(p, 1, 'options') : const {})
            : (a.length > 2 ? _doc(p, 2, 'options') : const {}));
        final r = await _command(ns.db, {
          'findAndModify': ns.collection,
          'query': _doc(p, 0, 'a filter'),
          if (p.name == 'findOneAndDelete') 'remove': true,
          if (p.name != 'findOneAndDelete')
            'update': a.length > 1
                ? a[1]
                : throw ShellError('${p.name} needs an update'),
          if (options['returnDocument'] == 'after' ||
              options['returnNewDocument'] == true)
            'new': true,
          if (options['upsert'] == true) 'upsert': true,
          if (options['sort'] != null) 'sort': options['sort'],
          if (options['projection'] != null) 'fields': options['projection'],
        });
        return formatShell(r['value']);
      case 'createIndex':
        noChain();
        _needWrites();
        final o = a.length > 1
            ? _doc(p, 1, 'options')
            : const <String, dynamic>{};
        final name = await client.createIndex(
          ns,
          _doc(p, 0, 'index keys'),
          IndexOptions(
            name: o['name'] as String?,
            unique: o['unique'] == true,
            sparse: o['sparse'] == true,
            hidden: o['hidden'] == true,
            expireAfter: o['expireAfterSeconds'] is num
                ? Duration(seconds: (o['expireAfterSeconds'] as num).toInt())
                : null,
            partialFilterExpression: (o['partialFilterExpression'] as Map?)
                ?.cast<String, dynamic>(),
            collation: (o['collation'] as Map?)?.cast<String, dynamic>(),
            wildcardProjection: (o['wildcardProjection'] as Map?)
                ?.cast<String, dynamic>(),
          ),
        );
        return "'$name'";
      case 'getIndexes':
        noChain();
        return formatShell(await client.listIndexes(ns));
      case 'dropIndex':
        noChain();
        _needWrites();
        await client.dropIndex(ns, _string(p, 0, 'an index name'));
        return '{ ok: 1 }';
      case 'drop':
        noChain();
        _needWrites();
        await client.dropCollection(ns);
        return 'true';
      case 'renameCollection':
        noChain();
        _needWrites();
        await client.renameCollection(ns, _string(p, 0, 'a new name'));
        return '{ ok: 1 }';
      case 'stats':
        noChain();
        return formatShell(
          await _command(ns.db, {
            'aggregate': ns.collection,
            'pipeline': [
              {
                r'$collStats': {
                  'storageStats': <String, dynamic>{},
                  'count': <String, dynamic>{},
                },
              },
            ],
            'cursor': <String, dynamic>{},
          }).then(
            (r) =>
                ((r['cursor'] as Map?)?['firstBatch'] as List?)?.firstOrNull ??
                r,
          ),
        );
      default:
        throw ShellError(
          '.${p.name}() is not supported here; type help for the list',
        );
    }
  }

  Future<String> _find(
    Namespace ns, {
    required Map<String, dynamic> filter,
    Map<String, dynamic>? projection,
    required List<ChainPart> modifiers,
  }) async {
    Map<String, dynamic>? sort;
    var skip = 0;
    int? limit;
    Object? hint;
    Map<String, dynamic>? collation;
    String? terminal;
    for (final m in modifiers) {
      if (terminal != null) {
        throw ShellError('.$terminal() must come last');
      }
      final args = m.args;
      if (args == null) throw ShellError('Call .${m.name}() with brackets');
      switch (m.name) {
        case 'sort':
          sort = _doc(m, 0, 'a sort document');
        case 'skip':
          skip = _int(m, 0, 'a number');
        case 'limit':
          final n = _int(m, 0, 'a number');
          limit = n == 0 ? null : n.abs();
        case 'projection' || 'project':
          projection = _doc(m, 0, 'a projection');
        case 'hint':
          hint = args.isEmpty
              ? throw ShellError('hint needs an index')
              : args.first;
        case 'collation':
          collation = _doc(m, 0, 'a collation');
        case 'pretty' || 'batchSize' || 'maxTimeMS' || 'noCursorTimeout':
          break;
        case 'count' || 'size' || 'toArray' || 'explain' || 'itcount':
          terminal = m.name;
        default:
          throw ShellError('.${m.name}() is not a cursor method here');
      }
    }
    switch (terminal) {
      case 'count' || 'size' || 'itcount':
        return '${await client.countDocuments(ns, filter, skip: terminal == 'count' ? 0 : skip, limit: terminal == 'count' ? null : limit, hint: hint, collation: collation, maxTime: maxTime)}';
      case 'explain':
        return formatShell(
          await client.explain(ns.db, {
            'find': ns.collection,
            'filter': filter,
            'projection': ?projection,
            'sort': ?sort,
            if (skip > 0) 'skip': skip,
            'limit': ?limit,
            'hint': ?hint,
            'collation': ?collation,
          }, maxTime: maxTime),
        );
    }
    final all = terminal == 'toArray';
    var offset = skip;
    var remaining = limit;
    Future<String> page() async {
      final want = all ? (remaining ?? 1000) : batch;
      final take = remaining == null
          ? want
          : (want < remaining! ? want : remaining!);
      final r = await client.find(
        ns,
        FindRequest(
          filter: filter,
          projection: projection,
          sort: sort,
          skip: offset,
          limit: take + 1,
          hint: hint,
          collation: collation,
          maxTime: maxTime,
          maxBytes: 16 << 20,
        ),
      );
      final docs = r.documents.take(take).toList();
      offset += docs.length;
      if (remaining != null) remaining = remaining! - docs.length;
      final more =
          r.documents.length > take && (remaining == null || remaining! > 0);
      _more = more && !all ? page : null;
      if (all) return formatShell(docs);
      if (docs.isEmpty) return '';
      return [
        ...docs.map(formatShell),
        if (more) 'Type "it" for more',
      ].join('\n');
    }

    return page();
  }

  Future<String> _aggregate(
    Namespace ns,
    List<Map<String, dynamic>> pipeline,
    Map<String, dynamic> options,
  ) async {
    final r = await client.aggregate(
      ns,
      pipeline,
      limit: 10000,
      maxTime: maxTime,
      maxBytes: 16 << 20,
      collation: (options['collation'] as Map?)?.cast<String, dynamic>(),
      hint: options['hint'],
    );
    final docs = r.documents;
    var shown = 0;
    String page() {
      final part = docs.skip(shown).take(batch).toList();
      shown += part.length;
      final more = shown < docs.length;
      _more = more ? () async => page() : null;
      return [
        ...part.map(formatShell),
        if (more) 'Type "it" for more',
        if (!more && r.truncated) '(stopped at the 16 MB result limit)',
      ].join('\n');
    }

    return page();
  }

  Map<String, dynamic> _doc(ChainPart p, int i, String what) {
    final a = p.args!;
    if (i >= a.length || a[i] is! Map) {
      throw ShellError(
        '${p.name}() needs $what${i > 0 ? ' as argument ${i + 1}' : ''}',
      );
    }
    return (a[i] as Map).cast<String, dynamic>();
  }

  List<Map<String, dynamic>> _pipeline(ChainPart p, int i) {
    final a = p.args!;
    if (i >= a.length || a[i] is! List) {
      throw ShellError('${p.name}() needs a pipeline: an array of stages');
    }
    final stages = a[i] as List;
    if (stages.any((s) => s is! Map)) {
      throw ShellError('Each pipeline stage must be a document');
    }
    return stages.cast<Map<String, dynamic>>();
  }

  String _string(ChainPart p, int i, String what) {
    final a = p.args!;
    if (i >= a.length || a[i] is! String) {
      throw ShellError('${p.name}() needs $what');
    }
    return a[i] as String;
  }

  int _int(ChainPart p, int i, String what) {
    final a = p.args!;
    final v = i < a.length ? a[i] : null;
    return switch (v) {
      int() => v,
      double() => v.toInt(),
      BsonLong() => v.value,
      _ => throw ShellError('${p.name}() needs $what'),
    };
  }
}

/// One `.name` or `.name(args)` in a chain like `db.users.find({}).limit(5)`.
class ChainPart {
  const ChainPart(this.name, this.args);
  final String name;

  /// Null when the part is not called.
  final List<Object?>? args;
}

/// Splits `db.coll.find({…}).sort({…})` into its parts, parsing the
/// arguments as shell-syntax Extended JSON.
List<ChainPart> parseChain(String src) {
  final parts = <ChainPart>[];
  var i = 0;
  String? pending;
  void flush() {
    if (pending != null) parts.add(ChainPart(pending!, null));
    pending = null;
  }

  bool identChar(String c) => RegExp(r'[\w$]').hasMatch(c);
  void skipSpace() {
    while (i < src.length && src[i].trim().isEmpty) {
      i++;
    }
  }

  skipSpace();
  final start = i;
  while (i < src.length && identChar(src[i])) {
    i++;
  }
  if (i == start) throw ShellError('Expected db at the start');
  pending = src.substring(start, i);
  while (true) {
    skipSpace();
    if (i >= src.length) break;
    final c = src[i];
    if (c == '.') {
      flush();
      i++;
      skipSpace();
      final s = i;
      while (i < src.length && identChar(src[i])) {
        i++;
      }
      if (i == s) throw ShellError('Expected a name after "." at ${s + 1}');
      pending = src.substring(s, i);
    } else if (c == '[') {
      flush();
      final end = _matching(src, i, '[', ']');
      final inner = src.substring(i + 1, end).trim();
      final name = _parseValue(inner);
      if (name is! String) throw ShellError('Use db["name"] with a string');
      pending = name;
      i = end + 1;
    } else if (c == '(') {
      if (pending == null) throw ShellError('Unexpected "(" at ${i + 1}');
      final end = _matching(src, i, '(', ')');
      parts.add(ChainPart(pending!, _parseArgs(src.substring(i + 1, end))));
      pending = null;
      i = end + 1;
    } else {
      throw ShellError(
        'Unexpected "$c" at ${i + 1}. This shell runs MongoDB commands, not '
        'JavaScript.',
      );
    }
  }
  flush();
  return parts;
}

/// The index of the bracket that closes the one at [open].
int _matching(String s, int open, String o, String c) {
  var depth = 0;
  String? quote;
  for (var i = open; i < s.length; i++) {
    final ch = s[i];
    if (quote != null) {
      if (ch == r'\') {
        i++;
      } else if (ch == quote) {
        quote = null;
      }
      continue;
    }
    if (ch == '"' || ch == "'") {
      quote = ch;
    } else if (ch == '(' || ch == '[' || ch == '{') {
      depth++;
    } else if (ch == ')' || ch == ']' || ch == '}') {
      depth--;
      if (depth == 0) {
        if (ch != c) throw ShellError('Mismatched "$ch" at ${i + 1}');
        return i;
      }
    }
  }
  throw ShellError('Missing "$c"');
}

List<Object?> _parseArgs(String inner) {
  final args = <Object?>[];
  var depth = 0;
  String? quote;
  var start = 0;
  for (var i = 0; i < inner.length; i++) {
    final ch = inner[i];
    if (quote != null) {
      if (ch == r'\') {
        i++;
      } else if (ch == quote) {
        quote = null;
      }
      continue;
    }
    if (ch == '"' || ch == "'") {
      quote = ch;
    } else if ('([{'.contains(ch)) {
      depth++;
    } else if (')]}'.contains(ch)) {
      depth--;
    } else if (ch == ',' && depth == 0) {
      args.add(_parseValue(inner.substring(start, i)));
      start = i + 1;
    }
  }
  final last = inner.substring(start);
  if (last.trim().isNotEmpty || args.isNotEmpty) args.add(_parseValue(last));
  return args;
}

Object? _parseValue(String text) {
  final t = text.trim();
  if (t.isEmpty) throw ShellError('An argument is empty');
  if (t == 'true') return true;
  if (t == 'false') return false;
  try {
    return EJson.parse(t);
  } on EJsonParseException catch (e) {
    throw ShellError('In "$t": ${e.message}');
  }
}

/// mongosh-style output: `{ _id: ObjectId('…'), name: 'Ada' }`, broken
/// over lines when long.
String formatShell(Object? v, [int indent = 0]) {
  final one = _oneLine(v);
  if (one.length + indent <= 72 || (v is! Map && v is! List)) return one;
  final pad = '  ' * (indent ~/ 2 + 1);
  final close = '  ' * (indent ~/ 2);
  if (v is Map) {
    if (v.isEmpty) return '{}';
    final lines = [
      for (final MapEntry(:key, :value) in v.entries)
        '$pad${_key('$key')}: ${formatShell(value, indent + 2)}',
    ];
    return '{\n${lines.join(',\n')}\n$close}';
  }
  final list = v as List;
  if (list.isEmpty) return '[]';
  return '[\n${[for (final e in list) '$pad${formatShell(e, indent + 2)}'].join(',\n')}\n$close]';
}

final _plainKey = RegExp(r'^[A-Za-z_$][\w$]*$');
String _key(String k) =>
    _plainKey.hasMatch(k) ? k : "'${k.replaceAll("'", r"\'")}'";

String _oneLine(Object? v) => switch (v) {
  Map() =>
    v.isEmpty
        ? '{}'
        : '{ ${v.entries.map((e) => '${_key('${e.key}')}: ${_oneLine(e.value)}').join(', ')} }',
  List() => v.isEmpty ? '[]' : '[ ${v.map(_oneLine).join(', ')} ]',
  null => 'null',
  String() =>
    "'${v.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll('\n', r'\n')}'",
  bool() || int() => '$v',
  double() =>
    v.isNaN
        ? 'NaN'
        : v.isInfinite
        ? (v > 0 ? 'Infinity' : '-Infinity')
        : formatDouble(v),
  BsonLong() => "Long('${v.value}')",
  Decimal128() => "Decimal128('$v')",
  ObjectId() => "ObjectId('${v.hex}')",
  DateTime() => "ISODate('${formatIsoDate(v)}')",
  BsonBinary(isUuid: true) => "UUID('${v.uuidString}')",
  BsonBinary() =>
    "Binary.createFromBase64('${base64.encode(v.data)}', ${v.subtype})",
  BsonRegex() => '/${v.pattern}/${v.options}',
  BsonTimestamp() => 'Timestamp({ t: ${v.seconds}, i: ${v.increment} })',
  BsonMinKey() => 'MinKey()',
  BsonMaxKey() => 'MaxKey()',
  _ => EJson.stringify(v, pretty: false),
};
