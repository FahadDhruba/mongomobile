import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mongo_wire/mongo_wire.dart';

import '../../services/importer.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../widgets/common.dart';
import '../widgets/document_card.dart';

const _delimiters = {',': 'Comma', ';': 'Semicolon', '\t': 'Tab', '|': 'Pipe'};

/// Imports a JSON (array or one document per line) or CSV file into a
/// collection. Pops with a summary when something was inserted.
class ImportScreen extends ConsumerStatefulWidget {
  const ImportScreen({super.key, required this.namespace});

  final Namespace namespace;

  @override
  ConsumerState<ImportScreen> createState() => _ImportScreenState();
}

enum _Stage { picking, options, running, done }

class _ImportScreenState extends ConsumerState<ImportScreen> {
  _Stage _stage = _Stage.picking;
  ImportSource? _source;
  String _head = '';
  ImportFormat _format = ImportFormat.json;
  String _delimiter = ',';
  bool _ignoreEmpty = true;
  bool _stopOnError = false;
  CsvPreview? _csv;
  List<CsvType> _types = const [];
  List<Map<String, dynamic>>? _json;
  String? _previewError;
  String? _error;
  ImportProgress? _progress;
  ImportResult? _result;
  CancelToken? _cancel;

  @override
  void initState() {
    super.initState();
    Future.microtask(_pick);
  }

  @override
  void dispose() {
    _cancel?.cancel();
    super.dispose();
  }

  Future<void> _pick() async {
    ImportSource? source;
    try {
      source = await ref.read(nativeFilesProvider).open(const [
        'application/json',
        'application/x-ndjson',
        'text/csv',
        'text/comma-separated-values',
        'text/tab-separated-values',
        'text/plain',
        'application/octet-stream',
      ]);
    } on PlatformException catch (e) {
      if (mounted) setState(() => _error = e.message ?? '$e');
      return;
    }
    if (!mounted) return;
    if (source == null) {
      if (_source == null) Navigator.pop(context);
      return;
    }
    String head;
    try {
      head = await readHead(source);
    } on Object catch (e) {
      if (mounted) setState(() => _error = 'Could not read the file: $e');
      return;
    }
    if (!mounted) return;
    setState(() {
      _source = source;
      _head = head;
      _format = detectFormat(source!.name, head);
      _delimiter = source.name.toLowerCase().endsWith('.tsv')
          ? '\t'
          : detectDelimiter(head);
      _stage = _Stage.options;
      _error = null;
    });
    _preview();
  }

  void _preview() {
    setState(() {
      _previewError = null;
      _csv = null;
      _json = null;
      try {
        if (_format == ImportFormat.csv) {
          _csv = previewCsv(_head, _delimiter);
          _types = List.of(_csv!.types);
        } else {
          _json = previewJson(_head);
        }
      } on ImportException catch (e) {
        _previewError = e.message;
      } on EJsonParseException catch (e) {
        _previewError = 'Line ${e.line}, column ${e.column}: ${e.message}';
      } on FormatException catch (e) {
        _previewError = e.message;
      }
    });
  }

  Future<void> _run() async {
    final source = _source!;
    final token = _cancel = CancelToken();
    final csv = _csv;
    setState(() {
      _stage = _Stage.running;
      _progress = null;
      _error = null;
    });
    try {
      final result = await Importer(
        client: ref.read(clientProvider),
        namespace: widget.namespace,
        source: source,
        options: ImportOptions(
          format: _format,
          delimiter: _delimiter,
          types: csv == null
              ? const {}
              : Map.fromIterables(csv.headers, _types),
          ignoreEmpty: _ignoreEmpty,
          stopOnError: _stopOnError,
        ),
        cancel: token,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      ).run();
      if (!mounted) return;
      setState(() {
        _result = result;
        _stage = _Stage.done;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ImportException ? e.message : describeError(e);
        _stage = _Stage.done;
        _result = ImportResult(
          inserted: _progress?.inserted ?? 0,
          failed: _progress?.failed ?? 0,
          errors: const [],
          cancelled: false,
        );
      });
    }
  }

