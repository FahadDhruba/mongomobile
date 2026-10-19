import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../errors.dart';
import 'connection_string.dart';

/// An SRV record answer.
final class SrvRecord {
  const SrvRecord(this.priority, this.weight, this.port, this.target);
  final int priority;
  final int weight;
  final int port;
  final String target;
}

/// Resolves the DNS records needed for `mongodb+srv://` connection strings.
abstract interface class DnsResolver {
  Future<List<SrvRecord>> srv(String name);

  /// TXT records, each joined from its character strings.
  Future<List<String>> txt(String name);
}

/// Resolves records with DNS-over-HTTPS JSON APIs, which works on Android
/// where `dart:io` has no SRV lookup. Tries each endpoint in turn.
class DohResolver implements DnsResolver {
  DohResolver({
    this.endpoints = const [
      'https://dns.google/resolve',
      'https://cloudflare-dns.com/dns-query',
    ],
    this.timeout = const Duration(seconds: 8),
    HttpClient? httpClient,
  }) : _client = httpClient ?? HttpClient();

  final List<String> endpoints;
  final Duration timeout;
  final HttpClient _client;

  static const _typeSrv = 33;
  static const _typeTxt = 16;

  Future<List<String>> _query(String name, int type) async {
    Object? lastError;
    for (final endpoint in endpoints) {
      try {
        final uri = Uri.parse(
          endpoint,
        ).replace(queryParameters: {'name': name, 'type': '$type'});
        final req = await _client.getUrl(uri).timeout(timeout);
        req.headers.set(HttpHeaders.acceptHeader, 'application/dns-json');
        final res = await req.close().timeout(timeout);
        final body = await res.transform(utf8.decoder).join().timeout(timeout);
        if (res.statusCode != 200) {
          lastError = 'HTTP ${res.statusCode} from ${uri.host}';
          continue;
        }
        final json = jsonDecode(body) as Map<String, dynamic>;
        final status = json['Status'];
        if (status == 3) return const []; // NXDOMAIN
        if (status != 0) {
          lastError = 'DNS status $status from ${uri.host}';
          continue;
        }
        final answers = (json['Answer'] as List?) ?? const [];
        return [
          for (final a in answers.cast<Map<String, dynamic>>())
            if (a['type'] == type) a['data'] as String,
        ];
      } on Object catch (e) {
        lastError = e;
      }
    }
    throw MongoDnsError('DNS lookup for $name failed: $lastError');
  }

  @override
  Future<List<SrvRecord>> srv(String name) async {
    final data = await _query(name, _typeSrv);
    return [for (final d in data) ?_parseSrv(d)];
  }

  static SrvRecord? _parseSrv(String data) {
    final parts = data.trim().split(RegExp(r'\s+'));
    if (parts.length != 4) return null;
    final p = int.tryParse(parts[0]);
    final w = int.tryParse(parts[1]);
    final port = int.tryParse(parts[2]);
    if (p == null || w == null || port == null) return null;
    return SrvRecord(p, w, port, parts[3]);
  }

  @override
  Future<List<String>> txt(String name) async {
    final data = await _query(name, _typeTxt);
    return data.map(_joinTxt).toList();
  }

  /// DoH answers quote each character string: `"a=b" "&c=d"`.
  static String _joinTxt(String data) {
    final matches = RegExp(r'"((?:[^"\\]|\\.)*)"').allMatches(data);
    if (matches.isEmpty) return data;
    return matches.map((m) => m.group(1)!.replaceAll(r'\"', '"')).join();
  }
}

/// The hosts and options a `mongodb+srv://` name resolves to.
final class Seedlist {
  const Seedlist(this.hosts, this.options);
  final List<HostAddress> hosts;
  final Map<String, String> options;
}

/// Implements the Initial DNS Seedlist Discovery specification.
Future<Seedlist> resolveSeedlist(String host, DnsResolver dns) async {
  final name = host.toLowerCase();
  final labels = name.split('.');
  final records = await dns.srv('_mongodb._tcp.$name');
  if (records.isEmpty) {
    throw MongoDnsError(
      'No SRV record found for _mongodb._tcp.$name. '
      'Check the host name, or use a mongodb:// connection string.',
    );
  }
  // Targets must share the parent domain of the SRV name. Names with fewer
  // than three labels must match the full name instead.
  final domain = labels.length >= 3 ? labels.sublist(1).join('.') : name;
  final hosts = <HostAddress>[];
  for (final r in records) {
    var target = r.target.toLowerCase();
    if (target.endsWith('.')) target = target.substring(0, target.length - 1);
    if (target == domain || !target.endsWith('.$domain')) {
      throw MongoDnsError(
        'SRV record target "$target" is not part of the domain "$domain"',
      );
    }
    hosts.add(HostAddress(target, r.port));
  }

  final options = <String, String>{};
  final txt = await dns.txt(name);
  if (txt.length > 1) {
    throw MongoDnsError('More than one TXT record found for $name');
  }
  if (txt.isNotEmpty) {
    for (final pair in txt.single.split('&')) {
      if (pair.isEmpty) continue;
      final eq = pair.indexOf('=');
      if (eq <= 0) throw MongoDnsError('Invalid TXT record option "$pair"');
      final key = pair.substring(0, eq).toLowerCase();
      if (!const {'authsource', 'replicaset', 'loadbalanced'}.contains(key)) {
        throw MongoDnsError('TXT record option "$key" is not allowed');
      }
      options[key] = Uri.decodeQueryComponent(pair.substring(eq + 1));
    }
  }
  return Seedlist(hosts, options);
}
