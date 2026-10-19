/// Base class for everything the client throws.
sealed class MongoException implements Exception {
  MongoException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The connection string or an option is invalid.
class MongoConfigError extends MongoException {
  MongoConfigError(super.message);
}

/// The server could not be reached, or the connection broke.
class MongoNetworkError extends MongoException {
  MongoNetworkError(super.message, [this.cause]);
  final Object? cause;
}

/// Looking up `mongodb+srv` records failed.
class MongoDnsError extends MongoException {
  MongoDnsError(super.message);
}

/// No usable server was found in time, or a request took too long locally.
class MongoTimeoutError extends MongoException {
  MongoTimeoutError(super.message);
}

/// The caller cancelled the operation.
class MongoCancelledError extends MongoException {
  MongoCancelledError() : super('The operation was cancelled');
}

/// Authentication was rejected or could not be completed.
class MongoAuthError extends MongoException {
  MongoAuthError(super.message);
}

/// The server answered with `ok: 0`.
class MongoServerError extends MongoException {
  MongoServerError(
    super.message, {
    this.code,
    this.codeName,
    this.labels = const [],
    this.details,
  });

  /// Builds an error from a command reply.
  factory MongoServerError.fromReply(Map<String, dynamic> reply) {
    final code = reply['code'];
    final labels = reply['errorLabels'];
    return MongoServerError(
      (reply['errmsg'] ?? reply[r'$err'] ?? 'Command failed').toString(),
      code: code is int ? code : null,
      codeName: reply['codeName']?.toString(),
      labels: labels is List ? labels.map((e) => '$e').toList() : const [],
      details: reply,
    );
  }

  final int? code;
  final String? codeName;
  final List<String> labels;
  final Map<String, dynamic>? details;

  bool get isMaxTimeExpired => code == 50;

  /// Errors that mean we are talking to a node that is no longer primary.
  bool get isNotPrimary =>
      const {10107, 13435, 13436, 11600, 11602, 189, 91}.contains(code);

  @override
  String toString() {
    if (isMaxTimeExpired) {
      return 'The operation exceeded its time limit (maxTimeMS). '
          'Narrow the query or raise the limit in Settings.';
    }
    final name = codeName != null ? '$codeName: ' : '';
    return '$name$message';
  }
}

/// A write was rejected (for example a duplicate key).
class MongoWriteError extends MongoException {
  MongoWriteError(super.message, {this.code});
  final int? code;

  bool get isDuplicateKey => code == 11000;
}
