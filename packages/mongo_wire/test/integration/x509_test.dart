@Tags(['integration'])
library;

import 'dart:io';

import 'package:mongo_wire/mongo_wire.dart';
import 'package:test/test.dart';

import 'socks_proxy.dart';

/// Needs a TLS server that trusts the test CA. Set MONGO_TLS_URI (e.g.
/// `mongodb://localhost:27018/?tls=true`) and MONGO_TLS_CERTS, a folder
/// with ca.pem and client.pem (certificate and key).
final String? uri = Platform.environment['MONGO_TLS_URI'];
final String? certs = Platform.environment['MONGO_TLS_CERTS'];

void main() {
  if (uri == null || certs == null) {
    test('x509 tests', () {}, skip: 'MONGO_TLS_URI is not set');
    return;
  }
  final ca = File('$certs/ca.pem').readAsStringSync();
  final client = File('$certs/client.pem').readAsStringSync();

  test('verifies the server with a custom CA', () async {
    final c = await WireMongoClient.connect(
      uri!,
      options: ConnectOptions(caCertificatePem: ca),
    );
    expect(await c.runCommand('admin', {'ping': 1}), containsPair('ok', 1.0));
    await c.close();
  });

  test('rejects the server without the CA', () async {
    await expectLater(
      WireMongoClient.connect(uri!),
      throwsA(isA<MongoException>()),
    );
  });

  test('signs in with an X.509 client certificate', () async {
    final c = await WireMongoClient.connect(
      '$uri&authMechanism=MONGODB-X509',
      options: ConnectOptions(
        caCertificatePem: ca,
        clientCertificatePem: client,
      ),
    );
    final status = await c.runCommand('admin', {'connectionStatus': 1});
    final users = (status['authInfo'] as Map)['authenticatedUsers'] as List;
    expect(
      (users.single as Map)['user'],
      'O=MongoMobileClient,OU=apps,CN=mmclient',
    );
    await c.close();
  });

  test('a certificate without a key is reported clearly', () async {
    await expectLater(
      WireMongoClient.connect(
        '$uri&authMechanism=MONGODB-X509',
        options: ConnectOptions(
          caCertificatePem: ca,
          clientCertificatePem: client.substring(
            0,
            client.indexOf('-----BEGIN PRIVATE KEY'),
          ),
        ),
      ),
      throwsA(isA<MongoConfigError>()),
    );
  });

  test('TLS runs end to end through a tunnel', () async {
    final proxy = TestSocksProxy();
    await proxy.start();
    final tunnel = Socks5Tunnel(proxy: HostAddress('127.0.0.1', proxy.port));
    final c = await WireMongoClient.connect(
      '$uri&authMechanism=MONGODB-X509',
      options: ConnectOptions(
        caCertificatePem: ca,
        clientCertificatePem: client,
        tunnel: tunnel,
      ),
    );
    expect(await c.runCommand('admin', {'ping': 1}), containsPair('ok', 1.0));
    await c.close();
    await tunnel.close();
    await proxy.close();
    expect(proxy.targets, contains('localhost:27018'));
  });
}
