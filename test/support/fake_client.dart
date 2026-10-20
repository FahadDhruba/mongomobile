import 'package:mongomobile/models/app_settings.dart';
import 'package:mongomobile/services/connection_store.dart';
import 'package:mongomobile/services/query_library.dart';
import 'package:mongomobile/services/settings_store.dart';
import 'package:mongomobile/models/connection_profile.dart';
import 'package:mongo_wire/mongo_wire.dart';

/// An in-memory [MongoClient] for tests. It understands the small subset of
/// query syntax the app itself generates: equality, `$gt`/`$gte`/`$lt`/
/// `$lte` on `_id` or any field, `$and`, single-field sorts, skip and limit.
class FakeMongoClient implements MongoClient {
  FakeMongoClient(this.data);

  /// db → collection → documents.
  final Map<String, Map<String, List<Map<String, dynamic>>>> data;
  final List<FindRequest> finds = [];
  Duration findDelay = Duration.zero;
  bool closed = false;

  @override
  ServerInfo get server => const ServerInfo(
    address: 'localhost:27017',
    version: '7.0.14',
    kind: 'Standalone',
    isWritable: true,
    maxWireVersion: 21,
  );

  /// Reads never create a collection; writes do.
  List<Map<String, dynamic>> _coll(Namespace ns) =>
      data[ns.db]?[ns.collection] ?? <Map<String, dynamic>>[];

  List<Map<String, dynamic>> _writable(Namespace ns) =>
      data.putIfAbsent(ns.db, () => {}).putIfAbsent(ns.collection, () => []);

  static int _cmp(Object? a, Object? b) {
    if (a is num && b is num) return a.compareTo(b);
    if (a is ObjectId && b is ObjectId) return a.compareTo(b);
    if (a is String && b is String) return a.compareTo(b);
    return '$a'.compareTo('$b');
  }

  static bool matches(Map<String, dynamic> doc, Map<String, dynamic> filter) {
    for (final e in filter.entries) {
      if (e.key == r'$and') {
        if (!(e.value as List).every(
          (f) => matches(doc, f as Map<String, dynamic>),
        )) {
          return false;
        }
        continue;
      }
      final v = doc[e.key];
      final cond = e.value;
      if (cond is Map<String, dynamic> &&
          cond.keys.every((k) => k.startsWith(r'$'))) {
        for (final op in cond.entries) {
          final c = _cmp(v, op.value);
          final ok = switch (op.key) {
            r'$gt' => c > 0,
            r'$gte' => c >= 0,
            r'$lt' => c < 0,
            r'$lte' => c <= 0,
            r'$ne' => c != 0,
            _ => throw UnsupportedError(op.key),
          };
          if (!ok) return false;
        }
      } else if (_cmp(v, cond) != 0) {
        return false;
      }
    }
    return true;
  }

  @override
  Future<FindResult> find(
    Namespace ns,
    FindRequest r, {
    CancelToken? cancel,
  }) async {
    finds.add(r);
    if (findDelay > Duration.zero) {
      await Future.any([
        Future<void>.delayed(findDelay),
        if (cancel != null) cancel.whenCancelled,
      ]);
      cancel?.throwIfCancelled();
    }
    var docs = _coll(ns).where((d) => matches(d, r.filter)).toList();
    final sort = r.sort;
    if (sort != null && sort.isNotEmpty) {
      final field = sort.keys.single;
      final dir = (sort.values.single as num).toInt();
      docs.sort((a, b) => dir * _cmp(a[field], b[field]));
    }
    docs = docs.skip(r.skip).take(r.limit).toList();
    return FindResult(
      [
        for (final d in docs) {...d},
      ],
      byteLength: 100 * docs.length,
      truncated: false,
      elapsed: const Duration(milliseconds: 3),
    );
  }

  @override
  Future<int> estimatedDocumentCount(
    Namespace ns, {
    Duration? maxTime,
    CancelToken? cancel,
  }) async => _coll(ns).length;

