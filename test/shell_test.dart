import 'package:flutter_test/flutter_test.dart';
import 'package:mongo_wire/mongo_wire.dart';
import 'package:mongomobile/services/shell.dart';

import 'support/fake_client.dart';

void main() {
  test('parses call chains with shell-syntax arguments', () {
    final parts = parseChain(
      "db.orders.find({ total: { \$gt: 5 }, note: 'a, (b)' }, { _id: 0 })"
      '.sort({ total: -1 }).limit(3)',
    );
    expect(parts.map((p) => p.name), ['db', 'orders', 'find', 'sort', 'limit']);
    expect(parts[1].args, isNull);
    expect(parts[2].args, [
      {
        'total': {r'$gt': 5},
        'note': 'a, (b)',
      },
      {'_id': 0},
    ]);
    expect(parts[4].args, [3]);
    final idParts = parseChain(
      "db['my coll'].findOne({ _id: ObjectId('65a1b2c3d4e5f60718293a4b') })",
    );
    expect(idParts[1].name, 'my coll');
    expect(
      (idParts[2].args!.single as Map)['_id'],
      ObjectId.parse('65a1b2c3d4e5f60718293a4b'),
    );
    expect(parseChain('db.getName()').last.args, isEmpty);
    expect(() => parseChain('db.x.find({)'), throwsA(isA<ShellError>()));
    expect(() => parseChain('db.x = 1'), throwsA(isA<ShellError>()));
  });

  test('formats like mongosh', () {
    expect(
      formatShell({
        '_id': ObjectId.parse('65a1b2c3d4e5f60718293a4b'),
        'n': const BsonLong(5),
        'price': Decimal128.parse('1.50'),
        'when': DateTime.utc(2024),
        "it's": "Ada's",
      }),
      "{\n  _id: ObjectId('65a1b2c3d4e5f60718293a4b'),\n  n: Long('5'),\n"
      "  price: Decimal128('1.50'),\n"
      "  when: ISODate('2024-01-01T00:00:00.000Z'),\n"
      "  'it\\'s': 'Ada\\'s'\n}",
    );
    expect(
      formatShell({
        'a': 1,
        'b': [true, null],
      }),
      '{ a: 1, b: [ true, null ] }',
    );
  });

  group('session', () {
    late FakeMongoClient client;
    late ShellSession shell;
    var writes = false;
    setUp(() {
      writes = false;
      client = FakeMongoClient({
        'shop': {
          'orders': [
            for (var i = 0; i < 25; i++) {'_id': i, 'n': i},
          ],
        },
      });
      shell = ShellSession(client: client, db: 'test', canWrite: () => writes);
    });

    test('use, show and paging with it', () async {
      expect(await shell.run('use shop'), 'switched to db shop');
      expect(await shell.run('show collections'), 'orders');
      final first = await shell.run('db.orders.find()');
      expect(first.split('\n').length, 21);
      expect(first, endsWith('Type "it" for more'));
      final second = await shell.run('it');
      expect(second.split('\n'), hasLength(5));
      expect(second, startsWith('{ _id: 20, n: 20 }'));
      await expectLater(shell.run('it'), throwsA(isA<ShellError>()));
      expect(await shell.run('db.orders.find({ n: 3 })'), '{ _id: 3, n: 3 }');
      expect(await shell.run('db.orders.countDocuments({})'), '25');
      expect(await shell.run('db.orders.find().count()'), '25');
      expect(
        await shell.run('db.orders.find().skip(2).limit(2).toArray()'),
        '[ { _id: 2, n: 2 }, { _id: 3, n: 3 } ]',
      );
    });

    test('writes need write mode', () async {
      await shell.run('use shop');
      await expectLater(
        shell.run("db.orders.insertOne({ _id: 99 })"),
        throwsA(isA<ShellError>()),
      );
      await expectLater(
        shell.run('db.runCommand({ drop: "orders" })'),
        throwsA(isA<ShellError>()),
      );
      writes = true;
      expect(
        await shell.run('db.orders.insertOne({ _id: 99 })'),
        '{ acknowledged: true, insertedId: 99 }',
      );
      expect(
        await shell.run(
          r'db.orders.updateMany({ n: { $lt: 2 } }, { $set: { low: true } })',
        ),
        '{ acknowledged: true, matchedCount: 2, modifiedCount: 2 }',
      );
      expect(
        await shell.run('db.orders.deleteOne({ _id: 99 })'),
        '{ acknowledged: true, deletedCount: 1 }',
      );
    });

    test('explains what it cannot do', () async {
      await expectLater(
        shell.run('const x = 1'),
        throwsA(
          isA<ShellError>().having(
            (e) => e.message,
            'message',
            contains('not JavaScript'),
          ),
        ),
      );
      await expectLater(shell.run('db.foo()'), throwsA(isA<ShellError>()));
      expect(await shell.run('help'), contains('show dbs'));
    });
  });
}
