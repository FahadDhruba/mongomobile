import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mongo_wire/mongo_wire.dart';

import '../../services/codegen.dart';
import '../../services/pipeline.dart';
import '../../state/aggregation_controller.dart';
import '../../state/providers.dart';
import '../../state/query_library.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../widgets/common.dart';
import '../widgets/document_card.dart';
import '../widgets/json_highlight.dart';
import '../widgets/query_assist.dart';
import 'aggregation_results_screen.dart';
import 'code_export_sheet.dart';
import 'explain_screen.dart';
import 'history_sheet.dart';

/// The Aggregations tab: build a pipeline stage by stage with a preview of
/// each stage's output, as in Compass. With [AggregationKey.view] set it
/// edits that view's definition instead.
class AggregationsView extends ConsumerStatefulWidget {
  const AggregationsView({super.key, required this.aggregationKey, this.info});

  final AggregationKey aggregationKey;
  final CollectionInfo? info;

  @override
  ConsumerState<AggregationsView> createState() => _AggregationsViewState();
}

class _AggregationsViewState extends ConsumerState<AggregationsView> {
  late final JsonEditingController _text;
  String? _error;
  final _scroll = ScrollController();

  AggregationKey get _key => widget.aggregationKey;
  Namespace get _ns => _key.source;
  AggregationController get _ctrl =>
      ref.read(aggregationProvider(_key).notifier);

  @override
  void initState() {
    super.initState();
    _text = JsonEditingController(
      text: ref.read(aggregationProvider(_key)).text,
    );
  }

