import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'singbox_config.dart' show XrayAuth;

/// For tests: what happens on the sockets, as text.
void Function(String line)? socksDebug;

/// What a request answered: the status, where it points to when it redirects, and the body.
typedef _Reply = ({int status, String? location, Uint8List body});

/// [url]'s body fetched through the SOCKS5 proxy at 127.0.0.1:[socksPort] (the port Xray opens for
/// the app: with Xray running the app itself is outside the VPN, so its own downloads would go
/// out the network's own way). Plain HTTP and HTTPS, redirects followed (three at most). Null when
/// anything goes wrong: the proxy, the page (anything but 200) or a body over [maxBytes].
///
/// [onBadCertificate] is for tests; a real download checks the certificate.
Future<Uint8List?> socksGet(
  String url,
  int socksPort, {
  XrayAuth? auth,
  Duration timeout = const Duration(seconds: 25),
  int maxBytes = 64 * 1024 * 1024,
  bool Function(X509Certificate certificate)? onBadCertificate,
  void Function(Object error)? onError,
}) async {
  var target = Uri.tryParse(url);
  for (var hop = 0; hop < 4; hop++) {
    if (target == null || target.host.isEmpty || (target.scheme != 'http' && target.scheme != 'https')) return null;
    final reply = await _fetchOnce(target, socksPort, auth, timeout, maxBytes, onBadCertificate, onError);
    if (reply == null) return null;
    if (reply.status == 200) return reply.body;
    final where = reply.location;
    if (const {301, 302, 303, 307, 308}.contains(reply.status) && where != null && where.isNotEmpty) {
      target = target.resolve(where);
      continue;
    }
    return null;
  }
  return null;
}

Future<_Reply?> _fetchOnce(Uri uri, int socksPort, XrayAuth? auth, Duration timeout, int maxBytes,
    bool Function(X509Certificate)? onBad, void Function(Object error)? onError) async {
  final open = <RawSocket>[];
  Future<_Reply?> run() async {
    final pipe = await _connect(uri, socksPort, auth, timeout, onBad, open);
    return _httpGet(pipe, uri, maxBytes);
  }

  try {
    final reply = await run().timeout(timeout, onTimeout: () {
      onError?.call('timeout');
      return null;
    });
    if (reply == null) onError?.call('no answer from ${uri.host}');
    return reply;
  } catch (e) {
    onError?.call(e);
    return null;
  } finally {
    for (final s in open) {
      unawaited(s.close().then<void>((_) {}, onError: (Object _) {}));
    }
  }
}

/// A connection to [uri]'s host through the proxy, with TLS on it for https. Every socket made is added
/// to [open], for the caller to close.
Future<_Pipe> _connect(Uri uri, int socksPort, XrayAuth? auth, Duration timeout, bool Function(X509Certificate)? onBad,
    List<RawSocket> open) async {
  final raw = await RawSocket.connect(InternetAddress.loopbackIPv4, socksPort, timeout: timeout);
  open.add(raw);
  var pipe = _Pipe(raw);
  await _socksHandshake(pipe, uri.host, uri.port, auth);
  if (uri.scheme == 'https') {
    // The reading that the handshake started is handed over to the secure socket.
    final secure =
        await RawSecureSocket.secure(raw, subscription: pipe.subscription, host: uri.host, onBadCertificate: onBad);
    open.add(secure);
    pipe = _Pipe(secure);
  }
  return pipe;
}

Future<void> _socksHandshake(_Pipe p, String host, int port, XrayAuth? auth) async {
  final name = utf8.encode(host);
  if (name.length > 255) throw const FormatException('name too long');
  if (auth == null) {
    await p.write([5, 1, 0]);
    if ((await p.take(2))[1] != 0) throw const SocketException('socks: no method');
  } else {
    // method 2: user name and password (RFC 1929)
    await p.write([5, 1, 2]);
    if ((await p.take(2))[1] != 2) throw const SocketException('socks: no method');
    final user = utf8.encode(auth.user), pass = utf8.encode(auth.pass);
    await p.write([1, user.length, ...user, pass.length, ...pass]);
    if ((await p.take(2))[1] != 0) throw const SocketException('socks: login refused');
  }
  await p.write([5, 1, 0, 3, name.length, ...name, port >> 8, port & 255]);
  final head = await p.take(4);
  if (head[1] != 0) throw SocketException('socks: refused (${head[1]})');
  if (head[3] == 3) {
    final length = (await p.take(1))[0];
    await p.take(length + 2);
  } else {
    await p.take((head[3] == 4 ? 16 : 4) + 2);
  }
}

