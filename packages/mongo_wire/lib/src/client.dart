import 'cancel.dart';

/// A database and collection name.
final class Namespace {
  const Namespace(this.db, this.collection);
  final String db;
  final String collection;

  @override
  bool operator ==(Object other) =>
      other is Namespace && other.db == db && other.collection == collection;

  @override
  int get hashCode => Object.hash(db, collection);

  @override
  String toString() => '$db.$collection';
}

/// Facts about the connected server, for display.
final class ServerInfo {
  const ServerInfo({
    required this.address,
    required this.version,
    required this.kind,
    required this.isWritable,
    required this.maxWireVersion,
    this.setName,
    this.members = const [],
    this.roundTrip,
  });

  final String address;
  final String version;

  /// Standalone, replica set primary, mongos and so on.
  final String kind;
  final bool isWritable;
  final int maxWireVersion;
  final String? setName;
  final List<String> members;
  final Duration? roundTrip;
}

final class DatabaseInfo {
  const DatabaseInfo(this.name, {this.sizeOnDisk, this.empty = false});
  final String name;
  final int? sizeOnDisk;
  final bool empty;
}

final class CollectionInfo {
  const CollectionInfo(
    this.name, {
    this.type = 'collection',
    this.readOnly = false,
    this.options = const {},
  });
  final String name;

  /// `collection`, `view` or `timeseries`.
  final String type;
  final bool readOnly;
  final Map<String, dynamic> options;

  bool get isView => type == 'view';
  bool get isSystem => name.startsWith('system.');
}

final class CollectionStats {
  const CollectionStats({
    required this.count,
    required this.size,
    required this.storageSize,
    required this.totalIndexSize,
    this.indexSizes = const {},
  });

  final int count;

  /// Uncompressed data size in bytes.
  final int size;
  final int storageSize;
  final int totalIndexSize;
  final Map<String, int> indexSizes;

  int get averageDocumentSize => count == 0 ? 0 : size ~/ count;
}

/// Parameters of a find query.
final class FindRequest {
  const FindRequest({
    this.filter = const {},
    this.projection,
    this.sort,
    this.skip = 0,
    required this.limit,
    this.maxTime,
    this.maxBytes = 4 * 1024 * 1024,
    this.hint,
  });

  final Map<String, dynamic> filter;
  final Map<String, dynamic>? projection;
  final Map<String, dynamic>? sort;
  final int skip;

  /// The most documents to return; must be positive.
  final int limit;

  /// Server-side time limit (maxTimeMS).
  final Duration? maxTime;

  /// Soft cap on the reply size. Fetching stops once this many bytes have
  /// arrived; the server's own batch limit of 16 MB still applies to the
  /// first batch.
  final int maxBytes;
  final Object? hint;
}

final class FindResult {
  const FindResult(
    this.documents, {
    required this.byteLength,
    required this.truncated,
    required this.elapsed,
  });

  final List<Map<String, dynamic>> documents;
  final int byteLength;

  /// True when fewer than `limit` documents were returned because
  /// [FindRequest.maxBytes] was reached.
  final bool truncated;
  final Duration elapsed;
}

final class UpdateResult {
  const UpdateResult(this.matched, this.modified);
  final int matched;
  final int modified;
}

/// Index creation options.
final class IndexOptions {
  const IndexOptions({
    this.name,
    this.unique = false,
    this.sparse = false,
    this.hidden = false,
    this.expireAfter,
    this.partialFilterExpression,
  });

  final String? name;
  final bool unique;
  final bool sparse;
  final bool hidden;
  final Duration? expireAfter;
  final Map<String, dynamic>? partialFilterExpression;
}

/// The operations MongoMobile needs from a database connection.
///
/// [WireMongoClient] implements this over the MongoDB wire protocol; other
/// transports (for example an HTTP data API) can implement it too.
abstract interface class MongoClient {
  ServerInfo get server;

  /// Runs any command and returns the reply. Throws on `ok: 0`.
  Future<Map<String, dynamic>> runCommand(
    String db,
    Map<String, dynamic> command, {
    CancelToken? cancel,
    Duration? maxTime,
  });

  Future<List<DatabaseInfo>> listDatabases({CancelToken? cancel});

  Future<List<CollectionInfo>> listCollections(
    String db, {
    CancelToken? cancel,
  });

  /// Count and sizes, or null when the server can't report them (views).
  Future<CollectionStats?> collectionStats(Namespace ns, {CancelToken? cancel});

  Future<FindResult> find(
    Namespace ns,
    FindRequest request, {
    CancelToken? cancel,
  });

  /// Fast count from collection metadata.
  Future<int> estimatedDocumentCount(
    Namespace ns, {
    Duration? maxTime,
    CancelToken? cancel,
  });

  /// Exact count of documents matching [filter].
  Future<int> countDocuments(
    Namespace ns,
    Map<String, dynamic> filter, {
    int skip = 0,
    int? limit,
    Duration? maxTime,
    CancelToken? cancel,
  });

  /// Inserts [document] and returns its `_id`. An ObjectId `_id` is added
  /// when the document has none.
  Future<Object?> insertOne(Namespace ns, Map<String, dynamic> document);

  Future<UpdateResult> replaceOne(
    Namespace ns,
    Map<String, dynamic> filter,
    Map<String, dynamic> replacement,
  );

  /// Returns the number of deleted documents (0 or 1).
  Future<int> deleteOne(Namespace ns, Map<String, dynamic> filter);

  Future<List<Map<String, dynamic>>> listIndexes(
    Namespace ns, {
    CancelToken? cancel,
  });

  /// Creates an index and returns its name.
  Future<String> createIndex(
    Namespace ns,
    Map<String, dynamic> keys, [
    IndexOptions options = const IndexOptions(),
  ]);

  Future<void> dropIndex(Namespace ns, String name);

  /// Drops the collection. Dropping one that doesn't exist is not an error.
  Future<void> dropCollection(Namespace ns);

  /// Streams every matching document in batches, for exports.
  ///
  /// Unlike [find], there is no size cap and no overall time limit, since an
  /// export of a large collection legitimately takes long; [limit] 0 means
  /// no limit. Cancelling [cancel] stops the stream with a
  /// [MongoCancelledError] and closes the server cursor.
  Stream<List<Map<String, dynamic>>> findBatches(
    Namespace ns, {
    Map<String, dynamic> filter = const {},
    Map<String, dynamic>? projection,
    Map<String, dynamic>? sort,
    int limit = 0,
    int batchSize = 1000,
    CancelToken? cancel,
  });

  Future<void> close();
}

/// Settings that are not part of the connection string.
final class ConnectOptions {
  const ConnectOptions({
    this.caCertificatePem,
    this.allowInvalidCertificates = false,
    this.appName = 'MongoMobile',
    this.poolSize = 4,
  });

  /// Extra trusted CA certificates in PEM format.
  final String? caCertificatePem;

  /// Accept any TLS certificate, in addition to the URI's own option.
  final bool allowInvalidCertificates;
  final String appName;
  final int poolSize;
}

/// Opens [MongoClient]s; one implementation per transport.
abstract interface class MongoConnector {
  Future<MongoClient> connect(
    String uri, [
    ConnectOptions options = const ConnectOptions(),
  ]);
}
