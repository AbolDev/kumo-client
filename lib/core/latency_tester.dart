import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'dart:convert';

import 'proxy_config.dart';
import 'vpn_channel.dart';

/// Page fetched through the proxy to measure the real delay. Plain HTTP on purpose: HTTPS adds a
/// TLS handshake with the site (two more round trips through the proxy) to every number.
const defaultDelayUrl = 'http://cp.cloudflare.com/generate_204';

/// The earlier default, replaced when it is found in saved settings.
const oldDefaultDelayUrl = 'https://www.google.com/generate_204';

/// The address used for the real delay; changed in Settings.
String delayTestUrl = defaultDelayUrl;

/// Protocols that run over UDP: a TCP connect to their port always fails, so they skip that stage.
const _udpProtocols = {'hysteria2', 'tuic'};

/// Minimal sing-box config holding only [c], used by the throw-away test core.
String _delayConfig(Map<String, dynamic> outbound) => jsonEncode({
      'log': {'level': 'error'},
      'dns': {
        'servers': [
          {'type': 'udp', 'tag': 'dns', 'server': '1.1.1.1'},
        ],
        'final': 'dns',
      },
      'outbounds': [
        {...outbound, 'tag': 'proxy'},
      ],
      'route': {'default_domain_resolver': 'dns'},
    });

/// The outbound with its server name already resolved by the system resolver. Resolving it inside
/// the throw-away core went through a fixed public DNS server, which is slow or blocked on many
/// networks and was counted in every result. The name stays where a server needs it (TLS server
/// name, Host header).
Future<Map<String, dynamic>> _resolved(ProxyConfig c) async {
  final out = Map<String, dynamic>.of(c.outbound);
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

/// Real delay: time to fetch a page through the server (handshake included), -1 on failure.
/// XHTTP servers need Xray, which only runs with the VPN, so they keep the TCP time.
Future<int> realDelay(ProxyConfig c,
    {Duration timeout = const Duration(seconds: 8)}) async {
  if (c.needsXray) return tcpLatency(c);
  final ms = await VpnChannel.delay(_delayConfig(await _resolved(c)), delayTestUrl,
      timeoutMs: timeout.inMilliseconds);
  return ms == -2 ? tcpLatency(c) : ms;
}

/// Delay of fetching [delayTestUrl] while the VPN is up, in ms, -1 on failure. The request
/// rides the tunnel; with Xray running the app is outside it, so the time to open a SOCKS
/// connection to the page's server through Xray's port ([socksPort]) is measured instead.
Future<int> tunnelDelay(
    {int? socksPort,
    int? proxyPort,
    Duration timeout = const Duration(seconds: 8)}) async {
  final uri = Uri.parse(delayTestUrl);
  final sw = Stopwatch()..start();
  try {
    if (socksPort == null) {
      final client = HttpClient()..connectionTimeout = timeout;
      // Without a tunnel the page is fetched through the local proxy instead.
      if (proxyPort != null) {
        client.findProxy = (_) => 'PROXY 127.0.0.1:$proxyPort';
      }
      try {
        final req = await client.getUrl(uri).timeout(timeout);
        final res = await req.close().timeout(timeout);
        await res.drain<void>().timeout(timeout);
      } finally {
        client.close(force: true);
      }
      return sw.elapsedMilliseconds;
    }
    final socket =
        await Socket.connect('127.0.0.1', socksPort, timeout: timeout);
    try {
      final reader = StreamIterator<List<int>>(socket);
      Future<List<int>> take(int n) async {
        final out = <int>[];
        while (out.length < n) {
          if (!await reader.moveNext().timeout(timeout)) {
            throw const SocketException('closed');
          }
          out.addAll(reader.current);
        }
        return out;
      }

      socket.add([5, 1, 0]);
      if ((await take(2))[1] != 0) return -1;
      final host = utf8.encode(uri.host);
      final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
      socket.add([5, 1, 0, 3, host.length, ...host, port >> 8, port & 255]);
      if ((await take(2))[1] != 0) return -1;
      // The proxy reached the server: that is the delay through Xray.
      return sw.elapsedMilliseconds;
    } finally {
      socket.destroy();
    }
  } catch (_) {
    return -1;
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
  final stage1 = testLatencies(
    tcp,
    stopAfterAlive: stopAfterAlive == null ? null : stopAfterAlive * 3,
    isCancelled: stop,
    onResult: (c) {
      if (c.isAlive) {
        queue.add(c);
      } else {
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
      c.latencyMs = await realDelay(c, timeout: const Duration(seconds: 5));
      if (c.isAlive) alive++;
      onResult?.call(c);
    }
  }

  await Future.wait([stage1, ...List.generate(_realWorkers, (_) => worker())]);
}

// Every test starts its own core; more of them at once only slow each other down and inflate the
// numbers.
const _realWorkers = 6;

/// TCP connect time to the server in ms, or -1 if it can't be reached.
Future<int> tcpLatency(ProxyConfig c,
    {Duration timeout = const Duration(seconds: 3)}) async {
  final sw = Stopwatch()..start();
  try {
    final s = await Socket.connect(c.host, c.port, timeout: timeout);
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
      c.latencyMs = await tcpLatency(c, timeout: timeout);
      if (c.isAlive) alive++;
      onResult?.call(c);
    }
  }

  await Future.wait(List.generate(concurrency, (_) => worker()));
}
