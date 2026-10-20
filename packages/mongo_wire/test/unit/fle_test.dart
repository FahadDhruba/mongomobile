import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mongo_wire/mongo_wire.dart';
import 'package:test/test.dart';

/// A client whose key vault holds the fixture's data key.
class KeyVaultClient implements MongoClient {
  KeyVaultClient(this.keyDoc);
  final Map<String, dynamic> keyDoc;
  int finds = 0;

  @override
  Future<FindResult> find(
    Namespace ns,
    FindRequest r, {
    CancelToken? cancel,
  }) async {
    finds++;
    final id = r.filter['_id'] as BsonBinary;
    final match =
        Bson.encode({'v': id}).toString() ==
        Bson.encode({'v': keyDoc['_id']}).toString();
    return FindResult(
      match ? [keyDoc] : [],
      byteLength: 0,
      truncated: false,
      elapsed: Duration.zero,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  // Made with pymongo 4.19 / libmongocrypt 1.21 against mongo:7.
  final fixture =
      jsonDecode(File('test/fixtures/fle_local.json').readAsStringSync())
          as Map<String, dynamic>;
  final keyDoc = EJson.parseDocument(jsonEncode(fixture['keyDoc']));
  final master = Uint8List.fromList(base64.decode(fixture['master'] as String));
  final values = (fixture['values'] as Map)
      .cast<String, Map<String, dynamic>>();

  FieldEncryption fle(KmsProviders kms) => FieldEncryption(
    client: KeyVaultClient(keyDoc),
    keyVault: const Namespace('encryption', '__keyVault'),
    kms: kms,
  );

  Object? plain(Map<String, dynamic> v) =>
      EJson.parseDocument(jsonEncode({'v': v['plain']}))['v'];
  BsonBinary cipher(Map<String, dynamic> v) =>
      BsonBinary(6, base64.decode(v['cipher'] as String));
  String enc(Object? v) => EJson.stringify(v, mode: EJsonMode.canonical);

  test('decrypts every value libmongocrypt encrypted', () async {
    final f = fle(KmsProviders(localKey: master));
    for (final MapEntry(:key, :value) in values.entries) {
      expect(
        enc(await f.decryptValue(cipher(value))),
        enc(plain(value)),
        reason: key,
      );
    }
  });

  test(
    'deterministic encryption gives the same bytes as libmongocrypt',
    () async {
      final f = fle(KmsProviders(localKey: master));
      final keyId = keyDoc['_id'] as BsonBinary;
      for (final MapEntry(:key, :value) in values.entries) {
        if (!key.endsWith('Deterministic')) continue;
        final ours = await f.encryptValue(
          plain(value),
          keyId,
          deterministic: true,
        );
        expect(base64.encode(ours.data), value['cipher'], reason: key);
      }
      // Random values round-trip and differ each time.
      final a = await f.encryptValue('x', keyId, deterministic: false);
      final b = await f.encryptValue('x', keyId, deterministic: false);
      expect(base64.encode(a.data), isNot(base64.encode(b.data)));
      expect(await f.decryptValue(a), 'x');
    },
  );

  test('decrypts documents and encrypts the same fields again', () async {
    final client = KeyVaultClient(keyDoc);
    final f = FieldEncryption(
      client: client,
      keyVault: const Namespace('encryption', '__keyVault'),
      kms: KmsProviders(localKey: master),
    );
    final doc = <String, dynamic>{
      '_id': 1,
      'name': cipher(values['str.Deterministic']!),
      'info': {'age': cipher(values['int.Random']!)},
      'list': [cipher(values['str.Random']!), 'plain'],
    };
    final d = await f.decryptDocument(doc);
    expect(d.document['name'], 'Ada Lovelace');
    expect((d.document['info'] as Map)['age'], 42);
    expect((d.document['list'] as List).first, 'Ada Lovelace');
    expect(d.fields.map((x) => x.path.join('.')), [
      'name',
      'info.age',
      'list.0',
    ]);
    expect(client.finds, 1, reason: 'the data key is fetched once');

    final edited = {...d.document, 'name': 'Grace'};
    final saved = await f.reencrypt(edited, d.fields);
    expect(isEncryptedValue(saved['name']), isTrue);
    expect(await f.decryptValue(saved['name'] as BsonBinary), 'Grace');
    expect(isEncryptedValue((saved['info'] as Map)['age']), isTrue);
    expect((saved['list'] as List)[1], 'plain');
    // The unchanged deterministic value encrypts to its original bytes.
    final again = await f.reencrypt(d.document, d.fields);
    expect(
      base64.encode((again['name'] as BsonBinary).data),
      values['str.Deterministic']!['cipher'],
    );
  });

  test('a wrong master key or no key is reported, not thrown', () async {
    final f = fle(KmsProviders(localKey: Uint8List(96)));
    final d = await f.decryptDocument({'x': cipher(values['str.Random']!)});
    expect(isEncryptedValue(d.document['x']), isTrue);
    expect(d.failures['x'], contains('local master key'));
    final none = fle(const KmsProviders());
    final e = await none.decryptDocument({'x': cipher(values['str.Random']!)});
    expect(e.failures['x'], contains('add it'));
  });
}
