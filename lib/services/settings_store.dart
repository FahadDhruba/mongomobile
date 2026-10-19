import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/app_settings.dart';

/// Keeps settings next to the saved connections in secure storage. This
/// avoids shared_preferences, whose Android implementation goes through
/// package:jni and failed in release builds, leaving the app on its splash
/// screen.
class SettingsStore {
  SettingsStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'settings.v1';
  final FlutterSecureStorage _storage;

  /// Never throws: unreadable or missing settings give the defaults.
  Future<AppSettings> load() async {
    try {
      final raw = await _storage
          .read(key: _key)
          .timeout(const Duration(seconds: 3));
      if (raw == null || raw.isEmpty) return const AppSettings();
      return AppSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return const AppSettings();
    }
  }

  Future<void> save(AppSettings settings) =>
      _storage.write(key: _key, value: jsonEncode(settings.toJson()));
}
