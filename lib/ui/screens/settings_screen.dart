import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/app_settings.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../widgets/common.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final s = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    Widget section(String title) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
          child: Text(title.toUpperCase(),
              style: TextStyle(
                  color: c.accent,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8)),
        );

    Future<void> pickNumber({
      required String title,
      required String unit,
      required int current,
      required List<int> options,
      required void Function(int) apply,
    }) async {
      final v = await showDialog<int>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: Text(title),
          children: [
            RadioGroup<int>(
              groupValue: current,
              onChanged: (x) => Navigator.pop(ctx, x),
              child: Column(
                children: [
                  for (final o in options)
                    RadioListTile<int>(value: o, title: Text('$o $unit')),
                ],
              ),
            ),
          ],
        ),
      );
      if (v != null) apply(v);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          section('Appearance'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<ThemeMode>(
              style: SegmentedButton.styleFrom(
                selectedBackgroundColor: c.accentStrong,
                selectedForegroundColor: Colors.white,
              ),
              segments: const [
                ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                ButtonSegment(value: ThemeMode.system, label: Text('System')),
              ],
              selected: {s.themeMode},
              onSelectionChanged: (v) =>
                  notifier.update((x) => x.copyWith(themeMode: v.first)),
            ),
          ),
          section('Queries'),
          ListTile(
            title: const Text('Query time limit (maxTimeMS)'),
            subtitle: const Text('The server stops queries that run longer'),
            trailing: Text('${s.queryTimeoutMs ~/ 1000} s'),
            onTap: () => pickNumber(
              title: 'Query time limit',
              unit: 'seconds',
              current: s.queryTimeoutMs ~/ 1000,
              options: const [5, 10, 20, 30, 60, 120],
              apply: (v) =>
                  notifier.update((x) => x.copyWith(queryTimeoutMs: v * 1000)),
            ),
          ),
          ListTile(
            title: const Text('Count time limit'),
            subtitle: const Text(
                'Filtered counts run in the background and give up after this'),
            trailing: Text('${s.countTimeoutMs ~/ 1000} s'),
            onTap: () => pickNumber(
              title: 'Count time limit',
              unit: 'seconds',
              current: s.countTimeoutMs ~/ 1000,
              options: const [2, 5, 10, 20, 30],
              apply: (v) =>
                  notifier.update((x) => x.copyWith(countTimeoutMs: v * 1000)),
            ),
          ),
          ListTile(
            title: const Text('Default page size'),
            trailing: Text('${s.defaultPageSize}'),
            onTap: () => pickNumber(
              title: 'Default page size',
              unit: 'documents',
              current: s.defaultPageSize,
              options: AppSettings.pageSizes,
              apply: (v) =>
                  notifier.update((x) => x.copyWith(defaultPageSize: v)),
            ),
          ),
          ListTile(
            title: const Text('Page size limit'),
            subtitle: const Text('Stop reading a page after this much data'),
            trailing: Text('${s.maxPageMegabytes} MB'),
            onTap: () => pickNumber(
              title: 'Page size limit',
              unit: 'MB',
              current: s.maxPageMegabytes,
              options: const [1, 2, 4, 8, 16],
              apply: (v) =>
                  notifier.update((x) => x.copyWith(maxPageMegabytes: v)),
            ),
          ),
          ListTile(
            title: const Text('Long values'),
            subtitle: const Text('Show this many characters before "show more"'),
            trailing: Text('${s.stringPreviewLength}'),
            onTap: () => pickNumber(
              title: 'Preview length',
              unit: 'characters',
              current: s.stringPreviewLength,
              options: const [80, 200, 500, 2000],
              apply: (v) =>
                  notifier.update((x) => x.copyWith(stringPreviewLength: v)),
            ),
          ),
          section('Security'),
          SwitchListTile(
            title: const Text('Biometric lock'),
            subtitle: const Text(
                'Ask for your fingerprint, face or screen lock when the app '
                'opens or returns after 30 seconds'),
            value: s.biometricLock,
            onChanged: (v) async {
              final bio = ref.read(biometricsProvider);
              if (v) {
                if (!await bio.isAvailable()) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text(
                            'Set up a screen lock or biometrics on this device first')));
                  }
                  return;
                }
                final error =
                    await bio.authenticate('Confirm to turn on the app lock');
                if (error != null) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(error)));
                  }
                  return;
                }
              }
              await notifier.update((x) => x.copyWith(biometricLock: v));
            },
          ),
          const ListTile(
            leading: Icon(Icons.lock_outline),
            title: Text('Connections are stored encrypted'),
            subtitle: Text(
                'Connection strings, including passwords, are kept in Android '
                'secure storage and never leave the device except to reach your '
                'server.'),
          ),
          section('About'),
          ListTile(
            leading: const AppLogo(size: 28),
            title: const Text('MongoMobile'),
            subtitle: const Text(
                'A serverless MongoDB client. Not affiliated with MongoDB, Inc.'),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'MongoMobile',
              applicationIcon: const Padding(
                padding: EdgeInsets.all(8),
                child: AppLogo(size: 48),
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
