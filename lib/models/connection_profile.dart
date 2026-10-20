import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:mongo_wire/mongo_wire.dart';

enum TunnelKind { ssh, socks5 }

/// How to reach the server: through an SSH server or a SOCKS5 proxy.
class TunnelSettings {
  const TunnelSettings({
    required this.kind,
    required this.host,
    required this.port,
    this.username = '',
    this.password = '',
    this.privateKeyPem = '',
    this.passphrase = '',
    this.hostKey = '',
  });

  final TunnelKind kind;
  final String host;
  final int port;
  final String username;

  /// SSH or proxy password.
  final String password;

  /// SSH private key (OpenSSH or PEM) and its passphrase.
  final String privateKeyPem;
  final String passphrase;

  /// The SSH host key fingerprint seen on first connect (`SHA256:…`).
  final String hostKey;

  String get display =>
      '${kind == TunnelKind.ssh ? 'SSH' : 'SOCKS5'} '
      '${username.isEmpty ? '' : '$username@'}$host:$port';

  TunnelSettings copyWith({String? hostKey}) => TunnelSettings(
    kind: kind,
    host: host,
    port: port,
    username: username,
    password: password,
    privateKeyPem: privateKeyPem,
    passphrase: passphrase,
    hostKey: hostKey ?? this.hostKey,
  );

  Map<String, dynamic> toJson({bool secrets = true}) => {
    'kind': kind.name,
    'host': host,
    'port': port,
    if (username.isNotEmpty) 'username': username,
    if (secrets && password.isNotEmpty) 'password': password,
    if (secrets && privateKeyPem.isNotEmpty) 'privateKeyPem': privateKeyPem,
    if (secrets && passphrase.isNotEmpty) 'passphrase': passphrase,
    if (hostKey.isNotEmpty) 'hostKey': hostKey,
  };

  static TunnelSettings? fromJson(Object? j) {
    if (j is! Map) return null;
    final kind = TunnelKind.values
        .where((k) => k.name == j['kind'])
        .firstOrNull;
    if (kind == null || j['host'] is! String) return null;
    return TunnelSettings(
      kind: kind,
      host: j['host'] as String,
      port:
          (j['port'] as num?)?.toInt() ?? (kind == TunnelKind.ssh ? 22 : 1080),
      username: j['username'] as String? ?? '',
      password: j['password'] as String? ?? '',
      privateKeyPem: j['privateKeyPem'] as String? ?? '',
      passphrase: j['passphrase'] as String? ?? '',
      hostKey: j['hostKey'] as String? ?? '',
    );
  }
}

/// Client-side field level encryption: where the data keys are and the
/// master keys that unlock them.
class EncryptionSettings {
  const EncryptionSettings({
    this.keyVault = 'encryption.__keyVault',
    this.localKey = '',
    this.awsAccessKeyId = '',
    this.awsSecretAccessKey = '',
    this.awsSessionToken = '',
  });

  /// `database.collection` of the key vault.
  final String keyVault;

  /// The 96-byte local master key, base64.
  final String localKey;
  final String awsAccessKeyId;
  final String awsSecretAccessKey;
  final String awsSessionToken;

  Namespace get keyVaultNamespace {
    final dot = keyVault.indexOf('.');
    return dot <= 0
        ? const Namespace('encryption', '__keyVault')
        : Namespace(keyVault.substring(0, dot), keyVault.substring(dot + 1));
  }

  /// Why the settings can't be used, or null.
  String? get error {
    if (!RegExp(r'^[^.]+\..+$').hasMatch(keyVault)) {
      return 'The key vault is database.collection, e.g. encryption.__keyVault';
    }
    if (localKey.isEmpty && awsAccessKeyId.isEmpty) {
      return 'Add a local master key or AWS credentials';
    }
    if (localKey.isNotEmpty) {
      try {
        if (base64.decode(localKey.trim()).length != 96) {
          return 'The local master key must be 96 bytes (128 base64 characters)';
        }
      } on FormatException {
        return 'The local master key is not valid base64';
      }
    }
    if (awsAccessKeyId.isNotEmpty && awsSecretAccessKey.isEmpty) {
      return 'Add the AWS secret access key';
    }
    return null;
  }

