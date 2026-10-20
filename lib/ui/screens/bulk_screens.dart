import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mongo_wire/mongo_wire.dart';

import '../../services/update_preview.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../widgets/common.dart';
import '../widgets/document_card.dart';
import '../widgets/json_highlight.dart';
import '../widgets/query_assist.dart';

/// How many matching documents the bulk screens preview.
const _previewCount = 3;

/// The filter the bulk action applies to, with the number of documents it
/// matches.
class _FilterPanel extends StatelessWidget {
  const _FilterPanel({
    required this.filter,
    required this.filterText,
    required this.count,
  });

  final Map<String, dynamic> filter;
  final String filterText;
  final AsyncValue<int> count;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Filter', style: TextStyle(color: c.muted, fontSize: 12)),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: c.card,
            border: Border.all(color: c.border),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            filterText.trim().isNotEmpty
                ? filterText.trim()
                : filter.isEmpty
                ? '{}'
                : EJson.stringify(filter, pretty: false),
            style: monoStyle(context, size: 12.5),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          switch (count) {
            AsyncData(:final value) =>
              '${groupDigits(value)} document${value == 1 ? '' : 's'} match'
                  '${filter.isEmpty ? ': every document in the collection' : ''}',
            AsyncError(:final error) => describeError(error),
            _ => 'Counting…',
          },
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: count.hasError ? c.danger : c.text,
          ),
        ),
      ],
    );
  }
}

Future<int> _countMatching(
  WidgetRef ref,
  Namespace ns,
  Map<String, dynamic> filter,
) => ref
    .read(clientProvider)
    .countDocuments(
      ns,
      filter,
      maxTime: ref.read(settingsProvider).queryTimeout,
    );

Future<List<Map<String, dynamic>>> _sample(
  WidgetRef ref,
  Namespace ns,
  Map<String, dynamic> filter,
) async {
  final r = await ref
      .read(clientProvider)
      .find(
        ns,
        FindRequest(
          filter: filter,
          limit: _previewCount,
          maxTime: ref.read(settingsProvider).queryTimeout,
          maxBytes: 16 << 20,
        ),
      );
  return r.documents;
}

/// Updates every document matching a filter with `updateMany`, after
/// previewing the change on the first few.
class BulkUpdateScreen extends ConsumerStatefulWidget {
  const BulkUpdateScreen({
    super.key,
    required this.namespace,
    required this.filter,
    this.filterText = '',
  });

  final Namespace namespace;
  final Map<String, dynamic> filter;

  /// The filter as typed in the query bar.
  final String filterText;

  @override
  ConsumerState<BulkUpdateScreen> createState() => _BulkUpdateScreenState();
}

class _BulkUpdateScreenState extends ConsumerState<BulkUpdateScreen> {
  final _text = JsonEditingController(text: '{\n  \$set: {\n    \n  }\n}');
  AsyncValue<int> _count = const AsyncLoading();
  List<Map<String, dynamic>>? _before;
  List<Map<String, dynamic>>? _after;
  Object? _update;
  String? _problem;
  String? _previewNote;
  String? _submitError;
  bool _saving = false;
  Timer? _debounce;
  int _previewRun = 0;

  @override
  void initState() {
    super.initState();
    _load();
    _text.addListener(() {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 500), _preview);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _text.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final ns = widget.namespace;
    try {
      final n = await _countMatching(ref, ns, widget.filter);
      if (mounted) setState(() => _count = AsyncData(n));
    } on Object catch (e, st) {
      if (mounted) setState(() => _count = AsyncError(e, st));
    }
    try {
      _before = await _sample(ref, ns, widget.filter);
    } on Object catch (e) {
      _before = const [];
      _previewNote = 'Could not load documents to preview: ${describeError(e)}';
    }
    _preview();
  }

