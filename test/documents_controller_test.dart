import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mongo_wire/mongo_wire.dart';
import 'package:mongomobile/models/connection_profile.dart';
import 'package:mongomobile/state/documents_controller.dart';
import 'package:mongomobile/state/providers.dart';
import 'package:mongomobile/ui/screens/documents_view.dart';

import 'support/fake_client.dart';

const ns = Namespace('shop', 'orders');

Future<ProviderContainer> connected(FakeMongoClient client) async {
  final container = ProviderContainer(overrides: [
    connectorProvider.overrideWithValue(FakeConnector(client)),
    connectionStoreProvider.overrideWithValue(MemoryConnectionStore()),
  ]);
  await container.read(sessionProvider.notifier).connect(
      const ConnectionProfile(id: '1', name: 'test', uri: 'mongodb://x'));
  return container;
}

/// Waits until the controller has settled.
Future<DocumentsState> settle(ProviderContainer c) async {
  for (var i = 0; i < 50; i++) {
    await Future<void>.delayed(Duration.zero);
    final s = c.read(documentsProvider(ns));
    if (!s.loading && s.loadedOnce && s.count.kind != CountKind.loading) {
      return s;
    }
  }
  return c.read(documentsProvider(ns));
}

List<Object?> ids(DocumentsState s) => s.documents.map((d) => d['_id']).toList();

