import 'package:flutter_test/flutter_test.dart';
import 'package:mongo_wire/mongo_wire.dart';
import 'package:mongomobile/services/connection_form.dart';

void main() {
  test('reads every field from a connection string', () {
    final f = ConnectionForm.fromUri(
      'mongodb://ad%40min:p%3Ass@a.example:27018,b.example/shop'
      '?replicaSet=rs0&authSource=admin&authMechanism=SCRAM-SHA-256'
      '&tls=true&tlsAllowInvalidCertificates=true&readPreference=secondary'
      '&appName=My%20App&connectTimeoutMS=5000&retryWrites=false&w=majority',
    );
    expect(f.srv, isFalse);
    expect(f.hosts, ['a.example:27018', 'b.example:27017']);
    expect(f.auth, AuthMethod.password);
    expect(f.username, 'ad@min');
    expect(f.password, 'p:ss');
    expect(f.mechanism, 'SCRAM-SHA-256');
    expect(f.authSource, 'admin');
    expect(f.tls, TlsMode.on);
    expect(f.allowInvalidCertificates, isTrue);
    expect(f.replicaSet, 'rs0');
    expect(f.readPreference, 'secondary');
    expect(f.appName, 'My App');
    expect(f.database, 'shop');
    expect(f.connectTimeoutMs, '5000');
    expect(f.otherOptions, {'retrywrites': 'false', 'w': 'majority'});
  });

  test('round-trips through the form', () {
    for (final uri in [
      'mongodb://localhost:27017/',
      'mongodb+srv://user:pw@cluster0.abc.mongodb.net/app?retryWrites=true&w=majority',
      'mongodb://u:p%40ss@h:1/?authMechanism=PLAIN&authSource=%24external',
      'mongodb://h:1/?directConnection=true&tls=false',
      'mongodb://h:1/?authMechanism=MONGODB-X509&tls=true',
    ]) {
      final out = ConnectionForm.fromUri(uri).toUri();
      final a = ConnectionString.parse(uri);
      final b = ConnectionString.parse(out);
      expect(b.isSrv, a.isSrv, reason: out);
      expect(b.hosts, a.hosts, reason: out);
      expect(b.username, a.username, reason: out);
      expect(b.password, a.password, reason: out);
      expect(b.database, a.database, reason: out);
      expect(b.options, a.options, reason: out);
    }
  });

  test('builds a connection string from fields', () {
    final f = ConnectionForm(
      srv: true,
      hosts: ['cluster0.abc.mongodb.net'],
      auth: AuthMethod.password,
      username: 'app user',
      password: 'p@ss/word',
      readPreference: 'nearest',
      appName: 'Field app',
    );
    expect(f.error, isNull);
    final uri = f.toUri();
    expect(
      uri,
      'mongodb+srv://app%20user:p%40ss%2Fword@cluster0.abc.mongodb.net/'
      '?readPreference=nearest&appName=Field%20app',
    );
    final cs = ConnectionString.parse(uri);
    expect(cs.password, 'p@ss/word');
    expect(cs.appName, 'Field app');
  });

  test('reports problems', () {
    expect(ConnectionForm(hosts: ['']).error, 'Add a host');
    expect(
      ConnectionForm(srv: true, hosts: ['a', 'b']).error,
      'mongodb+srv takes exactly one host name',
    );
    expect(
      ConnectionForm(srv: true, hosts: ['a:1']).error,
      'mongodb+srv host names have no port',
    );
    expect(ConnectionForm(auth: AuthMethod.password).error, 'Enter a username');
    expect(
      ConnectionForm(connectTimeoutMs: 'soon').error,
      'Connect timeout must be a number of milliseconds',
    );
  });
}
