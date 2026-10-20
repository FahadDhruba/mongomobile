import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mongo_wire/mongo_wire.dart';

import '../../services/schema_analysis.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/document_card.dart';
import '../widgets/json_highlight.dart';
import '../widgets/query_assist.dart';

/// The Validation tab: the collection's validator, level and action, with
/// a document that passes and one that fails the rules as typed.
class ValidationView extends ConsumerStatefulWidget {
  const ValidationView({super.key, required this.namespace, this.info});

  final Namespace namespace;
  final CollectionInfo? info;

  @override
  ConsumerState<ValidationView> createState() => _ValidationViewState();
}

class _ValidationViewState extends ConsumerState<ValidationView>
    with AutomaticKeepAliveClientMixin {
  late final _rules = JsonEditingController(text: _currentText);
  late String _level = _currentLevel;
  late String _action = _currentAction;
  Map<String, dynamic>? _parsed;
  String? _parseError;
  Timer? _debounce;
  bool _saving = false;
  bool _generating = false;
  String? _message;
  bool _messageIsError = false;
  Map<String, dynamic>? _passing;
  Map<String, dynamic>? _failing;
  bool _previewLoading = false;
  String? _previewError;
  int _previewRun = 0;

  @override
  bool get wantKeepAlive => true;

  Map<String, dynamic> get _options => widget.info?.options ?? const {};

  String get _currentText {
    final v = _options['validator'];
    return v is Map && v.isNotEmpty ? EJson.stringify(v) : '{}';
  }

  String get _currentLevel =>
      _options['validationLevel'] as String? ?? 'strict';
  String get _currentAction =>
      _options['validationAction'] as String? ?? 'error';

  @override
  void initState() {
    super.initState();
    _parse();
    _rules.addListener(() {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 600), () {
        if (!mounted) return;
        setState(_parse);
        _preview();
      });
    });
    Future.microtask(_preview);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _rules.dispose();
    super.dispose();
  }

  void _parse() {
    try {
      _parsed = EJson.parseDocument(_rules.text);
      _parseError = null;
    } on EJsonParseException catch (e) {
      _parsed = null;
      _parseError = 'Line ${e.line}, column ${e.column}: ${e.message}';
    }
  }

  bool get _changed =>
      _parsed != null &&
      (EJson.stringify(_parsed, pretty: false) !=
              EJson.stringify(
                _options['validator'] ?? const <String, dynamic>{},
                pretty: false,
              ) ||
          _level != _currentLevel ||
          _action != _currentAction);

  Future<void> _preview() async {
    final rules = _parsed;
    final run = ++_previewRun;
    if (rules == null || rules.isEmpty) {
      setState(() {
        _passing = null;
        _failing = null;
        _previewError = null;
      });
      return;
    }
    setState(() => _previewLoading = true);
    final client = ref.read(clientProvider);
    final timeout = ref.read(settingsProvider).queryTimeout;
    Future<Map<String, dynamic>?> one(Map<String, dynamic> filter) async {
      final r = await client.find(
        widget.namespace,
        FindRequest(
          filter: filter,
          limit: 1,
          maxTime: timeout,
          maxBytes: 16 << 20,
        ),
      );
      return r.documents.firstOrNull;
    }

    try {
      final passing = await one(rules);
      final failing = await one({
        r'$nor': [rules],
      });
      if (!mounted || run != _previewRun) return;
      setState(() {
        _passing = passing;
        _failing = failing;
        _previewError = null;
        _previewLoading = false;
      });
    } on Object catch (e) {
      if (!mounted || run != _previewRun) return;
      setState(() {
        _previewError = describeError(e);
        _previewLoading = false;
      });
    }
  }

  Future<void> _generate() async {
    setState(() => _generating = true);
    try {
      final r = await ref
          .read(clientProvider)
          .aggregate(
            widget.namespace,
            [
              {
                r'$sample': {'size': 1000},
              },
            ],
            limit: 1000,
            maxTime: ref.read(settingsProvider).queryTimeout,
            maxBytes: 64 << 20,
          );
      if (!mounted) return;
      if (r.documents.isEmpty) {
        setState(() {
          _generating = false;
          _message = 'There are no documents to generate rules from.';
          _messageIsError = true;
        });
        return;
      }
      _rules.text = EJson.stringify(
        jsonSchemaOf(SchemaAnalysis.of(r.documents)),
      );
      setState(() {
        _generating = false;
        _parse();
        _message =
            'Rules generated from ${r.documents.length} sampled documents. '
            'Review them before updating.';
        _messageIsError = false;
      });
      _preview();
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _generating = false;
        _message = describeError(e);
        _messageIsError = true;
      });
    }
  }

  Future<void> _save() async {
    final rules = _parsed;
    if (rules == null) return;
    final ok = await confirmDialog(
      context,
      title: 'Update validation?',
      message: _action == 'error' && _level != 'off'
          ? 'Inserts and updates that break these rules will be rejected '
                '(${_level == 'strict' ? 'all documents' : 'documents that already pass'}).'
          : 'Documents that break these rules will be logged as warnings '
                'but still written.',
      confirmLabel: 'Update',
      destructive: false,
    );
    if (!ok || !mounted) return;
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      await ref.read(clientProvider).modifyCollection(widget.namespace, {
        'validator': rules,
        'validationLevel': _level,
        'validationAction': _action,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Validation updated')));
      setState(() => _saving = false);
      // Reloads the collection options, which rebuilds this tab with them.
      ref.invalidate(collectionsProvider(widget.namespace.db));
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _message = describeError(e);
        _messageIsError = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final c = context.colors;
    final info = widget.info;
    if (info != null && (info.isView || info.type == 'timeseries')) {
      return ListView(
        children: [
          EmptyState(
            icon: Icons.rule,
            title: 'No validation here',
            message: info.isView
                ? 'Views cannot have validation rules.'
                : 'Time series collections cannot have validation rules.',
          ),
        ],
      );
    }
    final readOnly = ref.watch(readOnlyProvider);
    final preview = ref.watch(settingsProvider).stringPreviewLength;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Rules: a query filter or a \$jsonSchema',
                style: TextStyle(color: c.muted, fontSize: 12.5),
              ),
            ),
            TextButton.icon(
              onPressed: _generating ? null : _generate,
              icon: const Icon(Icons.auto_fix_high, size: 18),
              label: Text(_generating ? 'Generating…' : 'Generate'),
            ),
          ],
        ),
        TextField(
          controller: _rules,
          minLines: 6,
          maxLines: 18,
          keyboardType: TextInputType.multiline,
          autocorrect: false,
          enableSuggestions: false,
          inputFormatters: [QueryInputFormatter(wrapInBraces: false)],
          style: monoStyle(context, size: 13),
          decoration: InputDecoration(
            fillColor: c.card,
            errorText: _parseError,
            errorMaxLines: 3,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _Choice(
                label: 'Action',
                value: _action,
                options: const {'error': 'Error', 'warn': 'Warning'},
                onChanged: (v) => setState(() => _action = v),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _Choice(
                label: 'Level',
                value: _level,
                options: const {
                  'strict': 'Strict',
                  'moderate': 'Moderate',
                  'off': 'Off',
                },
                onChanged: (v) => setState(() => _level = v),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(switch (_level) {
          'strict' => 'Strict checks every insert and update.',
          'moderate' =>
            'Moderate skips updates to documents that already break the '
                'rules.',
          _ => 'Off turns validation off without removing the rules.',
        }, style: TextStyle(color: c.muted, fontSize: 12)),
        if (_message case final m?) ...[
          const SizedBox(height: 10),
          MessageBanner(
            message: m,
            kind: _messageIsError ? BannerKind.error : BannerKind.info,
          ),
        ],
        const SizedBox(height: 10),
        Row(
          children: [
            if (_changed)
              TextButton(
                onPressed: () {
                  _rules.text = _currentText;
                  setState(() {
                    _level = _currentLevel;
                    _action = _currentAction;
                    _parse();
                    _message = null;
                  });
                },
                child: const Text('Revert'),
              ),
            const Spacer(),
            Tooltip(
              message: readOnly ? 'Turn on write mode to change rules' : '',
              child: AccentButton(
                label: _saving ? 'Updating…' : 'Update',
                compact: true,
                onPressed: readOnly || _saving || !_changed ? null : _save,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            const Expanded(
              child: Text(
                'Sample documents',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            if (_previewLoading)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        const SizedBox(height: 6),
        if (_previewError case final e?)
          MessageBanner(message: e)
        else if (_parsed == null || _parsed!.isEmpty)
          Text(
            'Enter rules to see a document that passes and one that fails.',
            style: TextStyle(color: c.muted, fontSize: 12.5),
          )
        else ...[
          _SampleHeader(passes: true),
          _passing == null
              ? _None(text: 'No document passes these rules.')
              : DocumentCard(document: _passing!, previewLength: preview),
          const SizedBox(height: 12),
          _SampleHeader(passes: false),
          _failing == null
              ? _None(text: 'Every document passes these rules.')
              : DocumentCard(document: _failing!, previewLength: preview),
        ],
      ],
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final String value;
  final Map<String, String> options;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      initialValue: options.containsKey(value) ? value : options.keys.first,
      isDense: true,
      decoration: InputDecoration(labelText: label, isDense: true),
      items: [
        for (final MapEntry(:key, :value) in options.entries)
          DropdownMenuItem(value: key, child: Text(value)),
      ],
      onChanged: (v) => onChanged(v!),
    );
  }
}

class _SampleHeader extends StatelessWidget {
  const _SampleHeader({required this.passes});
  final bool passes;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(
            passes ? Icons.check_circle_outline : Icons.cancel_outlined,
            size: 16,
            color: passes ? c.accent : c.danger,
          ),
          const SizedBox(width: 6),
          Text(
            passes ? 'Passes validation' : 'Fails validation',
            style: TextStyle(
              fontSize: 12.5,
              color: passes ? c.accent : c.danger,
            ),
          ),
        ],
      ),
    );
  }
}

class _None extends StatelessWidget {
  const _None({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: TextStyle(color: context.colors.muted, fontSize: 12.5));
}
