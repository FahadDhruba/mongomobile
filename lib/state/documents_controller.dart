import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mongo_wire/mongo_wire.dart';

import '../models/app_settings.dart';
import '../util/format.dart';
import 'providers.dart';

/// The query bar contents, both as typed and parsed.
class QuerySpec {
  const QuerySpec({
    this.filterText = '',
    this.projectText = '',
    this.sortText = '',
    this.limitText = '',
    this.skipText = '',
    this.collationText = '',
    this.hintText = '',
    this.maxTimeText = '',
    this.filter = const {},
    this.projection,
    this.sort,
    this.limit,
    this.skip = 0,
    this.collation,
    this.hint,
    this.maxTime,
  });

  /// Parses the inputs. Throws [FormatException] naming the field.
  factory QuerySpec.parse({
    String filter = '',
    String project = '',
    String sort = '',
    String limit = '',
    String skip = '',
    String collation = '',
    String hint = '',
    String maxTime = '',
  }) {
    Map<String, dynamic> parse(String label, String text) {
      try {
        return EJson.parseDocument(text, allowEmpty: true);
      } on EJsonParseException catch (e) {
        throw FormatException('$label: ${e.message} '
            '(line ${e.line}, column ${e.column})');
      }
    }

    int? whole(String label, String text) {
      if (text.trim().isEmpty) return null;
      final v = int.tryParse(text.trim());
      if (v == null || v < 0) {
        throw FormatException('$label: enter a whole number');
      }
      return v;
    }

    final f = parse('Filter', filter);
    final p = parse('Project', project);
    final s = parse('Sort', sort);
    for (final v in s.values) {
      final ok = v == 1 || v == -1 || v == 1.0 || v == -1.0 || v is Map;
      if (!ok) {
        throw const FormatException(
            'Sort: use 1 for ascending and -1 for descending');
      }
    }
    final c = parse('Collation', collation);
    if (c.isNotEmpty && c['locale'] is! String) {
      throw const FormatException(
          "Collation: needs a locale, e.g. { locale: 'en', strength: 2 }");
    }
    // A hint is an index name or a key pattern.
    Object? h;
    final ht = hint.trim();
    if (ht.isNotEmpty) {
      h = ht.startsWith('{')
          ? parse('Hint', ht)
          : ht.replaceAll(RegExp(r'''^["']|["']$'''), '');
    }
    final l = whole('Limit', limit);
    final mt = whole('Max time', maxTime);
    if (mt == 0) {
      throw const FormatException('Max time: enter milliseconds above 0');
    }
    return QuerySpec(
      filterText: filter,
      projectText: project,
      sortText: sort,
      limitText: limit,
      skipText: skip,
      collationText: collation,
      hintText: hint,
      maxTimeText: maxTime,
      filter: f,
      projection: p.isEmpty ? null : p,
      sort: s.isEmpty ? null : s,
      limit: l == 0 ? null : l,
      skip: whole('Skip', skip) ?? 0,
      collation: c.isEmpty ? null : c,
      hint: h,
      maxTime: mt == null ? null : Duration(milliseconds: mt),
    );
  }

  final String filterText;
  final String projectText;
  final String sortText;
  final String limitText;
  final String skipText;
  final String collationText;
  final String hintText;
  final String maxTimeText;
  final Map<String, dynamic> filter;
  final Map<String, dynamic>? projection;
  final Map<String, dynamic>? sort;
  final int? limit;

  /// Documents to skip before the first page.
  final int skip;
  final Map<String, dynamic>? collation;

  /// An index name or key pattern.
  final Object? hint;

  /// Overrides the query time limit from Settings for this query.
  final Duration? maxTime;

  /// 1 or -1 when the sort is by `_id` alone (or absent), which allows
  /// keyset pagination; null otherwise. A skip or a collation (which can
  /// change how string `_id`s compare) switch to skip/limit paging.
  int? get keysetDirection {
    if (skip > 0 || collation != null) return null;
    final s = sort;
    if (s == null || s.isEmpty) return 1;
    if (s.length != 1 || s.keys.single != '_id') return null;
    final v = s.values.single;
    if (v == 1 || v == 1.0) return 1;
    if (v == -1 || v == -1.0) return -1;
    return null;
  }

  /// True when the projection hides `_id`, which paging and editing need.
  bool get hidesId {
    final v = projection?['_id'];
    return v == 0 || v == false || v == 0.0;
  }

