import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A minimal SOCKS5 proxy (CONNECT only) for the tests, with optional user
/// name and password.
class TestSocksProxy {
  TestSocksProxy({this.username, this.password});
  final String? username;
  final String? password;
  late final ServerSocket _server;
  final targets = <String>[];

  int get port => _server.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> close() => _server.close();

  Future<void> _handle(Socket client) async {
    final buf = <int>[];
    final waiters = <Completer<void>>[];
    StreamSubscription<List<int>>? sub;
    Socket? upstream;
    sub = client.listen((d) {
      if (upstream != null) {
        upstream.add(d);
        return;
      }
      buf.addAll(d);
      for (final w in waiters) {
        w.complete();
      }
      waiters.clear();
    }, onDone: () => upstream?.destroy());
    Future<List<int>> take(int n) async {
      while (buf.length < n) {
        final c = Completer<void>();
        waiters.add(c);
        await c.future;
      }
      final out = buf.sublist(0, n);
      buf.removeRange(0, n);
      return out;
    }

    final head = await take(2);
    final methods = await take(head[1]);
    final wantAuth = username != null;
    if (wantAuth && !methods.contains(2) || !wantAuth && !methods.contains(0)) {
      client.add([5, 0xff]);
      await client.close();
      return;
    }
    client.add([5, wantAuth ? 2 : 0]);
    if (wantAuth) {
      await take(1);
      final u = utf8.decode(await take((await take(1))[0]));
      final p = utf8.decode(await take((await take(1))[0]));
      final ok = u == username && p == password;
      client.add([1, ok ? 0 : 1]);
      if (!ok) {
        await client.close();
        return;
      }
    }
    final req = await take(4);
    String host;
    switch (req[3]) {
      case 1:
        host = (await take(4)).join('.');
      case 3:
        host = utf8.decode(await take((await take(1))[0]));
      default:
        client.add([5, 8, 0, 1, 0, 0, 0, 0, 0, 0]);
        await client.close();
        return;
    }
    final p = await take(2);
    final port = p[0] << 8 | p[1];
    targets.add('$host:$port');
    try {
      upstream = await Socket.connect(host, port);
    } on SocketException {
      client.add([5, 5, 0, 1, 0, 0, 0, 0, 0, 0]);
      await client.close();
      return;
    }
    client.add([5, 0, 0, 1, 127, 0, 0, 1, 0, 0]);
    if (buf.isNotEmpty) upstream.add(List.of(buf));
    buf.clear();
    upstream.listen(client.add, onDone: client.destroy, onError: (_) {});
    unawaited(sub.asFuture<void>().catchError((_) {}));
  }
}
