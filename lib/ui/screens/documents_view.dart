import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mongo_wire/mongo_wire.dart';

import '../../models/app_settings.dart';
import '../../state/documents_controller.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../widgets/bson_value.dart';
import '../widgets/common.dart';
import '../widgets/document_card.dart';
import '../widgets/document_table.dart';
import '../widgets/query_assist.dart';
import '../widgets/query_bar.dart';
import 'document_editor_screen.dart';
import '../../services/codegen.dart';
import '../../state/query_library.dart';
import 'bulk_screens.dart';
import 'code_export_sheet.dart';
import 'explain_screen.dart';
import 'field_edit_sheet.dart';
import 'export_sheet.dart';
import 'history_sheet.dart';
import 'import_screen.dart';

enum DocumentView { list, json, table }

/// Field paths from a random sample of the collection, for query bar
/// suggestions. Failures (views without $sample, permissions) give none.
final sampledFieldsProvider = FutureProvider.autoDispose
    .family<List<String>, Namespace>((ref, ns) async {
      final client = ref.watch(clientProvider);
      try {
        final reply = await client.runCommand(ns.db, {
          'aggregate': ns.collection,
          'pipeline': [
            {
              r'$sample': {'size': 200},
            },
          ],
          'cursor': {'batchSize': 200},
        }, maxTime: const Duration(seconds: 5));
        final batch =
            ((reply['cursor'] as Map?)?['firstBatch'] as List?) ?? const [];
        return fieldPathsOf(batch.cast<Map<String, dynamic>>());
      } on Object {
        return const [];
      }
    }, dependencies: [clientProvider]);

/// The Documents tab: query bar, toolbar, one page of results and the
/// pagination controls.
class DocumentsView extends ConsumerStatefulWidget {
  const DocumentsView({super.key, required this.namespace, this.info});

  final Namespace namespace;
  final CollectionInfo? info;

  @override
  ConsumerState<DocumentsView> createState() => _DocumentsViewState();
}

class _DocumentsViewState extends ConsumerState<DocumentsView> {
  DocumentView _view = DocumentView.list;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  List<String>? _lastFields;
  Object? _lastSample;
  Object? _lastDocs;

  /// Sampled fields plus those on the current page, cached so the query
  /// bar only rebuilds its suggestions when the inputs change.
  List<String> _mergeFields(
    List<String>? sampled,
    List<Map<String, dynamic>> docs,
  ) {
    if (identical(sampled, _lastSample) &&
        identical(docs, _lastDocs) &&
        _lastFields != null) {
      return _lastFields!;
    }
    _lastSample = sampled;
    _lastDocs = docs;
    final page = fieldPathsOf(docs);
    final merged = <String>{...?sampled, ...page}.toList();
    if (merged.remove('_id')) merged.insert(0, '_id');
    return _lastFields = merged;
  }

  DocumentsController get _ctrl =>
      ref.read(documentsProvider(widget.namespace).notifier);

  void _toTop() {
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  /// Loads the complete document, since the page may use a projection.
  Future<Map<String, dynamic>?> _fetchFull(Object? id) async {
    try {
      final r = await ref
          .read(clientProvider)
          .find(
            widget.namespace,
            FindRequest(
              filter: {'_id': id},
              limit: 1,
              maxTime: ref.read(settingsProvider).queryTimeout,
              maxBytes: 64 << 20,
            ),
          );
      if (r.documents.isEmpty) {
        _snack('The document no longer exists.');
        return null;
      }
      return r.documents.single;
    } on Object catch (e) {
      _snack(describeError(e));
      return null;
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _openEditor(EditorMode mode, String text, {Object? id}) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => DocumentEditorScreen(
          mode: mode,
          namespace: widget.namespace,
          initialText: text,
          originalId: id,
        ),
      ),
    );
    if (saved == true) {
      _snack(switch (mode) {
        EditorMode.edit => 'Document updated',
        _ => 'Document inserted',
      });
      await _ctrl.refresh(countToo: mode != EditorMode.edit);
      ref.invalidate(collectionStatsProvider(widget.namespace));
    }
  }

