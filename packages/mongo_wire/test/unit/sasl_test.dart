import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:mongo_wire/mongo_wire.dart';
import 'package:test/test.dart';

/// A pretend mongod that speaks just enough OP_MSG to answer `hello`,
/// `buildInfo` and the SASL conversations of MONGODB-OIDC and MONGODB-AWS.
class FakeServer {
  FakeServer(this.handle);

  /// Answers one command (with `$db` set).
  final Map<String, dynamic> Function(Map<String, dynamic> cmd) handle;
  late final ServerSocket _server;
  final commands = <Map<String, dynamic>>[];

  int get port => _server.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((s) {
      final buf = BytesBuilder();
      s.listen((data) {
        buf.add(data);
        var bytes = buf.toBytes();
        while (bytes.length >= 4) {
          final len = ByteData.sublistView(bytes).getInt32(0, Endian.little);
          if (bytes.length < len) break;
          final msg = Uint8List.sublistView(bytes, 0, len);
          final id = ByteData.sublistView(msg).getInt32(4, Endian.little);
          // header 16, flags 4, kind 1, then the document.
          final cmd = Bson.decode(Uint8List.sublistView(msg, 21));
          commands.add(cmd);
          final reply = Bson.encode({...handle(cmd)});
          final out = ByteData(21);
          out.setInt32(0, 21 + reply.length, Endian.little);
          out.setInt32(4, id + 1000, Endian.little);
          out.setInt32(8, id, Endian.little);
          out.setInt32(12, 2013, Endian.little);
          s.add([...out.buffer.asUint8List(), ...reply]);
          bytes = Uint8List.fromList(bytes.sublist(len));
        }
        buf.clear();
        buf.add(bytes);
      }, onError: (_) {});
    });
  }

  Future<void> close() => _server.close();
}

Map<String, dynamic> hello() => {
  'ok': 1.0,
  'isWritablePrimary': true,
  'maxWireVersion': 21,
  'minWireVersion': 0,
  'maxBsonObjectSize': 16777216,
  'maxMessageSizeBytes': 48000000,
};

void main() {
  test('MONGODB-OIDC asks the callback once and sends the token', () async {
    var calls = 0;
    final server = FakeServer((cmd) {
      if (cmd.containsKey('hello') || cmd.containsKey('isMaster')) {
        return hello();
      }
      if (cmd.containsKey('buildInfo')) return {'ok': 1.0, 'version': '7.0.0'};
      if (cmd['saslStart'] == 1) {
        final p = Bson.decode((cmd['payload'] as BsonBinary).data);
        if (p.containsKey('jwt')) {
          return {
            'ok': p['jwt'] == 'tok-1' ? 1.0 : 0.0,
            'done': true,
            'conversationId': 1,
            'code': 18,
            'errmsg': 'bad',
          };
        }
        return {
          'ok': 1.0,
          'done': false,
          'conversationId': 7,
          'payload': BsonBinary(
            0,
            Bson.encode({
              'issuer': 'https://idp.example.com',
              'clientId': 'abc',
              'requestScopes': ['s1'],
            }),
          ),
        };
      }
      if (cmd['saslContinue'] == 1) {
        final p = Bson.decode((cmd['payload'] as BsonBinary).data);
        return p['jwt'] == 'tok-1'
            ? {'ok': 1.0, 'done': true, 'conversationId': 7}
            : {'ok': 0.0, 'code': 18, 'errmsg': 'Authentication failed'};
      }
      return {'ok': 1.0};
    });
    await server.start();
    OidcIdpInfo? seen;
    final client = await WireMongoClient.connect(
      'mongodb://127.0.0.1:${server.port}/?authMechanism=MONGODB-OIDC'
      '&directConnection=true',
      options: ConnectOptions(
        poolSize: 3,
        oidcCallback: (idp, {username}) async {
          calls++;
          seen = idp;
          return 'tok-1';
        },
      ),
    );
    expect(seen!.issuer, 'https://idp.example.com');
    expect(seen!.clientId, 'abc');
    expect(seen!.requestScopes, ['s1']);
    // More connections reuse the token instead of signing in again.
    await Future.wait([
      for (var i = 0; i < 3; i++) client.runCommand('admin', {'ping': 1}),
    ]);
    expect(calls, 1);
    final starts = server.commands.where((c) => c['saslStart'] == 1);
    expect(starts.every((c) => c[r'$db'] == r'$external'), isTrue);
    await client.close();
    await server.close();
  });

  test('MONGODB-AWS sends a signed STS request', () async {
    late List<int> clientNonce;
    Map<String, dynamic>? signed;
    final server = FakeServer((cmd) {
      if (cmd.containsKey('hello') || cmd.containsKey('isMaster')) {
        return hello();
      }
      if (cmd.containsKey('buildInfo')) return {'ok': 1.0, 'version': '7.0.0'};
      if (cmd['saslStart'] == 1) {
        expect(cmd['mechanism'], 'MONGODB-AWS');
        final p = Bson.decode((cmd['payload'] as BsonBinary).data);
        expect(p['p'], 110);
        clientNonce = (p['r'] as BsonBinary).data;
        return {
          'ok': 1.0,
          'done': false,
          'conversationId': 3,
          'payload': BsonBinary(
            0,
            Bson.encode({
              's': BsonBinary(0, [...clientNonce, ...List.filled(32, 9)]),
              'h': 'sts.amazonaws.com',
            }),
          ),
        };
      }
      if (cmd['saslContinue'] == 1) {
        signed = Bson.decode((cmd['payload'] as BsonBinary).data);
        return {'ok': 1.0, 'done': true, 'conversationId': 3};
      }
      return {'ok': 1.0};
    });
    await server.start();
    final client = await WireMongoClient.connect(
      'mongodb://AKIDEXAMPLE:secret@127.0.0.1:${server.port}/'
      '?authMechanism=MONGODB-AWS&directConnection=true'
      '&authMechanismProperties=AWS_SESSION_TOKEN:tok',
      options: const ConnectOptions(poolSize: 1),
    );
    expect(clientNonce, hasLength(32));
    expect(
      signed!['a'],
      startsWith('AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/'),
    );
    expect(signed!['a'], contains('/us-east-1/sts/aws4_request'));
    expect(signed!['a'], contains('x-amz-security-token'));
    expect(signed!['t'], 'tok');
    await client.close();
    await server.close();
  });

  test(
    'MONGODB-AWS rejects a server nonce that does not extend ours',
    () async {
      final server = FakeServer((cmd) {
        if (cmd.containsKey('hello') || cmd.containsKey('isMaster')) {
          return hello();
        }
        if (cmd['saslStart'] == 1) {
          return {
            'ok': 1.0,
            'conversationId': 3,
            'payload': BsonBinary(
              0,
              Bson.encode({
                's': BsonBinary(0, List.filled(64, 1)),
                'h': 'sts.amazonaws.com',
              }),
            ),
          };
        }
        return {'ok': 1.0};
      });
      await server.start();
      await expectLater(
        WireMongoClient.connect(
          'mongodb://AKID:secret@127.0.0.1:${server.port}/'
          '?authMechanism=MONGODB-AWS&directConnection=true',
        ),
        throwsA(isA<MongoAuthError>()),
      );
      await server.close();
    },
  );
}
