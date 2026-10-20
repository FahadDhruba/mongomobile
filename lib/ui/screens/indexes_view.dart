import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mongo_wire/mongo_wire.dart';

import '../../services/server_activity.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../widgets/common.dart';
import '../widgets/json_highlight.dart';
import '../widgets/query_assist.dart';

final indexesProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, Namespace>(
      (ref, ns) => ref.watch(clientProvider).listIndexes(ns),
      dependencies: [clientProvider],
    );

/// How often an index was used, from `$indexStats`.
class IndexUsage {
  const IndexUsage(this.ops, this.since);
  final int ops;
  final DateTime? since;
}

/// Index name → usage. Empty when the user may not run `$indexStats`.
final indexUsageProvider = FutureProvider.autoDispose
    .family<Map<String, IndexUsage>, Namespace>((ref, ns) async {
      try {
        final stats = await ref.watch(clientProvider).indexStats(ns);
        return {
          for (final s in stats)
            '${s['name']}': IndexUsage(
              _int((s['accesses'] as Map?)?['ops']),
              (s['accesses'] as Map?)?['since'] as DateTime?,
            ),
        };
      } on Object {
        return const {};
      }
    }, dependencies: [clientProvider]);

int _int(Object? v) => switch (v) {
  int() => v,
  BsonLong() => v.value,
  double() => v.toInt(),
  _ => 0,
};

/// An index build that is still running.
class IndexBuild {
  const IndexBuild({
    required this.names,
    required this.opid,
    this.done,
    this.total,
    this.message,
  });

  final List<String> names;
  final Object? opid;
  final int? done;
  final int? total;
  final String? message;

  double? get fraction =>
      done != null && total != null && total! > 0 ? done! / total! : null;
}

/// Builds in progress on [ns], from `$currentOp`. Empty when the user may
/// not see other operations.
final indexBuildsProvider = FutureProvider.autoDispose
    .family<List<IndexBuild>, Namespace>((ref, ns) async {
      final client = ref.watch(clientProvider);
      Future<Map<String, dynamic>> run({required bool allUsers}) =>
          client.runCommand('admin', {
            'aggregate': 1,
            'pipeline': [
              {
                r'$currentOp': {'allUsers': allUsers, 'idleConnections': false},
              },
              {
                r'$match': {
                  'command.createIndexes': ns.collection,
                  r'$or': [
                    {'ns': '$ns'},
                    {'ns': '${ns.db}.\$cmd'},
                    {'command.\$db': ns.db},
                  ],
                },
              },
            ],
            'cursor': {'batchSize': 100},
          }, maxTime: const Duration(seconds: 5));
      try {
        Map<String, dynamic> reply;
        try {
          reply = await run(allUsers: true);
        } on Object catch (e) {
          if (!isAllUsersRestricted(e)) rethrow;
          reply = await run(allUsers: false);
        }
        final ops = ((reply['cursor'] as Map?)?['firstBatch'] as List?) ?? [];
        final byNames = <String, IndexBuild>{};
        for (final op in ops.cast<Map<String, dynamic>>()) {
          final command = op['command'] as Map? ?? const {};
          final names = [
            for (final i in (command['indexes'] as List? ?? const []))
              if (i is Map && i['name'] != null) '${i['name']}',
          ];
          if (names.isEmpty) continue;
          final progress = op['progress'] as Map?;
          final build = IndexBuild(
            names: names,
            opid: op['opid'],
            done: progress == null ? null : _int(progress['done']),
            total: progress == null ? null : _int(progress['total']),
            message: op['msg'] as String?,
          );
          // The build thread carries the progress; prefer it over the
          // client's waiting command.
          final key = names.join(',');
          if (byNames[key]?.fraction == null) byNames[key] = build;
        }
        return byNames.values.toList();
      } on Object {
        return const [];
      }
    }, dependencies: [clientProvider]);

/// The Indexes tab: lists indexes with their usage, shows builds in
/// progress, and creates, hides and drops indexes.
class IndexesView extends ConsumerStatefulWidget {
  const IndexesView({super.key, required this.namespace, this.info});

  final Namespace namespace;
  final CollectionInfo? info;

  @override
  ConsumerState<IndexesView> createState() => _IndexesViewState();
}

class _IndexesViewState extends ConsumerState<IndexesView> {
  Timer? _poll;

