import 'package:mongomobile/models/app_settings.dart';
import 'package:mongomobile/services/connection_store.dart';
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

  List<Map<String, dynamic>> _coll(Namespace ns) =>
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
            (f) => matches(doc, f as Map<String, dynamic>))) {
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
  Future<FindResult> find(Namespace ns, FindRequest r,
      {CancelToken? cancel}) async {
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
    return FindResult([for (final d in docs) {...d}],
        byteLength: 100 * docs.length,
        truncated: false,
        elapsed: const Duration(milliseconds: 3));
  }

  @override
  Future<int> estimatedDocumentCount(Namespace ns,
          {Duration? maxTime, CancelToken? cancel}) async =>
      _coll(ns).length;

  @override
  Future<int> countDocuments(Namespace ns, Map<String, dynamic> filter,
      {int skip = 0, int? limit, Duration? maxTime, CancelToken? cancel}) async {
    var n = _coll(ns).where((d) => matches(d, filter)).length - skip;
    if (limit != null && n > limit) n = limit;
    return n < 0 ? 0 : n;
  }

  @override
  Future<Object?> insertOne(Namespace ns, Map<String, dynamic> document) async {
    final doc = {'_id': ObjectId(), ...document};
    _coll(ns).add(doc);
    return doc['_id'];
  }

  @override
  Future<UpdateResult> replaceOne(Namespace ns, Map<String, dynamic> filter,
      Map<String, dynamic> replacement) async {
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
  Future<List<CollectionInfo>> listCollections(String db,
          {CancelToken? cancel}) async =>
      [for (final c in (data[db] ?? {}).keys) CollectionInfo(c)];

  @override
  Future<CollectionStats?> collectionStats(Namespace ns,
          {CancelToken? cancel}) async =>
      CollectionStats(
          count: _coll(ns).length,
          size: _coll(ns).length * 100,
          storageSize: 4096,
          totalIndexSize: 4096,
          indexSizes: const {'_id_': 4096});

  final Map<Namespace, List<Map<String, dynamic>>> indexes = {};

  @override
  Future<List<Map<String, dynamic>>> listIndexes(Namespace ns,
          {CancelToken? cancel}) async =>
      [
        {
          'v': 2,
          'key': {'_id': 1},
          'name': '_id_'
        },
        ...?indexes[ns],
      ];

  @override
  Future<String> createIndex(Namespace ns, Map<String, dynamic> keys,
      [IndexOptions options = const IndexOptions()]) async {
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

  @override
  Future<Map<String, dynamic>> runCommand(
          String db, Map<String, dynamic> command,
          {CancelToken? cancel, Duration? maxTime}) async =>
      {'ok': 1};

  @override
  Future<void> close() async => closed = true;
}

class FakeConnector implements MongoConnector {
  FakeConnector(this.client);
  final FakeMongoClient client;
  String? lastUri;

  @override
  Future<MongoClient> connect(String uri,
      [ConnectOptions options = const ConnectOptions()]) async {
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
