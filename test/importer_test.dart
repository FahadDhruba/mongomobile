import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mongo_wire/mongo_wire.dart';
import 'package:mongomobile/services/exporter.dart';
import 'package:mongomobile/services/importer.dart';

import 'support/fake_client.dart';

/// File contents served in small chunks, so values cross chunk borders.
class MemorySource implements ImportSource {
  MemorySource(this.text, {this.name = 'data', this.chunk = 7});
  final String text;
  final int chunk;

  @override
  final String name;

  @override
  int? get size => utf8.encode(text).length;

  @override
  Stream<List<int>> read() async* {
    final bytes = utf8.encode(text);
    for (var i = 0; i < bytes.length; i += chunk) {
      yield bytes.sublist(i, i + chunk > bytes.length ? bytes.length : i + chunk);
    }
  }
}

class MemorySink implements ExportSink {
  final bytes = <int>[];
  @override
  Future<void> add(List<int> b) async => bytes.addAll(b);
  @override
  Future<void> close() async {}
  @override
  Future<void> abort() async {}
}

const ns = Namespace('shop', 'imported');

Future<(ImportResult, List<Map<String, dynamic>>)> run(
  String text,
  ImportOptions options, {
  FakeMongoClient? client,
}) async {
  final c = client ?? FakeMongoClient({'shop': {}});
  final r = await Importer(
    client: c,
    namespace: ns,
    source: MemorySource(text),
    options: options,
  ).run();
  return (r, c.data['shop']!['imported'] ?? []);
}

