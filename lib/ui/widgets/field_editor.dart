import 'package:flutter/material.dart';
import 'package:mongo_wire/mongo_wire.dart';

import '../../services/field_model.dart';
import '../../theme/app_theme.dart';

/// Edits a document field by field: a name, a type and a value per row,
/// with nested objects and arrays that expand in place.
class FieldEditor extends StatelessWidget {
  const FieldEditor({
    super.key,
    required this.root,
    required this.onChanged,
    this.lockId = false,
    this.singleField = false,
    this.controller,
  });

  final FieldNode root;

  /// Called after every change so the parent can rebuild and revalidate.
  final VoidCallback onChanged;

  /// Makes the top-level `_id` read-only (editing an existing document).
  final bool lockId;

  /// Edits just the value (and type) of the root's one field: its name is
  /// fixed and it cannot be removed.
  final bool singleField;

  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    void walk(FieldNode parent, int depth) {
      for (final n in parent.children) {
        rows.add(
          _FieldRow(
            key: ObjectKey(n),
            node: n,
            parent: parent,
            depth: depth,
            locked: lockId && depth == 0 && n.key == '_id',
            fixedKey: singleField && depth == 0,
            onChanged: onChanged,
          ),
        );
        if (n.type.isContainer && n.expanded) walk(n, depth + 1);
      }
      if (singleField && depth == 0) return;
      rows.add(
        _AddRow(
          key: ObjectKey((parent, 'add')),
          depth: depth,
          label: parent.type == FieldType.array ? 'Add item' : 'Add field',
          onTap: () {
            parent.addChild();
            onChanged();
          },
        ),
      );
    }

    walk(root, 0);
    return ListView(
      controller: controller,
      shrinkWrap: singleField,
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
      children: rows,
    );
  }
}

class _AddRow extends StatelessWidget {
  const _AddRow({
    super.key,
    required this.depth,
    required this.label,
    required this.onTap,
  });

  final int depth;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: depth * 16.0 + 4, bottom: 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: onTap,
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          icon: const Icon(Icons.add, size: 16),
          label: Text(label),
        ),
      ),
    );
  }
}

class _FieldRow extends StatelessWidget {
  const _FieldRow({
    super.key,
    required this.node,
    required this.parent,
    required this.depth,
    required this.locked,
    required this.onChanged,
    this.fixedKey = false,
  });

  final FieldNode node;
  final FieldNode parent;
  final int depth;
  final bool locked;
  final bool fixedKey;
  final VoidCallback onChanged;

