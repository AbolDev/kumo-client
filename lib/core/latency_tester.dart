import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'dart:convert';

import 'proxy_config.dart';
import 'singbox_config.dart' show XrayAuth, buildXrayConfig;
import 'vpn_channel.dart';

/// Page fetched through the proxy to measure the real delay. Plain HTTP on purpose: HTTPS adds a
/// TLS handshake with the site (two more round trips through the proxy) to every number.
const defaultDelayUrl = 'http://cp.cloudflare.com/generate_204';

/// The earlier default, replaced when it is found in saved settings.
const oldDefaultDelayUrl = 'https://www.google.com/generate_204';

/// The address used for the real delay; changed in Settings.
String delayTestUrl = defaultDelayUrl;

/// Protocols that run over UDP: a TCP connect to their port always fails, so they skip that stage.
const _udpProtocols = {'hysteria2', 'tuic', 'hysteria', 'wireguard'};

/// Minimal sing-box config holding only [c] (and the layers it is dialled through), used by the
/// throw-away test core. WireGuard is an endpoint there, everything else an outbound.
String _delayConfig(List<Map<String, dynamic>> layers) {
  final wireguard = layers.first['type'] == 'wireguard';
  return jsonEncode({
    'log': {'level': 'error'},
    'dns': {
      'servers': [
        {'type': 'udp', 'tag': 'dns', 'server': '1.1.1.1'},
      ],
      'final': 'dns',
    },
    if (!wireguard)
      'outbounds': [
        for (var i = 0; i < layers.length; i++)
          {
            ...layers[i],
            'tag': i == 0 ? 'proxy' : 'proxy-l$i',
            if (i + 1 < layers.length) 'detour': 'proxy-l${i + 1}',
          },
      ],
    if (wireguard)
      'endpoints': [
        {...layers.first, 'tag': 'proxy'},
      ],
    'route': {'default_domain_resolver': 'dns'},
  });
}

/// The server and the layers under it with their names already resolved by the system resolver.
/// Resolving them inside the throw-away core went through a fixed public DNS server, which is slow
/// or blocked on many networks and was counted in every result. The name stays where a server
/// needs it (TLS server name, Host header).
Future<List<Map<String, dynamic>>> _resolvedLayers(ProxyConfig c) async => [
      await _resolved(c.outbound),
      for (final layer in c.inner) await _resolved(layer),
    ];

Future<Map<String, dynamic>> _resolved(Map<String, dynamic> outbound) async {
  final out = Map<String, dynamic>.of(outbound);
  // A WireGuard endpoint keeps its server in the peer.
  if (out['type'] == 'wireguard') {
    final peers = out['peers'];
    if (peers is List && peers.isNotEmpty && peers.first is Map) {
      final peer = Map<String, dynamic>.from(peers.first as Map);
      final host = peer['address'];
      if (host is String && InternetAddress.tryParse(host) == null) {
        try {
          final found = await InternetAddress.lookup(host).timeout(const Duration(seconds: 3));
          if (found.isNotEmpty) peer['address'] = found.first.address;
          out['peers'] = [peer, ...peers.skip(1)];
        } catch (_) {}
      }
    }
    return out;
  }
  final server = out['server'];
  if (server is! String || InternetAddress.tryParse(server) != null) return out;
  try {
    final found = await InternetAddress.lookup(server)
        .timeout(const Duration(seconds: 3));
    if (found.isEmpty) return out;
    final ip = found.firstWhere((a) => a.type == InternetAddressType.IPv4,
        orElse: () => found.first);
    out['server'] = ip.address;
    final tls = out['tls'];
    if (tls is Map && (tls['server_name'] ?? '') == '') {
      out['tls'] = {...tls, 'server_name': server};
    }
    final t = out['transport'];
    if (t is Map) {
      final type = t['type'];
      if (type == 'ws' && !((t['headers'] as Map?)?.containsKey('Host') ?? false)) {
        out['transport'] = {
          ...t,
          'headers': {...?(t['headers'] as Map?), 'Host': server},
        };
      } else if ((type == 'httpupgrade' || type == 'http') && t['host'] == null) {
        out['transport'] = {
          ...t,
          'host': type == 'http' ? [server] : server,
        };
      }
    }
  } catch (_) {}
  return out;
}

