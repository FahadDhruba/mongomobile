import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mongo_wire/mongo_wire.dart';
import 'package:mongomobile/services/exporter.dart';

import 'support/fake_client.dart';

class MemorySink implements ExportSink {
  final bytes = <int>[];
  bool closed = false;
  bool aborted = false;
  int writes = 0;

  @override
  Future<void> add(List<int> b) async {
    writes++;
    bytes.addAll(b);
  }

  @override
  Future<void> close() async => closed = true;

  @override
  Future<void> abort() async => aborted = true;

  String get text => utf8.decode(bytes);
}

const ns = Namespace('shop', 'orders');

FakeMongoClient sample() => FakeMongoClient({
      'shop': {
        'orders': [
          {
            '_id': ObjectId.parse('65a1b2c3d4e5f60718293a4b'),
            'name': 'Ada, "the first"',
            'qty': 2,
            'price': Decimal128.parse('19.99'),
            'when': DateTime.utc(2024, 5, 1),
            'tags': ['a', 'b'],
            'address': {'city': 'London', 'zip': null},
            'big': const BsonLong(1 << 40),
          },
          {
            '_id': ObjectId.parse('65a1b2c3d4e5f60718293a4c'),
            'name': 'Alan\nTuring',
            'extra': true,
            'empty': <String, dynamic>{},
            'none': <dynamic>[],
          },
        ],
      },
    });

Future<(MemorySink, int)> run(FakeMongoClient c, ExportOptions o,
    {int batchSize = 1000, void Function(ExportProgress)? onProgress}) async {
  final sink = MemorySink();
  final n = await Exporter(
    client: c,
    namespace: ns,
    options: o,
    sink: sink,
    batchSize: batchSize,
    onProgress: onProgress,
  ).run();
  return (sink, n);
}

void main() {
  test('JSON export is an array that reads back to the same BSON', () async {
    final client = sample();
    final (sink, n) = await run(
        client, const ExportOptions(format: ExportFormat.json, jsonMode: EJsonMode.canonical),
        batchSize: 1);
    expect(n, 2);
    expect(sink.closed, isTrue);
    final parsed = EJsonParser(sink.text).parseValue() as List;
    final original = client.data['shop']!['orders']!;
    for (var i = 0; i < 2; i++) {
      expect(Bson.encode(parsed[i] as Map<String, dynamic>),
          Bson.encode(original[i]));
    }
    // Plain JSON tools can read it too.
    expect(jsonDecode(sink.text), isA<List<dynamic>>());
  });

  test('relaxed JSON writes plain numbers and an empty export is []', () async {
    final (sink, _) =
        await run(sample(), const ExportOptions(format: ExportFormat.json));
    expect(sink.text, contains('"qty": 2'));
    final (empty, n) = await run(
        sample(),
        const ExportOptions(
            format: ExportFormat.json, filter: {'name': 'nobody'}));
    expect(n, 0);
    expect(jsonDecode(empty.text), isEmpty);
  });

  test('CSV export flattens fields and escapes cells', () async {
    final progress = <ExportPhase>{};
    final (sink, n) = await run(
        sample(), const ExportOptions(format: ExportFormat.csv),
        onProgress: (p) => progress.add(p.phase));
    expect(n, 2);
    expect(progress, {ExportPhase.scanning, ExportPhase.writing});
    final lines = sink.text.split('\r\n');
    expect(lines[0],
        '_id,name,qty,price,when,tags[0],tags[1],address.city,address.zip,big,extra,empty,none');
    expect(lines[1],
        '65a1b2c3d4e5f60718293a4b,"Ada, ""the first""",2,19.99,2024-05-01T00:00:00.000Z,a,b,London,,1099511627776,,,');
    // The newline inside the quoted cell is kept as is.
    expect(lines[2], '65a1b2c3d4e5f60718293a4c,"Alan\nTuring",,,,,,,,,true,{},[]');
    expect(lines.last, '');
  });

  test('flattens nested paths', () {
    expect(
        flattenDocument({
          'a': {
            'b': [
              1,
              {'c': 2}
            ]
          },
          'd': 3,
        }),
        {'a.b[0]': 1, 'a.b[1].c': 2, 'd': 3});
  });

  test('CSV refuses an explosion of columns', () async {
    final client = FakeMongoClient({
      'shop': {
        'orders': [
          {'_id': 1, 'arr': List.generate(Exporter.maxCsvColumns + 5, (i) => i)},
        ],
      },
    });
    final sink = MemorySink();
    await expectLater(
      Exporter(
        client: client,
        namespace: ns,
        options: const ExportOptions(format: ExportFormat.csv),
        sink: sink,
      ).run(),
      throwsA(isA<ExportException>()),
    );
    expect(sink.aborted, isTrue);
  });

  test('cancelling aborts the file', () async {
    final token = CancelToken()..cancel();
    final sink = MemorySink();
    await expectLater(
      Exporter(
        client: sample(),
        namespace: ns,
        options: const ExportOptions(format: ExportFormat.json),
        sink: sink,
        cancel: token,
      ).run(),
      throwsA(isA<MongoCancelledError>()),
    );
    expect(sink.aborted, isTrue);
    expect(sink.closed, isFalse);
  });

  test('large exports are written in chunks, not one string', () async {
    final client = FakeMongoClient({
      'shop': {
        'orders': [
          for (var i = 0; i < 3000; i++) {'_id': i, 'text': 'x' * 200},
        ],
      },
    });
    final (sink, n) = await run(
        client, const ExportOptions(format: ExportFormat.json));
    expect(n, 3000);
    expect(sink.writes, greaterThan(1));
  });
}
