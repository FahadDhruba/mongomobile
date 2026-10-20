import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mongo_wire/mongo_wire.dart';

import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/query_assist.dart';

/// Databases the app never offers to drop.
const protectedDatabases = {'admin', 'local', 'config'};

void _snack(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

bool _needsWrites(BuildContext context, WidgetRef ref, String what) {
  if (!ref.read(readOnlyProvider)) return false;
  _snack(context, 'Turn on write mode to $what');
  return true;
}

/// Creates a collection, or a database with its first collection when
/// [db] is null, then opens it.
Future<void> createCollectionFlow(
  BuildContext context,
  WidgetRef ref, {
  String? db,
}) async {
  if (_needsWrites(
    context,
    ref,
    db == null ? 'create databases' : 'create collections',
  )) {
    return;
  }
  final ns = await Navigator.push<Namespace>(
    context,
    MaterialPageRoute(builder: (_) => CreateCollectionScreen(db: db)),
  );
  if (ns == null || !context.mounted) return;
  ref.invalidate(databasesProvider);
  ref.invalidate(collectionsProvider(ns.db));
  ref.read(selectionProvider.notifier).collection(ns.db, ns.collection);
  _snack(context, 'Collection ${ns.collection} created');
}

/// Drops a database after the user types its name.
Future<void> dropDatabaseFlow(
  BuildContext context,
  WidgetRef ref,
  String db,
) async {
  if (_needsWrites(context, ref, 'drop databases')) return;
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => TypeToConfirmDialog(
      title: 'Drop database?',
      message:
          'This permanently deletes the database $db with all its '
          'collections, views, documents and indexes. It cannot be undone.',
      name: db,
      confirmLabel: 'Drop',
    ),
  );
  if (ok != true || !context.mounted) return;
  try {
    await ref.read(clientProvider).dropDatabase(db);
    ref.read(selectionProvider.notifier).clear();
    ref.invalidate(databasesProvider);
    ref.invalidate(collectionsProvider(db));
    if (context.mounted) _snack(context, 'Database $db dropped');
  } on Object catch (e) {
    if (context.mounted) _snack(context, describeError(e));
  }
}

/// Renames a collection within its database.
Future<void> renameCollectionFlow(
  BuildContext context,
  WidgetRef ref,
  Namespace ns,
) async {
  if (_needsWrites(context, ref, 'rename collections')) return;
  final name = await showDialog<String>(
    context: context,
    builder: (_) => _RenameDialog(namespace: ns),
  );
  if (name == null || !context.mounted) return;
  try {
    await ref.read(clientProvider).renameCollection(ns, name);
    ref.invalidate(collectionsProvider(ns.db));
    ref.invalidate(collectionStatsProvider(ns));
    ref.read(selectionProvider.notifier).collection(ns.db, name);
    if (context.mounted) {
      _snack(context, 'Renamed ${ns.collection} to $name');
    }
  } on Object catch (e) {
    if (context.mounted) _snack(context, describeError(e));
  }
}

/// Why [name] can't be a database name, or null.
String? databaseNameError(String name) {
  if (name.isEmpty) return 'Enter a database name';
  if (RegExp(r'[/\\. "$*<>:|?]').hasMatch(name)) {
    return r'Database names cannot contain / \ . " $ * < > : | ? or spaces';
  }
  if (name.length > 63) return 'Use at most 63 characters';
  return null;
}

/// Why [name] can't be a collection name, or null.
String? collectionNameError(String name) {
  if (name.isEmpty) return 'Enter a collection name';
  if (name.contains(r'$')) return r'Collection names cannot contain $';
  if (name.startsWith('system.')) return '"system." names are reserved';
  if (name.contains('\u0000')) return 'Collection names cannot contain NUL';
  return null;
}

/// Asks the user to type [name] before a destructive action, as Compass
/// does.
class TypeToConfirmDialog extends StatefulWidget {
  const TypeToConfirmDialog({
    super.key,
    required this.title,
    required this.message,
    required this.name,
    required this.confirmLabel,
  });

  final String title;
  final String message;
  final String name;
  final String confirmLabel;

  @override
  State<TypeToConfirmDialog> createState() => _TypeToConfirmDialogState();
}