/// Real delay: time to fetch a page through the server (handshake included), -1 on failure and -2
/// when the test was skipped (the tunnel is being started or stopped). Servers only Xray can carry
/// (XHTTP ...) are measured with a throw-away Xray the same way. A TCP connect is never put in its
/// place: a server that fails the real delay has failed it.
Future<int> realDelay(ProxyConfig c,
    {Duration timeout = const Duration(seconds: 8)}) async {
  if (!c.canSingBox) {
    if (!c.canXray) return -1;
    return VpnChannel.xrayDelay((port) => buildXrayConfig(c, port), delayTestUrl,
        timeoutMs: timeout.inMilliseconds);
  }
  return VpnChannel.delay(_delayConfig(await _resolvedLayers(c)), delayTestUrl,
      timeoutMs: timeout.inMilliseconds);
}

/// Delay of fetching [delayTestUrl] while the VPN is up, in ms, -1 on failure. The request
/// rides the tunnel; with Xray running the app is outside it, so a SOCKS connection through
/// Xray's port ([socksPort]) is used instead. The delay counts what a server's own delay test
/// counts: the connection to the server and the request, not the lookup of the page's name, and
/// with [samples] above one the lowest of that many requests is kept, since the first request
/// of a connection pays for warming up everything on the way.
Future<int> tunnelDelay(
    {int? socksPort,
    XrayAuth? socksAuth,
    int? proxyPort,
    int samples = 1,
    Duration timeout = const Duration(seconds: 8)}) async {
  final uri = Uri.parse(delayTestUrl);
  // Through the tunnel the app looks the name up itself, and the first lookup of a session goes
  // through a cold encrypted DNS connection: that is no part of the delay. (With a local proxy or
  // Xray the name is given to them and their own cache takes care of it.)
  if (socksPort == null && proxyPort == null) {
    try {
      await InternetAddress.lookup(uri.host).timeout(timeout);
    } catch (_) {
      return -1;
    }
  }
  var best = -1;
  for (var i = 0; i < samples; i++) {
    final ms = await _delayOnce(uri, socksPort, socksAuth, proxyPort, timeout);
    if (ms < 0) return best;
    if (best < 0 || ms < best) best = ms;
  }
  return best;
}

Future<int> _delayOnce(
    Uri uri, int? socksPort, XrayAuth? socksAuth, int? proxyPort, Duration timeout) async {
  final sw = Stopwatch();
  try {
    if (socksPort != null) return socksWarmDelay(socksPort, uri, timeout, auth: socksAuth);
    final client = HttpClient()..connectionTimeout = timeout;
    // Without a tunnel the page is fetched through the local proxy instead.
    if (proxyPort != null) {
      client.findProxy = (_) => 'PROXY 127.0.0.1:$proxyPort';
    }
    try {
      // Two requests one after the other over the same connection: the first opens everything on
      // the way, the second is the round trip that traffic then sees (see [socksWarmDelay]).
      for (var i = 0; i < 2; i++) {
        sw
          ..reset()
          ..start();
        final req = await client.getUrl(uri).timeout(timeout);
        final res = await req.close().timeout(timeout);
        await res.drain<void>().timeout(timeout);
      }
      return sw.elapsedMilliseconds;
    } finally {
      client.close(force: true);
    }
  } catch (_) {
    return -1;
  }
}

