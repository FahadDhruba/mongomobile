import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mongo_wire/mongo_wire.dart';

import '../models/app_settings.dart';
import '../models/connection_profile.dart';
import '../services/biometrics.dart';
import '../services/connection_opener.dart';
import '../services/connection_store.dart';
import '../services/native.dart';
import '../services/oidc_flow.dart';
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
final nativeBrowserProvider = Provider<NativeBrowser>((_) => NativeBrowser());
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
    this.tunnel,
  });

  final ConnectionProfile profile;
  final MongoClient client;

  /// The SSH tunnel or SOCKS5 proxy the client runs over.
  final Tunnel? tunnel;

  /// Writes are blocked until the user turns on write mode.
  final bool readOnly;

  Session copyWith({bool? readOnly}) => Session(
    profile: profile,
    client: client,
    readOnly: readOnly ?? this.readOnly,
    tunnel: tunnel,
  );
}

/// Every open connection, in the order they were opened, and the one on
/// screen.
class Sessions {
  const Sessions(this.all, this.activeId);
  final List<Session> all;
  final String? activeId;

  Session? byId(String? id) =>
      all.where((s) => s.profile.id == id).firstOrNull;
  Session? get active => byId(activeId);
}

class SessionsNotifier extends Notifier<Sessions> {
  @override
  Sessions build() => const Sessions([], null);

  OidcBrowserFlow? _oidc;

  /// Opens [profile] (or switches to it when it is already open) and makes
  /// it the active connection.
  Future<void> connect(ConnectionProfile profile) async {
    if (state.byId(profile.id) != null) {
      state = Sessions(state.all, profile.id);
      return;
    }
    final oidc = _oidc = OidcBrowserFlow(
      openUrl: ref.read(nativeBrowserProvider).open,
    );
    final opened = await openConnection(
      ref.read(connectorProvider),
      profile,
      oidc: oidc,
    );
    _oidc = null;
    final session = Session(
      profile: opened.profile,
      client: opened.client,
      tunnel: opened.tunnel,
    );
    state = Sessions([...state.all, session], profile.id);
    final connections = ref.read(connectionsProvider.notifier);
    if (!identical(opened.profile, profile)) {
      // The SSH host key was seen for the first time: remember it.
      await connections.upsert(opened.profile);
    }
    unawaited(connections.markUsed(profile.id));
  }

  /// Stops a browser sign-in that [connect] is waiting for.
  void cancelSignIn() => _oidc?.cancel();

  void activate(String id) {
    if (state.byId(id) != null) state = Sessions(state.all, id);
  }

  void setReadOnly(String id, bool readOnly) {
    state = Sessions([
      for (final s in state.all)
        s.profile.id == id ? s.copyWith(readOnly: readOnly) : s,
    ], state.activeId);
  }

  /// Closes one connection; the next open one becomes active.
  Future<void> disconnect(String id) async {
    final s = state.byId(id);
    if (s == null) return;
    final rest = [
      for (final x in state.all)
        if (x.profile.id != id) x,
    ];
    final i = state.all.indexOf(s);
    state = Sessions(
      rest,
      state.activeId != id
          ? state.activeId
          : rest.isEmpty
          ? null
          : rest[i.clamp(0, rest.length - 1)].profile.id,
    );
    await s.client.close();
    await s.tunnel?.close();
  }

  Future<void> disconnectAll() async {
    for (final s in state.all.toList()) {
      await disconnect(s.profile.id);
    }
  }
}

final sessionsProvider = NotifierProvider<SessionsNotifier, Sessions>(
  SessionsNotifier.new,
);

/// The connection the surrounding workspace shows. Each open connection's
/// workspace overrides it in its own [ProviderScope], so everything below
/// (documents, pipelines, indexes…) belongs to that connection.
final sessionProvider = Provider<Session?>(
  (ref) => ref.watch(sessionsProvider).active,
  dependencies: const [],
);

/// The current client; throws when nothing is connected.
final clientProvider = Provider<MongoClient>((ref) {
  final s = ref.watch(sessionProvider);
  if (s == null) throw StateError('Not connected');
  return s.client;
}, dependencies: [sessionProvider]);

