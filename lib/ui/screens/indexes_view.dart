import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mongo_wire/mongo_wire.dart';

import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../widgets/common.dart';
import '../widgets/json_highlight.dart';

final indexesProvider =
    FutureProvider.autoDispose.family<List<Map<String, dynamic>>, Namespace>(
        (ref, ns) => ref.watch(clientProvider).listIndexes(ns));

/// The Indexes tab: lists indexes and lets the user create and drop them.
class IndexesView extends ConsumerWidget {
  const IndexesView({super.key, required this.namespace, this.info});

  final Namespace namespace;
  final CollectionInfo? info;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    if (info?.isView ?? false) {
      return const EmptyState(
        icon: Icons.visibility_outlined,
        title: 'Views have no indexes',
        message: 'Queries on a view use the indexes of its source collection.',
      );
    }
    final indexes = ref.watch(indexesProvider(namespace));
    final stats = ref.watch(collectionStatsProvider(namespace)).value;
    final readOnly = ref.watch(readOnlyProvider);

    Future<void> refresh() async {
      ref.invalidate(indexesProvider(namespace));
      ref.invalidate(collectionStatsProvider(namespace));
    }

    final header = Container(
      color: c.panel,
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      child: Row(
        children: [
          Tooltip(
            message: readOnly ? 'Turn on write mode to create indexes' : '',
            child: AccentButton(
              label: 'Create Index',
              icon: Icons.add,
              compact: true,
              onPressed: readOnly
                  ? null
                  : () async {
                      final created = await showModalBottomSheet<String>(
                        context: context,
                        isScrollControlled: true,
                        useSafeArea: true,
                        builder: (_) => CreateIndexSheet(namespace: namespace),
                      );
                      if (created != null && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Index "$created" created')));
                        await refresh();
                      }
                    },
            ),
          ),
          const Spacer(),
          if (indexes.value != null)
            Text(
                '${indexes.value!.length} ${indexes.value!.length == 1 ? 'index' : 'indexes'}',
                style: TextStyle(color: c.muted, fontSize: 13)),
          IconButton(
              tooltip: 'Refresh',
              onPressed: refresh,
              icon: const Icon(Icons.refresh, size: 20)),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        Divider(height: 1, color: c.border),
        Expanded(
          child: indexes.when(
            loading: () => const LoadingView(label: 'Loading indexes…'),
            error: (e, _) => ListView(
              padding: const EdgeInsets.all(12),
              children: [
                MessageBanner(
                  message: describeError(e),
                  action: TextButton(onPressed: refresh, child: const Text('Retry')),
                ),
              ],
            ),
            data: (list) => RefreshIndicator(
              onRefresh: refresh,
              child: ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: list.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _IndexCard(
                  index: list[i],
                  size: stats?.indexSizes['${list[i]['name']}'],
                  onDrop: readOnly || list[i]['name'] == '_id_'
                      ? null
                      : () => _drop(context, ref, '${list[i]['name']}', refresh),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _drop(BuildContext context, WidgetRef ref, String name,
      Future<void> Function() refresh) async {
    final ok = await confirmDialog(context,
        title: 'Drop index?',
        message: 'Drop the index "$name" on $namespace? Queries that rely on '
            'it may become slow.',
        confirmLabel: 'Drop');
    if (!ok) return;
    try {
      await ref.read(clientProvider).dropIndex(namespace, name);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Index "$name" dropped')));
      }
      await refresh();
    } on Object catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(describeError(e))));
      }
    }
  }
}

class _IndexCard extends StatelessWidget {
  const _IndexCard({required this.index, this.size, this.onDrop});

  final Map<String, dynamic> index;
  final int? size;
  final VoidCallback? onDrop;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final key = (index['key'] as Map<String, dynamic>?) ?? const {};
    final ttl = index['expireAfterSeconds'];
    final pills = <Widget>[
      if (index['name'] == '_id_') Pill('DEFAULT', color: c.muted),
      if (index['unique'] == true) Pill('UNIQUE', color: c.accent),
      if (index['sparse'] == true) Pill('SPARSE', color: c.number),
      if (ttl != null) Pill('TTL ${shortDuration(ttl)}', color: c.date),
      if (index['partialFilterExpression'] != null)
        Pill('PARTIAL', color: c.objectId),
      if (index['hidden'] == true) Pill('HIDDEN', color: c.warning),
      if (key.values.any((v) => v == 'text')) Pill('TEXT', color: c.string),
      if (key.values.any((v) => v == '2dsphere' || v == '2d'))
        Pill('GEO', color: c.other),
      if (key.values.any((v) => v == 'hashed')) Pill('HASHED', color: c.other),
      if (key.keys.any((k) => k.contains(r'$**'))) Pill('WILDCARD', color: c.other),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 4, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${index['name']}',
                      style: monoStyle(context,
                          size: 13.5, weight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(shellDocument(key),
                      style: monoStyle(context, size: 12.5, color: c.muted)),
                  if (pills.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(spacing: 6, runSpacing: 6, children: pills),
                  ],
                  if (index['partialFilterExpression'] != null) ...[
                    const SizedBox(height: 6),
                    Text(
                        'partial: ${EJson.stringify(index['partialFilterExpression'], pretty: false)}',
                        style: monoStyle(context, size: 11.5, color: c.muted)),
                  ],
                  const SizedBox(height: 6),
                  Text('Size: ${formatBytes(size)}',
                      style: TextStyle(color: c.muted, fontSize: 12)),
                ],
              ),
            ),
            if (onDrop != null)
              IconButton(
                tooltip: 'Drop index',
                onPressed: onDrop,
                icon: Icon(Icons.delete_outline, color: c.danger),
              ),
          ],
        ),
      ),
    );
  }
}

