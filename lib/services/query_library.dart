import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A query as typed into the query bar (input name → text), or a pipeline.
class SavedQuery {
  const SavedQuery({required this.texts, required this.at, this.name});

  final Map<String, String> texts;
  final DateTime at;

  /// Set for favourites.
  final String? name;

  Map<String, dynamic> toJson() => {
    't': texts,
    'at': at.toIso8601String(),
    if (name != null) 'name': name,
  };

  factory SavedQuery.fromJson(Map<String, dynamic> j) => SavedQuery(
    texts: (j['t'] as Map).map((k, v) => MapEntry('$k', '$v')),
    at: DateTime.tryParse('${j['at']}') ?? DateTime.now(),
    name: j['name'] as String?,
  );

  bool sameTexts(Map<String, String> other) {
    if (other.length != texts.length) return false;
    for (final e in texts.entries) {
      if (other[e.key] != e.value) return false;
    }
    return true;
  }
}

/// Recent queries, favourites and saved pipelines of one collection.
class CollectionLibrary {
  const CollectionLibrary({
    this.recent = const [],
    this.favorites = const [],
    this.pipelines = const [],
  });

  final List<SavedQuery> recent;
  final List<SavedQuery> favorites;

  /// Saved aggregation pipelines; `texts['pipeline']` holds the stages.
  final List<SavedQuery> pipelines;

  CollectionLibrary copyWith({
    List<SavedQuery>? recent,
    List<SavedQuery>? favorites,
    List<SavedQuery>? pipelines,
  }) => CollectionLibrary(
    recent: recent ?? this.recent,
    favorites: favorites ?? this.favorites,
    pipelines: pipelines ?? this.pipelines,
  );

  bool get isEmpty => recent.isEmpty && favorites.isEmpty && pipelines.isEmpty;

  Map<String, dynamic> toJson() => {
    if (recent.isNotEmpty) 'recent': recent.map((q) => q.toJson()).toList(),
    if (favorites.isNotEmpty)
      'favorites': favorites.map((q) => q.toJson()).toList(),
    if (pipelines.isNotEmpty)
      'pipelines': pipelines.map((q) => q.toJson()).toList(),
  };

  static List<SavedQuery> _list(Object? v) => [
    for (final e in (v as List? ?? const []))
      SavedQuery.fromJson(e as Map<String, dynamic>),
  ];

  factory CollectionLibrary.fromJson(Map<String, dynamic> j) =>
      CollectionLibrary(
        recent: _list(j['recent']),
        favorites: _list(j['favorites']),
        pipelines: _list(j['pipelines']),
      );
}

/// Stores every collection's library in secure storage, since queries can
/// contain the same sensitive values as the data.
class QueryLibraryStore {
  QueryLibraryStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'queries.v1';
  final FlutterSecureStorage _storage;

  Future<Map<String, CollectionLibrary>> load() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null || raw.isEmpty) return {};
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return json.map(
        (k, v) =>
            MapEntry(k, CollectionLibrary.fromJson(v as Map<String, dynamic>)),
      );
    } on Object {
      return {};
    }
  }

  Future<void> save(Map<String, CollectionLibrary> all) => _storage.write(
    key: _key,
    value: jsonEncode({
      for (final e in all.entries)
        if (!e.value.isEmpty) e.key: e.value.toJson(),
    }),
  );
}
