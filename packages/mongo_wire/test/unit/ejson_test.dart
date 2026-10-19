import 'package:mongo_wire/mongo_wire.dart';
import 'package:test/test.dart';

void main() {
  group('EJson parser', () {
    test('parses strict Extended JSON wrappers', () {
      final doc = EJson.parseDocument('''{
        "_id": {"\$oid": "65a1b2c3d4e5f60718293a4b"},
        "d": {"\$date": "2024-05-01T12:00:00.000Z"},
        "d2": {"\$date": {"\$numberLong": "0"}},
        "i": {"\$numberInt": "7"},
        "l": {"\$numberLong": "9"},
        "f": {"\$numberDouble": "-Infinity"},
        "dec": {"\$numberDecimal": "1.10"},
        "bin": {"\$binary": {"base64": "AQID", "subType": "80"}},
        "legacyBin": {"\$binary": "AQID", "\$type": "0"},
        "uuid": {"\$uuid": "123e4567-e89b-12d3-a456-426614174000"},
        "ts": {"\$timestamp": {"t": 1, "i": 2}},
        "re": {"\$regularExpression": {"pattern": "a", "options": "mi"}},
        "code": {"\$code": "x"},
        "sym": {"\$symbol": "s"},
        "u": {"\$undefined": true},
        "min": {"\$minKey": 1},
        "max": {"\$maxKey": 1}
      }''');
      expect(doc['_id'], ObjectId.parse('65a1b2c3d4e5f60718293a4b'));
      expect(doc['d'], DateTime.utc(2024, 5, 1, 12));
      expect(doc['d2'], DateTime.utc(1970));
      expect(doc['i'], 7);
      expect(doc['l'], const BsonLong(9));
      expect(doc['f'], double.negativeInfinity);
      expect(doc['dec'].toString(), '1.10');
      expect(doc['bin'], BsonBinary(0x80, [1, 2, 3]));
      expect(doc['legacyBin'], BsonBinary(0, [1, 2, 3]));
      expect(
        (doc['uuid'] as BsonBinary).uuidString,
        '123e4567-e89b-12d3-a456-426614174000',
      );
      expect(doc['ts'], const BsonTimestamp(1, 2));
      expect(doc['re'], const BsonRegex('a', 'im'));
      expect(doc['code'], const BsonCode('x'));
      expect(doc['sym'], const BsonSymbol('s'));
      expect(doc['u'], BsonUndefined.instance);
      expect(doc['min'], BsonMinKey.instance);
      expect(doc['max'], BsonMaxKey.instance);
    });

    test('parses shell syntax', () {
      final doc = EJson.parseDocument('''{
        // comment
        _id: ObjectId('65a1b2c3d4e5f60718293a4b'),
        created: ISODate("2024-05-01"),
        when: new Date(0),
        n: NumberLong(5), i: NumberInt("3"), d: NumberDecimal("2.5"),
        u: UUID("123e4567-e89b-12d3-a456-426614174000"),
        b: BinData(0, "AQID"),
        t: Timestamp(10, 2),
        name: /^ab+c/i,
        'single': 'quoted \\'string\\'',
        nested: { "a.b": [1, 2.0, -3e2, true, null, undefined, ], },
        lo: MinKey(), hi: MaxKey,
        dotted.path: 1,
      }''');
      expect(doc['_id'], isA<ObjectId>());
      expect(doc['created'], DateTime.utc(2024, 5, 1));
      expect(doc['when'], DateTime.utc(1970));
      expect(doc['n'], const BsonLong(5));
      expect(doc['i'], 3);
      expect(doc['d'], Decimal128.parse('2.5'));
      expect(doc['u'], isA<BsonBinary>());
      expect(doc['b'], BsonBinary(0, [1, 2, 3]));
      expect(doc['t'], const BsonTimestamp(10, 2));
      expect(doc['name'], const BsonRegex('^ab+c', 'i'));
      expect(doc['single'], "quoted 'string'");
      final nested = (doc['nested'] as Map)['a.b'] as List;
      expect(nested[0], isA<int>());
      expect(nested[1], isA<double>());
      expect(nested[2], -300.0);
      expect(nested.sublist(3), [true, null, BsonUndefined.instance]);
      expect(doc['lo'], BsonMinKey.instance);
      expect(doc['hi'], BsonMaxKey.instance);
      expect(doc['dotted.path'], 1);
    });

    test('keeps query operators untouched', () {
      final q = EJson.parseDocument(
        '{age: {\$gt: 5, \$lt: 10}, name: {\$regex: "^a"}, tags: {\$in: ["x"]}}',
      );
      expect(q['age'], {r'$gt': 5, r'$lt': 10});
      expect(q['name'], {r'$regex': '^a'});
      expect(q['tags'], {
        r'$in': ['x'],
      });
    });

    test('integers pick Int32 or Int64 by size', () {
      final doc = EJson.parseDocument('{a: 2147483647, b: 2147483648}');
      expect(Bson.decode(Bson.encode(doc))['a'], isA<int>());
      expect(Bson.decode(Bson.encode(doc))['b'], const BsonLong(2147483648));
    });

    test('allows an empty filter', () {
      expect(EJson.parseDocument('  ', allowEmpty: true), isEmpty);
      expect(() => EJson.parseDocument(''), throwsFormatException);
    });

    test('reports positions of errors', () {
      try {
        EJson.parseDocument('{\n  a: 1,\n  b: ObjectId("zz")\n}');
        fail('should throw');
      } on EJsonParseException catch (e) {
        expect(e.line, 3);
        expect(e.message, contains('ObjectId'));
      }
      expect(() => EJson.parseDocument('{a: 1'), throwsFormatException);
      expect(() => EJson.parseDocument('{a: 1} x'), throwsFormatException);
      expect(() => EJson.parseDocument('[1]'), throwsFormatException);
      expect(() => EJson.parseDocument('{a: foo}'), throwsFormatException);
    });
  });

  group('EJson writer', () {
    final doc = <String, dynamic>{
      '_id': ObjectId.parse('65a1b2c3d4e5f60718293a4b'),
      'i': 1,
      'l': const BsonLong(2),
      'd': 3.0,
      'dec': Decimal128.parse('0.10'),
      'date': DateTime.utc(2024),
      'old': DateTime.utc(1900),
      'bin': BsonBinary(0x80, [255]),
      'uuid': BsonBinary.uuidFromString('123e4567-e89b-12d3-a456-426614174000'),
      'nan': double.nan,
      're': const BsonRegex('a', 'i'),
      'code': const BsonCode('f', {'x': 1}),
      'ptr': BsonDbPointer('a.b', ObjectId.parse('65a1b2c3d4e5f60718293a4b')),
      'nested': {
        'arr': [1, 'a', null, true, const BsonTimestamp(1, 2)],
        'empty': <String, dynamic>{},
        'emptyArr': <dynamic>[],
      },
      'u': BsonUndefined.instance,
      'min': BsonMinKey.instance,
      'max': BsonMaxKey.instance,
    };

    test('editable output parses back to the same BSON', () {
      for (final pretty in [true, false]) {
        final text = EJson.stringify(doc, pretty: pretty);
        final back = EJson.parseDocument(text);
        expect(Bson.encode(back), Bson.encode(doc), reason: text);
      }
    });

    test('canonical output parses back to the same BSON', () {
      final text = EJson.stringify(doc, mode: EJsonMode.canonical);
      expect(text, contains(r'"$numberInt": "1"'));
      expect(text, contains(r'"$numberDouble": "3.0"'));
      expect(Bson.encode(EJson.parseDocument(text)), Bson.encode(doc));
    });

    test('relaxed output is plain where the spec allows', () {
      final text = EJson.stringify(doc, mode: EJsonMode.relaxed, pretty: false);
      expect(text, contains('"l":2'));
      expect(text, contains('"d":3.0'));
      expect(text, contains(r'"date":{"$date":"2024-01-01T00:00:00.000Z"}'));
      expect(
        text,
        contains(r'"old":{"$date":{"$numberLong":"-2208988800000"}}'),
      );
      expect(
        text,
        contains(r'"bin":{"$binary":{"base64":"/w==","subType":"80"}}'),
      );
    });

    test('formats doubles so they read back as doubles', () {
      expect(formatDouble(1), '1.0');
      expect(formatDouble(1e21), '1E+21');
      expect(formatDouble(-0.0), '-0.0');
      expect(formatDouble(0.5), '0.5');
    });
  });
}