/// The time of the second of two HTTP requests sent one after the other over one connection made
/// through the SOCKS5 proxy at [socksPort]. The first request opens everything on the way (TCP,
/// TLS or WebSocket to the server, and from the server to the page); the second is the round trip
/// that a user's traffic then sees. That is what other clients such as v2rayN call the real delay;
/// timing the first one counts the whole set-up, which came out about three times as high. Falls
/// back to the time of the first request when the end of its answer cannot be told. -1 on failure.
Future<int> socksWarmDelay(int socksPort, Uri uri, Duration timeout, {XrayAuth? auth}) async {
  Socket? socket;
  try {
    socket = await Socket.connect('127.0.0.1', socksPort, timeout: timeout);
    final reader = StreamIterator<List<int>>(socket);
    // The bytes received and not read yet; [at] is the next one (reading by position keeps a
    // long answer from being shifted byte by byte).
    var buffer = <int>[];
    var at = 0;
    Future<int> nextByte() async {
      if (at >= buffer.length) {
        if (!await reader.moveNext().timeout(timeout)) {
          throw const SocketException('closed');
        }
        buffer = reader.current;
        at = 0;
      }
      return buffer[at++];
    }

    Future<List<int>> take(int n) async => [for (var i = 0; i < n; i++) await nextByte()];

    if (auth == null) {
      socket.add([5, 1, 0]);
      if ((await take(2))[1] != 0) return -1;
    } else {
      // method 2: user name and password (RFC 1929)
      socket.add([5, 1, 2]);
      if ((await take(2))[1] != 2) return -1;
      final user = utf8.encode(auth.user), pass = utf8.encode(auth.pass);
      socket.add([1, user.length, ...user, pass.length, ...pass]);
      if ((await take(2))[1] != 0) return -1;
    }
    final host = utf8.encode(uri.host);
    final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
    socket.add([5, 1, 0, 3, host.length, ...host, port >> 8, port & 255]);
    if ((await take(2))[1] != 0) return -1;
    // the rest of the SOCKS reply: reserved byte, address type, the address and the port
    final kind = (await take(2))[1];
    if (kind == 3) {
      await take((await nextByte()) + 2);
    } else {
      await take((kind == 4 ? 16 : 4) + 2);
    }
    final path = uri.path.isEmpty ? '/' : uri.path;
    final query = uri.hasQuery ? '?${uri.query}' : '';
    final request = utf8.encode('GET $path$query HTTP/1.1\r\n'
        'Host: ${uri.host}\r\nUser-Agent: Kumo\r\nConnection: keep-alive\r\n\r\n');

    // Sends the request, times the wait for the first byte of the answer, then reads the answer
    // to its end. `reusable` is false when its end cannot be found (no length given).
    Future<({int ms, bool reusable})> ask() async {
      final t = Stopwatch()..start();
      socket!.add(request);
      final head = <int>[await nextByte()];
      final ms = t.elapsedMilliseconds;
      while (!(head.length >= 4 &&
          head[head.length - 4] == 13 &&
          head[head.length - 3] == 10 &&
          head[head.length - 2] == 13 &&
          head[head.length - 1] == 10)) {
        head.add(await nextByte());
        if (head.length > 16384) return (ms: ms, reusable: false);
      }
      final text = utf8.decode(head, allowMalformed: true).toLowerCase();
      final status = RegExp(r'^http/1\.[01] (\d{3})').firstMatch(text)?.group(1);
      final length = int.tryParse(RegExp(r'content-length:\s*(\d+)').firstMatch(text)?.group(1) ?? '');
      final bodyless = status == '204' || status == '304' || length == 0;
      if (!bodyless && (length == null || length > 65536)) return (ms: ms, reusable: false);
      if (!bodyless) await take(length!);
      return (ms: ms, reusable: true);
    }

    final first = await ask();
    if (!first.reusable) return first.ms;
    return (await ask()).ms;
  } catch (_) {
    return -1;
  } finally {
    socket?.destroy();
  }
}
/// Two-stage test. Stage 1 drops servers whose port does not even accept a TCP connection
/// (cheap, many at once); stage 2 measures the real delay of the rest (a few at once).
///
/// With [tcpFirst] false (a user's own subscription) stage 1 is skipped: the user picked real delay.
///
/// Stops once [stopAfterAlive] servers answered in stage 2. [latencyMs] ends up as the real
/// delay, or -1 for servers that failed either stage. With [real] false only stage 1 runs
/// (needed while the VPN is up: the test core would go through the tunnel).
Future<void> testReal(
  List<ProxyConfig> candidates, {
  bool real = true,
  bool tcpFirst = true,
  int? stopAfterAlive,
  bool Function()? isCancelled,
  void Function(ProxyConfig c)? onResult,
}) async {
  if (!real) {
    return testLatencies(candidates,
        stopAfterAlive: stopAfterAlive,
        isCancelled: isCancelled,
        onResult: onResult);
  }
  final udp = tcpFirst
      ? candidates.where((c) => _udpProtocols.contains(c.protocol)).toList()
      : candidates;
  final tcp = tcpFirst
      ? candidates.where((c) => !_udpProtocols.contains(c.protocol)).toList()
      : <ProxyConfig>[];

  // The two stages overlap: a server that passed the TCP check goes straight to the real
  // delay workers while the rest are still being checked.
  final queue = Queue<ProxyConfig>.of(udp);
  var checking = true;
  var alive = 0;
  bool stop() =>
      (isCancelled?.call() ?? false) ||
      (stopAfterAlive != null && alive >= stopAfterAlive);

  // Stage 1: only the TCP servers. Servers never reached because it stopped early stay untested.
  // The TCP times only decide who goes on to the real delay; they are not shown as pings.
  final tcpMs = <ProxyConfig, int>{};
  final stage1 = testLatencies(
    tcp,
    stopAfterAlive: stopAfterAlive == null ? null : stopAfterAlive * 3,
    isCancelled: stop,
    into: tcpMs,
    onResult: (c) {
      if ((tcpMs[c] ?? -1) >= 0) {
        queue.add(c);
      } else {
        c.latencyMs = -1;
        onResult?.call(c);
      }
    },
  ).whenComplete(() => checking = false);

  // Stage 2: real delay.
  Future<void> worker() async {
    while (!stop()) {
      if (queue.isEmpty) {
        if (!checking) return;
        await Future<void>.delayed(const Duration(milliseconds: 40));
        continue;
      }
      final c = queue.removeFirst();
      final ms = await realDelay(c, timeout: const Duration(seconds: 5));
      // -2: skipped, so the old value stays
      if (ms != -2) c.latencyMs = ms;
      if (c.isAlive) alive++;
      onResult?.call(c);
    }
  }

  await Future.wait([stage1, ...List.generate(_realWorkers, (_) => worker())]);
}

