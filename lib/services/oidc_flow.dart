import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:mongo_wire/mongo_wire.dart';

/// Thrown when OIDC sign-in fails or is cancelled.
class OidcException implements Exception {
  OidcException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Signs in at an OpenID Connect provider with the authorization code flow
/// and PKCE, the way Compass does: the provider's page opens in the
/// browser and redirects back to a one-off server on
/// `http://localhost:27097/redirect`, Compass's registered redirect.
class OidcBrowserFlow {
  OidcBrowserFlow({
    required this.openUrl,
    this.redirectPort = 27097,
    this.timeout = const Duration(minutes: 5),
    HttpClient? http,
  }) : _http = http ?? HttpClient();

  /// Opens a URL in the browser.
  final Future<void> Function(Uri url) openUrl;
  final int redirectPort;
  final Duration timeout;
  final HttpClient _http;
  Completer<String>? _cancel;

  /// Stops a sign-in that is waiting for the browser.
  void cancel() {
    final c = _cancel;
    if (c != null && !c.isCompleted) {
      c.completeError(OidcException('Sign-in was cancelled'));
    }
  }

  static String _random(int bytes) {
    final r = Random.secure();
    return base64Url
        .encode(List.generate(bytes, (_) => r.nextInt(256)))
        .replaceAll('=', '');
  }

  Future<Map<String, dynamic>> _json(
    Uri url, {
    Map<String, String>? form,
  }) async {
    final req = form == null
        ? await _http.getUrl(url)
        : await _http.postUrl(url);
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (form != null) {
      req.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
        charset: 'utf-8',
      );
      req.write(Uri(queryParameters: form).query);
    }
    final res = await req.close().timeout(const Duration(seconds: 30));
    final body = await res.transform(utf8.decoder).join();
    Object? j;
    try {
      j = jsonDecode(body);
    } on FormatException {
      j = null;
    }
    if (res.statusCode >= 400 || j is! Map<String, dynamic>) {
      final error = j is Map ? (j['error_description'] ?? j['error']) : null;
      throw OidcException(
        'The identity provider answered ${res.statusCode}'
        '${error == null ? '' : ': $error'}',
      );
    }
    return j;
  }

  /// Gets an access token from [idp], usable as [OidcCallback].
  Future<String> signIn(OidcIdpInfo idp, {String? username}) async {
    final clientId = idp.clientId;
    if (clientId == null || clientId.isEmpty) {
      throw OidcException('The server did not give an OIDC client ID');
    }
    final issuer = idp.issuer.replaceFirst(RegExp(r'/+$'), '');
    final config = await _json(
      Uri.parse('$issuer/.well-known/openid-configuration'),
    );
    final authorize = config['authorization_endpoint'];
    final tokenUrl = config['token_endpoint'];
    if (authorize is! String || tokenUrl is! String) {
      throw OidcException(
        'The identity provider has no authorization or token endpoint',
      );
    }
    final verifier = _random(48);
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');
    final state = _random(24);
    final redirect = 'http://localhost:$redirectPort/redirect';

    final HttpServer server;
    try {
      server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        redirectPort,
      );
    } on SocketException {
      throw OidcException(
        'Port $redirectPort is in use, so the sign-in page cannot come back '
        'to the app. Close other apps using it and try again.',
      );
    }
    final code = _cancel = Completer<String>();
    server.listen((req) async {
      final q = req.uri.queryParameters;
      final ok = req.uri.path == '/redirect' && q['state'] == state;
      req.response.headers.contentType = ContentType.html;
      if (ok && q['code'] != null) {
        req.response.write(
          '<html><body style="font-family:sans-serif;padding:2em">'
          '<h2>Signed in</h2><p>You can go back to MongoMobile.</p>'
          '</body></html>',
        );
        if (!code.isCompleted) code.complete(q['code']);
      } else if (ok && q['error'] != null) {
        req.response.write('<html><body>Sign-in failed.</body></html>');
        if (!code.isCompleted) {
          code.completeError(
            OidcException(
              'Sign-in failed: ${q['error_description'] ?? q['error']}',
            ),
          );
        }
      } else {
        req.response.statusCode = HttpStatus.notFound;
      }
      await req.response.close();
    });

    try {
      final scopes = {'openid', 'offline_access', ...idp.requestScopes};
      final url = Uri.parse(authorize).replace(
        queryParameters: {
          ...Uri.parse(authorize).queryParameters,
          'response_type': 'code',
          'client_id': clientId,
          'redirect_uri': redirect,
          'scope': scopes.join(' '),
          'state': state,
          'code_challenge': challenge,
          'code_challenge_method': 'S256',
          'login_hint': ?username,
        },
      );
      await openUrl(url);
      final authCode = await code.future.timeout(
        timeout,
        onTimeout: () => throw OidcException('Sign-in timed out'),
      );
      final token = await _json(
        Uri.parse(tokenUrl),
        form: {
          'grant_type': 'authorization_code',
          'code': authCode,
          'redirect_uri': redirect,
          'client_id': clientId,
          'code_verifier': verifier,
        },
      );
      final access = token['access_token'];
      if (access is! String || access.isEmpty) {
        throw OidcException('The identity provider sent no access token');
      }
      return access;
    } finally {
      _cancel = null;
      await server.close(force: true);
    }
  }
}
