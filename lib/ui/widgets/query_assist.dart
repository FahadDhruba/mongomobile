import 'package:flutter/services.dart';

/// Which query bar input a suggestion is for.
enum QueryField { filter, project, sort }

const _pairs = {'{': '}', '[': ']', '(': ')', '"': '"', "'": "'"};
const _closers = {'}', ']', ')', '"', "'"};

/// Closes brackets and quotes as they are typed, steps over a closer that
/// is already there, deletes an empty pair together, and wraps the first
/// character typed into an empty input in `{ }`, the way Compass does.
///
/// Only plain one-character edits at the cursor are touched; anything else
/// (paste, keyboard word replacement) passes through unchanged.
class QueryInputFormatter extends TextInputFormatter {
  QueryInputFormatter({this.wrapInBraces = true});

  final bool wrapInBraces;

  static bool _word(String c) => RegExp(r'[\w$\\]').hasMatch(c);

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final a = oldValue.text;
    final b = newValue.text;
    if (!oldValue.selection.isCollapsed || !newValue.selection.isCollapsed) {
      return newValue;
    }
    final oc = oldValue.selection.baseOffset;
    final nc = newValue.selection.baseOffset;
    if (oc < 0 || nc < 0 || oc > a.length) return newValue;

    // One character typed at the cursor.
    if (b.length == a.length + 1 &&
        nc == oc + 1 &&
        b.substring(0, oc) == a.substring(0, oc) &&
        b.substring(nc) == a.substring(oc)) {
      final ch = b[oc];
      final prev = oc > 0 ? a[oc - 1] : '';
      final next = oc < a.length ? a[oc] : '';

      if (wrapInBraces && a.trim().isEmpty && ch != '{' && ch.trim().isNotEmpty) {
        final closer = (ch == '"' || ch == "'") ? ch : '';
        final text = '{ $ch$closer }';
        return TextEditingValue(
            text: text, selection: const TextSelection.collapsed(offset: 3));
      }
      if (_closers.contains(ch) && next == ch) {
        // Step over the closer we inserted earlier.
        return oldValue.copyWith(
            selection: TextSelection.collapsed(offset: oc + 1),
            composing: TextRange.empty);
      }
      final closer = _pairs[ch];
      if (closer != null) {
        final isQuote = ch == '"' || ch == "'";
        if (isQuote && _word(prev)) return newValue;
        final nextOk = next.isEmpty ||
            next.trim().isEmpty ||
            const {'}', ']', ')', ',', ':'}.contains(next);
        if (!nextOk) return newValue;
        final text = b.substring(0, nc) + closer + b.substring(nc);
        return TextEditingValue(
            text: text, selection: TextSelection.collapsed(offset: nc));
      }
      return newValue;
    }

    // Backspace inside an empty pair removes both halves.
    if (b.length == a.length - 1 &&
        nc == oc - 1 &&
        oc < a.length &&
        b == a.substring(0, oc - 1) + a.substring(oc)) {
      final deleted = a[oc - 1];
      if (_pairs[deleted] == a[oc]) {
        return TextEditingValue(
          text: a.substring(0, oc - 1) + a.substring(oc + 1),
          selection: TextSelection.collapsed(offset: oc - 1),
        );
      }
    }
    return newValue;
  }
}

enum SuggestionKind { field, operator, value }

class Suggestion {
  const Suggestion(this.label, this.kind, {this.insert, this.cursorBack = 0});

  /// What the chip shows.
  final String label;
  final SuggestionKind kind;

  /// Text to insert for values; fields and operators get `: ` appended.
  final String? insert;

  /// How far before the end of [insert] to leave the cursor, e.g. inside
  /// the quotes of `ObjectId('')`.
  final int cursorBack;

  @override
  bool operator ==(Object other) =>
      other is Suggestion && other.label == label && other.kind == kind;

  @override
  int get hashCode => Object.hash(label, kind);

  @override
  String toString() => label;
}

/// Where the cursor is, for picking suggestions.
class QueryContext {
  const QueryContext({
    required this.start,
    required this.end,
    required this.token,
    required this.isKey,
    required this.quote,
    required this.parentKey,
  });

  /// The range the suggestion replaces, including an opening quote.
  final int start;
  final int end;

  /// The word typed so far (without quotes).
  final String token;

  /// True in key position (`{ na|`), false in value position (`a: Obj|`).
  final bool isKey;

  /// The quote that opened the token, if any.
  final String? quote;

  /// For keys: the key whose value is the enclosing object, e.g. `age` in
  /// `{ age: { $g| } }`; null at the top level or inside arrays.
  final String? parentKey;
}

