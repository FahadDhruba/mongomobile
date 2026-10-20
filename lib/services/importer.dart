import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:mongo_wire/mongo_wire.dart';

/// A file to import: a document the user picked, or bytes in tests.
abstract interface class ImportSource {
  String get name;

  /// Size in bytes, when the provider knows it.
  int? get size;

  /// Reads the file from the start. Each call opens it again.
  Stream<List<int>> read();
}

enum ImportFormat { json, csv }

/// How a CSV column becomes a field value.
enum CsvType {
  string('String'),
  int32('Int32'),
  int64('Int64'),
  double_('Double'),
  decimal('Decimal128'),
  boolean('Boolean'),
  date('Date'),
  objectId('ObjectId'),
  json('JSON'),
  ignore('Ignore');

  const CsvType(this.label);
  final String label;
}

class ImportOptions {
  const ImportOptions({
    required this.format,
    this.delimiter = ',',
    this.types = const {},
    this.ignoreEmpty = true,
    this.stopOnError = false,
  });

  final ImportFormat format;
  final String delimiter;

  /// CSV column name → type. Columns not listed are read as strings.
  final Map<String, CsvType> types;

  /// Leaves out CSV cells that are empty instead of storing "".
  final bool ignoreEmpty;

  /// Stops at the first document that fails to parse or insert.
  final bool stopOnError;
}

class ImportProgress {
  const ImportProgress({
    required this.bytesRead,
    required this.inserted,
    required this.failed,
  });
  final int bytesRead;
  final int inserted;
  final int failed;
}

class ImportResult {
  const ImportResult({
    required this.inserted,
    required this.failed,
    required this.errors,
    required this.cancelled,
  });
  final int inserted;
  final int failed;

  /// The first [Importer.maxErrors] problems, one line each.
  final List<String> errors;
  final bool cancelled;
}

class ImportException implements Exception {
  ImportException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Picks the format from the file name, then from the first character.
ImportFormat detectFormat(String name, String head) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.csv') || lower.endsWith('.tsv')) return ImportFormat.csv;
  if (lower.endsWith('.json') ||
      lower.endsWith('.ndjson') ||
      lower.endsWith('.jsonl')) {
    return ImportFormat.json;
  }
  final first = head.trimLeft();
  return first.startsWith('{') || first.startsWith('[')
      ? ImportFormat.json
      : ImportFormat.csv;
}

/// The delimiter used in the header line: comma, semicolon, tab or pipe.
String detectDelimiter(String head) {
  final line = head.split('\n').first;
  var best = ',';
  var bestCount = 0;
  for (final d in const [',', ';', '\t', '|']) {
    final n = d.allMatches(line).length;
    if (n > bestCount) {
      best = d;
      bestCount = n;
    }
  }
  return best;
}

/// Reads up to [bytes] from the start of [source] as text.
Future<String> readHead(ImportSource source, {int bytes = 64 * 1024}) async {
  final buffer = <int>[];
  await for (final chunk in source.read()) {
    buffer.addAll(chunk.take(bytes - buffer.length));
    if (buffer.length >= bytes) break;
  }
  var text = utf8.decode(buffer, allowMalformed: true);
  if (text.startsWith('\uFEFF')) text = text.substring(1);
  return text;
}

// ---------------------------------------------------------------------------
// JSON

/// Splits a stream of JSON text into the source of each top-level document,
/// for a JSON array of documents or for one document after another
/// (NDJSON). Strings may use single or double quotes, as in the shell.
class JsonDocumentSplitter {
  final _current = StringBuffer();
  int _depth = 0;
  String? _quote;
  bool _escape = false;
  bool? _array;
  bool _arrayClosed = false;
  bool _started = false;
  int _line = 1;
  int _startLine = 1;

  /// The line the most recently returned document started on.
  final lines = <int>[];

