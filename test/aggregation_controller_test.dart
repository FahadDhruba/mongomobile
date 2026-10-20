import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mongo_wire/mongo_wire.dart';
import 'package:mongomobile/services/pipeline.dart';
import 'package:mongomobile/state/aggregation_controller.dart';

void main() {
  const key = AggregationKey(Namespace('shop', 'orders'));
  late ProviderContainer c;
  AggregationController ctrl() => c.read(aggregationProvider(key).notifier);
  AggregationState state() => c.read(aggregationProvider(key));

  setUp(() {
    c = ProviderContainer();
    c.listen(aggregationProvider(key), (_, _) {});
  });
  tearDown(() => c.dispose());

  test(r'starts with a $match stage', () {
    expect(state().stages.single.operator, r'$match');
  });

  test('adds, moves, toggles and removes stages', () {
    ctrl().addStage(r'$limit');
    ctrl().addStage(r'$sort', after: 0);
    expect(state().stages.map((s) => s.operator), [r'$match', r'$sort', r'$limit']);
    final limit = state().stages.last.id;
    ctrl().move(limit, -1);
    expect(state().stages.map((s) => s.operator), [r'$match', r'$limit', r'$sort']);
    ctrl().toggle(limit);
    expect(state().stages[1].enabled, isFalse);
    ctrl().remove(limit);
    expect(state().stages.map((s) => s.operator), [r'$match', r'$sort']);
  });

  test('changing the operator swaps an untouched template only', () {
    final id = state().stages.single.id;
    ctrl().setOperator(id, r'$limit');
    expect(state().stages.single.body, '20');
    ctrl().setBody(id, '{ custom: 1 }');
    ctrl().setOperator(id, r'$match');
    expect(state().stages.single.body, '{ custom: 1 }');
  });

  test('text mode converts both ways', () {
    final id = state().stages.single.id;
    ctrl().setBody(id, '{ paid: true }');
    ctrl().addStage(r'$limit');
    ctrl().setTextMode(true);
    expect(state().textMode, isTrue);
    expect(state().pipeline(), [
      {
        r'$match': {'paid': true},
      },
      {r'$limit': 20},
    ]);
    ctrl().setText(r'[{ $count: "n" }]');
    ctrl().setTextMode(false);
    expect(state().stages.single.operator, r'$count');
    ctrl().setText('nonsense');
    ctrl().setTextMode(true);
    ctrl().setText('{ not: "an array" }');
    expect(() => ctrl().setTextMode(false), throwsFormatException);
    expect(state().textMode, isTrue);
  });

  test('loads saved text and view pipelines', () {
    ctrl().loadText(r'[{ $match: { a: 1 } }, { $limit: 2 }]', name: 'Mine');
    expect(state().name, 'Mine');
    expect(state().stages.length, 2);
    ctrl().loadText('[{ broken', name: 'Odd');
    expect(state().textMode, isTrue);
    ctrl().load([
      {r'$sort': {'a': -1}},
    ]);
    expect(state().stages.single.operator, r'$sort');
  });

  test('collation must have a locale', () {
    ctrl().setCollation('{ strength: 2 }');
    expect(() => state().collation(), throwsFormatException);
    ctrl().setCollation("{ locale: 'fr' }");
    expect(state().collation(), {'locale': 'fr'});
  });

  test('knows when the pipeline writes', () {
    expect(state().writes, isFalse);
    ctrl().addStage(r'$out');
    expect(state().writes, isTrue);
    expect(templateFor(r'$out'), isNotNull);
  });
}
