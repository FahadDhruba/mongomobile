import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mongo_wire/mongo_wire.dart';

import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import 'documents_view.dart';
import 'indexes_view.dart';

/// A collection with Documents and Indexes tabs.
class CollectionScreen extends ConsumerWidget {
  const CollectionScreen({super.key, required this.namespace});

  final Namespace namespace;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final info = ref
        .watch(collectionsProvider(namespace.db))
        .value
        ?.where((x) => x.name == namespace.collection)
        .firstOrNull;
    final stats = info?.isView ?? false
        ? null
        : ref.watch(collectionStatsProvider(namespace)).value;

    final facts = [
      if (info?.isView ?? false) 'View',
      if (info?.type == 'timeseries') 'Time series',
      if (stats != null) ...[
        '${compactCount(stats.count)} documents',
        '${formatBytes(stats.size)} data',
        'avg ${formatBytes(stats.averageDocumentSize)}',
        '${formatBytes(stats.totalIndexSize)} indexes',
      ],
    ];

    return DefaultTabController(
      length: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: c.panel,
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (facts.isNotEmpty)
                  Text(facts.join('  ·  '),
                      style: TextStyle(color: c.muted, fontSize: 12)),
                TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: const [Tab(text: 'Documents'), Tab(text: 'Indexes')],
                ),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              physics: const NeverScrollableScrollPhysics(),
              children: [
                DocumentsView(namespace: namespace, info: info),
                IndexesView(namespace: namespace, info: info),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