  /// Feeds [chunk] and returns the documents it completed.
  List<String> add(String chunk) {
    final out = <String>[];
    lines.clear();
    for (var i = 0; i < chunk.length; i++) {
      final ch = chunk[i];
      if (ch == '\n') _line++;
      if (_quote != null) {
        _current.write(ch);
        if (_escape) {
          _escape = false;
        } else if (ch == r'\') {
          _escape = true;
        } else if (ch == _quote) {
          _quote = null;
        }
        continue;
      }
      final inValue = _depth > (_array == true ? 1 : 0);
      if (!inValue) {
        // Between documents: whitespace, the array brackets and commas.
        if (ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t') continue;
        if (ch == '\uFEFF' && !_started) continue;
        if (_arrayClosed) {
          throw ImportException('Line $_line: unexpected text after the array');
        }
        if (_array == null) {
          _started = true;
          if (ch == '[') {
            _array = true;
            _depth = 1;
            continue;
          }
          _array = false;
        }
        if (_array == true) {
          if (ch == ',') continue;
          if (ch == ']') {
            _arrayClosed = true;
            _depth = 0;
            continue;
          }
        }
        if (ch != '{') {
          throw ImportException(
            'Line $_line: expected a document starting with "{"',
          );
        }
        _startLine = _line;
      }
      _current.write(ch);
      switch (ch) {
        case '"' || "'":
          _quote = ch;
        case '{' || '[':
          _depth++;
        case '}' || ']':
          _depth--;
          if (_depth == (_array == true ? 1 : 0)) {
            out.add(_current.toString());
            lines.add(_startLine);
            _current.clear();
          }
      }
    }
    return out;
  }

  /// Checks that the input did not stop in the middle of a document.
  void close() {
    if (_current.toString().trim().isNotEmpty || _quote != null) {
      throw ImportException(
        'Line $_startLine: the file ends in the middle of a document',
      );
    }
    if (_array == true && !_arrayClosed) {
      throw ImportException('The file ends before the closing "]"');
    }
  }
}

/// The first [count] documents of a JSON file, for the preview.
List<Map<String, dynamic>> previewJson(String head, {int count = 3}) {
  final splitter = JsonDocumentSplitter();
  final out = <Map<String, dynamic>>[];
  for (final text in splitter.add(head)) {
    out.add(EJson.parseDocument(text));
    if (out.length >= count) break;
  }
  return out;
}

// ---------------------------------------------------------------------------
// CSV

/// An RFC 4180 CSV reader fed in chunks: quoted fields may hold the
/// delimiter, quotes ("") and line breaks.
class CsvSplitter {
  CsvSplitter(this.delimiter);
  final String delimiter;

  final _field = StringBuffer();
  var _row = <String>[];
  bool _quoted = false;
  bool _quoteSeen = false;
  bool _rowStarted = false;
  bool _skipLf = false;

  List<List<String>> add(String chunk) {
    final rows = <List<String>>[];
    for (var i = 0; i < chunk.length; i++) {
      final ch = chunk[i];
      if (_skipLf) {
        _skipLf = false;
        if (ch == '\n') continue;
      }
      if (_quoted) {
        if (_quoteSeen) {
          _quoteSeen = false;
          if (ch == '"') {
            _field.write('"');
            continue;
          }
          _quoted = false;
          // Falls through to handle the character after the closing quote.
        } else if (ch == '"') {
          _quoteSeen = true;
          continue;
        } else {
          _field.write(ch);
          continue;
        }
      }
      if (ch == '"' && _field.isEmpty) {
        _quoted = true;
        _rowStarted = true;
      } else if (ch == delimiter) {
        _row.add(_field.toString());
        _field.clear();
        _rowStarted = true;
      } else if (ch == '\n' || ch == '\r') {
        if (ch == '\r') _skipLf = true;
        if (_rowStarted || _field.isNotEmpty) {
          _row.add(_field.toString());
          rows.add(_row);
        }
        _field.clear();
        _row = <String>[];
        _rowStarted = false;
      } else if (ch == '\uFEFF' && !_rowStarted && _field.isEmpty) {
        continue;
      } else {
        _field.write(ch);
        _rowStarted = true;
      }
    }
    return rows;
  }

