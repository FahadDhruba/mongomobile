import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mongo_wire/mongo_wire.dart';

import '../../models/connection_profile.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../widgets/common.dart';

/// Create or edit a saved connection, with a Test button.
class ConnectionEditScreen extends ConsumerStatefulWidget {
  const ConnectionEditScreen({super.key, this.profile});
  final ConnectionProfile? profile;

  @override
  ConsumerState<ConnectionEditScreen> createState() =>
      _ConnectionEditScreenState();
}

class _ConnectionEditScreenState extends ConsumerState<ConnectionEditScreen> {
  late final _name = TextEditingController(text: widget.profile?.name ?? '');
  late final _uri = TextEditingController(
      text: widget.profile?.uri ?? 'mongodb://localhost:27017');
  late final _ca =
      TextEditingController(text: widget.profile?.caCertificatePem ?? '');
  late bool _allowInvalid = widget.profile?.allowInvalidCertificates ?? false;
  late int _color = widget.profile?.colorIndex ?? 0;
  bool _showUri = false;
  bool _testing = false;
  String? _uriError;
  _TestResult? _result;

  @override
  void initState() {
    super.initState();
    _showUri = widget.profile == null;
  }

  @override
  void dispose() {
    _name.dispose();
    _uri.dispose();
    _ca.dispose();
    super.dispose();
  }

  bool _validate() {
    try {
      ConnectionString.parse(_uri.text);
      setState(() => _uriError = null);
      return true;
    } on MongoException catch (e) {
      setState(() => _uriError = e.message);
      return false;
    }
  }

  ConnectionProfile _profile() => ConnectionProfile(
        id: widget.profile?.id ?? ConnectionProfile.newId(),
        name: _name.text.trim(),
        uri: _uri.text.trim(),
        allowInvalidCertificates: _allowInvalid,
        caCertificatePem: _ca.text.trim().isEmpty ? null : _ca.text.trim(),
        colorIndex: _color,
        lastUsed: widget.profile?.lastUsed,
      );

  Future<void> _test() async {
    if (!_validate()) return;
    setState(() {
      _testing = true;
      _result = null;
    });
    final p = _profile();
    final sw = Stopwatch()..start();
    MongoClient? client;
    try {
      client = await ref.read(connectorProvider).connect(p.uri, p.connectOptions);
      final s = client.server;
      final dbs = await client.listDatabases();
      setState(() => _result = _TestResult.ok(
          'Connected in ${formatDuration(sw.elapsed)}\n'
          '${s.address} · MongoDB ${s.version}\n'
          '${s.kind}${s.setName != null ? ' (${s.setName})' : ''}\n'
          '${dbs.length} database${dbs.length == 1 ? '' : 's'} visible'));
    } on Object catch (e) {
      setState(() => _result = _TestResult.failed(describeError(e)));
    } finally {
      await client?.close();
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    if (!_validate()) return;
    await ref.read(connectionsProvider.notifier).upsert(_profile());
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.profile == null ? 'New connection' : 'Edit connection'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                  labelText: 'Name', hintText: 'e.g. Production cluster'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _uri,
              style: monoStyle(context, size: 13),
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.url,
              obscureText: !_showUri,
              maxLines: _showUri ? 4 : 1,
              minLines: 1,
              onChanged: (_) {
                if (_uriError != null) _validate();
              },
              decoration: InputDecoration(
                labelText: 'Connection string',
                hintText: 'mongodb+srv://user:password@cluster.example.net/',
                errorText: _uriError,
                errorMaxLines: 3,
                suffixIcon: IconButton(
                  tooltip: _showUri ? 'Hide' : 'Show',
                  icon: Icon(_showUri ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _showUri = !_showUri),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'mongodb:// and mongodb+srv:// are supported, with TLS, '
              'SCRAM-SHA-256 and SCRAM-SHA-1. Encode special characters in the '
              'password, e.g. @ as %40.',
              style: TextStyle(color: c.muted, fontSize: 12),
            ),
            const SizedBox(height: 16),
            Text('Colour', style: TextStyle(color: c.muted, fontSize: 12.5)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              children: [
                for (var i = 0; i < connectionColors.length; i++)
                  InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => setState(() => _color = i),
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: connectionColors[i],
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: i == _color ? c.text : Colors.transparent,
                            width: 2),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Advanced TLS'),
                initiallyExpanded: _allowInvalid || _ca.text.isNotEmpty,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Allow invalid certificates'),
                    subtitle: const Text(
                        'Accept self-signed or mismatched certificates. Only '
                        'for servers you trust.'),
                    value: _allowInvalid,
                    onChanged: (v) => setState(() => _allowInvalid = v),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _ca,
                    style: monoStyle(context, size: 11.5),
                    maxLines: 6,
                    minLines: 3,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'CA certificate (PEM, optional)',
                      hintText: '-----BEGIN CERTIFICATE-----',
                      alignLabelWithHint: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
            if (_result != null) ...[
              const SizedBox(height: 8),
              MessageBanner(
                message: _result!.message,
                kind: _result!.ok ? BannerKind.info : BannerKind.error,
              ),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _testing ? null : _test,
                    style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 46)),
                    icon: _testing
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: c.accent))
                        : const Icon(Icons.network_check, size: 18),
                    label: Text(_testing ? 'Testing…' : 'Test connection'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: AccentButton(label: 'Save', onPressed: _save),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TestResult {
  _TestResult.ok(this.message) : ok = true;
  _TestResult.failed(this.message) : ok = false;
  final bool ok;
  final String message;
}
