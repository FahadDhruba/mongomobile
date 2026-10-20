import 'package:flutter/material.dart';

import '../../models/connection_profile.dart';
import '../../theme/app_theme.dart';

/// Edits how a connection reaches its server: directly, through an SSH
/// tunnel or through a SOCKS5 proxy. Reports every change with [onChanged]
/// (null for a direct connection).
class TunnelEditor extends StatefulWidget {
  const TunnelEditor({super.key, this.initial, required this.onChanged});

  final TunnelSettings? initial;
  final ValueChanged<TunnelSettings?> onChanged;

  @override
  State<TunnelEditor> createState() => _TunnelEditorState();
}

class _TunnelEditorState extends State<TunnelEditor> {
  late TunnelKind? _kind = widget.initial?.kind;
  late final _host = TextEditingController(text: widget.initial?.host ?? '');
  late final _port = TextEditingController(
    text: widget.initial == null ? '' : '${widget.initial!.port}',
  );
  late final _user = TextEditingController(
    text: widget.initial?.username ?? '',
  );
  late final _password = TextEditingController(
    text: widget.initial?.password ?? '',
  );
  late final _key = TextEditingController(
    text: widget.initial?.privateKeyPem ?? '',
  );
  late final _passphrase = TextEditingController(
    text: widget.initial?.passphrase ?? '',
  );
  late String _hostKey = widget.initial?.hostKey ?? '';
  bool _show = false;

  @override
  void dispose() {
    for (final c in [_host, _port, _user, _password, _key, _passphrase]) {
      c.dispose();
    }
    super.dispose();
  }

  int get _defaultPort => _kind == TunnelKind.ssh ? 22 : 1080;

  void _changed() {
    final kind = _kind;
    widget.onChanged(
      kind == null
          ? null
          : TunnelSettings(
              kind: kind,
              host: _host.text.trim(),
              port: int.tryParse(_port.text.trim()) ?? _defaultPort,
              username: _user.text.trim(),
              password: _password.text,
              privateKeyPem: kind == TunnelKind.ssh ? _key.text.trim() : '',
              passphrase: kind == TunnelKind.ssh ? _passphrase.text : '',
              hostKey: kind == TunnelKind.ssh ? _hostKey : '',
            ),
    );
  }

  Widget _field(
    TextEditingController c,
    String label, {
    String? hint,
    bool obscure = false,
    bool number = false,
    int lines = 1,
    bool mono = true,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: c,
      autocorrect: false,
      enableSuggestions: false,
      obscureText: obscure && !_show,
      keyboardType: number ? TextInputType.number : null,
      minLines: lines > 1 ? 3 : 1,
      maxLines: lines,
      style: mono ? monoStyle(context, size: lines > 1 ? 11.5 : 13.5) : null,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        alignLabelWithHint: lines > 1,
        suffixIcon: obscure
            ? IconButton(
                tooltip: _show ? 'Hide' : 'Show',
                onPressed: () => setState(() => _show = !_show),
                icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
              )
            : null,
      ),
      onChanged: (_) => _changed(),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<TunnelKind?>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: null, label: Text('Direct')),
            ButtonSegment(value: TunnelKind.ssh, label: Text('SSH')),
            ButtonSegment(value: TunnelKind.socks5, label: Text('SOCKS5')),
          ],
          selected: {_kind},
          onSelectionChanged: (s) {
            setState(() => _kind = s.first);
            _changed();
          },
        ),
        const SizedBox(height: 12),
        if (_kind != null) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: _field(
                  _host,
                  _kind == TunnelKind.ssh ? 'SSH host' : 'Proxy host',
                  hint: _kind == TunnelKind.ssh ? 'bastion.example.com' : null,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _field(
                  _port,
                  'Port',
                  hint: '$_defaultPort',
                  number: true,
                ),
              ),
            ],
          ),
          _field(
            _user,
            _kind == TunnelKind.ssh ? 'SSH user' : 'Proxy user (optional)',
          ),
          _field(
            _password,
            _kind == TunnelKind.ssh
                ? 'SSH password (or use a key)'
                : 'Proxy password (optional)',
            obscure: true,
          ),
          if (_kind == TunnelKind.ssh) ...[
            _field(
              _key,
              'Private key (optional)',
              hint: '-----BEGIN OPENSSH PRIVATE KEY-----',
              lines: 6,
            ),
            _field(_passphrase, 'Key passphrase (optional)', obscure: true),
            if (_hostKey.isNotEmpty)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Host key: $_hostKey',
                      style: monoStyle(context, size: 11.5, color: c.muted),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      setState(() => _hostKey = '');
                      _changed();
                    },
                    child: const Text('Forget'),
                  ),
                ],
              )
            else
              Text(
                'The server\'s host key is saved on the first connection and '
                'checked after that.',
                style: TextStyle(color: c.muted, fontSize: 12),
              ),
          ],
          Text(
            'TLS still runs end to end and checks the database server\'s '
            'name.',
            style: TextStyle(color: c.muted, fontSize: 12),
          ),
        ],
      ],
    );
  }
}