  void _finish() {
    final r = _result;
    Navigator.pop(
      context,
      r == null || r.inserted == 0
          ? null
          : 'Imported ${groupDigits(r.inserted)} document${r.inserted == 1 ? '' : 's'}',
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _stage != _Stage.running,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _stage == _Stage.running) _cancel?.cancel();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('Import into ${widget.namespace.collection}'),
          leading: _stage == _Stage.done
              ? IconButton(
                  tooltip: 'Close',
                  onPressed: _finish,
                  icon: const Icon(Icons.close),
                )
              : null,
        ),
        body: SafeArea(
          child: switch (_stage) {
            _Stage.picking => _picking(context),
            _Stage.options => _options(context),
            _Stage.running => _running(context),
            _Stage.done => _done(context),
          },
        ),
      ),
    );
  }

  Widget _picking(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_error case final error?) ...[
            MessageBanner(message: error),
            const SizedBox(height: 16),
          ],
          AccentButton(
            label: 'Choose a file',
            icon: Icons.upload_file,
            onPressed: _pick,
          ),
        ],
      ),
    ),
  );

  Widget _options(BuildContext context) {
    final c = context.colors;
    final source = _source!;
    final preview = ref.watch(settingsProvider).stringPreviewLength;
    final csv = _csv;
    final json = _json;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Row(
                children: [
                  Icon(Icons.description_outlined, color: c.muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      source.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text(
                    source.size == null ? '' : formatBytes(source.size),
                    style: TextStyle(color: c.muted, fontSize: 12.5),
                  ),
                  TextButton(onPressed: _pick, child: const Text('Change')),
                ],
              ),
              const SizedBox(height: 8),
              SegmentedButton<ImportFormat>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: ImportFormat.json, label: Text('JSON')),
                  ButtonSegment(value: ImportFormat.csv, label: Text('CSV')),
                ],
                selected: {_format},
                onSelectionChanged: (s) {
                  _format = s.first;
                  _preview();
                },
              ),
              const SizedBox(height: 4),
              Text(
                _format == ImportFormat.json
                    ? 'An array of documents, or one document per line. '
                          'Extended JSON and shell syntax are both read.'
                    : 'The first row names the fields; a.b and a[0] build '
                          'nested documents and arrays.',
                style: TextStyle(color: c.muted, fontSize: 12),
              ),
              if (_format == ImportFormat.csv) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Text('Delimiter'),
                    const Spacer(),
                    DropdownButton<String>(
                      value: _delimiter,
                      underline: const SizedBox(),
                      items: [
                        for (final MapEntry(:key, :value)
                            in _delimiters.entries)
                          DropdownMenuItem(value: key, child: Text(value)),
                      ],
                      onChanged: (v) {
                        _delimiter = v!;
                        _preview();
                      },
                    ),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Leave out empty cells'),
                  value: _ignoreEmpty,
                  onChanged: (v) => setState(() => _ignoreEmpty = v),
                ),
              ],
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Stop on the first error'),
                subtitle: const Text('Otherwise bad documents are skipped'),
                value: _stopOnError,
                onChanged: (v) => setState(() => _stopOnError = v),
              ),
              const SizedBox(height: 8),
              if (_previewError case final error?)
                MessageBanner(message: error)
              else if (csv != null) ...[
                const Text(
                  'Fields and types',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                for (var i = 0; i < csv.headers.length; i++)
                  _ColumnRow(
                    name: csv.headers[i],
                    samples: [
                      for (final r in csv.rows.take(3))
                        if (i < r.length) r[i],
                    ],
                    type: _types[i],
                    onType: (t) => setState(() => _types[i] = t),
                  ),
              ] else if (json != null) ...[
                Text(
                  json.isEmpty
                      ? 'No documents found at the start of the file'
                      : 'The first ${json.length}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                for (final d in json) ...[
                  DocumentCard(document: d, previewLength: preview),
                  const SizedBox(height: 8),
                ],
              ],
            ],
          ),
        ),
        _bar(context, [
          const Spacer(),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          const SizedBox(width: 4),
          AccentButton(
            label: 'Import',
            compact: true,
            onPressed: _previewError == null ? _run : null,
          ),
        ]),
      ],
    );
  }

  Widget _running(BuildContext context) {
    final c = context.colors;
    final p = _progress;
    final fraction = p == null ? null : progressOf(p.bytesRead, _source?.size);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Importing ${_source?.name ?? ''}…',
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 16),
          LinearProgressIndicator(
            value: fraction,
            color: c.accent,
            backgroundColor: c.border,
          ),
          const SizedBox(height: 12),
          Text(
            p == null
                ? 'Starting…'
                : '${groupDigits(p.inserted)} inserted'
                      '${p.failed > 0 ? ' · ${groupDigits(p.failed)} failed' : ''}'
                      ' · ${formatBytes(p.bytesRead)} read',
            textAlign: TextAlign.center,
            style: TextStyle(color: c.muted),
          ),
          const SizedBox(height: 16),
          Center(
            child: TextButton(
              onPressed: () => _cancel?.cancel(),
              child: Text('Cancel', style: TextStyle(color: c.danger)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _done(BuildContext context) {
    final c = context.colors;
    final r = _result!;
    final headline = r.cancelled
        ? 'Import cancelled'
        : _error != null
        ? 'Import stopped'
        : r.failed > 0
        ? 'Import finished with errors'
        : 'Import finished';
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                headline,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${groupDigits(r.inserted)} document${r.inserted == 1 ? '' : 's'} inserted'
                '${r.failed > 0 ? ', ${groupDigits(r.failed)} failed' : ''}.',
              ),
              if (_error case final error?) ...[
                const SizedBox(height: 12),
                MessageBanner(message: error),
              ],
              if (r.errors.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  r.failed > r.errors.length
                      ? 'The first ${r.errors.length} errors'
                      : 'Errors',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                for (final e in r.errors)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: SelectableText(
                      e,
                      style: monoStyle(context, size: 12, color: c.danger),
                    ),
                  ),
              ],
            ],
          ),
        ),
        _bar(context, [
          const Spacer(),
          AccentButton(label: 'Done', compact: true, onPressed: _finish),
        ]),
      ],
    );
  }

  Widget _bar(BuildContext context, List<Widget> children) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 12),
      decoration: BoxDecoration(
        color: c.panel,
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: Row(children: children),
    );
  }
}

