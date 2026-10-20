import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mongo_wire/mongo_wire.dart';

import '../../services/server_activity.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../widgets/common.dart';
import '../widgets/json_highlight.dart';

/// Live server activity, like Compass's Performance tab: charts from
/// `serverStatus`, current operations with a kill button, and slow queries
/// from the profiler.
class ServerActivityScreen extends ConsumerStatefulWidget {
  const ServerActivityScreen({super.key});

  @override
  ConsumerState<ServerActivityScreen> createState() =>
      _ServerActivityScreenState();
}

class _ServerActivityScreenState extends ConsumerState<ServerActivityScreen> {
  static const interval = Duration(seconds: 2);
  static const keep = 60;

  Timer? _timer;
  bool _paused = false;
  ServerSample? _last;
  final _rates = <ServerRates>[];
  final _connections = <int>[];
  final _memory = <int>[];
  String? _statusError;

  List<OperationInfo> _ops = const [];
  String? _opsError;
  bool _includeSystem = false;
  bool _opsLoaded = false;

  /// The server refused `allUsers`, so only the user's own operations show.
  bool _ownOnly = false;

  @override
  void initState() {
    super.initState();
    _tick();
    _timer = Timer.periodic(interval, (_) {
      if (!_paused) _tick();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _tick() async {
    await Future.wait([_sample(), _loadOps()]);
  }

  Future<void> _sample() async {
    try {
      final status = await ref.read(clientProvider).runCommand('admin', {
        'serverStatus': 1,
        'repl': 0,
        'metrics': 0,
        'locks': 0,
      }, maxTime: const Duration(seconds: 5));
      // The server's own clock makes the rates exact even when replies are
      // delayed.
      final at = status['localTime'];
      final sample = ServerSample.of(
        status,
        at is DateTime ? at : DateTime.now(),
      );
      if (!mounted) return;
      setState(() {
        _statusError = null;
        if (_last case final prev?) {
          if (ServerRates.between(prev, sample) case final r?) _rates.add(r);
        }
        _connections.add(sample.connections);
        _memory.add(sample.residentMb);
        for (final l in [_rates, _connections, _memory]) {
          if (l.length > keep) l.removeAt(0);
        }
        _last = sample;
      });
    } on Object catch (e) {
      if (mounted) setState(() => _statusError = describeError(e));
    }
  }

  Future<Map<String, dynamic>> _currentOp({required bool allUsers}) => ref
      .read(clientProvider)
      .runCommand(
        'admin',
        currentOpCommand(includeIdle: _includeSystem, allUsers: allUsers),
        maxTime: const Duration(seconds: 5),
      );

  Future<void> _loadOps() async {
    try {
      Map<String, dynamic> reply;
      try {
        reply = await _currentOp(allUsers: !_ownOnly);
      } on Object catch (e) {
        if (_ownOnly || !isAllUsersRestricted(e)) rethrow;
        _ownOnly = true;
        reply = await _currentOp(allUsers: false);
      }
      if (!mounted) return;
      setState(() {
        _ops = operationsOf(reply, includeSystem: _includeSystem);
        _opsError = null;
        _opsLoaded = true;
      });
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _opsError = describeError(e);
          _opsLoaded = true;
        });
      }
    }
  }

