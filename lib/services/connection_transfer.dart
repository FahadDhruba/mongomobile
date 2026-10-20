import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:mongo_wire/mongo_wire.dart';
import 'package:pointycastle/export.dart';

import '../models/connection_profile.dart';

/// Thrown for files that can't be imported, or a wrong passphrase.
class TransferException implements Exception {
  TransferException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The connection string without its password.
String withoutPassword(String uri) => uri.replaceFirstMapped(
  RegExp(r'^(mongodb(?:\+srv)?://[^:@/]*)(:[^@]*)(@)'),
  (m) => '${m[1]}${m[3]}',
);

/// Puts [password] (decoded) back into [uri], which has a user name.
String withPassword(String uri, String password) => uri.replaceFirstMapped(
  RegExp(r'^(mongodb(?:\+srv)?://[^:@/]+)(:[^@]*)?(@)'),
  (m) => '${m[1]}:${Uri.encodeComponent(password)}${m[3]}',
);

const _iterations = 200000;

/// Writes [profiles] in the file format Compass imports ("Compass
/// Connections", version 1). Passwords are left out unless [passphrase] is
/// given; then they are encrypted (AES-256-GCM, key from PBKDF2-SHA256) in
/// a `mongomobile` section that only MongoMobile reads, so Compass imports
/// the same file without the passwords.
Future<String> exportConnections(
  List<ConnectionProfile> profiles, {
  String? passphrase,
}) async {
  final secrets = <String, Map<String, dynamic>>{};
  final connections = <Map<String, dynamic>>[];
  final extra = <String, dynamic>{};
  for (final p in profiles) {
    String? password;
    try {
      password = ConnectionString.parse(p.uri).password;
    } on MongoException {
      password = null;
    }
    final secret = <String, dynamic>{
      'password': ?password,
      if (p.tunnel case final t?)
        if (t.password.isNotEmpty ||
            t.privateKeyPem.isNotEmpty ||
            t.passphrase.isNotEmpty)
          'tunnel': {
            if (t.password.isNotEmpty) 'password': t.password,
            if (t.privateKeyPem.isNotEmpty) 'privateKeyPem': t.privateKeyPem,
            if (t.passphrase.isNotEmpty) 'passphrase': t.passphrase,
          },
      'clientCertificatePem': ?p.clientCertificatePem,
      if (p.encryption case final e?)
        if (e.localKey.isNotEmpty || e.awsSecretAccessKey.isNotEmpty)
          'encryption': e.toJson(),
      'clientKeyPassword': ?p.clientKeyPassword,
    };
    if (secret.isNotEmpty) secrets[p.id] = secret;
    connections.add({
      'id': p.id,
      'connectionOptions': {'connectionString': withoutPassword(p.uri)},
      if (p.name.trim().isNotEmpty || p.favorite)
        'favorite': {
          'name': p.displayName,
          'color': 'color${p.colorIndex % 10 + 1}',
        },
      'savedConnectionType': p.favorite ? 'favorite' : 'recent',
      if (p.lastUsed != null)
        'lastUsed': {r'$date': p.lastUsed!.toUtc().toIso8601String()},
    });
    extra[p.id] = {
      'name': p.name,
      'colorIndex': p.colorIndex,
      if (p.favorite) 'favorite': true,
      if (p.group.isNotEmpty) 'group': p.group,
      if (p.allowInvalidCertificates) 'allowInvalidCertificates': true,
      if (p.caCertificatePem != null) 'caCertificatePem': p.caCertificatePem,
      if (p.tunnel != null) 'tunnel': p.tunnel!.toJson(secrets: false),
      if (p.encryption != null)
        'encryption': p.encryption!.toJson(secrets: false),
    };
  }
  final mm = <String, dynamic>{'version': 1, 'connections': extra};
  if (passphrase != null && passphrase.isNotEmpty && secrets.isNotEmpty) {
    mm['secrets'] = await _encrypt(jsonEncode(secrets), passphrase);
  }
  return const JsonEncoder.withIndent('  ').convert({
    'type': 'Compass Connections',
    'version': {r'$numberInt': '1'},
    'connections': connections,
    'mongomobile': mm,
  });
}

/// What an import file holds.
class ImportedConnections {
  const ImportedConnections(this.profiles, {required this.withoutPasswords});
  final List<ConnectionProfile> profiles;

