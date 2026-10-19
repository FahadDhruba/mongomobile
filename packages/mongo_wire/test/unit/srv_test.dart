import 'package:mongo_wire/mongo_wire.dart';
import 'package:test/test.dart';

class FakeDns implements DnsResolver {
  FakeDns(this.records, [this.texts = const []]);
  final List<SrvRecord> records;
  final List<String> texts;
  String? lastSrvName;

  @override
  Future<List<SrvRecord>> srv(String name) async {
    lastSrvName = name;
    return records;
  }

  @override
  Future<List<String>> txt(String name) async => texts;
}

void main() {
  test('resolves hosts and TXT options', () async {
    final dns = FakeDns(
      [
        const SrvRecord(0, 0, 27017, 'shard-00.ab.mongodb.net.'),
        const SrvRecord(0, 0, 27018, 'shard-01.ab.mongodb.net.'),
      ],
      ['authSource=admin&replicaSet=atlas-xyz-shard-0'],
    );
    final s = await resolveSeedlist('Cluster0.ab.mongodb.net', dns);
    expect(dns.lastSrvName, '_mongodb._tcp.cluster0.ab.mongodb.net');
    expect(s.hosts, [
      const HostAddress('shard-00.ab.mongodb.net'),
      const HostAddress('shard-01.ab.mongodb.net', 27018),
    ]);
    expect(s.options, {
      'authsource': 'admin',
      'replicaset': 'atlas-xyz-shard-0',
    });
  });

  test('TXT records are optional', () async {
    final s = await resolveSeedlist(
      'c.ab.net',
      FakeDns([const SrvRecord(0, 0, 1, 'x.ab.net')]),
    );
    expect(s.options, isEmpty);
  });

  test('rejects targets outside the domain', () async {
    expect(
      resolveSeedlist(
        'c.ab.net',
        FakeDns([const SrvRecord(0, 0, 1, 'evil.com.')]),
      ),
      throwsA(isA<MongoDnsError>()),
    );
  });

  test('rejects disallowed TXT options and missing records', () async {
    expect(
      resolveSeedlist(
        'c.ab.net',
        FakeDns([const SrvRecord(0, 0, 1, 'x.ab.net')], ['tls=false']),
      ),
      throwsA(isA<MongoDnsError>()),
    );
    expect(
      resolveSeedlist('c.ab.net', FakeDns(const [])),
      throwsA(isA<MongoDnsError>()),
    );
  });

  test('the TXT authSource wins over the database in the path', () async {
    // Regression: mongodb+srv://u:p@host/appdb used appdb as authSource
    // instead of Atlas's authSource=admin from the TXT record.
    final dns = FakeDns(
      [const SrvRecord(0, 0, 27017, 'shard-00.ab.mongodb.net.')],
      ['authSource=admin&replicaSet=atlas-1'],
    );
    final cs = ConnectionString.parse(
      'mongodb+srv://u:p@cluster0.ab.mongodb.net/fibrodon?retryWrites=true&w=majority',
    );
    expect(cs.authSource, 'fibrodon');
    final resolved = await resolveConnectionString(cs, dns);
    expect(resolved.authSource, 'admin');
    expect(resolved.database, 'fibrodon');
    expect(resolved.replicaSet, 'atlas-1');
    expect(resolved.tls, isTrue);
    expect(resolved.hosts.single, const HostAddress('shard-00.ab.mongodb.net'));
  });

  test('an explicit authSource in the URI still wins over TXT', () async {
    final dns = FakeDns(
      [const SrvRecord(0, 0, 27017, 'x.ab.net')],
      ['authSource=admin'],
    );
    final resolved = await resolveConnectionString(
      ConnectionString.parse('mongodb+srv://u:p@c.ab.net/app?authSource=app'),
      dns,
    );
    expect(resolved.authSource, 'app');
  });
}
