import 'package:flutter/material.dart';
import 'package:mongo_wire/mongo_wire.dart';

import '../../theme/app_theme.dart';
import 'bson_value.dart';
import 'document_card.dart';

/// The current page as a table: one column per top-level field, scrolling
/// sideways. Tapping a cell shows its full value; the row menu offers the
/// document actions.
class DocumentTable extends StatefulWidget {
  const DocumentTable({
    super.key,
    required this.documents,
    required this.firstRowNumber,
    required this.previewLength,
    required this.actionsFor,
    this.header,
  });

  final List<Map<String, dynamic>> documents;
  final int firstRowNumber;
  final int previewLength;
  final DocumentActions Function(int index) actionsFor;

  /// Shown above the table, e.g. banners.
  final Widget? header;

  /// Columns beyond this are left out; wide documents are better read in
  /// the list or JSON view.
  static const maxColumns = 60;
  static const cellChars = 48;

  @override
  State<DocumentTable> createState() => _DocumentTableState();
}

class _DocumentTableState extends State<DocumentTable> {
  final _horizontal = ScrollController();

  @override
  void dispose() {
    _horizontal.dispose();
    super.dispose();
  }

  /// Field names in first-seen order, `_id` first.
  static List<String> columnsOf(List<Map<String, dynamic>> docs) {
    final seen = <String>{};
    for (final d in docs) {
      seen.addAll(d.keys);
    }
    final cols = seen.toList();
    if (cols.remove('_id')) cols.insert(0, '_id');
    return cols;
  }

  double _width(String col) => col == '_id' ? 300 : 190;

  String _cellText(Object? v) {
    if (v is Map) return 'Object (${v.length} fields)';
    if (v is List) return 'Array (${v.length})';
    final s = shellRepr(v);
    return s.length > DocumentTable.cellChars
        ? '${s.substring(0, DocumentTable.cellChars)}…'
        : s;
  }

  void _showValue(String field, Object? value, bool missing) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (ctx, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.all(16),
          children: [
            Text(field,
                style: monoStyle(ctx, size: 14, weight: FontWeight.w700)),
            Text(missing ? 'missing' : bsonTypeName(value),
                style: TextStyle(color: ctx.colors.muted, fontSize: 12)),
            const SizedBox(height: 12),
            if (missing)
              Text('This document has no "$field" field.',
                  style: TextStyle(color: ctx.colors.muted))
            else if (value is Map<String, dynamic>)
              FieldList(
                  entries: value.entries.toList(),
                  previewLength: widget.previewLength)
            else if (value is List)
              FieldList(
                  entries: [
                    for (var i = 0; i < value.length; i++) MapEntry('$i', value[i]),
                  ],
                  isArray: true,
                  previewLength: widget.previewLength)
            else
              SelectableText(
                value is String ? value : shellRepr(value),
                style: monoStyle(ctx, color: typeColor(ctx.colors, value)),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    var cols = columnsOf(widget.documents);
    final hidden = cols.length - DocumentTable.maxColumns;
    if (hidden > 0) cols = cols.sublist(0, DocumentTable.maxColumns);
    const indexWidth = 64.0;
    final total =
        indexWidth + cols.fold<double>(0, (sum, col) => sum + _width(col));
    final headerStyle =
        monoStyle(context, size: 12.5, color: c.key, weight: FontWeight.w700);

    Widget cell(double width, Widget child, {Color? background}) => Container(
          width: width,
          height: 40,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: background,
            border: Border(
              right: BorderSide(color: c.border),
              bottom: BorderSide(color: c.border),
            ),
          ),
          child: child,
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ?widget.header,
        if (hidden > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Text(
                '$hidden more fields are not shown; use the list or JSON view.',
                style: TextStyle(color: c.muted, fontSize: 12)),
          ),
        Expanded(
          child: Scrollbar(
            controller: _horizontal,
            child: SingleChildScrollView(
              controller: _horizontal,
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: total,
                child: Column(
                  children: [
                    Row(
                      children: [
                        cell(indexWidth, const SizedBox(), background: c.panel),
                        for (final col in cols)
                          cell(
                            _width(col),
                            Text(col,
                                overflow: TextOverflow.ellipsis,
                                style: headerStyle),
                            background: c.panel,
                          ),
                      ],
                    ),
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.only(bottom: 24),
                        itemCount: widget.documents.length,
                        itemBuilder: (_, i) {
                          final doc = widget.documents[i];
                          final actions = widget.actionsFor(i);
                          final stripe = i.isOdd ? c.card : c.background;
                          return Row(
                            children: [
                              cell(
                                indexWidth,
                                _RowMenu(
                                  number: widget.firstRowNumber + i,
                                  document: doc,
                                  actions: actions,
                                ),
                                background: stripe,
                              ),
                              for (final col in cols)
                                InkWell(
                                  onTap: () => _showValue(
                                      col, doc[col], !doc.containsKey(col)),
                                  child: cell(
                                    _width(col),
                                    doc.containsKey(col)
                                        ? Text(
                                            _cellText(doc[col]),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: monoStyle(context,
                                                    size: 12.5,
                                                    color: typeColor(
                                                        c, doc[col]))
                                                .copyWith(
                                                    fontStyle: doc[col] == null
                                                        ? FontStyle.italic
                                                        : null),
                                          )
                                        : Text('—',
                                            style: TextStyle(color: c.border)),
                                    background: stripe,
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _RowMenu extends StatelessWidget {
  const _RowMenu({
    required this.number,
    required this.document,
    required this.actions,
  });

  final int number;
  final Map<String, dynamic> document;
  final DocumentActions actions;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return PopupMenuButton<String>(
      tooltip: 'Row $number actions',
      padding: EdgeInsets.zero,
      onSelected: (v) => switch (v) {
        'edit' => actions.onEdit?.call(),
        'clone' => actions.onClone?.call(),
        'delete' => actions.onDelete?.call(),
        _ => null,
      },
      itemBuilder: (_) => [
        if (actions.onEdit != null)
          const PopupMenuItem(value: 'edit', child: Text('Edit')),
        if (actions.onClone != null)
          const PopupMenuItem(value: 'clone', child: Text('Clone')),
        if (actions.onDelete != null)
          const PopupMenuItem(value: 'delete', child: Text('Delete')),
        if (actions.onEdit == null)
          const PopupMenuItem(
              enabled: false, child: Text('Read-only: no actions')),
      ],
      child: Row(
        children: [
          Text('$number', style: monoStyle(context, size: 12, color: c.muted)),
          const Spacer(),
          Icon(Icons.more_vert, size: 16, color: c.muted),
        ],
      ),
    );
  }
}

/// Exposed for tests.
List<String> tableColumns(List<Map<String, dynamic>> docs) =>
    _DocumentTableState.columnsOf(docs);