  /// The last row when the file does not end with a line break.
  List<String>? close() {
    if (_quoted && !_quoteSeen) {
      throw ImportException('The file ends inside a quoted field');
    }
    if (!_rowStarted && _field.isEmpty) return null;
    _row.add(_field.toString());
    final row = _row;
    _row = <String>[];
    _field.clear();
    _rowStarted = false;
    _quoted = false;
    _quoteSeen = false;
    return row;
  }
}

class CsvPreview {
  const CsvPreview(this.headers, this.rows, this.types);
  final List<String> headers;
  final List<List<String>> rows;

  /// The detected type of each column.
  final List<CsvType> types;
}

/// The header, the first rows and a type guess per column, from the start
/// of a CSV file.
CsvPreview previewCsv(String head, String delimiter, {int rows = 10}) {
  // The head may stop mid-row: drop the partial last line.
  final cut = head.lastIndexOf('\n');
  final text = cut > 0 && head.length >= 64 * 1024
      ? head.substring(0, cut + 1)
      : head;
  final splitter = CsvSplitter(delimiter);
  final all = [...splitter.add(text), ?splitter.close()];
  if (all.isEmpty) throw ImportException('The file is empty');
  final headers = csvHeaders(all.first);
  final body = all.skip(1).toList();
  return CsvPreview(headers, body.take(rows).toList(), [
    for (var c = 0; c < headers.length; c++)
      guessCsvType([
        for (final r in body)
          if (c < r.length) r[c],
      ]),
  ]);
}

/// Header names, with blank ones named after their position.
List<String> csvHeaders(List<String> row) => [
  for (var i = 0; i < row.length; i++)
    row[i].trim().isEmpty ? 'field${i + 1}' : row[i].trim(),
];

final _intText = RegExp(r'^[+-]?\d+$');
final _numberText = RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$');
final _dateText = RegExp(
  r'^\d{4}-\d\d-\d\d([T ]\d\d:\d\d(:\d\d(\.\d+)?)?(Z|[+-]\d\d:?\d\d)?)?$',
);
final _hexId = RegExp(r'^[0-9a-fA-F]{24}$');

/// The narrowest type that every non-empty value fits.
CsvType guessCsvType(List<String> values) {
  final v = [
    for (final s in values)
      if (s.trim().isNotEmpty) s.trim(),
  ];
  if (v.isEmpty) return CsvType.string;
  bool all(bool Function(String) test) => v.every(test);
  if (all(_hexId.hasMatch)) return CsvType.objectId;
  if (all((s) => s == 'true' || s == 'false')) return CsvType.boolean;
  if (all(_intText.hasMatch)) {
    final fits32 = all((s) {
      final n = int.tryParse(s);
      return n != null && n >= -0x80000000 && n <= 0x7fffffff;
    });
    if (fits32) return CsvType.int32;
    if (all((s) => int.tryParse(s) != null)) return CsvType.int64;
    return CsvType.decimal;
  }
  if (all(_numberText.hasMatch)) return CsvType.double_;
  if (all(_dateText.hasMatch)) return CsvType.date;
  if (all((s) => (s.startsWith('{') || s.startsWith('[')) && _parses(s))) {
    return CsvType.json;
  }
  return CsvType.string;
}

bool _parses(String s) {
  try {
    EJson.parse(s);
    return true;
  } on Object {
    return false;
  }
}

/// Converts one cell. Throws [FormatException] when it does not fit.
Object? csvValue(String text, CsvType type) {
  final t = text.trim();
  switch (type) {
    case CsvType.string || CsvType.ignore:
      return text;
    case CsvType.int32:
      final n = int.tryParse(t);
      if (n == null || n < -0x80000000 || n > 0x7fffffff) {
        throw const FormatException('not a 32-bit whole number');
      }
      return n;
    case CsvType.int64:
      final n = int.tryParse(t);
      if (n == null) throw const FormatException('not a whole number');
      return BsonLong(n);
    case CsvType.double_:
      final n = double.tryParse(t);
      if (n == null) throw const FormatException('not a number');
      return n;
    case CsvType.decimal:
      try {
        return Decimal128.parse(t);
      } on FormatException {
        throw const FormatException('not a decimal number');
      }
    case CsvType.boolean:
      return switch (t.toLowerCase()) {
        'true' || '1' || 'yes' => true,
        'false' || '0' || 'no' => false,
        _ => throw const FormatException('not true or false'),
      };
    case CsvType.date:
      if (_intText.hasMatch(t)) {
        return DateTime.fromMillisecondsSinceEpoch(int.parse(t), isUtc: true);
      }
      try {
        return parseIsoDate(t.replaceFirst(' ', 'T'));
      } on FormatException {
        throw const FormatException('not a date');
      }
    case CsvType.objectId:
      if (!_hexId.hasMatch(t)) {
        throw const FormatException('not a 24-character hex ObjectId');
      }
      return ObjectId.parse(t);
    case CsvType.json:
      try {
        return EJson.parse(t);
      } on EJsonParseException catch (e) {
        throw FormatException(e.message);
      }
  }
}

/// Puts [value] at a path such as `a.b[0].c`, the shape the CSV export
/// writes, creating objects and arrays on the way.
void setPath(Map<String, dynamic> doc, String path, Object? value) {
  final parts = <Object>[];
  for (final m in RegExp(r'([^.\[\]]+)|\[(\d+)\]').allMatches(path)) {
    parts.add(m.group(2) != null ? int.parse(m.group(2)!) : m.group(1)!);
  }
  if (parts.isEmpty) return;
  Object container = doc;
  for (var i = 0; i < parts.length; i++) {
    final part = parts[i];
    final last = i == parts.length - 1;
    Object? next() => last
        ? value
        : parts[i + 1] is int
        ? <Object?>[]
        : <String, dynamic>{};
    if (container is Map<String, dynamic>) {
      final key = '$part';
      if (last) {
        container[key] = value;
        return;
      }
      final existing = container[key];
      if (existing is Map<String, dynamic> || existing is List<Object?>) {
        container = existing!;
      } else {
        container = container[key] = next()!;
      }
    } else if (container is List<Object?>) {
      if (part is! int) {
        // A name inside an array: keep the value under its full path.
        doc[path] = value;
        return;
      }
      while (container.length <= part) {
        container.add(null);
      }
      if (last) {
        container[part] = value;
        return;
      }
      final existing = container[part];
      if (existing is Map<String, dynamic> || existing is List<Object?>) {
        container = existing!;
      } else {
        final created = next()!;
        container[part] = created;
        container = created;
      }
    }
  }
}

/// Builds the document for one CSV row.
Map<String, dynamic> csvDocument(
  List<String> headers,
  List<String> row,
  Map<String, CsvType> types, {
  bool ignoreEmpty = true,
}) {
  final doc = <String, dynamic>{};
  for (var c = 0; c < headers.length && c < row.length; c++) {
    final type = types[headers[c]] ?? CsvType.string;
    if (type == CsvType.ignore) continue;
    final text = row[c];
    if (text.trim().isEmpty) {
      if (ignoreEmpty || type != CsvType.string) continue;
    }
    try {
      setPath(doc, headers[c], csvValue(text, type));
    } on FormatException catch (e) {
      throw FormatException('${headers[c]}: "$text" is ${e.message}');
    }
  }
  return doc;
}

// ---------------------------------------------------------------------------
// Import

/// Reads a JSON or CSV file and inserts its documents in batches with
/// `insertMany`, reporting progress and collecting errors.
class Importer {
  Importer({
    required this.client,
    required this.namespace,
    required this.source,
    required this.options,
    this.onProgress,
    this.cancel,
  });

