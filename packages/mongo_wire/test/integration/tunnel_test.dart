@Tags(['integration'])
library;

import 'dart:io';

import 'package:mongo_wire/mongo_wire.dart';
import 'package:test/test.dart';

import 'socks_proxy.dart';

final String? uri = Platform.environment['MONGO_URI'];

void main() {
  if (uri == null) {
    test('tunnel tests', () {}, skip: 'MONGO_URI is not set');
    return;
  }
  final cs = ConnectionString.parse(uri!);
  // Reach the server by name through the proxy, as a remote host would be.
  final target = uri!.replaceFirst(
    cs.hosts.first.host,
    cs.hosts.first.host == '127.0.0.1' ? 'localhost' : cs.hosts.first.host,
  );

  test('connects through a SOCKS5 proxy', () async {
    final proxy = TestSocksProxy();
    await proxy.start();
    final tunnel = Socks5Tunnel(proxy: HostAddress('127.0.0.1', proxy.port));
    final client = await WireMongoClient.connect(
      target,
      options: ConnectOptions(tunnel: tunnel),
    );
    final dbs = await client.listDatabases();
    expect(dbs.map((d) => d.name), contains('admin'));
    await client.close();
    await tunnel.close();
    await proxy.close();
    expect(
      proxy.targets,
      everyElement(contains(cs.hosts.first.port.toString())),
    );
  });

  test('SOCKS5 with a user name and password', () async {
    final proxy = TestSocksProxy(username: 'u', password: 'p@ss');
    await proxy.start();
    final good = Socks5Tunnel(
      proxy: HostAddress('127.0.0.1', proxy.port),
      username: 'u',
      password: 'p@ss',
    );
    final client = await WireMongoClient.connect(
      target,
      options: ConnectOptions(tunnel: good),
    );
    expect(
      await client.runCommand('admin', {'ping': 1}),
      containsPair('ok', 1.0),
    );
    await client.close();
    await good.close();

    final bad = Socks5Tunnel(
      proxy: HostAddress('127.0.0.1', proxy.port),
      username: 'u',
      password: 'wrong',
    );
    final local = await bad.forward(cs.hosts.first);
    // The proxy refuses, so the forwarded connection closes at once.
    final s = await Socket.connect(local.host, local.port);
    expect(await s.isEmpty, isTrue);
    s.destroy();
    await bad.close();
    await proxy.close();
  });
}
