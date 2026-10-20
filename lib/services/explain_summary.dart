import 'package:mongo_wire/mongo_wire.dart';

/// One step of a query plan.
class PlanStage {
  PlanStage(this.name, {this.details = const {}, this.children = const []});

  /// e.g. `IXSCAN`, `FETCH`, `$group`, `Shard rs0`.
  final String name;

  /// Short label → value, e.g. `index: status_1`, `returned: 20`.
  final Map<String, String> details;
  final List<PlanStage> children;

  /// Every stage name in this subtree.
  Iterable<String> get allNames sync* {
    yield name;
    for (final c in children) {
      yield* c.allNames;
    }
  }
}

/// The parts of an explain result worth showing at a glance.
class ExplainSummary {
  ExplainSummary({
    required this.root,
    required this.indexes,
    this.returned,
    this.keysExamined,
    this.docsExamined,
    this.millis,
    this.pipeline = const [],
  });

  /// The query plan as a tree, executed stages where available.
  final PlanStage? root;

  /// Index names the winning plan uses.
  final List<String> indexes;
  final int? returned;
  final int? keysExamined;
  final int? docsExamined;
  final int? millis;

  /// Aggregation stages that run after the query part, in order.
  final List<PlanStage> pipeline;

  Iterable<String> get _names => [
    ...?root?.allNames,
    for (final p in pipeline) ...p.allNames,
  ];

  bool get collectionScan => _names.contains('COLLSCAN');

  bool get sortsInMemory =>
      _names.any((n) => n == 'SORT' || n == r'$sort' || n == 'sort');

  /// Answered from the index alone, without reading documents.
  bool get covered =>
      indexes.isNotEmpty &&
      !_names.contains('FETCH') &&
      !collectionScan &&
      (docsExamined ?? 0) == 0;

  /// Documents read per document returned; high values mean an index
  /// would help.
  double? get examineRatio {
    final r = returned, d = docsExamined;
    if (r == null || d == null || r == 0) return null;
    return d / r;
  }

  static int? _int(Object? v) => switch (v) {
    int() => v,
    BsonLong() => v.value,
    double() => v.round(),
    _ => null,
  };

  static Map<String, dynamic>? _map(Object? v) =>
      v is Map<String, dynamic> ? v : null;

  /// Reads the explain output of a find or aggregate command, from a
  /// standalone server, replica set or sharded cluster, classic or
  /// slot-based engine.
  factory ExplainSummary.parse(Map<String, dynamic> explain) {
    Map<String, dynamic>? planner = _map(explain['queryPlanner']);
    Map<String, dynamic>? stats = _map(explain['executionStats']);
    final pipeline = <PlanStage>[];

    // Aggregations that aren't pushed down list their stages; the first
    // is usually a $cursor holding the query part.
    final stages = explain['stages'];
    if (stages is List) {
      for (final s in stages.whereType<Map<String, dynamic>>()) {
        final cursor = _map(s[r'$cursor']);
        if (cursor != null) {
          planner ??= _map(cursor['queryPlanner']);
          stats ??= _map(cursor['executionStats']);
          continue;
        }
        final name = s.keys.firstWhere(
          (k) => k.startsWith(r'$'),
          orElse: () => 'stage',
        );
        pipeline.add(
          PlanStage(
            name,
            details: {
              if (s['nReturned'] != null)
                'returned': '${_int(s['nReturned'])}',
              if (s['executionTimeMillisEstimate'] != null)
                'time': '${_int(s['executionTimeMillisEstimate'])} ms',
              if (s['usedDisk'] == true) 'disk': 'spilled to disk',
              if (s[name] is Map)
                'spec': EJson.stringify(
                  s[name],
                  mode: EJsonMode.relaxed,
                  pretty: false,
                ),
            },
          ),
        );
      }
    }

    // Sharded: one plan per shard.
    final shards = explain['shards'];
    if (planner == null && shards is Map<String, dynamic>) {
      final children = <PlanStage>[];
      for (final e in shards.entries) {
        final shard = _map(e.value);
        if (shard == null) continue;
        final sub = ExplainSummary.parse(shard);
        children.add(PlanStage('Shard ${e.key}', children: [?sub.root]));
      }
      return ExplainSummary(
        root: PlanStage('SHARD_MERGE', children: children),
        indexes: const [],
        pipeline: pipeline,
      );
    }

    var winning = _map(planner?['winningPlan']);
    // Slot-based engine: the readable plan sits under queryPlan.
    winning = _map(winning?['queryPlan']) ?? winning;
    final execRoot = _map(stats?['executionStages']);
    final execName = '${execRoot?['stage'] ?? ''}';
    // Prefer executed stages (with counts) when they use the classic names.
    final useExec = execRoot != null && execName == execName.toUpperCase();
    final root = useExec
        ? _stage(execRoot)
        : (winning == null ? null : _stage(winning));

    final indexes = <String>{};
    void collect(Object? node) {
      if (node is Map) {
        final name = node['indexName'];
        if (name is String) indexes.add(name);
        node.values.forEach(collect);
      } else if (node is List) {
        node.forEach(collect);
      }
    }

    collect(winning);
    if (stats != null) collect(stats['executionStages']);

    return ExplainSummary(
      root: root,
      indexes: indexes.toList(),
      returned: _int(stats?['nReturned']),
      keysExamined: _int(stats?['totalKeysExamined']),
      docsExamined: _int(stats?['totalDocsExamined']),
      millis: _int(stats?['executionTimeMillis']),
      pipeline: pipeline,
    );
  }

  static const _childKeys = [
    'inputStage',
    'thenStage',
    'elseStage',
    'outerStage',
    'innerStage',
  ];

  static PlanStage _stage(Map<String, dynamic> node) {
    final children = <PlanStage>[];
    for (final key in _childKeys) {
      final c = _map(node[key]);
      if (c != null) children.add(_stage(c));
    }
    for (final key in const ['inputStages', 'shards']) {
      final list = node[key];
      if (list is List) {
        for (final c in list.whereType<Map<String, dynamic>>()) {
          final inner =
              _map(c['executionStages']) ?? _map(c['winningPlan']) ?? c;
          final stage = _stage(inner);
          children.add(
            c['shardName'] != null
                ? PlanStage('Shard ${c['shardName']}', children: [stage])
                : stage,
          );
        }
      }
    }
    String shell(Object? v) =>
        EJson.stringify(v, mode: EJsonMode.relaxed, pretty: false);
    final details = <String, String>{
      if (node['indexName'] != null) 'index': '${node['indexName']}',
      if (node['keyPattern'] != null) 'keys': shell(node['keyPattern']),
      if (node['direction'] != null) 'direction': '${node['direction']}',
      if (node['nReturned'] != null) 'returned': '${_int(node['nReturned'])}',
      if (node['keysExamined'] != null)
        'keys examined': '${_int(node['keysExamined'])}',
      if (node['docsExamined'] != null)
        'docs examined': '${_int(node['docsExamined'])}',
      if (node['executionTimeMillisEstimate'] != null)
        'time': '${_int(node['executionTimeMillisEstimate'])} ms',
      if (node['sortPattern'] != null) 'sort': shell(node['sortPattern']),
      if (node['limitAmount'] != null)
        'limit': '${_int(node['limitAmount'])}',
      if (node['skipAmount'] != null) 'skip': '${_int(node['skipAmount'])}',
      if (node['filter'] != null) 'filter': shell(node['filter']),
      if (node['usedDisk'] == true) 'disk': 'spilled to disk',
    };
    return PlanStage(
      '${node['stage'] ?? 'STAGE'}',
      details: details,
      children: children,
    );
  }
}
