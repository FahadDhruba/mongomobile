import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mongomobile/models/connection_profile.dart';
import 'package:mongomobile/services/connection_transfer.dart';

void main() {
  final profiles = [
    ConnectionProfile(
      id: 't3',
      name: 'Behind SSH',
      uri: 'mongodb://db.internal:27017',
      tunnel: const TunnelSettings(
        kind: TunnelKind.ssh,
        host: 'bastion',
        port: 22,
        username: 'ops',
        password: 'sshpw',
        privateKeyPem: 'KEY',
        hostKey: 'SHA256:abc',
      ),
      clientCertificatePem: 'CERT',
    ),
    ConnectionProfile(
      id: 'a1',
      name: 'Prod',
      uri: 'mongodb+srv://app:p%40ss@cluster0.ab.mongodb.net/?retryWrites=true',
      colorIndex: 3,
      favorite: true,
      group: 'Work',
      lastUsed: DateTime.utc(2026, 5, 1),
    ),
    const ConnectionProfile(
      id: 'b2',
      name: '',
      uri: 'mongodb://localhost:27017',
      allowInvalidCertificates: true,
    ),
  ];

  test('password helpers', () {
    expect(withoutPassword('mongodb://u:p@h/'), 'mongodb://u@h/');
    expect(withoutPassword('mongodb://h/'), 'mongodb://h/');
    expect(withPassword('mongodb://u@h/', 'p@ss'), 'mongodb://u:p%40ss@h/');
  });

  test('exports in the Compass format without passwords', () async {
    final text = await exportConnections(profiles);
    expect(text, isNot(contains('p%40ss')));
    final j = jsonDecode(text) as Map;
    expect(j['type'], 'Compass Connections');
    final c = (j['connections'] as List)[1] as Map;
    expect(
      (c['connectionOptions'] as Map)['connectionString'],
      'mongodb+srv://app@cluster0.ab.mongodb.net/?retryWrites=true',
    );
    expect(c['favorite'], {'name': 'Prod', 'color': 'color4'});
    expect(needsPassphrase(text), isFalse);

    final back = await importConnections(text);
    expect(text, isNot(contains('sshpw')));
    expect(text, isNot(contains('CERT')));
    expect(back.withoutPasswords, 1);
    final ssh = back.profiles.first.tunnel!;
    expect(ssh.host, 'bastion');
    expect(ssh.hostKey, 'SHA256:abc');
    expect(ssh.password, isEmpty);
    expect(back.profiles[1].group, 'Work');
    expect(back.profiles[1].favorite, isTrue);
    expect(back.profiles[1].colorIndex, 3);
    expect(back.profiles[1].lastUsed, DateTime.utc(2026, 5, 1));
    expect(back.profiles.last.allowInvalidCertificates, isTrue);
  });

  test('encrypts passwords with a passphrase', () async {
    final text = await exportConnections(profiles, passphrase: 'correct horse');
    expect(text, isNot(contains('p%40ss')));
    expect(text, isNot(contains('p@ss')));
    expect(needsPassphrase(text), isTrue);
    await expectLater(
      importConnections(text),
      throwsA(isA<TransferException>()),
    );
    await expectLater(
      importConnections(text, passphrase: 'wrong'),
      throwsA(
        isA<TransferException>().having(
          (e) => e.message,
          'message',
          'Wrong passphrase',
        ),
      ),
    );
    final back = await importConnections(text, passphrase: 'correct horse');
    expect(back.withoutPasswords, 0);
    expect(text, isNot(contains('sshpw')));
    expect(back.profiles.first.tunnel!.password, 'sshpw');
    expect(back.profiles.first.tunnel!.privateKeyPem, 'KEY');
    expect(back.profiles.first.clientCertificatePem, 'CERT');
    expect(
      back.profiles[1].uri,
      'mongodb+srv://app:p%40ss@cluster0.ab.mongodb.net/?retryWrites=true',
    );
  });

  test('reads a file exported by Compass', () async {
    const compass = '''
{
  "type": "Compass Connections",
  "version": {"\$numberInt": "1"},
  "connections": [
    {
      "id": "5f2c",
      "connectionOptions": {
        "connectionString": "mongodb://admin@db.example.com:27017/?authSource=admin"
      },
      "favorite": {"name": "Staging", "color": "color2"},
      "savedConnectionType": "favorite",
      "connectionSecrets": "AAECAwQF"
    },
    {"id": "x", "connectionOptions": {"connectionString": "not a uri"}}
  ]
}''';
    final r = await importConnections(compass);
    expect(r.profiles.single.name, 'Staging');
    expect(r.profiles.single.favorite, isTrue);
    expect(r.profiles.single.colorIndex, 1);
    expect(r.withoutPasswords, 1);
    await expectLater(
      importConnections('{"a": 1}'),
      throwsA(isA<TransferException>()),
    );
  });
}