  /// How many connections need a password the file did not provide.
  final int withoutPasswords;
}

/// Whether [text] has passwords that need a passphrase.
bool needsPassphrase(String text) {
  try {
    final j = jsonDecode(text);
    return j is Map && (j['mongomobile'] as Map?)?['secrets'] != null;
  } on FormatException {
    return false;
  }
}

/// Reads a file written by [exportConnections] or by Compass's "Export
/// saved connections". Compass's own encrypted passwords can't be read;
/// those connections come in without them.
Future<ImportedConnections> importConnections(
  String text, {
  String? passphrase,
}) async {
  final Object? j;
  try {
    j = jsonDecode(text);
  } on FormatException {
    throw TransferException('This is not a JSON file');
  }
  if (j is! Map || j['connections'] is! List) {
    throw TransferException(
      'This is not a connections file: it has no "connections" list',
    );
  }
  final mm = j['mongomobile'] as Map? ?? const {};
  final extra = mm['connections'] as Map? ?? const {};
  var secrets = const <String, dynamic>{};
  if (mm['secrets'] case final Map enc) {
    if (passphrase == null || passphrase.isEmpty) {
      throw TransferException('Enter the passphrase this file was saved with');
    }
    secrets =
        jsonDecode(await _decrypt(enc, passphrase)) as Map<String, dynamic>;
  }
  final profiles = <ConnectionProfile>[];
  var missing = 0;
  for (final c in (j['connections'] as List).whereType<Map>()) {
    var uri =
        ((c['connectionOptions'] as Map?)?['connectionString'] as String?) ??
        '';
    try {
      ConnectionString.parse(uri);
    } on MongoException {
      continue;
    }
    final id = '${c['id'] ?? ConnectionProfile.newId()}';
    final x = extra[id] as Map? ?? const {};
    // Older files kept only the password, as a string.
    final secret = switch (secrets[id]) {
      final String p => {'password': p},
      final Map m => m,
      _ => const {},
    };
    final password = secret['password'];
    if (password is String) uri = withPassword(uri, password);
    var tunnel = TunnelSettings.fromJson(x['tunnel']);
    if (tunnel != null && secret['tunnel'] is Map) {
      final t = secret['tunnel'] as Map;
      tunnel = TunnelSettings.fromJson({
        ...tunnel.toJson(),
        ...t.cast<String, dynamic>(),
      });
    }
    final cs = ConnectionString.parse(uri);
    if (cs.username != null && cs.password == null) missing++;
    final fav = c['favorite'] as Map?;
    final color = RegExp(r'\d+').firstMatch('${fav?['color'] ?? ''}');
    final lastUsed = switch (c['lastUsed']) {
      {r'$date': final String d} => DateTime.tryParse(d),
      final String d => DateTime.tryParse(d),
      _ => null,
    };
    profiles.add(
      ConnectionProfile(
        id: id,
        name: x['name'] as String? ?? fav?['name'] as String? ?? '',
        uri: uri,
        colorIndex:
            x['colorIndex'] as int? ??
            (color == null ? 0 : (int.parse(color[0]!) - 1).clamp(0, 9)),
        favorite:
            x['favorite'] == true || c['savedConnectionType'] == 'favorite',
        group: x['group'] as String? ?? '',
        allowInvalidCertificates: x['allowInvalidCertificates'] == true,
        caCertificatePem: x['caCertificatePem'] as String?,
        tunnel: tunnel,
        encryption: EncryptionSettings.fromJson(
          secret['encryption'] ?? x['encryption'],
        ),
        clientCertificatePem: secret['clientCertificatePem'] as String?,
        clientKeyPassword: secret['clientKeyPassword'] as String?,
        lastUsed: lastUsed,
      ),
    );
  }
  if (profiles.isEmpty) {
    throw TransferException('The file has no connections this app can read');
  }
  return ImportedConnections(profiles, withoutPasswords: missing);
}

Future<Map<String, dynamic>> _encrypt(String plain, String passphrase) async {
  final rnd = Random.secure();
  final salt = Uint8List.fromList(List.generate(16, (_) => rnd.nextInt(256)));
  final iv = Uint8List.fromList(List.generate(12, (_) => rnd.nextInt(256)));
  final key = await _deriveKey(passphrase, salt, _iterations);
  final cipher = GCMBlockCipher(AESEngine())
    ..init(true, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
  final out = cipher.process(Uint8List.fromList(utf8.encode(plain)));
  return {
    'kdf': 'pbkdf2-sha256',
    'iterations': _iterations,
    'salt': base64.encode(salt),
    'cipher': 'aes-256-gcm',
    'iv': base64.encode(iv),
    'data': base64.encode(out),
  };
}

Future<String> _decrypt(Map enc, String passphrase) async {
  try {
    final salt = base64.decode(enc['salt'] as String);
    final iv = base64.decode(enc['iv'] as String);
    final data = base64.decode(enc['data'] as String);
    final key = await _deriveKey(
      passphrase,
      salt,
      (enc['iterations'] as num).toInt(),
    );
    final cipher = GCMBlockCipher(AESEngine())
      ..init(false, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
    return utf8.decode(cipher.process(data));
  } on InvalidCipherTextException {
    throw TransferException('Wrong passphrase');
  } on ArgumentError {
    throw TransferException('Wrong passphrase');
  } on Object catch (e) {
    if (e is TransferException) rethrow;
    throw TransferException('The saved passwords could not be read');
  }
}

/// PBKDF2 off the UI thread: it takes a moment on a phone on purpose.
Future<Uint8List> _deriveKey(
  String passphrase,
  Uint8List salt,
  int iterations,
) => Isolate.run(() {
  final kdf = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(salt, iterations, 32));
  return kdf.process(Uint8List.fromList(utf8.encode(passphrase)));
});