  Future<void> _kill(OperationInfo op) async {
    final messenger = ScaffoldMessenger.of(context);
    if (ref.read(readOnlyProvider)) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Turn on write mode to kill operations'),
          ),
        );
      return;
    }
    final ok = await confirmDialog(
      context,
      title: 'Kill operation ${op.opid}?',
      message:
          'This stops the ${op.op} on ${op.ns.isEmpty ? 'the server' : op.ns} '
          'that has run for ${formatElapsed(op.running)}. A write may be '
          'left partly done.',
      confirmLabel: 'Kill',
    );
    if (!ok) return;
    try {
      await ref.read(clientProvider).runCommand('admin', {
        'killOp': 1,
        'op': op.opid,
      });
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Operation ${op.opid} killed')));
      await _loadOps();
    } on Object catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(describeError(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Server activity'),
          actions: [
            IconButton(
              tooltip: _paused ? 'Resume' : 'Pause',
              onPressed: () => setState(() => _paused = !_paused),
              icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Overview'),
              Tab(text: 'Operations'),
              Tab(text: 'Slow queries'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _overview(context),
            _operations(context),
            const _SlowQueries(),
          ],
        ),
      ),
    );
  }

  Widget _overview(BuildContext context) {
    final c = context.colors;
    final latest = _rates.lastOrNull;
    final last = _last;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (_statusError case final e?) ...[
          MessageBanner(message: e),
          const SizedBox(height: 12),
        ],
        Text(
          _paused
              ? 'Paused'
              : 'Updates every ${interval.inSeconds} s · last ${keep * interval.inSeconds ~/ 60} minutes',
          style: TextStyle(color: c.muted, fontSize: 12),
        ),
        const SizedBox(height: 8),
        _ChartCard(
          title: 'Operations per second',
          value: latest == null ? '—' : _rate(latest.totalOps),
          values: [for (final r in _rates) r.totalOps],
          color: c.accent,
          footer: latest == null
              ? null
              : [
                  for (final k in ServerSample.opKinds)
                    '$k ${_rate(latest.ops[k] ?? 0)}',
                ].join(' · '),
        ),
        _ChartCard(
          title: 'Connections',
          value: last == null ? '—' : groupDigits(last.connections),
          values: [for (final n in _connections) n.toDouble()],
          color: c.number,
          footer: last == null
              ? null
              : '${groupDigits(last.availableConnections)} available',
        ),
        _ChartCard(
          title: 'Network in',
          value: latest == null
              ? '—'
              : '${formatBytes(latest.bytesIn.round())}/s',
          values: [for (final r in _rates) r.bytesIn],
          color: c.date,
        ),
        _ChartCard(
          title: 'Network out',
          value: latest == null
              ? '—'
              : '${formatBytes(latest.bytesOut.round())}/s',
          values: [for (final r in _rates) r.bytesOut],
          color: c.objectId,
        ),
        _ChartCard(
          title: 'Memory (resident)',
          value: last == null ? '—' : '${groupDigits(last.residentMb)} MB',
          values: [for (final n in _memory) n.toDouble()],
          color: c.string,
        ),
      ],
    );
  }

  static String _rate(double v) =>
      v >= 100 ? groupDigits(v.round()) : v.toStringAsFixed(v < 10 ? 1 : 0);

  Widget _operations(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _opsLoaded
                      ? '${_ops.length} running operation${_ops.length == 1 ? '' : 's'}'
                      : 'Loading…',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              FilterChip(
                label: const Text('System and idle'),
                selected: _includeSystem,
                onSelected: (v) {
                  setState(() => _includeSystem = v);
                  _loadOps();
                },
              ),
            ],
          ),
        ),
        if (_ownOnly)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Text(
              'This server only shows your own operations (Atlas shared and '
              "Flex tiers don't allow seeing other users').",
              style: TextStyle(color: c.muted, fontSize: 12),
            ),
          ),
        Expanded(
          child: _opsError != null
              ? ListView(
                  padding: const EdgeInsets.all(12),
                  children: [MessageBanner(message: _opsError!)],
                )
              : _ops.isEmpty && _opsLoaded
              ? ListView(
                  children: const [
                    EmptyState(
                      icon: Icons.check_circle_outline,
                      title: 'Nothing running',
                      message: 'No client operations are in progress.',
                    ),
                  ],
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                  itemCount: _ops.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, i) => _OperationCard(
                    op: _ops[i],
                    onKill: () => _kill(_ops[i]),
                    color: c.danger,
                  ),
                ),
        ),
      ],
    );
  }
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({
    required this.title,
    required this.value,
    required this.values,
    required this.color,
    this.footer,
  });

  final String title;
  final String value;
  final List<double> values;
  final Color color;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title, style: TextStyle(color: c.muted)),
                ),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 56,
              child: CustomPaint(
                painter: _SparklinePainter(values, color, c.border),
              ),
            ),
            if (footer case final f?) ...[
              const SizedBox(height: 6),
              Text(f, style: TextStyle(color: c.muted, fontSize: 11.5)),
            ],
          ],
        ),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter(this.values, this.color, this.grid);

  final List<double> values;
  final Color color;
  final Color grid;

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, size.height - 0.5),
      Offset(size.width, size.height - 0.5),
      gridPaint,
    );
    if (values.length < 2) return;
    final max = math.max(values.reduce(math.max), 1e-9);
    final step = size.width / (_ServerActivityScreenState.keep - 1);
    final start = size.width - step * (values.length - 1);
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = start + step * i;
      final y = size.height - (values[i] / max) * (size.height - 4) - 2;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(start, size.height)
      ..close();
    canvas.drawPath(fill, Paint()..color = color.withValues(alpha: 0.15));
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.values != values || old.color != color;
}

