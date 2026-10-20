@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';

import 'package:mongo_wire/mongo_wire.dart';
import 'package:test/test.dart';

/// Runs against a real server. Set MONGO_URI, for example
/// `mongodb://root:secret@localhost:27017/?authSource=admin`.
final String? uri = Platform.environment['MONGO_URI'];

void main() {
  if (uri == null) {
    test('integration tests', () {}, skip: 'MONGO_URI is not set');
    return;
  }

  late WireMongoClient client;
  final dbName = 'mongo_wire_test_${DateTime.now().millisecondsSinceEpoch}';
  Namespace ns(String c) => Namespace(dbName, c);

  setUpAll(() async {
    client = await WireMongoClient.connect(uri!);
  });

  tearDownAll(() async {
    await client.runCommand(dbName, {'dropDatabase': 1});
    await client.close();
  });

  test('connects and reports the server', () {
    expect(client.server.isWritable, isTrue);
    expect(client.server.version, matches(RegExp(r'^\d+\.\d+')));
    expect(client.server.maxWireVersion, greaterThanOrEqualTo(6));
  });

  test('round-trips every BSON type through the server', () async {
    final id = ObjectId();
    final doc = <String, dynamic>{
      '_id': id,
      'double': 1.0,
      'int32': 1,
      'int64': const BsonLong(1),
      'decimal': Decimal128.parse('1.10'),
      'string': 'ünïcode',
      'date': DateTime.utc(2024, 1, 2, 3, 4, 5, 6),
      'bin': BsonBinary(0x80, [1, 2]),
      'uuid': BsonBinary.uuidFromString('123e4567-e89b-12d3-a456-426614174000'),
      'regex': const BsonRegex('a+', 'i'),
      'ts': const BsonTimestamp(5, 6),
      'code': const BsonCode('1'),
      'min': BsonMinKey.instance,
      'max': BsonMaxKey.instance,
      'null': null,
      'nested': {
        'arr': [
          1,
          'a',
          {'b': true},
        ],
      },
    };
    await client.insertOne(ns('types'), doc);
    final found = await client.find(
      ns('types'),
      FindRequest(filter: {'_id': id}, limit: 1),
    );
    expect(Bson.encode(found.documents.single), Bson.encode(doc));
  });

  group('documents', () {
    final coll = ns('docs');

    setUpAll(() async {
      for (var i = 0; i < 120; i++) {
        await client.insertOne(coll, {'_id': i, 'n': i, 'even': i.isEven});
      }
    });

    test('counts', () async {
      expect(await client.estimatedDocumentCount(coll), 120);
      expect(await client.countDocuments(coll, {'even': true}), 60);
      expect(await client.countDocuments(coll, {'even': true}, limit: 10), 10);
      expect(await client.countDocuments(coll, {'n': -1}), 0);
    });

    test('pages by _id with keyset filters', () async {
      final first = await client.find(
        coll,
        const FindRequest(sort: {'_id': 1}, limit: 50),
      );
      expect(first.documents.length, 50);
      expect(first.documents.last['_id'], 49);
      final next = await client.find(
        coll,
        FindRequest(
          filter: {
            '_id': {r'$gt': first.documents.last['_id']},
          },
          sort: {'_id': 1},
          limit: 50,
        ),
      );
      expect(next.documents.first['_id'], 50);
      final back = await client.find(
        coll,
        FindRequest(
          filter: {
            '_id': {r'$lt': next.documents.first['_id']},
          },
          sort: {'_id': -1},
          limit: 50,
        ),
      );
      expect(back.documents.first['_id'], 49);
    });

    test('skips, sorts and projects', () async {
      final r = await client.find(
        coll,
        const FindRequest(
          sort: {'n': -1},
          skip: 10,
          limit: 5,
          projection: {'n': 1, '_id': 0},
        ),
      );
      expect(r.documents.map((d) => d['n']), [109, 108, 107, 106, 105]);
      expect(r.documents.first.keys, ['n']);
    });

    test('reads more than one batch with a time limit', () async {
      // Regression: getMore must not carry maxTimeMS (BadValue on servers).
      final r = await client.find(
        coll,
        const FindRequest(limit: 100, maxTime: Duration(seconds: 10)),
      );
      expect(r.documents.length, 100);
    });

    test('reads more than one batch', () async {
      final r = await client.find(coll, const FindRequest(limit: 100));
      expect(r.documents.length, 100);
      expect(r.truncated, isFalse);
    });
  });

  group('export cursor', () {
    final coll = ns('export');

    setUpAll(() async {
      for (var i = 0; i < 120; i++) {
        await client.insertOne(coll, {'_id': i, 'even': i.isEven});
      }
    });

    test('streams every document in batches', () async {
      final batches = await client.findBatches(coll, batchSize: 50).toList();
      expect(batches.map((b) => b.length), [50, 50, 20]);
      expect(
        batches.expand((b) => b).map((d) => d['_id']),
        List.generate(120, (i) => i),
      );
    });

    test('applies filter, sort, projection and limit', () async {
      final docs = await client
          .findBatches(
            coll,
            filter: {'even': true},
            sort: {'_id': -1},
            projection: {'_id': 1},
            limit: 7,
            batchSize: 3,
          )
          .expand((b) => b)
          .toList();
      expect(docs.map((d) => d['_id']), [118, 116, 114, 112, 110, 108, 106]);
      expect(docs.first.keys, ['_id']);
    });

    test('stops when cancelled and leaves the client usable', () async {
      final token = CancelToken();
      var seen = 0;
      await expectLater(() async {
        await for (final b in client.findBatches(
          coll,
          batchSize: 10,
          cancel: token,
        )) {
          seen += b.length;
          if (seen >= 20) token.cancel();
        }
      }(), throwsA(isA<MongoCancelledError>()));
      expect(seen, 20);
      expect(await client.estimatedDocumentCount(coll), 120);
    });

    test('a listener that stops early releases the connection', () async {
      final first = await client.findBatches(coll, batchSize: 10).first;
      expect(first.length, 10);
      // Several more exports would block if connections leaked.
      for (var i = 0; i < 8; i++) {
        expect(
          (await client.findBatches(coll, batchSize: 10).first).length,
          10,
        );
      }
    });
  });

  group('aggregation and explain', () {
    final coll = ns('agg');

    setUpAll(() async {
      final docs = [
        for (var i = 0; i < 60; i++) {'_id': i, 'g': i % 3, 'name': 'n$i'},
      ];
      final r = await client.insertMany(coll, docs);
      expect(r.inserted, 60);
    });

    test('runs a pipeline and pages its output', () async {
      final r = await client.aggregate(coll, [
        {
          r'$group': {
            '_id': r'$g',
            'n': {r'$sum': 1},
          },
        },
        {
          r'$sort': {'_id': 1},
        },
      ], limit: 10);
      expect(r.documents, [
        {'_id': 0, 'n': 20},
        {'_id': 1, 'n': 20},
        {'_id': 2, 'n': 20},
      ]);
      final many = await client.aggregate(
        coll,
        [
          {r'$match': <String, dynamic>{}},
        ],
        limit: 55,
        maxTime: const Duration(seconds: 10),
      );
      expect(many.documents, hasLength(55));
    });

    test(r'$out writes and returns nothing', () async {
      final r = await client.aggregate(coll, [
        {
          r'$match': {'g': 0},
        },
        {r'$out': 'agg_out'},
      ], limit: 10);
      expect(r.documents, isEmpty);
      expect(await client.estimatedDocumentCount(ns('agg_out')), 20);
    });

    test('explains a find with execution stats', () async {
      final plan = await client.explain(dbName, {
        'find': 'agg',
        'filter': {'g': 1},
      });
      final stats = plan['executionStats'] as Map<String, dynamic>;
      expect(stats['nReturned'], 20);
      expect(stats['totalDocsExamined'], 60);
      expect(plan['queryPlanner'], isA<Map<String, dynamic>>());
    });

    test('counts with collation and hint', () async {
      final n = await client.countDocuments(
        coll,
        {'name': 'N1'},
        collation: {'locale': 'en', 'strength': 2},
        hint: {'_id': 1},
      );
      expect(n, 1);
      final found = await client.find(
        coll,
        const FindRequest(
          filter: {'name': 'N2'},
          collation: {'locale': 'en', 'strength': 2},
          limit: 5,
        ),
      );
      expect(found.documents.single['_id'], 2);
    });
  });

  group('bulk writes', () {
    final coll = ns('bulk');

    test('insertMany reports failures and keeps going', () async {
      final r = await client.insertMany(coll, [
        {'_id': 1},
        {'_id': 1},
        {'_id': 2},
      ]);
      expect(r.inserted, 2);
      expect(r.errors.single.index, 1);
      expect(r.errors.single.isDuplicateKey, isTrue);
    });

    test('updateOne, updateMany with a pipeline, deleteMany', () async {
      await client.insertMany(coll, [
        for (var i = 10; i < 20; i++) {'_id': i, 'v': i},
      ]);
      final one = await client.updateOne(
        coll,
        {'_id': 10},
        {
          r'$set': {'flag': true},
        },
      );
      expect(one.modified, 1);
      final many = await client.updateMany(
        coll,
        {
          'v': {r'$gte': 15},
        },
        [
          {
            r'$set': {
              'double': {
                r'$multiply': [r'$v', 2],
              },
            },
          },
        ],
      );
      expect(many.matched, 5);
      final doc = (await client.find(
        coll,
        const FindRequest(filter: {'_id': 19}, limit: 1),
      )).documents.single;
      expect(doc['double'], 38);
      expect(
        await client.deleteMany(coll, {
          'v': {r'$lt': 15},
        }),
        5,
      );
    });

    test('insertMany splits very large inputs', () async {
      final big = 'x' * 100000;
      final r = await client.insertMany(ns('bulk_big'), [
        for (var i = 0; i < 200; i++) {'_id': i, 'big': big},
      ]);
      expect(r.inserted, 200);
    });
  });

  group('collections and databases', () {
    test('creates capped, time series and view collections', () async {
      await client.createCollection(ns('capped'), {
        'capped': true,
        'size': 4096,
        'max': 10,
      });
      await client.createCollection(ns('ts'), {
        'timeseries': {
          'timeField': 't',
          'metaField': 'm',
          'granularity': 'hours',
        },
      });
      await client.insertOne(ns('src'), {'a': 1, 'b': 2});
      await client.createCollection(ns('v'), {
        'viewOn': 'src',
        'pipeline': [
          {
            r'$project': {'a': 1},
          },
        ],
      });
      final infos = {
        for (final c in await client.listCollections(dbName)) c.name: c,
      };
      expect(infos['capped']!.options['capped'], isTrue);
      expect(infos['ts']!.type, 'timeseries');
      expect(infos['v']!.isView, isTrue);
      final view = await client.find(ns('v'), const FindRequest(limit: 5));
      expect(view.documents.single.containsKey('b'), isFalse);

      // Edit the view's pipeline with collMod.
      await client.modifyCollection(ns('v'), {
        'viewOn': 'src',
        'pipeline': [
          {
            r'$project': {'b': 1},
          },
        ],
      });
      final edited = await client.find(ns('v'), const FindRequest(limit: 5));
      expect(edited.documents.single.containsKey('b'), isTrue);
    });

    test('sets a validator with collMod and enforces it', () async {
      await client.createCollection(ns('valid'));
      await client.modifyCollection(ns('valid'), {
        'validator': {
          r'$jsonSchema': {
            'required': ['name'],
          },
        },
        'validationLevel': 'strict',
        'validationAction': 'error',
      });
      await expectLater(
        client.insertOne(ns('valid'), {'x': 1}),
        throwsA(isA<MongoWriteError>()),
      );
      await client.insertOne(ns('valid'), {'name': 'ok'});
      final info = (await client.listCollections(
        dbName,
      )).firstWhere((c) => c.name == 'valid');
      expect(info.options['validator'], isNotNull);
    });

    test('hides an index and reads index stats', () async {
      await client.insertOne(ns('hide'), {'a': 1});
      await client.createIndex(ns('hide'), {'a': 1});
      await client.modifyCollection(ns('hide'), {
        'index': {'name': 'a_1', 'hidden': true},
      });
      final idx = await client.listIndexes(ns('hide'));
      expect(idx.firstWhere((i) => i['name'] == 'a_1')['hidden'], isTrue);
      final stats = await client.indexStats(ns('hide'));
      expect(stats.map((s) => s['name']), containsAll(['_id_', 'a_1']));
      expect(stats.first['accesses'], isA<Map<String, dynamic>>());
    });

    test('renames a collection', () async {
      await client.insertOne(ns('old_name'), {'a': 1});
      await client.renameCollection(ns('old_name'), 'new_name');
      final names = (await client.listCollections(dbName)).map((c) => c.name);
      expect(names, contains('new_name'));
      expect(names, isNot(contains('old_name')));
    });

    test('drops a database', () async {
      final other = '${dbName}_drop';
      await client.insertOne(Namespace(other, 'c'), {'a': 1});
      expect(
        (await client.listDatabases()).map((d) => d.name),
        contains(other),
      );
      await client.dropDatabase(other);
      expect(
        (await client.listDatabases()).map((d) => d.name),
        isNot(contains(other)),
      );
    });
  });

  test('drops a collection, and dropping again is fine', () async {
    final coll = ns('to_drop');
    await client.insertOne(coll, {'a': 1});
    await client.dropCollection(coll);
    final names = (await client.listCollections(dbName)).map((c) => c.name);
    expect(names, isNot(contains('to_drop')));
    await client.dropCollection(coll);
  });

  test('stops reading at the byte cap', () async {
    final coll = ns('big');
    final big = 'x' * (200 * 1024);
    for (var i = 0; i < 40; i++) {
      await client.insertOne(coll, {'_id': i, 'blob': big});
    }
    final r = await client.find(
      coll,
      const FindRequest(limit: 40, maxBytes: 1024 * 1024),
    );
    expect(r.truncated, isTrue);
    expect(r.documents.length, lessThan(40));
    expect(r.documents.length, greaterThan(0));
    final all = await client.find(
      coll,
      const FindRequest(limit: 40, maxBytes: 64 << 20),
    );
    expect(all.documents.length, 40);
  });

  test('enforces maxTimeMS', () async {
    final coll = ns('slow');
    await client.insertOne(coll, {'_id': 1});
    await expectLater(
      client.find(
        coll,
        const FindRequest(
          filter: {r'$where': 'sleep(2000) || true'},
          limit: 1,
          maxTime: Duration(milliseconds: 200),
        ),
      ),
      throwsA(
        isA<MongoServerError>().having(
          (e) => e.isMaxTimeExpired,
          'isMaxTimeExpired',
          isTrue,
        ),
      ),
    );
  });

  test('cancels a running query quickly and keeps working', () async {
    final coll = ns('cancel');
    await client.insertOne(coll, {'_id': 1});
    final token = CancelToken();
    final sw = Stopwatch()..start();
    final future = client.find(
      coll,
      const FindRequest(filter: {r'$where': 'sleep(5000) || true'}, limit: 1),
      cancel: token,
    );
    Timer(const Duration(milliseconds: 300), token.cancel);
    await expectLater(future, throwsA(isA<MongoCancelledError>()));
    expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
    final ok = await client.find(coll, const FindRequest(limit: 1));
    expect(ok.documents, hasLength(1));
  });

  test('replaces and deletes', () async {
    final coll = ns('edit');
    final id = await client.insertOne(coll, {'a': 1});
    expect(id, isA<ObjectId>());
    final r = await client.replaceOne(coll, {'_id': id}, {'_id': id, 'a': 2});
    expect(r.matched, 1);
    expect(r.modified, 1);
    await expectLater(
      client.insertOne(coll, {'_id': id}),
      throwsA(
        isA<MongoWriteError>().having((e) => e.isDuplicateKey, 'dup', true),
      ),
    );
    expect(await client.deleteOne(coll, {'_id': id}), 1);
    expect(await client.deleteOne(coll, {'_id': id}), 0);
  });

  test('lists databases and collections with stats', () async {
    final coll = ns('stats');
    await client.insertOne(coll, {'a': 1});
    final dbs = await client.listDatabases();
    expect(dbs.map((d) => d.name), contains(dbName));
    final colls = await client.listCollections(dbName);
    expect(colls.map((c) => c.name), contains('stats'));
    final stats = await client.collectionStats(coll);
    expect(stats!.count, 1);
    expect(stats.size, greaterThan(0));
    expect(stats.indexSizes.keys, contains('_id_'));
  });

  test('creates, lists and drops indexes', () async {
    final coll = ns('idx');
    await client.insertOne(coll, {'a': 1, 'b': 'x'});
    final name = await client.createIndex(coll, {
      'a': 1,
      'b': -1,
    }, const IndexOptions(unique: true));
    expect(name, 'a_1_b_-1');
    await client.createIndex(coll, {
      'b': 1,
    }, const IndexOptions(name: 'ttl', expireAfter: Duration(hours: 1)));
    var indexes = await client.listIndexes(coll);
    expect(
      indexes.map((i) => i['name']),
      containsAll(['_id_', 'a_1_b_-1', 'ttl']),
    );
    expect(
      indexes.firstWhere((i) => i['name'] == 'a_1_b_-1')['unique'],
      isTrue,
    );
    await client.dropIndex(coll, name);
    indexes = await client.listIndexes(coll);
    expect(indexes.map((i) => i['name']), isNot(contains(name)));
  });

  group('authentication', () {
    final user = 'mw_user_${DateTime.now().millisecondsSinceEpoch}';

    setUpAll(() async {
      await client.runCommand(dbName, {
        'createUser': user,
        'pwd': 'p@ss:word',
        'roles': [
          {'role': 'readWrite', 'db': dbName},
        ],
        'mechanisms': ['SCRAM-SHA-1', 'SCRAM-SHA-256'],
      });
    });

    String userUri(String extra) {
      final cs = ConnectionString.parse(uri!);
      final host = cs.hosts.first;
      return 'mongodb://$user:${Uri.encodeComponent('p@ss:word')}@$host/$dbName$extra';
    }

    for (final mech in ['SCRAM-SHA-256', 'SCRAM-SHA-1']) {
      test(mech, () async {
        final c = await WireMongoClient.connect(
          userUri('?authMechanism=$mech'),
        );
        await c.insertOne(Namespace(dbName, 'auth'), {'m': mech});
        await c.close();
      });
    }

    test('negotiates the mechanism', () async {
      final c = await WireMongoClient.connect(userUri(''));
      expect(
        await c.estimatedDocumentCount(Namespace(dbName, 'auth')),
        greaterThanOrEqualTo(0),
      );
      await c.close();
    });

    test('rejects a wrong password', () async {
      final cs = ConnectionString.parse(uri!);
      await expectLater(
        WireMongoClient.connect(
          'mongodb://$user:wrong@${cs.hosts.first}/$dbName',
        ),
        throwsA(isA<MongoAuthError>()),
      );
    });
  });

  test('reports unreachable servers', () async {
    await expectLater(
      WireMongoClient.connect(
        'mongodb://127.0.0.1:1/?serverSelectionTimeoutMS=3000&connectTimeoutMS=1000',
      ),
      throwsA(isA<MongoException>()),
    );
  });
}
