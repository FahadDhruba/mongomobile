import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mongo_wire/mongo_wire.dart';

import '../../services/schema_analysis.dart';
import '../../state/documents_controller.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../widgets/bson_value.dart';
import '../widgets/common.dart';

/// The Schema tab: samples documents (matching the Documents filter) and
/// shows each field's frequency, types and values.
class SchemaView extends ConsumerStatefulWidget {
  const SchemaView({super.key, required this.namespace});

  final Namespace namespace;

  @override
  ConsumerState<SchemaView> createState() => _SchemaViewState();
}

class _SchemaViewState extends ConsumerState<SchemaView>
    with AutomaticKeepAliveClientMixin {
  int _sampleSize = 1000;
  SchemaAnalysis? _result;
  Map<String, dynamic> _filter = const {};
  bool _loading = false;
  String? _error;
  CancelToken? _cancel;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _cancel?.cancel();
    super.dispose();
  }

  Future<void> _analyze() async {
    _cancel?.cancel();
    final token = _cancel = CancelToken();
    final filter = ref.read(documentsProvider(widget.namespace)).query.filter;
    setState(() {
      _loading = true;
      _error = null;
    });
    final settings = ref.read(settingsProvider);
    try {
      final r = await ref
          .read(clientProvider)
          .aggregate(
            widget.namespace,
            [
              if (filter.isNotEmpty) {r'$match': filter},
              {
                r'$sample': {'size': _sampleSize},
              },
            ],
            limit: _sampleSize,
            maxTime: settings.queryTimeout,
            maxBytes: 64 << 20,
            cancel: token,
          );
      if (!mounted || token.isCancelled) return;
      setState(() {
        _result = SchemaAnalysis.of(r.documents);
        _filter = filter;
        _loading = false;
      });
    } on MongoCancelledError {
      if (mounted) setState(() => _loading = false);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = describeError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final c = context.colors;
    final result = _result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: c.background,
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
          child: Row(
            children: [
              const Text('Sample'),
              const SizedBox(width: 8),
              DropdownButton<int>(
                value: _sampleSize,
                underline: const SizedBox(),
                items: [
                  for (final n in const [100, 1000, 5000])
                    DropdownMenuItem(value: n, child: Text(groupDigits(n))),
                ],
                onChanged: _loading
                    ? null
                    : (v) => setState(() => _sampleSize = v!),
              ),
              const Text('documents'),
              const Spacer(),
              if (_loading)
                TextButton(
                  onPressed: () => _cancel?.cancel(),
                  child: Text('Cancel', style: TextStyle(color: c.danger)),
                )
              else
                AccentButton(
                  label: result == null ? 'Analyze' : 'Analyze again',
                  compact: true,
                  onPressed: _analyze,
                ),
            ],
          ),
        ),
        if (_loading)
          LinearProgressIndicator(
            minHeight: 2,
            color: c.accent,
            backgroundColor: c.border,
          ),
        Divider(height: 1, color: c.border),
        Expanded(
          child: _error != null
              ? ListView(
                  padding: const EdgeInsets.all(12),
                  children: [MessageBanner(message: _error!)],
                )
              : result == null
              ? ListView(
                  children: const [
                    EmptyState(
                      icon: Icons.schema_outlined,
                      title: 'Analyze the schema',
                      message:
                          'Samples documents (matching the filter on the '
                          'Documents tab) and shows each field\'s types and '
                          'values.',
                    ),
                  ],
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
                  children: [
                    Text(
                      'Analyzed ${groupDigits(result.documents)} '
                      'document${result.documents == 1 ? '' : 's'}'
                      '${_filter.isEmpty ? '' : ' matching ${EJson.stringify(_filter, pretty: false)}'}'
                      ' · ${result.fields.length} top-level fields',
                      style: TextStyle(color: c.muted, fontSize: 12.5),
                    ),
                    const SizedBox(height: 10),
                    if (result.documents == 0)
                      const EmptyState(
                        icon: Icons.search_off,
                        title: 'No documents to analyze',
                      ),
                    for (final f in result.sortedFields)
                      _FieldCard(field: f, parentCount: result.documents),
                  ],
                ),
        ),
      ],
    );
  }
}

