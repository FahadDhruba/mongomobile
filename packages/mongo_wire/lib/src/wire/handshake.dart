import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../bson/codec.dart';
import '../bson/types.dart';
import '../errors.dart';
import 'aws.dart';
import 'connection.dart';
import 'connection_string.dart';
import 'oidc.dart';
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
    this.mechanismProperties = const {},
    this.oidcCallback,
  });

  final String? username;
  final String? password;
  final String authSource;
  final String? authMechanism;
  final String appName;

  /// `authMechanismProperties`, e.g. `AWS_SESSION_TOKEN`.
  final Map<String, String> mechanismProperties;
  final OidcCallback? oidcCallback;

  /// The OIDC access token, shared by the client's connections so the user
  /// signs in once.
  Future<String>? oidcToken;

  /// Shared between connections of one client.
  final Map<String, Uint8List> saltedPasswordCache = {};

  /// X.509 and OIDC can sign in without a user name.
  bool get hasCredentials =>
      username != null ||
      authMechanism == 'MONGODB-X509' ||
      authMechanism == 'MONGODB-OIDC';
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
    if (options.username != null && options.authMechanism == null)
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
      case 'MONGODB-X509':
        await conn.send(r'$external', {
          'authenticate': 1,
          'mechanism': 'MONGODB-X509',
          if (options.username != null) 'user': options.username,
        }, timeout: timeout);
      case 'MONGODB-AWS':
        await _aws(conn, options, timeout);
      case 'MONGODB-OIDC':
        await _oidc(conn, options, timeout);
      default:
        throw MongoAuthError(
          'The authentication mechanism "$mech" is not supported. Use '
          'SCRAM-SHA-256, SCRAM-SHA-1, PLAIN (LDAP), MONGODB-X509, '
          'MONGODB-AWS or MONGODB-OIDC.',
        );
    }
  } on MongoServerError catch (e) {
    conn.close();
    if (mech == 'MONGODB-OIDC') options.oidcToken = null;
    if (e.code == 18) {
      throw MongoAuthError(switch (mech) {
        'MONGODB-X509' =>
          'Authentication failed: the server did not accept the client '
              'certificate. Create a user in \$external named after its '
              'subject.',
        'MONGODB-AWS' =>
          'Authentication failed: AWS did not accept the access key, '
              'secret or session token, or no database user matches the IAM '
              'identity.',
        'MONGODB-OIDC' =>
          'Authentication failed: the server did not accept the token.',
        _ =>
          'Authentication failed: wrong user name, password '
              'or authSource (${options.authSource}).',
      });
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

Future<void> _aws(
  WireConnection conn,
  HandshakeOptions o,
  Duration timeout,
) async {
  final user = o.username;
  final secret = o.password;
  if (user == null || secret == null || secret.isEmpty) {
    throw MongoAuthError(
      'MONGODB-AWS needs the access key ID as the user name and the secret '
      'access key as the password',
    );
  }
  final rnd = Random.secure();
  final nonce = List.generate(32, (_) => rnd.nextInt(256));
  final start = (await conn.send(r'$external', {
    'saslStart': 1,
    'mechanism': 'MONGODB-AWS',
    'payload': BsonBinary(
      0,
      Bson.encode({'r': BsonBinary(0, nonce), 'p': 110}),
    ),
  }, timeout: timeout)).document;
  final server = Bson.decode(_payload(start['payload']));
  final s = server['s'];
  final host = server['h'];
  if (s is! BsonBinary ||
      s.data.length != 64 ||
      !_startsWith(s.data, nonce) ||
      host is! String ||
      !validStsHost(host)) {
    throw MongoAuthError('The server sent an invalid MONGODB-AWS reply');
  }
  final payload = awsClientFinal(
    credentials: AwsCredentials(
      user,
      secret,
      o.mechanismProperties['AWS_SESSION_TOKEN'],
    ),
    host: host,
    serverNonce: s.data,
    now: DateTime.now(),
  );
  final reply = (await conn.send(r'$external', {
    'saslContinue': 1,
    'conversationId': start['conversationId'],
    'payload': BsonBinary(0, Bson.encode(payload)),
  }, timeout: timeout)).document;
  if (reply['done'] != true) {
    throw MongoAuthError('The MONGODB-AWS conversation did not finish');
  }
}

bool _startsWith(List<int> a, List<int> prefix) {
  if (a.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (a[i] != prefix[i]) return false;
  }
  return true;
}

/// MONGODB-OIDC: a token given as the password is used as is; otherwise
/// the server names its identity provider and [HandshakeOptions.oidcCallback]
/// signs the user in there.
Future<void> _oidc(
  WireConnection conn,
  HandshakeOptions o,
  Duration timeout,
) async {
  Future<void> sendJwt(String token, [Object? conversationId]) async {
    final payload = BsonBinary(0, Bson.encode({'jwt': token}));
    final reply = (await conn.send(
      r'$external',
      conversationId == null
          ? {'saslStart': 1, 'mechanism': 'MONGODB-OIDC', 'payload': payload}
          : {
              'saslContinue': 1,
              'conversationId': conversationId,
              'payload': payload,
            },
      timeout: timeout,
    )).document;
    if (reply['done'] != true) {
      throw MongoAuthError('The MONGODB-OIDC conversation did not finish');
    }
  }

  final given = o.password;
  if (given != null && given.isNotEmpty) return sendJwt(given);
  final cached = o.oidcToken;
  if (cached != null) {
    try {
      return await sendJwt(await cached);
    } on MongoServerError catch (e) {
      // An expired token: sign in again below.
      if (e.code != 18) rethrow;
      o.oidcToken = null;
    }
  }
  final callback = o.oidcCallback;
  if (callback == null) {
    throw MongoAuthError(
      'MONGODB-OIDC needs an access token as the password, or a sign-in '
      'callback',
    );
  }
  final start = (await conn.send(r'$external', {
    'saslStart': 1,
    'mechanism': 'MONGODB-OIDC',
    'payload': BsonBinary(
      0,
      Bson.encode({if (o.username != null) 'n': o.username}),
    ),
  }, timeout: timeout)).document;
  final idp = OidcIdpInfo.fromReply(Bson.decode(_payload(start['payload'])));
  if (idp.issuer.isEmpty) {
    throw MongoAuthError('The server did not name an identity provider');
  }
  final token = o.oidcToken ??= callback(idp, username: o.username);
  String jwt;
  try {
    jwt = await token;
  } on Object {
    o.oidcToken = null;
    rethrow;
  }
  await sendJwt(jwt, start['conversationId']);
}
