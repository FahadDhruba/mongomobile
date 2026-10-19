import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mongo_wire/mongo_wire.dart'
    show CancelToken, MongoCancelledError;

import '../../services/updater.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../widgets/common.dart';

Future<void> showUpdateSheet(BuildContext context, ReleaseInfo release) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      isDismissible: false,
      builder: (_) => UpdateSheet(release: release),
    );

/// Checks for an update on request and reports the outcome.
Future<void> checkForUpdatesNow(BuildContext context, WidgetRef ref) async {
  final messenger = ScaffoldMessenger.of(context);
  final updater = ref.read(updaterProvider);
  if (updater.current == null) {
    messenger.showSnackBar(
      const SnackBar(
        content: Text(
          'This is a development build; updates come from '
          'GitHub Releases builds only.',
        ),
      ),
    );
    return;
  }
  messenger.showSnackBar(
    const SnackBar(content: Text('Checking for updates…')),
  );
  try {
    final r = await updater.availableUpdate();
    messenger.hideCurrentSnackBar();
    if (r == null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('MongoMobile $appVersion is the latest version'),
        ),
      );
    } else if (context.mounted) {
      await showUpdateSheet(context, r);
    }
  } on Object catch (e) {
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(content: Text('Could not check for updates: $e')),
    );
  }
}

class UpdateSheet extends ConsumerStatefulWidget {
  const UpdateSheet({super.key, required this.release});
  final ReleaseInfo release;

  @override
  ConsumerState<UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends ConsumerState<UpdateSheet>
    with WidgetsBindingObserver {
  CancelToken? _cancel;
  int _received = 0;
  int _total = 0;
  String? _apkPath;
  String? _error;
  bool _needsPermission = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancel?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from the "install unknown apps" screen.
    if (state == AppLifecycleState.resumed &&
        _needsPermission &&
        _apkPath != null) {
      _install();
    }
  }

  Future<void> _download() async {
    final token = CancelToken();
    setState(() {
      _cancel = token;
      _error = null;
      _received = 0;
    });
    try {
      final path = await ref
          .read(updaterProvider)
          .download(
            widget.release,
            cancel: token,
            onProgress: (r, t) {
              if (mounted) {
                setState(() {
                  _received = r;
                  _total = t;
                });
              }
            },
          );
      if (!mounted) return;
      setState(() {
        _cancel = null;
        _apkPath = path;
      });
      await _install();
    } on MongoCancelledError {
      if (mounted) setState(() => _cancel = null);
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _cancel = null;
          _error = 'Download failed: $e';
        });
      }
    }
  }

  Future<void> _install() async {
    final updater = ref.read(updaterProvider);
    try {
      if (!await updater.canInstall()) {
        setState(() => _needsPermission = true);
        return;
      }
      setState(() => _needsPermission = false);
      await updater.install(_apkPath!);
    } on PlatformException catch (e) {
      setState(() => _error = 'Could not start the installer: ${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final r = widget.release;
    final downloading = _cancel != null;
    final fraction = _total > 0 ? _received / _total : null;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const AppLogo(size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'MongoMobile ${r.versionName}',
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      'You have $appVersion  ·  download ${formatBytes(r.apkSize)}',
                      style: TextStyle(color: c.muted, fontSize: 12.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (r.notes.isNotEmpty) ...[
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: SingleChildScrollView(
                child: SelectableText(
                  r.notes,
                  style: TextStyle(color: c.text, fontSize: 13, height: 1.4),
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            'The update installs over this version and keeps your saved '
            'connections. Android will ask you to confirm.',
            style: TextStyle(color: c.muted, fontSize: 12.5),
          ),
          if (downloading) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: fraction,
              color: c.accent,
              backgroundColor: c.border,
            ),
            const SizedBox(height: 6),
            Text(
              'Downloading ${formatBytes(_received)}'
              '${_total > 0 ? ' of ${formatBytes(_total)}' : ''}',
              style: TextStyle(color: c.text, fontSize: 13),
            ),
          ],
          if (_needsPermission) ...[
            const SizedBox(height: 12),
            MessageBanner(
              kind: BannerKind.warning,
              message:
                  'Android needs your permission for MongoMobile to '
                  'install updates. Allow it on the next screen, then come back.',
              action: TextButton(
                onPressed: () =>
                    ref.read(updaterProvider).openInstallSettings(),
                child: const Text('Allow'),
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            MessageBanner(message: _error!),
          ],
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () {
                  _cancel?.cancel();
                  Navigator.pop(context);
                },
                child: Text(downloading ? 'Cancel' : 'Later'),
              ),
              const SizedBox(width: 8),
              AccentButton(
                label: _apkPath != null ? 'Install' : 'Download and install',
                icon: Icons.system_update_alt,
                onPressed: downloading
                    ? null
                    : (_apkPath != null ? _install : _download),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Shown at the top of the connections list when a newer release exists.
class UpdateBanner extends ConsumerWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final release = ref.watch(availableUpdateProvider).value;
    if (release == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Card(
        child: ListTile(
          leading: Icon(Icons.system_update, color: c.accent),
          title: Text('MongoMobile ${release.versionName} is available'),
          subtitle: Text(
            'You have $appVersion',
            style: TextStyle(color: c.muted, fontSize: 12.5),
          ),
          trailing: TextButton(
            onPressed: () => showUpdateSheet(context, release),
            child: const Text('Update'),
          ),
        ),
      ),
    );
  }
}
