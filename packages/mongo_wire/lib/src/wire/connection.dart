import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../bson/codec.dart';
import '../cancel.dart';
import '../errors.dart';
import 'connection_string.dart';

/// TLS settings for a connection.
final class TlsOptions {
  const TlsOptions({
    this.enabled = false,
    this.allowInvalidCertificates = false,
    this.caCertificatePem,
  });

  final bool enabled;
  final bool allowInvalidCertificates;

  /// Extra trusted CA certificates in PEM format, for self-signed servers.
  final String? caCertificatePem;
}

/// A reply and the number of bytes it took on the wire.
final class WireReply {
  const WireReply(this.document, this.byteLength);
  final Map<String, dynamic> document;
  final int byteLength;
}

const _opMsg = 2013;
const _opReply = 1;
const _headerSize = 16;

/// The largest reply accepted, a little over the server's 48 MB message
/// limit.
const _maxMessageSize = 50 * 1024 * 1024;

int _nextRequestId = 1;

/// One socket to one server. Requests run one at a time; [send] queues
/// callers so a connection can be shared safely.
class WireConnection {
  WireConnection._(this.address, this._socket) {
    _subscription = _socket.listen(
      _onData,
      onError: _onError,
      onDone: _onDone,
      cancelOnError: true,
    );
    // Write errors are reported through `done`; route them to the waiter
    // instead of letting them surface as uncaught errors.
    _socket.done.then<void>((_) {}, onError: _onError);
  }

  /// Opens a TCP or TLS socket to [address].
  static Future<WireConnection> open(
    HostAddress address, {
    TlsOptions tls = const TlsOptions(),
    Duration timeout = const Duration(seconds: 10),
  }) async {
    Socket socket;
    try {
      if (tls.enabled) {
        SecurityContext? context;
        final pem = tls.caCertificatePem;
        if (pem != null && pem.trim().isNotEmpty) {
          context = SecurityContext(withTrustedRoots: true)
            ..setTrustedCertificatesBytes(utf8.encode(pem));
        }
        socket = await SecureSocket.connect(
          address.host,
          address.port,
          context: context,
          timeout: timeout,
          onBadCertificate: tls.allowInvalidCertificates ? (_) => true : null,
        );
      } else {
        socket = await Socket.connect(
          address.host,
          address.port,
          timeout: timeout,
        );
      }
    } on HandshakeException catch (e) {
      throw MongoNetworkError(
        'TLS handshake with $address failed: ${e.osError?.message ?? e.message}. '
        'If the server uses a self-signed certificate, add its CA or allow '
        'invalid certificates.',
        e,
      );
    } on SocketException catch (e) {
      final reason = e.osError?.message ?? e.message;
      throw MongoNetworkError('Could not connect to $address: $reason', e);
    } on TlsException catch (e) {
      throw MongoNetworkError('TLS error with $address: ${e.message}', e);
    } on TimeoutException {
      throw MongoTimeoutError(
        'Connecting to $address timed out after ${timeout.inSeconds}s',
      );
    }
    socket.setOption(SocketOption.tcpNoDelay, true);
    return WireConnection._(address, socket);
  }

  final HostAddress address;
  final Socket _socket;
  late final StreamSubscription<Uint8List> _subscription;

  final List<Uint8List> _chunks = [];
  int _available = 0;
  int _expected = -1;

  Completer<WireReply>? _inFlight;
  int _inFlightId = 0;
  Future<void> _queue = Future.value();

  bool _closed = false;
  Object? _closeReason;

  bool get isClosed => _closed;

  /// Server limits from the handshake.
  int maxBsonObjectSize = 16 * 1024 * 1024;
  int maxMessageSizeBytes = 48000000;

  void _onData(Uint8List data) {
    _chunks.add(data);
    _available += data.length;
    while (true) {
      if (_expected < 0) {
        if (_available < 4) return;
        final head = _peek(4);
        _expected = ByteData.sublistView(head).getInt32(0, Endian.little);
        if (_expected < _headerSize || _expected > _maxMessageSize) {
          _fail(
            MongoNetworkError(
              'Invalid message length $_expected from $address',
            ),
          );
          return;
        }
      }
      if (_available < _expected) return;
      final message = _take(_expected);
      _expected = -1;
      _handleMessage(message);
    }
  }

  Uint8List _peek(int n) {
    final out = Uint8List(n);
    var filled = 0;
    for (final c in _chunks) {
      final k = (n - filled) < c.length ? n - filled : c.length;
      out.setRange(filled, filled + k, c);
      filled += k;
      if (filled == n) break;
    }
    return out;
  }

  /// Removes and returns the first [n] buffered bytes, copying each chunk
  /// once so large replies stay linear.
  Uint8List _take(int n) {
    final out = Uint8List(n);
    var filled = 0;
    while (filled < n) {
      final c = _chunks.first;
      final need = n - filled;
      if (c.length <= need) {
        out.setRange(filled, filled + c.length, c);
        filled += c.length;
        _chunks.removeAt(0);
      } else {
        out.setRange(filled, n, c);
        _chunks[0] = Uint8List.sublistView(c, need);
        filled = n;
      }
    }
    _available -= n;
    return out;
  }

