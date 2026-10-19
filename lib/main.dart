import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'services/settings_store.dart';
import 'state/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    for (final (name, file) in [
      ('Inter', 'assets/fonts/Inter-OFL.txt'),
      ('JetBrains Mono', 'assets/fonts/JetBrainsMono-OFL.txt'),
    ]) {
      yield LicenseEntryWithLineBreaks([name], await rootBundle.loadString(file));
    }
  });
  final settings = await SettingsStore().load();
  runApp(
    ProviderScope(
      overrides: [initialSettingsProvider.overrideWithValue(settings)],
      // Database errors are shown to the user with a Retry button instead of
      // being retried silently in the background.
      retry: (_, _) => null,
      child: const MongoMobileApp(),
    ),
  );
}
