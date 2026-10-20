import 'package:mongo_wire/mongo_wire.dart';

/// Per-field statistics for a sample of documents, the way Compass's Schema
/// tab shows them: how often each field appears, its types, and a summary
/// of its values per type.
class SchemaField {
  SchemaField(this.name, this.path);

  final String name;

  /// Dotted path from the document root; array items add no segment, so
  /// `items.sku` is the `sku` inside the documents of `items`.
  final String path;

  /// Parent objects (documents) that have this field.
  int count = 0;

  /// Type name (as `bsonTypeName` gives it) → statistics.
  final Map<String, TypeStats> types = {};

  /// Types sorted by how often they occur.
  List<TypeStats> get sortedTypes =>
      types.values.toList()..sort((a, b) => b.count.compareTo(a.count));
}

class TypeStats {
  TypeStats(this.name);

  final String name;
  int count = 0;

  /// Up to [SchemaAnalysis.maxValues] values seen, for summaries.
  final List<Object?> values = [];

  /// For documents (and documents inside arrays): their fields.
  final Map<String, SchemaField> fields = {};

  /// How many documents were looked into for [fields].
  int documents = 0;

  /// For arrays: their lengths and the types of their items.
  final List<int> lengths = [];
  final Map<String, TypeStats> itemTypes = {};

  List<SchemaField> get sortedFields => _byCount(fields.values);
}

/// Most frequent first; ties keep first-seen order.
List<SchemaField> _byCount(Iterable<SchemaField> fields) {
  final list = fields.toList();
  final order = {for (var i = 0; i < list.length; i++) list[i]: i};
  return list..sort((a, b) {
    final byCount = b.count.compareTo(a.count);
    return byCount != 0 ? byCount : order[a]!.compareTo(order[b]!);
  });
}

class SchemaAnalysis {
  SchemaAnalysis._(this.documents, this.fields);

  static const maxValues = 500;

  /// How many documents were analysed.
  final int documents;
  final Map<String, SchemaField> fields;

  /// Top-level fields, most frequent first, `_id` at the top.
  List<SchemaField> get sortedFields {
    final list = _byCount(fields.values);
    final id = list.indexWhere((f) => f.name == '_id');
    if (id > 0) list.insert(0, list.removeAt(id));
    return list;
  }

  factory SchemaAnalysis.of(List<Map<String, dynamic>> docs) {
    final root = TypeStats('Object');
    for (final d in docs) {
      _addDocument(root, d, '');
    }
    return SchemaAnalysis._(docs.length, root.fields);
  }

  static void _addDocument(TypeStats into, Map doc, String path) {
    into.documents++;
    for (final MapEntry(:key, :value) in doc.entries) {
      final name = '$key';
      final field = into.fields.putIfAbsent(
        name,
        () => SchemaField(name, path.isEmpty ? name : '$path.$name'),
      );
      field.count++;
      _addValue(field.types, value, field.path);
    }
  }

  static void _addValue(Map<String, TypeStats> types, Object? v, String path) {
    final t = types.putIfAbsent(
      bsonTypeName(v),
      () => TypeStats(bsonTypeName(v)),
    );
    t.count++;
    if (v is Map) {
      _addDocument(t, v, path);
    } else if (v is List) {
      t.lengths.add(v.length);
      for (final item in v) {
        _addValue(t.itemTypes, item, path);
      }
    } else if (t.values.length < maxValues) {
      t.values.add(v);
    }
  }
}

/// A value and how many times it was seen.
typedef ValueCount = ({Object? value, int count});

/// The most common values, most frequent first.
List<ValueCount> topValues(List<Object?> values, {int limit = 5}) {
  final counts = <String, ValueCount>{};
  for (final v in values) {
    final key = EJson.stringify(v, pretty: false);
    final prev = counts[key];
    counts[key] = (value: v, count: (prev?.count ?? 0) + 1);
  }
  final list = counts.values.toList()
    ..sort((a, b) => b.count.compareTo(a.count));
  return list.take(limit).toList();
}

/// How many distinct values there are.
int distinctCount(List<Object?> values) =>
    {for (final v in values) EJson.stringify(v, pretty: false)}.length;

/// A number for numeric BSON values, else null.
double? numericValue(Object? v) => switch (v) {
  int() => v.toDouble(),
  double() => v,
  BsonLong() => v.value.toDouble(),
  Decimal128() => double.tryParse(v.toString()),
  DateTime() => v.millisecondsSinceEpoch.toDouble(),
  ObjectId() => v.timestamp.millisecondsSinceEpoch.toDouble(),
  _ => null,
};

/// Counts of [values] in [bins] equal-width buckets between their minimum
/// and maximum (NaN and infinities left out).
List<int> histogram(List<double> values, {int bins = 12}) {
  final finite = values.where((v) => v.isFinite).toList();
  if (finite.isEmpty) return const [];
  var lo = finite.first;
  var hi = finite.first;
  for (final v in finite) {
    if (v < lo) lo = v;
    if (v > hi) hi = v;
  }
  final out = List.filled(bins, 0);
  if (hi == lo) {
    out[0] = finite.length;
    return out;
  }
  for (final v in finite) {
    var i = ((v - lo) / (hi - lo) * bins).floor();
    if (i >= bins) i = bins - 1;
    out[i]++;
  }
  return out;
}

const _jsonSchemaTypes = {
  'String': 'string',
  'Int32': 'int',
  'Int64': 'long',
  'Double': 'double',
  'Decimal128': 'decimal',
  'Boolean': 'bool',
  'Date': 'date',
  'ObjectId': 'objectId',
  'Null': 'null',
  'Object': 'object',
  'Array': 'array',
  'Binary': 'binData',
  'UUID': 'binData',
  'BSONRegExp': 'regex',
  'Timestamp': 'timestamp',
  'Code': 'javascript',
  'Symbol': 'symbol',
  'MinKey': 'minKey',
  'MaxKey': 'maxKey',
  'Undefined': 'undefined',
  'DBPointer': 'dbPointer',
};

/// A `$jsonSchema` validator describing the sampled documents: the types
/// seen for each field, nested documents and arrays of documents, and the
/// fields present in every sampled document as `required`.
Map<String, dynamic> jsonSchemaOf(SchemaAnalysis analysis) => {
  r'$jsonSchema': _objectSchema(analysis.sortedFields, analysis.documents),
};

Map<String, dynamic> _objectSchema(List<SchemaField> fields, int documents) {
  final required = [
    for (final f in fields)
      if (f.count == documents && documents > 0) f.name,
  ];
  return {
    'bsonType': 'object',
    if (required.isNotEmpty) 'required': required,
    'properties': {for (final f in fields) f.name: _fieldSchema(f.sortedTypes)},
  };
}

Map<String, dynamic> _fieldSchema(List<TypeStats> types) {
  final names = <String>[];
  for (final t in types) {
    final n = _jsonSchemaTypes[t.name];
    if (n != null && !names.contains(n)) names.add(n);
  }
  final out = <String, dynamic>{
    'bsonType': names.length == 1 ? names.single : names,
  };
  for (final t in types) {
    if (t.name == 'Object' && t.fields.isNotEmpty) {
      final nested = _objectSchema(t.sortedFields, t.documents);
      if (nested['required'] case final r?) out['required'] = r;
      out['properties'] = nested['properties'];
    } else if (t.name == 'Array' && t.itemTypes.isNotEmpty) {
      out['items'] = _fieldSchema(
        t.itemTypes.values.toList()..sort((a, b) => b.count.compareTo(a.count)),
      );
    }
  }
  return out;
}
