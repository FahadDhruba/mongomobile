import 'package:flutter/material.dart';

import '../../state/documents_controller.dart';
import '../../theme/app_theme.dart';
import 'query_assist.dart';

/// Compass-style query bar: a Filter input with Find and Reset, and
/// collapsible Project, Sort, Collation, Hint, Skip, Limit and Max time
/// options. Brackets and quotes close
/// themselves, and a row of chips suggests field names, operators and
/// value helpers for the input being edited.
class QueryBar extends StatefulWidget {
  const QueryBar({
    super.key,
    required this.initial,
    required this.onFind,
    required this.onReset,
    this.busy = false,
    this.fields = const [],
    this.onHistory,
    this.onSaveFavorite,
  });

  final QuerySpec initial;
  final ValueChanged<QuerySpec> onFind;
  final VoidCallback onReset;
  final bool busy;

  /// Known field paths of the collection, for suggestions.
  final List<String> fields;

  /// Opens recent and favourite queries.
  final VoidCallback? onHistory;

  /// Saves the query as typed (after checking it parses).
  final ValueChanged<QuerySpec>? onSaveFavorite;

  @override
  State<QueryBar> createState() => _QueryBarState();
}

class _QueryBarState extends State<QueryBar> {
  late final _filter = TextEditingController(text: widget.initial.filterText);
  late final _project = TextEditingController(text: widget.initial.projectText);
  late final _sort = TextEditingController(text: widget.initial.sortText);
  late final _limit = TextEditingController(text: widget.initial.limitText);
  late final _skip = TextEditingController(text: widget.initial.skipText);
  late final _collation =
      TextEditingController(text: widget.initial.collationText);
  late final _hint = TextEditingController(text: widget.initial.hintText);
  late final _maxTime = TextEditingController(text: widget.initial.maxTimeText);
  late bool _options = widget.initial.hasOptions;

  List<TextEditingController> get _all =>
      [_filter, _project, _sort, _collation, _hint, _skip, _limit, _maxTime];
  String? _error;

  final _focus = {
    for (final f in QueryField.values) f: FocusNode(),
  };
  QueryField? _active;
  List<Suggestion> _suggestions = const [];
  QueryContext? _context;

  TextEditingController _controllerOf(QueryField f) => switch (f) {
        QueryField.filter => _filter,
        QueryField.project => _project,
        QueryField.sort => _sort,
      };

  @override
  void initState() {
    super.initState();
    for (final f in QueryField.values) {
      _focus[f]!.addListener(() => _onFocus(f));
      _controllerOf(f).addListener(() {
        if (_active == f) _refreshSuggestions();
      });
    }
  }

  void _onFocus(QueryField f) {
    if (_focus[f]!.hasFocus) {
      _active = f;
      _refreshSuggestions();
    } else if (_active == f) {
      setState(() {
        _active = null;
        _suggestions = const [];
      });
    }
  }

  void _refreshSuggestions() {
    final f = _active;
    if (f == null) return;
    final value = _controllerOf(f).value;
    final sel = value.selection;
    QueryContext? ctx;
    var next = const <Suggestion>[];
    if (sel.isValid && sel.isCollapsed) {
      ctx = analyzeQuery(value.text, sel.baseOffset);
      if (ctx != null) next = suggestQuery(f, ctx, widget.fields);
    }
    if (!_sameLabels(next, _suggestions) || ctx?.start != _context?.start) {
      setState(() {
        _suggestions = next;
        _context = ctx;
      });
    } else {
      _context = ctx;
    }
  }

