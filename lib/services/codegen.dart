import 'dart:convert';

import 'package:mongo_wire/mongo_wire.dart';

enum CodeLanguage {
  shell('mongosh'),
  python('Python'),
  node('Node.js'),
  java('Java'),
  csharp('C#'),
  go('Go');

  const CodeLanguage(this.label);
  final String label;
}

/// A find query to turn into code.
class CodeQuery {
  const CodeQuery({
    this.filter = const {},
    this.projection,
    this.sort,
    this.skip = 0,
    this.limit,
    this.collation,
    this.hint,
    this.maxTimeMs,
  });

  final Map<String, dynamic> filter;
  final Map<String, dynamic>? projection;
  final Map<String, dynamic>? sort;
  final int skip;
  final int? limit;
  final Map<String, dynamic>? collation;

  /// An index name or key pattern.
  final Object? hint;
  final int? maxTimeMs;
}

const _uriPlaceholder = '<connection string>';

/// Code for a find query in [lang], ready to paste into a program. The
/// connection string is a placeholder, so no password ends up in the code.
String findCode(CodeLanguage lang, Namespace ns, CodeQuery q) =>
    _generator(lang).find(ns, q);

/// Code for an aggregation pipeline in [lang].
String aggregateCode(
  CodeLanguage lang,
  Namespace ns,
  List<Map<String, dynamic>> pipeline, {
  Map<String, dynamic>? collation,
  int? maxTimeMs,
}) => _generator(lang).aggregate(ns, pipeline, collation, maxTimeMs);

_Gen _generator(CodeLanguage lang) => switch (lang) {
  CodeLanguage.shell => _Shell(),
  CodeLanguage.python => _Python(),
  CodeLanguage.node => _Node(),
  CodeLanguage.java => _Java(),
  CodeLanguage.csharp => _CSharp(),
  CodeLanguage.go => _Go(),
};

String _q(String s) => jsonEncode(s);

String _num(double v) {
  if (v.isNaN) return 'NaN';
  if (v.isInfinite) return v > 0 ? 'Infinity' : '-Infinity';
  return formatDouble(v).replaceFirst('E', 'e');
}

String _iso(DateTime d) => formatIsoDate(d);

abstract class _Gen {
  /// Imports and helpers the generated value literals need.
  final imports = <String>{};

  String lit(Object? v, int depth);
  String find(Namespace ns, CodeQuery q);
  String aggregate(
    Namespace ns,
    List<Map<String, dynamic>> pipeline,
    Map<String, dynamic>? collation,
    int? maxTimeMs,
  );

  String pad(int depth) => '  ' * depth;

  static final _ident = RegExp(r'^[A-Za-z_$][\w$]*$');
  bool plainKey(String k) => _ident.hasMatch(k);
}

/// mongosh and Node.js share JavaScript object syntax.
abstract class _JsLike extends _Gen {
  String key(String k) => plainKey(k) ? k : _q(k);

  String scalar(Object? v);

  @override
  String lit(Object? v, int depth) {
    if (v is Map) {
      if (v.isEmpty) return '{}';
      final inner = v.entries
          .map((e) => '${pad(depth + 1)}${key('${e.key}')}: ${lit(e.value, depth + 1)}')
          .join(',\n');
      return '{\n$inner\n${pad(depth)}}';
    }
    if (v is List) {
      if (v.isEmpty) return '[]';
      final inner = v.map((e) => '${pad(depth + 1)}${lit(e, depth + 1)}').join(',\n');
      return '[\n$inner\n${pad(depth)}]';
    }
    return scalar(v);
  }
}

class _Shell extends _JsLike {
  @override
  String scalar(Object? v) => switch (v) {
    null => 'null',
    bool() => '$v',
    int() => '$v',
    double() => _num(v),
    String() => _q(v),
    BsonLong() => "NumberLong('${v.value}')",
    Decimal128() => "NumberDecimal('$v')",
    ObjectId() => "ObjectId('${v.hex}')",
    DateTime() => "ISODate('${_iso(v)}')",
    BsonDate() => 'new Date(${v.millis})',
    BsonBinary(isUuid: true) => "UUID('${v.uuidString}')",
    BsonBinary() => "BinData(${v.subtype}, '${base64.encode(v.data)}')",
    BsonRegex() => 'RegExp(${_q(v.pattern)}, ${_q(v.options)})',
    BsonTimestamp() => 'Timestamp({ t: ${v.seconds}, i: ${v.increment} })',
    BsonCode() => 'Code(${_q(v.code)})',
    BsonMinKey() => 'MinKey()',
    BsonMaxKey() => 'MaxKey()',
    BsonUndefined() => 'undefined',
    BsonSymbol() => _q(v.value),
    _ => _q(EJson.stringify(v, pretty: false)),
  };

