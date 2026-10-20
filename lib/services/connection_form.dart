import 'package:mongo_wire/mongo_wire.dart';

/// How the form signs in.
enum AuthMethod {
  none('None'),
  password('Username / Password'),
  ldap('LDAP');

  const AuthMethod(this.label);
  final String label;
}

/// `tls=` in the URI: unset (on for SRV, off otherwise), on or off.
enum TlsMode { auto, on, off }

/// The connection string as form fields, like Compass's "Advanced
/// Connection Options". Options the form has no field for are kept in
/// [otherOptions] so a round trip never loses them.
class ConnectionForm {
  ConnectionForm({
    this.srv = false,
    List<String>? hosts,
    this.directConnection = false,
    this.auth = AuthMethod.none,
    this.mechanism = '',
    this.username = '',
    this.password = '',
    this.authSource = '',
    this.tls = TlsMode.auto,
    this.allowInvalidCertificates = false,
    this.allowInvalidHostnames = false,
    this.replicaSet = '',
    this.readPreference = '',
    this.appName = '',
    this.database = '',
    this.connectTimeoutMs = '',
    this.serverSelectionTimeoutMs = '',
    Map<String, String>? otherOptions,
  }) : hosts = hosts ?? ['localhost:27017'],
       otherOptions = otherOptions ?? {};

  bool srv;
  List<String> hosts;
  bool directConnection;
  AuthMethod auth;

  /// `authMechanism` for [AuthMethod.password]: empty lets the server pick.
  String mechanism;
  String username;
  String password;
  String authSource;
  TlsMode tls;
  bool allowInvalidCertificates;
  bool allowInvalidHostnames;
  String replicaSet;
  String readPreference;
  String appName;
  String database;
  String connectTimeoutMs;
  String serverSelectionTimeoutMs;

  /// Lower-case option name → value, for options without a field.
  Map<String, String> otherOptions;

  static const mechanisms = ['', 'SCRAM-SHA-256', 'SCRAM-SHA-1'];
  static const readPreferences = [
    '',
    'primary',
    'primaryPreferred',
    'secondary',
    'secondaryPreferred',
    'nearest',
  ];

  /// Option names the form edits, lower case (as [ConnectionString] stores
  /// them) → the spelling written back.
  static const _fields = {
    'directconnection': 'directConnection',
    'authmechanism': 'authMechanism',
    'authsource': 'authSource',
    'tls': 'tls',
    'ssl': 'ssl',
    'tlsallowinvalidcertificates': 'tlsAllowInvalidCertificates',
    'tlsallowinvalidhostnames': 'tlsAllowInvalidHostnames',
    'replicaset': 'replicaSet',
    'readpreference': 'readPreference',
    'appname': 'appName',
    'connecttimeoutms': 'connectTimeoutMS',
    'serverselectiontimeoutms': 'serverSelectionTimeoutMS',
  };

  /// Spellings for common options the form keeps in [otherOptions].
  static const _knownSpelling = {
    'retrywrites': 'retryWrites',
    'retryreads': 'retryReads',
    'w': 'w',
    'wtimeoutms': 'wtimeoutMS',
    'journal': 'journal',
    'maxpoolsize': 'maxPoolSize',
    'minpoolsize': 'minPoolSize',
    'maxidletimems': 'maxIdleTimeMS',
    'sockettimeoutms': 'socketTimeoutMS',
    'heartbeatfrequencyms': 'heartbeatFrequencyMS',
    'readconcernlevel': 'readConcernLevel',
    'readpreferencetags': 'readPreferenceTags',
    'maxstalenessseconds': 'maxStalenessSeconds',
    'compressors': 'compressors',
    'zlibcompressionlevel': 'zlibCompressionLevel',
    'loadbalanced': 'loadBalanced',
    'authmechanismproperties': 'authMechanismProperties',
    'tlsinsecure': 'tlsInsecure',
    'tlscafile': 'tlsCAFile',
    'tlscertificatekeyfile': 'tlsCertificateKeyFile',
    'srvmaxhosts': 'srvMaxHosts',
    'srvservicename': 'srvServiceName',
  };