  @override
  Future<int> countDocuments(
    Namespace ns,
    Map<String, dynamic> filter, {
    int skip = 0,
    int? limit,
    Duration? maxTime,
    Map<String, dynamic>? collation,
    Object? hint,
    CancelToken? cancel,
  }) async {
    var n = _coll(ns).where((d) => matches(d, filter)).length - skip;
    if (limit != null && n > limit) n = limit;
    return n < 0 ? 0 : n;
  }

  @override
  Future<Object?> insertOne(Namespace ns, Map<String, dynamic> document) async {
    final doc = {'_id': ObjectId(), ...document};
    _writable(ns).add(doc);
    return doc['_id'];
  }

  @override
  Future<UpdateResult> replaceOne(
    Namespace ns,
    Map<String, dynamic> filter,
    Map<String, dynamic> replacement,
  ) async {
    final list = _coll(ns);
    final i = list.indexWhere((d) => matches(d, filter));
    if (i < 0) return const UpdateResult(0, 0);
    list[i] = replacement;
    return const UpdateResult(1, 1);
  }

  @override
  Future<int> deleteOne(Namespace ns, Map<String, dynamic> filter) async {
    final list = _coll(ns);
    final i = list.indexWhere((d) => matches(d, filter));
    if (i < 0) return 0;
    list.removeAt(i);
    return 1;
  }

  @override
  Future<List<DatabaseInfo>> listDatabases({CancelToken? cancel}) async => [
    for (final db in data.keys) DatabaseInfo(db, sizeOnDisk: 40960),
  ];

  @override
  Future<List<CollectionInfo>> listCollections(
    String db, {
    CancelToken? cancel,
  }) async => [
    for (final c in (data[db] ?? {}).keys)
      CollectionInfo(
        c,
        type: collectionOptions[Namespace(db, c)]?['viewOn'] != null
            ? 'view'
            : 'collection',
        options: collectionOptions[Namespace(db, c)] ?? const {},
      ),
  ];

  @override
  Future<CollectionStats?> collectionStats(
    Namespace ns, {
    CancelToken? cancel,
  }) async => CollectionStats(
    count: _coll(ns).length,
    size: _coll(ns).length * 100,
    storageSize: 4096,
    totalIndexSize: 4096,
    indexSizes: const {'_id_': 4096},
  );

  final Map<Namespace, List<Map<String, dynamic>>> indexes = {};

  @override
  Future<List<Map<String, dynamic>>> listIndexes(
    Namespace ns, {
    CancelToken? cancel,
  }) async => [
    {
      'v': 2,
      'key': {'_id': 1},
      'name': '_id_',
    },
    ...?indexes[ns],
  ];

  @override
  Future<String> createIndex(
    Namespace ns,
    Map<String, dynamic> keys, [
    IndexOptions options = const IndexOptions(),
  ]) async {
    final name = options.name?.isNotEmpty ?? false
        ? options.name!
        : WireMongoClient.defaultIndexName(keys);
    indexes.putIfAbsent(ns, () => []).add({
      'v': 2,
      'key': keys,
      'name': name,
      if (options.unique) 'unique': true,
    });
    return name;
  }

  @override
  Future<void> dropIndex(Namespace ns, String name) async {
    indexes[ns]?.removeWhere((i) => i['name'] == name);
  }

  final List<List<Map<String, dynamic>>> pipelines = [];
  final List<Map<String, dynamic>> explained = [];
  final List<(String, Map<String, dynamic>)> commands = [];