/// The start of a request: [method], the page, the headers every request has and [extra] ones.
List<int> _request(String method, Uri uri, [String extra = '']) {
  final defaultPort = uri.scheme == 'https' ? 443 : 80;
  final hostHeader = uri.port == defaultPort ? uri.host : '${uri.host}:${uri.port}';
  final path = uri.path.isEmpty ? '/' : uri.path;
  final query = uri.hasQuery ? '?${uri.query}' : '';
  return utf8.encode('$method $path$query HTTP/1.1\r\nHost: $hostHeader\r\nUser-Agent: Kumo\r\n'
      'Accept: */*\r\nAccept-Encoding: identity\r\nConnection: close\r\n$extra\r\n');
}

/// The status and the headers (names in lower case) of an answer; what comes after them stays in [p].
Future<({int status, Map<String, String> headers})?> _readHead(_Pipe p) async {
  var buffer = Uint8List(0);
  Uint8List headBytes;
  while (true) {
    final chunk = await p.next();
    if (chunk == null) return null;
    buffer = Uint8List.fromList([...buffer, ...chunk]);
    final end = _headEnd(buffer);
    if (end >= 0) {
      headBytes = Uint8List.sublistView(buffer, 0, end);
      p.unread(Uint8List.sublistView(buffer, end + 4));
      break;
    }
    if (buffer.length > 65536) return null;
  }
  final lines = latin1.decode(headBytes).split('\r\n');
  final status = int.tryParse(lines.first.split(' ').elementAtOrNull(1) ?? '');
  if (status == null) return null;
  final headers = <String, String>{};
  for (final line in lines.skip(1)) {
    final colon = line.indexOf(':');
    if (colon > 0) headers[line.substring(0, colon).trim().toLowerCase()] = line.substring(colon + 1).trim();
  }
  return (status: status, headers: headers);
}

Future<_Reply?> _httpGet(_Pipe p, Uri uri, int maxBytes) async {
  await p.write(_request('GET', uri));
  final head = await _readHead(p);
  if (head == null) return null;
  final status = head.status, headers = head.headers;
  if (status != 200) return (status: status, location: headers['location'], body: Uint8List(0));

  final body = BytesBuilder(copy: false);
  final length = int.tryParse(headers['content-length'] ?? '');
  if ((headers['transfer-encoding'] ?? '').toLowerCase().contains('chunked')) {
    while (true) {
      final size = int.tryParse(latin1.decode(await p.readLine()).split(';').first.trim(), radix: 16);
      if (size == null) return null;
      if (size == 0) break;
      if (body.length + size > maxBytes) return null;
      body.add(await p.take(size));
      await p.take(2); // the line break after a chunk
    }
  } else if (length != null) {
    if (length > maxBytes) return null;
    body.add(await p.take(length));
  } else {
    // No length given: the end of the connection is the end of the body.
    while (true) {
      final chunk = await p.next();
      if (chunk == null) break;
      body.add(chunk);
      if (body.length > maxBytes) return null;
    }
  }
  return (status: status, location: headers['location'], body: body.takeBytes());
}

/// How fast data goes through the SOCKS5 proxy at 127.0.0.1:[socksPort], in Mbit/s; -1 when it could not be
/// measured. A download counts what comes from [url] from its first byte until it ends or [window] has
/// passed; an upload sends [bytes] of zeros to [url] and counts the time until the server has answered
/// (so it must be a page that takes a body, such as Cloudflare's speed test).
///
/// [timeout] is for the whole, set-up included. [onBadCertificate] is for tests.
Future<double> socksSpeed(
  String url,
  int socksPort, {
  XrayAuth? auth,
  required bool upload,
  int bytes = 4000000,
  Duration timeout = const Duration(seconds: 30),
  Duration window = const Duration(seconds: 12),
  bool Function(X509Certificate certificate)? onBadCertificate,
}) async {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty || (uri.scheme != 'http' && uri.scheme != 'https')) return -1;
  final open = <RawSocket>[];
  Future<double> run() async {
    final pipe = await _connect(uri, socksPort, auth, timeout, onBadCertificate, open);
    if (upload) {
      await pipe.write(_request('POST', uri, 'Content-Type: application/octet-stream\r\nContent-Length: $bytes\r\n'));
      final sw = Stopwatch()..start();
      final chunk = Uint8List(32768);
      var left = bytes;
      while (left > 0) {
        final n = left < chunk.length ? left : chunk.length;
        await pipe.write(n == chunk.length ? chunk : Uint8List.sublistView(chunk, 0, n));
        left -= n;
      }
      final head = await _readHead(pipe);
      sw.stop();
      if (head == null || head.status >= 400) return -1;
      return bytes * 8 / (sw.elapsedMicroseconds / 1e6) / 1e6;
    }
    await pipe.write(_request('GET', uri));
    final head = await _readHead(pipe);
    if (head == null || head.status != 200) return -1;
    var total = 0;
    Stopwatch? sw;
    while (true) {
      final left = sw == null ? window : window - sw.elapsed;
      if (left <= Duration.zero) break;
      final chunk = await pipe.next().timeout(left, onTimeout: () => null);
      if (chunk == null) break;
      sw ??= Stopwatch()..start();
      total += chunk.length;
    }
    if (sw == null || total == 0) return -1;
    final seconds = sw.elapsedMicroseconds / 1e6;
    return total * 8 / (seconds < 0.05 ? 0.05 : seconds) / 1e6;
  }

  try {
    return await run().timeout(timeout, onTimeout: () => -1);
  } catch (_) {
    return -1;
  } finally {
    for (final s in open) {
      unawaited(s.close().then<void>((_) {}, onError: (Object _) {}));
    }
  }
}

