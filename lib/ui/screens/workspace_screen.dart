import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../widgets/common.dart';
import 'package:mongo_wire/mongo_wire.dart';

import '../../state/documents_controller.dart';
import 'collection_admin.dart';
import 'connections_screen.dart';
import 'collection_screen.dart';
import 'edit_view_screen.dart';
import 'export_sheet.dart';
import 'explorer_drawer.dart';
import 'overview_screens.dart';
import 'server_activity_screen.dart';
import 'settings_screen.dart';
import 'shell_screen.dart';

/// Every open connection, one workspace each, with the active one on
/// screen. Each workspace runs in its own [ProviderScope] and [Navigator],
/// so its queries, tabs and the screens it opens belong to that connection
/// and survive switching to another one.
class WorkspaceScreen extends ConsumerStatefulWidget {
  const WorkspaceScreen({super.key});

  @override
  ConsumerState<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends ConsumerState<WorkspaceScreen> {
  final _navigators = <String, GlobalKey<NavigatorState>>{};
  final _workspaces = <String, GlobalKey<ConnectionWorkspaceState>>{};
  bool _leaving = false;

  void _back() {
    final id = ref.read(sessionsProvider).activeId;
    final nav = _navigators[id]?.currentState;
    if (nav != null && nav.canPop()) {
      nav.pop();
      return;
    }
    _workspaces[id]?.currentState?.handleBack();
  }

  @override
  Widget build(BuildContext context) {
    final sessions = ref.watch(sessionsProvider);
    ref.listen(sessionsProvider, (_, next) {
      if (next.all.isEmpty && !_leaving && mounted) {
        _leaving = true;
        Navigator.of(context).pop();
      }
    });
    final ids = {for (final s in sessions.all) s.profile.id};
    _navigators.removeWhere((id, _) => !ids.contains(id));
    _workspaces.removeWhere((id, _) => !ids.contains(id));
    if (sessions.all.isEmpty) return const Scaffold();
    final active = sessions.all.indexWhere(
      (s) => s.profile.id == sessions.activeId,
    );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: IndexedStack(
        index: active < 0 ? 0 : active,
        children: [
          for (final s in sessions.all)
            ProviderScope(
              key: ValueKey(s.profile.id),
              overrides: [
                sessionProvider.overrideWith(
                  (ref) => ref.watch(sessionsProvider).byId(s.profile.id),
                ),
                selectionProvider.overrideWith(SelectionNotifier.new),
              ],
              child: Navigator(
                key: _navigators.putIfAbsent(s.profile.id, GlobalKey.new),
                onGenerateRoute: (_) => MaterialPageRoute<void>(
                  builder: (_) => ConnectionWorkspace(
                    key: _workspaces.putIfAbsent(s.profile.id, GlobalKey.new),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One connection's workspace. The drawer picks a database or collection
/// and the body shows it, with open collections as tabs. Back goes
/// collection → database → server → disconnect.
class ConnectionWorkspace extends ConsumerStatefulWidget {
  const ConnectionWorkspace({super.key});

  @override
  ConsumerState<ConnectionWorkspace> createState() =>
      ConnectionWorkspaceState();
}

class ConnectionWorkspaceState extends ConsumerState<ConnectionWorkspace> {
  final _scaffold = GlobalKey<ScaffoldState>();

  /// System back: closes the drawer, goes up a level, or disconnects.
  void handleBack() {
    if (_scaffold.currentState?.isDrawerOpen ?? false) {
      _scaffold.currentState!.closeDrawer();
      return;
    }
    if (!ref.read(selectionProvider.notifier).up()) _disconnect();
  }

  Future<void> _disconnect() async {
    final session = ref.read(sessionProvider);
    if (session == null) return;
    final ok = await confirmDialog(
      context,
      title: 'Disconnect?',
      message: 'Close the connection to ${session.profile.displayName}?',
      confirmLabel: 'Disconnect',
      destructive: false,
    );
    if (!ok || !mounted) return;
    await ref.read(sessionsProvider.notifier).disconnect(session.profile.id);
  }

  /// Lists the open connections to switch between, close, or add to.
  Future<void> _switcher() async {
    final current = ref.read(sessionProvider)?.profile.id;
    final c = context.colors;
    final choice = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => Consumer(
        builder: (ctx, ref, _) {
          final sessions = ref.watch(sessionsProvider);
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    'Open connections',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
                for (final s in sessions.all)
                  ListTile(
                    leading: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color:
                            connectionColors[s.profile.colorIndex %
                                connectionColors.length],
                        shape: BoxShape.circle,
                      ),
                    ),
                    title: Text(s.profile.displayName),
                    subtitle: Text(
                      s.client.server.address,
                      style: TextStyle(color: c.muted, fontSize: 12),
                    ),
                    selected: s.profile.id == current,
                    onTap: () => Navigator.pop(ctx, s.profile.id),
                    trailing: IconButton(
                      tooltip: 'Disconnect ${s.profile.displayName}',
                      onPressed: () => ref
                          .read(sessionsProvider.notifier)
                          .disconnect(s.profile.id),
                      icon: const Icon(Icons.close),
                    ),
                  ),
                ListTile(
                  leading: const Icon(Icons.add),
                  title: const Text('Open another connection'),
                  onTap: () => Navigator.pop(ctx, '+'),
                ),
              ],
            ),
          );
        },
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == '+') {
      await Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(
          builder: (_) => const ConnectionsScreen(picking: true),
        ),
      );
    } else {
      ref.read(sessionsProvider.notifier).activate(choice);
    }
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
    final id = ref.read(sessionProvider)?.profile.id;
    if (id != null) {
      ref.read(sessionsProvider.notifier).setReadOnly(id, !readOnly);
    }
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
      ref
          .read(selectionProvider.notifier)
          .dropped(db: ns.db, collection: ns.collection);
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
    final Widget overview;
    final String title;
    final String subtitle;
    if (ns != null) {
      overview = const SizedBox();
      title = ns.collection;
      subtitle = ns.db;
    } else if (selection.db != null) {
      overview = DatabaseOverview(
        key: ValueKey(selection.db),
        db: selection.db!,
      );
      title = selection.db!;
      subtitle = 'Database';
    } else {
      overview = const ServerOverview();
      title = session.profile.displayName;
      subtitle = 'Open the menu to browse';
    }
    final tabs = selection.tabs;
    // Open collections stay built, so each keeps its query and page.
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (tabs.isNotEmpty)
          _TabStrip(
            tabs: tabs,
            active: ns,
            onSelect: (t) => ref
                .read(selectionProvider.notifier)
                .collection(t.db, t.collection),
            onClose: (t) => ref.read(selectionProvider.notifier).closeTab(t),
          ),
        Expanded(
          child: IndexedStack(
            index: ns == null ? tabs.length : tabs.indexOf(ns),
            children: [
              for (final t in tabs)
                CollectionScreen(key: ValueKey(t), namespace: t),
              overview,
            ],
          ),
        ),
      ],
    );
    final others = ref.watch(sessionsProvider).all.length - 1;

    return KeyedSubtree(
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
          title: InkWell(
            onTap: _switcher,
            child: Row(
              children: [
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text(
                        others > 0
                            ? '$subtitle · ${session.profile.displayName}'
                            : subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: c.muted),
                      ),
                    ],
                  ),
                ),
                Tooltip(
                  message: 'Switch connection',
                  child: Icon(Icons.arrow_drop_down, color: c.muted),
                ),
                if (others > 0) Pill('+$others', color: c.accent),
              ],
            ),
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
                  case 'shell':
                    openShell(context, db: selection.db);
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
                const PopupMenuItem(value: 'shell', child: Text('Shell')),
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

/// The open collections, as tabs with a close button.
class _TabStrip extends StatelessWidget {
  const _TabStrip({
    required this.tabs,
    required this.active,
    required this.onSelect,
    required this.onClose,
  });

  final List<Namespace> tabs;
  final Namespace? active;
  final ValueChanged<Namespace> onSelect;
  final ValueChanged<Namespace> onClose;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      height: 38,
      decoration: BoxDecoration(
        color: c.background,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        children: [
          for (final t in tabs)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
              child: Material(
                color: t == active ? c.card : Colors.transparent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                  side: BorderSide(color: t == active ? c.accent : c.border),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => onSelect(t),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          t.collection,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: t == active
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: t == active ? c.text : c.muted,
                          ),
                        ),
                        SizedBox(
                          width: 30,
                          height: 28,
                          child: IconButton(
                            tooltip: 'Close ${t.collection}',
                            padding: EdgeInsets.zero,
                            iconSize: 15,
                            onPressed: () => onClose(t),
                            icon: Icon(Icons.close, color: c.muted),
                          ),
                        ),
                      ],
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
