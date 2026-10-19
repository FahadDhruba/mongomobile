import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/connection_profile.dart';

/// Keeps saved connections in the Android keystore-backed secure storage.
class ConnectionStore {
  ConnectionStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'connections.v1';
  final FlutterSecureStorage _storage;

  Future<List<ConnectionProfile>> load() async {
    final raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .cast<Map<String, dynamic>>()
        .map(ConnectionProfile.fromJson)
        .toList();
  }

  Future<void> save(List<ConnectionProfile> profiles) =>
      _storage.write(
          key: _key, value: jsonEncode(profiles.map((p) => p.toJson()).toList()));
}
