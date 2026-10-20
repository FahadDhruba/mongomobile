import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

import '../errors.dart';

/// AEAD_AES_256_CBC_HMAC_SHA_512, the cipher of client-side field level
/// encryption: a 96-byte key splits into a MAC key, an encryption key and
/// (for deterministic encryption) an IV key.
class Aead {
  Aead(Uint8List key) : _key = key {
    if (key.length != 96) {
      throw MongoConfigError('Encryption keys must be 96 bytes');
    }
  }

  final Uint8List _key;

  Uint8List get _macKey => Uint8List.sublistView(_key, 0, 32);
  Uint8List get _encKey => Uint8List.sublistView(_key, 32, 64);
  Uint8List get _ivKey => Uint8List.sublistView(_key, 64, 96);

  static Uint8List _al(List<int> ad) {
    final b = ByteData(8)..setUint64(0, ad.length * 8);
    return b.buffer.asUint8List();
  }

  List<int> _tag(List<int> ad, List<int> c) => Hmac(
    sha512,
    _macKey,
  ).convert([...ad, ...c, ..._al(ad)]).bytes.sublist(0, 32);

  /// Encrypts [plain]. Deterministic encryption derives the IV from the
  /// data, so equal values give equal ciphertexts (and can be queried).
  Uint8List encrypt(
    List<int> plain,
    List<int> ad, {
    required bool deterministic,
  }) {
    final Uint8List iv;
    if (deterministic) {
      iv = Uint8List.fromList(
        Hmac(
          sha512,
          _ivKey,
        ).convert([...ad, ..._al(ad), ...plain]).bytes.sublist(0, 16),
      );
    } else {
      final r = Random.secure();
      iv = Uint8List.fromList(List.generate(16, (_) => r.nextInt(256)));
    }
    final cipher =
        PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
          ..init(
            true,
            PaddedBlockCipherParameters(
              ParametersWithIV(KeyParameter(_encKey), iv),
              null,
            ),
          );
    final s = cipher.process(Uint8List.fromList(plain));
    final c = [...iv, ...s];
    return Uint8List.fromList([...c, ..._tag(ad, c)]);
  }

  /// Checks the tag and decrypts. Throws [MongoException] when the data
  /// was changed or the key is wrong.
  Uint8List decrypt(List<int> data, List<int> ad) {
    if (data.length < 16 + 16 + 32) {
      throw MongoAuthError('The encrypted value is too short');
    }
    final c = data.sublist(0, data.length - 32);
    final tag = data.sublist(data.length - 32);
    final expected = _tag(ad, c);
    var diff = 0;
    for (var i = 0; i < 32; i++) {
      diff |= tag[i] ^ expected[i];
    }
    if (diff != 0) {
      throw MongoAuthError(
        'The encrypted value could not be verified: wrong key or changed data',
      );
    }
    final iv = Uint8List.fromList(c.sublist(0, 16));
    final cipher =
        PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
          ..init(
            false,
            PaddedBlockCipherParameters(
              ParametersWithIV(KeyParameter(_encKey), iv),
              null,
            ),
          );
    return cipher.process(Uint8List.fromList(c.sublist(16)));
  }
}
