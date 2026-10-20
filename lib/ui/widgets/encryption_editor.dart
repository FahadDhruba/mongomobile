import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/connection_profile.dart';
import '../../theme/app_theme.dart';

/// Edits a connection's client-side field level encryption: the key vault
/// and the master keys. Reports changes with [onChanged] (null when off).
class EncryptionEditor extends StatefulWidget {
  const EncryptionEditor({super.key, this.initial, required this.onChanged});

  final EncryptionSettings? initial;
  final ValueChanged<EncryptionSettings?> onChanged;

  @override
  State<EncryptionEditor> createState() => _EncryptionEditorState();
}

class _EncryptionEditorState extends State<EncryptionEditor> {
  late bool _on = widget.initial != null;
  late final _vault = TextEditingController(
    text: widget.initial?.keyVault ?? 'encryption.__keyVault',
  );
  late final _local = TextEditingController(
    text: widget.initial?.localKey ?? '',
  );
  late final _awsKey = TextEditingController(
    text: widget.initial?.awsAccessKeyId ?? '',
  );
  late final _awsSecret = TextEditingController(
    text: widget.initial?.awsSecretAccessKey ?? '',
  );
  late final _awsToken = TextEditingController(
    text: widget.initial?.awsSessionToken ?? '',
  );
  bool _show = false;

  @override
  void dispose() {
    for (final c in [_vault, _local, _awsKey, _awsSecret, _awsToken]) {
      c.dispose();
    }
    super.dispose();
  }

  EncryptionSettings get _settings => EncryptionSettings(
    keyVault: _vault.text.trim(),
    localKey: _local.text.trim(),
    awsAccessKeyId: _awsKey.text.trim(),
    awsSecretAccessKey: _awsSecret.text.trim(),
    awsSessionToken: _awsToken.text.trim(),
  );

  void _changed() {
    setState(() {});
    widget.onChanged(_on ? _settings : null);
  }

  void _generate() {
    final r = Random.secure();
    _local.text = base64.encode(List.generate(96, (_) => r.nextInt(256)));
    Clipboard.setData(ClipboardData(text: _local.text));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text(
            'New master key copied. Keep a copy somewhere safe: data '
            'encrypted with keys under it cannot be read without it.',
          ),
        ),
      );
    _changed();
  }

  Widget _field(
    TextEditingController c,
    String label, {
    String? hint,
    bool secret = false,
    Widget? extra,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: c,
      autocorrect: false,
      enableSuggestions: false,
      obscureText: secret && !_show,
      style: monoStyle(context, size: 13),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        suffixIcon: secret
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ?extra,
                  IconButton(
                    tooltip: _show ? 'Hide' : 'Show',
                    onPressed: () => setState(() => _show = !_show),
                    icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
                  ),
                ],
              )
            : null,
      ),
      onChanged: (_) => _changed(),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final error = _on ? _settings.error : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Decrypt encrypted fields'),
          subtitle: const Text(
            'Client-side field level encryption with local or AWS KMS keys',
          ),
          value: _on,
          onChanged: (v) {
            _on = v;
            _changed();
          },
        ),
        if (_on) ...[
          _field(_vault, 'Key vault', hint: 'encryption.__keyVault'),
          _field(
            _local,
            'Local master key (base64, optional)',
            hint: '96 bytes',
            secret: true,
            extra: IconButton(
              tooltip: 'Generate a new key',
              onPressed: _generate,
              icon: const Icon(Icons.auto_fix_high),
            ),
          ),
          _field(_awsKey, 'AWS access key ID (optional)'),
          _field(_awsSecret, 'AWS secret access key', secret: true),
          _field(_awsToken, 'AWS session token (optional)', secret: true),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                error,
                style: TextStyle(color: c.danger, fontSize: 12.5),
              ),
            ),
          Text(
            'Encrypted values are decrypted on the phone for viewing and '
            'editing, and encrypted again with the same key when saved. '
            'Queryable Encryption fields are shown as they are stored.',
            style: TextStyle(color: c.muted, fontSize: 12),
          ),
        ],
      ],
    );
  }
}