  String _coll(Namespace ns) =>
      'db.getSiblingDB(${_q(ns.db)}).getCollection(${_q(ns.collection)})';

  @override
  String find(Namespace ns, CodeQuery q) {
    final b = StringBuffer('${_coll(ns)}.find(\n  ${lit(q.filter, 1)}');
    if (q.projection != null) b.write(',\n  ${lit(q.projection, 1)}');
    b.write('\n)');
    if (q.sort != null) b.write('\n  .sort(${lit(q.sort, 1)})');
    if (q.skip > 0) b.write('\n  .skip(${q.skip})');
    if (q.limit != null) b.write('\n  .limit(${q.limit})');
    if (q.collation != null) b.write('\n  .collation(${lit(q.collation, 1)})');
    if (q.hint != null) b.write('\n  .hint(${lit(q.hint, 1)})');
    if (q.maxTimeMs != null) b.write('\n  .maxTimeMS(${q.maxTimeMs})');
    return '$b;\n';
  }

  @override
  String aggregate(Namespace ns, List<Map<String, dynamic>> p,
      Map<String, dynamic>? collation, int? maxTimeMs) {
    final opts = {
      'collation': ?collation,
      'maxTimeMS': ?maxTimeMs,
    };
    return '${_coll(ns)}.aggregate(\n  ${lit(p, 1)}'
        '${opts.isEmpty ? '' : ',\n  ${lit(opts, 1)}'}\n);\n';
  }
}

class _Node extends _JsLike {
  @override
  String scalar(Object? v) {
    String use(String name, String code) {
      imports.add(name);
      return code;
    }

    return switch (v) {
      null => 'null',
      bool() => '$v',
      int() => '$v',
      double() => v.isNaN
          ? 'NaN'
          : v.isInfinite
          ? (v > 0 ? 'Infinity' : '-Infinity')
          : use('Double', 'new Double(${_num(v)})'),
      String() => _q(v),
      BsonLong() => use('Long', "Long.fromString('${v.value}')"),
      Decimal128() => use('Decimal128', "Decimal128.fromString('$v')"),
      ObjectId() => use('ObjectId', "new ObjectId('${v.hex}')"),
      DateTime() => "new Date('${_iso(v)}')",
      BsonDate() => 'new Date(${v.millis})',
      BsonBinary(isUuid: true) => use('UUID', "new UUID('${v.uuidString}')"),
      BsonBinary() => use(
        'Binary',
        "Binary.createFromBase64('${base64.encode(v.data)}', ${v.subtype})",
      ),
      BsonRegex() => use(
        'BSONRegExp',
        'new BSONRegExp(${_q(v.pattern)}, ${_q(v.options)})',
      ),
      BsonTimestamp() => use(
        'Timestamp',
        'new Timestamp({ t: ${v.seconds}, i: ${v.increment} })',
      ),
      BsonCode() => use('Code', 'new Code(${_q(v.code)})'),
      BsonMinKey() => use('MinKey', 'new MinKey()'),
      BsonMaxKey() => use('MaxKey', 'new MaxKey()'),
      BsonUndefined() => 'undefined',
      BsonSymbol() => _q(v.value),
      _ => _q(EJson.stringify(v, pretty: false)),
    };
  }

  String _wrap(String body) {
    final names = ({'MongoClient', ...imports}.toList()..sort());
    return "import { ${names.join(', ')} } from 'mongodb';\n\n"
        "const client = new MongoClient('$_uriPlaceholder');\n\n"
        '$body\n'
        'await client.close();\n';
  }