  @override
  void dispose() {
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// The pipeline, or null after showing why it doesn't parse.
  List<Map<String, dynamic>>? _pipeline() {
    try {
      final p = ref.read(aggregationProvider(_key)).pipeline();
      setState(() => _error = null);
      return p;
    } on FormatException catch (e) {
      setState(() => _error = e.message);
      return null;
    }
  }

  Map<String, dynamic>? _collation() {
    try {
      return ref.read(aggregationProvider(_key)).collation();
    } on FormatException catch (e) {
      setState(() => _error = e.message);
      throw const _Handled();
    }
  }

  Future<void> _run() async {
    final pipeline = _pipeline();
    if (pipeline == null) return;
    final Map<String, dynamic>? collation;
    try {
      collation = _collation();
    } on _Handled {
      return;
    }
    final writes =
        pipeline.isNotEmpty &&
        (pipeline.last.containsKey(r'$out') ||
            pipeline.last.containsKey(r'$merge'));
    if (writes) {
      if (ref.read(readOnlyProvider)) {
        _snack(r'Turn on write mode to run a pipeline with $out or $merge');
        return;
      }
      final ok = await confirmDialog(
        context,
        title: 'Run and write the output?',
        message:
            'The last stage writes its results to a collection, replacing '
            r'or merging documents there ($out replaces the whole target).',
        confirmLabel: 'Run',
        destructive: false,
      );
      if (!ok) return;
      try {
        await ref
            .read(clientProvider)
            .aggregate(
              _ns,
              pipeline,
              limit: 1,
              collation: collation,
              maxTime: ref.read(settingsProvider).queryTimeout,
            );
        ref.invalidate(collectionsProvider(_ns.db));
        _snack('Pipeline ran and wrote its output');
      } on Object catch (e) {
        _snack(describeError(e));
      }
      return;
    }
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AggregationResultsScreen(
          namespace: _ns,
          pipeline: pipeline,
          collation: collation,
        ),
      ),
    );
  }

  Future<void> _save({bool asNew = false}) async {
    final state = ref.read(aggregationProvider(_key));
    if (_pipeline() == null) return;
    var name = state.name;
    if (name == null || asNew) {
      name = await askName(
        context,
        title: 'Save pipeline',
        initial: asNew ? '' : (state.name ?? ''),
      );
      if (name == null) return;
    }
    final text = state.textMode
        ? state.text
        : pipelineToText(buildPipeline(state.stages));
    await ref
        .read(queryLibraryProvider.notifier)
        .savePipeline(_ns, name, text);
    _ctrl.setName(name);
    _snack('Pipeline "$name" saved');
  }

  Future<void> _openSaved() async {
    await ref.read(queryLibraryProvider.future);
    if (!mounted) return;
    final lib = ref.read(queryLibraryProvider.notifier).of(_ns);
    final picked = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      builder: (ctx) => _SavedPipelines(namespace: _ns, initial: lib.pipelines),
    );
    if (picked == null) return;
    final saved = lib.pipelines.firstWhere((p) => p.name == picked);
    _ctrl.loadText(saved.texts['pipeline'] ?? '[]', name: saved.name);
    _text.text = ref.read(aggregationProvider(_key)).text;
  }

  void _toggleText(bool on) {
    try {
      if (!on) _ctrl.setText(_text.text);
      _ctrl.setTextMode(on);
      _text.text = ref.read(aggregationProvider(_key)).text;
      setState(() => _error = null);
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    }
  }

  void _exportCode() {
    final pipeline = _pipeline();
    if (pipeline == null) return;
    Map<String, dynamic>? collation;
    try {
      collation = _collation();
    } on _Handled {
      return;
    }
    showCodeExport(
      context,
      title: 'Export pipeline to language',
      generate: (lang) =>
          aggregateCode(lang, _ns, pipeline, collation: collation),
    );
  }

  void _explain() {
    final pipeline = _pipeline();
    if (pipeline == null) return;
    Map<String, dynamic>? collation;
    try {
      collation = _collation();
    } on _Handled {
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ExplainScreen(
          namespace: _ns,
          command: {
            'aggregate': _ns.collection,
            'pipeline': pipeline,
            'cursor': <String, dynamic>{},
            'collation': ?collation,
          },
        ),
      ),
    );
  }

  Future<void> _editCollation() async {
    final state = ref.read(aggregationProvider(_key));
    final controller = TextEditingController(text: state.collationText);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Collation'),
        content: TextField(
          controller: controller,
          style: monoStyle(ctx),
          inputFormatters: [QueryInputFormatter()],
          decoration: const InputDecoration(
            hintText: "{ locale: 'en', strength: 2 }",
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, ''),
            child: const Text('Clear'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (result != null) _ctrl.setCollation(result);
  }

  Future<void> _createView() async {
    final pipeline = _pipeline();
    if (pipeline == null) return;
    if (ref.read(readOnlyProvider)) {
      _snack('Turn on write mode to create a view');
      return;
    }
    if (pipeline.any(
      (s) => s.containsKey(r'$out') || s.containsKey(r'$merge'),
    )) {
      _snack(r'Views cannot contain $out or $merge');
      return;
    }
    final name = await askName(
      context,
      title: 'Create view',
      hint: 'View name',
      confirm: 'Create',
    );
    if (name == null) return;
    try {
      await ref
          .read(clientProvider)
          .createCollection(Namespace(_ns.db, name), {
            'viewOn': _ns.collection,
            'pipeline': pipeline,
          });
      ref.invalidate(collectionsProvider(_ns.db));
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('View $name created'),
            action: SnackBarAction(
              label: 'Open',
              onPressed: () =>
                  ref.read(selectionProvider.notifier).collection(_ns.db, name),
            ),
          ),
        );
    } on Object catch (e) {
      _snack(describeError(e));
    }
  }

  Future<void> _updateView() async {
    final view = _key.view!;
    final pipeline = _pipeline();
    if (pipeline == null) return;
    if (ref.read(readOnlyProvider)) {
      _snack('Turn on write mode to change the view');
      return;
    }
    try {
      await ref.read(clientProvider).modifyCollection(view, {
        'viewOn': _ns.collection,
        'pipeline': pipeline,
      });
      ref.invalidate(collectionsProvider(view.db));
      if (mounted) Navigator.pop(context, true);
    } on Object catch (e) {
      _snack(describeError(e));
    }
  }

  Future<void> _addStage({int? after}) async {
    final op = await showStagePicker(context);
    if (op == null) return;
    _ctrl.addStage(op, after: after);
    if (after == null) {
      // Show the new stage at the end.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final state = ref.watch(aggregationProvider(_key));
    final editingView = _key.view != null;

    final header = Container(
      color: c.panel,
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  editingView
                      ? 'View ${_key.view!.collection} on ${_ns.collection}'
                      : (state.name ?? 'Untitled pipeline'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  [
                    state.textMode ? 'Text' : '${state.stages.length} stages',
                    if (state.collationText.trim().isNotEmpty) 'collation set',
                  ].join(' · '),
                  style: TextStyle(color: c.muted, fontSize: 12),
                ),
              ],
            ),
          ),
          SegmentedButton<bool>(
            showSelectedIcon: false,
            style: SegmentedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              selectedBackgroundColor: c.accentStrong,
              selectedForegroundColor: Colors.white,
            ),
            segments: const [
              ButtonSegment(
                value: false,
                icon: Icon(Icons.view_agenda_outlined, size: 18),
                tooltip: 'Stages',
              ),
              ButtonSegment(
                value: true,
                icon: Icon(Icons.data_array, size: 18),
                tooltip: 'Text',
              ),
            ],
            selected: {state.textMode},
            onSelectionChanged: (v) => _toggleText(v.first),
          ),
          PopupMenuButton<String>(
            tooltip: 'Pipeline actions',
            onSelected: (v) => switch (v) {
              'open' => _openSaved(),
              'save' => _save(),
              'saveAs' => _save(asNew: true),
              'new' => () {
                _ctrl.clear();
                _text.text = '[]';
              }(),
              'collation' => _editCollation(),
              'code' => _exportCode(),
              'explain' => _explain(),
              'view' => _createView(),
              _ => null,
            },
            itemBuilder: (_) => [
              if (!editingView) ...[
                const PopupMenuItem(
                  value: 'open',
                  child: Text('Open saved pipeline…'),
                ),
                const PopupMenuItem(value: 'save', child: Text('Save')),
                const PopupMenuItem(value: 'saveAs', child: Text('Save as…')),
                const PopupMenuItem(value: 'new', child: Text('New pipeline')),
                const PopupMenuDivider(),
              ],
              const PopupMenuItem(value: 'collation', child: Text('Collation…')),
              const PopupMenuItem(value: 'explain', child: Text('Explain')),
              const PopupMenuItem(
                value: 'code',
                child: Text('Export to language'),
              ),
              if (!editingView)
                const PopupMenuItem(value: 'view', child: Text('Create view…')),
            ],
          ),
        ],
      ),
    );

    final Widget body;
    if (state.textMode) {
      body = Padding(
        padding: const EdgeInsets.all(12),
        child: TextField(
          controller: _text,
          expands: true,
          maxLines: null,
          textAlignVertical: TextAlignVertical.top,
          keyboardType: TextInputType.multiline,
          autocorrect: false,
          enableSuggestions: false,
          inputFormatters: [QueryInputFormatter(wrapInBraces: false)],
          style: monoStyle(context, size: 12.5),
          onChanged: _ctrl.setText,
          decoration: InputDecoration(
            fillColor: c.card,
            hintText: "[\n  { \$match: { status: 'paid' } }\n]",
          ),
        ),
      );
    } else {
      body = ListView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          for (var i = 0; i < state.stages.length; i++)
            _StageCard(
              key: ValueKey(state.stages[i].id),
              aggregationKey: _key,
              index: i,
              stages: state.stages,
              collationText: state.collationText,
              onAddAfter: () => _addStage(after: i),
            ),
          OutlinedButton.icon(
            onPressed: _addStage,
            icon: const Icon(Icons.add),
            label: const Text('Add stage'),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        Divider(height: 1, color: c.border),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: MessageBanner(
              message: _error!,
              onDismiss: () => setState(() => _error = null),
            ),
          ),
        Expanded(child: body),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          decoration: BoxDecoration(
            color: c.panel,
            border: Border(top: BorderSide(color: c.border)),
          ),
          child: SafeArea(
            top: false,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    state.writes
                        ? r'Ends in $out/$merge: Run writes the output.'
                        : 'Previews show up to $previewSize documents per stage.',
                    style: TextStyle(color: c.muted, fontSize: 12),
                  ),
                ),
                if (editingView)
                  AccentButton(
                    label: 'Update view',
                    compact: true,
                    onPressed: _updateView,
                  )
                else
                  AccentButton(
                    label: 'Run',
                    icon: Icons.play_arrow,
                    compact: true,
                    onPressed: _run,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Handled implements Exception {
  const _Handled();
}

/// Documents shown in each stage's preview.
const previewSize = 10;

/// Lets the user pick a stage operator; returns it, or null.
Future<String?> showStagePicker(BuildContext context) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const FractionallySizedBox(
        heightFactor: 0.8,
        child: _StagePicker(),
      ),
    );

