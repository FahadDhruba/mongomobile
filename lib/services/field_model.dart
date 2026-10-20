import 'package:mongo_wire/mongo_wire.dart';

/// Types offered in the field editor's type picker.
enum FieldType {
  string('String'),
  int32('Int32'),
  int64('Int64'),
  double_('Double'),
  decimal('Decimal128'),
  boolean('Boolean'),
  date('Date'),
  objectId('ObjectId'),
  null_('Null'),
  object('Object'),
  array('Array'),

  /// Binary, regex, timestamp and other types kept as they are; they can be
  /// changed in the JSON editor.
  other('Other');

  const FieldType(this.label);
  final String label;

  bool get isContainer => this == object || this == array;

  /// Types the user can switch to.
  static const choices = [
    string,
    int32,
    int64,
    double_,
    decimal,
    boolean,
    date,
    objectId,
    null_,
    object,
    array,
  ];
}

FieldType typeOf(Object? v) => switch (v) {
  null => FieldType.null_,
  String() => FieldType.string,
  bool() => FieldType.boolean,
  int() => FieldType.int32,
  BsonLong() => FieldType.int64,
  double() => FieldType.double_,
  Decimal128() => FieldType.decimal,
  DateTime() => FieldType.date,
  ObjectId() => FieldType.objectId,
  Map() => FieldType.object,
  List() => FieldType.array,
  _ => FieldType.other,
};

/// The text a scalar shows in the value input.
String textOf(Object? v) => switch (v) {
  null => '',
  String() => v,
  bool() => '$v',
  int() => '$v',
  BsonLong() => '${v.value}',
  double() => formatDouble(v),
  Decimal128() => v.toString(),
  DateTime() => formatIsoDate(v),
  ObjectId() => v.hex,
  _ => EJson.stringify(v, pretty: false),
};

/// One field (or array element) in the editor.
class FieldNode {
  FieldNode({
    required this.key,
    required this.type,
    this.text = '',
    List<FieldNode>? children,
    this.original,
    this.expanded = true,
  }) : children = children ?? [];

  factory FieldNode.fromValue(String key, Object? value) {
    final type = typeOf(value);
    return FieldNode(
      key: key,
      type: type,
      text: type.isContainer || type == FieldType.other ? '' : textOf(value),
      children: switch (value) {
        Map() => [
          for (final e in value.entries)
            FieldNode.fromValue('${e.key}', e.value),
        ],
        List() => [
          for (var i = 0; i < value.length; i++)
            FieldNode.fromValue('$i', value[i]),
        ],
        _ => null,
      },
      original: type == FieldType.other ? value : null,
      expanded: value is! Map && value is! List || _small(value),
    );
  }

  static bool _small(Object? v) =>
      (v is Map && v.length <= 8) || (v is List && v.length <= 8);

  String key;
  FieldType type;

  /// The scalar value as typed.
  String text;
  final List<FieldNode> children;

  /// The untouched value of an [FieldType.other] field.
  Object? original;
  bool expanded;

  /// Bumped whenever [text] is replaced rather than typed, so the value
  /// input rebuilds with it.
  int revision = 0;

  /// Converts the typed text into a value of [type]. Throws
  /// [FormatException] with a short reason.
  Object? value() {
    final t = text.trim();
    switch (type) {
      case FieldType.string:
        return text;
      case FieldType.int32:
        final v = int.tryParse(t);
        if (v == null || v < -0x80000000 || v > 0x7fffffff) {
          throw const FormatException('Enter a whole number (32-bit)');
        }
        return v;
      case FieldType.int64:
        final v = int.tryParse(t);
        if (v == null) throw const FormatException('Enter a whole number');
        return BsonLong(v);
      case FieldType.double_:
        final v = switch (t) {
          'NaN' => double.nan,
          'Infinity' => double.infinity,
          '-Infinity' => double.negativeInfinity,
          _ => double.tryParse(t),
        };
        if (v == null) throw const FormatException('Enter a number');
        return v;
      case FieldType.decimal:
        try {
          return Decimal128.parse(t);
        } on FormatException {
          throw const FormatException('Enter a decimal number');
        }
      case FieldType.boolean:
        if (t == 'true') return true;
        if (t == 'false') return false;
        throw const FormatException('Enter true or false');
      case FieldType.date:
        try {
          return parseIsoDate(t);
        } on FormatException {
          throw const FormatException(
            'Enter an ISO date, e.g. 2024-05-01T12:00:00Z',
          );
        }
      case FieldType.objectId:
        if (!ObjectId.isValidHex(t)) {
          throw const FormatException('Enter 24 hex characters');
        }
        return ObjectId.parse(t);
      case FieldType.null_:
        return null;
      case FieldType.object:
        final out = <String, dynamic>{};
        for (final c in children) {
          if (c.key.isEmpty) throw const FormatException('A field has no name');
          if (out.containsKey(c.key)) {
            throw FormatException('"${c.key}" appears twice');
          }
          out[c.key] = c.value();
        }
        return out;
      case FieldType.array:
        return [for (final c in children) c.value()];
      case FieldType.other:
        return original;
    }
  }

