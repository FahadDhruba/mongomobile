import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

final _token = RegExp(
  r'''"(?:[^"\\]|\\.)*"(\s*:)?|'(?:[^'\\]|\\.)*'|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|\b(?:true|false|null|undefined|NaN|Infinity)\b|\b[A-Z][A-Za-z0-9]*(?=\()|[A-Za-z_$][\w$.]*(?=\s*:)''',
);

/// Colours Extended JSON or shell-syntax text by token type. Texts longer
/// than [maxLength] are returned plain to keep typing responsive.
TextSpan highlightJson(String text, TextStyle base, AppColors c,
    {int maxLength = 200000}) {
  if (text.length > maxLength) return TextSpan(text: text, style: base);
  final spans = <TextSpan>[];
  var pos = 0;
  for (final m in _token.allMatches(text)) {
    if (m.start > pos) {
      spans.add(TextSpan(text: text.substring(pos, m.start)));
    }
    final t = m[0]!;
    Color color;
    if (t.startsWith('"') || t.startsWith("'")) {
      if (m[1] != null) {
        // A quoted key; colour "$oid"-style wrappers like values' types.
        final key = t.substring(0, t.length - m[1]!.length);
        final isWrapper = key.startsWith(r'"$');
        spans.add(TextSpan(
            text: key,
            style: TextStyle(color: isWrapper ? c.muted : c.key)));
        spans.add(TextSpan(text: m[1]));
        pos = m.end;
        continue;
      }
      color = c.string;
    } else if (RegExp(r'^-?\d').hasMatch(t)) {
      color = c.number;
    } else if (t == 'true' || t == 'false') {
      color = c.boolean;
    } else if (t == 'null' || t == 'undefined') {
      color = c.nullValue;
    } else if (t == 'NaN' || t == 'Infinity') {
      color = c.number;
    } else if (RegExp('^[A-Z]').hasMatch(t) && !text.startsWith(':', m.end)) {
      color = t == 'ObjectId' ? c.objectId : c.date;
    } else {
      color = c.key;
    }
    spans.add(TextSpan(text: t, style: TextStyle(color: color)));
    pos = m.end;
  }
  if (pos < text.length) spans.add(TextSpan(text: text.substring(pos)));
  return TextSpan(style: base, children: spans);
}

/// A text controller that highlights its JSON content while editing.
class JsonEditingController extends TextEditingController {
  JsonEditingController({super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final base = style ?? monoStyle(context);
    if (withComposing && value.isComposingRangeValid) {
      return super.buildTextSpan(
          context: context, style: style, withComposing: withComposing);
    }
    return highlightJson(text, base, context.colors, maxLength: 100000);
  }
}

/// `{ a: 1, b: -1 }` for small documents like index keys.
String shellDocument(Map<String, dynamic> doc) {
  final ident = RegExp(r'^[A-Za-z_$][\w$]*$');
  final parts = doc.entries.map((e) {
    final k = ident.hasMatch(e.key) ? e.key : "'${e.key}'";
    final v = e.value is String ? "'${e.value}'" : '${e.value}';
    return '$k: $v';
  });
  return '{ ${parts.join(', ')} }';
}
