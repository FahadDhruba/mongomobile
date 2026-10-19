import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mongo_wire/mongo_wire.dart';

import '../../services/exporter.dart';
import '../../state/documents_controller.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../widgets/common.dart';

/// Opens the export sheet for [namespace]. With [fullCollection] the
/// "Full collection" scope is preselected.
Future<void> showExportSheet(
  BuildContext context,
  Namespace namespace, {
  QuerySpec? query,
  bool fullCollection = false,
}) async {
  final count = await showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    isDismissible: false,
    builder: (_) => ExportSheet(
      namespace: namespace,
      query: query ?? const QuerySpec(),
      fullCollection: fullCollection,
    ),
  );
  if (count != null && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Exported ${groupDigits(count)} '
          '${count == 1 ? 'document' : 'documents'}',
        ),
      ),
    );
  }
}

/// Compass-style export: current query or whole collection, as Extended
/// JSON or CSV, saved wherever the user picks.
class ExportSheet extends ConsumerStatefulWidget {
  const ExportSheet({
    super.key,
    required this.namespace,
    required this.query,
    this.fullCollection = false,
  });

  final Namespace namespace;
  final QuerySpec query;
  final bool fullCollection;

  @override
  ConsumerState<ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends ConsumerState<ExportSheet> {
  late bool _full = widget.fullCollection || widget.query.isDefault;
  ExportFormat _format = ExportFormat.json;
  EJsonMode _mode = EJsonMode.relaxed;
  CancelToken? _cancel;
  ExportProgress? _progress;
  int? _total;
  String? _error;

  bool get _running => _cancel != null;

  @override
  void initState() {
    super.initState();
    _loadTotal();
  }

  Future<void> _loadTotal() async {
    final client = ref.read(clientProvider);
    final timeout = ref.read(settingsProvider).countTimeout;
    try {
      final n = _full
          ? await client.estimatedDocumentCount(
              widget.namespace,
              maxTime: timeout,
            )
          : await client.countDocuments(
              widget.namespace,
              widget.query.filter,
              limit: widget.query.limit,
              maxTime: timeout,
            );
      if (mounted) setState(() => _total = n);
    } on Object {
      if (mounted) setState(() => _total = null);
    }
  }

  ExportOptions get _options => ExportOptions(
    format: _format,
    jsonMode: _mode,
    filter: _full ? const {} : widget.query.filter,
    projection: _full ? null : widget.query.projection,
    sort: _full ? null : widget.query.sort,
    limit: _full ? 0 : (widget.query.limit ?? 0),
  );

  Future<void> _export() async {
    final options = _options;
    final name =
        '${widget.namespace.db}.${widget.namespace.collection}'
        '.${options.extension}';
    setState(() => _error = null);
    final ExportSink? sink;
    try {
      sink = await ref.read(nativeFilesProvider).create(name, options.mimeType);
    } on PlatformException catch (e) {
      setState(() => _error = 'Could not open the save dialog: ${e.message}');
      return;
    }
    if (sink == null || !mounted) return;
    final token = CancelToken();
    setState(() {
      _cancel = token;
      _progress = const ExportProgress(ExportPhase.writing, 0);
    });
    try {
      final n = await Exporter(
        client: ref.read(clientProvider),
        namespace: widget.namespace,
        options: options,
        sink: sink,
        cancel: token,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      ).run();
      if (mounted) Navigator.pop(context, n);
    } on MongoCancelledError {
      if (mounted) {
        setState(() {
          _cancel = null;
          _progress = null;
          _error = 'Export cancelled; the partial file was removed.';
        });
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _cancel = null;
          _progress = null;
          _error = e is PlatformException
              ? 'Writing the file failed: ${e.message}'
              : describeError(e);
        });
      }
    }
  }

  String _progressText(ExportProgress p) {
    final total = _total;
    final of = total == null
        ? ''
        : ' of ${_full ? '~' : ''}${groupDigits(total)}';
    return switch (p.phase) {
      ExportPhase.scanning =>
        'Finding CSV columns: ${groupDigits(p.documents)}$of documents',
      ExportPhase.writing =>
        'Exported ${groupDigits(p.documents)}$of documents',
    };
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final q = widget.query;
    final p = _progress;
    final total = _total;
    double? fraction;
    if (p != null && total != null && total > 0) {
      final passes = _format == ExportFormat.csv ? 2 : 1;
      final done = p.phase == ExportPhase.scanning
          ? p.documents
          : (passes - 1) * total + p.documents;
      fraction = (done / (passes * total)).clamp(0.0, 1.0);
    }

    final querySummary = [
      if (q.filter.isNotEmpty) 'filter ${q.filterText.trim()}',
      if (q.projection != null) 'project ${q.projectText.trim()}',
      if (q.sort != null) 'sort ${q.sortText.trim()}',
      if (q.limit != null) 'limit ${q.limit}',
    ].join('  ·  ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Export ${widget.namespace}',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          Text('Documents', style: TextStyle(color: c.muted, fontSize: 12.5)),
          RadioGroup<bool>(
            groupValue: _full,
            onChanged: (v) {
              if (_running || v == null) return;
              setState(() {
                _full = v;
                _total = null;
              });
              _loadTotal();
            },
            child: Column(
              children: [
                RadioListTile<bool>(
                  contentPadding: EdgeInsets.zero,
                  value: false,
                  enabled: !q.isDefault && !_running,
                  title: const Text('Current query'),
                  subtitle: Text(
                    q.isDefault
                        ? 'No filter, projection or sort set'
                        : querySummary,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: monoStyle(context, size: 11.5, color: c.muted),
                  ),
                ),
                RadioListTile<bool>(
                  contentPadding: EdgeInsets.zero,
                  value: true,
                  enabled: !_running,
                  title: const Text('Full collection'),
                ),
              ],
            ),
          ),
          if (total != null)
            Text(
              '${_full ? '~' : ''}${groupDigits(total)} documents',
              style: TextStyle(color: c.muted, fontSize: 12.5),
            ),
          const SizedBox(height: 12),
          Text('Format', style: TextStyle(color: c.muted, fontSize: 12.5)),
          const SizedBox(height: 6),
          SegmentedButton<ExportFormat>(
            style: SegmentedButton.styleFrom(
              selectedBackgroundColor: c.accentStrong,
              selectedForegroundColor: Colors.white,
            ),
            segments: const [
              ButtonSegment(value: ExportFormat.json, label: Text('JSON')),
              ButtonSegment(value: ExportFormat.csv, label: Text('CSV')),
            ],
            selected: {_format},
            onSelectionChanged: _running
                ? null
                : (v) => setState(() => _format = v.first),
          ),
          const SizedBox(height: 8),
          if (_format == ExportFormat.json)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Canonical Extended JSON'),
              subtitle: const Text(
                'Keeps every type (Int32, Int64, Double) explicit. Off writes '
                'relaxed Extended JSON, which is easier to read.',
              ),
              value: _mode == EJsonMode.canonical,
              onChanged: _running
                  ? null
                  : (v) => setState(
                      () => _mode = v ? EJsonMode.canonical : EJsonMode.relaxed,
                    ),
            )
          else
            Text(
              'Nested fields become columns like address.city and items[0].sku. '
              'CSV reads the documents twice to find every column.',
              style: TextStyle(color: c.muted, fontSize: 12.5),
            ),
          if (p != null) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: fraction,
              color: c.accent,
              backgroundColor: c.border,
            ),
            const SizedBox(height: 6),
            Text(
              _progressText(p),
              style: TextStyle(color: c.text, fontSize: 13),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            MessageBanner(message: _error!),
          ],
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (_running)
                TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: c.danger),
                  onPressed: () => _cancel?.cancel(),
                  icon: const Icon(Icons.stop_circle_outlined, size: 18),
                  label: const Text('Cancel export'),
                )
              else ...[
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close'),
                ),
                const SizedBox(width: 8),
                AccentButton(
                  label: 'Export…',
                  icon: Icons.file_download_outlined,
                  onPressed: _export,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