class _OperationCard extends StatelessWidget {
  const _OperationCard({
    required this.op,
    required this.onKill,
    required this.color,
  });

  final OperationInfo op;
  final VoidCallback onKill;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final command = op.command;
    final meta = [
      'opid ${op.opid}',
      if (op.client != null) op.client!,
      if (op.appName != null && op.appName!.isNotEmpty) op.appName!,
      if (op.user != null) op.user!,
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 4, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Pill(
                        op.op.isEmpty ? 'op' : op.op.toUpperCase(),
                        color: c.accent,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          op.ns.isEmpty ? op.desc : op.ns,
                          overflow: TextOverflow.ellipsis,
                          style: monoStyle(
                            context,
                            size: 13,
                            weight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Text(
                        formatElapsed(op.running),
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: op.running > const Duration(seconds: 10)
                              ? c.warning
                              : c.text,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    meta.join(' · '),
                    style: TextStyle(color: c.muted, fontSize: 12),
                  ),
                  if (op.planSummary != null || op.waitingForLock) ...[
                    const SizedBox(height: 4),
                    Text(
                      [
                        ?op.planSummary,
                        if (op.waitingForLock) 'waiting for a lock',
                      ].join(' · '),
                      style: TextStyle(
                        color: op.planSummary?.startsWith('COLLSCAN') ?? false
                            ? c.warning
                            : c.muted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  if (command != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      shellDocument(command),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: monoStyle(context, size: 11.5, color: c.muted),
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              tooltip: 'Kill operation',
              onPressed: onKill,
              icon: Icon(Icons.stop_circle_outlined, color: color),
            ),
          ],
        ),
      ),
    );
  }
}

/// Slow queries from a database's profiler (`system.profile`).
class _SlowQueries extends ConsumerStatefulWidget {
  const _SlowQueries();

