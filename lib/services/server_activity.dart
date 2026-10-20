import 'package:mongo_wire/mongo_wire.dart';

int _int(Object? v) => switch (v) {
  int() => v,
  BsonLong() => v.value,
  double() => v.toInt(),
  _ => 0,
};

/// One `serverStatus` reading: the counters the activity charts use.
class ServerSample {
  const ServerSample({
    required this.at,
    required this.opcounters,
    required this.connections,
    required this.availableConnections,
    required this.bytesIn,
    required this.bytesOut,
    required this.residentMb,
  });

  factory ServerSample.of(Map<String, dynamic> status, DateTime at) {
    final ops = status['opcounters'] as Map? ?? const {};
    final conn = status['connections'] as Map? ?? const {};
    final net = status['network'] as Map? ?? const {};
    final mem = status['mem'] as Map? ?? const {};
    return ServerSample(
      at: at,
      opcounters: {for (final k in opKinds) k: _int(ops[k])},
      connections: _int(conn['current']),
      availableConnections: _int(conn['available']),
      bytesIn: _int(net['bytesIn']),
      bytesOut: _int(net['bytesOut']),
      residentMb: _int(mem['resident']),
    );
  }

  static const opKinds = [
    'insert',
    'query',
    'update',
    'delete',
    'getmore',
    'command',
  ];

  final DateTime at;
  final Map<String, int> opcounters;
  final int connections;
  final int availableConnections;
  final int bytesIn;
  final int bytesOut;
  final int residentMb;
}

/// Per-second rates between two samples.
class ServerRates {
  const ServerRates({
    required this.at,
    required this.ops,
    required this.bytesIn,
    required this.bytesOut,
  });

  final DateTime at;

  /// Operation kind → operations per second.
  final Map<String, double> ops;
  final double bytesIn;
  final double bytesOut;

  double get totalOps => ops.values.fold(0, (a, b) => a + b);

  /// Rates from [a] to [b], or null when [b] is not later (or the server
  /// restarted and its counters went backwards).
  static ServerRates? between(ServerSample a, ServerSample b) {
    final secs = b.at.difference(a.at).inMilliseconds / 1000;
    if (secs <= 0) return null;
    double rate(int x, int y) => y < x ? 0 : (y - x) / secs;
    return ServerRates(
      at: b.at,
      ops: {
        for (final k in ServerSample.opKinds)
          k: rate(a.opcounters[k] ?? 0, b.opcounters[k] ?? 0),
      },
      bytesIn: rate(a.bytesIn, b.bytesIn),
      bytesOut: rate(a.bytesOut, b.bytesOut),
    );
  }
}

/// One entry from `$currentOp`.
class OperationInfo {
  OperationInfo(this.raw);
  final Map<String, dynamic> raw;

  Object? get opid => raw['opid'];
  String get op => raw['op'] as String? ?? '';
  String get ns => raw['ns'] as String? ?? '';
  String get desc => raw['desc'] as String? ?? '';
  bool get active => raw['active'] == true;
  String? get client => raw['client'] as String? ?? raw['client_s'] as String?;
  String? get appName => raw['appName'] as String?;
  String? get planSummary => raw['planSummary'] as String?;
  bool get waitingForLock => raw['waitingForLock'] == true;

  Duration get running {
    final micros = raw['microsecs_running'];
    if (micros != null) return Duration(microseconds: _int(micros));
    return Duration(seconds: _int(raw['secs_running']));
  }

  String? get user {
    final users = raw['effectiveUsers'] as List?;
    if (users == null || users.isEmpty) return null;
    final u = users.first;
    return u is Map ? '${u['user']}@${u['db']}' : null;
  }

  Map<String, dynamic>? get command =>
      (raw['command'] as Map?)?.cast<String, dynamic>();

  /// Operations the server runs for itself (replication, TTL, monitoring)
  /// rather than for a client.
  bool get isSystem =>
      client == null && !desc.startsWith('conn') && raw['connectionId'] == null;

  /// The `currentOp` command used to watch our own requests also shows up;
  /// it is left out of the list.
  bool get isOwnCurrentOp {
    final pipeline = command?['pipeline'];
    return pipeline is List &&
        pipeline.isNotEmpty &&
        pipeline.first is Map &&
        (pipeline.first as Map).containsKey(r'$currentOp');
  }
}

/// The `$currentOp` aggregation the Operations tab runs.
Map<String, dynamic> currentOpCommand({required bool includeIdle}) => {
  'aggregate': 1,
  'pipeline': [
    {
      r'$currentOp': {
        'allUsers': true,
        'idleConnections': includeIdle,
        'idleSessions': includeIdle,
      },
    },
  ],
  'cursor': {'batchSize': 1000},
};

List<OperationInfo> operationsOf(
  Map<String, dynamic> reply, {
  required bool includeSystem,
}) {
  final batch = ((reply['cursor'] as Map?)?['firstBatch'] as List?) ?? [];
  final ops = [
    for (final o in batch.cast<Map<String, dynamic>>()) OperationInfo(o),
  ].where((o) => !o.isOwnCurrentOp && (includeSystem || !o.isSystem)).toList();
  ops.sort((a, b) => b.running.compareTo(a.running));
  return ops;
}

/// One `system.profile` entry.
class ProfileEntry {
  ProfileEntry(this.raw);
  final Map<String, dynamic> raw;

  DateTime? get ts => raw['ts'] as DateTime?;
  String get op => raw['op'] as String? ?? '';
  String get ns => raw['ns'] as String? ?? '';
  int get millis => _int(raw['millis']);
  String? get planSummary => raw['planSummary'] as String?;
  int? get docsExamined =>
      raw['docsExamined'] == null ? null : _int(raw['docsExamined']);
  int? get keysExamined =>
      raw['keysExamined'] == null ? null : _int(raw['keysExamined']);
  int? get returned => raw['nreturned'] == null ? null : _int(raw['nreturned']);
  Map<String, dynamic>? get command =>
      (raw['command'] as Map?)?.cast<String, dynamic>();

  bool get collectionScan => planSummary?.startsWith('COLLSCAN') ?? false;
}