  final MongoClient client;
  final Namespace namespace;
  final ImportSource source;
  final ImportOptions options;
  final void Function(ImportProgress progress)? onProgress;
  final CancelToken? cancel;

  static const batchSize = 1000;
  static const maxErrors = 50;

  int _bytes = 0;
  int _inserted = 0;
  int _failed = 0;
  int _number = 0;
  final _errors = <String>[];
  final _batch = <Map<String, dynamic>>[];
  final _batchNumbers = <int>[];

  void _error(String message) {
    _failed++;
    if (_errors.length < maxErrors) _errors.add(message);
    if (options.stopOnError) throw _Stop();
  }

  void _report() => onProgress?.call(
    ImportProgress(bytesRead: _bytes, inserted: _inserted, failed: _failed),
  );

  Future<void> _flush() async {
    if (_batch.isEmpty) return;
    final docs = List.of(_batch);
    final numbers = List.of(_batchNumbers);
    _batch.clear();
    _batchNumbers.clear();
    final r = await client.insertMany(
      namespace,
      docs,
      ordered: options.stopOnError,
    );
    _inserted += r.inserted;
    for (final e in r.errors) {
      final n = e.index < numbers.length ? numbers[e.index] : e.index + 1;
      // An ordered insert stops at its first error, so that is the last.
      _failed++;
      if (_errors.length < maxErrors) {
        _errors.add('Document $n: ${e.message}');
      }
    }
    if (options.stopOnError && r.errors.isNotEmpty) throw _Stop();
    _report();
  }

