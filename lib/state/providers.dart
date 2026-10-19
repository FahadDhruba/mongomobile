import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mongo_wire/mongo_wire.dart';

import '../models/app_settings.dart';
import '../models/connection_profile.dart';
import '../services/biometrics.dart';
import '../services/connection_store.dart';
import '../services/native.dart';
import '../services/settings_store.dart';
import '../services/updater.dart';

// Services. Overridden in tests.
final connectorProvider = Provider<MongoConnector>(
  (_) => const WireConnector(),
);
final connectionStoreProvider = Provider<ConnectionStore>(
  (_) => ConnectionStore(),
);
final settingsStoreProvider = Provider<SettingsStore>((_) => SettingsStore());
final biometricsProvider = Provider<Biometrics>((_) => Biometrics());
final nativeFilesProvider = Provider<NativeFiles>((_) => NativeFiles());
final updaterProvider = Provider<Updater>((_) => Updater());

/// A newer release, checked once per launch when automatic checks are on.
/// Errors (offline, rate limits) count as "no update".
final availableUpdateProvider = FutureProvider<ReleaseInfo?>((ref) async {
  final auto = ref.watch(settingsProvider.select((s) => s.autoCheckUpdates));
  if (!auto) return null;
  try {
    return await ref.read(updaterProvider).availableUpdate();
  } on Object {
    return null;
  }
});

/// Settings loaded before the app starts; see main().
final initialSettingsProvider = Provider<AppSettings>(
  (_) => const AppSettings(),
);

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.read(initialSettingsProvider);

  Future<void> update(AppSettings Function(AppSettings s) change) async {
    state = change(state);
    await ref.read(settingsStoreProvider).save(state);
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

class ConnectionsNotifier extends AsyncNotifier<List<ConnectionProfile>> {
  @override
  Future<List<ConnectionProfile>> build() => ref
      .read(connectionStoreProvider)
      .load()
      .timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException(
          'Secure storage did not answer within 10 seconds',
        ),
      );

  Future<void> _persist(List<ConnectionProfile> list) async {
    state = AsyncData(list);
    await ref.read(connectionStoreProvider).save(list);
  }

  Future<void> upsert(ConnectionProfile p) async {
    final list = [...?state.value];
    final i = list.indexWhere((e) => e.id == p.id);
    if (i >= 0) {
      list[i] = p;
    } else {
      list.add(p);
    }
    await _persist(list);
  }

  Future<void> delete(String id) async {
    await _persist([...?state.value]..removeWhere((e) => e.id == id));
  }

  Future<void> markUsed(String id) async {
    final list = [...?state.value];
    final i = list.indexWhere((e) => e.id == id);
    if (i < 0) return;
    list[i] = list[i].copyWith(lastUsed: DateTime.now());
    await _persist(list);
  }
}

final connectionsProvider =
    AsyncNotifierProvider<ConnectionsNotifier, List<ConnectionProfile>>(
      ConnectionsNotifier.new,
    );

/// A live connection.
class Session {
  const Session({
    required this.profile,
    required this.client,
    this.readOnly = true,
  });

  final ConnectionProfile profile;
  final MongoClient client;

  /// Writes are blocked until the user turns on write mode.
  final bool readOnly;

  Session copyWith({bool? readOnly}) => Session(
    profile: profile,
    client: client,
    readOnly: readOnly ?? this.readOnly,
  );
}

class SessionNotifier extends Notifier<Session?> {
  @override
  Session? build() => null;

  /// Connects and makes the result the current session.
  Future<void> connect(ConnectionProfile profile) async {
    await disconnect();
    final client = await ref
        .read(connectorProvider)
        .connect(profile.uri, profile.connectOptions);
    state = Session(profile: profile, client: client);
    ref.read(selectionProvider.notifier).clear();
    unawaited(ref.read(connectionsProvider.notifier).markUsed(profile.id));
  }

  void setReadOnly(bool readOnly) {
    final s = state;
    if (s != null) state = s.copyWith(readOnly: readOnly);
  }

  Future<void> disconnect() async {
    final s = state;
    state = null;
    await s?.client.close();
  }
}

final sessionProvider = NotifierProvider<SessionNotifier, Session?>(
  SessionNotifier.new,
);

/// The current client; throws when nothing is connected.
final clientProvider = Provider<MongoClient>((ref) {
  final s = ref.watch(sessionProvider);
  if (s == null) throw StateError('Not connected');
  return s.client;
});

final readOnlyProvider = Provider<bool>(
  (ref) => ref.watch(sessionProvider)?.readOnly ?? true,
);

/// What the workspace body shows.
class Selection {
  const Selection({this.db, this.collection});
  final String? db;
  final String? collection;

  Namespace? get namespace =>
      db != null && collection != null ? Namespace(db!, collection!) : null;
}

class SelectionNotifier extends Notifier<Selection> {
  @override
  Selection build() => const Selection();

  void clear() => state = const Selection();
  void database(String db) => state = Selection(db: db);
  void collection(String db, String coll) =>
      state = Selection(db: db, collection: coll);

  /// Moves one level up. Returns false when already at the top.
  bool up() {
    if (state.collection != null) {
      state = Selection(db: state.db);
      return true;
    }
    if (state.db != null) {
      state = const Selection();
      return true;
    }
    return false;
  }
}

final selectionProvider = NotifierProvider<SelectionNotifier, Selection>(
  SelectionNotifier.new,
);

final databasesProvider = FutureProvider<List<DatabaseInfo>>((ref) {
  final client = ref.watch(clientProvider);
  return client.listDatabases();
});

final collectionsProvider = FutureProvider.family<List<CollectionInfo>, String>(
  (ref, db) {
    final client = ref.watch(clientProvider);
    return client.listCollections(db);
  },
);

/// Limits how many stats requests run at once, so browsing the tree never
/// fills the connection pool ahead of a document query.
class Semaphore {
  Semaphore(this.permits);
  int permits;
  final _waiters = <Completer<void>>[];

  Future<T> run<T>(Future<T> Function() action) async {
    if (permits > 0) {
      permits--;
    } else {
      final c = Completer<void>();
      _waiters.add(c);
      await c.future;
    }
    try {
      return await action();
    } finally {
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete();
      } else {
        permits++;
      }
    }
  }
}

final _statsSemaphoreProvider = Provider<Semaphore>((ref) {
  ref.watch(clientProvider);
  return Semaphore(2);
});

final collectionStatsProvider =
    FutureProvider.family<CollectionStats?, Namespace>((ref, ns) {
      final client = ref.watch(clientProvider);
      return ref
          .watch(_statsSemaphoreProvider)
          .run(() => client.collectionStats(ns));
    });

/// Turns any error into a message for the UI.
String describeError(Object error) {
  if (error is MongoException) return error.toString();
  if (error is FormatException) return error.message;
  if (error is StateError) return error.message;
  return error.toString();
}