String shortDuration(Object? seconds) {
  final s = switch (seconds) {
    int() => seconds,
    double() => seconds.toInt(),
    BsonLong() => seconds.value,
    _ => 0,
  };
  if (s % 86400 == 0 && s > 0) return '${s ~/ 86400}d';
  if (s % 3600 == 0 && s > 0) return '${s ~/ 3600}h';
  if (s % 60 == 0 && s > 0) return '${s ~/ 60}m';
  return '${s}s';
}

/// Form for a new index. Pops with the created index name.
class CreateIndexSheet extends ConsumerStatefulWidget {
  const CreateIndexSheet({super.key, required this.namespace});
  final Namespace namespace;

  @override
  ConsumerState<CreateIndexSheet> createState() => _CreateIndexSheetState();
}

class _CreateIndexSheetState extends ConsumerState<CreateIndexSheet> {
  final _keys = TextEditingController(text: '{ field: 1 }');
  final _name = TextEditingController();
  final _ttl = TextEditingController();
  final _partial = TextEditingController();
  bool _unique = false;
  bool _sparse = false;
  bool _hidden = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_keys, _name, _ttl, _partial]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _create() async {
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      final keys = EJson.parseDocument(_keys.text);
      if (keys.isEmpty) throw const FormatException('Add at least one key');
      for (final v in keys.values) {
        final ok = v == 1 ||
            v == -1 ||
            const ['text', '2dsphere', '2d', 'hashed'].contains(v);
        if (!ok) {
          throw const FormatException(
              'Key values must be 1, -1, "text", "2dsphere", "2d" or "hashed"');
        }
      }
      Duration? ttl;
      if (_ttl.text.trim().isNotEmpty) {
        final s = int.tryParse(_ttl.text.trim());
        if (s == null || s < 0) {
          throw const FormatException('TTL must be a whole number of seconds');
        }
        ttl = Duration(seconds: s);
      }
      final partial = _partial.text.trim().isEmpty
          ? null
          : EJson.parseDocument(_partial.text);
      final name = await ref.read(clientProvider).createIndex(
            widget.namespace,
            keys,
            IndexOptions(
              name: _name.text,
              unique: _unique,
              sparse: _sparse,
              hidden: _hidden,
              expireAfter: ttl,
              partialFilterExpression: partial,
            ),
          );
      if (mounted) Navigator.pop(context, name);
    } on EJsonParseException catch (e) {
      setState(() => _error = 'Line ${e.line}, column ${e.column}: ${e.message}');
    } on Object catch (e) {
      setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    InputDecoration deco(String label, [String? hint]) => InputDecoration(
          labelText: label,
          hintText: hint,
          labelStyle: TextStyle(color: c.muted),
        );
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Create index on ${widget.namespace}',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            TextField(
              controller: _keys,
              style: monoStyle(context),
              autocorrect: false,
              maxLines: 3,
              minLines: 1,
              decoration: deco('Keys', '{ name: 1, createdAt: -1 }'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              style: monoStyle(context),
              decoration: deco('Name (optional)', 'Generated from the keys'),
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Unique'),
              subtitle: const Text('Reject documents with duplicate keys'),
              value: _unique,
              onChanged: (v) => setState(() => _unique = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Sparse'),
              subtitle: const Text('Skip documents without the field'),
              value: _sparse,
              onChanged: (v) => setState(() => _sparse = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Hidden'),
              subtitle: const Text('Build it, but keep the planner from using it'),
              value: _hidden,
              onChanged: (v) => setState(() => _hidden = v),
            ),
            TextField(
              controller: _ttl,
              keyboardType: TextInputType.number,
              style: monoStyle(context),
              decoration: deco('TTL in seconds (optional)', 'e.g. 3600'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _partial,
              style: monoStyle(context),
              autocorrect: false,
              maxLines: 3,
              minLines: 1,
              decoration: deco('Partial filter (optional)', '{ status: "active" }'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              MessageBanner(message: _error!),
            ],
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                    onPressed: _busy ? null : () => Navigator.pop(context),
                    child: const Text('Cancel')),
                const SizedBox(width: 8),
                AccentButton(
                  label: _busy ? 'Creating…' : 'Create Index',
                  onPressed: _busy ? null : _create,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