  Future<void> _add(Map<String, dynamic> doc) async {
    _batch.add(doc);
    _batchNumbers.add(_number);
    if (_batch.length >= batchSize) await _flush();
  }

  Future<ImportResult> run() async {
    var cancelled = false;
    try {
      final text = source
          .read()
          .map((chunk) {
            _bytes += chunk.length;
            return chunk;
          })
          .transform(const Utf8Decoder(allowMalformed: true));
      if (options.format == ImportFormat.json) {
        await _json(text);
      } else {
        await _csv(text);
      }
      if (cancel?.isCancelled ?? false) throw MongoCancelledError();
      await _flush();
    } on _Stop {
      // Stopped at the first error, as asked. Documents read before it
      // still go in, as with an ordered insert.
      try {
        await _flush();
      } on _Stop {
        // The flush hit an insert error; it is already counted.
      }
    } on MongoCancelledError {
      cancelled = true;
    }
    _report();
    return ImportResult(
      inserted: _inserted,
      failed: _failed,
      errors: List.unmodifiable(_errors),
      cancelled: cancelled,
    );
  }

  void _checkCancel() {
    if (cancel?.isCancelled ?? false) throw MongoCancelledError();
  }

  Future<void> _json(Stream<String> text) async {
    final splitter = JsonDocumentSplitter();
    await for (final chunk in text) {
      _checkCancel();
      final docs = splitter.add(chunk);
      final lines = List.of(splitter.lines);
      for (var i = 0; i < docs.length; i++) {
        _number++;
        try {
          await _add(EJson.parseDocument(docs[i]));
        } on EJsonParseException catch (e) {
          _error(
            'Document $_number (line ${lines[i] + e.line - 1}): ${e.message}',
          );
        } on FormatException catch (e) {
          _error('Document $_number (line ${lines[i]}): ${e.message}');
        }
      }
      _report();
    }
    splitter.close();
  }

  Future<void> _csv(Stream<String> text) async {
    final splitter = CsvSplitter(options.delimiter);
    List<String>? headers;
    Future<void> row(List<String> r) async {
      if (headers == null) {
        headers = csvHeaders(r);
        return;
      }
      _number++;
      try {
        final doc = csvDocument(
          headers!,
          r,
          options.types,
          ignoreEmpty: options.ignoreEmpty,
        );
        if (doc.isNotEmpty) await _add(doc);
      } on FormatException catch (e) {
        _error('Row ${_number + 1}: ${e.message}');
      }
    }

    await for (final chunk in text) {
      _checkCancel();
      for (final r in splitter.add(chunk)) {
        await row(r);
      }
      _report();
    }
    if (splitter.close() case final last?) await row(last);
    if (headers == null) throw ImportException('The file is empty');
  }
}

class _Stop implements Exception {}

/// Progress as a fraction, when the size is known.
double? progressOf(int bytesRead, int? size) =>
    size == null || size <= 0 ? null : math.min(1, bytesRead / size);