Color _typeColor(AppColors c, String type) => switch (type) {
  'String' || 'Symbol' => c.string,
  'Int32' || 'Int64' || 'Double' || 'Decimal128' => c.number,
  'Boolean' => c.boolean,
  'Date' || 'Timestamp' => c.date,
  'ObjectId' => c.objectId,
  'Null' || 'Undefined' => c.nullValue,
  'Object' || 'Array' => c.key,
  _ => c.other,
};

/// A number rounded to 6 significant digits for labels.
String _shortNumber(double v) {
  if (v == v.roundToDouble() && v.abs() < 1e15) return '${v.toInt()}';
  var s = v.toStringAsPrecision(6);
  if (s.contains('.') && !s.contains('e')) {
    s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }
  return s;
}

String _percent(int n, int of) {
  if (of == 0) return '0%';
  final p = n * 100 / of;
  return p >= 99.5 && n < of
      ? '>99%'
      : p > 0 && p < 1
      ? '<1%'
      : '${p.round()}%';
}

class _FieldCard extends StatefulWidget {
  const _FieldCard({required this.field, required this.parentCount});

  final SchemaField field;

  /// Documents the field could have appeared in.
  final int parentCount;

  @override
  State<_FieldCard> createState() => _FieldCardState();
}

class _FieldCardState extends State<_FieldCard> {
  String? _selected;
  bool _nestedOpen = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final f = widget.field;
    final types = f.sortedTypes;
    final total = types.fold<int>(0, (s, t) => s + t.count);
    final selected =
        types.where((t) => t.name == _selected).firstOrNull ??
        types.where((t) => t.name != 'Null').firstOrNull ??
        types.first;
    final nested = switch (selected.name) {
      'Object' => selected,
      'Array' => selected.itemTypes['Object'],
      _ => null,
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: c.card,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Text(
                  f.name,
                  overflow: TextOverflow.ellipsis,
                  style: monoStyle(
                    context,
                    size: 13.5,
                    color: c.key,
                    weight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                'in ${_percent(f.count, widget.parentCount)}',
                style: TextStyle(color: c.muted, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              height: 6,
              child: Row(
                children: [
                  for (final t in types)
                    Expanded(
                      flex: t.count,
                      child: Container(color: _typeColor(c, t.name)),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final t in types)
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => setState(() => _selected = t.name),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: t == selected ? _typeColor(c, t.name) : c.border,
                      ),
                    ),
                    child: Text(
                      '${t.name} ${_percent(t.count, total)}',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: t == selected ? c.text : c.muted,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          _TypeSummary(stats: selected),
          if (nested != null && nested.fields.isNotEmpty) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                ),
                onPressed: () => setState(() => _nestedOpen = !_nestedOpen),
                icon: Icon(
                  _nestedOpen ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                ),
                label: Text(
                  '${_nestedOpen ? 'Hide' : 'Show'} ${nested.fields.length} '
                  'nested field${nested.fields.length == 1 ? '' : 's'}',
                ),
              ),
            ),
            if (_nestedOpen)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Column(
                  children: [
                    for (final n in nested.sortedFields)
                      _FieldCard(field: n, parentCount: nested.documents),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _TypeSummary extends StatelessWidget {
  const _TypeSummary({required this.stats});
  final TypeStats stats;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final muted = TextStyle(color: c.muted, fontSize: 12.5);
    final values = stats.values;
    switch (stats.name) {
      case 'Null':
        return Text('${groupDigits(stats.count)} null values', style: muted);
      case 'Object':
        return Text(
          '${stats.fields.length} field${stats.fields.length == 1 ? '' : 's'}',
          style: muted,
        );
      case 'Array':
        final lengths = stats.lengths;
        final avg = lengths.isEmpty
            ? 0
            : lengths.reduce((a, b) => a + b) / lengths.length;
        final min = lengths.isEmpty
            ? 0
            : lengths.reduce((a, b) => a < b ? a : b);
        final max = lengths.isEmpty
            ? 0
            : lengths.reduce((a, b) => a > b ? a : b);
        final items = stats.itemTypes.values.toList()
          ..sort((a, b) => b.count.compareTo(a.count));
        return Text(
          'Length $min – $max (average ${avg.toStringAsFixed(1)})'
          '${items.isEmpty ? '' : ' · items: ${items.map((t) => t.name).join(', ')}'}',
          style: muted,
        );
      case 'Boolean':
        final t = values.where((v) => v == true).length;
        final f = values.length - t;
        return _Bars(
          rows: [('true', t), ('false', f)],
          total: values.length,
          color: c.boolean,
        );
      case 'Int32' ||
          'Int64' ||
          'Double' ||
          'Decimal128' ||
          'Date' ||
          'ObjectId':
        final nums = [for (final v in values) ?numericValue(v)];
        if (nums.isEmpty) return const SizedBox();
        final asDates = stats.name == 'Date' || stats.name == 'ObjectId';
        String label(double v) => asDates
            ? formatIsoDate(
                DateTime.fromMillisecondsSinceEpoch(v.round(), isUtc: true),
              ).replaceFirst('.000', '')
            : _shortNumber(v);
        final finite = nums.where((n) => n.isFinite).toList()..sort();
        final top = topValues(values, limit: 3);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (finite.isNotEmpty) ...[
              _Histogram(
                counts: histogram(finite),
                color: _typeColor(c, stats.name),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      label(finite.first),
                      overflow: TextOverflow.ellipsis,
                      style: monoStyle(context, size: 11.5, color: c.muted),
                    ),
                  ),
                  Text(
                    label(finite.last),
                    style: monoStyle(context, size: 11.5, color: c.muted),
                  ),
                ],
              ),
            ],
            if (!asDates && distinctCount(values) <= 12) ...[
              const SizedBox(height: 6),
              _Bars(
                rows: [for (final v in top) (shellRepr(v.value), v.count)],
                total: values.length,
                color: _typeColor(c, stats.name),
              ),
            ],
          ],
        );
      case 'String':
        final top = topValues(values);
        final distinct = distinctCount(values);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Bars(
              rows: [for (final v in top) ('${v.value}', v.count)],
              total: values.length,
              color: c.string,
            ),
            const SizedBox(height: 4),
            Text(
              '${groupDigits(distinct)} distinct value${distinct == 1 ? '' : 's'}'
              '${values.length < stats.count ? ' in the first ${groupDigits(values.length)}' : ''}',
              style: muted,
            ),
          ],
        );
      default:
        return Text(
          values.take(3).map(shellRepr).join(', '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: monoStyle(context, size: 12, color: c.other),
        );
    }
  }
}

/// Value rows with a bar for each one's share.
class _Bars extends StatelessWidget {
  const _Bars({required this.rows, required this.total, required this.color});

  final List<(String, int)> rows;
  final int total;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      children: [
        for (final (label, n) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 120,
                  child: Text(
                    label.isEmpty ? '""' : label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: monoStyle(context, size: 12),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: total == 0 ? 0 : n / total,
                      minHeight: 8,
                      color: color.withValues(alpha: 0.8),
                      backgroundColor: c.border,
                    ),
                  ),
                ),
                SizedBox(
                  width: 52,
                  child: Text(
                    _percent(n, total),
                    textAlign: TextAlign.right,
                    style: TextStyle(color: c.muted, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Histogram extends StatelessWidget {
  const _Histogram({required this.counts, required this.color});

  final List<int> counts;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final max = counts.fold<int>(0, (m, n) => n > m ? n : m);
    return SizedBox(
      height: 44,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final n in counts)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1),
                child: FractionallySizedBox(
                  heightFactor: max == 0 ? 0 : (n / max).clamp(0.03, 1.0),
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: n == 0 ? 0.15 : 0.75),
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
