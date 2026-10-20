import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../errors.dart';
import 'connection_string.dart';

/// A way to reach servers that are not directly reachable, such as an SSH
/// tunnel or a SOCKS5 proxy. The driver connects to the local address it
/// returns, and TLS still checks the real server's name.
abstract interface class Tunnel {
  /// A local address whose connections are forwarded to [target].
  Future<HostAddress> forward(HostAddress target);

  /// Stops forwarding and closes the underlying connection.
  Future<void> close();
}

/// A byte stream to a target, opened by a [ForwardingTunnel].
typedef ForwardedStream = ({
  Stream<List<int>> input,
  StreamSink<List<int>> output,
});

/// Listens on a loopback port per target and copies each local connection
/// to a stream from [open]. Subclasses provide [open].
abstract class ForwardingTunnel implements Tunnel {
  final Map<HostAddress, Future<ServerSocket>> _listeners = {};
  final Set<Socket> _sockets = {};
  bool _closed = false;

  /// Opens a stream to [target] through the tunnel.
  Future<ForwardedStream> open(HostAddress target);

  @override
  Future<HostAddress> forward(HostAddress target) async {
    if (_closed) throw MongoNetworkError('The tunnel is closed');
    final server = await _listeners.putIfAbsent(target, () async {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      s.listen((local) => _accept(local, target));
      return s;
    });
    return HostAddress(InternetAddress.loopbackIPv4.address, server.port);
  }

  Future<void> _accept(Socket local, HostAddress target) async {
    _sockets.add(local);
    ForwardedStream remote;
    try {
      remote = await open(target);
    } on Object {
      _sockets.remove(local);
      local.destroy();
      return;
    }
    local.setOption(SocketOption.tcpNoDelay, true);
    var done = false;
    void finish() {
      if (done) return;
      done = true;
      _sockets.remove(local);
      local.destroy();
      remote.output.close().catchError((_) {});
    }

    remote.input.listen(
      local.add,
      onError: (_) => finish(),
      onDone: finish,
      cancelOnError: true,
    );
    local.listen(
      remote.output.add,
      onError: (_) => finish(),
      onDone: finish,
      cancelOnError: true,
    );
  }

  @override
  Future<void> close() async {
    _closed = true;
    for (final s in _sockets.toList()) {
      s.destroy();
    }
    _sockets.clear();
    for (final l in _listeners.values) {
      try {
        await (await l).close();
      } on Object {
        // Already closed.
      }
    }
    _listeners.clear();
  }
}

/// Connects through a SOCKS5 proxy (RFC 1928), with optional user name and
/// password (RFC 1929). Host names are resolved by the proxy.
class Socks5Tunnel extends ForwardingTunnel {
  Socks5Tunnel({
    required this.proxy,
    this.username,
    this.password,
    this.timeout = const Duration(seconds: 10),
  });

  final HostAddress proxy;
  final String? username;
  final String? password;
  final Duration timeout;