  @override
  String find(Namespace ns, CodeQuery q) {
    final filter = lit(q.filter, 0);
    final opts = <String, String>{
      if (q.projection != null) 'projection': lit(q.projection, 1),
      if (q.sort != null) 'sort': lit(q.sort, 1),
      if (q.skip > 0) 'skip': '${q.skip}',
      if (q.limit != null) 'limit': '${q.limit}',
      if (q.collation != null) 'collation': lit(q.collation, 1),
      if (q.hint != null) 'hint': lit(q.hint, 1),
      if (q.maxTimeMs != null) 'maxTimeMS': '${q.maxTimeMs}',
    };
    final optText = opts.isEmpty
        ? ''
        : ',\n  {\n${opts.entries.map((e) => '    ${e.key}: ${e.value.replaceAll('\n', '\n  ')}').join(',\n')}\n  }';
    return _wrap(
      'const filter = $filter;\n\n'
      'const docs = await client\n'
      '  .db(${_q(ns.db)})\n'
      '  .collection(${_q(ns.collection)})\n'
      '  .find(filter$optText)\n'
      '  .toArray();\n',
    );
  }

  @override
  String aggregate(Namespace ns, List<Map<String, dynamic>> p,
      Map<String, dynamic>? collation, int? maxTimeMs) {
    final opts = {'collation': ?collation, 'maxTimeMS': ?maxTimeMs};
    return _wrap(
      'const pipeline = ${lit(p, 0)};\n\n'
      'const docs = await client\n'
      '  .db(${_q(ns.db)})\n'
      '  .collection(${_q(ns.collection)})\n'
      '  .aggregate(pipeline${opts.isEmpty ? '' : ', ${lit(opts, 1)}'})\n'
      '  .toArray();\n',
    );
  }
}

class _Python extends _Gen {
  String use(String import, String code) {
    imports.add(import);
    return code;
  }

  @override
  String lit(Object? v, int depth) {
    if (v is Map) {
      if (v.isEmpty) return '{}';
      final inner = v.entries
          .map((e) => '${pad(depth + 1)}${_q('${e.key}')}: ${lit(e.value, depth + 1)}')
          .join(',\n');
      return '{\n$inner\n${pad(depth)}}';
    }
    if (v is List) {
      if (v.isEmpty) return '[]';
      final inner = v.map((e) => '${pad(depth + 1)}${lit(e, depth + 1)}').join(',\n');
      return '[\n$inner\n${pad(depth)}]';
    }
    return switch (v) {
      null => 'None',
      true => 'True',
      false => 'False',
      int() => '$v',
      double() => v.isNaN
          ? "float('nan')"
          : v.isInfinite
          ? (v > 0 ? "float('inf')" : "float('-inf')")
          : _num(v),
      String() => _q(v),
      BsonLong() => use('from bson.int64 import Int64', 'Int64(${v.value})'),
      Decimal128() => use('from bson.decimal128 import Decimal128', "Decimal128('$v')"),
      ObjectId() => use('from bson.objectid import ObjectId', "ObjectId('${v.hex}')"),
      DateTime() => use(
        'from datetime import datetime, timezone',
        'datetime(${v.year}, ${v.month}, ${v.day}, ${v.hour}, ${v.minute}, '
            '${v.second}, ${v.millisecond * 1000}, tzinfo=timezone.utc)',
      ),
      BsonDate() => use(
        'from bson.datetime_ms import DatetimeMS',
        'DatetimeMS(${v.millis})',
      ),
      BsonBinary(isUuid: true) => () {
        imports.add('from uuid import UUID');
        return use(
          'from bson.binary import Binary',
          "Binary.from_uuid(UUID('${v.uuidString}'))",
        );
      }(),
      BsonBinary() => use(
        'from bson.binary import Binary',
        "Binary(bytes.fromhex('${v.hex}'), ${v.subtype})",
      ),
      BsonRegex() => use(
        'from bson.regex import Regex',
        'Regex(${_q(v.pattern)}, ${_q(v.options)})',
      ),
      BsonTimestamp() => use(
        'from bson.timestamp import Timestamp',
        'Timestamp(${v.seconds}, ${v.increment})',
      ),
      BsonCode() => use('from bson.code import Code', 'Code(${_q(v.code)})'),
      BsonMinKey() => use('from bson.min_key import MinKey', 'MinKey()'),
      BsonMaxKey() => use('from bson.max_key import MaxKey', 'MaxKey()'),
      BsonUndefined() => 'None',
      BsonSymbol() => _q(v.value),
      _ => _q(EJson.stringify(v, pretty: false)),
    };
  }