  void _handleMessage(Uint8List message) {
    final view = ByteData.sublistView(message);
    final responseTo = view.getInt32(8, Endian.little);
    final opCode = view.getInt32(12, Endian.little);
    final waiter = _inFlight;
    if (waiter == null || responseTo != _inFlightId) return;
    try {
      final Map<String, dynamic> doc;
      if (opCode == _opMsg) {
        doc = _parseOpMsg(message);
      } else if (opCode == _opReply) {
        // Only seen when a very old server answers; the first document is
        // the command reply.
        doc = Bson.decode(message, _headerSize + 20);
      } else {
        throw MongoNetworkError('Unsupported reply opcode $opCode');
      }
      _inFlight = null;
      waiter.complete(WireReply(doc, message.length));
    } on Object catch (e) {
      _inFlight = null;
      waiter.completeError(
        e is MongoException ? e : MongoNetworkError('Bad reply: $e', e),
      );
    }
  }

  static Map<String, dynamic> _parseOpMsg(Uint8List message) {
    final view = ByteData.sublistView(message);
    final flags = view.getUint32(_headerSize, Endian.little);
    var end = message.length;
    if (flags & 1 != 0) end -= 4; // checksum present
    var pos = _headerSize + 4;
    Map<String, dynamic>? body;
    final sequences = <String, List<Map<String, dynamic>>>{};
    while (pos < end) {
      final kind = message[pos++];
      if (kind == 0) {
        final len = view.getInt32(pos, Endian.little);
        body = Bson.decode(Uint8List.sublistView(message, pos, pos + len));
        pos += len;
      } else if (kind == 1) {
        final size = view.getInt32(pos, Endian.little);
        final sectionEnd = pos + size;
        pos += 4;
        final idStart = pos;
        while (message[pos] != 0) {
          pos++;
        }
        final id = utf8.decode(message.sublist(idStart, pos));
        pos++;
        final docs = <Map<String, dynamic>>[];
        while (pos < sectionEnd) {
          final len = view.getInt32(pos, Endian.little);
          docs.add(Bson.decode(Uint8List.sublistView(message, pos, pos + len)));
          pos += len;
        }
        sequences[id] = docs;
      } else {
        throw MongoNetworkError('Unknown OP_MSG section kind $kind');
      }
    }
    if (body == null) throw MongoNetworkError('OP_MSG reply without a body');
    body.addAll(sequences);
    return body;
  }

  void _onError(Object error) {
    _fail(MongoNetworkError('Connection to $address failed: $error', error));
  }

  void _onDone() {
    _fail(MongoNetworkError('The server closed the connection to $address'));
  }

  void _fail(Object reason) {
    if (!_closed) {
      _closed = true;
      _closeReason = reason;
      _subscription.cancel();
      _socket.destroy();
    }
    final waiter = _inFlight;
    _inFlight = null;
    if (waiter != null && !waiter.isCompleted) waiter.completeError(reason);
  }

  /// Closes the socket. Any running request fails with [reason].
  void close([Object? reason]) {
    _fail(reason ?? MongoNetworkError('Connection closed'));
  }

  /// Sends [command] to database [db] and returns the reply document.
  ///
  /// Server errors (`ok: 0`) are thrown as [MongoServerError]. When [cancel]
  /// fires, the socket is closed and [MongoCancelledError] is thrown. When
  /// [timeout] passes, the socket is closed and [MongoTimeoutError] thrown.
  Future<WireReply> send(
    String db,
    Map<String, dynamic> command, {
    CancelToken? cancel,
    Duration? timeout,
    bool checkOk = true,
  }) {
    final result = _queue.then((_) => _send(db, command, cancel, timeout));
    _queue = result.then<void>((_) {}, onError: (_) {});
    return result.then((reply) {
      if (checkOk && !_isOk(reply.document)) {
        throw MongoServerError.fromReply(reply.document);
      }
      return reply;
    });
  }

  static bool _isOk(Map<String, dynamic> reply) {
    final ok = reply['ok'];
    return ok == 1 || ok == 1.0 || ok == true;
  }

  Future<WireReply> _send(
    String db,
    Map<String, dynamic> command,
    CancelToken? cancel,
    Duration? timeout,
  ) async {
    cancel?.throwIfCancelled();
    if (_closed) {
      throw _closeReason ?? MongoNetworkError('Connection closed');
    }
    final body = Bson.encode({...command, r'$db': db});
    if (body.length > maxMessageSizeBytes) {
      throw MongoConfigError(
        'The request is larger than the server allows '
        '(${body.length} bytes)',
      );
    }
    final requestId = _nextRequestId++;
    final header = ByteData(_headerSize + 5);
    header.setInt32(0, _headerSize + 5 + body.length, Endian.little);
    header.setInt32(4, requestId, Endian.little);
    header.setInt32(8, 0, Endian.little);
    header.setInt32(12, _opMsg, Endian.little);
    header.setUint32(16, 0, Endian.little); // flags
    header.setUint8(20, 0); // section kind 0

    final waiter = Completer<WireReply>();
    _inFlight = waiter;
    _inFlightId = requestId;

    Timer? timer;
    if (timeout != null) {
      timer = Timer(timeout, () {
        close(
          MongoTimeoutError(
            'No reply from $address within ${timeout.inSeconds}s',
          ),
        );
      });
    }
    StreamSubscription<void>? cancelSub;
    if (cancel != null) {
      cancelSub = cancel.whenCancelled.asStream().listen((_) {
        close(MongoCancelledError());
      });
    }
    try {
      _socket.add(header.buffer.asUint8List());
      _socket.add(body);
      return await waiter.future;
    } finally {
      timer?.cancel();
      await cancelSub?.cancel();
    }
  }
}
