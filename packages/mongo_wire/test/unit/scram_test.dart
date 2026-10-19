import 'dart:convert';
import 'dart:typed_data';

import 'package:mongo_wire/mongo_wire.dart';
import 'package:test/test.dart';

Uint8List b(String s) => utf8.encode(s);

void main() {
  // Test vectors from RFC 7677 (SCRAM-SHA-256) and the MongoDB auth spec
  // (SCRAM-SHA-1, which pre-hashes the password).
  test('SCRAM-SHA-256 matches RFC 7677', () {
    final c = ScramConversation(
      mechanism: ScramMechanism.sha256,
      username: 'user',
      password: 'pencil',
      clientNonce: 'rOprNGfwEbeRWgbNEkqO',
    );
    expect(utf8.decode(c.clientFirst()), 'n,,n=user,r=rOprNGfwEbeRWgbNEkqO');
    final fin = c.clientFinal(
      b(
        'r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF\$k0,'
        's=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096',
      ),
    );
    expect(
      utf8.decode(fin),
      'c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF\$k0,'
      'p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=',
    );
    c.verifyServerFinal(b('v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4='));
    expect(
      () => c.verifyServerFinal(b('v=AAAA')),
      throwsA(isA<MongoAuthError>()),
    );
  });

  test('SCRAM-SHA-1 matches the MongoDB auth spec', () {
    final c = ScramConversation(
      mechanism: ScramMechanism.sha1,
      username: 'user',
      password: 'pencil',
      clientNonce: 'fyko+d2lbbFgONRv9qkxdawL',
    );
    c.clientFirst();
    final fin = c.clientFinal(
      b(
        'r=fyko+d2lbbFgONRv9qkxdawLHo+Vgk7qvUOKUwuWLIWg4l/9SraGMHEE,'
        's=rQ9ZY3MntBeuP3E1TDVC4w==,i=10000',
      ),
    );
    expect(
      utf8.decode(fin),
      'c=biws,r=fyko+d2lbbFgONRv9qkxdawLHo+Vgk7qvUOKUwuWLIWg4l/9SraGMHEE,'
      'p=MC2T8BvbmWRckDw8oWl5IVghwCY=',
    );
    c.verifyServerFinal(b('v=UMWeI25JD1yNYZRMpZ4VHvhZ9e0='));
  });

  test('rejects a nonce the client did not start', () {
    final c = ScramConversation(
      mechanism: ScramMechanism.sha256,
      username: 'u',
      password: 'p',
    );
    c.clientFirst();
    expect(
      () => c.clientFinal(b('r=other,s=AAAA,i=4096')),
      throwsA(isA<MongoAuthError>()),
    );
  });

  test('saslPrep maps spaces and rejects controls', () {
    expect(saslPrep('I­X'), 'IX');
    expect(saslPrep('a b'), 'a b');
    expect(() => saslPrep('a\u0007'), throwsA(isA<MongoAuthError>()));
  });
}