  /// PyMongo takes sort and hint as lists of (field, direction) pairs.
  String pairs(Map<String, dynamic> m) =>
      '[${m.entries.map((e) => '(${_q(e.key)}, ${lit(e.value, 1)})').join(', ')}]';

  String _wrap(Namespace ns, String body) {
    final lines = ({'from pymongo import MongoClient', ...imports}.toList()..sort());
    return '${lines.join('\n')}\n\n'
        "client = MongoClient('$_uriPlaceholder')\n"
        'collection = client[${_q(ns.db)}][${_q(ns.collection)}]\n\n'
        '$body';
  }

  @override
  String find(Namespace ns, CodeQuery q) {
    final args = <String>[
      'filter',
      if (q.projection != null) 'projection=${lit(q.projection, 1)}',
      if (q.sort != null) 'sort=${pairs(q.sort!)}',
      if (q.skip > 0) 'skip=${q.skip}',
      if (q.limit != null) 'limit=${q.limit}',
      if (q.collation != null) 'collation=${lit(q.collation, 1)}',
      if (q.hint != null)
        'hint=${q.hint is Map<String, dynamic> ? pairs(q.hint as Map<String, dynamic>) : lit(q.hint, 1)}',
      if (q.maxTimeMs != null) 'max_time_ms=${q.maxTimeMs}',
    ];
    final filter = lit(q.filter, 0);
    return _wrap(
      ns,
      'filter = $filter\n\n'
      'docs = list(collection.find(\n    ${args.join(',\n    ')},\n))\n',
    );
  }

  @override
  String aggregate(Namespace ns, List<Map<String, dynamic>> p,
      Map<String, dynamic>? collation, int? maxTimeMs) {
    final pipeline = lit(p, 0);
    final extra = [
      if (collation != null) 'collation=${lit(collation, 1)}',
      if (maxTimeMs != null) 'maxTimeMS=$maxTimeMs',
    ];
    return _wrap(
      ns,
      'pipeline = $pipeline\n\n'
      'docs = list(collection.aggregate(pipeline${extra.isEmpty ? '' : ', ${extra.join(', ')}'}))\n',
    );
  }
}

class _Java extends _Gen {
  String use(String import, String code) {
    imports.add(import);
    return code;
  }

  @override
  String lit(Object? v, int depth) {
    if (v is Map) {
      imports.add('org.bson.Document');
      if (v.isEmpty) return 'new Document()';
      final entries = v.entries.toList();
      final b = StringBuffer(
          'new Document(${_q('${entries.first.key}')}, ${lit(entries.first.value, depth + 1)})');
      for (final e in entries.skip(1)) {
        b.write('\n${pad(depth + 1)}.append(${_q('${e.key}')}, ${lit(e.value, depth + 1)})');
      }
      return b.toString();
    }
    if (v is List) {
      imports.add('java.util.Arrays');
      if (v.isEmpty) return 'Arrays.asList()';
      final inner = v.map((e) => '${pad(depth + 1)}${lit(e, depth + 1)}').join(',\n');
      return 'Arrays.asList(\n$inner)';
    }
    return switch (v) {
      null => 'null',
      bool() => '$v',
      int() => '$v',
      double() => v.isNaN
          ? 'Double.NaN'
          : v.isInfinite
          ? (v > 0 ? 'Double.POSITIVE_INFINITY' : 'Double.NEGATIVE_INFINITY')
          : '${_num(v)}d',
      String() => _q(v),
      BsonLong() => '${v.value}L',
      Decimal128() => use('org.bson.types.Decimal128', 'Decimal128.parse("$v")'),
      ObjectId() => use('org.bson.types.ObjectId', 'new ObjectId("${v.hex}")'),
      DateTime() => () {
        imports.add('java.time.Instant');
        return use('java.util.Date', 'Date.from(Instant.parse("${_iso(v)}"))');
      }(),
      BsonDate() => use('java.util.Date', 'new Date(${v.millis}L)'),
      // A plain java.util.UUID needs a uuidRepresentation on the client;
      // BsonBinary always encodes it as standard subtype 4.
      BsonBinary(isUuid: true) => () {
        imports.add('java.util.UUID');
        return use(
          'org.bson.BsonBinary',
          'new BsonBinary(UUID.fromString("${v.uuidString}"))',
        );
      }(),
      BsonBinary() => () {
        imports.add('java.util.Base64');
        return use(
          'org.bson.types.Binary',
          'new Binary((byte) ${v.subtype}, Base64.getDecoder().decode("${base64.encode(v.data)}"))',
        );
      }(),
      BsonRegex() => use(
        'org.bson.BsonRegularExpression',
        'new BsonRegularExpression(${_q(v.pattern)}, ${_q(v.options)})',
      ),
      BsonTimestamp() => use(
        'org.bson.BsonTimestamp',
        'new BsonTimestamp(${v.seconds}, ${v.increment})',
      ),
      BsonCode() => use('org.bson.types.Code', 'new Code(${_q(v.code)})'),
      BsonMinKey() => use('org.bson.types.MinKey', 'new MinKey()'),
      BsonMaxKey() => use('org.bson.types.MaxKey', 'new MaxKey()'),
      BsonUndefined() => 'null',
      BsonSymbol() => _q(v.value),
      _ => _q(EJson.stringify(v, pretty: false)),
    };
  }

