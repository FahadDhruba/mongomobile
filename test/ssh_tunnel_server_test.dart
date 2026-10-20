import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mongo_wire/mongo_wire.dart';
import 'package:mongomobile/services/ssh_tunnel.dart';

/// Needs an SSH server that can reach MongoDB. Set SSH_TEST (host:port),
/// SSH_TEST_USER, SSH_TEST_PASSWORD, SSH_TEST_KEY (a key file, encrypted
/// with SSH_TEST_PASSPHRASE) and MONGO_URI as seen from the SSH server.
void main() {
  final env = Platform.environment;
  final server = env['SSH_TEST'];
  final uri = env['MONGO_URI'];
  final skip = server == null || uri == null ? 'SSH_TEST is not set' : null;
  final host = server?.split(':').first ?? '';
  final port = int.tryParse(server?.split(':').last ?? '') ?? 22;

  Future<void> ping(SshTunnel tunnel) async {
    final client = await WireMongoClient.connect(
      uri!,
      options: ConnectOptions(tunnel: tunnel),
    );
    expect(
      await client.runCommand('admin', {'ping': 1}),
      containsPair('ok', 1.0),
    );
    final dbs = await client.listDatabases();
    expect(dbs, isNotEmpty);
    await client.close();
  }

  test('password sign-in, then the host key is pinned', () async {
    final t = await SshTunnel.connect(
      host: host,
      port: port,
      username: env['SSH_TEST_USER']!,
      password: env['SSH_TEST_PASSWORD'],
    );
    expect(t.hostKeyFingerprint, startsWith('SHA256:'));
    await ping(t);
    await t.close();

    final pinned = await SshTunnel.connect(
      host: host,
      port: port,
      username: env['SSH_TEST_USER']!,
      password: env['SSH_TEST_PASSWORD'],
      expectedFingerprint: t.hostKeyFingerprint,
    );
    await pinned.close();
    await expectLater(
      SshTunnel.connect(
        host: host,
        port: port,
        username: env['SSH_TEST_USER']!,
        password: env['SSH_TEST_PASSWORD'],
        expectedFingerprint: 'SHA256:somethingelse',
      ),
      throwsA(isA<HostKeyChanged>()),
    );
  }, skip: skip);

  test('encrypted key sign-in and a wrong password', () async {
    final key = File(env['SSH_TEST_KEY']!).readAsStringSync();
    final t = await SshTunnel.connect(
      host: host,
      port: port,
      username: env['SSH_TEST_USER']!,
      privateKeyPem: key,
      passphrase: env['SSH_TEST_PASSPHRASE'],
    );
    await ping(t);
    await t.close();
    await expectLater(
      SshTunnel.connect(
        host: host,
        port: port,
        username: env['SSH_TEST_USER']!,
        password: 'wrong',
      ),
      throwsA(isA<MongoAuthError>()),
    );
    await expectLater(
      SshTunnel.connect(
        host: host,
        port: port,
        username: env['SSH_TEST_USER']!,
        privateKeyPem: key,
        passphrase: 'nope',
      ),
      throwsA(isA<MongoConfigError>()),
    );
  }, skip: skip);
}