final readOnlyProvider = Provider<bool>(
  (ref) => ref.watch(sessionProvider)?.readOnly ?? true,
  dependencies: [sessionProvider],
);

/// What the workspace body shows, and the collections open as tabs.
class Selection {
  const Selection({this.db, this.collection, this.tabs = const []});
  final String? db;
  final String? collection;

  /// Open collections, oldest first.
  final List<Namespace> tabs;

  Namespace? get namespace =>
      db != null && collection != null ? Namespace(db!, collection!) : null;
}

class SelectionNotifier extends Notifier<Selection> {
  @override
  Selection build() => const Selection();

  static const maxTabs = 8;

  void clear() => state = const Selection();
  void database(String db) => state = Selection(db: db, tabs: state.tabs);

  /// Shows a collection, opening a tab for it (the oldest closes past
  /// [maxTabs]).
  void collection(String db, String coll) {
    final ns = Namespace(db, coll);
    var tabs = state.tabs;
    if (!tabs.contains(ns)) {
      tabs = [...tabs, ns];
      if (tabs.length > maxTabs) tabs = tabs.sublist(tabs.length - maxTabs);
    }
    state = Selection(db: db, collection: coll, tabs: tabs);
  }

  /// Closes a collection's tab; the neighbouring tab (or its database)
  /// shows next.
  void closeTab(Namespace ns) {
    final i = state.tabs.indexOf(ns);
    if (i < 0) return;
    final tabs = [...state.tabs]..removeAt(i);
    if (state.namespace != ns) {
      state = Selection(db: state.db, collection: state.collection, tabs: tabs);
    } else if (tabs.isEmpty) {
      state = Selection(db: ns.db);
    } else {
      final next = tabs[i.clamp(0, tabs.length - 1)];
      state = Selection(db: next.db, collection: next.collection, tabs: tabs);
    }
  }

  /// Renames an open tab after its collection was renamed.
  void renamed(Namespace from, Namespace to) {
    state = Selection(
      db: state.db,
      collection: state.namespace == from ? to.collection : state.collection,
      tabs: [for (final t in state.tabs) t == from ? to : t],
    );
  }

  /// Forgets tabs of a dropped collection or database.
  void dropped({required String db, String? collection}) {
    bool gone(Namespace t) =>
        t.db == db && (collection == null || t.collection == collection);
    final tabs = [
      for (final t in state.tabs)
        if (!gone(t)) t,
    ];
    final current = state.namespace;
    state = current != null && !gone(current)
        ? Selection(db: state.db, collection: state.collection, tabs: tabs)
        : collection == null
        ? Selection(tabs: tabs)
        : Selection(db: db, tabs: tabs);
  }

  /// Moves one level up. Returns false when already at the top.
  bool up() {
    if (state.collection != null) {
      state = Selection(db: state.db, tabs: state.tabs);
      return true;
    }
    if (state.db != null) {
      state = Selection(tabs: state.tabs);
      return true;
    }
    return false;
  }
}

final selectionProvider = NotifierProvider<SelectionNotifier, Selection>(
  SelectionNotifier.new,
  dependencies: const [],
);

final databasesProvider = FutureProvider<List<DatabaseInfo>>((ref) {
  final client = ref.watch(clientProvider);
  return client.listDatabases();
}, dependencies: [clientProvider]);

final collectionsProvider = FutureProvider.family<List<CollectionInfo>, String>(
  (ref, db) {
    final client = ref.watch(clientProvider);
    return client.listCollections(db);
  },
  dependencies: [clientProvider],
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
}, dependencies: [clientProvider]);

final collectionStatsProvider =
    FutureProvider.family<CollectionStats?, Namespace>((ref, ns) {
      final client = ref.watch(clientProvider);
      return ref
          .watch(_statsSemaphoreProvider)
          .run(() => client.collectionStats(ns));
    }, dependencies: [clientProvider, _statsSemaphoreProvider]);

/// Turns any error into a message for the UI.
String describeError(Object error) {
  if (error is MongoException) return error.toString();
  if (error is FormatException) return error.message;
  if (error is StateError) return error.message;
  return error.toString();
}
