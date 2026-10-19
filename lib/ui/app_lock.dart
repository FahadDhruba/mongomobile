import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import '../theme/app_theme.dart';
import 'widgets/common.dart';

/// Covers the app with a lock screen when the biometric lock is on: at
/// start, and when the app comes back after [relockAfter] in the
/// background. The navigation stack underneath is kept.
class AppLockGate extends ConsumerStatefulWidget {
  const AppLockGate({super.key, required this.child});
  final Widget child;

  static const relockAfter = Duration(seconds: 30);

  @override
  ConsumerState<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends ConsumerState<AppLockGate>
    with WidgetsBindingObserver {
  late bool _locked = ref.read(settingsProvider).biometricLock;
  bool _authenticating = false;
  DateTime? _backgroundSince;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_locked) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_authenticating) return;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _backgroundSince ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final since = _backgroundSince;
      _backgroundSince = null;
      if (since != null &&
          ref.read(settingsProvider).biometricLock &&
          DateTime.now().difference(since) >= AppLockGate.relockAfter) {
        setState(() => _locked = true);
        _unlock();
      }
    }
  }

  Future<void> _unlock() async {
    if (_authenticating) return;
    setState(() {
      _authenticating = true;
      _error = null;
    });
    final error = await ref
        .read(biometricsProvider)
        .authenticate('Unlock MongoMobile');
    if (!mounted) return;
    setState(() {
      _authenticating = false;
      _error = error;
      if (error == null) _locked = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Stack(
      children: [
        widget.child,
        if (_locked)
          Positioned.fill(
            child: Material(
              color: c.background,
              child: SafeArea(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const AppLogo(size: 72),
                        const SizedBox(height: 20),
                        const Text('MongoMobile is locked',
                            style: TextStyle(
                                fontSize: 18, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        Text(_error ?? 'Unlock to continue',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: c.muted)),
                        const SizedBox(height: 24),
                        AccentButton(
                          label: 'Unlock',
                          icon: Icons.fingerprint,
                          onPressed: _authenticating ? null : _unlock,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
