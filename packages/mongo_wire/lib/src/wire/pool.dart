import 'dart:async';
import 'dart:collection';

import '../cancel.dart';
import '../errors.dart';
import 'connection.dart';
import 'connection_string.dart';
import 'handshake.dart';

/// A small pool of authenticated connections to one server.
///
/// Separate connections let a slow count run next to the page query, and
/// let a cancelled request drop its socket without affecting others.
class ConnectionPool {
  ConnectionPool({
    required this.address,
    required this.tls,
    required this.handshakeOptions,
    this.maxSize = 4,
    this.connectTimeout = const Duration(seconds: 10),
  });

  final HostAddress address;
  final TlsOptions tls;
  final HandshakeOptions handshakeOptions;
  final int maxSize;
  final Duration connectTimeout;

  final List<WireConnection> _idle = [];
  final Queue<Completer<WireConnection>> _waiters = Queue();
  int _open = 0;
  bool _closed = false;

  ServerDescription? lastDescription;

  /// Opens one connection right away, so connection errors surface early.
  Future<ServerDescription> prime() async {
    final conn = await _create();
    release(conn);
    return lastDescription!;
  }

  Future<WireConnection> _create() async {
    _open++;
    try {
      final conn = await WireConnection.open(
        address,
        tls: tls,
        timeout: connectTimeout,
      );
      try {
        lastDescription = await handshake(
          conn,
          handshakeOptions,
          timeout: connectTimeout,
        );
      } catch (_) {
        conn.close();
        rethrow;
      }
      return conn;
    } catch (_) {
      _open--;
      _serveWaiter();
      rethrow;
    }
  }

  Future<WireConnection> acquire({CancelToken? cancel}) async {
    if (_closed) throw MongoNetworkError('The client is closed');
    cancel?.throwIfCancelled();
    while (_idle.isNotEmpty) {
      final c = _idle.removeLast();
      if (!c.isClosed) return c;
      _open--;
    }
    if (_open < maxSize) return _create();
    final waiter = Completer<WireConnection>();
    _waiters.add(waiter);
    if (cancel != null) {
      unawaited(
        cancel.whenCancelled.then((_) {
          if (_waiters.remove(waiter)) {
            waiter.completeError(MongoCancelledError());
          }
        }),
      );
    }
    return waiter.future;
  }

  /// Returns [conn] to the pool. Closed connections are dropped.
  void release(WireConnection conn) {
    if (conn.isClosed || _closed) {
      if (!conn.isClosed) conn.close();
      _open--;
      _serveWaiter();
      return;
    }
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete(conn);
      return;
    }
    _idle.add(conn);
  }

  void _serveWaiter() {
    if (_waiters.isEmpty || _closed) return;
    if (_idle.isNotEmpty) {
      _waiters.removeFirst().complete(_idle.removeLast());
      return;
    }
    if (_open < maxSize) {
      final waiter = _waiters.removeFirst();
      _create().then(waiter.complete, onError: waiter.completeError);
    }
  }

  /// Runs [action] with a pooled connection.
  Future<T> use<T>(
    Future<T> Function(WireConnection conn) action, {
    CancelToken? cancel,
  }) async {
    final conn = await acquire(cancel: cancel);
    try {
      return await action(conn);
    } finally {
      release(conn);
    }
  }

  void close() {
    _closed = true;
    for (final c in _idle) {
      c.close();
    }
    _idle.clear();
    while (_waiters.isNotEmpty) {
      _waiters.removeFirst().completeError(MongoNetworkError('Client closed'));
    }
  }
}