  Future<void> _preview() async {
    if (!mounted) return;
    final run = ++_previewRun;
    Object? update;
    try {
      update = EJson.parse(_text.text);
    } on EJsonParseException catch (e) {
      setState(() {
        _update = null;
        _problem = 'Line ${e.line}, column ${e.column}: ${e.message}';
      });
      return;
    }
    final shape = updateShapeError(update);
    final empty =
        update is Map && update.values.every((v) => v is Map && v.isEmpty);
    setState(() {
      _update = shape == null && !empty ? update : null;
      _problem = shape ?? (empty ? 'The update changes nothing yet' : null);
    });
    final before = _before;
    if (_update == null || before == null) return;

    if (update is Map<String, dynamic>) {
      try {
        final after = [for (final d in before) applyUpdate(d, update)];
        setState(() {
          _after = after;
          _previewNote = null;
        });
      } on PreviewUnsupported catch (e) {
        setState(() {
          _after = null;
          _previewNote =
              'No preview for ${e.message}; the server will '
              'still check the update.';
        });
      } on FormatException catch (e) {
        setState(() {
          _after = null;
          _update = null;
          _problem = e.message;
        });
      }
      return;
    }

    // A pipeline update: let the server run the stages on the sample.
    try {
      final r = await ref
          .read(clientProvider)
          .aggregate(
            widget.namespace,
            [
              {r'$match': widget.filter},
              {r'$limit': _previewCount},
              ...(update as List).cast<Map<String, dynamic>>(),
            ],
            limit: _previewCount,
            maxTime: ref.read(settingsProvider).queryTimeout,
          );
      if (!mounted || run != _previewRun) return;
      setState(() {
        _after = r.documents;
        _previewNote = null;
      });
    } on Object catch (e) {
      if (!mounted || run != _previewRun) return;
      setState(() {
        _after = null;
        _update = null;
        _problem = describeError(e);
      });
    }
  }

  Future<void> _submit() async {
    final update = _update;
    final n = _count.value;
    if (update == null) return;
    final ok = await confirmDialog(
      context,
      title: 'Update documents?',
      message:
          'This updates ${n == null ? 'every matching document' : '${groupDigits(n)} document${n == 1 ? '' : 's'}'} '
          'in ${widget.namespace}. It cannot be undone.',
      confirmLabel: 'Update',
    );
    if (!ok || !mounted) return;
    setState(() {
      _saving = true;
      _submitError = null;
    });
    try {
      final r = await ref
          .read(clientProvider)
          .updateMany(widget.namespace, widget.filter, update);
      if (!mounted) return;
      Navigator.pop(
        context,
        'Updated ${groupDigits(r.modified)} of ${groupDigits(r.matched)} '
        'matching document${r.matched == 1 ? '' : 's'}',
      );
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _submitError = describeError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final preview = ref.watch(settingsProvider).stringPreviewLength;
    final n = _count.value;
    final before = _before;
    final after = _after;
    return Scaffold(
      appBar: AppBar(title: const Text('Update documents')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  _FilterPanel(
                    filter: widget.filter,
                    filterText: widget.filterText,
                    count: _count,
                  ),
                  const SizedBox(height: 14),
                  Text(
                    r'Update: operators like $set, $unset, $inc, or a '
                    'pipeline in [ ]',
                    style: TextStyle(color: c.muted, fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  TextField(
                    controller: _text,
                    minLines: 5,
                    maxLines: 14,
                    keyboardType: TextInputType.multiline,
                    autocorrect: false,
                    enableSuggestions: false,
                    inputFormatters: [QueryInputFormatter(wrapInBraces: false)],
                    style: monoStyle(context, size: 13),
                    decoration: InputDecoration(
                      fillColor: c.card,
                      errorText: _problem,
                      errorMaxLines: 3,
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (_previewNote case final note?)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: MessageBanner(
                        message: note,
                        kind: BannerKind.warning,
                      ),
                    ),
                  if (before != null && before.isNotEmpty) ...[
                    Text(
                      'Preview of the first ${before.length}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    for (var i = 0; i < before.length; i++) ...[
                      _PreviewPair(
                        before: before[i],
                        after: after != null && i < after.length
                            ? after[i]
                            : null,
                        previewLength: preview,
                      ),
                      const SizedBox(height: 10),
                    ],
                  ],
                ],
              ),
            ),
            if (_submitError case final error?)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: MessageBanner(message: error),
              ),
            _BottomBar(
              children: [
                const Spacer(),
                TextButton(
                  onPressed: _saving ? null : () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 4),
                AccentButton(
                  label: _saving
                      ? 'Updating…'
                      : n == null
                      ? 'Update'
                      : 'Update ${groupDigits(n)} document${n == 1 ? '' : 's'}',
                  compact: true,
                  onPressed: _saving || _update == null || n == 0
                      ? null
                      : _submit,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One sample document before and after the update, with the changed
/// top-level fields named.
class _PreviewPair extends StatefulWidget {
  const _PreviewPair({
    required this.before,
    required this.after,
    required this.previewLength,
  });

  final Map<String, dynamic> before;
  final Map<String, dynamic>? after;
  final int previewLength;

  @override
  State<_PreviewPair> createState() => _PreviewPairState();
}

class _PreviewPairState extends State<_PreviewPair> {
  bool _showBefore = false;

  List<String> get _changed {
    final after = widget.after;
    if (after == null) return const [];
    String enc(Object? v) => EJson.stringify(v, pretty: false);
    return [
      for (final k in {...widget.before.keys, ...after.keys})
        if (!widget.before.containsKey(k) ||
            !after.containsKey(k) ||
            enc(widget.before[k]) != enc(after[k]))
          k,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final after = widget.after;
    final changed = _changed;
    final showing = _showBefore || after == null ? widget.before : after;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                after == null
                    ? 'Current document'
                    : changed.isEmpty
                    ? 'No change'
                    : 'Changes: ${changed.join(', ')}',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  color: changed.isEmpty ? c.muted : c.accent,
                ),
              ),
            ),
            if (after != null)
              SegmentedButton<bool>(
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: const [
                  ButtonSegment(value: true, label: Text('Before')),
                  ButtonSegment(value: false, label: Text('After')),
                ],
                selected: {_showBefore},
                onSelectionChanged: (s) =>
                    setState(() => _showBefore = s.first),
              ),
          ],
        ),
        const SizedBox(height: 4),
        DocumentCard(document: showing, previewLength: widget.previewLength),
      ],
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 12),
      decoration: BoxDecoration(
        color: c.panel,
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: Row(children: children),
    );
  }
}

/// Deletes every document matching a filter with `deleteMany`, after
/// showing how many there are and the first few.
class BulkDeleteScreen extends ConsumerStatefulWidget {
  const BulkDeleteScreen({
    super.key,
    required this.namespace,
    required this.filter,
    this.filterText = '',
  });

