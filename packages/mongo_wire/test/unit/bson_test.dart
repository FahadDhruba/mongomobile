import 'dart:typed_data';

import 'package:mongo_wire/mongo_wire.dart';
import 'package:test/test.dart';

Map<String, dynamic> roundTrip(Map<String, dynamic> doc) =>
    Bson.decode(Bson.encode(doc));

void main() {
  group('Bson codec', () {
    test('round-trips every BSON type', () {
      final oid = ObjectId.parse('65a1b2c3d4e5f60718293a4b');
      final doc = <String, dynamic>{
        'double': 1.5,
        'integralDouble': 5.0,
        'string': 'héllo',
        'doc': {'a': 1, 'b': 'x'},
        'array': [
          1,
          'two',
          null,
          [3],
        ],
        'binary': BsonBinary(0, [1, 2, 3]),
        'oldBinary': BsonBinary(2, [4, 5]),
        'userBinary': BsonBinary(0x80, [9]),
        'uuid': BsonBinary.uuidFromString(
          '123e4567-e89b-12d3-a456-426614174000',
        ),
        'undefined': BsonUndefined.instance,
        'oid': oid,
        'true': true,
        'false': false,
        'date': DateTime.utc(2024, 5, 1, 12, 30, 0, 123),
        'farDate': const BsonDate(8640000000000001),
        'null': null,
        'regex': const BsonRegex('^a.*b', 'imsx'),
        'dbPointer': BsonDbPointer('db.coll', oid),
        'code': const BsonCode('function() { return 1; }'),
        'codeWithScope': const BsonCode('x + 1', {'x': 1}),
        'symbol': const BsonSymbol('sym'),
        'int32': -42,
        'timestamp': const BsonTimestamp(1700000000, 7),
        'int64': const BsonLong(5),
        'bigInt': 1 << 40,
        'decimal': Decimal128.parse('1.50'),
        'minKey': BsonMinKey.instance,
        'maxKey': BsonMaxKey.instance,
      };
      final back = roundTrip(doc);
      expect(back.keys.toList(), doc.keys.toList());
      for (final key in doc.keys) {
        if (key == 'bigInt') {
          expect(back[key], const BsonLong(1 << 40), reason: key);
        } else if (key == 'codeWithScope') {
          final c = back[key] as BsonCode;
          expect(c.code, 'x + 1');
          expect(c.scope, {'x': 1});
        } else {
          expect(back[key], doc[key], reason: key);
        }
      }
      expect(back['integralDouble'], isA<double>());
      expect(back['int64'], isA<BsonLong>());
      expect(back['int32'], isA<int>());
    });

    test('re-encodes decoded bytes identically', () {
      final doc = {
        'a': const BsonLong(1),
        'b': 1.0,
        'c': BsonBinary(0x83, [1]),
        'd': Decimal128.parse('NaN'),
      };
      final bytes = Bson.encode(doc);
      expect(Bson.encode(Bson.decode(bytes)), bytes);
    });

    test('matches known bytes', () {
      expect(Bson.encode({'hello': 'world'}), [
        0x16, 0, 0, 0, 0x02, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0, 0x06, 0, 0, 0, //
        0x77, 0x6f, 0x72, 0x6c, 0x64, 0, 0,
      ]);
    });

    test('rejects truncated data', () {
      final bytes = Bson.encode({'a': 'hello'});
      expect(
        () => Bson.decode(Uint8List.sublistView(bytes, 0, 10)),
        throwsA(isA<BsonException>()),
      );
    });

    test('rejects unknown element types', () {
      final bytes = Bson.encode({'a': 1});
      bytes[4] = 0x42;
      expect(() => Bson.decode(bytes), throwsA(isA<BsonException>()));
    });
  });

  group('ObjectId', () {
    test('parses and prints hex', () {
      final id = ObjectId.parse('65A1B2C3D4E5F60718293A4B');
      expect(id.hex, '65a1b2c3d4e5f60718293a4b');
      expect(id.timestamp, DateTime.utc(2024, 1, 12, 21, 44, 35));
    });

    test('generates increasing ids', () {
      final a = ObjectId();
      final b = ObjectId();
      expect(a.compareTo(b), lessThan(0));
    });
  });

  group('Decimal128', () {
    const canonical = [
      '0',
      '-0',
      '1',
      '-1',
      '0.1',
      '0.001234',
      '1.50',
      '-1.00E-8',
      '1E+3',
      '123456789012345678901234567890.1234',
      '1.234567890123456789012345678901234E+40',
      '9.999999999999999999999999999999999E+6144',
      '1E-6176',
      '0E-6176',
      '0E+6111',
      'NaN',
      'Infinity',
      '-Infinity',
      '0.000001',
      '1E-7',
    ];

    for (final s in canonical) {
      test('round-trips $s', () {
        expect(Decimal128.parse(s).toString(), s);
      });
    }

    test('normalises input', () {
      expect(Decimal128.parse('1.234E+3').toString(), '1234');
      expect(Decimal128.parse('+12').toString(), '12');
      expect(Decimal128.parse('inf').toString(), 'Infinity');
      expect(Decimal128.parse('.5').toString(), '0.5');
      expect(Decimal128.parse('0.0000001234').toString(), '1.234E-7');
    });

    test('encodes 1 like the spec', () {
      final d = Decimal128.parse('1');
      expect(d.bytes, [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x40, 0x30]);
    });

    test('rejects values that need rounding', () {
      expect(
        () => Decimal128.parse('1.2345678901234567890123456789012345'),
        throwsFormatException,
      );
      expect(() => Decimal128.parse('1E+7000'), throwsFormatException);
      expect(() => Decimal128.parse('abc'), throwsFormatException);
    });
  });
}