  Namespace get namespace => widget.namespace;

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    ref.invalidate(indexesProvider(namespace));
    ref.invalidate(indexUsageProvider(namespace));
    ref.invalidate(indexBuildsProvider(namespace));
    ref.invalidate(collectionStatsProvider(namespace));
  }

  /// Polls every 2 s while a build runs, then refreshes the list once.
  void _watchBuilds(List<IndexBuild> builds) {
    if (builds.isEmpty) {
      if (_poll != null) {
        _poll!.cancel();
        _poll = null;
        ref.invalidate(indexesProvider(namespace));
        ref.invalidate(collectionStatsProvider(namespace));
      }
      return;
    }
    _poll ??= Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) ref.invalidate(indexBuildsProvider(namespace));
    });
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _create() async {
    final created = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => CreateIndexSheet(namespace: namespace),
    );
    if (created == null) return;
    _snack('Index "$created" created');
    await _refresh();
  }

  Future<void> _setHidden(String name, bool hidden) async {
    final ok = await confirmDialog(
      context,
      title: hidden ? 'Hide index?' : 'Unhide index?',
      message: hidden
          ? 'The query planner will stop using "$name", but it stays up to '
                'date, so unhiding it is instant. Use this to see whether '
                'an index is still needed before dropping it.'
          : 'The query planner can use "$name" again.',
      confirmLabel: hidden ? 'Hide' : 'Unhide',
      destructive: false,
    );
    if (!ok) return;
    try {
      await ref.read(clientProvider).modifyCollection(namespace, {
        'index': {'name': name, 'hidden': hidden},
      });
      _snack('Index "$name" ${hidden ? 'hidden' : 'unhidden'}');
      await _refresh();
    } on Object catch (e) {
      _snack(describeError(e));
    }
  }

  Future<void> _drop(String name) async {
    final ok = await confirmDialog(
      context,
      title: 'Drop index?',
      message:
          'Drop the index "$name" on $namespace? Queries that rely on '
          'it may become slow.',
      confirmLabel: 'Drop',
    );
    if (!ok) return;
    try {
      await ref.read(clientProvider).dropIndex(namespace, name);
      _snack('Index "$name" dropped');
      await _refresh();
    } on Object catch (e) {
      _snack(describeError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (widget.info?.isView ?? false) {
      return const EmptyState(
        icon: Icons.visibility_outlined,
        title: 'Views have no indexes',
        message: 'Queries on a view use the indexes of its source collection.',
      );
    }
    final indexes = ref.watch(indexesProvider(namespace));
    final usage = ref.watch(indexUsageProvider(namespace)).value ?? const {};
    final builds = ref.watch(indexBuildsProvider(namespace)).value ?? const [];
    ref.listen(
      indexBuildsProvider(namespace),
      (_, next) => _watchBuilds(next.value ?? const []),
    );
    final stats = ref.watch(collectionStatsProvider(namespace)).value;
    final readOnly = ref.watch(readOnlyProvider);
    final building = {for (final b in builds) ...b.names};

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
              onPressed: readOnly ? null : _create,
            ),
          ),
          const Spacer(),
          if (indexes.value != null)
            Text(
              '${indexes.value!.length} '
              '${indexes.value!.length == 1 ? 'index' : 'indexes'}',
              style: TextStyle(color: c.muted, fontSize: 13),
            ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh, size: 20),
          ),
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
                  action: TextButton(
                    onPressed: _refresh,
                    child: const Text('Retry'),
                  ),
                ),
              ],
            ),
            data: (list) {
              final listed = {for (final i in list) '${i['name']}'};
              final pending = [
                for (final b in builds)
                  if (!b.names.every(listed.contains)) b,
              ];
              return RefreshIndicator(
                onRefresh: _refresh,
                child: ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    for (final b in pending) ...[
                      _BuildCard(job: b),
                      const SizedBox(height: 8),
                    ],
                    for (final index in list) ...[
                      _IndexCard(
                        index: index,
                        size: stats?.indexSizes['${index['name']}'],
                        usage: usage['${index['name']}'],
                        job: building.contains('${index['name']}')
                            ? builds.firstWhere(
                                (b) => b.names.contains('${index['name']}'),
                              )
                            : null,
                        onHide: readOnly || index['name'] == '_id_'
                            ? null
                            : () => _setHidden(
                                '${index['name']}',
                                index['hidden'] != true,
                              ),
                        onDrop: readOnly || index['name'] == '_id_'
                            ? null
                            : () => _drop('${index['name']}'),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _BuildCard extends StatelessWidget {
  const _BuildCard({required this.job});
  final IndexBuild job;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fraction = job.fraction;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    job.names.join(', '),
                    style: monoStyle(
                      context,
                      size: 13.5,
                      weight: FontWeight.w700,
                    ),
                  ),
                ),
                Pill('BUILDING', color: c.warning),
              ],
            ),
            const SizedBox(height: 10),
            _BuildProgress(job: job),
            if (fraction == null && job.message != null) ...[
              const SizedBox(height: 6),
              Text(
                job.message!,
                style: TextStyle(color: c.muted, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _BuildProgress extends StatelessWidget {
  const _BuildProgress({required this.job});
  final IndexBuild job;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fraction = job.fraction;
    return Row(
      children: [
        Expanded(
          child: LinearProgressIndicator(
            value: fraction,
            color: c.warning,
            backgroundColor: c.border,
          ),
        ),
        const SizedBox(width: 10),
        Text(
          fraction == null ? 'Building…' : '${(fraction * 100).floor()}%',
          style: TextStyle(color: c.muted, fontSize: 12),
        ),
      ],
    );
  }
}

class _IndexCard extends StatelessWidget {
  const _IndexCard({
    required this.index,
    this.size,
    this.usage,
    this.job,
    this.onHide,
    this.onDrop,
  });

  final Map<String, dynamic> index;
  final int? size;
  final IndexUsage? usage;
  final IndexBuild? job;
  final VoidCallback? onHide;
  final VoidCallback? onDrop;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final key = (index['key'] as Map<String, dynamic>?) ?? const {};
    final ttl = index['expireAfterSeconds'];
    final hidden = index['hidden'] == true;
    final pills = <Widget>[
      if (index['name'] == '_id_') Pill('DEFAULT', color: c.muted),
      if (index['unique'] == true) Pill('UNIQUE', color: c.accent),
      if (index['sparse'] == true) Pill('SPARSE', color: c.number),
      if (ttl != null) Pill('TTL ${shortDuration(ttl)}', color: c.date),
      if (index['partialFilterExpression'] != null)
        Pill('PARTIAL', color: c.objectId),
      if (hidden) Pill('HIDDEN', color: c.warning),
      if (index['collation'] != null) Pill('COLLATION', color: c.string),
      if (key.values.any((v) => v == 'text')) Pill('TEXT', color: c.string),
      if (key.values.any((v) => v == '2dsphere' || v == '2d'))
        Pill('GEO', color: c.other),
      if (key.values.any((v) => v == 'hashed')) Pill('HASHED', color: c.other),
      if (key.keys.any((k) => k.contains(r'$**')))
        Pill('WILDCARD', color: c.other),
    ];
    final u = usage;
    final since = u?.since;
    final details = <String>[
      if (index['partialFilterExpression'] != null)
        'partial: ${EJson.stringify(index['partialFilterExpression'], pretty: false)}',
      if (index['collation'] case final Map coll)
        'collation: ${EJson.stringify({
          for (final k in const ['locale', 'strength'])
            if (coll[k] != null) k: coll[k],
        }, pretty: false)}',
      if (index['wildcardProjection'] != null)
        'projection: ${EJson.stringify(index['wildcardProjection'], pretty: false)}',
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
                  Text(
                    '${index['name']}',
                    style: monoStyle(
                      context,
                      size: 13.5,
                      weight: FontWeight.w700,
                      color: hidden ? c.muted : null,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    shellDocument(key),
                    style: monoStyle(context, size: 12.5, color: c.muted),
                  ),
                  if (pills.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(spacing: 6, runSpacing: 6, children: pills),
                  ],
                  for (final d in details) ...[
                    const SizedBox(height: 6),
                    Text(
                      d,
                      style: monoStyle(context, size: 11.5, color: c.muted),
                    ),
                  ],
                  if (job case final b?) ...[
                    const SizedBox(height: 10),
                    _BuildProgress(job: b),
                  ],
                  const SizedBox(height: 6),
                  Text(
                    [
                      'Size: ${formatBytes(size)}',
                      if (u != null)
                        u.ops == 0
                            ? 'Not used'
                            : 'Used ${groupDigits(u.ops)} time${u.ops == 1 ? '' : 's'}',
                      if (u != null && since != null)
                        'since ${formatShortDate(since)}',
                    ].join(' · '),
                    style: TextStyle(
                      color: u?.ops == 0 && index['name'] != '_id_'
                          ? c.warning
                          : c.muted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            if (onHide != null || onDrop != null)
              PopupMenuButton<String>(
                tooltip: 'Index actions',
                onSelected: (v) =>
                    v == 'hide' ? onHide?.call() : onDrop?.call(),
                itemBuilder: (_) => [
                  if (onHide != null)
                    PopupMenuItem(
                      value: 'hide',
                      child: Text(hidden ? 'Unhide index' : 'Hide index'),
                    ),
                  if (onDrop != null)
                    PopupMenuItem(
                      value: 'drop',
                      child: Text(
                        'Drop index',
                        style: TextStyle(color: c.danger),
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

/// A date like "2 Mar 2026" for usage lines.
String formatShortDate(DateTime d) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final l = d.toLocal();
  return '${l.day} ${months[l.month - 1]} ${l.year}';
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
  final _collation = TextEditingController();
  final _wildcard = TextEditingController();
  bool _unique = false;
  bool _sparse = false;
  bool _hidden = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _keys.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    for (final c in [_keys, _name, _ttl, _partial, _collation, _wildcard]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _isWildcard => _keys.text.contains(r'$**');

  Map<String, dynamic>? _optionalDocument(TextEditingController c) =>
      c.text.trim().isEmpty ? null : EJson.parseDocument(c.text);

  Future<void> _create() async {
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      final keys = EJson.parseDocument(_keys.text);
      if (keys.isEmpty) throw const FormatException('Add at least one key');
      for (final MapEntry(:key, :value) in keys.entries) {
        final ok =
            value == 1 ||
            value == -1 ||
            (!key.contains(r'$**') &&
                const ['text', '2dsphere', '2d', 'hashed'].contains(value));
        if (!ok) {
          throw FormatException(
            key.contains(r'$**')
                ? 'Wildcard keys take 1 or -1'
                : 'Key values must be 1, -1, "text", "2dsphere", "2d" or '
                      '"hashed"',
          );
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
      final collation = _optionalDocument(_collation);
      if (collation != null && collation['locale'] is! String) {
        throw const FormatException(
          "The collation needs a locale, e.g. { locale: 'en', strength: 2 }",
        );
      }
      final wildcard = _isWildcard ? _optionalDocument(_wildcard) : null;
      if (wildcard != null && keys.keys.any((k) => k != r'$**')) {
        throw const FormatException(
          r'A wildcard projection needs the key { "$**": 1 } on its own',
        );
      }
      final name = await ref
          .read(clientProvider)
          .createIndex(
            widget.namespace,
            keys,
            IndexOptions(
              name: _name.text,
              unique: _unique,
              sparse: _sparse,
              hidden: _hidden,
              expireAfter: ttl,
              partialFilterExpression: _optionalDocument(_partial),
              collation: collation,
              wildcardProjection: wildcard,
            ),
          );
      if (mounted) Navigator.pop(context, name);
    } on EJsonParseException catch (e) {
      setState(
        () => _error = 'Line ${e.line}, column ${e.column}: ${e.message}',
      );
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
    Widget doc(TextEditingController ctl, String label, String hint) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: ctl,
        style: monoStyle(context),
        autocorrect: false,
        enableSuggestions: false,
        maxLines: 3,
        minLines: 1,
        inputFormatters: [QueryInputFormatter()],
        decoration: deco(label, hint),
      ),
    );
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Create index on ${widget.namespace}',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _keys,
              style: monoStyle(context),
              autocorrect: false,
              enableSuggestions: false,
              maxLines: 3,
              minLines: 1,
              decoration: deco(
                'Keys',
                r'{ name: 1, createdAt: -1 } or { "$**": 1 }',
              ),
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
              subtitle: const Text(
                'Build it, but keep the planner from using it',
              ),
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
            doc(_partial, 'Partial filter (optional)', '{ status: "active" }'),
            doc(
              _collation,
              'Collation (optional)',
              "{ locale: 'en', strength: 2 }",
            ),
            if (_isWildcard)
              doc(
                _wildcard,
                'Wildcard projection (optional)',
                '{ attributes: 1 } or { secret: 0 }',
              ),
            if (_error != null) ...[
              MessageBanner(message: _error!),
              const SizedBox(height: 4),
            ],
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _busy ? null : () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
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
