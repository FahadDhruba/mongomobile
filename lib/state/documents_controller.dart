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
    this.filter = const {},
    this.projection,
    this.sort,
    this.limit,
  });

  /// Parses the four inputs. Throws [FormatException] naming the field.
  factory QuerySpec.parse({
    String filter = '',
    String project = '',
    String sort = '',
    String limit = '',
  }) {
    Map<String, dynamic> parse(String label, String text) {
      try {
        return EJson.parseDocument(text, allowEmpty: true);
      } on EJsonParseException catch (e) {
        throw FormatException('$label: ${e.message} '
            '(line ${e.line}, column ${e.column})');
      }
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
    int? l;
    if (limit.trim().isNotEmpty) {
      l = int.tryParse(limit.trim());
      if (l == null || l < 0) {
        throw const FormatException('Limit: enter a whole number');
      }
      if (l == 0) l = null;
    }
    return QuerySpec(
      filterText: filter,
      projectText: project,
      sortText: sort,
      limitText: limit,
      filter: f,
      projection: p.isEmpty ? null : p,
      sort: s.isEmpty ? null : s,
      limit: l,
    );
  }

  final String filterText;
  final String projectText;
  final String sortText;
  final String limitText;
  final Map<String, dynamic> filter;
  final Map<String, dynamic>? projection;
  final Map<String, dynamic>? sort;
  final int? limit;

  /// 1 or -1 when the sort is by `_id` alone (or absent), which allows
  /// keyset pagination; null otherwise.
  int? get keysetDirection {
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

  bool get isDefault =>
      filter.isEmpty && projection == null && sort == null && limit == null;
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
      skip = pageIndex * s.pageSize;
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
          maxTime: _settings.queryTimeout,
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
        if (q.filter.isEmpty) {
          var n = await client.estimatedDocumentCount(namespace,
              maxTime: settings.countTimeout, cancel: token);
          if (q.limit != null && q.limit! < n) n = q.limit!;
          return CountState(CountKind.estimated, n);
        }
        final n = await client.countDocuments(namespace, q.filter,
            limit: q.limit, maxTime: settings.countTimeout, cancel: token);
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
        DocumentsController.new);