class _TypeToConfirmDialogState extends State<TypeToConfirmDialog> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final matches = _name.text == widget.name;
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.message),
          const SizedBox(height: 12),
          Text.rich(
            TextSpan(
              children: [
                const TextSpan(text: 'Type '),
                TextSpan(
                  text: widget.name,
                  style: monoStyle(context, weight: FontWeight.w700),
                ),
                const TextSpan(text: ' to confirm.'),
              ],
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _name,
            autofocus: true,
            autocorrect: false,
            style: monoStyle(context),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: c.danger),
          onPressed: matches ? () => Navigator.pop(context, true) : null,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.namespace});
  final Namespace namespace;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _name = TextEditingController(text: widget.namespace.collection);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final name = _name.text.trim();
    final error = name == widget.namespace.collection
        ? null
        : collectionNameError(name);
    final ok = error == null && name != widget.namespace.collection;
    return AlertDialog(
      title: const Text('Rename collection'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Queries and saved pipelines that use the old name will need '
            'updating. Indexes and documents move with the collection.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            autofocus: true,
            autocorrect: false,
            style: monoStyle(context),
            decoration: InputDecoration(
              labelText: 'New name',
              errorText: error,
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: ok ? (_) => Navigator.pop(context, name) : null,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: ok ? () => Navigator.pop(context, name) : null,
          child: const Text('Rename'),
        ),
      ],
    );
  }
}

enum _Kind { plain, capped, timeseries, clustered }

/// Name and options for a new collection: capped, time series, clustered
/// index and default collation, as in Compass. With [db] null it also asks
/// for a database name (MongoDB creates a database with its first
/// collection).
class CreateCollectionScreen extends ConsumerStatefulWidget {
  const CreateCollectionScreen({super.key, this.db});
  final String? db;

  @override
  ConsumerState<CreateCollectionScreen> createState() =>
      _CreateCollectionScreenState();
}

