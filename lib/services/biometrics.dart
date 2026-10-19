import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

/// Wraps local_auth so the rest of the app deals in plain results.
class Biometrics {
  Biometrics([LocalAuthentication? auth]) : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  /// Whether the device can authenticate the user at all (biometrics or a
  /// screen lock).
  Future<bool> isAvailable() async {
    try {
      return await _auth.isDeviceSupported();
    } on PlatformException {
      return false;
    }
  }

  /// Shows the system prompt. Returns null on success, or a message.
  Future<String?> authenticate(String reason) async {
    try {
      final ok = await _auth.authenticate(
        localizedReason: reason,
        persistAcrossBackgrounding: true,
      );
      return ok ? null : 'Authentication was cancelled';
    } on LocalAuthException catch (e) {
      return e.description ?? e.code.name;
    } on PlatformException catch (e) {
      return e.message ?? e.code;
    }
  }
}
