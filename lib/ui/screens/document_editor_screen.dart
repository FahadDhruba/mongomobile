import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mongo_wire/mongo_wire.dart';

import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/json_highlight.dart';

enum EditorMode { insert, edit, clone }

/// Edits a document as Extended JSON (shell syntax is accepted too) and
/// validates it while typing.
class DocumentEditorScreen extends ConsumerStatefulWidget {
  const DocumentEditorScreen({
    super.key,
    required this.mode,
    required this.namespace,
    required this.initialText,
    this.originalId,
  });

  final EditorMode mode;
  final Namespace namespace;
  final String initialText;

  /// The `_id` of the document being edited.
  final Object? originalId;

  @override
  ConsumerState<DocumentEditorScreen> createState() =>
      _DocumentEditorScreenState();
}

class _DocumentEditorScreenState extends ConsumerState<DocumentEditorScreen> {
  late final _controller = JsonEditingController(text: widget.initialText);
  Timer? _debounce;
  String? _parseError;
  String? _submitError;
  bool _saving = false;
  int _documentCount = 1;

  @override
  void initState() {
    super.initState();
    _validate();
    _controller.addListener(() {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 350), _validate);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>>? _parse() {
    try {
      final docs = widget.mode == EditorMode.insert
          ? EJsonParser.parseDocuments(_controller.text)
          : [EJson.parseDocument(_controller.text)];
      _parseError = null;
      _documentCount = docs.length;
      return docs;
    } on EJsonParseException catch (e) {
      _parseError = 'Line ${e.line}, column ${e.column}: ${e.message}';
    } on FormatException catch (e) {
      _parseError = e.message;
    }
    return null;
  }

  void _validate() {
    if (!mounted) return;
    setState(() => _parse());
  }

  void _format() {
    final docs = _parse();
    if (docs == null) {
      setState(() {});
      return;
    }
    _controller.text =
        EJson.stringify(docs.length == 1 ? docs.single : docs);
  }

  bool _sameId(Object? a, Object? b) {
    try {
      return Bson.encode({'v': a}).toString() == Bson.encode({'v': b}).toString();
    } on BsonException {
      return false;
    }
  }

  Future<void> _submit() async {
    final docs = _parse();
    if (docs == null) {
      setState(() {});
      return;
    }
    final client = ref.read(clientProvider);
    setState(() {
      _saving = true;
      _submitError = null;
    });
    try {
      switch (widget.mode) {
        case EditorMode.insert:
        case EditorMode.clone:
          for (final d in docs) {
            await client.insertOne(widget.namespace, d);
          }
        case EditorMode.edit:
          var doc = docs.single;
          if (!doc.containsKey('_id')) {
            doc = {'_id': widget.originalId, ...doc};
          } else if (!_sameId(doc['_id'], widget.originalId)) {
            throw const FormatException(
                'The _id of a document cannot be changed. Use Clone to make a '
                'copy with a new _id.');
          }
          final r = await client.replaceOne(
              widget.namespace, {'_id': widget.originalId}, doc);
          if (r.matched == 0) {
            throw const FormatException(
                'The document no longer exists; it may have been deleted.');
          }
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _submitError = describeError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final title = switch (widget.mode) {
      EditorMode.insert => 'Insert Document',
      EditorMode.edit => 'Edit Document',
      EditorMode.clone => 'Clone Document',
    };
    final action = switch (widget.mode) {
      EditorMode.insert || EditorMode.clone =>
        _documentCount > 1 ? 'Insert $_documentCount' : 'Insert',
      EditorMode.edit => 'Update',
    };
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            tooltip: 'Format',
            onPressed: _format,
            icon: const Icon(Icons.format_align_left),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Text(
                '${widget.namespace}  ·  Extended JSON or shell syntax, e.g. '
                "ObjectId('…'), ISODate('…'), NumberLong(1)"
                '${widget.mode == EditorMode.insert ? '. An array inserts several documents.' : ''}',
                style: TextStyle(color: c.muted, fontSize: 12),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: TextField(
                  controller: _controller,
                  expands: true,
                  maxLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  keyboardType: TextInputType.multiline,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: monoStyle(context, size: 13),
                  decoration: InputDecoration(
                    fillColor: c.card,
                    errorText: null,
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(
                          color: _parseError != null ? c.danger : c.border),
                    ),
                  ),
                ),
              ),
            ),
            if (_submitError != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: MessageBanner(message: _submitError!),
              ),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 8, 12, 12),
              decoration: BoxDecoration(
                color: c.panel,
                border: Border(top: BorderSide(color: c.border)),
              ),
              child: Row(
                children: [
                  Icon(
                    _parseError == null
                        ? Icons.check_circle_outline
                        : Icons.error_outline,
                    size: 18,
                    color: _parseError == null ? c.accent : c.danger,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _parseError ?? 'Valid document',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12.5,
                          color: _parseError == null ? c.muted : c.danger),
                    ),
                  ),
                  TextButton(
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 4),
                  AccentButton(
                    label: _saving ? 'Saving…' : action,
                    compact: true,
                    onPressed:
                        _saving || _parseError != null ? null : _submit,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