  @override
  Future<ForwardedStream> open(HostAddress target) async {
    final Socket socket;
    try {
      socket = await Socket.connect(proxy.host, proxy.port, timeout: timeout);
    } on SocketException catch (e) {
      throw MongoNetworkError(
        'Could not reach the SOCKS5 proxy $proxy: '
        '${e.osError?.message ?? e.message}',
        e,
      );
    }
    final reader = _Reader(socket);
    try {
      final auth = username != null && username!.isNotEmpty;
      socket.add([5, 1, auth ? 2 : 0]);
      final choice = await reader.take(2).timeout(timeout);
      if (choice[0] != 5) {
        throw MongoNetworkError('$proxy is not a SOCKS5 proxy');
      }
      if (choice[1] == 0xff) {
        throw MongoNetworkError(
          auth
              ? 'The SOCKS5 proxy does not accept a user name and password'
              : 'The SOCKS5 proxy needs a user name and password',
        );
      }
      if (choice[1] == 2) {
        final u = utf8.encode(username ?? '');
        final p = utf8.encode(password ?? '');
        if (u.length > 255 || p.length > 255) {
          throw MongoConfigError('SOCKS5 user name and password are too long');
        }
        socket.add([1, u.length, ...u, p.length, ...p]);
        final r = await reader.take(2).timeout(timeout);
        if (r[1] != 0) {
          throw MongoAuthError(
            'The SOCKS5 proxy rejected the user name or password',
          );
        }
      } else if (choice[1] != 0) {
        throw MongoNetworkError(
          'The SOCKS5 proxy asked for an unsupported method',
        );
      }
      final ip = InternetAddress.tryParse(target.host);
      final host = utf8.encode(target.host);
      socket.add([
        5, 1, 0, // CONNECT
        if (ip == null) ...[
          3,
          host.length,
          ...host,
        ] else if (ip.type == InternetAddressType.IPv4) ...[
          1,
          ...ip.rawAddress,
        ] else ...[
          4,
          ...ip.rawAddress,
        ],
        target.port >> 8, target.port & 0xff,
      ]);
      final head = await reader.take(4).timeout(timeout);
      if (head[1] != 0) {
        throw MongoNetworkError(
          'The SOCKS5 proxy could not connect to $target: '
          '${_socksError(head[1])}',
        );
      }
      final rest = switch (head[3]) {
        1 => 4,
        4 => 16,
        3 => (await reader.take(1).timeout(timeout))[0],
        _ => throw MongoNetworkError('Bad reply from the SOCKS5 proxy'),
      };
      await reader.take(rest + 2).timeout(timeout);
      return (input: reader.rest(), output: socket);
    } on TimeoutException {
      socket.destroy();
      throw MongoTimeoutError('The SOCKS5 proxy $proxy did not answer');
    } on Object {
      socket.destroy();
      rethrow;
    }
  }

  static String _socksError(int code) => switch (code) {
    1 => 'general failure',
    2 => 'not allowed by the proxy rules',
    3 => 'network unreachable',
    4 => 'host unreachable',
    5 => 'connection refused',
    6 => 'TTL expired',
    7 => 'command not supported',
    8 => 'address type not supported',
    _ => 'error $code',
  };
}

/// Reads exact byte counts from a socket during a handshake, then hands
/// the rest of the stream on.
class _Reader {
  _Reader(Socket socket) {
    _sub = socket.listen(
      (d) {
        _buffer.addAll(d);
        _wake();
      },
      onError: (Object e) {
        _error = e;
        _wake();
      },
      onDone: () {
        _done = true;
        _wake();
      },
    );
  }

  late final StreamSubscription<Uint8List> _sub;
  final _buffer = <int>[];
  Completer<void>? _waiting;
  Object? _error;
  bool _done = false;
  StreamController<List<int>>? _out;

  void _wake() {
    final out = _out;
    if (out != null) {
      if (_buffer.isNotEmpty) {
        out.add(List.of(_buffer));
        _buffer.clear();
      }
      if (_error != null) out.addError(_error!);
      if (_done || _error != null) out.close();
      return;
    }
    _waiting?.complete();
    _waiting = null;
  }

  Future<List<int>> take(int n) async {
    while (_buffer.length < n) {
      if (_error != null) {
        throw MongoNetworkError('Proxy connection failed: $_error');
      }
      if (_done) throw MongoNetworkError('The proxy closed the connection');
      await (_waiting = Completer<void>()).future;
    }
    final out = _buffer.sublist(0, n);
    _buffer.removeRange(0, n);
    return out;
  }

  Stream<List<int>> rest() {
    final out = _out = StreamController<List<int>>(
      onPause: _sub.pause,
      onResume: _sub.resume,
      onCancel: _sub.cancel,
    );
    if (_buffer.isNotEmpty || _done) scheduleMicrotask(_wake);
    return out.stream;
  }
}
