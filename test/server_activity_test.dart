import 'package:flutter_test/flutter_test.dart';
import 'package:mongo_wire/mongo_wire.dart';
import 'package:mongomobile/services/server_activity.dart';

void main() {
  test('rates between two serverStatus samples', () {
    final t = DateTime.utc(2026);
    Map<String, dynamic> status(int q, int i, int net) => {
      'opcounters': {'query': BsonLong(q), 'insert': i, 'command': 10},
      'connections': {'current': 5, 'available': 100},
      'network': {'bytesIn': BsonLong(net), 'bytesOut': BsonLong(net * 2)},
      'mem': {'resident': 120},
    };
    final a = ServerSample.of(status(100, 10, 1000), t);
    final b = ServerSample.of(
      status(120, 14, 3000),
      t.add(const Duration(seconds: 2)),
    );
    final r = ServerRates.between(a, b)!;
    expect(r.ops['query'], 10);
    expect(r.ops['insert'], 2);
    expect(r.ops['command'], 0);
    expect(r.totalOps, 12);
    expect(r.bytesIn, 1000);
    expect(r.bytesOut, 2000);
    expect(b.connections, 5);
    expect(b.residentMb, 120);
    // A restart resets counters: no negative rates.
    final c = ServerSample.of(
      status(1, 1, 1),
      t.add(const Duration(seconds: 4)),
    );
    expect(ServerRates.between(b, c)!.totalOps, 0);
    expect(ServerRates.between(b, b), isNull);
  });

  test('operations: sorted, system and own currentOp left out', () {
    final reply = {
      'cursor': {
        'firstBatch': [
          {'opid': 1, 'op': 'query', 'client': '1.2.3.4:5', 'secs_running': 1},
          {
            'opid': 2,
            'op': 'command',
            'client': '1.2.3.4:6',
            'microsecs_running': BsonLong(9000000),
            'effectiveUsers': [
              {'user': 'app', 'db': 'admin'},
            ],
          },
          {'opid': 3, 'op': 'none', 'desc': 'TTLMonitor', 'secs_running': 99},
          {
            'opid': 4,
            'client': 'x',
            'command': {
              'aggregate': 1,
              'pipeline': [
                {r'$currentOp': {}},
              ],
            },
          },
        ],
      },
    };
    final ops = operationsOf(reply, includeSystem: false);
    expect(ops.map((o) => o.opid), [2, 1]);
    expect(ops.first.running, const Duration(seconds: 9));
    expect(ops.first.user, 'app@admin');
    expect(operationsOf(reply, includeSystem: true).map((o) => o.opid), [
      3,
      2,
      1,
    ]);
  });

  test('profile entries', () {
    final e = ProfileEntry({
      'op': 'query',
      'ns': 'shop.orders',
      'millis': 250,
      'planSummary': 'COLLSCAN',
      'docsExamined': 10000,
      'nreturned': 3,
    });
    expect(e.collectionScan, isTrue);
    expect(e.millis, 250);
    expect(e.docsExamined, 10000);
    expect(e.returned, 3);
    expect(e.keysExamined, isNull);
  });

  test('currentOpCommand can ask for the own user only', () {
    Map stage(Map<String, dynamic> c) =>
        ((c['pipeline'] as List).first as Map)[r'$currentOp'] as Map;
    final own = stage(currentOpCommand(includeIdle: false, allUsers: false));
    expect(own['allUsers'], false);
    expect(own['idleConnections'], false);
    expect(stage(currentOpCommand(includeIdle: true))['allUsers'], true);
  });

  test('restriction errors are recognised', () {
    final allUsers = MongoServerError(
      r"Error validating $currentOp value. arg=allUsers isn't allowed in this "
      'atlas tier',
      code: 8000,
    );
    expect(isAllUsersRestricted(allUsers), isTrue);
    expect(isAllUsersRestricted(Exception('socket closed')), isFalse);

    expect(
      isCommandRestricted(MongoServerError('CMD_NOT_ALLOWED: profile')),
      isTrue,
    );
    expect(
      isCommandRestricted(
        Exception('(Unauthorized) not authorized on local to execute command'),
      ),
      isTrue,
    );
    expect(isCommandRestricted(Exception('socket closed')), isFalse);
    expect(
      isAllUsersRestricted(MongoServerError('CMD_NOT_ALLOWED: profile')),
      isFalse,
    );
  });
}
