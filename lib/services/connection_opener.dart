import 'package:mongo_wire/mongo_wire.dart';

import '../models/connection_profile.dart';
import 'oidc_flow.dart';
import 'ssh_tunnel.dart';

/// A connected client and what it runs over.
class OpenedConnection {
  const OpenedConnection(this.client, this.tunnel, this.profile);
  final MongoClient client;
  final Tunnel? tunnel;

  /// The profile, with the SSH host key filled in on first use.
  final ConnectionProfile profile;

  Future<void> close() async {
    await client.close();
    await tunnel?.close();
  }
}

/// Opens the tunnel the profile asks for, then the client through it.
/// [oidc] signs in for MONGODB-OIDC connections.
Future<OpenedConnection> openConnection(
  MongoConnector connector,
  ConnectionProfile profile, {
  OidcBrowserFlow? oidc,
}) async {
  Tunnel? tunnel;
  var updated = profile;
  final t = profile.tunnel;
  if (t != null) {
    switch (t.kind) {
      case TunnelKind.socks5:
        tunnel = Socks5Tunnel(
          proxy: HostAddress(t.host, t.port),
          username: t.username.isEmpty ? null : t.username,
          password: t.password.isEmpty ? null : t.password,
        );
      case TunnelKind.ssh:
        final ssh = await SshTunnel.connect(
          host: t.host,
          port: t.port,
          username: t.username,
          password: t.password,
          privateKeyPem: t.privateKeyPem,
          passphrase: t.passphrase,
          expectedFingerprint: t.hostKey,
        );
        tunnel = ssh;
        if (t.hostKey.isEmpty && ssh.hostKeyFingerprint.isNotEmpty) {
          updated = profile.copyWith(
            tunnel: t.copyWith(hostKey: ssh.hostKeyFingerprint),
          );
        }
    }
  }
  final base = profile.connectOptions;
  try {
    final client = await connector.connect(
      profile.uri,
      ConnectOptions(
        caCertificatePem: base.caCertificatePem,
        allowInvalidCertificates: base.allowInvalidCertificates,
        clientCertificatePem: base.clientCertificatePem,
        clientKeyPassword: base.clientKeyPassword,
        poolSize: base.poolSize,
        tunnel: tunnel,
        oidcCallback: oidc?.signIn,
      ),
    );
    return OpenedConnection(client, tunnel, updated);
  } on Object {
    await tunnel?.close();
    rethrow;
  }
}
