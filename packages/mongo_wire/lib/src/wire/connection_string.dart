import '../errors.dart';

/// A host and port pair.
final class HostAddress {
  const HostAddress(this.host, [this.port = 27017]);

  /// Parses `host`, `host:port`, `[v6]` or `[v6]:port`.
  factory HostAddress.parse(String s) {
    final text = s.trim();
    if (text.isEmpty) throw MongoConfigError('Empty host name');
    if (text.startsWith('[')) {
      final end = text.indexOf(']');
      if (end < 0) throw MongoConfigError('Invalid IPv6 address "$s"');
      final host = text.substring(1, end);
      final rest = text.substring(end + 1);
      if (rest.isEmpty) return HostAddress(host);
      if (!rest.startsWith(':')) throw MongoConfigError('Invalid host "$s"');
      return HostAddress(host, _port(rest.substring(1), s));
    }
    final colon = text.lastIndexOf(':');
    if (colon < 0) return HostAddress(text.toLowerCase());
    if (text.indexOf(':') != colon) {
      throw MongoConfigError('IPv6 addresses must be in brackets: "$s"');
    }
    return HostAddress(
      text.substring(0, colon).toLowerCase(),
      _port(text.substring(colon + 1), s),
    );
  }

  static int _port(String p, String whole) {
    final v = int.tryParse(p);
    if (v == null || v <= 0 || v > 65535) {
      throw MongoConfigError('Invalid port in "$whole"');
    }
    return v;
  }

  final String host;
  final int port;

  @override
  bool operator ==(Object other) =>
      other is HostAddress && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);

  @override
  String toString() => host.contains(':') ? '[$host]:$port' : '$host:$port';
}

/// A parsed `mongodb://` or `mongodb+srv://` connection string.
///
/// Option names are matched case-insensitively, as the URI specification
/// requires; [options] stores them in lower case.
final class ConnectionString {
  ConnectionString._({
    required this.isSrv,
    required this.username,
    required this.password,
    required this.hosts,
    required this.database,
    required this.options,
  });

  static const _knownBoolOptions = {
    'tls',
    'ssl',
    'tlsallowinvalidcertificates',
    'tlsallowinvalidhostnames',
    'tlsinsecure',
    'directconnection',
    'loadbalanced',
    'retrywrites',
    'retryreads',
  };

  /// Parses [uri]. Throws [MongoConfigError] with a readable message when the
  /// string is malformed.
  factory ConnectionString.parse(String uri) {
    final text = uri.trim();
    final bool isSrv;
    String rest;
    if (text.startsWith('mongodb://')) {
      isSrv = false;
      rest = text.substring('mongodb://'.length);
    } else if (text.startsWith('mongodb+srv://')) {
      isSrv = true;
      rest = text.substring('mongodb+srv://'.length);
    } else {
      throw MongoConfigError(
        'The connection string must start with mongodb:// or mongodb+srv://',
      );
    }

    String? query;
    final q = rest.indexOf('?');
    if (q >= 0) {
      query = rest.substring(q + 1);
      rest = rest.substring(0, q);
    }
    // The user info ends at the last "@" before the path; a literal "@" in a
    // password has to be percent-encoded, but be forgiving about it.
    final slashAfterAt = rest.indexOf('/', rest.lastIndexOf('@') + 1);
    String hostPart;
    String? path;
    if (slashAfterAt >= 0) {
      hostPart = rest.substring(0, slashAfterAt);
      path = rest.substring(slashAfterAt + 1);
    } else {
      hostPart = rest;
    }
    String? username;
    String? password;
    final at = hostPart.lastIndexOf('@');
    if (at >= 0) {
      final info = hostPart.substring(0, at);
      hostPart = hostPart.substring(at + 1);
      final colon = info.indexOf(':');
      try {
        if (colon >= 0) {
          username = Uri.decodeComponent(info.substring(0, colon));
          password = Uri.decodeComponent(info.substring(colon + 1));
        } else {
          username = Uri.decodeComponent(info);
        }
      } on ArgumentError {
        throw MongoConfigError(
          'The user name or password has an invalid percent-encoding',
        );
      }
      if (username.isEmpty) throw MongoConfigError('The user name is empty');
    }
    if (hostPart.isEmpty) throw MongoConfigError('No host given');
    final hosts = hostPart.split(',').map(HostAddress.parse).toList();
    if (isSrv) {
      if (hosts.length != 1) {
        throw MongoConfigError('mongodb+srv:// takes exactly one host name');
      }
      if (hostPart.contains(':') && !hostPart.startsWith('[')) {
        throw MongoConfigError('mongodb+srv:// host names cannot have a port');
      }
    }

    String? database;
    if (path != null && path.isNotEmpty) {
      database = Uri.decodeComponent(path);
      if (database.contains(RegExp(r'[/\\ ".$]'))) {
        throw MongoConfigError('Invalid database name "$database" in the path');
      }
    }

    final options = <String, String>{};
    if (query != null && query.isNotEmpty) {
      for (final pair in query.split(RegExp('[&;]'))) {
        if (pair.isEmpty) continue;
        final eq = pair.indexOf('=');
        if (eq <= 0) throw MongoConfigError('Invalid option "$pair"');
        final key = Uri.decodeComponent(pair.substring(0, eq)).toLowerCase();
        final value = Uri.decodeQueryComponent(pair.substring(eq + 1));
        if (_knownBoolOptions.contains(key) &&
            value != 'true' &&
            value != 'false') {
          throw MongoConfigError('Option "$key" must be true or false');
        }
        options[key] = value;
      }
    }
    if (options['directconnection'] == 'true' && (isSrv || hosts.length > 1)) {
      throw MongoConfigError(
        'directConnection=true needs a single mongodb:// host',
      );
    }
    return ConnectionString._(
      isSrv: isSrv,
      username: username,
      password: password,
      hosts: hosts,
      database: database,
      options: options,
    );
  }