  /// Runs the few stages the tests need: $match, $sort, $skip, $limit,
  /// $project (inclusion of plain fields) and $count.
  @override
  Future<FindResult> aggregate(
    Namespace ns,
    List<Map<String, dynamic>> pipeline, {
    required int limit,
    Duration? maxTime,
    int maxBytes = 4 * 1024 * 1024,
    Map<String, dynamic>? collation,
    Object? hint,
    CancelToken? cancel,
  }) async {
    pipelines.add(pipeline);
    var docs = [for (final d in _coll(ns)) {...d}];
    for (final stage in pipeline) {
      final op = stage.keys.single;
      final arg = stage[op];
      switch (op) {
        case r'$match':
          docs = docs.where((d) => matches(d, arg as Map<String, dynamic>)).toList();
        case r'$sort':
          final m = arg as Map<String, dynamic>;
          final field = m.keys.single;
          final dir = (m.values.single as num).toInt();
          docs.sort((a, b) => dir * _cmp(a[field], b[field]));
        case r'$skip':
          docs = docs.skip(arg as int).toList();
        case r'$limit':
          docs = docs.take(arg as int).toList();
        case r'$project':
          final keep = (arg as Map<String, dynamic>).keys.toSet()..add('_id');
          docs = [
            for (final d in docs)
              {for (final e in d.entries) if (keep.contains(e.key)) e.key: e.value},
          ];
        case r'$count':
          docs = [
            {arg as String: docs.length},
          ];
        case r'$out' || r'$merge':
          docs = [];
        default:
          throw UnsupportedError('Fake aggregate does not support $op');
      }
    }
    return FindResult(
      docs.take(limit).toList(),
      byteLength: 100 * docs.length,
      truncated: false,
      elapsed: const Duration(milliseconds: 4),
    );
  }

  @override
  Future<Map<String, dynamic>> explain(
    String db,
    Map<String, dynamic> command, {
    String verbosity = 'executionStats',
    Duration? maxTime,
    CancelToken? cancel,
  }) async {
    explained.add(command);
    return {
      'queryPlanner': {
        'namespace': '$db.${command['find'] ?? command['aggregate']}',
        'winningPlan': {
          'stage': 'FETCH',
          'inputStage': {
            'stage': 'IXSCAN',
            'indexName': 'paid_1',
            'keyPattern': {'paid': 1},
          },
        },
        'rejectedPlans': [],
      },
      'executionStats': {
        'nReturned': 20,
        'executionTimeMillis': 3,
        'totalKeysExamined': 20,
        'totalDocsExamined': 20,
        'executionStages': {
          'stage': 'FETCH',
          'nReturned': 20,
          'executionTimeMillisEstimate': 1,
          'docsExamined': 20,
          'inputStage': {
            'stage': 'IXSCAN',
            'nReturned': 20,
            'indexName': 'paid_1',
            'keysExamined': 20,
            'executionTimeMillisEstimate': 0,
          },
        },
      },
      'ok': 1,
    };
  }

  Map<String, dynamic> _applySet(Map<String, dynamic> d, Object update) {
    if (update is Map &&
        update.keys.every((k) => k == r'$set' || k == r'$unset')) {
      final out = {...d};
      (update[r'$set'] as Map? ?? {}).forEach((k, v) => out['$k'] = v);
      (update[r'$unset'] as Map? ?? {}).forEach((k, _) => out.remove('$k'));
      return out;
    }
    throw UnsupportedError('Fake updates only support \$set and \$unset');
  }

  @override
  Future<UpdateResult> updateOne(
    Namespace ns,
    Map<String, dynamic> filter,
    Object update,
  ) async {
    final list = _coll(ns);
    final i = list.indexWhere((d) => matches(d, filter));
    if (i < 0) return const UpdateResult(0, 0);
    list[i] = _applySet(list[i], update);
    return const UpdateResult(1, 1);
  }

  @override
  Future<UpdateResult> updateMany(
    Namespace ns,
    Map<String, dynamic> filter,
    Object update,
  ) async {
    final list = _coll(ns);
    var n = 0;
    for (var i = 0; i < list.length; i++) {
      if (matches(list[i], filter)) {
        list[i] = _applySet(list[i], update);
        n++;
      }
    }
    return UpdateResult(n, n);
  }

  @override
  Future<int> deleteMany(Namespace ns, Map<String, dynamic> filter) async {
    final list = _coll(ns);
    final before = list.length;
    list.removeWhere((d) => matches(d, filter));
    return before - list.length;
  }

