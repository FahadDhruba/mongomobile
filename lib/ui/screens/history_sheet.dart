import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mongo_wire/mongo_wire.dart';

import '../../services/query_library.dart';
import '../../state/query_library.dart';
import '../../theme/app_theme.dart';
import '../widgets/common.dart';

/// Shows recent and favourite queries; returns the one the user picked.
Future<SavedQuery?> showQueryHistory(BuildContext context, Namespace ns) =>
    showModalBottomSheet<SavedQuery>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.75,
        child: QueryHistorySheet(namespace: ns),
      ),
    );

/// Asks for a name; returns null when cancelled.
Future<String?> askName(
  BuildContext context, {
  required String title,
  String initial = '',
  String hint = 'Name',
  String confirm = 'Save',
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (v) {
          if (v.trim().isNotEmpty) Navigator.pop(ctx, v.trim());
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final v = controller.text.trim();
            if (v.isNotEmpty) Navigator.pop(ctx, v);
          },
          child: Text(confirm),
        ),
      ],
    ),
  );
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  if (d.inDays < 30) return '${d.inDays} d ago';
  return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}

const _labels = {
  'filter': 'filter',
  'project': 'project',
  'sort': 'sort',
  'collation': 'collation',
  'hint': 'hint',
  'skip': 'skip',
  'limit': 'limit',
  'maxTime': 'maxTimeMS',
};

class QueryHistorySheet extends ConsumerWidget {
  const QueryHistorySheet({super.key, required this.namespace});
  final Namespace namespace;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    ref.watch(queryLibraryProvider);
    final notifier = ref.read(queryLibraryProvider.notifier);
    final lib = notifier.of(namespace);

    Widget tile(SavedQuery q, {required bool favorite}) {
      final lines = [
        for (final e in _labels.entries)
          if (q.texts[e.key] != null) '${e.value}: ${q.texts[e.key]}',
      ];
      return Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => Navigator.pop(context, q),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (q.name != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            q.name!,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      for (final l in lines)
                        Text(
                          l,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: monoStyle(context, size: 12),
                        ),
                      const SizedBox(height: 4),
                      Text(
                        _ago(q.at),
                        style: TextStyle(color: c.muted, fontSize: 11.5),
                      ),
                    ],
                  ),
                ),
                if (!favorite)
                  IconButton(
                    tooltip: 'Save as favourite',
                    icon: const Icon(Icons.star_border, size: 20),
                    onPressed: () async {
                      final name = await askName(
                        context,
                        title: 'Save favourite',
                      );
                      if (name != null) {
                        await notifier.addFavorite(namespace, name, q.texts);
                      }
                    },
                  ),
                IconButton(
                  tooltip: 'Remove',
                  icon: Icon(Icons.close, size: 20, color: c.muted),
                  onPressed: () => favorite
                      ? notifier.removeFavorite(namespace, q)
                      : notifier.removeRecent(namespace, q),
                ),
              ],
            ),
          ),
        ),
      );
    }

    Widget list(List<SavedQuery> items, bool favorite) {
      if (items.isEmpty) {
        return EmptyState(
          icon: favorite ? Icons.star_border : Icons.history,
          title: favorite ? 'No favourites yet' : 'No recent queries',
          message: favorite
              ? 'Tap the star in the query bar to save the current query.'
              : 'Queries you run on ${namespace.collection} show up here.',
        );
      }
      return ListView.separated(
        padding: const EdgeInsets.all(12),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (_, i) => tile(items[i], favorite: favorite),
      );
    }

    return DefaultTabController(
      length: 2,
      initialIndex: lib.recent.isEmpty && lib.favorites.isNotEmpty ? 1 : 0,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Queries on $namespace',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (lib.recent.isNotEmpty)
                  TextButton(
                    onPressed: () => notifier.clearRecent(namespace),
                    child: const Text('Clear recent'),
                  ),
              ],
            ),
          ),
          const TabBar(
            tabs: [
              Tab(text: 'Recent'),
              Tab(text: 'Favourites'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [list(lib.recent, false), list(lib.favorites, true)],
            ),
          ),
        ],
      ),
    );
  }
}
