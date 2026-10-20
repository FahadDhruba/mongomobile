import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mongo_wire/mongo_wire.dart';
import 'package:mongomobile/services/schema_analysis.dart';
import 'package:mongomobile/services/update_preview.dart';

/// Checks features against a real server: the update preview and generated
/// validators. Runs only with MONGO_URI set, e.g. mongodb://localhost:27017.
void main() {
  final uri = Platform.environment['MONGO_URI'];

  test('preview matches the server', () async {
    final client = await WireMongoClient.connect(uri!);
    addTearDown(client.close);
    const ns = Namespace('mongomobile_test', 'update_preview');
    await client.deleteMany(ns, {});
    Map<String, dynamic> doc() => {
      '_id': 1,
      'n': 5,
      'l': const BsonLong(5),
      'd': 1.5,
      'tags': ['a', 'b', 'a'],
      'a': {'b': 1},
      'nested': [
        {'x': 1},
      ],
    };
    final updates = <Map<String, dynamic>>[
      {
        r'$set': {'x': 1, 'a.c': 2, 'new.deep': true, 'tags.1': 'z'},
        r'$unset': {'d': '', 'nope': ''},
      },
      {
        r'$inc': {'n': 2, 'l': 1, 'd': 1, 'missing': const BsonLong(3)},
        r'$mul': {'m2': 4.0},
      },
      {
        r'$inc': {'n': 0x7fffffff},
      },
      {
        r'$push': {
          'tags': {
            r'$each': ['c', 'd'],
          },
        },
        r'$addToSet': {'set': 'x', 'a.list': 1},
      },
      {
        r'$addToSet': {
          'tags': {
            r'$each': ['a', 'q', 'q'],
          },
        },
      },
      {
        r'$pull': {'tags': 'a'},
        r'$pop': {'nested': 1},
      },
      {
        r'$rename': {'n': 'count', 'a.b': 'ab', 'none': 'other'},
      },
      {
        r'$set': {'tags.5': 'far', 'nested.0.y': 2},
      },
      {
        r'$unset': {'tags.0': ''},
      },
    ];
    for (final u in updates) {
      await client.deleteMany(ns, {});
      await client.insertOne(ns, doc());
      await client.updateOne(ns, {'_id': 1}, u);
      final server = (await client.find(
        ns,
        const FindRequest(filter: {'_id': 1}, limit: 1),
      )).documents.single;
      final preview = applyUpdate(doc(), u);
      expect(
        EJson.stringify(preview),
        EJson.stringify(server),
        reason: EJson.stringify(u),
      );
    }
    await client.dropCollection(ns);
  }, skip: uri == null ? 'MONGO_URI is not set' : null);

  test('generated validators accept the sample and reject others', () async {
    final client = await WireMongoClient.connect(uri!);
    addTearDown(client.close);
    const ns = Namespace('mongomobile_test', 'validation');
    await client.dropCollection(ns).catchError((_) {});
    final docs = <Map<String, dynamic>>[
      {
        'name': 'Ada',
        'n': 1,
        'big': const BsonLong(1),
        'when': DateTime.utc(2024),
        'tags': ['a'],
        'items': [
          {'sku': 'A', 'qty': 1.5},
        ],
        'address': {'city': 'London'},
        'maybe': null,
      },
      {
        'name': 'Bob',
        'n': 2,
        'big': const BsonLong(2),
        'when': DateTime.utc(2025),
        'tags': <Object?>[],
        'items': [
          {'sku': 'B'},
        ],
        'address': {'city': 'Paris', 'zip': '75001'},
        'maybe': 'x',
      },
    ];
    for (final d in docs) {
      await client.insertOne(ns, d);
    }
    final sample = (await client.find(
      ns,
      const FindRequest(limit: 10),
    )).documents;
    final validator = jsonSchemaOf(SchemaAnalysis.of(sample));
    await client.modifyCollection(ns, {
      'validator': validator,
      'validationLevel': 'strict',
      'validationAction': 'error',
    });
    final failing = await client.find(
      ns,
      FindRequest(
        filter: {
          r'$nor': [validator],
        },
        limit: 10,
      ),
    );
    expect(failing.documents, isEmpty);
    await client.insertOne(ns, {...docs.first, 'name': 'Cy'});
    await expectLater(
      client.insertOne(ns, {...docs.first, 'n': 'not a number'}),
      throwsA(isA<MongoException>()),
    );
    await expectLater(
      client.insertOne(ns, {'name': 'missing required fields'}),
      throwsA(isA<MongoException>()),
    );
    await client.dropCollection(ns);
  }, skip: uri == null ? 'MONGO_URI is not set' : null);
}