  KmsProviders get kmsProviders => KmsProviders(
    localKey: localKey.isEmpty
        ? null
        : Uint8List.fromList(base64.decode(localKey.trim())),
    aws: awsAccessKeyId.isEmpty
        ? null
        : AwsCredentials(
            awsAccessKeyId,
            awsSecretAccessKey,
            awsSessionToken.isEmpty ? null : awsSessionToken,
          ),
  );

  Map<String, dynamic> toJson({bool secrets = true}) => {
    'keyVault': keyVault,
    if (secrets && localKey.isNotEmpty) 'localKey': localKey,
    if (awsAccessKeyId.isNotEmpty) 'awsAccessKeyId': awsAccessKeyId,
    if (secrets && awsSecretAccessKey.isNotEmpty)
      'awsSecretAccessKey': awsSecretAccessKey,
    if (secrets && awsSessionToken.isNotEmpty)
      'awsSessionToken': awsSessionToken,
  };

  static EncryptionSettings? fromJson(Object? j) => j is! Map
      ? null
      : EncryptionSettings(
          keyVault: j['keyVault'] as String? ?? 'encryption.__keyVault',
          localKey: j['localKey'] as String? ?? '',
          awsAccessKeyId: j['awsAccessKeyId'] as String? ?? '',
          awsSecretAccessKey: j['awsSecretAccessKey'] as String? ?? '',
          awsSessionToken: j['awsSessionToken'] as String? ?? '',
        );
}

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
    this.favorite = false,
    this.group = '',
    this.tunnel,
    this.clientCertificatePem,
    this.clientKeyPassword,
    this.encryption,
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

  /// Starred: listed first.
  final bool favorite;

  /// A folder name on the connections screen; empty for none.
  final String group;

  /// SSH tunnel or SOCKS5 proxy, if any.
  final TunnelSettings? tunnel;

  /// Client certificate and private key (PEM) for X.509 sign-in.
  final String? clientCertificatePem;
  final String? clientKeyPassword;

  /// Client-side field level encryption, if set up.
  final EncryptionSettings? encryption;

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
    clientCertificatePem: clientCertificatePem,
    clientKeyPassword: clientKeyPassword,
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
    bool? favorite,
    String? group,
    TunnelSettings? tunnel,
    bool clearTunnel = false,
  }) => ConnectionProfile(
    id: id ?? this.id,
    name: name ?? this.name,
    uri: uri ?? this.uri,
    allowInvalidCertificates:
        allowInvalidCertificates ?? this.allowInvalidCertificates,
    caCertificatePem: caCertificatePem ?? this.caCertificatePem,
    colorIndex: colorIndex ?? this.colorIndex,
    lastUsed: lastUsed ?? this.lastUsed,
    favorite: favorite ?? this.favorite,
    group: group ?? this.group,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'uri': uri,
    'allowInvalidCertificates': allowInvalidCertificates,
    if (caCertificatePem != null) 'caCertificatePem': caCertificatePem,
    'colorIndex': colorIndex,
    if (lastUsed != null) 'lastUsed': lastUsed!.toIso8601String(),
    if (favorite) 'favorite': true,
    if (group.isNotEmpty) 'group': group,
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
        favorite: j['favorite'] == true,
        group: (j['group'] as String?) ?? '',
        tunnel: TunnelSettings.fromJson(j['tunnel']),
        clientCertificatePem: j['clientCertificatePem'] as String?,
        clientKeyPassword: j['clientKeyPassword'] as String?,
        encryption: EncryptionSettings.fromJson(j['encryption']),
      );
}