class _StagePicker extends StatefulWidget {
  const _StagePicker();

  @override
  State<_StagePicker> createState() => _StagePickerState();
}

class _StagePickerState extends State<_StagePicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final q = _query.toLowerCase();
    final items = stageTemplates
        .where(
          (t) =>
              q.isEmpty ||
              t.operator.toLowerCase().contains(q) ||
              t.summary.toLowerCase().contains(q),
        )
        .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: TextField(
            autofocus: false,
            decoration: const InputDecoration(
              hintText: r'Search stages, e.g. $group or join',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (v) => setState(() => _query = v.trim()),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: items.length,
            itemBuilder: (_, i) => ListTile(
              title: Text(
                items[i].operator,
                style: monoStyle(context, color: c.accent, weight: FontWeight.w700),
              ),
              subtitle: Text(items[i].summary),
              onTap: () => Navigator.pop(context, items[i].operator),
            ),
          ),
        ),
      ],
    );
  }
}

/// One stage: operator, value editor, on/off switch, and a preview of the
/// documents coming out of it.
class _StageCard extends ConsumerStatefulWidget {
  const _StageCard({
    super.key,
    required this.aggregationKey,
    required this.index,
    required this.stages,
    required this.collationText,
    required this.onAddAfter,
  });

  final AggregationKey aggregationKey;
  final int index;
  final List<StageDraft> stages;
  final String collationText;
  final VoidCallback onAddAfter;

