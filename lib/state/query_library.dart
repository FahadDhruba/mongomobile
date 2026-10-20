import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mongo_wire/mongo_wire.dart';

import '../services/query_library.dart';
import 'providers.dart';

final queryLibraryStoreProvider = Provider<QueryLibraryStore>(
  (_) => QueryLibraryStore(),
);

/// Recent queries kept per collection.
const maxRecentQueries = 30;
const maxSavedPerCollection = 100;

/// History, favourites and saved pipelines for every collection, keyed by
/// connection and namespace so the same collection name on two servers
/// doesn't mix.
class QueryLibraryNotifier extends AsyncNotifier<Map<String, CollectionLibrary>> {
  @override
  Future<Map<String, CollectionLibrary>> build() =>
      ref.read(queryLibraryStoreProvider).load();

  String _key(Namespace ns) {
    final id = ref.read(sessionProvider)?.profile.id ?? '-';
    return '$id/$ns';
  }

  CollectionLibrary of(Namespace ns) =>
      state.value?[_key(ns)] ?? const CollectionLibrary();

  Future<void> _update(
    Namespace ns,
    CollectionLibrary Function(CollectionLibrary lib) change,
  ) async {
    // Wait for the stored library first, or a late load would wipe this
    // change.
    final all = {...await future};
    final key = _key(ns);
    all[key] = change(all[key] ?? const CollectionLibrary());
    state = AsyncData(all);
    await ref.read(queryLibraryStoreProvider).save(all);
  }

  /// Puts [texts] at the top of the recent list, without duplicates.
  Future<void> addRecent(Namespace ns, Map<String, String> texts) {
    if (texts.isEmpty) return Future.value();
    return _update(ns, (lib) {
      final recent = [
        SavedQuery(texts: texts, at: DateTime.now()),
        ...lib.recent.where((q) => !q.sameTexts(texts)),
      ];
      return lib.copyWith(recent: recent.take(maxRecentQueries).toList());
    });
  }

  Future<void> removeRecent(Namespace ns, SavedQuery q) => _update(
    ns,
    (lib) => lib.copyWith(recent: [...lib.recent]..remove(q)),
  );

  Future<void> clearRecent(Namespace ns) =>
      _update(ns, (lib) => lib.copyWith(recent: const []));

  Future<void> addFavorite(
    Namespace ns,
    String name,
    Map<String, String> texts,
  ) => _update(ns, (lib) {
    final favorites = [
      SavedQuery(texts: texts, at: DateTime.now(), name: name),
      ...lib.favorites.where((q) => q.name != name),
    ];
    return lib.copyWith(
      favorites: favorites.take(maxSavedPerCollection).toList(),
    );
  });

  Future<void> removeFavorite(Namespace ns, SavedQuery q) => _update(
    ns,
    (lib) => lib.copyWith(favorites: [...lib.favorites]..remove(q)),
  );

  Future<void> savePipeline(Namespace ns, String name, String pipeline) =>
      _update(ns, (lib) {
        final pipelines = [
          SavedQuery(
            texts: {'pipeline': pipeline},
            at: DateTime.now(),
            name: name,
          ),
          ...lib.pipelines.where((q) => q.name != name),
        ];
        return lib.copyWith(
          pipelines: pipelines.take(maxSavedPerCollection).toList(),
        );
      });

  Future<void> removePipeline(Namespace ns, SavedQuery q) => _update(
    ns,
    (lib) => lib.copyWith(pipelines: [...lib.pipelines]..remove(q)),
  );
}

final queryLibraryProvider =
    AsyncNotifierProvider<
      QueryLibraryNotifier,
      Map<String, CollectionLibrary>
    >(QueryLibraryNotifier.new);
