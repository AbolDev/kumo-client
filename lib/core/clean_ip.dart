import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'latency_tester.dart' show realDelay;
import 'link_fields.dart';
import 'proxy_config.dart';
import 'warp/warp_profile.dart' show cloudflareRanges, parseCidrV4;
import 'warp/warp_scan.dart' show pickScanAddresses;

/// "Find a clean IP": a server that sits behind a CDN (its name resolves to an address of Cloudflare,
/// Fastly ...) can be reached at many addresses of that CDN, and on some networks only some of them
/// work. This tries addresses of the CDN's ranges with the server's own settings (the name stays as
/// the TLS server name and the Host header) and says which ones answer fastest here. Everything runs
/// on this device.

/// Fastly's addresses (IPv4).
const fastlyRanges = ['151.101.0.0/16', '199.232.0.0/16', '146.75.0.0/16'];

/// The CDNs with ranges built in; anything else is typed in by the user.
enum Cdn { cloudflare, fastly }

List<String> rangesOf(Cdn cdn) => switch (cdn) {
      Cdn.cloudflare => cloudflareRanges,
      Cdn.fastly => fastlyRanges,
    };

/// The CDN whose range holds [ip], or null.
Cdn? cdnOf(String ip) {
  final n = _ipInt(ip);
  if (n == null) return null;
  for (final cdn in Cdn.values) {
    for (final r in rangesOf(cdn)) {
      final c = parseCidrV4(r, minBits: 8);
      if (c == null) continue;
      final mask = (0xFFFFFFFF << (32 - c.bits)) & 0xFFFFFFFF;
      if ((n & mask) == (c.base & mask)) return cdn;
    }
  }
  return null;
}

int? _ipInt(String ip) {
  final m = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$').firstMatch(ip);
  if (m == null) return null;
  var n = 0;
  for (var i = 1; i <= 4; i++) {
    final p = int.parse(m[i]!);
    if (p > 255) return null;
    n = (n << 8) | p;
  }
  return n;
}

/// The most ranges the user may type in, and the shortest prefix (a /8 is sixteen million addresses).
const maxCustomRanges = 32;

/// The ranges in [text], one "a.b.c.d/n" per line or separated by commas. Throws a [FormatException]
/// naming the first one that cannot be used.
List<String> parseRanges(String text) {
  final out = <String>[];
  for (final part in text.split(RegExp(r'[\s,;]+'))) {
    final r = part.trim();
    if (r.isEmpty) continue;
    if (parseCidrV4(r, minBits: 8) == null) throw FormatException('Not a range', r);
    out.add(r);
    if (out.length > maxCustomRanges) throw const FormatException('Too many ranges');
  }
  return out;
}

/// A copy of [source] that connects to [ip]: the old address stays where the server needs the name
/// (the TLS server name for TLS, the Host header for WebSocket, HTTP upgrade and HTTP transports).
/// Null when [source] is not a link of a server that can sit behind a CDN.
LinkFields? withCleanIp(LinkFields source, String ip) {
  if (!const {'vless', 'vmess', 'trojan'}.contains(source.scheme)) return null;
  final copy = LinkFields.parse(source.build());
  if (copy == null || copy.host.isEmpty) return null;
  final name = copy.host;
  final p = copy.params;
  final security = source.isVmess ? ((p['tls'] ?? '').isNotEmpty && p['tls'] != 'none' ? 'tls' : 'none') : (p['security'] ?? (source.scheme == 'trojan' ? 'tls' : 'none'));
  final transport = (p[source.isVmess ? 'net' : 'type'] ?? 'tcp');
  if (security == 'tls' && (p['sni'] ?? '').isEmpty) p['sni'] = name;
  if (const {'ws', 'httpupgrade', 'http', 'h2'}.contains(transport) && (p['host'] ?? '').isEmpty) {
    p['host'] = name;
  }
  copy.host = ip;
  return copy;
}

class CleanIp {
  const CleanIp(this.ip, this.tcpMs, this.delayMs);
  final String ip;

  /// Time of a TCP connection to the address, ms.
  final int tcpMs;

  /// The real delay through the server with this address, ms; null when not tested or no answer.
  final int? delayMs;
}

typedef TcpProbe = Future<int> Function(String ip, int port);
typedef DelayProbe = Future<int> Function(ProxyConfig config);

Future<int> _tcp(String ip, int port) async {
  try {
    final sw = Stopwatch()..start();
    final s = await Socket.connect(ip, port, timeout: const Duration(seconds: 2));
    s.destroy();
    return sw.elapsedMilliseconds;
  } catch (_) {
    return -1;
  }
}

Future<int> _delay(ProxyConfig c) => realDelay(c, timeout: const Duration(seconds: 7));

/// How many addresses are tried by TCP, and how many of the fastest of those get the real delay test.
const cleanIpTcpCount = 96;
const cleanIpDelayCount = 10;

/// Runs [jobs] (indices 0 until [count]) with [parallel] at a time.
Future<void> _pool(int count, int parallel, Future<void> Function(int i) job, bool Function()? cancelled) async {
  var next = 0;
  Future<void> worker() async {
    while (true) {
      if (cancelled?.call() == true) return;
      final i = next++;
      if (i >= count) return;
      await job(i);
    }
  }

  await Future.wait([for (var i = 0; i < min(parallel, max(1, count)); i++) worker()]);
}

/// Two stages: the addresses drawn from [ranges] are tried by a TCP connection to the server's port
/// (many at once); the fastest few get the real delay test with the server's own settings. The
/// answer is the ones that answered the real test, the fastest first (and, when none did, an empty
/// list). [onProgress] gets the stage (1 or 2), how many are done and how many there are.
Future<List<CleanIp>> scanCleanIps({
  required LinkFields server,
  required List<String> ranges,
  Random? random,
  TcpProbe tcp = _tcp,
  DelayProbe delay = _delay,
  int tcpCount = cleanIpTcpCount,
  int delayCount = cleanIpDelayCount,
  void Function(int stage, int done, int total)? onProgress,
  bool Function()? cancelled,
}) async {
  final port = int.tryParse(server.port) ?? 443;
  final addresses = pickScanAddresses(ranges, tcpCount, random ?? Random(), minBits: 8);
  if (addresses.isEmpty) return const [];

  // Stage 1.
  final open = <CleanIp>[];
  var done = 0;
  await _pool(addresses.length, 24, (i) async {
    final ms = await tcp(addresses[i], port);
    if (ms >= 0) open.add(CleanIp(addresses[i], ms, null));
    onProgress?.call(1, ++done, addresses.length);
  }, cancelled);
  if (cancelled?.call() == true || open.isEmpty) return const [];
  open.sort((a, b) => a.tcpMs.compareTo(b.tcpMs));
  final best = open.take(delayCount).toList();

  // Stage 2.
  final answered = <CleanIp>[];
  var tested = 0;
  await _pool(best.length, 3, (i) async {
    final fields = withCleanIp(server, best[i].ip);
    final config = fields == null ? null : parseLink(fields.build());
    var ms = -1;
    if (config != null) {
      try {
        ms = await delay(config);
      } catch (_) {}
    }
    if (ms >= 0) answered.add(CleanIp(best[i].ip, best[i].tcpMs, ms));
    onProgress?.call(2, ++tested, best.length);
  }, cancelled);
  answered.sort((a, b) => a.delayMs!.compareTo(b.delayMs!));
  return answered;
}