  @override
  ConsumerState<_StageCard> createState() => _StageCardState();
}

class _StageCardState extends ConsumerState<_StageCard> {
  late final _body = JsonEditingController(text: _stage.body);
  bool _previewOpen = false;
  bool _loading = false;
  FindResult? _preview;
  String? _previewError;
  String? _signature;
  Timer? _debounce;
  CancelToken? _cancel;

  StageDraft get _stage => widget.stages[widget.index];
  AggregationController get _ctrl =>
      ref.read(aggregationProvider(widget.aggregationKey).notifier);

  /// Changes whenever this stage's input or itself changes.
  String get _currentSignature => [
    for (var i = 0; i <= widget.index; i++)
      if (widget.stages[i].enabled)
        '${widget.stages[i].operator}:${widget.stages[i].body}',
    widget.collationText,
  ].join('\u0000');

  @override
  void didUpdateWidget(covariant _StageCard old) {
    super.didUpdateWidget(old);
    if (_body.text != _stage.body) _body.text = _stage.body;
    if (_previewOpen && _currentSignature != _signature) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 700), _runPreview);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _cancel?.cancel();
    _body.dispose();
    super.dispose();
  }

  Future<void> _runPreview() async {
    if (!mounted) return;
    _signature = _currentSignature;
    if (_stage.writes) {
      setState(() {
        _preview = null;
        _previewError = null;
      });
      return;
    }
    List<Map<String, dynamic>> pipeline;
    Map<String, dynamic>? collation;
    try {
      pipeline = buildPipeline(widget.stages, upTo: widget.index);
      collation = ref
          .read(aggregationProvider(widget.aggregationKey))
          .collation();
    } on FormatException catch (e) {
      setState(() {
        _previewError = e.message;
        _preview = null;
      });
      return;
    }
    _cancel?.cancel();
    final token = _cancel = CancelToken();
    setState(() {
      _loading = true;
      _previewError = null;
    });
    try {
      final r = await ref
          .read(clientProvider)
          .aggregate(
            widget.aggregationKey.source,
            [
              ...pipeline,
              {r'$limit': previewSize},
            ],
            limit: previewSize,
            collation: collation,
            maxTime: ref.read(settingsProvider).queryTimeout,
            cancel: token,
          );
      if (!mounted || token.isCancelled) return;
      setState(() {
        _preview = r;
        _loading = false;
      });
    } on MongoCancelledError {
      if (mounted) setState(() => _loading = false);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _previewError = describeError(e);
        _preview = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = _stage;
    String? error;
    try {
      s.parse();
    } on FormatException catch (e) {
      error = e.message;
    }
    final last = widget.index == widget.stages.length - 1;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Opacity(
        opacity: s.enabled ? 1 : 0.55,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text(
                      'Stage ${widget.index + 1}',
                      style: TextStyle(color: c.muted, fontSize: 12),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: () async {
                          final op = await showStagePicker(context);
                          if (op != null) _ctrl.setOperator(s.id, op);
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 4,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  s.operator,
                                  overflow: TextOverflow.ellipsis,
                                  style: monoStyle(
                                    context,
                                    size: 14,
                                    color: c.accent,
                                    weight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              Icon(Icons.arrow_drop_down, color: c.muted),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const Spacer(),
                    Switch(
                      value: s.enabled,
                      onChanged: (_) => _ctrl.toggle(s.id),
                    ),
                    PopupMenuButton<String>(
                      tooltip: 'Stage actions',
                      onSelected: (v) => switch (v) {
                        'up' => _ctrl.move(s.id, -1),
                        'down' => _ctrl.move(s.id, 1),
                        'add' => widget.onAddAfter(),
                        'delete' => _ctrl.remove(s.id),
                        _ => null,
                      },
                      itemBuilder: (_) => [
                        if (widget.index > 0)
                          const PopupMenuItem(value: 'up', child: Text('Move up')),
                        if (!last)
                          const PopupMenuItem(
                            value: 'down',
                            child: Text('Move down'),
                          ),
                        const PopupMenuItem(
                          value: 'add',
                          child: Text('Add stage after'),
                        ),
                        const PopupMenuItem(
                          value: 'delete',
                          child: Text('Delete stage'),
                        ),
                      ],
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: TextField(
                    controller: _body,
                    minLines: 1,
                    maxLines: 12,
                    keyboardType: TextInputType.multiline,
                    autocorrect: false,
                    enableSuggestions: false,
                    inputFormatters: [QueryInputFormatter(wrapInBraces: false)],
                    style: monoStyle(context, size: 12.5),
                    onChanged: (v) => _ctrl.setBody(s.id, v),
                    decoration: InputDecoration(
                      errorText: error,
                      errorMaxLines: 3,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                InkWell(
                  onTap: () {
                    setState(() => _previewOpen = !_previewOpen);
                    if (_previewOpen) _runPreview();
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Icon(
                          _previewOpen ? Icons.expand_more : Icons.chevron_right,
                          size: 18,
                          color: c.muted,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            _previewLabel(),
                            style: TextStyle(color: c.muted, fontSize: 12.5),
                          ),
                        ),
                        if (_loading)
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: c.accent,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (_previewOpen) ..._previewBody(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _previewLabel() {
    if (_stage.writes) return 'Output: written by Run';
    final p = _preview;
    if (!_previewOpen || p == null) return 'Output preview';
    final n = p.documents.length;
    return 'Output: ${n == previewSize ? 'first $n' : '$n'} '
        '${n == 1 ? 'document' : 'documents'} · ${formatDuration(p.elapsed)}';
  }

  List<Widget> _previewBody(BuildContext context) {
    final c = context.colors;
    if (_stage.writes) {
      return [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 8, 0),
          child: Text(
            '${_stage.operator} writes to a collection, so there is no preview. '
            'Run the pipeline to write the output.',
            style: TextStyle(color: c.muted, fontSize: 12.5),
          ),
        ),
      ];
    }
    if (_previewError != null) {
      return [
        Padding(
          padding: const EdgeInsets.only(right: 8, top: 4),
          child: MessageBanner(message: _previewError!),
        ),
      ];
    }
    final docs = _preview?.documents ?? const [];
    if (_preview != null && docs.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 8, 0),
          child: Text(
            'No documents come out of this stage.',
            style: TextStyle(color: c.muted, fontSize: 12.5),
          ),
        ),
      ];
    }
    // A sideways row of small cards, like Compass, so long pipelines stay
    // readable.
    return [
      SizedBox(
        height: 210,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.only(top: 6, right: 8),
          itemCount: docs.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (_, i) => Container(
            width: 250,
            decoration: BoxDecoration(
              color: c.background,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: c.border),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(6, 8, 8, 8),
              child: FieldList(
                entries: docs[i].entries.toList(),
                previewLength: 80,
                initialCount: 12,
              ),
            ),
          ),
        ),
      ),
    ];
  }
}

class _SavedPipelines extends ConsumerWidget {
  const _SavedPipelines({required this.namespace, required this.initial});

  final Namespace namespace;
  final List<Object> initial;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    ref.watch(queryLibraryProvider);
    final notifier = ref.read(queryLibraryProvider.notifier);
    final pipelines = notifier.of(namespace).pipelines;
    if (pipelines.isEmpty) {
      return const SizedBox(
        height: 260,
        child: EmptyState(
          icon: Icons.folder_open,
          title: 'No saved pipelines',
          message: 'Use Save in the pipeline menu to keep one here.',
        ),
      );
    }
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        for (final p in pipelines)
          ListTile(
            leading: Icon(Icons.account_tree_outlined, color: c.accent),
            title: Text(p.name ?? 'Pipeline'),
            subtitle: Text(
              (p.texts['pipeline'] ?? '').replaceAll(RegExp(r'\s+'), ' '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: monoStyle(context, size: 11.5, color: c.muted),
            ),
            trailing: IconButton(
              tooltip: 'Delete',
              icon: Icon(Icons.close, color: c.muted),
              onPressed: () => notifier.removePipeline(namespace, p),
            ),
            onTap: () => Navigator.pop(context, p.name),
          ),
      ],
    );
  }
}
