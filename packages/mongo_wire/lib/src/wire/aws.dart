import 'dart:convert';

import 'package:crypto/crypto.dart';

/// AWS credentials for MONGODB-AWS sign-in.
final class AwsCredentials {
  const AwsCredentials(
    this.accessKeyId,
    this.secretAccessKey, [
    this.sessionToken,
  ]);
  final String accessKeyId;
  final String secretAccessKey;
  final String? sessionToken;
}

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

List<int> _hmac(List<int> key, String data) =>
    Hmac(sha256, key).convert(utf8.encode(data)).bytes;

String _two(int n) => n.toString().padLeft(2, '0');

/// `20150830T123600Z`.
String amzDate(DateTime t) {
  final u = t.toUtc();
  return '${u.year}${_two(u.month)}${_two(u.day)}T'
      '${_two(u.hour)}${_two(u.minute)}${_two(u.second)}Z';
}

/// The SigV4 signing key for [date] (`yyyyMMdd`), [region] and [service].
List<int> signingKey(
  String secret,
  String date,
  String region,
  String service,
) {
  final kDate = _hmac(utf8.encode('AWS4$secret'), date);
  final kRegion = _hmac(kDate, region);
  final kService = _hmac(kRegion, service);
  return _hmac(kService, 'aws4_request');
}

/// Signs a request with AWS Signature Version 4 and returns the
/// `Authorization` header. [headers] must include `host` and
/// `x-amz-date`; every header given is signed.
String sigV4Authorization({
  required String method,
  required String path,
  String query = '',
  required Map<String, String> headers,
  required String body,
  required String region,
  required String service,
  required AwsCredentials credentials,
}) {
  final lower = {
    for (final e in headers.entries)
      e.key.toLowerCase(): e.value.trim().replaceAll(RegExp(r'\s+'), ' '),
  };
  final names = lower.keys.toList()..sort();
  final canonicalHeaders = names.map((n) => '$n:${lower[n]}\n').join();
  final signedHeaders = names.join(';');
  final canonicalRequest = [
    method,
    path,
    query,
    canonicalHeaders,
    signedHeaders,
    _hex(sha256.convert(utf8.encode(body)).bytes),
  ].join('\n');
  final date = lower['x-amz-date']!;
  final scope = '${date.substring(0, 8)}/$region/$service/aws4_request';
  final toSign = [
    'AWS4-HMAC-SHA256',
    date,
    scope,
    _hex(sha256.convert(utf8.encode(canonicalRequest)).bytes),
  ].join('\n');
  final key = signingKey(
    credentials.secretAccessKey,
    date.substring(0, 8),
    region,
    service,
  );
  final signature = _hex(_hmac(key, toSign));
  return 'AWS4-HMAC-SHA256 Credential=${credentials.accessKeyId}/$scope, '
      'SignedHeaders=$signedHeaders, Signature=$signature';
}

/// The region for an STS host, as the MONGODB-AWS spec defines it:
/// `sts.amazonaws.com` is us-east-1, otherwise the second label.
String stsRegion(String host) {
  if (host == 'sts.amazonaws.com') return 'us-east-1';
  final parts = host.split('.');
  return parts.length > 1 ? parts[1] : 'us-east-1';
}

/// Whether the server's STS host is acceptable (spec: non-empty labels,
/// at most 255 characters).
bool validStsHost(String host) =>
    host.isNotEmpty &&
    host.length <= 255 &&
    host.split('.').every((label) => label.isNotEmpty);

const stsBody = 'Action=GetCallerIdentity&Version=2011-06-15';

/// The signed `GetCallerIdentity` request the client sends in its second
/// SASL message: `{a: Authorization, d: X-Amz-Date, t?: token}`.
Map<String, Object> awsClientFinal({
  required AwsCredentials credentials,
  required String host,
  required List<int> serverNonce,
  required DateTime now,
}) {
  final date = amzDate(now);
  final headers = {
    'Content-Type': 'application/x-www-form-urlencoded',
    'Content-Length': '${stsBody.length}',
    'Host': host,
    'X-Amz-Date': date,
    'X-MongoDB-Server-Nonce': base64.encode(serverNonce),
    'X-MongoDB-GS2-CB-Flag': 'n',
    if (credentials.sessionToken != null)
      'X-Amz-Security-Token': credentials.sessionToken!,
  };
  return {
    'a': sigV4Authorization(
      method: 'POST',
      path: '/',
      headers: headers,
      body: stsBody,
      region: stsRegion(host),
      service: 'sts',
      credentials: credentials,
    ),
    'd': date,
    if (credentials.sessionToken != null) 't': credentials.sessionToken!,
  };
}