  String collation(Map<String, dynamic> c) {
    imports.add('com.mongodb.client.model.Collation');
    final b = StringBuffer('Collation.builder().locale(${_q('${c['locale']}')})');
    final strength = c['strength'];
    if (strength is int) {
      imports.add('com.mongodb.client.model.CollationStrength');
      b.write('.collationStrength(CollationStrength.fromInt($strength))');
    }
    if (c['caseLevel'] is bool) b.write('.caseLevel(${c['caseLevel']})');
    if (c['numericOrdering'] is bool) {
      b.write('.numericOrdering(${c['numericOrdering']})');
    }
    return '$b.build()';
  }

  String _wrap(Namespace ns, String type, String body) {
    imports
      ..add('com.mongodb.client.MongoClient')
      ..add('com.mongodb.client.MongoClients')
      ..add('com.mongodb.client.MongoCollection')
      ..add('org.bson.Document')
      ..add('com.mongodb.client.$type');
    final lines = imports.map((i) => 'import $i;').toList()..sort();
    return '${lines.join('\n')}\n\n'
        'public class Query {\n'
        '  public static void main(String[] args) {\n'
        '    try (MongoClient client = MongoClients.create("$_uriPlaceholder")) {\n'
        '      MongoCollection<Document> collection = client\n'
        '          .getDatabase(${_q(ns.db)})\n'
        '          .getCollection(${_q(ns.collection)});\n\n'
        '${body.split('\n').map((l) => l.isEmpty ? l : '      $l').join('\n')}\n'
        '    }\n'
        '  }\n'
        '}\n';
  }

  @override
  String find(Namespace ns, CodeQuery q) {
    final b = StringBuffer('Document filter = ${lit(q.filter, 0)};\n\n');
    b.write('FindIterable<Document> result = collection.find(filter)');
    if (q.projection != null) b.write('\n    .projection(${lit(q.projection, 1)})');
    if (q.sort != null) b.write('\n    .sort(${lit(q.sort, 1)})');
    if (q.skip > 0) b.write('\n    .skip(${q.skip})');
    if (q.limit != null) b.write('\n    .limit(${q.limit})');
    if (q.collation != null) b.write('\n    .collation(${collation(q.collation!)})');
    final hint = q.hint;
    if (hint is String) b.write('\n    .hintString(${_q(hint)})');
    if (hint is Map) b.write('\n    .hint(${lit(hint, 1)})');
    if (q.maxTimeMs != null) {
      imports.add('java.util.concurrent.TimeUnit');
      b.write('\n    .maxTime(${q.maxTimeMs}, TimeUnit.MILLISECONDS)');
    }
    b.write(';\n\nfor (Document doc : result) {\n  System.out.println(doc.toJson());\n}');
    return _wrap(ns, 'FindIterable', b.toString());
  }