  /// True when any of the inputs behind "Options" is set.
  bool get hasOptions =>
      projection != null ||
      sort != null ||
      limit != null ||
      skip > 0 ||
      collation != null ||
      hint != null ||
      maxTime != null;

  bool get isDefault => filter.isEmpty && !hasOptions;

  /// The typed text of every input that is set, for history and favourites.
  Map<String, String> toTexts() => {
    for (final e in {
      'filter': filterText,
      'project': projectText,
      'sort': sortText,
      'collation': collationText,
      'hint': hintText,
      'skip': skipText,
      'limit': limitText,
      'maxTime': maxTimeText,
    }.entries)
      if (e.value.trim().isNotEmpty) e.key: e.value.trim(),
  };

  factory QuerySpec.fromTexts(Map<String, String> t) => QuerySpec.parse(
    filter: t['filter'] ?? '',
    project: t['project'] ?? '',
    sort: t['sort'] ?? '',
    collation: t['collation'] ?? '',
    hint: t['hint'] ?? '',
    skip: t['skip'] ?? '',
    limit: t['limit'] ?? '',
    maxTime: t['maxTime'] ?? '',
  );
}

enum CountKind { loading, estimated, exact, unavailable }

class CountState {
  const CountState(this.kind, [this.value, this.reason]);
  static const loading = CountState(CountKind.loading);

  final CountKind kind;
  final int? value;
  final String? reason;
}

class DocumentsState {
  const DocumentsState({
    this.query = const QuerySpec(),
    required this.pageSize,
    this.pageIndex = 0,
    this.documents = const [],
    this.ids = const [],
    this.loading = false,
    this.error,
    this.hasNext = false,
    this.truncated = false,
    this.elapsed,
    this.count = CountState.loading,
    this.warning,
    this.loadedOnce = false,
  });

  final QuerySpec query;
  final int pageSize;
  final int pageIndex;

  /// Only the current page is held in memory.
  final List<Map<String, dynamic>> documents;

  /// The `_id` of each document, kept even when the projection hides it,
  /// so edit and delete still work.
  final List<Object?> ids;
  final bool loading;
  final String? error;
  final bool hasNext;

  /// The page was cut short by the size cap.
  final bool truncated;
  final Duration? elapsed;
  final CountState count;

  /// Shown above the results, e.g. for deep skip offsets.
  final String? warning;
  final bool loadedOnce;

  int get offset => pageIndex * pageSize;
  bool get hasPrevious => pageIndex > 0;
  bool get usesKeyset => query.keysetDirection != null;

  DocumentsState copyWith({
    QuerySpec? query,
    int? pageSize,
    int? pageIndex,
    List<Map<String, dynamic>>? documents,
    List<Object?>? ids,
    bool? loading,
    String? error,
    bool clearError = false,
    bool? hasNext,
    bool? truncated,
    Duration? elapsed,
    CountState? count,
    String? warning,
    bool clearWarning = false,
    bool? loadedOnce,
  }) =>
      DocumentsState(
        query: query ?? this.query,
        pageSize: pageSize ?? this.pageSize,
        pageIndex: pageIndex ?? this.pageIndex,
        documents: documents ?? this.documents,
        ids: ids ?? this.ids,
        loading: loading ?? this.loading,
        error: clearError ? null : (error ?? this.error),
        hasNext: hasNext ?? this.hasNext,
        truncated: truncated ?? this.truncated,
        elapsed: elapsed ?? this.elapsed,
        count: count ?? this.count,
        warning: clearWarning ? null : (warning ?? this.warning),
        loadedOnce: loadedOnce ?? this.loadedOnce,
      );
}

/// Skip offsets from here on get a warning, since the server must walk
/// past every skipped document.
const largeSkipThreshold = 10000;

enum _Move { first, next, previous, reload }

/// Pages through one collection.
///
/// Sorting by `_id` (the default) uses keyset pagination: the next page
/// asks for `_id` greater than the last one seen, the previous page for
/// `_id` less than the first one, so deep pages cost the same as the first.
/// Any other sort uses skip and limit.
class DocumentsController extends Notifier<DocumentsState> {
  DocumentsController(this.namespace);

  final Namespace namespace;

  CancelToken? _pageToken;
  CancelToken? _countToken;
  int _generation = 0;

  MongoClient get _client => ref.read(clientProvider);
  AppSettings get _settings => ref.read(settingsProvider);

  @override
  DocumentsState build() {
    ref.onDispose(() {
      _pageToken?.cancel();
      _countToken?.cancel();
    });
    final s = DocumentsState(pageSize: ref.read(settingsProvider).defaultPageSize);
    Future.microtask(() => _load(_Move.first, countToo: true));
    return s;
  }