final _ident = RegExp(r'[\w$.]');

/// Works out what is being typed at [cursor] in [text]; null when no
/// suggestion fits (inside a string value, after a number, …).
QueryContext? analyzeQuery(String text, int cursor) {
  if (cursor < 0 || cursor > text.length) return null;
  var start = cursor;
  while (start > 0 && _ident.hasMatch(text[start - 1])) {
    start--;
  }
  var end = cursor;
  while (end < text.length && _ident.hasMatch(text[end])) {
    end++;
  }
  final token = text.substring(start, cursor);
  String? quote;
  var before = start;
  if (start > 0 && (text[start - 1] == '"' || text[start - 1] == "'")) {
    quote = text[start - 1];
    before = start - 1;
    if (end < text.length && text[end] == quote) end++;
  }
  var p = before - 1;
  while (p >= 0 && text[p].trim().isEmpty) {
    p--;
  }
  final prev = p >= 0 ? text[p] : '';
  final replaceFrom = quote != null ? start - 1 : start;
  if (prev == '{' || prev == ',') {
    // A comma can also separate array items; only objects take keys.
    final open = _enclosingOpen(text, p + (prev == '{' ? 0 : 0), prev == '{');
    if (open == null || text[open] != '{') return null;
    return QueryContext(
      start: replaceFrom,
      end: end,
      token: token,
      isKey: true,
      quote: quote,
      parentKey: _keyBefore(text, open),
    );
  }
  if ((prev == ':' || prev == '[') && quote == null) {
    return QueryContext(
      start: start,
      end: end,
      token: token,
      isKey: false,
      quote: null,
      parentKey: null,
    );
  }
  return null;
}

/// The index of the unclosed `{` or `[` that contains position [from].
int? _enclosingOpen(String text, int from, bool fromIsOpen) {
  if (fromIsOpen) return from;
  var depth = 0;
  String? inString;
  // Scan backwards; strings are skipped roughly by tracking quotes.
  for (var i = from; i >= 0; i--) {
    final c = text[i];
    if (inString != null) {
      if (c == inString && (i == 0 || text[i - 1] != '\\')) inString = null;
      continue;
    }
    if (c == '"' || c == "'") {
      inString = c;
    } else if (c == '}' || c == ']') {
      depth++;
    } else if (c == '{' || c == '[') {
      if (depth == 0) return i;
      depth--;
    }
  }
  return null;
}

/// The key in front of the `{` at [open] (`age` in `age: {`), if any.
String? _keyBefore(String text, int open) {
  var i = open - 1;
  while (i >= 0 && text[i].trim().isEmpty) {
    i--;
  }
  if (i < 0 || text[i] != ':') return null;
  i--;
  while (i >= 0 && text[i].trim().isEmpty) {
    i--;
  }
  if (i < 0) return null;
  var endKey = i + 1;
  if (text[i] == '"' || text[i] == "'") {
    final q = text[i];
    endKey = i;
    i--;
    while (i >= 0 && text[i] != q) {
      i--;
    }
    return i < 0 ? null : text.substring(i + 1, endKey);
  }
  while (i >= 0 && _ident.hasMatch(text[i])) {
    i--;
  }
  final key = text.substring(i + 1, endKey);
  return key.isEmpty ? null : key;
}

const _fieldOperators = [
  r'$eq', r'$ne', r'$gt', r'$gte', r'$lt', r'$lte', r'$in', r'$nin',
  r'$exists', r'$regex', r'$options', r'$type', r'$all', r'$elemMatch',
  r'$size', r'$not', r'$mod',
];
const _topOperators = [r'$and', r'$or', r'$nor', r'$expr', r'$text'];

const _valueHelpers = [
  Suggestion("ObjectId('')", SuggestionKind.value,
      insert: "ObjectId('')", cursorBack: 2),
  Suggestion("ISODate('')", SuggestionKind.value,
      insert: "ISODate('')", cursorBack: 2),
  Suggestion('NumberLong()', SuggestionKind.value,
      insert: 'NumberLong()', cursorBack: 1),
  Suggestion("NumberDecimal('')", SuggestionKind.value,
      insert: "NumberDecimal('')", cursorBack: 2),
  Suggestion("UUID('')", SuggestionKind.value, insert: "UUID('')", cursorBack: 2),
  Suggestion('true', SuggestionKind.value, insert: 'true'),
  Suggestion('false', SuggestionKind.value, insert: 'false'),
  Suggestion('null', SuggestionKind.value, insert: 'null'),
  Suggestion('{ }', SuggestionKind.value, insert: '{  }', cursorBack: 2),
  Suggestion('[ ]', SuggestionKind.value, insert: '[  ]', cursorBack: 2),
];