class _CreateCollectionScreenState
    extends ConsumerState<CreateCollectionScreen> {
  final _db = TextEditingController();
  final _name = TextEditingController();
  final _cappedSize = TextEditingController();
  final _cappedMax = TextEditingController();
  final _timeField = TextEditingController();
  final _metaField = TextEditingController();
  final _expire = TextEditingController();
  final _clusterName = TextEditingController();
  final _collation = TextEditingController();
  _Kind _kind = _Kind.plain;
  String _granularity = 'seconds';
  bool _saving = false;
  bool _tried = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [
      _db,
      _name,
      _cappedSize,
      _cappedMax,
      _timeField,
      _metaField,
      _expire,
      _clusterName,
      _collation,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  String? get _dbError =>
      widget.db == null ? databaseNameError(_db.text.trim()) : null;
  String? get _nameError => collectionNameError(_name.text.trim());

  int? _int(TextEditingController c) => int.tryParse(c.text.trim());

  /// The `create` options, or a problem to show.
  (Map<String, dynamic>?, String?) _options() {
    final o = <String, dynamic>{};
    switch (_kind) {
      case _Kind.plain:
        break;
      case _Kind.capped:
        final size = _int(_cappedSize);
        if (size == null || size <= 0) {
          return (null, 'Enter the capped size in bytes');
        }
        o['capped'] = true;
        o['size'] = size;
        if (_cappedMax.text.trim().isNotEmpty) {
          final max = _int(_cappedMax);
          if (max == null || max <= 0) {
            return (null, 'Max documents must be a positive whole number');
          }
          o['max'] = max;
        }
      case _Kind.timeseries:
        final time = _timeField.text.trim();
        if (time.isEmpty) return (null, 'Enter the time field');
        o['timeseries'] = {
          'timeField': time,
          if (_metaField.text.trim().isNotEmpty)
            'metaField': _metaField.text.trim(),
          'granularity': _granularity,
        };
      case _Kind.clustered:
        o['clusteredIndex'] = {
          'key': {'_id': 1},
          'unique': true,
          if (_clusterName.text.trim().isNotEmpty)
            'name': _clusterName.text.trim(),
        };
    }
    if (_kind == _Kind.timeseries || _kind == _Kind.clustered) {
      if (_expire.text.trim().isNotEmpty) {
        final s = _int(_expire);
        if (s == null || s <= 0) {
          return (null, 'Expire after must be a positive number of seconds');
        }
        o['expireAfterSeconds'] = s;
      }
    }
    final collation = _collation.text.trim();
    if (collation.isNotEmpty) {
      try {
        final c = EJson.parseDocument(collation);
        if (c['locale'] is! String) {
          return (null, "The collation needs a locale, e.g. { locale: 'en' }");
        }
        o['collation'] = c;
      } on Object catch (e) {
        return (
          null,
          'Collation: ${e is EJsonParseException ? e.message : '$e'}',
        );
      }
    }
    return (o, null);
  }

  Future<void> _create() async {
    setState(() => _tried = true);
    final (options, problem) = _options();
    if (_dbError != null || _nameError != null || problem != null) {
      setState(() => _error = problem);
      return;
    }
    final ns = Namespace(widget.db ?? _db.text.trim(), _name.text.trim());
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(clientProvider).createCollection(ns, options!);
      if (mounted) Navigator.pop(context, ns);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = describeError(e);
      });
    }
  }

  Widget _field(
    TextEditingController c,
    String label, {
    String? hint,
    String? error,
    bool number = false,
    bool mono = true,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: c,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: number ? TextInputType.number : null,
      style: mono ? monoStyle(context, size: 13.5) : null,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        errorText: error,
      ),
      onChanged: (_) => setState(() {}),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final title = widget.db == null ? 'Create database' : 'Create collection';
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (widget.db == null) ...[
                    _field(
                      _db,
                      'Database name',
                      error: _tried ? _dbError : null,
                    ),
                    Text(
                      'A database is created with its first collection.',
                      style: TextStyle(color: c.muted, fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                  ] else
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        'In ${widget.db}',
                        style: TextStyle(color: c.muted),
                      ),
                    ),
                  _field(
                    _name,
                    'Collection name',
                    error: _tried ? _nameError : null,
                  ),
                  Text(
                    'Type',
                    style: TextStyle(color: c.muted, fontSize: 12.5),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final (kind, label) in const [
                        (_Kind.plain, 'Standard'),
                        (_Kind.capped, 'Capped'),
                        (_Kind.timeseries, 'Time series'),
                        (_Kind.clustered, 'Clustered'),
                      ])
                        ChoiceChip(
                          label: Text(label),
                          selected: _kind == kind,
                          onSelected: (_) => setState(() => _kind = kind),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ...switch (_kind) {
                    _Kind.plain => const <Widget>[],
                    _Kind.capped => [
                      _field(
                        _cappedSize,
                        'Size in bytes',
                        hint: 'e.g. 1048576',
                        number: true,
                      ),
                      _field(
                        _cappedMax,
                        'Max documents (optional)',
                        number: true,
                      ),
                    ],
                    _Kind.timeseries => [
                      _field(_timeField, 'Time field', hint: 'e.g. timestamp'),
                      _field(
                        _metaField,
                        'Meta field (optional)',
                        hint: 'e.g. sensor',
                      ),
                      Row(
                        children: [
                          const Text('Granularity'),
                          const Spacer(),
                          DropdownButton<String>(
                            value: _granularity,
                            underline: const SizedBox(),
                            items: const [
                              DropdownMenuItem(
                                value: 'seconds',
                                child: Text('Seconds'),
                              ),
                              DropdownMenuItem(
                                value: 'minutes',
                                child: Text('Minutes'),
                              ),
                              DropdownMenuItem(
                                value: 'hours',
                                child: Text('Hours'),
                              ),
                            ],
                            onChanged: (v) => setState(() => _granularity = v!),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      _field(
                        _expire,
                        'Expire after seconds (optional)',
                        number: true,
                      ),
                    ],
                    _Kind.clustered => [
                      Text(
                        'Documents are stored in _id order, which makes '
                        'range queries on _id and TTL deletes cheaper. '
                        'Needs MongoDB 5.3 or later.',
                        style: TextStyle(color: c.muted, fontSize: 12.5),
                      ),
                      const SizedBox(height: 10),
                      _field(_clusterName, 'Index name (optional)'),
                      _field(
                        _expire,
                        'Expire after seconds (optional)',
                        number: true,
                      ),
                    ],
                  },
                  const SizedBox(height: 4),
                  TextField(
                    controller: _collation,
                    autocorrect: false,
                    enableSuggestions: false,
                    inputFormatters: [QueryInputFormatter()],
                    style: monoStyle(context, size: 13.5),
                    decoration: const InputDecoration(
                      labelText: 'Default collation (optional)',
                      hintText: "{ locale: 'en', strength: 2 }",
                    ),
                  ),
                  if (_error case final error?) ...[
                    const SizedBox(height: 16),
                    MessageBanner(message: error),
                  ],
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 8, 12, 12),
              decoration: BoxDecoration(
                color: c.panel,
                border: Border(top: BorderSide(color: c.border)),
              ),
              child: Row(
                children: [
                  const Spacer(),
                  TextButton(
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 4),
                  AccentButton(
                    label: _saving ? 'Creating…' : 'Create',
                    compact: true,
                    onPressed: _saving ? null : _create,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
