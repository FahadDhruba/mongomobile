import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/codegen.dart';
import '../../theme/app_theme.dart';

/// Shows [generate]'s code for each language, with a copy button.
Future<void> showCodeExport(
  BuildContext context, {
  required String title,
  required String Function(CodeLanguage lang) generate,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => FractionallySizedBox(
    heightFactor: 0.85,
    child: CodeExportSheet(title: title, generate: generate),
  ),
);

class CodeExportSheet extends StatefulWidget {
  const CodeExportSheet({
    super.key,
    required this.title,
    required this.generate,
  });

  final String title;
  final String Function(CodeLanguage lang) generate;

  @override
  State<CodeExportSheet> createState() => _CodeExportSheetState();
}

class _CodeExportSheetState extends State<CodeExportSheet> {
  CodeLanguage _lang = CodeLanguage.python;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final code = widget.generate(_lang);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: code));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('${_lang.label} code copied')),
                  );
                },
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copy'),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final l in CodeLanguage.values)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(l.label),
                    selected: l == _lang,
                    selectedColor: c.accentStrong,
                    labelStyle: TextStyle(
                      color: l == _lang ? Colors.white : c.text,
                    ),
                    onSelected: (_) => setState(() => _lang = l),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Text(
            'Replace <connection string> with your URI. Uses the official '
            '${_lang == CodeLanguage.shell ? 'mongosh syntax' : '${_lang.label} driver'}.',
            style: TextStyle(color: c.muted, fontSize: 12),
          ),
        ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            decoration: BoxDecoration(
              color: c.background,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: c.border),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SelectableText(
                  code,
                  style: monoStyle(context, size: 12),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
