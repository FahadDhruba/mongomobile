import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/connection_profile.dart';
import '../../services/connection_transfer.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../widgets/common.dart';
import 'connection_edit_screen.dart';
import 'settings_screen.dart';
import 'update_sheet.dart';
import 'workspace_screen.dart';

/// The start screen: saved connections.
class ConnectionsScreen extends ConsumerWidget {
  const ConnectionsScreen({super.key});

  Future<void> _edit(BuildContext context, [ConnectionProfile? profile]) =>
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ConnectionEditScreen(profile: profile),
        ),
      );

  void _snack(BuildContext context, String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _export(BuildContext context, WidgetRef ref) async {
    final list = ref.read(connectionsProvider).value ?? const [];
    if (list.isEmpty) {
      _snack(context, 'There are no connections to export');
      return;
    }
    final passphrase = await showDialog<String>(
      context: context,
      builder: (_) => _ExportDialog(count: list.length),
    );
    if (passphrase == null || !context.mounted) return;
    try {
      final text = await exportConnections(
        list,
        passphrase: passphrase.isEmpty ? null : passphrase,
      );
      final sink = await ref
          .read(nativeFilesProvider)
          .create('mongomobile-connections.json', 'application/json');
      if (sink == null) return;
      await sink.add(utf8.encode(text));
      await sink.close();
      if (context.mounted) {
        _snack(
          context,
          'Exported ${list.length} connection${list.length == 1 ? '' : 's'}',
        );
      }
    } on Object catch (e) {
      if (context.mounted) _snack(context, describeError(e));
    }
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    try {
      final source = await ref.read(nativeFilesProvider).open(const [
        'application/json',
        'text/plain',
        'application/octet-stream',
      ]);
      if (source == null) return;
      final bytes = <int>[];
      await for (final chunk in source.read()) {
        bytes.addAll(chunk);
        if (bytes.length > 8 << 20) {
          throw TransferException(
            'The file is too large for a connections file',
          );
        }
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      String? passphrase;
      if (needsPassphrase(text)) {
        if (!context.mounted) return;
        passphrase = await showDialog<String>(
          context: context,
          builder: (_) => const _PassphraseDialog(),
        );
        if (passphrase == null) return;
      }
      final imported = await importConnections(text, passphrase: passphrase);
      final notifier = ref.read(connectionsProvider.notifier);
      final existing = {
        for (final p in ref.read(connectionsProvider).value ?? const []) p.id,
      };
      var replaced = 0;
      for (final p in imported.profiles) {
        if (existing.contains(p.id)) replaced++;
        await notifier.upsert(p);
      }
      final n = imported.profiles.length;
      if (context.mounted) {
        _snack(
          context,
          'Imported $n connection${n == 1 ? '' : 's'}'
          '${replaced > 0 ? ' ($replaced updated)' : ''}'
          '${imported.withoutPasswords > 0 ? '. ${imported.withoutPasswords} need a password: edit them before connecting.' : ''}',
        );
      }
    } on TransferException catch (e) {
      if (context.mounted) _snack(context, e.message);
    } on PlatformException catch (e) {
      if (context.mounted) _snack(context, e.message ?? '$e');
    } on Object catch (e) {
      if (context.mounted) _snack(context, describeError(e));
    }
  }

  Future<void> _connect(
    BuildContext context,
    WidgetRef ref,
    ConnectionProfile profile,
  ) async {
    var cancelled = false;
    String? error;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: ctx.colors.accent,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(child: Text('Connecting to ${profile.displayName}…')),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                cancelled = true;
                Navigator.pop(ctx);
              },
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
    try {
      await ref.read(sessionProvider.notifier).connect(profile);
    } on Object catch (e) {
      error = describeError(e);
    }
    if (!context.mounted) return;
    if (cancelled) {
      // The user gave up waiting; drop the connection if it arrived anyway.
      await ref.read(sessionProvider.notifier).disconnect();
      return;
    }
    Navigator.pop(context);
    if (error != null) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Could not connect'),
          content: SelectableText(error!),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _edit(context, profile);
              },
              child: const Text('Edit connection'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const WorkspaceScreen()),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final connections = ref.watch(connectionsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            AppLogo(size: 28),
            SizedBox(width: 10),
            Text('MongoMobile'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Settings',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
            icon: const Icon(Icons.settings_outlined),
          ),
          PopupMenuButton<String>(
            tooltip: 'More options',
            onSelected: (v) =>
                v == 'import' ? _import(context, ref) : _export(context, ref),
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'import',
                child: Text('Import connections…'),
              ),
              PopupMenuItem(
                value: 'export',
                child: Text('Export connections…'),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: c.accent,
        foregroundColor: c.onAccent,
        onPressed: () => _edit(context),
        icon: const Icon(Icons.add),
        label: const Text(
          'New connection',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const UpdateBanner(),
          Expanded(child: _list(context, ref, connections)),
        ],
      ),
    );
  }

  Widget _list(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<List<ConnectionProfile>> connections,
  ) {
    return connections.when(
      loading: () => const LoadingView(),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(16),
        child: MessageBanner(
          message: 'Saved connections could not be read: ${describeError(e)}',
        ),
      ),
      data: (list) {
        if (list.isEmpty) {
          return EmptyState(
            icon: Icons.cable,
            title: 'No connections yet',
            message:
                'Add a mongodb:// or mongodb+srv:// connection string. '
                'Everything stays on this device; there is no server in '
                'between.',
            action: AccentButton(
              label: 'New connection',
              icon: Icons.add,
              onPressed: () => _edit(context),
            ),
          );
        }
        final notifier = ref.read(connectionsProvider.notifier);
        int byRecent(ConnectionProfile a, ConnectionProfile b) {
          final x = a.lastUsed, y = b.lastUsed;
          if (x == null && y == null) {
            return a.displayName.toLowerCase().compareTo(
              b.displayName.toLowerCase(),
            );
          }
          if (x == null) return 1;
          if (y == null) return -1;
          return y.compareTo(x);
        }

        final favorites = list.where((p) => p.favorite).toList()
          ..sort(byRecent);
        final groups = <String, List<ConnectionProfile>>{};
        for (final p in list.where((p) => !p.favorite && p.group.isNotEmpty)) {
          groups.putIfAbsent(p.group, () => []).add(p);
        }
        final groupNames = groups.keys.toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        final rest = list.where((p) => !p.favorite && p.group.isEmpty).toList()
          ..sort(byRecent);
        final allGroups = {
          for (final p in list)
            if (p.group.isNotEmpty) p.group,
        }.toList()..sort();

        Widget card(ConnectionProfile p) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _ConnectionCard(
            profile: p,
            onTap: () => _connect(context, ref, p),
            onEdit: () => _edit(context, p),
            onFavorite: () =>
                notifier.upsert(p.copyWith(favorite: !p.favorite)),
            onGroup: () async {
              final group = await showDialog<String>(
                context: context,
                builder: (_) =>
                    _GroupDialog(current: p.group, groups: allGroups),
              );
              if (group != null) {
                await notifier.upsert(p.copyWith(group: group));
              }
            },
            onDuplicate: () => notifier.upsert(
              p.copyWith(
                id: ConnectionProfile.newId(),
                name: '${p.displayName} copy',
                favorite: false,
              ),
            ),
            onDelete: () async {
              final ok = await confirmDialog(
                context,
                title: 'Delete connection?',
                message: 'Remove "${p.displayName}" from this device?',
              );
              if (ok) await notifier.delete(p.id);
            },
          ),
        );

        final sectioned = favorites.isNotEmpty || groups.isNotEmpty;
        return ListView(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
          children: [
            if (favorites.isNotEmpty) ...[
              const _Section(icon: Icons.star, title: 'Favourites'),
              for (final p in favorites) card(p),
            ],
            for (final g in groupNames) ...[
              _Section(icon: Icons.folder_outlined, title: g),
              for (final p in groups[g]!) card(p),
            ],
            if (rest.isNotEmpty) ...[
              if (sectioned)
                const _Section(icon: Icons.history, title: 'Connections')
              else
                const SizedBox(height: 8),
              for (final p in rest) card(p),
            ],
          ],
        );
      },
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({
    required this.profile,
    required this.onTap,
    required this.onEdit,
    required this.onFavorite,
    required this.onGroup,
    required this.onDuplicate,
    required this.onDelete,
  });

  final ConnectionProfile profile;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onFavorite;
  final VoidCallback onGroup;
  final VoidCallback onDuplicate;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color =
        connectionColors[profile.colorIndex % connectionColors.length];
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profile.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      profile.displayHost,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: monoStyle(context, size: 12, color: c.muted),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: profile.favorite
                    ? 'Remove from favourites'
                    : 'Add to favourites',
                onPressed: onFavorite,
                icon: Icon(
                  profile.favorite ? Icons.star : Icons.star_border,
                  color: profile.favorite ? c.warning : c.muted,
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Connection actions',
                onSelected: (v) => switch (v) {
                  'edit' => onEdit(),
                  'group' => onGroup(),
                  'duplicate' => onDuplicate(),
                  'delete' => onDelete(),
                  _ => null,
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit')),
                  PopupMenuItem(value: 'group', child: Text('Move to group…')),
                  PopupMenuItem(value: 'duplicate', child: Text('Duplicate')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.icon, required this.title});
  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: c.muted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              title,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: c.muted,
                fontWeight: FontWeight.w700,
                fontSize: 12.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Picks a group for a connection; pops with '' for none.
class _GroupDialog extends StatefulWidget {
  const _GroupDialog({required this.current, required this.groups});
  final String current;
  final List<String> groups;

  @override
  State<_GroupDialog> createState() => _GroupDialogState();
}

class _GroupDialogState extends State<_GroupDialog> {
  late final _name = TextEditingController(text: widget.current);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Move to group'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Group name',
              hintText: 'e.g. Work',
            ),
            onSubmitted: (v) => Navigator.pop(context, v.trim()),
          ),
          if (widget.groups.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final g in widget.groups)
                  ActionChip(
                    label: Text(g),
                    onPressed: () => Navigator.pop(context, g),
                  ),
              ],
            ),
          ],
        ],
      ),
      actions: [
        if (widget.current.isNotEmpty)
          TextButton(
            onPressed: () => Navigator.pop(context, ''),
            child: const Text('No group'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _name.text.trim()),
          child: const Text('Move'),
        ),
      ],
    );
  }
}

