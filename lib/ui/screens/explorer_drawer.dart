import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mongo_wire/mongo_wire.dart';

import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../widgets/common.dart';

/// The navigation drawer: the connection, then a tree of databases and
/// their collections with counts and sizes. It plays the part of the
/// Compass sidebar.
class ExplorerDrawer extends ConsumerStatefulWidget {
  const ExplorerDrawer({super.key, required this.onDisconnect});

  final VoidCallback onDisconnect;

  @override
  ConsumerState<ExplorerDrawer> createState() => _ExplorerDrawerState();
}

class _ExplorerDrawerState extends ConsumerState<ExplorerDrawer> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final session = ref.watch(sessionProvider);
    final dbs = ref.watch(databasesProvider);
    final width = MediaQuery.sizeOf(context).width;
    if (session == null) return const Drawer();
    final server = session.client.server;

    return Drawer(
      width: width * 0.88 > 380 ? 380 : width * 0.88,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
              child: Row(
                children: [
                  const AppLogo(size: 36),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(session.profile.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 15.5, fontWeight: FontWeight.w700)),
                        Text(server.address,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: monoStyle(context, size: 11.5, color: c.muted)),
                        Text('MongoDB ${server.version} · ${server.kind}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11.5, color: c.muted)),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Disconnect',
                    onPressed: widget.onDisconnect,
                    icon: Icon(Icons.power_settings_new, color: c.danger),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _search,
                      onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
                      decoration: InputDecoration(
                        hintText: 'Search databases and collections',
                        prefixIcon: Icon(Icons.search, size: 20, color: c.muted),
                        suffixIcon: _query.isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.close, size: 18),
                                onPressed: () {
                                  _search.clear();
                                  setState(() => _query = '');
                                }),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh',
                    onPressed: () {
                      ref.invalidate(databasesProvider);
                      ref.invalidate(collectionsProvider);
                      ref.invalidate(collectionStatsProvider);
                    },
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: c.border),
            Expanded(
              child: dbs.when(
                loading: () => const LoadingView(label: 'Loading databases…'),
                error: (e, _) => ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    MessageBanner(
                      message: describeError(e),
                      action: TextButton(
                          onPressed: () => ref.invalidate(databasesProvider),
                          child: const Text('Retry')),
                    ),
                  ],
                ),
                data: (list) {
                  if (list.isEmpty) {
                    return const EmptyState(
                        icon: Icons.storage_outlined,
                        title: 'No databases',
                        message: 'This user cannot see any databases.');
                  }
                  return ListView(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    children: [
                      for (final db in list)
                        _DatabaseTile(
                          key: ValueKey('${db.name}-${_query.isNotEmpty}'),
                          db: db,
                          query: _query,
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DatabaseTile extends ConsumerWidget {
  const _DatabaseTile({super.key, required this.db, required this.query});

  final DatabaseInfo db;
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final selection = ref.watch(selectionProvider);
    final nameMatches = query.isEmpty || db.name.toLowerCase().contains(query);
    // While searching, look inside every database so matching collections
    // show up, and hide databases with no match.
    if (query.isNotEmpty && !nameMatches) {
      final colls = ref.watch(collectionsProvider(db.name)).value;
      if (colls == null ||
          !colls.any((x) => x.name.toLowerCase().contains(query))) {
        return const SizedBox.shrink();
      }
    }
    final selected = selection.db == db.name && selection.collection == null;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        initiallyExpanded: query.isNotEmpty || selection.db == db.name,
        tilePadding: const EdgeInsets.only(left: 12, right: 4),
        childrenPadding: const EdgeInsets.only(left: 12),
        leading: Icon(Icons.storage_outlined,
            size: 20, color: selected ? c.accent : c.muted),
        title: Text(db.name,
            style: TextStyle(
                fontWeight: FontWeight.w600,
                color: selected ? c.accent : c.text)),
        subtitle: Text(
            db.sizeOnDisk == null ? 'database' : formatBytes(db.sizeOnDisk),
            style: TextStyle(fontSize: 12, color: c.muted)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Open database',
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.open_in_new, size: 18, color: c.muted),
              onPressed: () {
                ref.read(selectionProvider.notifier).database(db.name);
                Navigator.pop(context);
              },
            ),
            Icon(Icons.expand_more, color: c.muted),
          ],
        ),
        children: [_CollectionList(db: db.name, query: query)],
      ),
    );
  }
}

class _CollectionList extends ConsumerWidget {
  const _CollectionList({required this.db, required this.query});
  final String db;
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final colls = ref.watch(collectionsProvider(db));
    return colls.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(12),
        child: LinearProgressIndicator(minHeight: 2),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 12, 8),
        child: Text(describeError(e), style: TextStyle(color: c.danger, fontSize: 12.5)),
      ),
      data: (list) {
        final dbMatches = db.toLowerCase().contains(query);
        final shown = query.isEmpty || dbMatches
            ? list
            : list.where((x) => x.name.toLowerCase().contains(query)).toList();
        if (shown.isEmpty) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 12, 10),
            child: Text('No collections', style: TextStyle(color: c.muted, fontSize: 13)),
          );
        }
        return Column(
          children: [for (final coll in shown) _CollectionTile(db: db, info: coll)],
        );
      },
    );
  }
}

class _CollectionTile extends ConsumerWidget {
  const _CollectionTile({required this.db, required this.info});
  final String db;
  final CollectionInfo info;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final ns = Namespace(db, info.name);
    final selection = ref.watch(selectionProvider);
    final selected = selection.db == db && selection.collection == info.name;
    String subtitle;
    if (info.isView) {
      subtitle = 'view';
    } else {
      final stats = ref.watch(collectionStatsProvider(ns));
      subtitle = stats.when(
        data: (s) => s == null
            ? info.type
            : '${compactCount(s.count)} docs · ${formatBytes(s.size)}',
        loading: () => '…',
        error: (_, _) => info.type,
      );
    }
    return ListTile(
      dense: true,
      selected: selected,
      selectedColor: c.accent,
      selectedTileColor: c.accentStrong.withValues(alpha: 0.18),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      contentPadding: const EdgeInsets.only(left: 12, right: 12),
      leading: Icon(
        info.isView
            ? Icons.visibility_outlined
            : info.type == 'timeseries'
                ? Icons.timeline
                : Icons.folder_outlined,
        size: 18,
      ),
      title: Text(info.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14)),
      subtitle: Text(subtitle, style: TextStyle(fontSize: 11.5, color: c.muted)),
      onTap: () {
        ref.read(selectionProvider.notifier).collection(db, info.name);
        Navigator.pop(context);
      },
    );
  }
}
