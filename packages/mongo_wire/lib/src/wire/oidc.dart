/// What the server says about its identity provider in a MONGODB-OIDC
/// conversation.
final class OidcIdpInfo {
  const OidcIdpInfo({
    required this.issuer,
    this.clientId,
    this.requestScopes = const [],
  });

  factory OidcIdpInfo.fromReply(Map<String, dynamic> m) => OidcIdpInfo(
    issuer: '${m['issuer'] ?? ''}',
    clientId: m['clientId'] as String?,
    requestScopes: [
      for (final s in (m['requestScopes'] as List? ?? const [])) '$s',
    ],
  );

  final String issuer;
  final String? clientId;
  final List<String> requestScopes;
}

/// Signs the user in at [idp] (for example in a browser) and returns an
/// access token for the server.
typedef OidcCallback =
    Future<String> Function(OidcIdpInfo idp, {String? username});
