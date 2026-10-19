import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../bson/types.dart';
import '../errors.dart';
import 'connection.dart';
import 'connection_string.dart';
import 'scram.dart';

/// What a server said about itself in its `hello` reply.
final class ServerDescription {
  ServerDescription(this.address, this.hello, this.roundTrip);

  final HostAddress address;
  final Map<String, dynamic> hello;
  final Duration roundTrip;

  bool get isWritablePrimary =>
      hello['isWritablePrimary'] == true || hello['ismaster'] == true;
  bool get isSecondary => hello['secondary'] == true;
  bool get isArbiter => hello['arbiterOnly'] == true;
  bool get isMongos => hello['msg'] == 'isdbgrid';
  String? get setName => hello['setName'] as String?;
  String? get primary => hello['primary'] as String?;

  List<String> get members => [
    for (final key in const ['hosts', 'passives'])
      ...((hello[key] as List?) ?? const []).map((e) => '$e'),
  ];

  int get maxWireVersion => _int(hello['maxWireVersion']) ?? 0;

  List<String>? get saslSupportedMechs =>
      (hello['saslSupportedMechs'] as List?)?.map((e) => '$e').toList();

  /// Standalone, replica set member or mongos, for display.
  String get kind {
    if (isMongos) return 'Sharded cluster (mongos)';
    if (setName != null) {
      if (isWritablePrimary) return 'Replica set primary';
      if (isSecondary) return 'Replica set secondary';
      if (isArbiter) return 'Replica set arbiter';
      return 'Replica set member';
    }
    return 'Standalone';
  }
}

int? _int(Object? v) => switch (v) {
  int() => v,
  BsonLong() => v.value,
  double() => v.toInt(),
  _ => null,
};

/// Credentials and client details used when opening connections.
final class HandshakeOptions {
  HandshakeOptions({
    this.username,
    this.password,
    this.authSource = 'admin',
    this.authMechanism,
    this.appName = 'MongoMobile',
  });

  final String? username;
  final String? password;
  final String authSource;
  final String? authMechanism;
  final String appName;

  /// Shared between connections of one client.
  final Map<String, Uint8List> saltedPasswordCache = {};

  bool get hasCredentials => username != null;
}

Map<String, dynamic> _clientMetadata(String appName) => {
  'application': {'name': appName},
  'driver': {'name': 'mongo_wire', 'version': '0.1.0'},
  'os': {
    'type': Platform.operatingSystem,
    'name': Platform.operatingSystem,
    'version': Platform.operatingSystemVersion.split(' ').first,
  },
  'platform': 'Dart ${Platform.version.split(' ').first}',
};

/// Runs `hello` on a fresh connection, falling back to `isMaster` on old
/// servers, then authenticates when credentials are set.
Future<ServerDescription> handshake(
  WireConnection conn,
  HandshakeOptions options, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final cmd = <String, dynamic>{
    'hello': 1,
    'helloOk': true,
    'client': _clientMetadata(options.appName),
    if (options.hasCredentials && options.authMechanism == null)
      'saslSupportedMechs': '${options.authSource}.${options.username}',
  };
  final started = DateTime.now();
  Map<String, dynamic> reply;
  try {
    reply = (await conn.send('admin', cmd, timeout: timeout)).document;
  } on MongoServerError catch (e) {
    // Servers before 4.4.2 don't know `hello`.
    if (e.code != 59) rethrow;
    cmd
      ..remove('hello')
      ..remove('helloOk');
    reply = (await conn.send('admin', {
      'isMaster': 1,
      ...cmd,
    }, timeout: timeout)).document;
  }
  final desc = ServerDescription(
    conn.address,
    reply,
    DateTime.now().difference(started),
  );
  if (desc.maxWireVersion < 6) {
    conn.close();
    throw MongoConfigError(
      'This server is too old. MongoMobile needs MongoDB 3.6 or newer.',
    );
  }
  conn.maxBsonObjectSize =
      _int(reply['maxBsonObjectSize']) ?? conn.maxBsonObjectSize;
  conn.maxMessageSizeBytes =
      _int(reply['maxMessageSizeBytes']) ?? conn.maxMessageSizeBytes;
  if (options.hasCredentials && !desc.isArbiter) {
    await authenticate(conn, options, desc, timeout: timeout);
  }
  return desc;
}

