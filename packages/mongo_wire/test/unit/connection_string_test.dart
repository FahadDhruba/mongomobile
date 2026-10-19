import 'package:mongo_wire/mongo_wire.dart';
import 'package:test/test.dart';

void main() {
  group('ConnectionString', () {
    test('parses a full mongodb:// string', () {
      final cs = ConnectionString.parse(
        'mongodb://us%40r:p%3Ass@h1.example.com:27018,h2,[::1]:27019/app'
        '?replicaSet=rs0&TLS=true&authSource=admin&appName=x',
      );
      expect(cs.isSrv, isFalse);
      expect(cs.username, 'us@r');
      expect(cs.password, 'p:ss');
      expect(cs.hosts, [
        const HostAddress('h1.example.com', 27018),
        const HostAddress('h2'),
        const HostAddress('::1', 27019),
      ]);
      expect(cs.database, 'app');
      expect(cs.replicaSet, 'rs0');
      expect(cs.tls, isTrue);
      expect(cs.authSource, 'admin');
      expect(cs.appName, 'x');
    });

    test('defaults', () {
      final cs = ConnectionString.parse('mongodb://localhost');
      expect(cs.hosts.single, const HostAddress('localhost'));
      expect(cs.tls, isFalse);
      expect(cs.authSource, 'admin');
      expect(cs.readPreference, 'primary');
      expect(ConnectionString.parse('mongodb://h/db').authSource, 'db');
      expect(
        ConnectionString.parse(
          'mongodb://u:p@h/?authMechanism=PLAIN',
        ).authSource,
        r'$external',
      );
    });

    test('mongodb+srv defaults to TLS and needs one host without port', () {
      final cs = ConnectionString.parse('mongodb+srv://u:p@cluster0.ab.net/');
      expect(cs.isSrv, isTrue);
      expect(cs.tls, isTrue);
      expect(
        ConnectionString.parse('mongodb+srv://c.ab.net/?tls=false').tls,
        isFalse,
      );
      expect(
        () => ConnectionString.parse('mongodb+srv://a.b.c:27017'),
        throwsA(isA<MongoConfigError>()),
      );
      expect(
        () => ConnectionString.parse('mongodb+srv://a.b.c,d.e.f'),
        throwsA(isA<MongoConfigError>()),
      );
    });

    test('merges SRV results under URI options', () {
      final cs = ConnectionString.parse('mongodb+srv://c.ab.net/?authSource=x');
      final merged = cs.withSeedlist(
        [const HostAddress('s1.ab.net')],
        {'authSource': 'admin', 'replicaSet': 'atlas-1'},
      );
      expect(merged.authSource, 'x');
      expect(merged.replicaSet, 'atlas-1');
      expect(merged.tls, isTrue);
      expect(merged.isSrv, isFalse);
    });

    test('rejects bad input with readable errors', () {
      for (final bad in [
        'http://x',
        'mongodb://',
        'mongodb://h:0',
        'mongodb://h:99999',
        'mongodb://h/?tls=yes',
        'mongodb://a,b/?directConnection=true',
        'mongodb://h/?novalue',
        'mongodb://h/bad.name',
      ]) {
        expect(
          () => ConnectionString.parse(bad),
          throwsA(isA<MongoConfigError>()),
          reason: bad,
        );
      }
    });

    test('redacts passwords', () {
      expect(
        ConnectionString.redact('mongodb://u:secret@h/db'),
        'mongodb://u:****@h/db',
      );
      expect(
        ConnectionString.redact('mongodb+srv://u:s@c@h'),
        'mongodb+srv://u:****@c@h',
      );
      expect(ConnectionString.redact('mongodb://h'), 'mongodb://h');
    });
  });
}