  /// The first problem in this subtree, as `path: reason`.
  String? error([String path = '']) {
    final here = path.isEmpty ? key : '$path.$key';
    if (type.isContainer) {
      final seen = <String>{};
      for (final c in children) {
        if (type == FieldType.object) {
          if (c.key.isEmpty) return '$here: a field has no name';
          if (!seen.add(c.key)) return '$here: "${c.key}" appears twice';
        }
        final e = c.error(here);
        if (e != null) return e;
      }
      return null;
    }
    try {
      value();
      return null;
    } on FormatException catch (e) {
      return '$here: ${e.message}';
    }
  }

  /// Switches to [next], keeping as much of the value as possible: numbers
  /// and dates convert, a scalar becomes the first array element, and so on.
  void changeType(FieldType next) {
    if (next == type) return;
    Object? current;
    try {
      current = value();
    } on FormatException {
      current = text;
    }
    final prev = type;
    type = next;
    revision++;
    original = null;
    if (next == FieldType.object) {
      if (prev != FieldType.array) children.clear();
      for (var i = 0; i < children.length; i++) {
        children[i].key = 'field$i';
      }
      text = '';
    } else if (next == FieldType.array) {
      if (prev == FieldType.object) {
        for (var i = 0; i < children.length; i++) {
          children[i].key = '$i';
        }
      } else {
        children
          ..clear()
          ..add(FieldNode.fromValue('0', current));
      }
      text = '';
    } else {
      children.clear();
      text = switch ((current, next)) {
        (null, _) => '',
        (bool b, FieldType.int32 || FieldType.int64) => b ? '1' : '0',
        (DateTime d, FieldType.int64) => '${d.millisecondsSinceEpoch}',
        (BsonLong n, FieldType.date) => formatIsoDate(
          DateTime.fromMillisecondsSinceEpoch(n.value, isUtc: true),
        ),
        (double d, FieldType.int32 || FieldType.int64) =>
          d.isFinite ? '${d.truncate()}' : '0',
        (ObjectId o, FieldType.date) => formatIsoDate(o.timestamp),
        (Map() || List(), _) => '',
        (final v, _) => textOf(v),
      };
      if (next == FieldType.boolean && text != 'true' && text != 'false') {
        text = 'false';
      }
      if (next == FieldType.objectId && !ObjectId.isValidHex(text.trim())) {
        text = ObjectId().hex;
      }
      if (next == FieldType.date && text.trim().isEmpty) {
        text = formatIsoDate(DateTime.now().toUtc());
      }
    }
    expanded = true;
  }

  /// Adds an empty child to an object or array.
  FieldNode addChild() {
    final child = FieldNode(
      key: type == FieldType.array ? '${children.length}' : '',
      type: FieldType.string,
    );
    children.add(child);
    expanded = true;
    return child;
  }

  void removeChild(FieldNode child) {
    children.remove(child);
    if (type == FieldType.array) {
      for (var i = 0; i < children.length; i++) {
        children[i].key = '$i';
      }
    }
  }
}

/// The root of a document being edited.
FieldNode documentNode(Map<String, dynamic> doc) =>
    FieldNode.fromValue('', doc)..expanded = true;