// Every test starts its own core; more of them at once only slow each other down and inflate the
// numbers. A phone has far less CPU to share between their TLS handshakes than a computer.
final _realWorkers = Platform.isAndroid ? 4 : 6;

/// TCP connect time to the server in ms, or -1 if it can't be reached. The lookup of the server's
/// name comes first and is not counted: with it, every server with a name showed the time of a
/// DNS query on top of its own ping.
Future<int> tcpLatency(ProxyConfig c,
    {Duration timeout = const Duration(seconds: 3)}) async {
  try {
    final address = InternetAddress.tryParse(c.host) ??
        (await InternetAddress.lookup(c.host).timeout(timeout)).first;
    final sw = Stopwatch()..start();
    final s = await Socket.connect(address, c.port, timeout: timeout);
    s.destroy();
    return sw.elapsedMilliseconds;
  } catch (_) {
    return -1;
  }
}
/// Tests [candidates] with [concurrency] workers and calls [onResult] for each.
///
/// Stops early once [stopAfterAlive] reachable servers were found (the app only
/// needs a few good ones to connect quickly). [isCancelled] aborts the run.
Future<void> testLatencies(
  List<ProxyConfig> candidates, {
  int concurrency = 60,
  int? stopAfterAlive,
  Duration timeout = const Duration(seconds: 3),
  bool Function()? isCancelled,
  void Function(ProxyConfig c)? onResult,
  Map<ProxyConfig, int>? into,
}) async {
  var next = 0;
  var alive = 0;

  bool done() =>
      (isCancelled?.call() ?? false) ||
      (stopAfterAlive != null && alive >= stopAfterAlive) ||
      next >= candidates.length;

  Future<void> worker() async {
    while (!done()) {
      final c = candidates[next++];
      final ms = await tcpLatency(c, timeout: timeout);
      // into keeps the time out of the config (it is not its ping)
      if (into != null) {
        into[c] = ms;
      } else {
        c.latencyMs = ms;
      }
      if (ms >= 0) alive++;
      onResult?.call(c);
    }
  }

  await Future.wait(List.generate(concurrency, (_) => worker()));
}
