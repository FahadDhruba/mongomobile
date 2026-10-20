import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mongo_wire/mongo_wire.dart';
import 'package:mongomobile/services/oidc_flow.dart';

/// A tiny identity provider: discovery, an authorize endpoint that
/// redirects straight back, and a token endpoint that checks PKCE.
Future<(HttpServer, List<Map<String, String>>)> fakeIdp() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final base = 'http://127.0.0.1:${server.port}';
  final challenges = <String, String>{};
  final seen = <Map<String, String>>[];
  server.listen((req) async {
    final res = req.response;
    switch (req.uri.path) {
      case '/.well-known/openid-configuration':
        res.write(
          jsonEncode({
            'issuer': base,
            'authorization_endpoint': '$base/authorize',
            'token_endpoint': '$base/token',
          }),
        );
      case '/authorize':
        final q = req.uri.queryParameters;
        seen.add(q);
        challenges['code-1'] = q['code_challenge']!;
        res.statusCode = HttpStatus.found;
        res.headers.set(
          HttpHeaders.locationHeader,
          '${q['redirect_uri']}?code=code-1&state=${q['state']}',
        );
      case '/token':
        final form = Uri.splitQueryString(await utf8.decoder.bind(req).join());
        seen.add(form);
        final expected = base64Url
            .encode(sha256.convert(ascii.encode(form['code_verifier']!)).bytes)
            .replaceAll('=', '');
        if (challenges[form['code']] != expected) {
          res.statusCode = 400;
          res.write(jsonEncode({'error': 'invalid_grant'}));
        } else {
          res.write(
            jsonEncode({'access_token': 'jwt-123', 'token_type': 'Bearer'}),
          );
        }
      default:
        res.statusCode = 404;
    }
    await res.close();
  });
  return (server, seen);
}

void main() {
  test('authorization code with PKCE through the loopback redirect', () async {
    final (idp, seen) = await fakeIdp();
    final browser = HttpClient();
    final flow = OidcBrowserFlow(
      redirectPort: 0 + 27197,
      // The "browser" follows the redirect back to the app.
      openUrl: (url) async {
        final req = await browser.getUrl(url);
        final res = await req.close();
        await res.drain<void>();
      },
    );
    final token = await flow.signIn(
      OidcIdpInfo(
        issuer: 'http://127.0.0.1:${idp.port}/',
        clientId: 'client-1',
        requestScopes: const ['api://mongo/read'],
      ),
      username: 'ada@example.com',
    );
    expect(token, 'jwt-123');
    final authorize = seen.first;
    expect(authorize['client_id'], 'client-1');
    expect(authorize['code_challenge_method'], 'S256');
    expect(authorize['scope'], 'openid offline_access api://mongo/read');
    expect(authorize['login_hint'], 'ada@example.com');
    expect(authorize['redirect_uri'], 'http://localhost:27197/redirect');
    expect(seen.last['grant_type'], 'authorization_code');
    await idp.close(force: true);
  });

  test('reports a missing client id and cancellation', () async {
    final flow = OidcBrowserFlow(openUrl: (_) async {}, redirectPort: 27198);
    await expectLater(
      flow.signIn(const OidcIdpInfo(issuer: 'http://127.0.0.1:1')),
      throwsA(isA<OidcException>()),
    );
    final (idp, _) = await fakeIdp();
    final waiting = OidcBrowserFlow(openUrl: (_) async {}, redirectPort: 27198);
    final f = waiting.signIn(
      OidcIdpInfo(issuer: 'http://127.0.0.1:${idp.port}', clientId: 'c'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    waiting.cancel();
    await expectLater(f, throwsA(isA<OidcException>()));
    await idp.close(force: true);
  });
}
