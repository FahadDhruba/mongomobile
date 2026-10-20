import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mongo_wire/mongo_wire.dart';
import 'package:mongomobile/services/codegen.dart';

/// With CODEGEN_OUT set, every snippet is also written there so it can be
/// checked with the real compilers (python3, node, gofmt, javac).
final String? out = Platform.environment['CODEGEN_OUT'];

const ns = Namespace('shop', 'orders');

final query = CodeQuery(
  filter: {
    'status': 'paid',
    'total': {r'$gte': 10.5, r'$lt': 100},
    'qty': const BsonLong(3),
    'price': Decimal128.parse('19.99'),
    '_id': ObjectId.parse('65a1b2c3d4e5f60718293a4b'),
    'createdAt': {r'$gt': DateTime.utc(2024, 5, 1, 9, 30, 0, 250)},
    'name': const BsonRegex('^ad', 'i'),
    'ref': BsonBinary.uuidFromString('123e4567-e89b-12d3-a456-426614174000'),
    'blob': BsonBinary(0, [1, 2, 3]),
    'ts': const BsonTimestamp(5, 6),
    'flag': true,
    'gone': null,
    'tags': {
      r'$in': ['a', 'b "quoted"'],
    },
    'address.city': 'London',
    r'$or': [
      {'min': BsonMinKey.instance},
      {'max': BsonMaxKey.instance},
    ],
  },
  projection: {'status': 1, 'total': 1},
  sort: {'total': -1, '_id': 1},
  skip: 20,
  limit: 10,
  collation: {'locale': 'en', 'strength': 2},
  hint: {'status': 1},
  maxTimeMs: 5000,
);

final pipeline = <Map<String, dynamic>>[
  {
    r'$match': {
      'status': 'paid',
      'when': {r'$gte': DateTime.utc(2024)},
    },
  },
  {
    r'$group': {
      '_id': r'$customer',
      'n': {r'$sum': 1},
      'total': {r'$sum': r'$total'},
    },
  },
  {
    r'$sort': {'n': -1},
  },
  {r'$limit': 5},
];

const _ext = {
  CodeLanguage.shell: 'shell.js',
  CodeLanguage.python: 'query.py',
  CodeLanguage.node: 'query.mjs',
  CodeLanguage.java: 'Query.java',
  CodeLanguage.csharp: 'query.cs',
  CodeLanguage.go: 'query.go',
};

void save(String kind, CodeLanguage lang, String code) {
  if (out == null) return;
  File('$out/$kind/${_ext[lang]}')
    ..createSync(recursive: true)
    ..writeAsStringSync(code);
}

void main() {
  for (final lang in CodeLanguage.values) {
    test('find in ${lang.label}', () {
      final code = findCode(lang, ns, query);
      save('find', lang, code);
      expect(code, contains('shop'));
      expect(code, contains('orders'));
      expect(code, contains('65a1b2c3d4e5f60718293a4b'));
      expect(code, contains('19.99'));
      expect(code, isNot(contains('password')));
      if (lang != CodeLanguage.shell) {
        expect(code, contains('<connection string>'));
      }
    });

    test('aggregate in ${lang.label}', () {
      final code = aggregateCode(lang, ns, pipeline, maxTimeMs: 3000);
      save('aggregate', lang, code);
      expect(code, contains(r'$group'));
      expect(code, contains(r'$customer'));
    });
  }

  test('language specifics', () {
    expect(
      findCode(CodeLanguage.python, ns, query),
      allOf(
        contains("sort=[('total', -1), ('_id', 1)]".replaceAll("'", '"')),
        contains('Int64(3)'),
        contains('datetime(2024, 5, 1, 9, 30, 0, 250000, tzinfo=timezone.utc)'),
        contains('max_time_ms=5000'),
      ),
    );
    expect(
      findCode(CodeLanguage.shell, ns, query),
      allOf(
        contains("ISODate('2024-05-01T09:30:00.250Z')"),
        contains("NumberLong('3')"),
        contains('.skip(20)'),
        contains('"address.city"'),
      ),
    );
    expect(
      findCode(CodeLanguage.java, ns, query),
      contains('CollationStrength.fromInt(2)'),
    );
    expect(
      findCode(CodeLanguage.csharp, ns, query),
      contains('CollationStrength.Secondary'),
    );
    expect(
      findCode(CodeLanguage.go, ns, query),
      allOf(contains('int64(3)'), contains('func oid(')),
    );
    expect(
      findCode(CodeLanguage.node, ns, query),
      contains("import { BSONRegExp, Binary, Decimal128,"),
    );
  });
}