  /// Runs a new query from the first page.
  Future<void> run(QuerySpec query) {
    state = state.copyWith(query: query, pageIndex: 0);
    return _load(_Move.first, countToo: true);
  }

  Future<void> next() => state.hasNext && !state.loading
      ? _load(_Move.next)
      : Future.value();

  Future<void> previous() => state.hasPrevious && !state.loading
      ? _load(_Move.previous)
      : Future.value();

  Future<void> first() => _load(_Move.first);

  /// Reloads the current page, for instance after an edit.
  Future<void> refresh({bool countToo = true}) =>
      _load(_Move.reload, countToo: countToo);

  Future<void> setPageSize(int size) {
    if (size == state.pageSize) return Future.value();
    state = state.copyWith(pageSize: size, pageIndex: 0);
    return _load(_Move.first);
  }

  void cancel() {
    _pageToken?.cancel();
  }

  Map<String, dynamic> _and(Map<String, dynamic> a, Map<String, dynamic> b) {
    if (a.isEmpty) return b;
    return {
      r'$and': [a, b]
    };
  }

  /// The projection sent to the server: `_id` stays included so paging
  /// works, and is removed again before display.
  Map<String, dynamic>? _serverProjection(QuerySpec q) {
    final p = q.projection;
    if (p == null || !q.hidesId) return p;
    final copy = {...p}..remove('_id');
    return copy.isEmpty ? null : copy;
  }

  Future<void> _load(_Move move, {bool countToo = false}) async {
    final gen = ++_generation;
    _pageToken?.cancel();
    final token = _pageToken = CancelToken();
    final s = state;
    final q = s.query;
    final dir = q.keysetDirection;

    var pageIndex = switch (move) {
      _Move.first => 0,
      _Move.next => s.pageIndex + 1,
      _Move.previous => s.pageIndex - 1,
      _Move.reload => s.pageIndex,
    };

    state = s.copyWith(loading: true, clearError: true);
    if (countToo) _startCount(q);

    // Respect the user's Limit across pages.
    int remainingFor(int index) => q.limit == null
        ? 1 << 30
        : q.limit! - index * s.pageSize;

    var filter = q.filter;
    Map<String, dynamic>? sort = q.sort;
    var skip = 0;
    var reverse = false;
    String? warning;

    if (dir != null) {
      sort = {'_id': dir};
      final ids = s.ids;
      final canAnchor = ids.isNotEmpty && ids.first != null && ids.last != null;
      if (move == _Move.next && canAnchor) {
        filter = _and(q.filter, {
          '_id': {dir == 1 ? r'$gt' : r'$lt': ids.last}
        });
      } else if (move == _Move.previous && canAnchor && pageIndex > 0) {
        filter = _and(q.filter, {
          '_id': {dir == 1 ? r'$lt' : r'$gt': ids.first}
        });
        sort = {'_id': -dir};
        reverse = true;
      } else if (move == _Move.reload && canAnchor && pageIndex > 0) {
        filter = _and(q.filter, {
          '_id': {dir == 1 ? r'$gte' : r'$lte': ids.first}
        });
      } else if (move != _Move.first && pageIndex > 0) {
        // No anchor (empty page); fall back to an offset.
        skip = pageIndex * s.pageSize;
      } else {
        pageIndex = 0;
      }
    } else {
      skip = q.skip + pageIndex * s.pageSize;
      if (skip >= largeSkipThreshold) {
        warning = 'This page skips ${groupDigits(skip)} documents, which the server '
            'has to read and discard. Sort by _id or narrow the filter for '
            'fast deep paging.';
      }
    }

    final remaining = remainingFor(pageIndex);
    // One extra document tells us whether there is a next page.
    final wanted = remaining <= s.pageSize ? remaining : s.pageSize + 1;
    final fetch = reverse ? s.pageSize : wanted;
    if (fetch <= 0) {
      state = state.copyWith(
          loading: false, documents: const [], ids: const [], hasNext: false);
      return;
    }

    try {
      final result = await _client.find(
        namespace,
        FindRequest(
          filter: filter,
          projection: _serverProjection(q),
          sort: sort,
          skip: skip,
          limit: fetch,
          maxTime: q.maxTime ?? _settings.queryTimeout,
          collation: q.collation,
          hint: q.hint,
          maxBytes: _settings.maxPageBytes,
        ),
        cancel: token,
      );
      if (gen != _generation || !ref.mounted) return;
      var docs = result.documents;
      bool hasNext;
      if (reverse) {
        docs = docs.reversed.toList();
        if (docs.length < s.pageSize) {
          // Documents were removed before this page; start over.
          state = state.copyWith(pageIndex: 0);
          await _load(_Move.first);
          return;
        }
        hasNext = true;
      } else {
        hasNext = docs.length > s.pageSize;
        if (hasNext) docs = docs.sublist(0, s.pageSize);
        if (result.truncated) hasNext = true;
      }
      final encryption = ref.read(encryptionProvider);
      var undecrypted = 0;
      if (encryption != null &&
          docs.any((d) => _hasEncrypted(d))) {
        final out = <Map<String, dynamic>>[];
        for (final d in docs) {
          final r = await encryption.decryptDocument(d);
          undecrypted += r.failures.length;
          out.add(r.document);
        }
        if (gen != _generation || !ref.mounted) return;
        docs = out;
      }
      if (undecrypted > 0) {
        warning = [
          ?warning,
          '$undecrypted encrypted value${undecrypted == 1 ? '' : 's'} on '
              'this page could not be decrypted; check the connection\'s '
              'encryption keys.',
        ].join(' ');
      }
      final ids = [for (final d in docs) d['_id']];
      if (q.hidesId) {
        docs = [for (final d in docs) {...d}..remove('_id')];
      }
      var count = state.count;
      if (!hasNext && !result.truncated) {
        // The last page tells us the exact total.
        final total = pageIndex * s.pageSize + docs.length;
        if (count.kind != CountKind.exact || count.value != total) {
          count = CountState(CountKind.exact, total);
        }
      }
      state = state.copyWith(
        pageIndex: pageIndex,
        documents: docs,
        ids: ids,
        loading: false,
        hasNext: hasNext,
        truncated: result.truncated,
        elapsed: result.elapsed,
        count: count,
        warning: warning,
        clearWarning: warning == null,
        loadedOnce: true,
      );
    } on MongoCancelledError {
      if (gen != _generation || !ref.mounted) return;
      state = state.copyWith(
          loading: false, error: 'Query cancelled', loadedOnce: true);
    } on Object catch (e) {
      if (gen != _generation || !ref.mounted) return;
      state = state.copyWith(
          loading: false, error: describeError(e), loadedOnce: true);
    }
  }