int _headEnd(Uint8List b) {
  for (var i = 0; i + 3 < b.length; i++) {
    if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) return i;
  }
  return -1;
}

/// What comes in on a [RawSocket], read in order, with a way to put back what was read too far.
class _Pipe {
  _Pipe(this.socket) {
    subscription = socket.listen(_onEvent, onError: (Object e) {
      _error = e;
      _closed = true;
      _wake();
    }, onDone: () {
      _closed = true;
      _wake();
    });
  }

  final RawSocket socket;
  late final StreamSubscription<RawSocketEvent> subscription;
  final _chunks = ListQueue<Uint8List>();
  Completer<void>? _waiting;
  Completer<void>? _writable;
  Object? _error;
  var _closed = false;

  void _onEvent(RawSocketEvent event) {
    socksDebug?.call('event $event');
    if (event == RawSocketEvent.read) {
      while (true) {
        final data = socket.read();
        if (data == null || data.isEmpty) break;
        _chunks.add(data);
      }
    } else if (event == RawSocketEvent.write) {
      final w = _writable;
      _writable = null;
      if (w != null && !w.isCompleted) w.complete();
    } else if (event == RawSocketEvent.readClosed || event == RawSocketEvent.closed) {
      _closed = true;
      // A writer that waits for the socket will not get it now.
      final w = _writable;
      _writable = null;
      if (w != null && !w.isCompleted) w.completeError(const SocketException('closed'));
    }
    _wake();
  }

  void _wake() {
    final w = _waiting;
    _waiting = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  /// The next bytes that came, or null when the other side has closed and nothing is left.
  Future<Uint8List?> next() async {
    while (_chunks.isEmpty) {
      if (_error != null) throw _error!;
      if (_closed) return null;
      final w = _waiting = Completer<void>();
      await w.future;
    }
    return _chunks.removeFirst();
  }

  void unread(Uint8List bytes) {
    if (bytes.isNotEmpty) _chunks.addFirst(bytes);
  }

  /// Exactly [n] bytes.
  Future<Uint8List> take(int n) async {
    final out = BytesBuilder(copy: false);
    while (out.length < n) {
      final chunk = await next();
      if (chunk == null) throw const SocketException('closed too early');
      final need = n - out.length;
      if (chunk.length > need) {
        out.add(Uint8List.sublistView(chunk, 0, need));
        unread(Uint8List.sublistView(chunk, need));
      } else {
        out.add(chunk);
      }
    }
    return out.takeBytes();
  }

  /// One line, without its line break.
  Future<Uint8List> readLine() async {
    final line = <int>[];
    while (true) {
      final chunk = await next();
      if (chunk == null) throw const SocketException('closed too early');
      final at = chunk.indexOf(10);
      if (at < 0) {
        line.addAll(chunk);
        if (line.length > 65536) throw const FormatException('line too long');
        continue;
      }
      line.addAll(Uint8List.sublistView(chunk, 0, at));
      unread(Uint8List.sublistView(chunk, at + 1));
      if (line.isNotEmpty && line.last == 13) line.removeLast();
      return Uint8List.fromList(line);
    }
  }

  /// Sends [data]; what the socket does not take at once waits for it to be ready again.
  Future<void> write(List<int> data) async {
    var sent = 0;
    while (sent < data.length) {
      final n = socket.write(data, sent, data.length - sent);
      socksDebug?.call('write ${data.length - sent} -> $n');
      sent += n;
      if (sent < data.length) {
        final w = _writable = Completer<void>();
        socket.writeEventsEnabled = true;
        await w.future;
      }
    }
  }
}
