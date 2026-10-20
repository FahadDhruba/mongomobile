import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mongo_wire/mongo_wire.dart';

import '../../services/explain_summary.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../widgets/common.dart';
import '../widgets/json_highlight.dart';

/// Runs `explain` with execution statistics for [command] (a find or
/// aggregate command) and shows a summary, the plan as a tree, and the raw
/// output, like Compass's Explain Plan.
class ExplainScreen extends ConsumerStatefulWidget {
  const ExplainScreen({
    super.key,
    required this.namespace,
    required this.command,
    this.maxTime,
  });

  final Namespace namespace;
  final Map<String, dynamic> command;
  final Duration? maxTime;

  @override
  ConsumerState<ExplainScreen> createState() => _ExplainScreenState();
}

class _ExplainScreenState extends ConsumerState<ExplainScreen> {
  Map<String, dynamic>? _raw;
  ExplainSummary? _summary;
  String? _error;
  bool _showRaw = false;
  final _cancel = CancelToken();

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _cancel.cancel();
    super.dispose();
  }

  Future<void> _run() async {
    try {
      final raw = await ref
          .read(clientProvider)
          .explain(
            widget.namespace.db,
            widget.command,
            maxTime: widget.maxTime ?? ref.read(settingsProvider).queryTimeout,
            cancel: _cancel,
          );
      if (!mounted) return;
      setState(() {
        _raw = raw;
        _summary = ExplainSummary.parse(raw);
      });
    } on Object catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = _summary;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Explain plan'),
        actions: [
          if (_raw != null)
            TextButton(
              onPressed: () => setState(() => _showRaw = !_showRaw),
              child: Text(_showRaw ? 'Visual' : 'Raw JSON'),
            ),
        ],
      ),
      body: _error != null
          ? ListView(
              padding: const EdgeInsets.all(16),
              children: [MessageBanner(message: _error!)],
            )
          : s == null
          ? const LoadingView(label: 'Running explain…')
          : _showRaw
          ? ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText.rich(
                      highlightJson(
                        EJson.stringify(_raw, mode: EJsonMode.relaxed),
                        monoStyle(context, size: 11.5),
                        c,
                      ),
                    ),
                  ),
                ),
              ],
            )
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Text(
                  EJson.stringify(widget.command, pretty: false),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: monoStyle(context, size: 11.5, color: c.muted),
                ),
                const SizedBox(height: 10),
                _Verdict(summary: s),
                const SizedBox(height: 10),
                _Stats(summary: s),
                const SizedBox(height: 16),
                if (s.root != null) ...[
                  Text(
                    'Query plan',
                    style: TextStyle(
                      color: c.muted,
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Execution starts at the leaves, so show them first.
                  ..._flatten(s.root!).reversed.map(
                    (e) => _StageCard(stage: e.$1, depth: e.$2),
                  ),
                ],
                if (s.pipeline.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Then the pipeline',
                    style: TextStyle(
                      color: c.muted,
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final p in s.pipeline) _StageCard(stage: p, depth: 0),
                ],
              ],
            ),
    );
  }

  /// Depth-first list of (stage, indent), parents before children. Only
  /// branches (stages with several inputs) indent, so a simple chain like
  /// IXSCAN → FETCH → SORT reads as one column.
  static List<(PlanStage, int)> _flatten(PlanStage root) {
    final out = <(PlanStage, int)>[];
    void walk(PlanStage s, int d) {
      out.add((s, d));
      final branch = s.children.length > 1 ? 1 : 0;
      for (final c in s.children) {
        walk(c, d + branch);
      }
    }

    walk(root, 0);
    return out;
  }
}

class _Verdict extends StatelessWidget {
  const _Verdict({required this.summary});
  final ExplainSummary summary;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final notes = <(BannerKind, String)>[
      if (s.collectionScan)
        (
          BannerKind.warning,
          'Collection scan: every document is read. An index on the '
              'filtered fields would make this faster.',
        )
      else if (s.indexes.isNotEmpty)
        (BannerKind.info, 'Uses index ${s.indexes.join(', ')}.'),
      if (s.covered)
        (
          BannerKind.info,
          'Covered query: answered from the index without reading documents.',
        ),
      if (s.sortsInMemory)
        (
          BannerKind.warning,
          'Sorts in memory. An index matching the sort avoids this and its '
              '100 MB limit.',
        ),
      if ((s.examineRatio ?? 0) > 10)
        (
          BannerKind.warning,
          'Reads ${s.examineRatio!.toStringAsFixed(0)} documents for each one '
              'returned.',
        ),
    ];
    return Column(
      children: [
        for (final n in notes)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: MessageBanner(message: n.$2, kind: n.$1),
          ),
      ],
    );
  }
}

class _Stats extends StatelessWidget {
  const _Stats({required this.summary});
  final ExplainSummary summary;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget stat(String label, int? v, {String suffix = ''}) => Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(color: c.muted, fontSize: 11)),
              const SizedBox(height: 4),
              Text(
                v == null ? '—' : '${groupDigits(v)}$suffix',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return Column(
      children: [
        Row(
          children: [
            stat('Returned', summary.returned),
            const SizedBox(width: 8),
            stat('Time', summary.millis, suffix: ' ms'),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            stat('Keys examined', summary.keysExamined),
            const SizedBox(width: 8),
            stat('Docs examined', summary.docsExamined),
          ],
        ),
      ],
    );
  }
}

class _StageCard extends StatelessWidget {
  const _StageCard({required this.stage, required this.depth});
  final PlanStage stage;
  final int depth;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = switch (stage.name) {
      'COLLSCAN' => c.danger,
      'IXSCAN' || 'COUNT_SCAN' || 'DISTINCT_SCAN' => c.accent,
      'SORT' || r'$sort' => c.warning,
      _ => c.text,
    };
    return Padding(
      padding: EdgeInsets.only(left: depth * 14.0, bottom: 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                stage.name,
                style: monoStyle(context, color: color, weight: FontWeight.w700),
              ),
              for (final d in stage.details.entries)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '${d.key}: ',
                          style: TextStyle(color: c.muted, fontSize: 12),
                        ),
                        TextSpan(
                          text: d.value,
                          style: monoStyle(context, size: 12),
                        ),
                      ],
                    ),
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
