import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/shell.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';

/// Entered commands per connection, kept while the app runs.
final _histories = <String, List<String>>{};

/// The built-in shell: type mongosh-style commands and see the replies.
class ShellScreen extends ConsumerStatefulWidget {
  const ShellScreen({super.key, this.db});

  /// The database to start in; `test` when null, as in mongosh.
  final String? db;

  @override
  ConsumerState<ShellScreen> createState() => _ShellScreenState();
}

class _ShellEntry {
  const _ShellEntry(this.text, this.kind, [this.db]);
  final String text;
  final ShellTextKind kind;
  final String? db;
}

class _ShellScreenState extends ConsumerState<ShellScreen> {
  late final ShellSession _shell = ShellSession(
    client: ref.read(clientProvider),
    db: widget.db ?? 'test',
    canWrite: () => !ref.read(readOnlyProvider),
  );
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final _entries = <_ShellEntry>[];
  bool _running = false;
  int? _historyIndex;

  late final List<String> _history = _histories.putIfAbsent(
    ref.read(sessionProvider)?.profile.id ?? '',
    () => [],
  );

  @override
  void initState() {
    super.initState();
    _entries.add(
      _ShellEntry(
        'Connected to ${ref.read(clientProvider).server.address} '
        '(MongoDB ${ref.read(clientProvider).server.version}). Type help '
        'for the commands.',
        ShellTextKind.info,
      ),
    );
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _run([String? command]) async {
    final text = (command ?? _input.text).trim();
    if (text.isEmpty || _running) return;
    if (text == 'cls' || text == 'clear') {
      setState(() {
        _entries.clear();
        _input.clear();
      });
      return;
    }
    if (_history.isEmpty || _history.last != text) {
      _history.add(text);
      if (_history.length > 100) _history.removeAt(0);
    }
    _historyIndex = null;
    setState(() {
      _entries.add(_ShellEntry(text, ShellTextKind.input, _shell.db));
      _running = true;
      if (command == null) _input.clear();
    });
    _toBottom();
    try {
      final out = await _shell.run(text);
      if (!mounted) return;
      setState(() {
        if (out.isNotEmpty) {
          _entries.add(_ShellEntry(out, ShellTextKind.result));
        }
      });
    } on ShellError catch (e) {
      if (mounted) {
        setState(
          () => _entries.add(_ShellEntry(e.message, ShellTextKind.error)),
        );
      }
    } on Object catch (e) {
      if (mounted) {
        setState(
          () =>
              _entries.add(_ShellEntry(describeError(e), ShellTextKind.error)),
        );
      }
    } finally {
      if (mounted) setState(() => _running = false);
      _toBottom();
      _focus.requestFocus();
    }
  }

  void _recall(int step) {
    if (_history.isEmpty) return;
    final i = ((_historyIndex ?? _history.length) + step).clamp(
      0,
      _history.length,
    );
    setState(() {
      _historyIndex = i;
      _input.text = i == _history.length ? '' : _history[i];
      _input.selection = TextSelection.collapsed(offset: _input.text.length);
    });
  }

  void _insert(String snippet) {
    final sel = _input.selection;
    final text = _input.text;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    // A pair like "()" puts the cursor between the brackets.
    final back = switch (snippet) {
      _ when snippet.endsWith('()') || snippet == "''" => 1,
      '{  }' || '[  ]' => 2,
      _ => 0,
    };
    final caret = start + snippet.length - back;
    _input.value = TextEditingValue(
      text: text.replaceRange(start, end, snippet),
      selection: TextSelection.collapsed(offset: caret),
    );
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final mono = monoStyle(context, size: 12.5);
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Shell'),
            Text(_shell.db, style: TextStyle(fontSize: 12, color: c.muted)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Help',
            onPressed: () => _run('help'),
            icon: const Icon(Icons.help_outline),
          ),
          IconButton(
            tooltip: 'Clear',
            onPressed: () => setState(_entries.clear),
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Container(
                color: c.card,
                child: ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  itemCount: _entries.length,
                  itemBuilder: (_, i) {
                    final e = _entries[i];
                    return Padding(
                      padding: EdgeInsets.only(
                        top: e.kind == ShellTextKind.input && i > 0 ? 10 : 2,
                      ),
                      child: SelectableText(
                        e.kind == ShellTextKind.input
                            ? '${e.db}> ${e.text}'
                            : e.text,
                        style: mono.copyWith(
                          color: switch (e.kind) {
                            ShellTextKind.input => c.accent,
                            ShellTextKind.error => c.danger,
                            ShellTextKind.info => c.muted,
                            ShellTextKind.result => c.text,
                          },
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            if (_running)
              LinearProgressIndicator(
                minHeight: 2,
                color: c.accent,
                backgroundColor: c.border,
              ),
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                children: [
                  for (final s in const [
                    'db.',
                    '.find()',
                    '{  }',
                    '[  ]',
                    r'$',
                    ': ',
                    "''",
                    '.limit()',
                    '.sort()',
                    '.aggregate()',
                    'show collections',
                    'it',
                  ])
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ActionChip(
                        visualDensity: VisualDensity.compact,
                        label: Text(s, style: mono),
                        onPressed: () => s == 'it' || s == 'show collections'
                            ? _run(s)
                            : _insert(s),
                      ),
                    ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(8, 4, 4, 8),
              decoration: BoxDecoration(
                color: c.panel,
                border: Border(top: BorderSide(color: c.border)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    tooltip: 'Previous command',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _recall(-1),
                    icon: const Icon(Icons.keyboard_arrow_up),
                  ),
                  IconButton(
                    tooltip: 'Next command',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _recall(1),
                    icon: const Icon(Icons.keyboard_arrow_down),
                  ),
                  Expanded(
                    child: CallbackShortcuts(
                      bindings: {
                        const SingleActivator(LogicalKeyboardKey.enter): _run,
                        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                            _recall(-1),
                        const SingleActivator(
                          LogicalKeyboardKey.arrowDown,
                        ): () =>
                            _recall(1),
                      },
                      child: TextField(
                        controller: _input,
                        focusNode: _focus,
                        autofocus: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        minLines: 1,
                        maxLines: 5,
                        keyboardType: TextInputType.visiblePassword,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _run(),
                        style: mono,
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: 'db.collection.find()',
                          prefixText: '${_shell.db}> ',
                          prefixStyle: mono.copyWith(color: c.accent),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Run',
                    onPressed: _running ? null : _run,
                    icon: Icon(Icons.send, color: c.accent),
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

/// Opens the shell in [db].
void openShell(BuildContext context, {String? db}) => Navigator.push(
  context,
  MaterialPageRoute(builder: (_) => ShellScreen(db: db)),
);
