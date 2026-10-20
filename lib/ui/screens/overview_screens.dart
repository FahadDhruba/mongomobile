import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mongo_wire/mongo_wire.dart';

import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../widgets/common.dart';
import 'collection_admin.dart';

/// Shown right after connecting: the server and its databases.
class ServerOverview extends ConsumerWidget {
  const ServerOverview({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final session = ref.watch(sessionProvider);
    if (session == null) return const SizedBox.shrink();
    final server = session.client.server;
    final dbs = ref.watch(databasesProvider);

    Widget fact(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                  width: 110,
                  child: Text(label, style: TextStyle(color: c.muted, fontSize: 13))),
              Expanded(
                  child: SelectableText(value, style: monoStyle(context, size: 12.5))),
            ],
          ),
        );

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(databasesProvider),
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.dns_outlined, color: c.accent),
                    const SizedBox(width: 8),
                    Text(server.kind,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 15)),
                  ]),
                  const SizedBox(height: 10),
                  fact('Host', server.address),
                  fact('Version', 'MongoDB ${server.version}'),
                  if (server.setName != null) fact('Replica set', server.setName!),
                  if (server.members.length > 1)
                    fact('Members', server.members.join('\n')),
                  if (server.roundTrip != null)
                    fact('Round trip', formatDuration(server.roundTrip!)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Text('Databases',
                    style: TextStyle(
                        color: c.muted,
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5)),
              ),
              TextButton.icon(
                onPressed: () => createCollectionFlow(context, ref),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Create database'),
              ),
            ],
          ),
          ...dbs.when(
            loading: () => [const LoadingView()],
            error: (e, _) => [MessageBanner(message: describeError(e))],
            data: (list) => [
              for (final db in list)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Card(
                    child: ListTile(
                      leading: Icon(Icons.storage_outlined, color: c.accent),
                      title: Text(db.name,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(formatBytes(db.sizeOnDisk),
                          style: TextStyle(color: c.muted)),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () =>
                          ref.read(selectionProvider.notifier).database(db.name),
                    ),
                  ),
                ),
              if (list.isEmpty)
                const EmptyState(
                    icon: Icons.storage_outlined, title: 'No databases'),
            ],
          ),
        ],
      ),
    );
  }
}

/// One database: its collections with counts and sizes.
class DatabaseOverview extends ConsumerWidget {
  const DatabaseOverview({super.key, required this.db});
  final String db;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colls = ref.watch(collectionsProvider(db));
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(collectionsProvider(db));
        ref.invalidate(collectionStatsProvider);
      },
      child: colls.when(
        loading: () => const LoadingView(label: 'Loading collections…'),
        error: (e, _) => ListView(
          padding: const EdgeInsets.all(12),
          children: [MessageBanner(message: describeError(e))],
        ),
        data: (list) => list.isEmpty
            ? ListView(children: [
                const EmptyState(
                  icon: Icons.folder_off_outlined,
                  title: 'No collections',
                  message: 'This database has no collections you can see.',
                ),
                Center(
                  child: TextButton.icon(
                    onPressed: () => createCollectionFlow(context, ref, db: db),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Create collection'),
                  ),
                ),
              ])
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                itemCount: list.length + 1,
                separatorBuilder: (_, i) =>
                    SizedBox(height: i == 0 ? 0 : 8),
                itemBuilder: (_, i) => i == 0
                    ? Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: () =>
                              createCollectionFlow(context, ref, db: db),
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Create collection'),
                        ),
                      )
                    : _CollectionCard(db: db, info: list[i - 1]),
              ),
      ),
    );
  }
}

class _CollectionCard extends ConsumerWidget {
  const _CollectionCard({required this.db, required this.info});
  final String db;
  final CollectionInfo info;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final ns = Namespace(db, info.name);
    final stats = info.isView ? null : ref.watch(collectionStatsProvider(ns));

    Widget stat(String label, String value) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(color: c.muted, fontSize: 11)),
              const SizedBox(height: 2),
              Text(value,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
            ],
          ),
        );

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => ref.read(selectionProvider.notifier).collection(db, info.name),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(info.isView ? Icons.visibility_outlined : Icons.folder_outlined,
                      size: 20, color: c.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(info.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 15)),
                  ),
                  if (info.isView) const Pill('VIEW'),
                  if (info.type == 'timeseries') const Pill('TIME SERIES'),
                ],
              ),
              const SizedBox(height: 12),
              if (stats == null)
                Text('Views compute their documents when queried.',
                    style: TextStyle(color: c.muted, fontSize: 12.5))
              else
                stats.when(
                  loading: () => const LinearProgressIndicator(minHeight: 2),
                  error: (e, _) => Text(describeError(e),
                      style: TextStyle(color: c.danger, fontSize: 12)),
                  data: (s) => s == null
                      ? Text('No statistics available',
                          style: TextStyle(color: c.muted, fontSize: 12.5))
                      : Row(children: [
                          stat('Documents', compactCount(s.count)),
                          stat('Data', formatBytes(s.size)),
                          stat('Avg size', formatBytes(s.averageDocumentSize)),
                          stat('Indexes', formatBytes(s.totalIndexSize)),
                        ]),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
