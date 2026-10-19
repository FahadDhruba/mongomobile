import 'dart:convert';

import 'package:mongo_wire/mongo_wire.dart';

enum ExportFormat { json, csv }

/// What to export and how.
class ExportOptions {
  const ExportOptions({
    required this.format,
    this.jsonMode = EJsonMode.relaxed,
    this.filter = const {},
    this.projection,
    this.sort,
    this.limit = 0,
  });

  final ExportFormat format;

  /// Relaxed or canonical Extended JSON, for JSON exports.
  final EJsonMode jsonMode;
  final Map<String, dynamic> filter;
  final Map<String, dynamic>? projection;
  final Map<String, dynamic>? sort;

  /// 0 exports every matching document.
  final int limit;

  String get extension => format == ExportFormat.json ? 'json' : 'csv';
  String get mimeType =>
      format == ExportFormat.json ? 'application/json' : 'text/csv';
}

/// Where exported bytes go: a file the user picked, or memory in tests.
abstract interface class ExportSink {
  Future<void> add(List<int> bytes);
  Future<void> close();

  /// Stops and removes the partial output.
  Future<void> abort();
}

enum ExportPhase { scanning, writing }

class ExportProgress {
  const ExportProgress(this.phase, this.documents);
  final ExportPhase phase;
  final int documents;
}

class ExportException implements Exception {
  ExportException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Writes query results as a JSON array of Extended JSON documents, or as
/// CSV with one column per field path, the way Compass does.
///
/// CSV needs the full set of columns before the first row, so it reads the
/// results twice: once to collect field paths, once to write rows.
class Exporter {
  Exporter({
    required this.client,
    required this.namespace,
    required this.options,
    required this.sink,
    this.onProgress,
    this.cancel,
    this.batchSize = 1000,
  });

  final MongoClient client;
  final Namespace namespace;
  final ExportOptions options;
  final ExportSink sink;
  final void Function(ExportProgress progress)? onProgress;
  final CancelToken? cancel;
  final int batchSize;

  /// CSV exports with more columns than this are refused; such data reads
  /// better as JSON.
  static const maxCsvColumns = 2000;

  final _buffer = StringBuffer();
  static const _flushAt = 256 * 1024;

  Future<void> _write(String text) async {
    _buffer.write(text);
    if (_buffer.length >= _flushAt) await _flush();
  }

  Future<void> _flush() async {
    if (_buffer.isEmpty) return;
    final bytes = utf8.encode(_buffer.toString());
    _buffer.clear();
    await sink.add(bytes);
  }

  Stream<List<Map<String, dynamic>>> _batches() => client.findBatches(
    namespace,
    filter: options.filter,
    projection: options.projection,
    sort: options.sort,
    limit: options.limit,
    batchSize: batchSize,
    cancel: cancel,
  );

  /// Runs the export and returns the number of documents written. On any
  /// error or cancellation the partial output is removed.
  Future<int> run() async {
    try {
      final n = options.format == ExportFormat.json
          ? await _json()
          : await _csv();
      await _flush();
      await sink.close();
      return n;
    } catch (_) {
      _buffer.clear();
      await sink.abort();
      rethrow;
    }
  }

  Future<int> _json() async {
    final writer = EJsonWriter(mode: options.jsonMode);
    var n = 0;
    await _write('[');
    await for (final batch in _batches()) {
      for (final doc in batch) {
        final text = writer.write(doc).replaceAll('\n', '\n  ');
        await _write('${n == 0 ? '\n  ' : ',\n  '}$text');
        n++;
      }
      onProgress?.call(ExportProgress(ExportPhase.writing, n));
    }
    await _write(n == 0 ? ']\n' : '\n]\n');
    return n;
  }

  Future<int> _csv() async {
    // Pass 1: every field path, in first-seen order with _id first.
    final columns = <String>{};
    var scanned = 0;
    await for (final batch in _batches()) {
      for (final doc in batch) {
        for (final path in flattenDocument(doc).keys) {
          if (columns.add(path) && columns.length > maxCsvColumns) {
            throw ExportException(
              'These documents have more than $maxCsvColumns distinct '
              'fields (large arrays become one column per element). '
              'Export as JSON instead, or add a projection.',
            );
          }
        }
      }
      scanned += batch.length;
      onProgress?.call(ExportProgress(ExportPhase.scanning, scanned));
    }
    final ordered = columns.toList();
    final idColumns = ordered
        .where(
          (c) => c == '_id' || c.startsWith('_id.') || c.startsWith('_id['),
        )
        .toList();
    ordered.removeWhere(idColumns.contains);
    ordered.insertAll(0, idColumns);

    // Pass 2: rows.
    await _write('${ordered.map(csvEscape).join(',')}\r\n');
    var n = 0;
    await for (final batch in _batches()) {
      for (final doc in batch) {
        final flat = flattenDocument(doc);
        await _write(
          '${ordered.map((c) => flat.containsKey(c) ? csvEscape(csvCell(flat[c])) : '').join(',')}\r\n',
        );
        n++;
      }
      onProgress?.call(ExportProgress(ExportPhase.writing, n));
    }
    return n;
  }
}

/// Turns nested documents into dotted paths and arrays into indexed
/// paths: `{a: {b: [1, 2]}}` → `{'a.b[0]': 1, 'a.b[1]': 2}`. Empty objects
/// and arrays keep their own column so they are not lost.
Map<String, Object?> flattenDocument(Map<String, dynamic> doc) {
  final out = <String, Object?>{};
  void walk(String path, Object? v) {
    if (v is Map && v.isNotEmpty) {
      v.forEach((k, child) => walk(path.isEmpty ? '$k' : '$path.$k', child));
    } else if (v is List && v.isNotEmpty) {
      for (var i = 0; i < v.length; i++) {
        walk('$path[$i]', v[i]);
      }
    } else {
      out[path] = v;
    }
  }

  doc.forEach((k, v) => walk(k, v));
  return out;
}

/// The text of one CSV cell.
String csvCell(Object? v) => switch (v) {
  null => '',
  String() => v,
  bool() || int() => '$v',
  double() => formatDouble(v),
  BsonLong() => '${v.value}',
  Decimal128() => v.toString(),
  ObjectId() => v.hex,
  DateTime() => formatIsoDate(v),
  Map() => '{}',
  List() => '[]',
  _ => EJson.stringify(v, mode: EJsonMode.relaxed, pretty: false),
};

/// Quotes a cell when RFC 4180 requires it.
String csvEscape(String s) {
  if (s.contains(RegExp(r'[",\r\n]')) || s != s.trim()) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}