  void _startCount(QuerySpec q) {
    _countToken?.cancel();
    final token = _countToken = CancelToken();
    state = state.copyWith(count: CountState.loading);
    final client = _client;
    final settings = _settings;
    Future<CountState> task() async {
      try {
        // The fast metadata count only applies to the whole collection.
        if (q.filter.isEmpty &&
            q.skip == 0 &&
            q.collation == null &&
            q.hint == null) {
          var n = await client.estimatedDocumentCount(namespace,
              maxTime: settings.countTimeout, cancel: token);
          if (q.limit != null && q.limit! < n) n = q.limit!;
          return CountState(CountKind.estimated, n);
        }
        final n = await client.countDocuments(
          namespace,
          q.filter,
          skip: q.skip,
          limit: q.limit,
          collation: q.collation,
          hint: q.hint,
          maxTime: settings.countTimeout,
          cancel: token,
        );
        return CountState(CountKind.exact, n);
      } on MongoServerError catch (e) {
        return CountState(CountKind.unavailable, null,
            e.isMaxTimeExpired ? 'Counting took too long' : e.toString());
      } on MongoCancelledError {
        return const CountState(CountKind.unavailable, null, 'Cancelled');
      } on Object catch (e) {
        return CountState(CountKind.unavailable, null, describeError(e));
      }
    }

    task().then((count) {
      if (token.isCancelled || !ref.mounted) return;
      // A count from the last page is exact; don't replace it.
      if (state.count.kind == CountKind.exact &&
          count.kind != CountKind.exact) {
        return;
      }
      state = state.copyWith(count: count);
    });
  }
}

final documentsProvider = NotifierProvider.autoDispose
    .family<DocumentsController, DocumentsState, Namespace>(
        DocumentsController.new,
        dependencies: [clientProvider, encryptionProvider]);

/// Whether [v] holds a client-side encrypted value anywhere inside.
bool _hasEncrypted(Object? v) => switch (v) {
      Map() => v.values.any(_hasEncrypted),
      List() => v.any(_hasEncrypted),
      _ => isEncryptedValue(v),
    };