  @override
  String aggregate(Namespace ns, List<Map<String, dynamic>> p,
      Map<String, dynamic>? collation, int? maxTimeMs) {
    imports
      ..add('java.util.List')
      ..add('java.util.Arrays');
    final stages = p.map((s) => '    ${lit(s, 2)}').join(',\n');
    final b = StringBuffer(
        'List<Document> pipeline = Arrays.asList(\n$stages);\n\n'
        'AggregateIterable<Document> result = collection.aggregate(pipeline)');
    if (collation != null) b.write('\n    .collation(${this.collation(collation)})');
    if (maxTimeMs != null) {
      imports.add('java.util.concurrent.TimeUnit');
      b.write('\n    .maxTime($maxTimeMs, TimeUnit.MILLISECONDS)');
    }
    b.write(';\n\nfor (Document doc : result) {\n  System.out.println(doc.toJson());\n}');
    return _wrap(ns, 'AggregateIterable', b.toString());
  }
}

class _CSharp extends _Gen {
  @override
  String lit(Object? v, int depth) {
    if (v is Map) {
      if (v.isEmpty) return 'new BsonDocument()';
      final inner = v.entries
          .map((e) => '${pad(depth + 1)}{ ${_q('${e.key}')}, ${lit(e.value, depth + 1)} }')
          .join(',\n');
      return 'new BsonDocument\n${pad(depth)}{\n$inner\n${pad(depth)}}';
    }
    if (v is List) {
      if (v.isEmpty) return 'new BsonArray()';
      final inner = v.map((e) => '${pad(depth + 1)}${lit(e, depth + 1)}').join(',\n');
      return 'new BsonArray\n${pad(depth)}{\n$inner\n${pad(depth)}}';
    }
    return switch (v) {
      null => 'BsonNull.Value',
      bool() => v ? 'true' : 'false',
      int() => '$v',
      double() => v.isNaN
          ? 'double.NaN'
          : v.isInfinite
          ? (v > 0 ? 'double.PositiveInfinity' : 'double.NegativeInfinity')
          : '${_num(v)}d',
      String() => _q(v),
      BsonLong() => '${v.value}L',
      Decimal128() => 'Decimal128.Parse("$v")',
      ObjectId() => 'new ObjectId("${v.hex}")',
      DateTime() =>
        'new BsonDateTime(DateTime.Parse("${_iso(v)}", null, System.Globalization.DateTimeStyles.RoundtripKind))',
      BsonDate() => 'new BsonDateTime(${v.millis}L)',
      BsonBinary(isUuid: true) =>
        'new BsonBinaryData(Guid.Parse("${v.uuidString}"), GuidRepresentation.Standard)',
      BsonBinary() =>
        'new BsonBinaryData(Convert.FromBase64String("${base64.encode(v.data)}"), (BsonBinarySubType)${v.subtype})',
      BsonRegex() => 'new BsonRegularExpression(${_q(v.pattern)}, ${_q(v.options)})',
      BsonTimestamp() => 'new BsonTimestamp(${v.seconds}, ${v.increment})',
      BsonCode() => 'new BsonJavaScript(${_q(v.code)})',
      BsonMinKey() => 'BsonMinKey.Value',
      BsonMaxKey() => 'BsonMaxKey.Value',
      BsonUndefined() => 'BsonUndefined.Value',
      BsonSymbol() => _q(v.value),
      _ => _q(EJson.stringify(v, pretty: false)),
    };
  }

  static const _strengths = {
    1: 'Primary',
    2: 'Secondary',
    3: 'Tertiary',
    4: 'Quaternary',
    5: 'Identical',
  };

  String collation(Map<String, dynamic> c) {
    final s = _strengths[c['strength']];
    return 'new Collation(${_q('${c['locale']}')}'
        '${s == null ? '' : ', strength: CollationStrength.$s'})';
  }

  String _wrap(Namespace ns, String body) =>
      'using MongoDB.Bson;\n'
      'using MongoDB.Driver;\n\n'
      'var client = new MongoClient("$_uriPlaceholder");\n'
      'var collection = client\n'
      '    .GetDatabase(${_q(ns.db)})\n'
      '    .GetCollection<BsonDocument>(${_q(ns.collection)});\n\n'
      '$body';

