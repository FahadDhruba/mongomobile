import 'dart:math';

import 'package:mongo_wire/mongo_wire.dart';

/// A saved connection. Stored encrypted, since the URI holds the password.
class ConnectionProfile {
  const ConnectionProfile({
    required this.id,
    required this.name,
    required this.uri,
    this.allowInvalidCertificates = false,
    this.caCertificatePem,
    this.colorIndex = 0,
    this.lastUsed,
  });

  static String newId() {
    final r = Random.secure();
    return List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  final String id;
  final String name;
  final String uri;
  final bool allowInvalidCertificates;
  final String? caCertificatePem;

  /// Index into `connectionColors`, used for the dot next to the name.
  final int colorIndex;
  final DateTime? lastUsed;

  /// Hosts for display, without credentials.
  String get displayHost {
    try {
      final cs = ConnectionString.parse(uri);
      final hosts = cs.hosts.map((h) => cs.isSrv ? h.host : '$h').join(', ');
      return cs.isSrv ? 'srv: $hosts' : hosts;
    } on MongoException {
      return ConnectionString.redact(uri);
    }
  }

  String get displayName => name.trim().isEmpty ? displayHost : name;

  ConnectOptions get connectOptions => ConnectOptions(
        allowInvalidCertificates: allowInvalidCertificates,
        caCertificatePem: caCertificatePem,
        poolSize: 6,
      );

  ConnectionProfile copyWith({
    String? id,
    String? name,
    String? uri,
    bool? allowInvalidCertificates,
    String? caCertificatePem,
    int? colorIndex,
    DateTime? lastUsed,
  }) =>
      ConnectionProfile(
        id: id ?? this.id,
        name: name ?? this.name,
        uri: uri ?? this.uri,
        allowInvalidCertificates:
            allowInvalidCertificates ?? this.allowInvalidCertificates,
        caCertificatePem: caCertificatePem ?? this.caCertificatePem,
        colorIndex: colorIndex ?? this.colorIndex,
        lastUsed: lastUsed ?? this.lastUsed,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'uri': uri,
        'allowInvalidCertificates': allowInvalidCertificates,
        if (caCertificatePem != null) 'caCertificatePem': caCertificatePem,
        'colorIndex': colorIndex,
        if (lastUsed != null) 'lastUsed': lastUsed!.toIso8601String(),
      };

  factory ConnectionProfile.fromJson(Map<String, dynamic> j) =>
      ConnectionProfile(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '',
        uri: j['uri'] as String,
        allowInvalidCertificates: j['allowInvalidCertificates'] == true,
        caCertificatePem: j['caCertificatePem'] as String?,
        colorIndex: (j['colorIndex'] as int?) ?? 0,
        lastUsed: DateTime.tryParse((j['lastUsed'] as String?) ?? ''),
      );
}