class _ColumnRow extends StatelessWidget {
  const _ColumnRow({
    required this.name,
    required this.samples,
    required this.type,
    required this.onType,
  });

  final String name;
  final List<String> samples;
  final CsvType type;
  final ValueChanged<CsvType> onType;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final ignored = type == CsvType.ignore;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  overflow: TextOverflow.ellipsis,
                  style:
                      monoStyle(
                        context,
                        size: 13,
                        color: ignored ? c.muted : c.key,
                        weight: FontWeight.w700,
                      ).copyWith(
                        decoration: ignored ? TextDecoration.lineThrough : null,
                      ),
                ),
                Text(
                  samples.where((s) => s.isNotEmpty).join(', '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.muted, fontSize: 12),
                ),
              ],
            ),
          ),
          PopupMenuButton<CsvType>(
            tooltip: 'Type of $name',
            initialValue: type,
            onSelected: onType,
            itemBuilder: (_) => [
              for (final t in CsvType.values)
                PopupMenuItem(value: t, height: 38, child: Text(t.label)),
            ],
            child: Container(
              padding: const EdgeInsets.fromLTRB(8, 5, 4, 5),
              decoration: BoxDecoration(
                border: Border.all(color: c.border),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    type.label,
                    style: TextStyle(fontSize: 12, color: c.muted),
                  ),
                  Icon(Icons.arrow_drop_down, size: 16, color: c.muted),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