  @override
  String find(Namespace ns, CodeQuery q) {
    final opts = <String>[
      if (q.collation != null) 'Collation = ${collation(q.collation!)}',
      if (q.hint != null) 'Hint = ${q.hint is String ? _q(q.hint as String) : lit(q.hint, 1)}',
      if (q.maxTimeMs != null) 'MaxTime = TimeSpan.FromMilliseconds(${q.maxTimeMs})',
    ];
    final b = StringBuffer('var filter = ${lit(q.filter, 0)};\n\n');
    b.write('var result = collection.Find(filter');
    if (opts.isNotEmpty) {
      b.write(', new FindOptions\n{\n    ${opts.join(',\n    ')}\n}');
    }
    b.write(')');
    if (q.projection != null) b.write('\n    .Project(${lit(q.projection, 1)})');
    if (q.sort != null) b.write('\n    .Sort(${lit(q.sort, 1)})');
    if (q.skip > 0) b.write('\n    .Skip(${q.skip})');
    if (q.limit != null) b.write('\n    .Limit(${q.limit})');
    b.write('\n    .ToList();\n');
    return _wrap(ns, b.toString());
  }

  @override
  String aggregate(Namespace ns, List<Map<String, dynamic>> p,
      Map<String, dynamic>? collation, int? maxTimeMs) {
    final stages = p.map((s) => '    ${lit(s, 1)}').join(',\n');
    final opts = <String>[
      if (collation != null) 'Collation = ${this.collation(collation)}',
      if (maxTimeMs != null) 'MaxTime = TimeSpan.FromMilliseconds($maxTimeMs)',
    ];
    return _wrap(
      ns,
      'var pipeline = new BsonDocument[]\n{\n$stages\n};\n\n'
      'var result = collection.Aggregate<BsonDocument>(pipeline'
      '${opts.isEmpty ? '' : ', new AggregateOptions\n{\n    ${opts.join(',\n    ')}\n}'}'
      ').ToList();\n',
    );
  }
}

class _Go extends _Gen {
  final helpers = <String>{};

  static const _helperCode = {
    'oid': 'func oid(hex string) bson.ObjectID {\n'
        '\tid, err := bson.ObjectIDFromHex(hex)\n'
        '\tif err != nil {\n\t\tpanic(err)\n\t}\n'
        '\treturn id\n}',
    'date': 'func date(iso string) bson.DateTime {\n'
        '\tt, err := time.Parse(time.RFC3339Nano, iso)\n'
        '\tif err != nil {\n\t\tpanic(err)\n\t}\n'
        '\treturn bson.NewDateTimeFromTime(t)\n}',
    'dec': 'func dec(s string) bson.Decimal128 {\n'
        '\td, err := bson.ParseDecimal128(s)\n'
        '\tif err != nil {\n\t\tpanic(err)\n\t}\n'
        '\treturn d\n}',
    'b64': 'func b64(s string) []byte {\n'
        '\tb, err := base64.StdEncoding.DecodeString(s)\n'
        '\tif err != nil {\n\t\tpanic(err)\n\t}\n'
        '\treturn b\n}',
  };

  @override
  String lit(Object? v, int depth) {
    if (v is Map) {
      if (v.isEmpty) return 'bson.D{}';
      final inner = v.entries
          .map((e) =>
              '${pad(depth + 1)}{Key: ${_q('${e.key}')}, Value: ${lit(e.value, depth + 1)}},')
          .join('\n');
      return 'bson.D{\n$inner\n${pad(depth)}}';
    }
    if (v is List) {
      if (v.isEmpty) return 'bson.A{}';
      final inner = v.map((e) => '${pad(depth + 1)}${lit(e, depth + 1)},').join('\n');
      return 'bson.A{\n$inner\n${pad(depth)}}';
    }
    String helper(String name, String code) {
      helpers.add(name);
      return code;
    }

    return switch (v) {
      null => 'nil',
      bool() => '$v',
      int() => 'int32($v)',
      double() => v.isNaN
          ? 'math.NaN()'
          : v.isInfinite
          ? 'math.Inf(${v > 0 ? 1 : -1})'
          : _num(v),
      String() => _q(v),
      BsonLong() => 'int64(${v.value})',
      Decimal128() => helper('dec', 'dec("$v")'),
      ObjectId() => helper('oid', 'oid("${v.hex}")'),
      DateTime() => helper('date', 'date("${_iso(v)}")'),
      BsonDate() => 'bson.DateTime(${v.millis})',
      BsonBinary() => helper(
        'b64',
        'bson.Binary{Subtype: ${v.subtype}, Data: b64("${base64.encode(v.data)}")}',
      ),
      BsonRegex() => 'bson.Regex{Pattern: ${_q(v.pattern)}, Options: ${_q(v.options)}}',
      BsonTimestamp() => 'bson.Timestamp{T: ${v.seconds}, I: ${v.increment}}',
      BsonCode() => 'bson.JavaScript(${_q(v.code)})',
      BsonMinKey() => 'bson.MinKey{}',
      BsonMaxKey() => 'bson.MaxKey{}',
      BsonUndefined() => 'bson.Undefined{}',
      BsonSymbol() => _q(v.value),
      _ => _q(EJson.stringify(v, pretty: false)),
    };
  }

