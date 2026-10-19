import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../errors.dart';

/// The SCRAM variants MongoDB supports.
enum ScramMechanism {
  sha1('SCRAM-SHA-1'),
  sha256('SCRAM-SHA-256');

  const ScramMechanism(this.wireName);
  final String wireName;

  crypto.Hash get hash => this == sha1 ? crypto.sha1 : crypto.sha256;
}

/// Client side of a SCRAM conversation (RFC 5802 / RFC 7677).
class ScramConversation {
  ScramConversation({
    required this.mechanism,
    required String username,
    required String password,
    String? clientNonce,
    this.saltedPasswordCache,
  }) : _username = username,
       _password = mechanism == ScramMechanism.sha1
           // MongoDB hashes SCRAM-SHA-1 passwords like MONGODB-CR did.
           ? crypto.md5
                 .convert(utf8.encode('$username:mongo:$password'))
                 .toString()
           : saslPrep(password),
       _nonce = clientNonce ?? _randomNonce();

  final ScramMechanism mechanism;
  final String _username;
  final String _password;
  final String _nonce;

  /// Caches salted passwords by salt and iteration count, since deriving
  /// them is slow and every pooled connection authenticates.
  final Map<String, Uint8List>? saltedPasswordCache;

  late String _clientFirstBare;
  late Uint8List _serverSignature;

  static String _randomNonce() {
    final r = Random.secure();
    return base64.encode(List<int>.generate(24, (_) => r.nextInt(256)));
  }

  static String _escapeName(String name) =>
      name.replaceAll('=', '=3D').replaceAll(',', '=2C');

  /// The first client message (`n,,n=user,r=nonce`).
  Uint8List clientFirst() {
    _clientFirstBare = 'n=${_escapeName(_username)},r=$_nonce';
    return utf8.encode('n,,$_clientFirstBare');
  }

  /// Answers the server's first message with the client proof.
  Uint8List clientFinal(Uint8List serverFirstBytes) {
    final serverFirst = utf8.decode(serverFirstBytes);
    final attrs = _parse(serverFirst);
    final nonce = attrs['r'];
    final salt = attrs['s'];
    final iterations = int.tryParse(attrs['i'] ?? '');
    if (nonce == null || salt == null || iterations == null) {
      throw MongoAuthError('Invalid SCRAM server message');
    }
    if (!nonce.startsWith(_nonce)) {
      throw MongoAuthError('The server returned an invalid SCRAM nonce');
    }
    if (iterations < 4096) {
      throw MongoAuthError('The server asked for too few SCRAM iterations');
    }
    final saltBytes = base64.decode(salt);
    final cacheKey = '${mechanism.wireName}:$salt:$iterations:$_password';
    final salted =
        saltedPasswordCache?[cacheKey] ??
        pbkdf2(mechanism.hash, utf8.encode(_password), saltBytes, iterations);
    saltedPasswordCache?[cacheKey] = salted;

    final clientKey = _hmac(salted, 'Client Key');
    final storedKey = mechanism.hash.convert(clientKey).bytes;
    final withoutProof = 'c=biws,r=$nonce';
    final authMessage = '$_clientFirstBare,$serverFirst,$withoutProof';
    final clientSignature = _hmacBytes(storedKey, utf8.encode(authMessage));
    final proof = Uint8List(clientKey.length);
    for (var i = 0; i < proof.length; i++) {
      proof[i] = clientKey[i] ^ clientSignature[i];
    }
    final serverKey = _hmac(salted, 'Server Key');
    _serverSignature = _hmacBytes(serverKey, utf8.encode(authMessage));
    return utf8.encode('$withoutProof,p=${base64.encode(proof)}');
  }

  /// Checks the server's final message so we know we talked to a server
  /// that knows the password.
  void verifyServerFinal(Uint8List serverFinalBytes) {
    final attrs = _parse(utf8.decode(serverFinalBytes));
    if (attrs['e'] != null) {
      throw MongoAuthError('Authentication failed: ${attrs['e']}');
    }
    final v = attrs['v'];
    if (v == null || base64.encode(_serverSignature) != v) {
      throw MongoAuthError('The server signature did not verify');
    }
  }

  Uint8List _hmac(List<int> key, String text) =>
      _hmacBytes(key, utf8.encode(text));

  Uint8List _hmacBytes(List<int> key, List<int> data) =>
      Uint8List.fromList(crypto.Hmac(mechanism.hash, key).convert(data).bytes);

  static Map<String, String> _parse(String message) {
    final out = <String, String>{};
    for (final part in message.split(',')) {
      final eq = part.indexOf('=');
      if (eq == 1) out[part.substring(0, 1)] = part.substring(2);
    }
    return out;
  }
}

/// PBKDF2 with an HMAC of [hash] (RFC 8018), producing one hash-sized block.
Uint8List pbkdf2(
  crypto.Hash hash,
  List<int> password,
  List<int> salt,
  int iterations,
) {
  final hmac = crypto.Hmac(hash, password);
  final block = Uint8List(salt.length + 4)
    ..setRange(0, salt.length, salt)
    ..[salt.length + 3] = 1;
  var u = hmac.convert(block).bytes;
  final out = Uint8List.fromList(u);
  for (var i = 1; i < iterations; i++) {
    u = hmac.convert(u).bytes;
    for (var j = 0; j < out.length; j++) {
      out[j] ^= u[j];
    }
  }
  return out;
}

/// A practical subset of SASLprep (RFC 4013): maps non-ASCII spaces to a
/// space, removes characters mapped to nothing and rejects prohibited
/// control characters. ASCII passwords pass through unchanged. Unicode
/// normalisation (NFKC) is not applied, so passwords that rely on it may
/// need to be entered in normalised form.
String saslPrep(String input) {
  final sb = StringBuffer();
  for (final rune in input.runes) {
    if (const {
      0x00AD,
      0x034F,
      0x1806,
      0x180B,
      0x180C,
      0x180D,
      0x200B,
      0x200C,
      0x200D,
      0x2060,
      0xFE00,
      0xFE0F,
      0xFEFF,
    }.contains(rune)) {
      continue;
    }
    if (rune == 0x00A0 ||
        rune == 0x1680 ||
        (rune >= 0x2000 && rune <= 0x200A) ||
        rune == 0x202F ||
        rune == 0x205F ||
        rune == 0x3000) {
      sb.write(' ');
      continue;
    }
    if (rune < 0x20 || rune == 0x7F || (rune >= 0x80 && rune <= 0x9F)) {
      throw MongoAuthError('The password contains a prohibited character');
    }
    sb.writeCharCode(rune);
  }
  return sb.toString();
}