void main() {
  late FakeMongoClient client;
  late ProviderContainer c;

  setUp(() async {
    client = FakeMongoClient({
      'shop': {
        'orders': [
          for (var i = 0; i < 60; i++) {'_id': i, 'n': 59 - i, 'even': i.isEven},
        ],
      },
    });
    c = await connected(client);
    c.listen(documentsProvider(ns), (_, _) {});
  });

  tearDown(() => c.dispose());

  test('first page, estimated count and label', () async {
    final s = await settle(c);
    expect(ids(s), List.generate(25, (i) => i));
    expect(s.hasNext, isTrue);
    expect(s.hasPrevious, isFalse);
    expect(s.count.kind, CountKind.estimated);
    expect(pageLabel(s), '1 – 25 of ~60');
    expect(client.finds.last.limit, 26, reason: 'one extra to detect a next page');
  });

  test('pages forward and back with _id anchors, not skip', () async {
    await settle(c);
    final ctrl = c.read(documentsProvider(ns).notifier);
    await ctrl.next();
    var s = c.read(documentsProvider(ns));
    expect(ids(s), List.generate(25, (i) => i + 25));
    expect(client.finds.last.skip, 0);
    expect(client.finds.last.filter, {
      '_id': {r'$gt': 24}
    });
    await ctrl.next();
    s = c.read(documentsProvider(ns));
    expect(ids(s), List.generate(10, (i) => i + 50));
    expect(s.hasNext, isFalse);
    expect(pageLabel(s), '51 – 60 of 60');

    await ctrl.previous();
    s = c.read(documentsProvider(ns));
    expect(ids(s), List.generate(25, (i) => i + 25));
    expect(client.finds.last.filter, {
      '_id': {r'$lt': 50}
    });
    expect(client.finds.last.sort, {'_id': -1});
    expect(s.pageIndex, 1);
  });

  test('descending _id sort also uses keyset', () async {
    await settle(c);
    final ctrl = c.read(documentsProvider(ns).notifier);
    await ctrl.run(QuerySpec.parse(sort: '{_id: -1}'));
    await ctrl.next();
    final s = c.read(documentsProvider(ns));
    expect(ids(s).first, 34);
    expect(client.finds.last.filter, {
      '_id': {r'$lt': 35}
    });
  });

  test('other sorts use skip and limit', () async {
    await settle(c);
    final ctrl = c.read(documentsProvider(ns).notifier);
    await ctrl.run(QuerySpec.parse(sort: '{n: 1}'));
    await ctrl.next();
    final s = c.read(documentsProvider(ns));
    expect(client.finds.last.skip, 25);
    expect(s.documents.first['n'], 25);
    expect(s.usesKeyset, isFalse);
  });

  test('filters combine with anchors and count exactly', () async {
    await settle(c);
    final ctrl = c.read(documentsProvider(ns).notifier);
    await ctrl.run(QuerySpec.parse(filter: '{even: true}'));
    var s = await settle(c);
    expect(s.count.kind, CountKind.exact);
    expect(s.count.value, 30);
    expect(pageLabel(s), '1 – 25 of 30');
    await ctrl.next();
    s = c.read(documentsProvider(ns));
    expect(client.finds.last.filter, {
      r'$and': [
        {'even': true},
        {
          '_id': {r'$gt': 48}
        },
      ]
    });
    expect(ids(s), [50, 52, 54, 56, 58]);
  });

  test('the user limit caps pages', () async {
    await settle(c);
    final ctrl = c.read(documentsProvider(ns).notifier);
    await ctrl.run(QuerySpec.parse(limit: '30'));
    var s = await settle(c);
    expect(pageLabel(s), '1 – 25 of ~30');
    await ctrl.next();
    s = c.read(documentsProvider(ns));
    expect(ids(s), [25, 26, 27, 28, 29]);
    expect(s.hasNext, isFalse);
  });

  test('page size changes restart at the first page', () async {
    await settle(c);
    final ctrl = c.read(documentsProvider(ns).notifier);
    await ctrl.next();
    await ctrl.setPageSize(10);
    final s = c.read(documentsProvider(ns));
    expect(s.pageIndex, 0);
    expect(ids(s), List.generate(10, (i) => i));
  });

  test('a projection hiding _id still pages and keeps ids for actions',
      () async {
    await settle(c);
    final ctrl = c.read(documentsProvider(ns).notifier);
    await ctrl.run(QuerySpec.parse(project: '{_id: 0, n: 1}'));
    var s = c.read(documentsProvider(ns));
    expect(s.documents.first.containsKey('_id'), isFalse);
    expect(s.ids.first, 0);
    await ctrl.next();
    s = c.read(documentsProvider(ns));
    expect(s.ids.first, 25);
  });

  test('cancel stops a slow query', () async {
    await settle(c);
    client.findDelay = const Duration(seconds: 30);
    final ctrl = c.read(documentsProvider(ns).notifier);
    final f = ctrl.refresh(countToo: false);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(c.read(documentsProvider(ns)).loading, isTrue);
    ctrl.cancel();
    await f;
    final s = c.read(documentsProvider(ns));
    expect(s.loading, isFalse);
    expect(s.error, 'Query cancelled');
  });

  test('parse errors name the field', () {
    expect(() => QuerySpec.parse(filter: '{a: }'),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', startsWith('Filter'))));
    expect(() => QuerySpec.parse(sort: '{a: 2}'), throwsFormatException);
    expect(() => QuerySpec.parse(limit: 'x'), throwsFormatException);
  });

  test('skip, collation and hint switch to skip paging and reach the server',
      () async {
    await settle(c);
    final ctrl = c.read(documentsProvider(ns).notifier);
    await ctrl.run(QuerySpec.parse(
      skip: '10',
      collation: "{ locale: 'en' }",
      hint: '{ _id: 1 }',
      maxTime: '1500',
    ));
    var s = c.read(documentsProvider(ns));
    expect(s.usesKeyset, isFalse);
    expect(ids(s).first, 10);
    expect(client.finds.last.collation, {'locale': 'en'});
    expect(client.finds.last.hint, {'_id': 1});
    expect(client.finds.last.maxTime, const Duration(milliseconds: 1500));
    await ctrl.next();
    s = c.read(documentsProvider(ns));
    expect(client.finds.last.skip, 35);
    expect(ids(s).first, 35);
  });

  test('query texts round-trip for history', () {
    final q = QuerySpec.parse(filter: '{ a: 1 }', hint: 'a_1', skip: '3');
    expect(q.toTexts(), {'filter': '{ a: 1 }', 'hint': 'a_1', 'skip': '3'});
    final back = QuerySpec.fromTexts(q.toTexts());
    expect(back.hint, 'a_1');
    expect(back.skip, 3);
    expect(() => QuerySpec.parse(collation: '{ strength: 2 }'),
        throwsFormatException);
    expect(() => QuerySpec.parse(maxTime: '0'), throwsFormatException);
  });
}
