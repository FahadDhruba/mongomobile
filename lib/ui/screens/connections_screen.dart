import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/connection_profile.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../widgets/common.dart';
import 'connection_edit_screen.dart';
import 'settings_screen.dart';
import 'workspace_screen.dart';

/// The start screen: saved connections.
class ConnectionsScreen extends ConsumerWidget {
  const ConnectionsScreen({super.key});

  Future<void> _edit(BuildContext context, [ConnectionProfile? profile]) =>
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ConnectionEditScreen(profile: profile)),
      );

  Future<void> _connect(
      BuildContext context, WidgetRef ref, ConnectionProfile profile) async {
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
                    strokeWidth: 2.5, color: ctx.colors.accent),
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
                child: const Text('Edit connection')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
          ],
        ),
      );
      return;
    }
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => const WorkspaceScreen()));
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
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SettingsScreen())),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: c.accent,
        foregroundColor: c.onAccent,
        onPressed: () => _edit(context),
        icon: const Icon(Icons.add),
        label: const Text('New connection',
            style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: connections.when(
        loading: () => const LoadingView(),
        error: (e, _) => Padding(
          padding: const EdgeInsets.all(16),
          child: MessageBanner(
              message: 'Saved connections could not be read: ${describeError(e)}'),
        ),
        data: (list) {
          if (list.isEmpty) {
            return EmptyState(
              icon: Icons.cable,
              title: 'No connections yet',
              message: 'Add a mongodb:// or mongodb+srv:// connection string. '
                  'Everything stays on this device; there is no server in '
                  'between.',
              action: AccentButton(
                label: 'New connection',
                icon: Icons.add,
                onPressed: () => _edit(context),
              ),
            );
          }
          final sorted = [...list]..sort((a, b) {
              final x = a.lastUsed, y = b.lastUsed;
              if (x == null && y == null) return a.displayName.compareTo(b.displayName);
              if (x == null) return 1;
              if (y == null) return -1;
              return y.compareTo(x);
            });
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
            itemCount: sorted.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (_, i) => _ConnectionCard(
              profile: sorted[i],
              onTap: () => _connect(context, ref, sorted[i]),
              onEdit: () => _edit(context, sorted[i]),
              onDuplicate: () => ref.read(connectionsProvider.notifier).upsert(
                  sorted[i].copyWith(
                      id: ConnectionProfile.newId(),
                      name: '${sorted[i].displayName} copy')),
              onDelete: () async {
                final ok = await confirmDialog(context,
                    title: 'Delete connection?',
                    message: 'Remove "${sorted[i].displayName}" from this device?');
                if (ok) {
                  await ref.read(connectionsProvider.notifier).delete(sorted[i].id);
                }
              },
            ),
          );
        },
      ),
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({
    required this.profile,
    required this.onTap,
    required this.onEdit,
    required this.onDuplicate,
    required this.onDelete,
  });

  final ConnectionProfile profile;
  final VoidCallback onTap;
  final VoidCallback onEdit;
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
                    Text(profile.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 15.5, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(profile.displayHost,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle(context, size: 12, color: c.muted)),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (v) => switch (v) {
                  'edit' => onEdit(),
                  'duplicate' => onDuplicate(),
                  'delete' => onDelete(),
                  _ => null,
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit')),
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
