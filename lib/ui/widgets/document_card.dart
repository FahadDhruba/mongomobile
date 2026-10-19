import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mongo_wire/mongo_wire.dart';

import '../../theme/app_theme.dart';
import 'bson_value.dart';

/// Actions offered on a document. Null callbacks hide the button.
class DocumentActions {
  const DocumentActions({this.onEdit, this.onClone, this.onDelete});
  final VoidCallback? onEdit;
  final VoidCallback? onClone;
  final VoidCallback? onDelete;
}

/// A document as Compass shows it: `field: value` lines in monospace,
/// with nested objects and arrays that expand in place.
class DocumentCard extends StatelessWidget {
  const DocumentCard({
    super.key,
    required this.document,
    required this.previewLength,
    this.actions = const DocumentActions(),
  });

  final Map<String, dynamic> document;
  final int previewLength;
  final DocumentActions actions;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ActionRow(document: document, actions: actions),
            FieldList(
              entries: document.entries.toList(),
              previewLength: previewLength,
              initialCount: 25,
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.document, required this.actions});
  final Map<String, dynamic> document;
  final DocumentActions actions;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget button(IconData icon, String tip, VoidCallback? onTap,
            {Color? color}) =>
        IconButton(
          tooltip: tip,
          visualDensity: VisualDensity.compact,
          iconSize: 19,
          color: color ?? c.muted,
          onPressed: onTap,
          icon: Icon(icon),
        );
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        button(Icons.content_copy_outlined, 'Copy as JSON', () {
          Clipboard.setData(ClipboardData(text: EJson.stringify(document)));
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Document copied as Extended JSON')));
        }),
        if (actions.onClone != null)
          button(Icons.control_point_duplicate, 'Clone', actions.onClone),
        if (actions.onEdit != null)
          button(Icons.edit_outlined, 'Edit', actions.onEdit),
        if (actions.onDelete != null)
          button(Icons.delete_outline, 'Delete', actions.onDelete,
              color: c.danger),
      ],
    );
  }
}

/// A list of fields that shows the first [initialCount] and offers to show
/// more, so huge documents and arrays stay cheap to render.
class FieldList extends StatefulWidget {
  const FieldList({
    super.key,
    required this.entries,
    required this.previewLength,
    this.initialCount = 50,
    this.isArray = false,
  });

  final List<MapEntry<String, dynamic>> entries;
  final int previewLength;
  final int initialCount;
  final bool isArray;

  @override
  State<FieldList> createState() => _FieldListState();
}

class _FieldListState extends State<FieldList> {
  late int _visible = widget.initialCount;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final total = widget.entries.length;
    final shown = total < _visible ? total : _visible;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < shown; i++)
          FieldRow(
            name: widget.entries[i].key,
            value: widget.entries[i].value,
            previewLength: widget.previewLength,
            isIndex: widget.isArray,
          ),
        if (shown < total)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 4)),
              onPressed: () => setState(() => _visible += 50),
              child: Text(
                'Show ${total - shown < 50 ? total - shown : 50} more of '
                '${total - shown} ${widget.isArray ? 'items' : 'fields'}',
                style: TextStyle(fontSize: 12.5, color: c.accent),
              ),
            ),
          ),
      ],
    );
  }
}

/// One `key: value` line. Objects and arrays expand when tapped; a long
/// press copies the value.
class FieldRow extends StatefulWidget {
  const FieldRow({
    super.key,
    required this.name,
    required this.value,
    required this.previewLength,
    this.isIndex = false,
  });

  final String name;
  final Object? value;
  final int previewLength;
  final bool isIndex;

  @override
  State<FieldRow> createState() => _FieldRowState();
}

class _FieldRowState extends State<FieldRow> {
  bool _expanded = false;

  bool get _nested => widget.value is Map || widget.value is List;

  void _copy() {
    final v = widget.value;
    final text = v is String
        ? v
        : (v is Map || v is List)
            ? EJson.stringify(v)
            : shellRepr(v);
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Copied ${widget.name}')));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final keyStyle = monoStyle(context,
        size: 12.5,
        color: widget.isIndex ? c.muted : c.key,
        weight: widget.isIndex ? null : FontWeight.w700);
    final v = widget.value;

    final line = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 18,
          child: _nested
              ? Icon(_expanded ? Icons.expand_more : Icons.chevron_right,
                  size: 18, color: c.muted)
              : null,
        ),
        Flexible(
          child: _nested
              ? Text.rich(TextSpan(children: [
                  TextSpan(text: widget.name, style: keyStyle),
                  TextSpan(text: ': ', style: monoStyle(context, size: 12.5)),
                  TextSpan(
                    text: v is Map
                        ? 'Object${_expanded ? '' : ' (${v.length} fields)'}'
                        : 'Array (${(v as List).length})',
                    style: monoStyle(context, size: 12.5, color: c.muted),
                  ),
                ]))
              : Wrap(
                  crossAxisAlignment: WrapCrossAlignment.start,
                  children: [
                    Text('${widget.name}: ', style: keyStyle),
                    ScalarValue(v, previewLength: widget.previewLength),
                  ],
                ),
        ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: _nested ? () => setState(() => _expanded = !_expanded) : null,
          onLongPress: _copy,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Tooltip(
              message: bsonTypeName(v),
              waitDuration: const Duration(seconds: 1),
              child: line,
            ),
          ),
        ),
        if (_nested && _expanded)
          Container(
            margin: const EdgeInsets.only(left: 8),
            padding: const EdgeInsets.only(left: 10),
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: c.border)),
            ),
            child: FieldList(
              entries: v is Map
                  ? (v as Map<String, dynamic>).entries.toList()
                  : [
                      for (var i = 0; i < (v as List).length; i++)
                        MapEntry('$i', v[i]),
                    ],
              previewLength: widget.previewLength,
              isArray: v is List,
            ),
          ),
      ],
    );
  }
}

/// The document as Extended JSON text, cut off after [maxChars] with a
/// control to show the rest.
class JsonDocumentCard extends StatefulWidget {
  const JsonDocumentCard({
    super.key,
    required this.document,
    this.actions = const DocumentActions(),
    this.maxChars = 20000,
  });

  final Map<String, dynamic> document;
  final DocumentActions actions;
  final int maxChars;

  @override
  State<JsonDocumentCard> createState() => _JsonDocumentCardState();
}

class _JsonDocumentCardState extends State<JsonDocumentCard> {
  bool _full = false;
  late String _text = EJson.stringify(widget.document);

  @override
  void didUpdateWidget(covariant JsonDocumentCard old) {
    super.didUpdateWidget(old);
    if (!identical(old.document, widget.document)) {
      _text = EJson.stringify(widget.document);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final cut = !_full && _text.length > widget.maxChars;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ActionRow(document: widget.document, actions: widget.actions),
            SelectableText(
              cut ? '${_text.substring(0, widget.maxChars)}\n…' : _text,
              style: monoStyle(context, size: 12),
            ),
            if (cut)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => setState(() => _full = true),
                  child: Text(
                      'Show the full document (${_text.length ~/ 1024} KB)',
                      style: TextStyle(color: c.accent)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
