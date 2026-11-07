import 'dart:async';
import 'dart:io';

/// Holds the proxy ports of the app itself, so that they are never closed while the proxy is kept
/// running: the cores that carry the traffic listen on ports of their own, and each connection that
/// comes in here is passed on to the core that runs at that moment. When one core is replaced by
/// another (connecting, disconnecting, a change of server) a new connection waits a moment for the
/// next core instead of being refused.
class ProxyHolder {
  ProxyHolder({this.patience = const Duration(seconds: 30)});

  /// How long a connection waits for a core to be there.
  final Duration patience;

  final _fronts = <int, _Front>{};

  /// The ports that are held now.
  Iterable<int> get ports => _fronts.keys;

  /// Starts to listen on [port] of [host]; true when it is held (it already was, or it is now).
  Future<bool> bind(int port, String host) async {
    final have = _fronts[port];
    if (have != null) return have.host == host;
    try {
      final server = await ServerSocket.bind(host, port);
      final front = _Front(port, host, server);
      _fronts[port] = front;
      server.listen((client) => _carry(front, client), onError: (_) {}, cancelOnError: false);
      return true;
    } on SocketException {
      return false;
    }
  }

  /// From now on new connections to [port] go to the core on 127.0.0.1:[upstream].
  void route(int port, int upstream) {
    final front = _fronts[port];
    if (front == null) return;
    front.upstream = upstream;
    final waiting = front.waiting.toList();
    front.waiting.clear();
    for (final c in waiting) {
      if (!c.isCompleted) c.complete(upstream);
    }
  }

  /// The core on [upstream] is gone: a connection that comes now waits for the next one. (Nothing
  /// happens when the port has been given to another core meanwhile.)
  void unroute(int port, int upstream) {
    final front = _fronts[port];
    if (front != null && front.upstream == upstream) front.upstream = null;
  }

  /// Stops listening on [port].
  Future<void> close(int port) async {
    final front = _fronts.remove(port);
    if (front == null) return;
    for (final c in front.waiting) {
      if (!c.isCompleted) c.complete(null);
    }
    await front.server.close().catchError((_) => front.server);
  }

  /// Stops listening on every port. The connections that are carried now go on.
  Future<void> release() async {
    final fronts = _fronts.values.toList();
    _fronts.clear();
    for (final f in fronts) {
      for (final c in f.waiting) {
        if (!c.isCompleted) c.complete(null);
      }
      f.waiting.clear();
      await f.server.close().catchError((_) => f.server);
    }
  }

  Future<int?> _upstream(_Front front, DateTime end) async {
    final now = front.upstream;
    if (now != null) return now;
    final left = end.difference(DateTime.now());
    if (left <= Duration.zero) return null;
    final c = Completer<int?>();
    front.waiting.add(c);
    return c.future.timeout(left, onTimeout: () {
      front.waiting.remove(c);
      return null;
    });
  }

  Future<void> _carry(_Front front, Socket client) async {
    try {
      client.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
    final end = DateTime.now().add(patience);
    Socket? up;
    while (up == null) {
      final port = await _upstream(front, end);
      if (port == null || _fronts[front.port] != front) {
        client.destroy();
        return;
      }
      try {
        up = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(seconds: 2));
      } catch (_) {
        // The core that was there is going away, or the next one is not listening yet.
        if (front.upstream == port) front.upstream = null;
        if (DateTime.now().isAfter(end)) {
          client.destroy();
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
    try {
      up.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
    void closeBoth() {
      client.destroy();
      up!.destroy();
    }

    // Each side is closed for writing when the other one is done (a half close goes through).
    Future<void> pass(Socket from, Socket to) =>
        to.addStream(from).then((_) => to.close()).catchError((_) => closeBoth());
    Future.wait([pass(client, up), pass(up, client)]).whenComplete(closeBoth);
  }
}

class _Front {
  _Front(this.port, this.host, this.server);
  final int port;
  final String host;
  final ServerSocket server;
  int? upstream;
  final waiting = <Completer<int?>>[];
}