/// Asks whether to include passwords. Pops with the passphrase, '' for
/// none, or null when cancelled.
class _ExportDialog extends StatefulWidget {
  const _ExportDialog({required this.count});
  final int count;

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  bool _withPasswords = false;
  final _pass = TextEditingController();
  final _again = TextEditingController();

  @override
  void dispose() {
    _pass.dispose();
    _again.dispose();
    super.dispose();
  }

  String? get _problem {
    if (!_withPasswords) return null;
    if (_pass.text.length < 8) return 'Use at least 8 characters';
    if (_pass.text != _again.text) return 'The passphrases differ';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AlertDialog(
      title: Text(
        'Export ${widget.count} connection${widget.count == 1 ? '' : 's'}',
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'The file works with MongoDB Compass\'s "Import saved '
              'connections" too.',
              style: TextStyle(color: c.muted, fontSize: 13),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Include passwords'),
              subtitle: const Text(
                'Encrypted with a passphrase. Compass imports the file '
                'without them.',
              ),
              value: _withPasswords,
              onChanged: (v) => setState(() => _withPasswords = v),
            ),
            if (_withPasswords) ...[
              TextField(
                controller: _pass,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Passphrase'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _again,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'Passphrase again',
                  errorText: _again.text.isEmpty ? null : _problem,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _problem == null
              ? () => Navigator.pop(context, _withPasswords ? _pass.text : '')
              : null,
          child: const Text('Export'),
        ),
      ],
    );
  }
}

class _PassphraseDialog extends StatefulWidget {
  const _PassphraseDialog();

  @override
  State<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<_PassphraseDialog> {
  final _pass = TextEditingController();

  @override
  void dispose() {
    _pass.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Passphrase'),
      content: TextField(
        controller: _pass,
        autofocus: true,
        obscureText: true,
        decoration: const InputDecoration(
          labelText: 'The passphrase the file was saved with',
        ),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _pass.text),
          child: const Text('Import'),
        ),
      ],
    );
  }
}
