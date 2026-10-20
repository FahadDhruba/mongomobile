import 'package:flutter/material.dart';

import '../../services/connection_form.dart';
import '../../theme/app_theme.dart';

/// Edits a [ConnectionForm] in place: hosts, authentication, TLS and the
/// common options. Calls [onChanged] after every edit.
class ConnectionFormView extends StatefulWidget {
  const ConnectionFormView({
    super.key,
    required this.form,
    required this.onChanged,
  });

  final ConnectionForm form;
  final VoidCallback onChanged;

  @override
  State<ConnectionFormView> createState() => _ConnectionFormViewState();
}

class _ConnectionFormViewState extends State<ConnectionFormView> {
  ConnectionForm get f => widget.form;
  bool _showPassword = false;

  void _set(VoidCallback change) {
    setState(change);
    widget.onChanged();
  }

  Widget _text(
    String label,
    String value,
    ValueChanged<String> onChanged, {
    String? hint,
    bool mono = true,
    bool number = false,
    bool obscure = false,
    Widget? suffix,
    Key? key,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      key: key,
      initialValue: value,
      autocorrect: false,
      enableSuggestions: false,
      obscureText: obscure,
      keyboardType: number ? TextInputType.number : null,
      style: mono ? monoStyle(context, size: 13.5) : null,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        suffixIcon: suffix,
      ),
      onChanged: (v) => _set(() => onChanged(v)),
    ),
  );

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 10),
    child: Text(
      title,
      style: TextStyle(
        color: context.colors.muted,
        fontWeight: FontWeight.w700,
        fontSize: 12.5,
      ),
    ),
  );

  Widget _dropdown<T>(
    String label,
    T value,
    Map<T, String> options,
    ValueChanged<T> onChanged,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: DropdownButtonFormField<T>(
      initialValue: value,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final MapEntry(:key, :value) in options.entries)
          DropdownMenuItem(value: key, child: Text(value)),
      ],
      onChanged: (v) => _set(() => onChanged(v as T)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section('GENERAL'),
        SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: false, label: Text('mongodb')),
            ButtonSegment(value: true, label: Text('mongodb+srv')),
          ],
          selected: {f.srv},
          onSelectionChanged: (s) => _set(() {
            f.srv = s.first;
            if (f.srv) {
              f.hosts = [f.hosts.first.split(':').first];
              f.directConnection = false;
            }
          }),
        ),
        const SizedBox(height: 6),
        Text(
          f.srv
              ? 'One host name; the server list comes from DNS and TLS is on '
                    'by default.'
              : 'One host for a single server, or several for a replica set.',
          style: TextStyle(color: c.muted, fontSize: 12),
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < f.hosts.length; i++)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _text(
                  f.srv ? 'Host name' : 'Host ${i + 1}',
                  f.hosts[i],
                  (v) => f.hosts[i] = v,
                  hint: f.srv
                      ? 'cluster0.abcde.mongodb.net'
                      : 'localhost:27017',
                  key: ValueKey(('host', i, f.hosts.length, f.srv)),
                ),
              ),
              if (f.hosts.length > 1)
                IconButton(
                  tooltip: 'Remove host',
                  onPressed: () => _set(() => f.hosts.removeAt(i)),
                  icon: Icon(Icons.remove_circle_outline, color: c.muted),
                ),
            ],
          ),
        if (!f.srv)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _set(() {
                f.hosts.add('');
                f.directConnection = false;
              }),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add host'),
            ),
          ),
        if (!f.srv && f.hosts.length == 1)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Direct connection'),
            subtitle: const Text(
              'Talk to this server only, even if it is a replica set member',
            ),
            value: f.directConnection,
            onChanged: (v) => _set(() => f.directConnection = v),
          ),
        _section('AUTHENTICATION'),
        _dropdown('Method', f.auth, {
          for (final m in AuthMethod.values) m: m.label,
        }, (v) => f.auth = v),
        if (f.auth != AuthMethod.none) ...[
          _text('Username', f.username, (v) => f.username = v),
          _text(
            'Password',
            f.password,
            (v) => f.password = v,
            obscure: !_showPassword,
            suffix: IconButton(
              tooltip: _showPassword ? 'Hide' : 'Show',
              onPressed: () => setState(() => _showPassword = !_showPassword),
              icon: Icon(
                _showPassword ? Icons.visibility_off : Icons.visibility,
              ),
            ),
          ),
          _text(
            'Authentication database',
            f.authSource,
            (v) => f.authSource = v,
            hint: f.auth == AuthMethod.ldap
                ? r'$external'
                : 'admin, or the default database',
          ),
          if (f.auth == AuthMethod.password)
            _dropdown('Mechanism', f.mechanism, {
              for (final m in ConnectionForm.mechanisms)
                m: m.isEmpty ? 'Default (the server picks)' : m,
            }, (v) => f.mechanism = v),
        ],
        _section('TLS'),
        _dropdown('TLS', f.tls, const {
          TlsMode.auto: 'Default (on for mongodb+srv)',
          TlsMode.on: 'On',
          TlsMode.off: 'Off',
        }, (v) => f.tls = v),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Allow invalid certificates'),
          value: f.allowInvalidCertificates,
          onChanged: (v) => _set(() => f.allowInvalidCertificates = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Allow invalid host names'),
          value: f.allowInvalidHostnames,
          onChanged: (v) => _set(() => f.allowInvalidHostnames = v),
        ),
        _section('ADVANCED'),
        _text(
          'Default database',
          f.database,
          (v) => f.database = v,
          hint: 'Opened first; also the default auth database',
        ),
        _text('Replica set name', f.replicaSet, (v) => f.replicaSet = v),
        _dropdown('Read preference', f.readPreference, {
          for (final p in ConnectionForm.readPreferences)
            p: p.isEmpty ? 'Default (primary)' : p,
          if (!ConnectionForm.readPreferences.contains(f.readPreference))
            f.readPreference: f.readPreference,
        }, (v) => f.readPreference = v),
        _text(
          'App name',
          f.appName,
          (v) => f.appName = v,
          hint: 'Shown in server logs',
          mono: false,
        ),
        _text(
          'Connect timeout (ms)',
          f.connectTimeoutMs,
          (v) => f.connectTimeoutMs = v,
          hint: '10000',
          number: true,
        ),
        _text(
          'Server selection timeout (ms)',
          f.serverSelectionTimeoutMs,
          (v) => f.serverSelectionTimeoutMs = v,
          hint: '20000',
          number: true,
        ),
        if (f.otherOptions.isNotEmpty) ...[
          Text(
            'Other options',
            style: TextStyle(color: c.muted, fontSize: 12.5),
          ),
          const SizedBox(height: 6),
          for (final MapEntry(:key, :value) in f.otherOptions.entries.toList())
            Row(
              children: [
                Expanded(
                  child: Text(
                    '$key=$value',
                    style: monoStyle(context, size: 12.5),
                  ),
                ),
                IconButton(
                  tooltip: 'Remove $key',
                  onPressed: () => _set(() => f.otherOptions.remove(key)),
                  icon: Icon(Icons.close, size: 18, color: c.muted),
                ),
              ],
            ),
          Text(
            'Edit these in the connection string.',
            style: TextStyle(color: c.muted, fontSize: 12),
          ),
        ],
      ],
    );
  }
}
