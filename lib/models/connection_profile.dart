import 'dart:math';

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
      );
}