  String? get _valueError {
    if (node.type.isContainer) return null;
    try {
      node.value();
      return null;
    } on FormatException catch (e) {
      return e.message;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final inArray = parent.type == FieldType.array;
    final mono = monoStyle(context, size: 13);
    final dense = InputDecoration(
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      fillColor: c.card,
    );

    final keyPart = fixedKey
        ? Expanded(
            child: Text(
              node.key,
              overflow: TextOverflow.ellipsis,
              style: mono.copyWith(color: c.key, fontWeight: FontWeight.w700),
            ),
          )
        : inArray
        ? Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text('[${node.key}]', style: mono.copyWith(color: c.muted)),
          )
        : Expanded(
            child: TextFormField(
              key: ValueKey((node, 'key')),
              initialValue: node.key,
              enabled: !locked,
              autocorrect: false,
              enableSuggestions: false,
              style: mono.copyWith(color: c.key),
              decoration: dense.copyWith(hintText: 'field name'),
              onChanged: (v) {
                node.key = v;
                onChanged();
              },
            ),
          );

    return Container(
      margin: EdgeInsets.only(left: depth * 16.0, bottom: 6),
      padding: const EdgeInsets.fromLTRB(2, 4, 2, 6),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: depth > 0 ? c.border : Colors.transparent),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: 28,
                child: node.type.isContainer
                    ? IconButton(
                        tooltip: node.expanded ? 'Collapse' : 'Expand',
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        onPressed: () {
                          node.expanded = !node.expanded;
                          onChanged();
                        },
                        icon: Icon(
                          node.expanded
                              ? Icons.expand_more
                              : Icons.chevron_right,
                          size: 20,
                        ),
                      )
                    : null,
              ),
              keyPart,
              if (inArray) const Spacer(),
              const SizedBox(width: 6),
              _TypeButton(node: node, enabled: !locked, onChanged: onChanged),
              SizedBox(
                width: 36,
                child: fixedKey
                    ? null
                    : locked
                    ? Icon(Icons.lock_outline, size: 16, color: c.muted)
                    : IconButton(
                        tooltip: 'Remove ${inArray ? 'item' : 'field'}',
                        visualDensity: VisualDensity.compact,
                        onPressed: () {
                          parent.removeChild(node);
                          onChanged();
                        },
                        icon: Icon(Icons.close, size: 18, color: c.muted),
                      ),
              ),
            ],
          ),
          if (_valueBody(context, dense, mono) case final body?)
            Padding(
              padding: const EdgeInsets.only(left: 28, top: 6, right: 36),
              child: body,
            ),
        ],
      ),
    );
  }

  Widget? _valueBody(
    BuildContext context,
    InputDecoration dense,
    TextStyle mono,
  ) {
    final c = context.colors;
    switch (node.type) {
      case FieldType.object || FieldType.array:
        if (node.expanded) return null;
        final n = node.children.length;
        return Text(
          node.type == FieldType.array
              ? '$n item${n == 1 ? '' : 's'}'
              : '$n field${n == 1 ? '' : 's'}',
          style: TextStyle(color: c.muted, fontSize: 12.5),
        );
      case FieldType.null_:
        return Text('null', style: mono.copyWith(color: c.nullValue));
      case FieldType.other:
        return Text(
          EJson.stringify(node.original, pretty: false),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: mono.copyWith(color: c.other),
        );
      case FieldType.boolean:
        return Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<bool>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(value: true, label: Text('true')),
              ButtonSegment(value: false, label: Text('false')),
            ],
            selected: {node.text.trim() == 'true'},
            onSelectionChanged: locked
                ? null
                : (s) {
                    node.text = '${s.first}';
                    onChanged();
                  },
          ),
        );
      default:
        final color = switch (node.type) {
          FieldType.string => c.string,
          FieldType.date => c.date,
          FieldType.objectId => c.objectId,
          _ => c.number,
        };
        final numeric = switch (node.type) {
          FieldType.int32 ||
          FieldType.int64 ||
          FieldType.double_ ||
          FieldType.decimal => true,
          _ => false,
        };
        return TextFormField(
          key: ValueKey((node, node.revision)),
          initialValue: node.text,
          enabled: !locked,
          autocorrect: false,
          enableSuggestions: false,
          minLines: 1,
          maxLines: node.type == FieldType.string ? 6 : 1,
          keyboardType: numeric
              ? const TextInputType.numberWithOptions(
                  signed: true,
                  decimal: true,
                )
              : null,
          style: mono.copyWith(color: color),
          decoration: dense.copyWith(
            hintText: node.type == FieldType.string ? 'empty string' : null,
            errorText: _valueError,
            suffixIcon: node.type == FieldType.objectId && !locked
                ? _SuffixButton(
                    tooltip: 'New ObjectId',
                    icon: Icons.autorenew,
                    onTap: () {
                      node
                        ..text = ObjectId().hex
                        ..revision += 1;
                      onChanged();
                    },
                  )
                : node.type == FieldType.date && !locked
                ? _SuffixButton(
                    tooltip: 'Pick a date',
                    icon: Icons.calendar_today_outlined,
                    onTap: () => _pickDate(context),
                  )
                : null,
          ),
          onChanged: (v) {
            node.text = v;
            onChanged();
          },
        );
    }
  }

  Future<void> _pickDate(BuildContext context) async {
    DateTime current;
    try {
      current = parseIsoDate(node.text.trim()) as DateTime;
    } on FormatException {
      current = DateTime.now().toUtc();
    }
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime.utc(1),
      lastDate: DateTime.utc(9999, 12, 31),
    );
    if (picked == null) return;
    final next = DateTime.utc(
      picked.year,
      picked.month,
      picked.day,
      current.hour,
      current.minute,
      current.second,
      current.millisecond,
    );
    node
      ..text = formatIsoDate(next)
      ..revision += 1;
    onChanged();
  }
}

class _SuffixButton extends StatelessWidget {
  const _SuffixButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    visualDensity: VisualDensity.compact,
    onPressed: onTap,
    icon: Icon(icon, size: 18),
  );
}

class _TypeButton extends StatelessWidget {
  const _TypeButton({
    required this.node,
    required this.enabled,
    required this.onChanged,
  });

  final FieldNode node;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final chip = Container(
      padding: const EdgeInsets.fromLTRB(8, 5, 4, 5),
      decoration: BoxDecoration(
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            node.type == FieldType.other
                ? bsonTypeName(node.original)
                : node.type.label,
            style: TextStyle(fontSize: 12, color: c.muted),
          ),
          if (enabled) Icon(Icons.arrow_drop_down, size: 16, color: c.muted),
        ],
      ),
    );
    if (!enabled) return chip;
    return PopupMenuButton<FieldType>(
      tooltip: 'Field type',
      initialValue: node.type,
      onSelected: (t) {
        node.changeType(t);
        onChanged();
      },
      itemBuilder: (_) => [
        for (final t in FieldType.choices)
          PopupMenuItem(value: t, height: 38, child: Text(t.label)),
      ],
      child: chip,
    );
  }
}