void main() {
  group('JSON', () {
    test('splits arrays and NDJSON across chunks', () {
      final s = JsonDocumentSplitter();
      const text =
          '[ {"a": "x}y", "b": [1, {"c": 2}]},\n'
          "  {'q': 'it\\'s'} ]";
      final out = <String>[];
      for (var i = 0; i < text.length; i += 3) {
        out.addAll(s.add(text.substring(i, i + 3 > text.length ? text.length : i + 3)));
      }
      s.close();
      expect(out, ['{"a": "x}y", "b": [1, {"c": 2}]}', "{'q': 'it\\'s'}"]);

      final nd = JsonDocumentSplitter();
      expect(nd.add('{"a":1}\n{"a":2}\n\n{"a"'), ['{"a":1}', '{"a":2}']);
      expect(nd.add(':3}\n'), ['{"a":3}']);
      nd.close();
    });

    test('rejects broken files', () {
      expect(
        () => JsonDocumentSplitter()
          ..add('{"a": 1')
          ..close(),
        throwsA(isA<ImportException>()),
      );
      expect(
        () => JsonDocumentSplitter().add('[1, 2]'),
        throwsA(isA<ImportException>()),
      );
      expect(
        () => JsonDocumentSplitter()
          ..add('[{"a": 1}')
          ..close(),
        throwsA(isA<ImportException>()),
      );
    });

    test('imports Extended JSON and reports bad documents', () async {
      final (r, docs) = await run(
        '[{"_id": {"\$oid": "65a1b2c3d4e5f60718293a4b"}, "n": {"\$numberLong": "5"}},\n'
        ' {"when": ISODate("2024-05-01T00:00:00Z")},\n'
        ' {"bad": tru},\n'
        ' {"ok": true}]',
        const ImportOptions(format: ImportFormat.json),
      );
      expect(r.inserted, 3);
      expect(r.failed, 1);
      expect(r.errors.single, startsWith('Document 3 (line 3)'));
      expect(docs[0]['_id'], ObjectId.parse('65a1b2c3d4e5f60718293a4b'));
      expect(docs[0]['n'], const BsonLong(5));
      expect(docs[1]['when'], DateTime.utc(2024, 5, 1));
    });

    test('stops at the first error when asked', () async {
      final (r, docs) = await run(
        '{"a": 1}\n{"a": }\n{"a": 3}',
        const ImportOptions(format: ImportFormat.json, stopOnError: true),
      );
      expect(r.failed, 1);
      expect(docs, isEmpty);
    });

    test('duplicate _id errors come back per document', () async {
      final client = FakeMongoClient({
        'shop': {
          'imported': [
            {'_id': 1},
          ],
        },
      });
      final (r, docs) = await run(
        '{"_id": 1}\n{"_id": 2}',
        const ImportOptions(format: ImportFormat.json),
        client: client,
      );
      expect(r.inserted, 1);
      expect(r.errors, ['Document 1: E11000 duplicate key']);
      expect(docs.length, 2);
    });
  });

  group('CSV', () {
    test('reads quotes, delimiters and line breaks across chunks', () {
      final s = CsvSplitter(',');
      const text = 'a,b,c\r\n"x, ""y""",2,"multi\nline"\r\n,,\n4,5,6';
      final rows = <List<String>>[];
      for (var i = 0; i < text.length; i += 2) {
        rows.addAll(s.add(text.substring(i, i + 2 > text.length ? text.length : i + 2)));
      }
      rows.add(s.close()!);
      expect(rows, [
        ['a', 'b', 'c'],
        ['x, "y"', '2', 'multi\nline'],
        ['', '', ''],
        ['4', '5', '6'],
      ]);
    });

    test('detects delimiters and column types', () {
      expect(detectDelimiter('a;b;c\n1;2;3'), ';');
      expect(detectDelimiter('a\tb\n'), '\t');
      expect(guessCsvType(['1', '2', '']), CsvType.int32);
      expect(guessCsvType(['1', '9999999999']), CsvType.int64);
      expect(guessCsvType(['1', '2.5']), CsvType.double_);
      expect(guessCsvType(['true', 'false']), CsvType.boolean);
      expect(guessCsvType(['2024-05-01', '2024-05-01T09:30:00Z']), CsvType.date);
      expect(guessCsvType(['65a1b2c3d4e5f60718293a4b']), CsvType.objectId);
      expect(guessCsvType(['{"a": 1}', '[]']), CsvType.json);
      expect(guessCsvType(['1', 'x']), CsvType.string);
      final p = previewCsv('name,qty,,when\nAda,2,,2024-05-01\n', ',');
      expect(p.headers, ['name', 'qty', 'field3', 'when']);
      expect(p.types, [CsvType.string, CsvType.int32, CsvType.string, CsvType.date]);
    });

    test('builds nested documents from dotted and indexed headers', () {
      final d = <String, dynamic>{};
      setPath(d, 'a.b', 1);
      setPath(d, 'a.c[1]', 'y');
      setPath(d, 'a.c[0]', 'x');
      setPath(d, 'items[0].sku', 'A');
      setPath(d, 'items[1].sku', 'B');
      expect(d, {
        'a': {
          'b': 1,
          'c': ['x', 'y'],
        },
        'items': [
          {'sku': 'A'},
          {'sku': 'B'},
        ],
      });
    });

    test('imports typed rows and reports cells that do not fit', () async {
      final (r, docs) = await run(
        'name,qty,when,tags[0]\nAda,2,2024-05-01,x\nBob,,2024-05-02,\nEve,lots,2024-05-03,y\n',
        const ImportOptions(
          format: ImportFormat.csv,
          types: {
            'name': CsvType.string,
            'qty': CsvType.int32,
            'when': CsvType.date,
            'tags[0]': CsvType.string,
          },
        ),
      );
      expect(r.inserted, 2);
      expect(r.errors.single, 'Row 4: qty: "lots" is not a 32-bit whole number');
      expect(docs[0]['qty'], 2);
      expect(docs[0]['when'], DateTime.utc(2024, 5, 1));
      expect(docs[0]['tags'], ['x']);
      expect(docs[1].containsKey('qty'), isFalse);
      expect(docs[1].containsKey('tags'), isFalse);
    });

    test('round-trips the CSV export', () async {
      final source = FakeMongoClient({
        'shop': {
          'orders': [
            {
              '_id': ObjectId.parse('65a1b2c3d4e5f60718293a4b'),
              'name': 'Ada, "the first"',
              'qty': 2,
              'big': const BsonLong(1 << 40),
              'when': DateTime.utc(2024, 5, 1, 9, 30),
              'paid': true,
              'customer': {'city': 'London'},
              'items': [
                {'sku': 'A-1', 'qty': 2},
              ],
            },
          ],
        },
      });
      final sink = MemorySink();
      await Exporter(
        client: source,
        namespace: const Namespace('shop', 'orders'),
        options: const ExportOptions(format: ExportFormat.csv),
        sink: sink,
      ).run();
      final text = utf8.decode(sink.bytes);
      final preview = previewCsv(text, detectDelimiter(text));
      final (r, docs) = await run(
        text,
        ImportOptions(
          format: ImportFormat.csv,
          types: Map.fromIterables(preview.headers, preview.types),
        ),
      );
      expect(r.failed, 0);
      expect(
        EJson.stringify(docs.single),
        EJson.stringify(source.data['shop']!['orders']!.single),
      );
    });
  });

  test('cancelling stops between chunks', () async {
    final token = CancelToken()..cancel();
    final r = await Importer(
      client: FakeMongoClient({'shop': {}}),
      namespace: ns,
      source: MemorySource('{"a":1}\n' * 10),
      options: const ImportOptions(format: ImportFormat.json),
      cancel: token,
    ).run();
    expect(r.cancelled, isTrue);
    expect(r.inserted, 0);
  });
}