/// Authenticates [conn] with the configured mechanism.
Future<void> authenticate(
  WireConnection conn,
  HandshakeOptions options,
  ServerDescription desc, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final mech = options.authMechanism ?? _negotiate(desc);
  try {
    switch (mech) {
      case 'SCRAM-SHA-256':
        await _scram(conn, options, ScramMechanism.sha256, timeout);
      case 'SCRAM-SHA-1':
        await _scram(conn, options, ScramMechanism.sha1, timeout);
      case 'PLAIN':
        await _plain(conn, options, timeout);
      default:
        throw MongoAuthError(
          'The authentication mechanism "$mech" is not '
          'supported. Use SCRAM-SHA-256, SCRAM-SHA-1 or PLAIN.',
        );
    }
  } on MongoServerError catch (e) {
    conn.close();
    if (e.code == 18) {
      throw MongoAuthError(
        'Authentication failed: wrong user name, password '
        'or authSource (${options.authSource}).',
      );
    }
    throw MongoAuthError('Authentication failed: ${e.message}');
  } on MongoAuthError {
    conn.close();
    rethrow;
  }
}

String _negotiate(ServerDescription desc) {
  final mechs = desc.saslSupportedMechs;
  if (mechs != null) {
    if (mechs.contains('SCRAM-SHA-256')) return 'SCRAM-SHA-256';
    if (mechs.contains('SCRAM-SHA-1')) return 'SCRAM-SHA-1';
  }
  return desc.maxWireVersion >= 7 ? 'SCRAM-SHA-256' : 'SCRAM-SHA-1';
}

Uint8List _payload(Object? p) {
  if (p is BsonBinary) return p.data;
  throw MongoAuthError('Unexpected SASL payload from the server');
}

Future<void> _scram(
  WireConnection conn,
  HandshakeOptions o,
  ScramMechanism mechanism,
  Duration timeout,
) async {
  final scram = ScramConversation(
    mechanism: mechanism,
    username: o.username!,
    password: o.password ?? '',
    saltedPasswordCache: o.saltedPasswordCache,
  );
  final start = (await conn.send(o.authSource, {
    'saslStart': 1,
    'mechanism': mechanism.wireName,
    'payload': BsonBinary(0, scram.clientFirst()),
    'autoAuthorize': 1,
    'options': {'skipEmptyExchange': true},
  }, timeout: timeout)).document;
  final id = start['conversationId'];
  final finalMsg = scram.clientFinal(_payload(start['payload']));
  var reply = (await conn.send(o.authSource, {
    'saslContinue': 1,
    'conversationId': id,
    'payload': BsonBinary(0, finalMsg),
  }, timeout: timeout)).document;
  scram.verifyServerFinal(_payload(reply['payload']));
  var rounds = 0;
  while (reply['done'] != true) {
    if (++rounds > 3) throw MongoAuthError('SCRAM conversation did not end');
    reply = (await conn.send(o.authSource, {
      'saslContinue': 1,
      'conversationId': id,
      'payload': BsonBinary(0, const []),
    }, timeout: timeout)).document;
  }
}

Future<void> _plain(
  WireConnection conn,
  HandshakeOptions o,
  Duration timeout,
) async {
  final payload = <int>[
    0,
    ...utf8.encode(o.username!),
    0,
    ...utf8.encode(o.password ?? ''),
  ];
  await conn.send(o.authSource, {
    'saslStart': 1,
    'mechanism': 'PLAIN',
    'payload': BsonBinary(0, payload),
    'autoAuthorize': 1,
  }, timeout: timeout);
}
