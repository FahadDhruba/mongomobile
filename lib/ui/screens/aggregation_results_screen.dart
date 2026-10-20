import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mongo_wire/mongo_wire.dart';

import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../widgets/common.dart';
import '../widgets/document_card.dart';

/// Runs a pipeline and pages through its output (20 at a time, by
/// appending $skip and $limit).
class AggregationResultsScreen extends ConsumerStatefulWidget {
  const AggregationResultsScreen({
    super.key,
    required this.namespace,
    required this.pipeline,
    this.collation,
  });

  final Namespace namespace;
  final List<Map<String, dynamic>> pipeline;
  final Map<String, dynamic>? collation;

  @override
  ConsumerState<AggregationResultsScreen> createState() =>
      _AggregationResultsScreenState();
}

class _AggregationResultsScreenState
    extends ConsumerState<AggregationResultsScreen> {
  static const pageSize = 20;
  int _page = 0;
  FindResult? _result;
  bool _hasNext = false;
  bool _loading = false;
  bool _json = false;
  String? _error;
  CancelToken? _cancel;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _cancel?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    _cancel?.cancel();
    final token = _cancel = CancelToken();
    setState(() {
      _loading = true;
      _error = null;
    });
    final settings = ref.read(settingsProvider);
    try {
      final r = await ref
          .read(clientProvider)
          .aggregate(
            widget.namespace,
            [
              ...widget.pipeline,
              if (_page > 0) {r'$skip': _page * pageSize},
              {r'$limit': pageSize + 1},
            ],
            limit: pageSize + 1,
            collation: widget.collation,
            maxTime: settings.queryTimeout,
            maxBytes: settings.maxPageBytes,
            cancel: token,
          );
      if (!mounted || token.isCancelled) return;
      setState(() {
        _hasNext = r.documents.length > pageSize || r.truncated;
        _result = FindResult(
          r.documents.take(pageSize).toList(),
          byteLength: r.byteLength,
          truncated: r.truncated,
          elapsed: r.elapsed,
        );
        _loading = false;
      });
    } on MongoCancelledError {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Cancelled';
        });
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = describeError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final docs = _result?.documents ?? const [];
    final preview = ref.watch(settingsProvider).stringPreviewLength;
    final from = _page * pageSize;
    return Scaffold(
      appBar: AppBar(
        title: Text('Results · ${widget.namespace.collection}'),
        actions: [
          IconButton(
            tooltip: _json ? 'List view' : 'JSON view',
            onPressed: () => setState(() => _json = !_json),
            icon: Icon(_json ? Icons.view_agenda_outlined : Icons.data_object),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            color: c.panel,
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    docs.isEmpty
                        ? (_loading ? 'Running…' : 'No results')
                        : '${groupDigits(from + 1)} – ${groupDigits(from + docs.length)}'
                              '${_result == null ? '' : ' · ${formatDuration(_result!.elapsed)}'}',
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                ),
                if (_loading)
                  TextButton(
                    onPressed: () => _cancel?.cancel(),
                    child: Text('Cancel', style: TextStyle(color: c.danger)),
                  ),
                IconButton(
                  tooltip: 'Previous page',
                  onPressed: _page > 0 && !_loading
                      ? () {
                          _page--;
                          _load();
                        }
                      : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                IconButton(
                  tooltip: 'Next page',
                  onPressed: _hasNext && !_loading
                      ? () {
                          _page++;
                          _load();
                        }
                      : null,
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ),
          if (_loading)
            LinearProgressIndicator(
              minHeight: 2,
              color: c.accent,
              backgroundColor: c.border,
            ),
          Expanded(
            child: _error != null
                ? ListView(
                    padding: const EdgeInsets.all(12),
                    children: [
                      MessageBanner(
                        message: _error!,
                        action: TextButton(
                          onPressed: _load,
                          child: const Text('Retry'),
                        ),
                      ),
                    ],
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: docs.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, i) => _json
                        ? JsonDocumentCard(document: docs[i])
                        : DocumentCard(document: docs[i], previewLength: preview),
                  ),
          ),
        ],
      ),
    );
  }
}