  final bool isSrv;
  final String? username;
  final String? password;
  final List<HostAddress> hosts;

  /// The default database from the path, if any.
  final String? database;
  final Map<String, String> options;

  bool _flag(String key) => options[key] == 'true';

  /// TLS is on when asked for, and by default for SRV connection strings.
  bool get tls {
    final v = options['tls'] ?? options['ssl'];
    if (v != null) return v == 'true';
    return isSrv;
  }

  bool get tlsAllowInvalidCertificates =>
      _flag('tlsallowinvalidcertificates') ||
      _flag('tlsinsecure') ||
      _flag('tlsallowinvalidhostnames');

  bool get directConnection => _flag('directconnection');

  String? get replicaSet => options['replicaset'];

  String? get authMechanism => options['authmechanism']?.toUpperCase();

  /// Where credentials are checked: `authSource`, else the path database,
  /// else `admin`. `$external` for mechanisms that need it.
  String get authSource {
    final explicit = options['authsource'];
    if (explicit != null && explicit.isNotEmpty) return explicit;
    if (const {
      'PLAIN',
      'MONGODB-X509',
      'MONGODB-AWS',
      'MONGODB-OIDC',
      'GSSAPI',
    }.contains(authMechanism)) {
      return r'$external';
    }
    return database ?? 'admin';
  }

  String? get appName => options['appname'];

  /// `authMechanismProperties=KEY:value,KEY2:value2`.
  Map<String, String> get authMechanismProperties {
    final raw = options['authmechanismproperties'];
    if (raw == null || raw.isEmpty) return const {};
    return {
      for (final pair in raw.split(','))
        if (pair.contains(':'))
          pair.substring(0, pair.indexOf(':')).trim(): pair
              .substring(pair.indexOf(':') + 1)
              .trim(),
    };
  }

  String get readPreference => options['readpreference'] ?? 'primary';

  Duration get connectTimeout => _millis('connecttimeoutms', 10000);

  Duration get serverSelectionTimeout =>
      _millis('serverselectiontimeoutms', 20000);

  Duration? get socketTimeout {
    final ms = int.tryParse(options['sockettimeoutms'] ?? '');
    return ms == null || ms <= 0 ? null : Duration(milliseconds: ms);
  }

  Duration _millis(String key, int fallback) {
    final v = int.tryParse(options[key] ?? '');
    return Duration(milliseconds: v == null || v <= 0 ? fallback : v);
  }

  /// Returns a copy with [hosts] replaced and [extra] options added under
  /// the existing ones. Used after resolving an SRV record.
  ConnectionString withSeedlist(
    List<HostAddress> hosts,
    Map<String, String> extra,
  ) {
    final merged = <String, String>{
      for (final e in extra.entries) e.key.toLowerCase(): e.value,
      ...options,
    };
    if (!merged.containsKey('tls') && !merged.containsKey('ssl')) {
      merged['tls'] = 'true';
    }
    return ConnectionString._(
      isSrv: false,
      username: username,
      password: password,
      hosts: hosts,
      database: database,
      options: merged,
    );
  }

  /// The connection string with the password hidden.
  static String redact(String uri) => uri.replaceFirstMapped(
    RegExp(r'^(mongodb(?:\+srv)?://[^:@/]*:)([^@]*)(@)'),
    (m) => '${m[1]}****${m[3]}',
  );
}
