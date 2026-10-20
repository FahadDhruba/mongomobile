import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mongo_wire/mongo_wire.dart';
import 'package:mongomobile/services/explain_summary.dart';

/// Real explain output captured from MongoDB 7.0.
ExplainSummary fixture(String name) => ExplainSummary.parse(
  EJson.parseDocument(File('test/fixtures/$name.json').readAsStringSync()),
);

void main() {
  test('index scan with an in-memory sort', () {
    final s = fixture('explain_ixscan');
    expect(s.indexes, ['status_1']);
    expect(s.collectionScan, isFalse);
    expect(s.sortsInMemory, isTrue);
    expect(s.returned, 10);
    expect(s.keysExamined, 100);
    expect(s.docsExamined, 100);
    expect(s.root!.name, 'SORT');
    expect(s.root!.allNames, containsAllInOrder(['SORT', 'FETCH', 'IXSCAN']));
    final ix = s.root!.children.single.children.single;
    expect(ix.details['index'], 'status_1');
  });

  test('collection scan', () {
    final s = fixture('explain_collscan');
    expect(s.collectionScan, isTrue);
    expect(s.indexes, isEmpty);
    expect(s.docsExamined, 500);
    expect(s.returned, 13);
    expect(s.examineRatio, closeTo(500 / 13, 0.01));
    expect(s.root!.details['filter'], contains('c3'));
  });

  test('covered query', () {
    final s = fixture('explain_covered');
    expect(s.covered, isTrue);
    expect(s.docsExamined, 0);
  });

  test('aggregation with pipeline stages after the cursor', () {
    final s = fixture('explain_aggregate');
    expect(s.indexes, ['status_1']);
    expect(s.pipeline.map((p) => p.name), [r'$group', r'$sort']);
    expect(s.pipeline.first.details['returned'], '32');
    expect(s.sortsInMemory, isTrue);
    expect(s.returned, 400);
  });

  test('lookup pipelines parse too', () {
    final s = fixture('explain_lookup');
    expect(s.pipeline.map((p) => p.name), contains(r'$lookup'));
  });

  test('slot-based engine plans use queryPlan', () {
    final s = ExplainSummary.parse({
      'explainVersion': '2',
      'queryPlanner': {
        'winningPlan': {
          'queryPlan': {
            'stage': 'FETCH',
            'inputStage': {'stage': 'IXSCAN', 'indexName': 'a_1'},
          },
          'slotBasedPlan': {'stages': '...'},
        },
      },
      'executionStats': {
        'nReturned': 3,
        'totalKeysExamined': 3,
        'totalDocsExamined': 3,
        'executionTimeMillis': 1,
        'executionStages': {'stage': 'nlj', 'outerStage': {'stage': 'ixseek'}},
      },
    });
    expect(s.root!.allNames, ['FETCH', 'IXSCAN']);
    expect(s.indexes, ['a_1']);
    expect(s.returned, 3);
  });

  test('sharded plans group per shard', () {
    final s = ExplainSummary.parse({
      'queryPlanner': {
        'winningPlan': {
          'stage': 'SHARD_MERGE',
          'shards': [
            {
              'shardName': 'rs0',
              'winningPlan': {'stage': 'COLLSCAN'},
            },
            {
              'shardName': 'rs1',
              'winningPlan': {
                'stage': 'FETCH',
                'inputStage': {'stage': 'IXSCAN', 'indexName': 'x_1'},
              },
            },
          ],
        },
      },
    });
    expect(s.root!.name, 'SHARD_MERGE');
    expect(s.root!.children.map((c) => c.name), ['Shard rs0', 'Shard rs1']);
    expect(s.collectionScan, isTrue);
    expect(s.indexes, ['x_1']);
  });
}
