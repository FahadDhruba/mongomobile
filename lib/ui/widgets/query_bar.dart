import 'package:flutter/material.dart';

import '../../state/documents_controller.dart';
import '../../theme/app_theme.dart';

/// Compass-style query bar: a Filter input with Find and Reset, and
/// collapsible Project, Sort and Limit options.
class QueryBar extends StatefulWidget {
  const QueryBar({
    super.key,
    required this.initial,
    required this.onFind,
    required this.onReset,
    this.busy = false,
  });

  final QuerySpec initial;
  final ValueChanged<QuerySpec> onFind;
  final VoidCallback onReset;
  final bool busy;

  @override
  State<QueryBar> createState() => _QueryBarState();
}

class _QueryBarState extends State<QueryBar> {
  late final _filter = TextEditingController(text: widget.initial.filterText);
  late final _project = TextEditingController(text: widget.initial.projectText);
  late final _sort = TextEditingController(text: widget.initial.sortText);
  late final _limit = TextEditingController(text: widget.initial.limitText);
  late bool _options = widget.initial.projectText.isNotEmpty ||
      widget.initial.sortText.isNotEmpty ||
      widget.initial.limitText.isNotEmpty;
  String? _error;

  @override
  void dispose() {
    for (final c in [_filter, _project, _sort, _limit]) {
      c.dispose();
    }
    super.dispose();
  }

  void _find() {
    try {
      final spec = QuerySpec.parse(
        filter: _filter.text,
        project: _project.text,
        sort: _sort.text,
        limit: _limit.text,
      );
      setState(() => _error = null);
      FocusScope.of(context).unfocus();
      widget.onFind(spec);
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    }
  }

  void _reset() {
    for (final c in [_filter, _project, _sort, _limit]) {
      c.clear();
    }
    setState(() => _error = null);
    FocusScope.of(context).unfocus();
    widget.onReset();
  }

  Widget _field(String label, TextEditingController controller, String hint,
      {TextInputType? keyboard}) {
    final c = context.colors;
    return TextField(
      controller: controller,
      style: monoStyle(context, size: 13),
      keyboardType: keyboard ?? TextInputType.multiline,
      autocorrect: false,
      enableSuggestions: false,
      minLines: 1,
      maxLines: keyboard == null ? 4 : 1,
      textInputAction: TextInputAction.search,
      onSubmitted: (_) => _find(),
      decoration: InputDecoration(
        prefixIcon: Padding(
          padding: const EdgeInsets.only(left: 12, right: 8),
          child: Text(label,
              style: TextStyle(
                  color: c.muted, fontWeight: FontWeight.w600, fontSize: 12.5)),
        ),
        prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
        hintText: hint,
        hintStyle: monoStyle(context, size: 13, color: c.muted),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      color: c.panel,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _field('Filter', _filter, "{ field: 'value' }"),
          if (_options) ...[
            const SizedBox(height: 8),
            _field('Project', _project, '{ field: 1 }'),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(flex: 3, child: _field('Sort', _sort, '{ _id: -1 }')),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: _field('Limit', _limit, '0',
                      keyboard: TextInputType.number),
                ),
              ],
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 6),
            Text(_error!, style: TextStyle(color: c.danger, fontSize: 12.5)),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              TextButton.icon(
                style: TextButton.styleFrom(
                    foregroundColor: c.muted,
                    visualDensity: VisualDensity.compact),
                onPressed: () => setState(() => _options = !_options),
                icon: Icon(_options ? Icons.expand_less : Icons.tune, size: 18),
                label: Text(_options ? 'Fewer options' : 'Options'),
              ),
              const Spacer(),
              OutlinedButton(
                onPressed: _reset,
                style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact),
                child: const Text('Reset'),
              ),
              const SizedBox(width: 8),
              AccentButton(
                label: 'Find',
                compact: true,
                onPressed: widget.busy ? null : _find,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
