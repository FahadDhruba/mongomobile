import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'state/providers.dart';
import 'theme/app_theme.dart';
import 'ui/app_lock.dart';
import 'ui/screens/connections_screen.dart';

class MongoMobileApp extends ConsumerWidget {
  const MongoMobileApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(settingsProvider.select((s) => s.themeMode));
    return MaterialApp(
      title: 'MongoMobile',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: themeMode,
      builder: (context, child) => AppLockGate(child: child!),
      home: const ConnectionsScreen(),
    );
  }
}