  @override
  ConsumerState<_SlowQueries> createState() => _SlowQueriesState();
}

class _SlowQueriesState extends ConsumerState<_SlowQueries>
    with AutomaticKeepAliveClientMixin {
  String? _db;
  int? _level;
  int? _slowMs;
  List<ProfileEntry>? _entries;
  String? _error;
  bool _restricted = false;
  bool _loading = false;

  @override
  bool get wantKeepAlive => true;

  Future<void> _load() async {
    final db = _db;
    if (db == null) return;
    setState(() {
      _loading = true;
      _error = null;
      _restricted = false;
    });
    final client = ref.read(clientProvider);
    try {
      final status = await client.runCommand(db, {'profile': -1});
      final r = await client.find(
        Namespace(db, 'system.profile'),
        FindRequest(
          sort: const {'ts': -1},
          limit: 50,
          maxTime: ref.read(settingsProvider).queryTimeout,
          maxBytes: 16 << 20,
        ),
      );
      if (!mounted || db != _db) return;
      setState(() {
        _level = (status['was'] as num?)?.toInt();
        _slowMs = (status['slowms'] as num?)?.toInt();
        _entries = [for (final d in r.documents) ProfileEntry(d)];
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        if (isCommandRestricted(e)) {
          _restricted = true;
        } else {
          _error = describeError(e);
        }
        _loading = false;
      });
    }
  }

  Future<void> _changeLevel() async {
    final messenger = ScaffoldMessenger.of(context);
    if (ref.read(readOnlyProvider)) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Turn on write mode to change the profiler'),
          ),
        );
      return;
    }
    final result = await showDialog<(int, int)>(
      context: context,
      builder: (_) =>
          _ProfilerDialog(level: _level ?? 0, slowMs: _slowMs ?? 100),
    );
    if (result == null || _db == null) return;
    try {
      await ref.read(clientProvider).runCommand(_db!, {
        'profile': result.$1,
        'slowms': result.$2,
      });
      await _load();
    } on Object catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(describeError(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final c = context.colors;
    final dbs = [
      for (final d in ref.watch(databasesProvider).value ?? const [])
        if (!const {'admin', 'local', 'config'}.contains(d.name)) d,
    ];
    final entries = _entries;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Row(
          children: [
            const Text('Database'),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButton<String>(
                isExpanded: true,
                value: _db,
                hint: const Text('Choose a database'),
                items: [
                  for (final d in dbs)
                    DropdownMenuItem(value: d.name, child: Text(d.name)),
                ],
                onChanged: (v) {
                  setState(() {
                    _db = v;
                    _entries = null;
                    _level = null;
                  });
                  _load();
                },
              ),
            ),
            IconButton(
              tooltip: 'Refresh',
              onPressed: _db == null || _loading ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        if (_loading) const LinearProgressIndicator(),
        if (_error case final e?) ...[
          const SizedBox(height: 8),
          MessageBanner(message: e),
        ],
        if (_level case final level?) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(switch (level) {
                  0 => 'The profiler is off for this database.',
                  1 => 'Profiling operations slower than ${_slowMs ?? 100} ms.',
                  _ => 'Profiling every operation.',
                }, style: TextStyle(color: c.muted, fontSize: 12.5)),
              ),
              TextButton(onPressed: _changeLevel, child: const Text('Change')),
            ],
          ),
        ],
        if (_restricted)
          const EmptyState(
            icon: Icons.speed,
            title: "The profiler isn't available",
            message:
                "This server doesn't let this user read or change the "
                'database profiler. Atlas shared and Flex tiers don\'t allow '
                'it; on a dedicated cluster it needs a user with the dbAdmin '
                'role. In Atlas, the Query Profiler and Performance Advisor in '
                'the Atlas web UI show slow queries.',
          )
        else if (_db == null)
          const EmptyState(
            icon: Icons.speed,
            title: 'Slow queries',
            message:
                'Choose a database to see the latest operations its profiler '
                'recorded.',
          )
        else if (entries != null && entries.isEmpty)
          EmptyState(
            icon: Icons.speed,
            title: 'No profiled operations',
            message: _level == 0
                ? 'Turn the profiler on to record slow operations.'
                : 'Nothing slow has run since profiling started.',
          )
        else if (entries != null)
          for (final e in entries) _ProfileCard(entry: e),
      ],
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.entry});
  final ProfileEntry entry;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final ts = entry.ts;
    final command = entry.command;
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Pill(entry.op.toUpperCase(), color: c.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    entry.ns,
                    overflow: TextOverflow.ellipsis,
                    style: monoStyle(
                      context,
                      size: 13,
                      weight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  '${groupDigits(entry.millis)} ms',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              [
                if (ts != null)
                  formatIsoDate(ts.toUtc()).replaceFirst('.000', ''),
                ?entry.planSummary,
                if (entry.docsExamined != null)
                  '${groupDigits(entry.docsExamined!)} docs examined',
                if (entry.keysExamined != null)
                  '${groupDigits(entry.keysExamined!)} keys',
                if (entry.returned != null)
                  '${groupDigits(entry.returned!)} returned',
              ].join(' · '),
              style: TextStyle(
                color: entry.collectionScan ? c.warning : c.muted,
                fontSize: 12,
              ),
            ),
            if (command != null) ...[
              const SizedBox(height: 6),
              Text(
                shellDocument(command),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: monoStyle(context, size: 11.5, color: c.muted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ProfilerDialog extends StatefulWidget {
  const _ProfilerDialog({required this.level, required this.slowMs});
  final int level;
  final int slowMs;

  @override
  State<_ProfilerDialog> createState() => _ProfilerDialogState();
}

class _ProfilerDialogState extends State<_ProfilerDialog> {
  late int _level = widget.level;
  late final _slow = TextEditingController(text: '${widget.slowMs}');

  @override
  void dispose() {
    _slow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final slow = int.tryParse(_slow.text.trim());
    return AlertDialog(
      title: const Text('Profiler'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RadioGroup<int>(
            groupValue: _level,
            onChanged: (v) => setState(() => _level = v!),
            child: Column(
              children: [
                for (final (level, label) in const [
                  (0, 'Off'),
                  (1, 'Slow operations only'),
                  (2, 'Every operation (heavy)'),
                ])
                  RadioListTile<int>(
                    contentPadding: EdgeInsets.zero,
                    value: level,
                    title: Text(label),
                  ),
              ],
            ),
          ),
          TextField(
            controller: _slow,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Slow threshold (ms)'),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: slow == null || slow < 0
              ? null
              : () => Navigator.pop(context, (_level, slow)),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
