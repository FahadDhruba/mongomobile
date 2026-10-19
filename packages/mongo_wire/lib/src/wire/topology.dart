import 'dart:async';

import '../errors.dart';
import 'connection.dart';
import 'connection_string.dart';
import 'handshake.dart';
import 'pool.dart';
import 'srv.dart';

/// The server picked for a connection string and the pool for it.
final class SelectedServer {
  SelectedServer(this.pool, this.description, this.members);

  final ConnectionPool pool;
  final ServerDescription description;

  /// Every server that answered during discovery.
  final List<ServerDescription> members;
}

/// Finds the server to talk to: resolves `mongodb+srv` names, says `hello`
/// to the seeds and follows them to the primary.
///
/// With `directConnection=true` the single host is used as is. Otherwise a
/// writable primary or a mongos is required, unless the read preference
/// allows secondaries, in which case a secondary is used when no primary
/// answers.
Future<SelectedServer> selectServer(
  ConnectionString cs, {
  required TlsOptions Function(ConnectionString cs) tlsFor,
  required HandshakeOptions handshakeOptions,
  required DnsResolver dns,
  int poolSize = 4,
}) {
  return _select(cs, tlsFor, handshakeOptions, dns, poolSize).timeout(
    cs.serverSelectionTimeout,
    onTimeout: () {
      throw MongoTimeoutError(
        'No server was selected within '
        '${cs.serverSelectionTimeout.inSeconds}s. Check the host, port, '
        'network access list and TLS settings.',
      );
    },
  );
}

Future<SelectedServer> _select(
  ConnectionString original,
  TlsOptions Function(ConnectionString cs) tlsFor,
  HandshakeOptions handshakeOptions,
  DnsResolver dns,
  int poolSize,
) async {
  var cs = original;
  if (cs.isSrv) {
    final seeds = await resolveSeedlist(cs.hosts.single.host, dns);
    cs = cs.withSeedlist(seeds.hosts, seeds.options);
  }
  final tls = tlsFor(cs);

  ConnectionPool poolFor(HostAddress a) => ConnectionPool(
    address: a,
    tls: tls,
    handshakeOptions: handshakeOptions,
    maxSize: poolSize,
    connectTimeout: cs.connectTimeout,
  );

  Future<SelectedServer> use(
    ServerDescription d,
    List<ServerDescription> seen,
  ) async {
    final pool = poolFor(d.address);
    final authed = await pool.prime();
    return SelectedServer(pool, authed, seen);
  }

  if (cs.directConnection) {
    final pool = poolFor(cs.hosts.single);
    final d = await pool.prime();
    return SelectedServer(pool, d, [d]);
  }

  final probeOptions = HandshakeOptions(appName: handshakeOptions.appName);
  final seen = <HostAddress, ServerDescription>{};
  final errors = <HostAddress, Object>{};

  Future<void> probe(Iterable<HostAddress> hosts) async {
    await Future.wait(
      hosts.where((h) => !seen.containsKey(h) && !errors.containsKey(h)).map((
        h,
      ) async {
        try {
          final conn = await WireConnection.open(
            h,
            tls: tls,
            timeout: cs.connectTimeout,
          );
          try {
            seen[h] = await handshake(
              conn,
              probeOptions,
              timeout: cs.connectTimeout,
            );
          } finally {
            conn.close();
          }
        } on Object catch (e) {
          errors[h] = e;
        }
      }),
    );
  }

  bool matchesSet(ServerDescription d) =>
      cs.replicaSet == null || d.setName == cs.replicaSet || d.isMongos;

  ServerDescription? best(bool Function(ServerDescription) test) {
    final candidates =
        seen.values.where((d) => matchesSet(d) && test(d)).toList()
          ..sort((a, b) => a.roundTrip.compareTo(b.roundTrip));
    return candidates.isEmpty ? null : candidates.first;
  }

  await probe(cs.hosts);
  var primary = best((d) => d.isWritablePrimary || d.isMongos);
  if (primary == null) {
    // Follow what the members say about the primary and the member list.
    final hints = <HostAddress>{};
    for (final d in seen.values.where(matchesSet)) {
      if (d.primary != null) hints.add(HostAddress.parse(d.primary!));
    }
    await probe(hints);
    primary = best((d) => d.isWritablePrimary);
  }
  if (primary == null) {
    final listed = <HostAddress>{
      for (final d in seen.values.where(matchesSet))
        ...d.members.map(HostAddress.parse),
    };
    await probe(listed);
    primary = best((d) => d.isWritablePrimary);
  }
  final all = seen.values.toList();
  if (primary != null) return use(primary, all);

  if (cs.readPreference.toLowerCase() != 'primary') {
    final secondary = best((d) => d.isSecondary);
    if (secondary != null) return use(secondary, all);
  }

  if (seen.isEmpty && errors.isNotEmpty) {
    final first = errors.values.first;
    if (first is MongoException) throw first;
    throw MongoNetworkError('$first', first);
  }
  if (cs.replicaSet != null && seen.values.every((d) => !matchesSet(d))) {
    throw MongoConfigError(
      'No member of replica set "${cs.replicaSet}" was '
      'found. The servers report: '
      '${seen.values.map((d) => d.setName ?? 'no replica set').toSet().join(', ')}',
    );
  }
  final states = seen.values.map((d) => '${d.address} (${d.kind})').join(', ');
  throw MongoTimeoutError(
    'No primary is available. Reachable: $states. '
    'Add readPreference=secondaryPreferred to read from a secondary, or '
    'directConnection=true to connect to one member.',
  );
}
