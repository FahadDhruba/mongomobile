import 'package:flutter_test/flutter_test.dart';
import 'package:mongo_wire/mongo_wire.dart';
import 'package:mongomobile/services/pipeline.dart';

void main() {
  var id = 0;
  int next() => ++id;

  test('every template parses', () {
    for (final t in stageTemplates) {
      final d = StageDraft(id: 0, operator: t.operator, body: t.template);
      expect(d.parse().keys.single, t.operator, reason: t.operator);
    }
  });

  test('builds the enabled stages up to a point', () {
    final stages = [
      const StageDraft(id: 1, operator: r'$match', body: '{ a: 1 }'),
      const StageDraft(
        id: 2,
        operator: r'$sort',
        body: '{ a: -1 }',
        enabled: false,
      ),
      const StageDraft(id: 3, operator: r'$limit', body: '5'),
    ];
    expect(buildPipeline(stages), [
      {
        r'$match': {'a': 1},
      },
      {r'$limit': 5},
    ]);
    expect(buildPipeline(stages, upTo: 1), [
      {
        r'$match': {'a': 1},
      },
    ]);
  });

  test('names the stage with an error', () {
    final stages = [
      const StageDraft(id: 1, operator: r'$match', body: '{ a: 1 }'),
      const StageDraft(id: 2, operator: r'$group', body: '{ _id: '),
    ];
    expect(
      () => buildPipeline(stages),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          startsWith(r'Stage 2 ($group)'),
        ),
      ),
    );
  });

  test('text and stages convert both ways', () {
    final pipeline = [
      {
        r'$match': {
          'when': {r'$gte': DateTime.utc(2024)},
        },
      },
      {r'$unwind': r'$tags'},
      {r'$limit': 3},
    ];
    final drafts = textToStages(pipelineToText(pipeline), next);
    expect(drafts.map((d) => d.operator), [r'$match', r'$unwind', r'$limit']);
    expect(drafts[1].body, r'"$tags"');
    expect(Bson.encode({'p': buildPipeline(drafts)}),
        Bson.encode({'p': pipeline}));
    // mongosh style works too.
    final shell = textToStages(
      "[{ \$match: { _id: ObjectId('65a1b2c3d4e5f60718293a4b') } }]",
      next,
    );
    expect(buildPipeline(shell).single[r'$match']['_id'], isA<ObjectId>());
  });

  test('rejects text that is not a list of single-operator stages', () {
    expect(() => textToStages('{ a: 1 }', next), throwsFormatException);
    expect(
      () => textToStages(r'[{ $match: {}, $limit: 1 }]', next),
      throwsFormatException,
    );
  });

  test(r'$out and $merge are write stages', () {
    expect(const StageDraft(id: 1, operator: r'$out', body: "'x'").writes, isTrue);
    expect(const StageDraft(id: 1, operator: r'$match', body: '{}').writes, isFalse);
  });
}