  String collation(Map<String, dynamic> c) {
    final strength = c['strength'];
    return '&options.Collation{Locale: ${_q('${c['locale']}')}'
        '${strength is int ? ', Strength: $strength' : ''}}';
  }

  String _wrap(String body, int? maxTimeMs) {
    final usesMath = body.contains('math.');
    final importSet = <String>{
      '"context"',
      '"fmt"',
      if (helpers.contains('b64')) '"encoding/base64"',
      if (usesMath) '"math"',
      if (helpers.contains('date') || maxTimeMs != null) '"time"',
      '"go.mongodb.org/mongo-driver/v2/bson"',
      '"go.mongodb.org/mongo-driver/v2/mongo"',
      '"go.mongodb.org/mongo-driver/v2/mongo/options"',
    };
    final ctx = maxTimeMs == null
        ? '\tctx := context.Background()\n'
        : '\tctx, cancel := context.WithTimeout(context.Background(), $maxTimeMs*time.Millisecond)\n'
              '\tdefer cancel()\n';
    final helperCode =
        (helpers.toList()..sort()).map((h) => '\n${_helperCode[h]}\n').join();
    return 'package main\n\n'
        'import (\n${importSet.map((i) => '\t$i').join('\n')}\n)\n\n'
        'func main() {\n'
        '$ctx'
        '\tclient, err := mongo.Connect(options.Client().ApplyURI("$_uriPlaceholder"))\n'
        '\tif err != nil {\n\t\tpanic(err)\n\t}\n'
        '\tdefer client.Disconnect(ctx)\n\n'
        '${body.split('\n').map((l) => l.isEmpty ? l : '\t$l').join('\n')}\n'
        '\tvar docs []bson.M\n'
        '\tif err := cursor.All(ctx, &docs); err != nil {\n\t\tpanic(err)\n\t}\n'
        '\tfmt.Println(docs)\n'
        '}\n'
        '$helperCode';
  }

  @override
  String find(Namespace ns, CodeQuery q) {
    final b = StringBuffer('coll := client.Database(${_q(ns.db)}).Collection(${_q(ns.collection)})\n');
    b.write('filter := ${lit(q.filter, 0)}\n');
    b.write('opts := options.Find()');
    if (q.projection != null) b.write('.\n\tSetProjection(${lit(q.projection, 1)})');
    if (q.sort != null) b.write('.\n\tSetSort(${lit(q.sort, 1)})');
    if (q.skip > 0) b.write('.\n\tSetSkip(${q.skip})');
    if (q.limit != null) b.write('.\n\tSetLimit(${q.limit})');
    if (q.collation != null) b.write('.\n\tSetCollation(${collation(q.collation!)})');
    if (q.hint != null) b.write('.\n\tSetHint(${lit(q.hint, 1)})');
    b.write('\ncursor, err := coll.Find(ctx, filter, opts)\n');
    b.write('if err != nil {\n\tpanic(err)\n}');
    return _wrap(b.toString(), q.maxTimeMs);
  }

  @override
  String aggregate(Namespace ns, List<Map<String, dynamic>> p,
      Map<String, dynamic>? collation, int? maxTimeMs) {
    final stages = p.map((s) => '\t${lit(s, 1)},').join('\n');
    final b = StringBuffer('coll := client.Database(${_q(ns.db)}).Collection(${_q(ns.collection)})\n');
    b.write('pipeline := mongo.Pipeline{\n$stages\n}\n');
    b.write('opts := options.Aggregate()');
    if (collation != null) b.write('.SetCollation(${this.collation(collation)})');
    b.write('\ncursor, err := coll.Aggregate(ctx, pipeline, opts)\n');
    b.write('if err != nil {\n\tpanic(err)\n}');
    return _wrap(b.toString(), maxTimeMs);
  }
}
