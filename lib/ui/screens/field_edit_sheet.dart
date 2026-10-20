import 'package:flutter/material.dart';

import '../../services/field_model.dart';
import '../../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/field_editor.dart';

/// Edits one top-level field of a document in a bottom sheet. [onSave]
/// receives the new value and [onRemove] removes the field; both return
/// an error message, or null on success.
Future<bool?> showFieldEditSheet(
  BuildContext context, {
  required String field,
  required Object? value,
  required bool missing,
  required Future<String?> Function(Object? value) onSave,
  required Future<String?> Function() onRemove,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: _FieldEditSheet(
        field: field,
        value: value,
        missing: missing,
        onSave: onSave,
        onRemove: onRemove,
      ),
    ),
  );
}

class _FieldEditSheet extends StatefulWidget {
  const _FieldEditSheet({
    required this.field,
    required this.value,
    required this.missing,
    required this.onSave,
    required this.onRemove,
  });

  final String field;
  final Object? value;
  final bool missing;
  final Future<String?> Function(Object? value) onSave;
  final Future<String?> Function() onRemove;

  @override
  State<_FieldEditSheet> createState() => _FieldEditSheetState();
}

class _FieldEditSheetState extends State<_FieldEditSheet> {
  late final FieldNode _root = FieldNode.fromValue('', <String, dynamic>{
    widget.field: widget.missing ? '' : widget.value,
  });
  bool _busy = false;
  String? _error;

  Future<void> _run(Future<String?> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await action();
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final invalid = _root.error();
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.8,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              widget.missing ? 'Add field' : 'Edit field',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
          ),
          Flexible(
            child: FieldEditor(
              root: _root,
              singleField: true,
              onChanged: () => setState(() {}),
            ),
          ),
          if (_error ?? invalid case final message?)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: MessageBanner(message: message),
            ),
          Container(
            padding: const EdgeInsets.fromLTRB(8, 8, 12, 12),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: c.border)),
            ),
            child: Row(
              children: [
                if (!widget.missing)
                  TextButton(
                    onPressed: _busy ? null : () => _run(widget.onRemove),
                    child: Text(
                      'Remove field',
                      style: TextStyle(color: _busy ? null : c.danger),
                    ),
                  ),
                const Spacer(),
                TextButton(
                  onPressed: _busy ? null : () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 4),
                AccentButton(
                  label: _busy ? 'Saving…' : 'Save',
                  compact: true,
                  onPressed: _busy || invalid != null
                      ? null
                      : () => _run(
                          () => widget.onSave(_root.children.single.value()),
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
