import 'dart:convert';

import '../bson/types.dart';

/// Output styles for [EJson.stringify].
enum EJsonMode {
  /// MongoDB Extended JSON v2, canonical: every number carries its type.
  canonical,

  /// MongoDB Extended JSON v2, relaxed: numbers and recent dates are plain.
  /// Int32, Int64 and integral doubles become indistinguishable.
  relaxed,

  /// Relaxed, except that Int64 values stay wrapped in `$numberLong`,
  /// doubles always have a decimal point and UUIDs use `$uuid`. Parsing
  /// the output gives back exactly the same BSON types, which makes it the
  /// format used by the document editor.
  editable,
}

/// Writes Dart BSON values as Extended JSON.
class EJsonWriter {
  EJsonWriter({this.mode = EJsonMode.editable, this.indent = '  '});

  final EJsonMode mode;

  /// Indentation per level. Use an empty string for single-line output.
  final String indent;

  String write(Object? value) {
    final sb = StringBuffer();
    _value(sb, value, 0);
    return sb.toString();
  }

  bool get _pretty => indent.isNotEmpty;

  void _newline(StringBuffer sb, int depth) {
    if (!_pretty) return;
    sb.write('\n');
    for (var i = 0; i < depth; i++) {
      sb.write(indent);
    }
  }

  void _object(StringBuffer sb, Map<dynamic, dynamic> map, int depth) {
    if (map.isEmpty) {
      sb.write('{}');
      return;
    }
    sb.write('{');
    var first = true;
    map.forEach((k, v) {
      if (!first) sb.write(',');
      first = false;
      _newline(sb, depth + 1);
      sb.write(jsonEncode(k.toString()));
      sb.write(_pretty ? ': ' : ':');
      _value(sb, v, depth + 1);
    });
    _newline(sb, depth);
    sb.write('}');
  }

  void _array(StringBuffer sb, List<dynamic> list, int depth) {
    if (list.isEmpty) {
      sb.write('[]');
      return;
    }
    sb.write('[');
    for (var i = 0; i < list.length; i++) {
      if (i > 0) sb.write(',');
      _newline(sb, depth + 1);
      _value(sb, list[i], depth + 1);
    }
    _newline(sb, depth);
    sb.write(']');
  }

  /// Writes a one-key wrapper object such as `{"$oid": "..."}` on one line.
  void _wrap(StringBuffer sb, String key, Object? inner) {
    sb.write('{');
    sb.write(jsonEncode(key));
    sb.write(_pretty ? ': ' : ':');
    sb.write(_inline(inner));
    sb.write('}');
  }

  String _inline(Object? v) {
    if (v is Map) {
      final parts = v.entries.map((e) =>
          '${jsonEncode(e.key)}${_pretty ? ': ' : ':'}${_inline(e.value)}');
      return '{${parts.join(_pretty ? ', ' : ',')}}';
    }
    return jsonEncode(v);
  }

  void _value(StringBuffer sb, Object? v, int depth) {
    switch (v) {
      case null:
        sb.write('null');
      case bool():
        sb.write(v ? 'true' : 'false');
      case String():
        sb.write(jsonEncode(v));
      case int():
        if (mode == EJsonMode.canonical) {
          _wrap(sb, r'$numberInt', '$v');
        } else {
          sb.write('$v');
        }
      case double():
        if (v.isNaN || v.isInfinite || mode == EJsonMode.canonical) {
          _wrap(sb, r'$numberDouble', formatDouble(v));
        } else {
          sb.write(formatDouble(v));
        }
      case BsonLong():
        if (mode == EJsonMode.relaxed) {
          sb.write('${v.value}');
        } else {
          _wrap(sb, r'$numberLong', '${v.value}');
        }
      case Decimal128():
        _wrap(sb, r'$numberDecimal', v.toString());
      case ObjectId():
        _wrap(sb, r'$oid', v.hex);
      case DateTime():
        final ms = v.millisecondsSinceEpoch;
        if (mode != EJsonMode.canonical && v.year >= 1970 && v.year <= 9999) {
          _wrap(sb, r'$date', formatIsoDate(v));
        } else {
          _wrap(sb, r'$date', {r'$numberLong': '$ms'});
        }
      case BsonDate():
        _wrap(sb, r'$date', {r'$numberLong': '${v.millis}'});
      case BsonBinary():
        if (mode == EJsonMode.editable && v.isUuid) {
          _wrap(sb, r'$uuid', v.uuidString);
        } else {
          _wrap(sb, r'$binary', {
            'base64': base64.encode(v.data),
            'subType': v.subtype.toRadixString(16).padLeft(2, '0'),
          });
        }
      case BsonTimestamp():
        _wrap(sb, r'$timestamp', {'t': v.seconds, 'i': v.increment});
      case BsonRegex():
        _wrap(sb, r'$regularExpression',
            {'pattern': v.pattern, 'options': v.options});
      case BsonCode(scope: null):
        _wrap(sb, r'$code', v.code);
      case BsonCode():
        sb.write('{');
        sb.write(jsonEncode(r'$code'));
        sb.write(_pretty ? ': ' : ':');
        sb.write(jsonEncode(v.code));
        sb.write(',');
        _newline(sb, depth + 1);
        sb.write(jsonEncode(r'$scope'));
        sb.write(_pretty ? ': ' : ':');
        _object(sb, v.scope!, depth + 1);
        sb.write('}');
      case BsonSymbol():
        _wrap(sb, r'$symbol', v.value);
      case BsonDbPointer():
        sb.write('{"\$dbPointer"${_pretty ? ': ' : ':'}{"\$ref"'
            '${_pretty ? ': ' : ':'}${jsonEncode(v.namespace)}'
            '${_pretty ? ', ' : ','}"\$id"${_pretty ? ': ' : ':'}');
        _wrap(sb, r'$oid', v.id.hex);
        sb.write('}}');
      case BsonUndefined():
        _wrap(sb, r'$undefined', true);
      case BsonMinKey():
        _wrap(sb, r'$minKey', 1);
      case BsonMaxKey():
        _wrap(sb, r'$maxKey', 1);
      case Map():
        _object(sb, v, depth);
      case List():
        _array(sb, v, depth);
      default:
        throw ArgumentError('Cannot write ${v.runtimeType} as Extended JSON');
    }
  }
}

/// Formats a double so that it always reads back as a double: integral
/// values keep a `.0`, and non-finite values use the EJSON spellings.
String formatDouble(double v) {
  if (v.isNaN) return 'NaN';
  if (v.isInfinite) return v > 0 ? 'Infinity' : '-Infinity';
  if (v == 0 && v.isNegative) return '-0.0';
  final s = v.toString();
  if (s.contains('.') || s.contains('e') || s.contains('E')) {
    return s.replaceFirst('e+', 'E+').replaceFirst('e-', 'E-');
  }
  return '$s.0';
}

/// ISO-8601 in UTC with milliseconds, e.g. `2024-05-01T12:00:00.000Z`.
String formatIsoDate(DateTime d) {
  final u = d.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  final y = u.year.toString().padLeft(4, '0');
  final ms = u.millisecond.toString().padLeft(3, '0');
  return '$y-${two(u.month)}-${two(u.day)}T${two(u.hour)}:${two(u.minute)}:'
      '${two(u.second)}.${ms}Z';
}
