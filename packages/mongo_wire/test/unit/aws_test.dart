import 'dart:convert';

import 'package:mongo_wire/mongo_wire.dart';
import 'package:test/test.dart';

String hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  const creds = AwsCredentials(
    'AKIDEXAMPLE',
    'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
  );

  test('derives the signing key from the AWS documentation example', () {
    expect(
      hex(
        signingKey(
          'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
          '20120215',
          'us-east-1',
          'iam',
        ),
      ),
      'f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d',
    );
  });

  // Expected values computed with botocore's SigV4Auth for the same
  // request.
  test('signs GetCallerIdentity like botocore', () {
    final at = DateTime.utc(2026, 10, 20, 12, 34, 56);
    final nonce = List.generate(64, (i) => i);
    final plain = awsClientFinal(
      credentials: creds,
      host: 'sts.us-west-2.amazonaws.com',
      serverNonce: nonce,
      now: at,
    );
    expect(plain['d'], '20261020T123456Z');
    expect(
      plain['a'],
      'AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20261020/us-west-2/sts/'
      'aws4_request, SignedHeaders=content-length;content-type;host;'
      'x-amz-date;x-mongodb-gs2-cb-flag;x-mongodb-server-nonce, '
      'Signature=51d806373492ee65ea3b2fc4199c7d20478d96d5fbcfb9adfd371646b6c91328',
    );
    final withToken = awsClientFinal(
      credentials: const AwsCredentials(
        'AKIDEXAMPLE',
        'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
        'TOKEN123',
      ),
      host: 'sts.us-west-2.amazonaws.com',
      serverNonce: nonce,
      now: at,
    );
    expect(withToken['t'], 'TOKEN123');
    expect(
      withToken['a'],
      endsWith(
        'Signature=ab24c9f7d24ee2977360ee6f37848e678199621567f0dea413307c5d43adbaa0',
      ),
    );
    expect(base64.encode(nonce), isNotEmpty);
  });

  test('STS hosts and regions', () {
    expect(stsRegion('sts.amazonaws.com'), 'us-east-1');
    expect(stsRegion('sts.eu-west-1.amazonaws.com'), 'eu-west-1');
    expect(validStsHost('sts.amazonaws.com'), isTrue);
    expect(validStsHost('sts..amazonaws.com'), isFalse);
    expect(validStsHost(''), isFalse);
    expect(validStsHost('a' * 256), isFalse);
  });

  test('reads authMechanismProperties', () {
    final cs = ConnectionString.parse(
      'mongodb://AKID:secret@h/?authMechanism=MONGODB-AWS'
      '&authMechanismProperties=AWS_SESSION_TOKEN:abc%3D,OTHER:x',
    );
    expect(cs.authMechanismProperties, {
      'AWS_SESSION_TOKEN': 'abc=',
      'OTHER': 'x',
    });
    expect(cs.authSource, r'$external');
  });
}