List<String> _match(Iterable<String> options, String token) {
  final t = token.toLowerCase();
  final starts = <String>[];
  final contains = <String>[];
  for (final o in options) {
    final l = o.toLowerCase();
    if (l == t) continue;
    if (l.startsWith(t)) {
      starts.add(o);
    } else if (t.isNotEmpty && l.contains(t)) {
      contains.add(o);
    }
  }
  return [...starts, ...contains];
}

/// Suggestions for the cursor position, best first.
List<Suggestion> suggestQuery(
  QueryField field,
  QueryContext ctx,
  List<String> fieldPaths, {
  int max = 12,
}) {
  final out = <Suggestion>[];
  if (ctx.isKey) {
    final parent = ctx.parentKey;
    final underField = parent != null && !parent.startsWith(r'$');
    final wantsOperators = field == QueryField.filter &&
        (ctx.token.startsWith(r'$') || underField || parent == r'$not');
    if (wantsOperators) {
      final ops = underField || parent == r'$not'
          ? _fieldOperators
          : [..._topOperators, ..._fieldOperators];
      out.addAll(_match(ops, ctx.token)
          .map((o) => Suggestion(o, SuggestionKind.operator)));
    }
    if (!underField || ctx.token.isNotEmpty && !ctx.token.startsWith(r'$')) {
      if (!ctx.token.startsWith(r'$')) {
        out.addAll(_match(fieldPaths, ctx.token)
            .map((f) => Suggestion(f, SuggestionKind.field)));
      }
    }
  } else {
    if (field == QueryField.filter) {
      final t = ctx.token.toLowerCase();
      out.addAll(_valueHelpers.where((s) =>
          t.isEmpty ? s.label.startsWith(RegExp('[A-Z]')) : s.label.toLowerCase().startsWith(t) && s.label.toLowerCase() != t));
    } else if (ctx.token.isEmpty) {
      out.addAll(field == QueryField.sort
          ? const [
              Suggestion('1', SuggestionKind.value, insert: '1'),
              Suggestion('-1', SuggestionKind.value, insert: '-1'),
            ]
          : const [
              Suggestion('1', SuggestionKind.value, insert: '1'),
              Suggestion('0', SuggestionKind.value, insert: '0'),
            ]);
    }
  }
  return out.take(max).toList();
}

final _plainKey = RegExp(r'^[A-Za-z_$][\w$]*$');

/// Puts [s] into [value] at the place described by [ctx].
TextEditingValue applySuggestion(
    TextEditingValue value, QueryContext ctx, Suggestion s) {
  final text = value.text;
  String insert;
  int cursorFromEnd = s.cursorBack;
  if (s.kind == SuggestionKind.value) {
    insert = s.insert ?? s.label;
  } else {
    final key = s.label;
    final q = ctx.quote ?? (_plainKey.hasMatch(key) ? null : "'");
    insert = q == null ? key : '$q$key$q';
    var after = ctx.end;
    while (after < text.length && text[after] == ' ') {
      after++;
    }
    final hasColon = after < text.length && text[after] == ':';
    if (!hasColon) insert = '$insert: ';
  }
  final newText = text.replaceRange(ctx.start, ctx.end, insert);
  var cursor = ctx.start + insert.length - cursorFromEnd;
  if (s.kind != SuggestionKind.value) {
    // Land after an existing ": " too.
    var c = cursor;
    while (c < newText.length && (newText[c] == ' ' || newText[c] == ':')) {
      c++;
    }
    if (c != cursor && newText.substring(cursor, c).contains(':')) cursor = c;
  }
  return TextEditingValue(
      text: newText, selection: TextSelection.collapsed(offset: cursor));
}

/// Dotted field paths in [docs], e.g. `address.city`; array elements are
/// looked through, as MongoDB queries do. `_id` comes first.
List<String> fieldPathsOf(Iterable<Map<String, dynamic>> docs, {int max = 500}) {
  final paths = <String>{};
  void walk(String prefix, Object? v, int depth) {
    if (paths.length >= max || depth > 6) return;
    if (v is Map) {
      for (final e in v.entries) {
        final p = prefix.isEmpty ? '${e.key}' : '$prefix.${e.key}';
        paths.add(p);
        walk(p, e.value, depth + 1);
      }
    } else if (v is List) {
      for (final item in v.take(20)) {
        if (item is Map) walk(prefix, item, depth + 1);
      }
    }
  }

  for (final d in docs) {
    walk('', d, 0);
  }
  final list = paths.toList();
  if (list.remove('_id')) list.insert(0, '_id');
  return list;
}
