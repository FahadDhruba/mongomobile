import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../widgets/common.dart';
import 'package:mongo_wire/mongo_wire.dart';

import '../../state/documents_controller.dart';
import 'collection_admin.dart';
import 'collection_screen.dart';
import 'edit_view_screen.dart';
import 'export_sheet.dart';
import 'explorer_drawer.dart';
import 'overview_screens.dart';
import 'server_activity_screen.dart';
import 'settings_screen.dart';

/// The connected workspace. The drawer picks a database or collection and
/// the body shows it. Back goes collection → database → server → disconnect.
class WorkspaceScreen extends ConsumerStatefulWidget {
  const WorkspaceScreen({super.key});

  @override
  ConsumerState<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends ConsumerState<WorkspaceScreen> {
  final _scaffold = GlobalKey<ScaffoldState>();

  Future<void> _disconnect() async {
    final ok = await confirmDialog(
      context,
      title: 'Disconnect?',
      message:
          'Close the connection to '
          '${ref.read(sessionProvider)?.profile.displayName ?? 'the server'}?',
      confirmLabel: 'Disconnect',
      destructive: false,
    );
    if (!ok || !mounted) return;
    Navigator.of(context).pop();
    await ref.read(sessionProvider.notifier).disconnect();
  }

  Future<void> _toggleWrites(bool readOnly) async {
    if (readOnly) {
      final ok = await confirmDialog(
        context,
        title: 'Turn on write mode?',
        message:
            'You will be able to insert, edit and delete documents and '
            'create or drop indexes on this connection. Read-only mode comes '
            'back the next time you connect.',
        confirmLabel: 'Allow writes',
        destructive: false,
      );
      if (!ok) return;
    }
    ref.read(sessionProvider.notifier).setReadOnly(!readOnly);
  }

  CollectionInfo? _infoOf(Namespace ns) => ref
      .read(collectionsProvider(ns.db))
      .value
      ?.where((c) => c.name == ns.collection)
      .firstOrNull;

  bool _isView(Namespace ns) => _infoOf(ns)?.isView ?? false;

  Future<void> _editView(Namespace view) async {
    final info = _infoOf(view);
    final source = info?.options['viewOn'];
    if (info == null || source is! String) return;
    final pipeline = (info.options['pipeline'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    final updated = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => EditViewScreen(
          view: view,
          source: Namespace(view.db, source),
          pipeline: pipeline,
        ),
      ),
    );
    if (updated == true && mounted) {
      ref.invalidate(documentsProvider(view));
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('View ${view.collection} updated')),
        );
    }
  }

  Future<void> _dropCollection(Namespace ns) async {
    final messenger = ScaffoldMessenger.of(context);
    if (ref.read(readOnlyProvider)) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        const SnackBar(content: Text('Turn on write mode to drop collections')),
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => TypeToConfirmDialog(
        title: 'Drop collection?',
        message:
            'This permanently deletes $ns with all its documents and '
            'indexes. It cannot be undone.',
        name: ns.collection,
        confirmLabel: 'Drop',
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(clientProvider).dropCollection(ns);
      ref.read(selectionProvider.notifier).database(ns.db);
      ref.invalidate(collectionsProvider(ns.db));
      ref.invalidate(collectionStatsProvider(ns));
      ref.invalidate(databasesProvider);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('Collection ${ns.collection} dropped')),
        );
    } on Object catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(describeError(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final selection = ref.watch(selectionProvider);
    final readOnly = ref.watch(readOnlyProvider);
    final c = context.colors;
    if (session == null) return const Scaffold();

    final ns = selection.namespace;
    final Widget body;
    final String title;
    final String? subtitle;
    if (ns != null) {
      body = CollectionScreen(key: ValueKey(ns), namespace: ns);
      title = ns.collection;
      subtitle = ns.db;
    } else if (selection.db != null) {
      body = DatabaseOverview(key: ValueKey(selection.db), db: selection.db!);
      title = selection.db!;
      subtitle = 'Database';
    } else {
      body = const ServerOverview();
      title = session.profile.displayName;
      subtitle = 'Open the menu to browse';
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_scaffold.currentState?.isDrawerOpen ?? false) {
          _scaffold.currentState!.closeDrawer();
          return;
        }
        if (!ref.read(selectionProvider.notifier).up()) _disconnect();
      },
      child: Scaffold(
        key: _scaffold,
        drawer: ExplorerDrawer(
          onDisconnect: () {
            Navigator.pop(context);
            _disconnect();
          },
        ),
        appBar: AppBar(
          titleSpacing: 0,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: c.muted),
              ),
            ],
          ),
          actions: [
            _WriteModeChip(
              readOnly: readOnly,
              onTap: () => _toggleWrites(readOnly),
            ),
            PopupMenuButton<String>(
              tooltip: 'More options',
              onSelected: (v) {
                switch (v) {
                  case 'export':
                    showExportSheet(
                      context,
                      ns!,
                      query: ref.read(documentsProvider(ns)).query,
                    );
                  case 'drop':
                    _dropCollection(ns!);
                  case 'editView':
                    _editView(ns!);
                  case 'rename':
                    renameCollectionFlow(context, ref, ns!);
                  case 'createDb':
                    createCollectionFlow(context, ref);
                  case 'createColl':
                    createCollectionFlow(context, ref, db: selection.db);
                  case 'dropDb':
                    dropDatabaseFlow(context, ref, selection.db!);
                  case 'activity':
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const ServerActivityScreen(),
                      ),
                    );
                  case 'settings':
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const SettingsScreen()),
                    );
                  case 'disconnect':
                    _disconnect();
                }
              },
              itemBuilder: (_) => [
                if (ns != null) ...[
                  if (_isView(ns))
                    const PopupMenuItem(
                      value: 'editView',
                      child: Text('Edit view pipeline…'),
                    ),
                  const PopupMenuItem(
                    value: 'export',
                    child: Text('Export collection…'),
                  ),
                  if (!_isView(ns))
                    const PopupMenuItem(
                      value: 'rename',
                      child: Text('Rename collection…'),
                    ),
                  PopupMenuItem(
                    value: 'drop',
                    child: Text(
                      'Drop collection…',
                      style: TextStyle(color: c.danger),
                    ),
                  ),
                  const PopupMenuDivider(),
                ] else if (selection.db case final db?) ...[
                  const PopupMenuItem(
                    value: 'createColl',
                    child: Text('Create collection…'),
                  ),
                  if (!protectedDatabases.contains(db))
                    PopupMenuItem(
                      value: 'dropDb',
                      child: Text(
                        'Drop database…',
                        style: TextStyle(color: c.danger),
                      ),
                    ),
                  const PopupMenuDivider(),
                ] else ...[
                  const PopupMenuItem(
                    value: 'createDb',
                    child: Text('Create database…'),
                  ),
                  const PopupMenuDivider(),
                ],
                const PopupMenuItem(
                  value: 'activity',
                  child: Text('Server activity'),
                ),
                const PopupMenuItem(value: 'settings', child: Text('Settings')),
                const PopupMenuItem(
                  value: 'disconnect',
                  child: Text('Disconnect'),
                ),
              ],
            ),
          ],
        ),
        body: body,
      ),
    );
  }
}

class _WriteModeChip extends StatelessWidget {
  const _WriteModeChip({required this.readOnly, required this.onTap});
  final bool readOnly;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = readOnly ? c.muted : c.warning;
    return Tooltip(
      message: readOnly
          ? 'Read-only: tap to allow writes'
          : 'Writes allowed: tap to lock',
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withValues(alpha: 0.7)),
            color: color.withValues(alpha: 0.12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                readOnly ? Icons.lock_outline : Icons.edit_note,
                size: 16,
                color: color,
              ),
              const SizedBox(width: 4),
              Text(
                readOnly ? 'Read-only' : 'Writes on',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
