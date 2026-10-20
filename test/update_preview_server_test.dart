import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mongo_wire/mongo_wire.dart';
import 'package:mongomobile/services/update_preview.dart';

/// Compares the update preview with what a real server does. Runs only
/// with MONGO_URI set, e.g. mongodb://localhost:27017.
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
}