  /// Reads [uri]; throws [MongoConfigError] when it can't be parsed.
  factory ConnectionForm.fromUri(String uri) {
    final cs = ConnectionString.parse(uri);
    final o = Map.of(cs.options);
    String take(String k) => o.remove(k) ?? '';
    final mech = take('authmechanism').toUpperCase();
    final tlsText = o.remove('tls') ?? o.remove('ssl');
    final form = ConnectionForm(
      srv: cs.isSrv,
      hosts: [for (final h in cs.hosts) cs.isSrv ? h.host : '$h'],
      directConnection: take('directconnection') == 'true',
      auth: mech == 'PLAIN'
          ? AuthMethod.ldap
          : cs.username != null
          ? AuthMethod.password
          : AuthMethod.none,
      mechanism: mechanisms.contains(mech) ? mech : '',
      username: cs.username ?? '',
      password: cs.password ?? '',
      authSource: take('authsource'),
      tls: switch (tlsText) {
        'true' => TlsMode.on,
        'false' => TlsMode.off,
        _ => TlsMode.auto,
      },
      allowInvalidCertificates: take('tlsallowinvalidcertificates') == 'true',
      allowInvalidHostnames: take('tlsallowinvalidhostnames') == 'true',
      replicaSet: take('replicaset'),
      readPreference: _canonicalReadPreference(take('readpreference')),
      appName: take('appname'),
      database: cs.database ?? '',
      connectTimeoutMs: take('connecttimeoutms'),
      serverSelectionTimeoutMs: take('serverselectiontimeoutms'),
      otherOptions: o,
    );
    // A mechanism the form has no choice for (e.g. MONGODB-X509) stays an
    // option.
    if (mech.isNotEmpty && mech != 'PLAIN' && !mechanisms.contains(mech)) {
      form.otherOptions['authmechanism'] = mech;
    }
    return form;
  }

  static String _canonicalReadPreference(String v) => readPreferences
      .firstWhere((p) => p.toLowerCase() == v.toLowerCase(), orElse: () => v);

  /// The first problem that stops a connection string being built.
  String? get error {
    final h = hosts.map((x) => x.trim()).where((x) => x.isNotEmpty).toList();
    if (h.isEmpty) return 'Add a host';
    if (srv && h.length > 1) return 'mongodb+srv takes exactly one host name';
    if (srv && h.single.contains(':')) {
      return 'mongodb+srv host names have no port';
    }
    if (directConnection && (srv || h.length > 1)) {
      return 'Direct connection needs a single mongodb:// host';
    }
    if (auth != AuthMethod.none && username.trim().isEmpty) {
      return 'Enter a username';
    }
    for (final (label, v) in [
      ('Connect timeout', connectTimeoutMs),
      ('Server selection timeout', serverSelectionTimeoutMs),
    ]) {
      if (v.trim().isNotEmpty && (int.tryParse(v.trim()) ?? -1) < 0) {
        return '$label must be a number of milliseconds';
      }
    }
    return null;
  }

  /// The connection string for the fields.
  String toUri() {
    final b = StringBuffer(srv ? 'mongodb+srv://' : 'mongodb://');
    if (auth != AuthMethod.none && username.trim().isNotEmpty) {
      b.write(Uri.encodeComponent(username.trim()));
      if (password.isNotEmpty) b.write(':${Uri.encodeComponent(password)}');
      b.write('@');
    }
    b.write(hosts.map((x) => x.trim()).where((x) => x.isNotEmpty).join(','));
    b.write('/');
    if (database.trim().isNotEmpty) {
      b.write(Uri.encodeComponent(database.trim()));
    }
    final options = <String, String>{
      if (directConnection) 'directConnection': 'true',
      if (auth == AuthMethod.ldap) 'authMechanism': 'PLAIN',
      if (auth == AuthMethod.password && mechanism.isNotEmpty)
        'authMechanism': mechanism,
      if (auth != AuthMethod.none && authSource.trim().isNotEmpty)
        'authSource': authSource.trim(),
      if (tls == TlsMode.on) 'tls': 'true',
      if (tls == TlsMode.off) 'tls': 'false',
      if (allowInvalidCertificates) 'tlsAllowInvalidCertificates': 'true',
      if (allowInvalidHostnames) 'tlsAllowInvalidHostnames': 'true',
      if (replicaSet.trim().isNotEmpty) 'replicaSet': replicaSet.trim(),
      if (readPreference.isNotEmpty) 'readPreference': readPreference,
      if (appName.trim().isNotEmpty) 'appName': appName.trim(),
      if (connectTimeoutMs.trim().isNotEmpty)
        'connectTimeoutMS': connectTimeoutMs.trim(),
      if (serverSelectionTimeoutMs.trim().isNotEmpty)
        'serverSelectionTimeoutMS': serverSelectionTimeoutMs.trim(),
      for (final MapEntry(:key, :value) in otherOptions.entries)
        if (!_fields.containsKey(key) || key == 'authmechanism')
          _knownSpelling[key] ?? key: value,
    };
    if (options.isNotEmpty) {
      b.write('?');
      b.write(
        options.entries
            .map(
              (e) =>
                  '${e.key}=${Uri.encodeQueryComponent(e.value).replaceAll('+', '%20')}',
            )
            .join('&'),
      );
    }
    return b.toString();
  }
}
