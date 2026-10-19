import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mongo_wire/mongo_wire.dart';

import '../../theme/app_theme.dart';

/// Formats dates like Compass: `2024-05-01T12:00:00.000+00:00`.
String formatDate(DateTime d) =>
    formatIsoDate(d).replaceFirst(RegExp(r'Z$'), '+00:00');

String _quote(String s) => jsonEncode(s);

/// A one-line, shell-style rendering of a scalar value.
String shellRepr(Object? v) => switch (v) {
      null => 'null',
      String() => _quote(v),
      bool() => '$v',
      int() => '$v',
      double() => v.isNaN
          ? 'NaN'
          : v.isInfinite
              ? (v > 0 ? 'Infinity' : '-Infinity')
              : (v == v.truncateToDouble() && v.abs() < 1e16
                  ? v.toInt().toString()
                  : '$v'),
      BsonLong() => '${v.value}',
      Decimal128() => v.toString(),
      ObjectId() => "ObjectId('${v.hex}')",
      DateTime() => formatDate(v),
      BsonDate() => 'Date(${v.millis})',
      BsonBinary(isUuid: true) => "UUID('${v.uuidString}')",
      BsonBinary() =>
        "Binary.createFromBase64('${base64.encode(v.data)}', ${v.subtype})",
      BsonRegex() => '/${v.pattern}/${v.options}',
      BsonTimestamp() => 'Timestamp({ t: ${v.seconds}, i: ${v.increment} })',
      BsonCode(scope: null) => "Code('${v.code}')",
      BsonCode() => "Code('${v.code}', ${EJson.stringify(v.scope, pretty: false)})",
      BsonSymbol() => "Symbol('${v.value}')",
      BsonDbPointer() => "DBPointer('${v.namespace}', ObjectId('${v.id.hex}'))",
      BsonUndefined() => 'undefined',
      BsonMinKey() => 'MinKey()',
      BsonMaxKey() => 'MaxKey()',
      Map() => 'Object',
      List() => 'Array (${v.length})',
      _ => '$v',
    };

/// The colour for a value of this type.
Color typeColor(AppColors c, Object? v) => switch (v) {
      null || BsonUndefined() => c.nullValue,
      String() || BsonSymbol() => c.string,
      int() || double() || BsonLong() || Decimal128() => c.number,
      bool() => c.boolean,
      DateTime() || BsonDate() || BsonTimestamp() => c.date,
      ObjectId() => c.objectId,
      Map() || List() => c.muted,
      _ => c.other,
    };

/// A scalar value, cut to [previewLength] characters with a "show more"
/// control for long text.
class ScalarValue extends StatefulWidget {
  const ScalarValue(this.value, {super.key, required this.previewLength});

  final Object? value;
  final int previewLength;

  @override
  State<ScalarValue> createState() => _ScalarValueState();
}

class _ScalarValueState extends State<ScalarValue> {
  int _shown = 0;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final text = shellRepr(widget.value);
    final limit = _shown == 0 ? widget.previewLength : _shown;
    final cut = text.length > limit;
    final style = monoStyle(context,
        size: 12.5,
        color: typeColor(c, widget.value)).copyWith(
      fontStyle: widget.value == null ? FontStyle.italic : null,
    );
    if (!cut) return Text(text, style: style);
    final more = (text.length - limit);
    return Text.rich(TextSpan(children: [
      TextSpan(text: '${text.substring(0, limit)}…', style: style),
      WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: InkWell(
          onTap: () => setState(() => _shown = limit * 4 > text.length
              ? text.length
              : limit * 4),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Text('show more (${more < 1000 ? more : '${more ~/ 1000}K'} chars)',
                style: TextStyle(
                    fontSize: 11.5, color: c.accent, fontWeight: FontWeight.w600)),
          ),
        ),
      ),
    ]));
  }
}