  @override
  Future<InsertManyResult> insertMany(
    Namespace ns,
    List<Map<String, dynamic>> documents, {
    bool ordered = false,
  }) async {
    final list = _writable(ns);
    final errors = <WriteErrorInfo>[];
    var n = 0;
    for (var i = 0; i < documents.length; i++) {
      final doc = {'_id': ObjectId(), ...documents[i]};
      if (list.any((d) => _cmp(d['_id'], doc['_id']) == 0)) {
        errors.add(WriteErrorInfo(i, 11000, 'E11000 duplicate key'));
        if (ordered) break;
        continue;
      }
      list.add(doc);
      n++;
    }
    return InsertManyResult(n, errors);
  }

  final Map<Namespace, Map<String, dynamic>> collectionOptions = {};

  @override
  Future<void> createCollection(
    Namespace ns, [
    Map<String, dynamic> options = const {},
  ]) async {
    _writable(ns);
    collectionOptions[ns] = options;
  }

  @override
  Future<void> dropDatabase(String db) async {
    data.remove(db);
  }

  @override
  Future<void> renameCollection(Namespace ns, String newName) async {
    final docs = data[ns.db]?.remove(ns.collection);
    if (docs != null) data[ns.db]![newName] = docs;
  }

  final List<(Namespace, Map<String, dynamic>)> collMods = [];

  @override
  Future<void> modifyCollection(
    Namespace ns,
    Map<String, dynamic> options,
  ) async {
    collMods.add((ns, options));
    collectionOptions[ns] = {...?collectionOptions[ns], ...options};
  }

  @override
  Future<List<Map<String, dynamic>>> indexStats(
    Namespace ns, {
    CancelToken? cancel,
  }) async => [
    {
      'name': '_id_',
      'accesses': {'ops': BsonLong(42), 'since': DateTime.utc(2024)},
    },
  ];

  @override
  Future<void> dropCollection(Namespace ns) async {
    data[ns.db]?.remove(ns.collection);
  }

  @override
  Stream<List<Map<String, dynamic>>> findBatches(
    Namespace ns, {
    Map<String, dynamic> filter = const {},
    Map<String, dynamic>? projection,
    Map<String, dynamic>? sort,
    int limit = 0,
    int batchSize = 1000,
    CancelToken? cancel,
  }) async* {
    final all = (await find(
      ns,
      FindRequest(
        filter: filter,
        sort: sort,
        limit: limit > 0 ? limit : 1 << 30,
      ),
    )).documents;
    for (var i = 0; i < all.length; i += batchSize) {
      cancel?.throwIfCancelled();
      yield all.sublist(
        i,
        i + batchSize > all.length ? all.length : i + batchSize,
      );
    }
  }

  @override
  Future<Map<String, dynamic>> runCommand(
    String db,
    Map<String, dynamic> command, {
    CancelToken? cancel,
    Duration? maxTime,
  }) async => {'ok': 1};

  @override
  Future<void> close() async => closed = true;
}

class FakeConnector implements MongoConnector {
  FakeConnector(this.client);
  final FakeMongoClient client;
  String? lastUri;

  @override
  Future<MongoClient> connect(
    String uri, [
    ConnectOptions options = const ConnectOptions(),
  ]) async {
    lastUri = uri;
    return client;
  }
}

class MemoryConnectionStore implements ConnectionStore {
  List<ConnectionProfile> saved = [];

  @override
  Future<List<ConnectionProfile>> load() async => [...saved];

  @override
  Future<void> save(List<ConnectionProfile> profiles) async =>
      saved = [...profiles];
}

class MemorySettingsStore implements SettingsStore {
  AppSettings saved = const AppSettings();

  @override
  Future<AppSettings> load() async => saved;

  @override
  Future<void> save(AppSettings settings) async => saved = settings;
}

class MemoryQueryLibraryStore implements QueryLibraryStore {
  Map<String, CollectionLibrary> saved = {};

  @override
  Future<Map<String, CollectionLibrary>> load() async => {...saved};

  @override
  Future<void> save(Map<String, CollectionLibrary> all) async =>
      saved = {...all};
}