  Future<void> _openHistory() async {
    await ref.read(queryLibraryProvider.future);
    if (!mounted) return;
    final picked = await showQueryHistory(context, widget.namespace);
    if (picked == null || !mounted) return;
    try {
      final q = QuerySpec.fromTexts(picked.texts);
      _toTop();
      await _ctrl.run(q);
    } on FormatException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _saveFavorite(QuerySpec q) async {
    final name = await askName(context, title: 'Save favourite query');
    if (name == null) return;
    await ref
        .read(queryLibraryProvider.notifier)
        .addFavorite(widget.namespace, name, q.toTexts());
    _snack('Saved "$name" to favourites');
  }

  /// The find command the current query runs, for explain.
  Map<String, dynamic> _findCommand(QuerySpec q) => {
    'find': widget.namespace.collection,
    'filter': q.filter,
    'projection': ?q.projection,
    'sort': ?q.sort,
    if (q.skip > 0) 'skip': q.skip,
    'limit': ?q.limit,
    'collation': ?q.collation,
    'hint': ?q.hint,
  };

  void _explain(QuerySpec q) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ExplainScreen(
          namespace: widget.namespace,
          command: _findCommand(q),
          maxTime: q.maxTime,
        ),
      ),
    );
  }

  void _exportCode(QuerySpec q) {
    final code = CodeQuery(
      filter: q.filter,
      projection: q.projection,
      sort: q.sort,
      skip: q.skip,
      limit: q.limit,
      collation: q.collation,
      hint: q.hint,
      maxTimeMs: q.maxTime?.inMilliseconds,
    );
    showCodeExport(
      context,
      title: 'Export query to language',
      generate: (lang) => findCode(lang, widget.namespace, code),
    );
  }

  Future<void> _edit(Object? id) async {
    final doc = await _fetchFull(id);
    if (doc == null || !mounted) return;
    await _openEditor(EditorMode.edit, EJson.stringify(doc), id: id);
  }

  Future<void> _clone(Object? id) async {
    final doc = await _fetchFull(id);
    if (doc == null || !mounted) return;
    final copy = {...doc}..remove('_id');
    await _openEditor(EditorMode.clone, EJson.stringify(copy));
  }

  /// Edits one top-level field from the Table view with `$set`/`$unset`.
  /// The value comes from the full document, since the page may be
  /// projected.
  Future<void> _editField(Object? id, String field) async {
    final doc = await _fetchFull(id);
    if (doc == null || !mounted) return;
    final client = ref.read(clientProvider);
    Future<String?> write(Map<String, dynamic> update) async {
      try {
        final r = await client.updateOne(widget.namespace, {'_id': id}, update);
        return r.matched == 0
            ? 'The document no longer exists; it may have been deleted.'
            : null;
      } on Object catch (e) {
        return describeError(e);
      }
    }

    final saved = await showFieldEditSheet(
      context,
      field: field,
      value: doc[field],
      missing: !doc.containsKey(field),
      onSave: (v) => write({
        r'$set': {field: v},
      }),
      onRemove: () => write({
        r'$unset': {field: ''},
      }),
    );
    if (saved == true) {
      _snack('Field updated');
      await _ctrl.refresh();
    }
  }

  /// Opens the bulk update or delete screen for the current filter and
  /// refreshes when it changed something.
  Future<void> _bulk(QuerySpec q, {required bool delete}) async {
    final message = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => delete
            ? BulkDeleteScreen(
                namespace: widget.namespace,
                filter: q.filter,
                filterText: q.filterText,
              )
            : BulkUpdateScreen(
                namespace: widget.namespace,
                filter: q.filter,
                filterText: q.filterText,
              ),
      ),
    );
    if (message == null || !mounted) return;
    _snack(message);
    await _ctrl.refresh();
    ref.invalidate(collectionStatsProvider(widget.namespace));
  }

  Future<void> _import() async {
    final message = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => ImportScreen(namespace: widget.namespace),
      ),
    );
    if (!mounted) return;
    // Refresh even after a cancelled import: part of it may be in.
    await _ctrl.refresh();
    ref.invalidate(collectionStatsProvider(widget.namespace));
    if (message != null) _snack(message);
  }

  Future<void> _delete(Object? id) async {
    final ok = await confirmDialog(
      context,
      title: 'Delete document?',
      message:
          'This permanently deletes the document with _id '
          '${shellRepr(id)} from ${widget.namespace}.',
    );
    if (!ok) return;
    try {
      final n = await ref.read(clientProvider).deleteOne(widget.namespace, {
        '_id': id,
      });
      _snack(n == 1 ? 'Document deleted' : 'The document was already gone');
      await _ctrl.refresh();
      ref.invalidate(collectionStatsProvider(widget.namespace));
    } on Object catch (e) {
      _snack(describeError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(documentsProvider(widget.namespace));
    final settings = ref.watch(settingsProvider);
    final readOnly = ref.watch(readOnlyProvider);
    final c = context.colors;
    final isView = widget.info?.isView ?? false;
    final canWrite = !readOnly && !isView && !(widget.info?.readOnly ?? false);

    DocumentActions actionsFor(int i) {
      final id = i < state.ids.length ? state.ids[i] : null;
      if (!canWrite || id == null) return const DocumentActions();
      return DocumentActions(
        onEdit: () => _edit(id),
        onClone: () => _clone(id),
        onDelete: () => _delete(id),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        QueryBar(
          initial: state.query,
          busy: state.loading,
          fields: _mergeFields(
            ref.watch(sampledFieldsProvider(widget.namespace)).value,
            state.documents,
          ),
          onFind: (q) {
            _toTop();
            _ctrl.run(q);
            ref
                .read(queryLibraryProvider.notifier)
                .addRecent(widget.namespace, q.toTexts());
          },
          onReset: () {
            _toTop();
            _ctrl.run(const QuerySpec());
          },
          onHistory: _openHistory,
          onSaveFavorite: _saveFavorite,
        ),
        Divider(height: 1, color: c.border),
        _Toolbar(
          state: state,
          view: _view,
          canInsert: canWrite,
          insertHint: isView
              ? 'Views are read-only'
              : readOnly
              ? 'Turn on write mode to insert'
              : null,
          onView: (v) => setState(() => _view = v),
          onInsert: () => _openEditor(EditorMode.insert, '{\n  \n}'),
          onPageSize: (n) {
            _toTop();
            _ctrl.setPageSize(n);
          },
          onPrevious: () {
            _toTop();
            _ctrl.previous();
          },
          onNext: () {
            _toTop();
            _ctrl.next();
          },
          onRefresh: () => _ctrl.refresh(),
          onExport: () =>
              showExportSheet(context, widget.namespace, query: state.query),
          onExplain: () => _explain(state.query),
          onExportCode: () => _exportCode(state.query),
          onBulkUpdate: canWrite
              ? () => _bulk(state.query, delete: false)
              : null,
          onImport: canWrite ? _import : null,
          onBulkDelete: canWrite
              ? () => _bulk(state.query, delete: true)
              : null,
        ),
        if (state.loading) _RunningBar(onCancel: _ctrl.cancel),
        Expanded(
          child: _Results(
            state: state,
            settings: settings,
            view: _view,
            scroll: _scroll,
            actionsFor: actionsFor,
            onEditField: canWrite
                ? (i, field) {
                    if (i < state.ids.length) _editField(state.ids[i], field);
                  }
                : null,
            onRetry: () => _ctrl.refresh(),
          ),
        ),
      ],
    );
  }
}

class _RunningBar extends StatelessWidget {
  const _RunningBar({required this.onCancel});
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      children: [
        LinearProgressIndicator(
          minHeight: 2,
          color: c.accent,
          backgroundColor: c.border,
        ),
        Container(
          color: c.panel,
          padding: const EdgeInsets.fromLTRB(16, 2, 8, 2),
          child: Row(
            children: [
              Text(
                'Running query…',
                style: TextStyle(color: c.muted, fontSize: 13),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: onCancel,
                style: TextButton.styleFrom(
                  foregroundColor: c.danger,
                  visualDensity: VisualDensity.compact,
                ),
                icon: const Icon(Icons.stop_circle_outlined, size: 18),
                label: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// "1 – 25 of ~2.4M" and friends.
String pageLabel(DocumentsState s) {
  final n = s.documents.length;
  final count = s.count;
  String total() => switch (count.kind) {
    CountKind.loading => ' of …',
    CountKind.estimated => ' of ~${compactCount(count.value!)}',
    CountKind.exact => ' of ${groupDigits(count.value!)}',
    CountKind.unavailable => ' · count unavailable',
  };
  if (n == 0) {
    if (count.kind == CountKind.exact && count.value == 0) return '0 documents';
    return s.offset == 0 ? 'No documents' : 'No more documents';
  }
  return '${groupDigits(s.offset + 1)} – ${groupDigits(s.offset + n)}${total()}';
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.state,
    required this.view,
    required this.canInsert,
    required this.insertHint,
    required this.onView,
    required this.onInsert,
    required this.onPageSize,
    required this.onPrevious,
    required this.onNext,
    required this.onRefresh,
    required this.onExport,
    required this.onExplain,
    required this.onExportCode,
    required this.onBulkUpdate,
    required this.onBulkDelete,
    required this.onImport,
  });

  final DocumentsState state;
  final DocumentView view;
  final bool canInsert;
  final String? insertHint;
  final ValueChanged<DocumentView> onView;
  final VoidCallback onInsert;
  final ValueChanged<int> onPageSize;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onRefresh;
  final VoidCallback onExport;
  final VoidCallback onExplain;
  final VoidCallback onExportCode;

  /// Null in read-only mode.
  final VoidCallback? onBulkUpdate;
  final VoidCallback? onBulkDelete;
  final VoidCallback? onImport;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final insert = AccentButton(
      label: 'Insert Document',
      icon: Icons.add,
      compact: true,
      onPressed: canInsert ? onInsert : null,
    );
    return Container(
      color: c.background,
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
      child: Column(
        children: [
          Row(
            children: [
              insertHint != null
                  ? Tooltip(message: insertHint!, child: insert)
                  : insert,
              const Spacer(),
              SegmentedButton<DocumentView>(
                showSelectedIcon: false,
                style: SegmentedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  selectedBackgroundColor: c.accentStrong,
                  selectedForegroundColor: Colors.white,
                  side: BorderSide(color: c.border),
                ),
                segments: const [
                  ButtonSegment(
                    value: DocumentView.list,
                    icon: Icon(Icons.view_agenda_outlined, size: 18),
                    tooltip: 'List view',
                  ),
                  ButtonSegment(
                    value: DocumentView.json,
                    icon: Icon(Icons.data_object, size: 18),
                    tooltip: 'JSON view',
                  ),
                  ButtonSegment(
                    value: DocumentView.table,
                    icon: Icon(Icons.table_chart_outlined, size: 18),
                    tooltip: 'Table view',
                  ),
                ],
                selected: {view},
                onSelectionChanged: (s) => onView(s.first),
              ),
              PopupMenuButton<String>(
                tooltip: 'More actions',
                icon: const Icon(Icons.more_vert),
                onSelected: (v) => switch (v) {
                  'explain' => onExplain(),
                  'code' => onExportCode(),
                  'export' => onExport(),
                  'update' => onBulkUpdate?.call(),
                  'delete' => onBulkDelete?.call(),
                  'import' => onImport?.call(),
                  _ => null,
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'explain',
                    child: ListTile(
                      leading: Icon(Icons.query_stats),
                      title: Text('Explain plan'),
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'code',
                    child: ListTile(
                      leading: Icon(Icons.code),
                      title: Text('Export query to language'),
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'export',
                    child: ListTile(
                      leading: Icon(Icons.file_download_outlined),
                      title: Text('Export data'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'import',
                    enabled: onImport != null,
                    child: const ListTile(
                      leading: Icon(Icons.file_upload_outlined),
                      title: Text('Import data'),
                      subtitle: Text('JSON or CSV'),
                    ),
                  ),
                  const PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'update',
                    enabled: onBulkUpdate != null,
                    child: const ListTile(
                      leading: Icon(Icons.edit_note),
                      title: Text('Update documents…'),
                      subtitle: Text('All that match the filter'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    enabled: onBulkDelete != null,
                    child: const ListTile(
                      leading: Icon(Icons.delete_sweep_outlined),
                      title: Text('Delete documents…'),
                      subtitle: Text('All that match the filter'),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              _PageSizeMenu(value: state.pageSize, onChanged: onPageSize),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  pageLabel(state),
                  textAlign: TextAlign.right,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: c.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Export',
                visualDensity: VisualDensity.compact,
                onPressed: onExport,
                icon: const Icon(Icons.file_download_outlined, size: 20),
              ),
              IconButton(
                tooltip: 'Refresh',
                visualDensity: VisualDensity.compact,
                onPressed: state.loading ? null : onRefresh,
                icon: const Icon(Icons.refresh, size: 20),
              ),
              IconButton(
                tooltip: 'Previous page',
                visualDensity: VisualDensity.compact,
                onPressed: state.hasPrevious && !state.loading
                    ? onPrevious
                    : null,
                icon: const Icon(Icons.chevron_left),
              ),
              IconButton(
                tooltip: 'Next page',
                visualDensity: VisualDensity.compact,
                onPressed: state.hasNext && !state.loading ? onNext : null,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PageSizeMenu extends StatelessWidget {
  const _PageSizeMenu({required this.value, required this.onChanged});
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return PopupMenuButton<int>(
      tooltip: 'Documents per page',
      initialValue: value,
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final n in AppSettings.pageSizes)
          PopupMenuItem(value: n, child: Text('$n per page')),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: c.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$value', style: TextStyle(color: c.text, fontSize: 13)),
            Icon(Icons.arrow_drop_down, size: 18, color: c.muted),
          ],
        ),
      ),
    );
  }
}

class _Results extends StatelessWidget {
  const _Results({
    required this.state,
    required this.settings,
    required this.view,
    required this.scroll,
    required this.actionsFor,
    required this.onEditField,
    required this.onRetry,
  });

  final DocumentsState state;
  final AppSettings settings;
  final DocumentView view;
  final ScrollController scroll;
  final DocumentActions Function(int index) actionsFor;
  final void Function(int index, String field)? onEditField;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final banners = <Widget>[
      if (state.error != null)
        MessageBanner(
          message: state.error!,
          action: TextButton(onPressed: onRetry, child: const Text('Retry')),
        ),
      if (state.warning != null)
        MessageBanner(message: state.warning!, kind: BannerKind.warning),
      if (state.truncated)
        MessageBanner(
          kind: BannerKind.warning,
          message:
              'This page stopped at ${state.documents.length} documents '
              'because it reached the ${settings.maxPageMegabytes} MB page size '
              'limit. Use a projection or a smaller page size, or raise the '
              'limit in Settings.',
        ),
    ];

    if (!state.loadedOnce && state.loading) {
      return const LoadingView(label: 'Loading documents…');
    }
    if (state.documents.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(12),
        children: [
          ...banners.expand((b) => [b, const SizedBox(height: 8)]),
          if (state.error == null && state.loadedOnce)
            EmptyState(
              icon: Icons.inbox_outlined,
              title: state.query.isDefault
                  ? 'This collection has no documents'
                  : 'No documents match this query',
              message: state.query.isDefault
                  ? 'Insert a document to get started.'
                  : 'Change the filter, or press Reset.',
            ),
        ],
      );
    }
    if (view == DocumentView.table) {
      return DocumentTable(
        documents: state.documents,
        firstRowNumber: state.offset + 1,
        previewLength: settings.stringPreviewLength,
        actionsFor: actionsFor,
        onEditField: onEditField,
        header: banners.isEmpty
            ? null
            : Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: Column(
                  children: [
                    for (final b in banners)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: b,
                      ),
                  ],
                ),
              ),
      );
    }
    return ListView.separated(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: banners.length + state.documents.length + 1,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        if (i < banners.length) return banners[i];
        final j = i - banners.length;
        if (j == state.documents.length) {
          return Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              [
                pageLabel(state),
                if (state.elapsed != null) formatDuration(state.elapsed!),
                if (state.usesKeyset) 'paged by _id' else 'paged by skip',
              ].join('  ·  '),
              textAlign: TextAlign.center,
              style: TextStyle(color: c.muted, fontSize: 12),
            ),
          );
        }
        final doc = state.documents[j];
        final key = ValueKey('${state.offset}-$j-${identityHashCode(doc)}');
        return view == DocumentView.list
            ? DocumentCard(
                key: key,
                document: doc,
                previewLength: settings.stringPreviewLength,
                actions: actionsFor(j),
              )
            : JsonDocumentCard(key: key, document: doc, actions: actionsFor(j));
      },
    );
  }
}
