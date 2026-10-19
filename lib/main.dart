import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'models/app_settings.dart';
import 'services/settings_store.dart';
import 'state/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Anything that goes wrong before or while drawing the first frame must
  // end up on screen; otherwise Android keeps showing the splash.
  ErrorWidget.builder = (details) => StartupErrorView(error: details.exception);
  LicenseRegistry.addLicense(() async* {
    for (final (name, file) in [
      ('Inter', 'assets/fonts/Inter-OFL.txt'),
      ('JetBrains Mono', 'assets/fonts/JetBrainsMono-OFL.txt'),
    ]) {
      yield LicenseEntryWithLineBreaks([name], await rootBundle.loadString(file));
    }
  });
  AppSettings settings;
  try {
    settings = await SettingsStore().load().timeout(const Duration(seconds: 4));
  } on Object {
    settings = const AppSettings();
  }
  try {
    runApp(
      ProviderScope(
        overrides: [initialSettingsProvider.overrideWithValue(settings)],
        // Database errors are shown to the user with a Retry button instead
        // of being retried silently in the background.
        retry: (_, _) => null,
        child: const MongoMobileApp(),
      ),
    );
  } on Object catch (e) {
    runApp(MaterialApp(home: StartupErrorView(error: e)));
  }
}

/// A plain, readable error screen that needs no app state.
class StartupErrorView extends StatelessWidget {
  const StartupErrorView({super.key, required this.error});
  final Object error;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF001E2B),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Text(
            'MongoMobile hit an error:\n\n$error',
            textDirection: TextDirection.ltr,
            style: const TextStyle(color: Color(0xFFFF6F5C), fontSize: 14),
          ),
        ),
      ),
    );
  }
}