  static bool _sameLabels(List<Suggestion> a, List<Suggestion> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _apply(Suggestion s) {
    final f = _active;
    final ctx = _context;
    if (f == null || ctx == null) return;
    final controller = _controllerOf(f);
    controller.value = applySuggestion(controller.value, ctx, s);
    _focus[f]!.requestFocus();
  }

  @override
  void didUpdateWidget(covariant QueryBar old) {
    super.didUpdateWidget(old);
    if (old.fields != widget.fields) _refreshSuggestions();
    // A query run from elsewhere (history, favourites) fills the inputs.
    if (!identical(old.initial, widget.initial)) {
      final q = widget.initial;
      final texts = [
        q.filterText,
        q.projectText,
        q.sortText,
        q.collationText,
        q.hintText,
        q.skipText,
        q.limitText,
        q.maxTimeText,
      ];
      for (var i = 0; i < _all.length; i++) {
        if (_all[i].text != texts[i]) _all[i].text = texts[i];
      }
      if (q.hasOptions && !_options) setState(() => _options = true);
    }
  }

  @override
  void dispose() {
    for (final c in _all) {
      c.dispose();
    }
    for (final n in _focus.values) {
      n.dispose();
    }
    super.dispose();
  }

  QuerySpec? _parse() {
    try {
      final spec = QuerySpec.parse(
        filter: _filter.text,
        project: _project.text,
        sort: _sort.text,
        collation: _collation.text,
        hint: _hint.text,
        skip: _skip.text,
        limit: _limit.text,
        maxTime: _maxTime.text,
      );
      setState(() => _error = null);
      return spec;
    } on FormatException catch (e) {
      setState(() => _error = e.message);
      return null;
    }
  }

  void _find() {
    final spec = _parse();
    if (spec == null) return;
    FocusScope.of(context).unfocus();
    widget.onFind(spec);
  }

  void _save() {
    final spec = _parse();
    if (spec == null) return;
    if (spec.isDefault) {
      setState(() => _error = 'Type a query to save it');
      return;
    }
    widget.onSaveFavorite?.call(spec);
  }

  void _reset() {
    for (final c in _all) {
      c.clear();
    }
    setState(() => _error = null);
    FocusScope.of(context).unfocus();
    widget.onReset();
  }

  Widget _field(String label, TextEditingController controller, String hint,
      {TextInputType? keyboard, QueryField? field, bool braces = false}) {
    final c = context.colors;
    return TextField(
      controller: controller,
      focusNode: field == null ? null : _focus[field],
      inputFormatters:
          field != null || braces ? [QueryInputFormatter()] : null,
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
          _field('Filter', _filter, "{ field: 'value' }",
              field: QueryField.filter),
          if (_options) ...[
            const SizedBox(height: 8),
            _field('Project', _project, '{ field: 1 }',
                field: QueryField.project),
            const SizedBox(height: 8),
            _field('Sort', _sort, '{ _id: -1 }', field: QueryField.sort),
            const SizedBox(height: 8),
            _field('Collation', _collation, "{ locale: 'en', strength: 2 }",
                braces: true),
            const SizedBox(height: 8),
            _field('Hint', _hint, '{ field: 1 } or index name'),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _field('Skip', _skip, '0',
                      keyboard: TextInputType.number),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _field('Limit', _limit, '0',
                      keyboard: TextInputType.number),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _field('Max time ms', _maxTime, 'from Settings',
                keyboard: TextInputType.number),
          ],
          if (_suggestions.isNotEmpty) ...[
            const SizedBox(height: 6),
            _SuggestionStrip(suggestions: _suggestions, onPick: _apply),
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
                label: Text(_options ? 'Fewer' : 'Options'),
              ),
              if (widget.onHistory != null)
                IconButton(
                  tooltip: 'Query history',
                  visualDensity: VisualDensity.compact,
                  color: c.muted,
                  onPressed: widget.onHistory,
                  icon: const Icon(Icons.history, size: 20),
                ),
              if (widget.onSaveFavorite != null)
                IconButton(
                  tooltip: 'Save as favourite',
                  visualDensity: VisualDensity.compact,
                  color: c.muted,
                  onPressed: _save,
                  icon: const Icon(Icons.star_border, size: 20),
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

/// A sideways-scrolling row of suggestion chips.
class _SuggestionStrip extends StatelessWidget {
  const _SuggestionStrip({required this.suggestions, required this.onPick});

  final List<Suggestion> suggestions;
  final ValueChanged<Suggestion> onPick;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Taps here count as taps on the text field, so it keeps focus and the
    // keyboard stays up.
    return TextFieldTapRegion(
      child: SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: suggestions.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final s = suggestions[i];
          final color = switch (s.kind) {
            SuggestionKind.field => c.key,
            SuggestionKind.operator => c.accent,
            SuggestionKind.value => c.objectId,
          };
          return ActionChip(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            backgroundColor: c.background,
            side: BorderSide(color: c.border),
            label: Text(s.label, style: monoStyle(context, size: 12.5, color: color)),
            onPressed: () => onPick(s),
          );
        },
      ),
      ),
    );
  }
}