  final Namespace namespace;
  final Map<String, dynamic> filter;

  /// The filter as typed in the query bar.
  final String filterText;

  @override
  ConsumerState<BulkDeleteScreen> createState() => _BulkDeleteScreenState();
}

class _BulkDeleteScreenState extends ConsumerState<BulkDeleteScreen> {
  AsyncValue<int> _count = const AsyncLoading();
  AsyncValue<List<Map<String, dynamic>>> _sampleDocs = const AsyncLoading();
  String? _submitError;
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ns = widget.namespace;
    final count = await AsyncValue.guard(
      () => _countMatching(ref, ns, widget.filter),
    );
    if (mounted) setState(() => _count = count);
    final docs = await AsyncValue.guard(() => _sample(ref, ns, widget.filter));
    if (mounted) setState(() => _sampleDocs = docs);
  }

  Future<void> _submit() async {
    final n = _count.value ?? 0;
    final ok = await confirmDialog(
      context,
      title: 'Delete ${groupDigits(n)} document${n == 1 ? '' : 's'}?',
      message:
          'This permanently deletes every document matching the filter '
          'from ${widget.namespace}. It cannot be undone.',
    );
    if (!ok || !mounted) return;
    setState(() {
      _deleting = true;
      _submitError = null;
    });
    try {
      final deleted = await ref
          .read(clientProvider)
          .deleteMany(widget.namespace, widget.filter);
      if (!mounted) return;
      Navigator.pop(
        context,
        'Deleted ${groupDigits(deleted)} document${deleted == 1 ? '' : 's'}',
      );
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _deleting = false;
        _submitError = describeError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final preview = ref.watch(settingsProvider).stringPreviewLength;
    final n = _count.value;
    return Scaffold(
      appBar: AppBar(title: const Text('Delete documents')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  _FilterPanel(
                    filter: widget.filter,
                    filterText: widget.filterText,
                    count: _count,
                  ),
                  const SizedBox(height: 14),
                  switch (_sampleDocs) {
                    AsyncData(:final value) when value.isNotEmpty => Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'The first ${value.length}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 6),
                        for (final d in value) ...[
                          DocumentCard(document: d, previewLength: preview),
                          const SizedBox(height: 8),
                        ],
                      ],
                    ),
                    AsyncError(:final error) => MessageBanner(
                      message: describeError(error),
                    ),
                    AsyncLoading() => const LinearProgressIndicator(),
                    _ => const SizedBox(),
                  },
                ],
              ),
            ),
            if (_submitError case final error?)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: MessageBanner(message: error),
              ),
            _BottomBar(
              children: [
                const Spacer(),
                TextButton(
                  onPressed: _deleting ? null : () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 4),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: c.danger,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: _deleting || n == null || n == 0 ? null : _submit,
                  child: Text(
                    _deleting
                        ? 'Deleting…'
                        : n == null
                        ? 'Delete'
                        : 'Delete ${groupDigits(n)} document${n == 1 ? '' : 's'}',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
