import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data' show BytesBuilder;

import 'latency_tester.dart' show realDelay;
import 'link_fields.dart';
import 'proxy_config.dart';
import 'usage/usage_transport.dart' show defaultFragment;
import 'warp/warp_profile.dart' show cloudflareRanges, parseCidrV4;
import 'warp/warp_register.dart' show FragmentRelay;
import 'warp/warp_scan.dart' show pickScanAddresses;

/// "Find a clean IP": a server that sits behind a CDN (its name resolves to an address of Cloudflare,
/// Fastly ...) can be reached at many addresses of that CDN, and on some networks only some of them
/// work. This tries addresses of the CDN's ranges, or a list of the user's own, and says which ones
/// answer best here: with the server's own settings (the name stays as the TLS server name and the
/// Host header), or by themselves. Everything runs on this device.

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

String _ipText(int n) => '${(n >> 24) & 255}.${(n >> 16) & 255}.${(n >> 8) & 255}.${n & 255}';

// ---------------------------------------------------------------- the user's own list

/// The most ranges the user may type in, and the most addresses of a list.
const maxCustomRanges = 32;
const cleanIpMaxList = 2000;
const maxDomains = 50;

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

/// What the user typed or loaded: ranges to draw addresses from, single addresses, names to look
/// up, and the entries that could not be read.
class Targets {
  Targets(this.ranges, this.ips, this.domains, this.bad);
  final List<String> ranges, ips, domains, bad;
  bool get isEmpty => ranges.isEmpty && ips.isEmpty && domains.isEmpty;
}

final _domain = RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9-]{1,63})+$');
final _span = RegExp(r'^(\d{1,3}(?:\.\d{1,3}){3})-(\d{1,3}(?:\.\d{1,3}){3}|\d{1,3})$');

/// Reads a list of IPv4 addresses (`1.2.3.4`), ranges (`1.2.3.4-1.2.3.40` or `1.2.3.4-40`), CIDR
/// ranges (`1.2.3.0/24`) and domain names, one per line or separated by commas, spaces or semicolons.
/// Lines starting with `#` are comments. An entry that cannot be read goes to [Targets.bad] (the
/// others are kept).
Targets parseTargets(String text) {
  final ranges = <String>[], ips = <String>[], domains = <String>[], bad = <String>[];
  final seen = <String>{};
  void addIp(String ip) {
    if (ips.length < cleanIpMaxList && seen.add(ip)) ips.add(ip);
  }

  for (final line in text.split(RegExp(r'\r?\n'))) {
    final trimmed = line.trim();
    if (trimmed.startsWith('#')) continue;
    for (final raw in trimmed.split(RegExp(r'[\s,;]+'))) {
      final t = raw.trim();
      if (t.isEmpty) continue;
      if (t.contains('/')) {
        if (parseCidrV4(t, minBits: 8) != null && ranges.length < maxCustomRanges) {
          ranges.add(t);
        } else {
          bad.add(t);
        }
        continue;
      }
      final span = _span.firstMatch(t);
      if (span != null) {
        final from = _ipInt(span[1]!);
        final end = span[2]!;
        final to = end.contains('.') ? _ipInt(end) : (from == null || int.parse(end) > 255 ? null : (from & ~255) | int.parse(end));
        if (from == null || to == null || to < from || to - from > 4096) {
          bad.add(t);
        } else {
          for (var n = from; n <= to; n++) {
            addIp(_ipText(n));
          }
        }
        continue;
      }
      if (_ipInt(t) != null) {
        addIp(t);
        continue;
      }
      // A name has a last part with a letter in it (so an address with a part over 255 is no name).
      if (_domain.hasMatch(t) && !RegExp(r'^\d+$').hasMatch(t.split('.').last) && domains.length < maxDomains) {
        domains.add(t.toLowerCase());
        continue;
      }
      bad.add(t);
    }
  }
  return Targets(ranges, ips, domains, bad);
}

/// A name's IPv4 addresses (the system's resolver).
Future<List<String>> lookupAll(String host) async {
  try {
    final found = await InternetAddress.lookup(host, type: InternetAddressType.IPv4).timeout(const Duration(seconds: 4));
    return [for (final a in found) a.address];
  } catch (_) {
    return const [];
  }
}

/// The addresses of [t]: its single addresses, and what its names resolve to (at most the limit of a list).
Future<List<String>> resolveTargets(Targets t, {Future<List<String>> Function(String host) lookup = lookupAll}) async {
  final out = <String>{...t.ips};
  for (final d in t.domains) {
    if (out.length >= cleanIpMaxList) break;
    out.addAll(await lookup(d));
  }
  return out.take(cleanIpMaxList).toList();
}

// ---------------------------------------------------------------- the server

/// True when the link of [f] uses TLS (so its name matters as the server name).
bool usesTls(LinkFields f) {
  final p = f.params;
  if (f.isVmess) return (p['tls'] ?? '').isNotEmpty && p['tls'] != 'none';
  return (p['security'] ?? (f.scheme == 'trojan' ? 'tls' : 'none')) == 'tls';
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
  final transport = (p[source.isVmess ? 'net' : 'type'] ?? 'tcp');
  if (usesTls(source) && (p['sni'] ?? '').isEmpty) p['sni'] = name;
  if (const {'ws', 'httpupgrade', 'http', 'h2'}.contains(transport) && (p['host'] ?? '').isEmpty) {
    p['host'] = name;
  }
  copy.host = ip;
  return copy;
}

/// The name a TLS connection to this server asks for, or null.
String? serverNameOf(LinkFields f) {
  final sni = (f.params['sni'] ?? '').trim();
  if (sni.isNotEmpty) return sni;
  return _ipInt(f.host) == null && f.host.isNotEmpty ? f.host : null;
}

// ---------------------------------------------------------------- options and results

/// How many addresses are tried by default, and the limits the user may set. (Cloudflare's ranges
/// hold about 1.5 million addresses and Fastly's about 200,000: a scan of thousands is still a small
/// sample of them.)
const cleanIpTcpCount = 1000;
const cleanIpDelayCount = 16;
const cleanIpMinCount = 10;
const cleanIpMaxCount = 10000;

/// The numbers of addresses the user picks from.
const cleanIpCountChoices = [200, 500, 1000, 2000, 5000, 10000];

/// The timeouts the user picks from (seconds).
const cleanIpTimeoutChoices = [1, 2, 3, 5];

/// How many probes run at once in the first stage: more for a bigger scan, so that thousands of
/// addresses take minutes, not an hour (and not more than 64: a network may take more for a flood).
int cleanIpWorkers(int addresses, {bool gentle = false}) =>
    gentle ? gentleWorkers : (addresses ~/ 40).clamp(24, 64).toInt();
const cleanIpMinTimeout = 1;
const cleanIpMaxTimeout = 10;
const cleanIpMaxSamples = 5;
const cleanIpMaxPorts = 8;

/// How many of the fastest open addresses are listed when no server takes part, and how many are
/// given the real test when the first stage is skipped.
const cleanIpKeep = 50;

/// How many of the best addresses are measured for speed through the server (when asked for), and the most.
const cleanIpSpeedCount = 8;
const cleanIpMaxSpeedCount = 20;
const cleanIpMaxRealTests = 60;

/// Gentle mode, for networks that cut the connection when a scan looks like a flood: few at once, a
/// long wait and a limit of probes a second.
const gentleWorkers = 12;
const gentleMinTimeout = 6;
const gentleProbesPerSecond = 40;

class ScanOptions {
  const ScanOptions({
    this.count = cleanIpTcpCount,
    this.timeoutSeconds = 2,
    this.gentle = false,
    this.ports = const [443],
    this.sni = '',
    this.stopAfter = 0,
    this.skipFirst = false,
    this.neighbors = false,
    this.samples = 1,
    this.fragment = false,
    this.keep = cleanIpKeep,
    this.delayCount = cleanIpDelayCount,
    this.speedTest = 0,
    this.speedCount = cleanIpSpeedCount,
  });

  /// How many addresses are drawn from the ranges.
  final int count;

  /// How long each probe waits.
  final int timeoutSeconds;
  final bool gentle;

  /// The ports tried without a server (with a server: its own port).
  final List<int> ports;

  /// Without a server: a TLS handshake for this name is tried instead of a plain connection.
  final String sni;

  /// Stop once this many good addresses were found (0: never).
  final int stopAfter;

  /// With a server: give every address the real test, without the first stage.
  final bool skipFirst;

  /// Also try the addresses next to the best ones.
  final bool neighbors;

  /// Probes per address (loss and jitter are measured from them).
  final int samples;

  /// Split the first bytes of the TLS hello (against filters that read the server name).
  final bool fragment;
  final int keep;
  final int delayCount;

  /// With a server: after the real test, the speed of the best addresses through the server. 0 none,
  /// 1 download, 2 upload, 3 both. [speedCount] is how many of them.
  final int speedTest;
  final int speedCount;

  /// The values brought inside their limits.
  ScanOptions normalized() => ScanOptions(
        count: count.clamp(cleanIpMinCount, cleanIpMaxCount),
        timeoutSeconds: timeoutSeconds.clamp(cleanIpMinTimeout, cleanIpMaxTimeout),
        gentle: gentle,
        ports: [for (final p in ports) if (p >= 1 && p <= 65535) p].take(cleanIpMaxPorts).toList().isEmpty
            ? const [443]
            : [for (final p in ports) if (p >= 1 && p <= 65535) p].take(cleanIpMaxPorts).toList(),
        sni: sni.trim(),
        stopAfter: stopAfter < 0 ? 0 : stopAfter,
        skipFirst: skipFirst,
        neighbors: neighbors,
        samples: samples.clamp(1, cleanIpMaxSamples),
        fragment: fragment,
        keep: keep.clamp(1, 200),
        delayCount: delayCount.clamp(1, cleanIpMaxRealTests),
        speedTest: speedTest.clamp(0, 3),
        speedCount: speedCount.clamp(1, cleanIpMaxSpeedCount),
      );

  Map<String, Object> toJson() => {
        'count': count,
        'timeout': timeoutSeconds,
        'gentle': gentle,
        'ports': ports,
        'sni': sni,
        'stopAfter': stopAfter,
        'skipFirst': skipFirst,
        'neighbors': neighbors,
        'samples': samples,
        'fragment': fragment,
        'speedTest': speedTest,
        'speedCount': speedCount,
      };

  static ScanOptions fromJson(Object? j) {
    if (j is! Map) return const ScanOptions();
    int i(String k, int d) => j[k] is int ? j[k] as int : d;
    bool b(String k) => j[k] == true;
    return ScanOptions(
      count: i('count', cleanIpTcpCount),
      timeoutSeconds: i('timeout', 2),
      gentle: b('gentle'),
      ports: j['ports'] is List ? [for (final p in j['ports'] as List) if (p is int) p] : const [443],
      sni: j['sni'] is String ? j['sni'] as String : '',
      stopAfter: i('stopAfter', 0),
      skipFirst: b('skipFirst'),
      neighbors: b('neighbors'),
      samples: i('samples', 1),
      fragment: b('fragment'),
      speedTest: i('speedTest', 0),
      speedCount: i('speedCount', cleanIpSpeedCount),
    ).normalized();
  }
}

class CleanIp {
  const CleanIp(this.ip, this.tcpMs, this.delayMs,
      {this.port = 443, this.loss = 0, this.jitterMs = 0, this.colo, this.downMbps, this.upMbps, this.ttfbMs});
  final String ip;
  final int port;

  /// Time of a connection to the address, ms (the middle one of the probes).
  final int tcpMs;

  /// The real delay through the server with this address, ms; null when not tested or no answer.
  final int? delayMs;

  /// The share of the probes that failed (0 to 1), and the spread of the ones that did, ms.
  final double loss;
  final int jitterMs;

  /// Cloudflare's data center ("FRA") and the speed of a download from the address, when asked for.
  /// With a server, [downMbps] and [upMbps] are the speed of a download and of an upload through the server
  /// with this address (Mbit/s), when asked for.
  final String? colo;
  final double? downMbps;
  final double? upMbps;
  final int? ttfbMs;

  CleanIp with_({String? colo, double? downMbps, double? upMbps, int? ttfbMs}) => CleanIp(ip, tcpMs, delayMs,
      port: port,
      loss: loss,
      jitterMs: jitterMs,
      colo: colo ?? this.colo,
      downMbps: downMbps ?? this.downMbps,
      upMbps: upMbps ?? this.upMbps,
      ttfbMs: ttfbMs ?? this.ttfbMs);

  Map<String, Object?> toJson() => {'ip': ip, 'port': port, 'ms': tcpMs, 'loss': loss, 'jitter': jitterMs};

  static CleanIp? fromJson(Object? j) {
    if (j is! Map || j['ip'] is! String || j['ms'] is! int) return null;
    return CleanIp(j['ip'] as String, j['ms'] as int, null,
        port: j['port'] is int ? j['port'] as int : 443,
        loss: j['loss'] is num ? (j['loss'] as num).toDouble() : 0,
        jitterMs: j['jitter'] is int ? j['jitter'] as int : 0);
  }
}

/// A scan that was stopped: the addresses not yet tried and the good ones found so far.
class ScanState {
  ScanState(this.pending, this.results);
  final List<String> pending;
  final List<CleanIp> results;

  Map<String, Object> toJson() => {
        'pending': pending,
        'results': [for (final r in results) r.toJson()],
      };

  static ScanState? fromJson(Object? j) {
    if (j is! Map || j['pending'] is! List) return null;
    final pending = [for (final p in j['pending'] as List) if (p is String && _ipInt(p) != null) p];
    final results = <CleanIp>[];
    if (j['results'] is List) {
      for (final r in j['results'] as List) {
        final parsed = CleanIp.fromJson(r);
        if (parsed != null) results.add(parsed);
      }
    }
    return ScanState(pending.take(cleanIpMaxList + cleanIpMaxCount).toList(), results);
  }
}

// ---------------------------------------------------------------- probes

typedef TcpProbe = Future<int> Function(String ip, int port);
typedef DelayProbe = Future<int> Function(ProxyConfig config);

/// The speed through a server, Mbit/s (null: not measured): a download, an upload, or both.
typedef SpeedProbe = Future<({double? down, double? up})> Function(ProxyConfig config, bool down, bool up);

/// [SpeedProbe] with a throw-away core and Cloudflare's speed test (see [realSpeed]).
Future<({double? down, double? up})> measureSpeedVia(ProxyConfig config, bool down, bool up) async {
  double? d, u;
  if (down) {
    final v = await realSpeed(config, upload: false);
    if (v >= 0) d = v;
  }
  if (up) {
    final v = await realSpeed(config, upload: true);
    if (v >= 0) u = v;
  }
  return (down: d, up: u);
}

/// A TCP connection to [ip]:[port]: the time it took in ms, -1 when it did not happen within [timeout].
Future<int> tcpProbe(String ip, int port, Duration timeout) async {
  try {
    final sw = Stopwatch()..start();
    final s = await Socket.connect(ip, port, timeout: timeout);
    s.destroy();
    return sw.elapsedMilliseconds;
  } catch (_) {
    return -1;
  }
}

/// A TLS handshake with [ip]:[port] for the server name [sni] (the certificate must be good for that
/// name): the time of the whole connection in ms, -1 when it failed or took longer than [timeout].
Future<int> tlsProbe(String ip, int port, String sni, Duration timeout) async {
  Socket? plain;
  SecureSocket? secure;
  try {
    final sw = Stopwatch()..start();
    plain = await Socket.connect(ip, port, timeout: timeout);
    secure = await SecureSocket.secure(plain, host: sni).timeout(timeout);
    return sw.elapsedMilliseconds;
  } catch (_) {
    return -1;
  } finally {
    secure?.destroy();
    plain?.destroy();
  }
}

/// [tlsProbe] with the first bytes of the TLS hello cut into small pieces, through a local relay (the
/// way the sign-up of WARP is done): for networks that read the server name in the hello.
Future<int> fragmentedTlsProbe(String ip, int port, String sni, Duration timeout) async {
  FragmentRelay? relay;
  Socket? plain;
  SecureSocket? secure;
  try {
    final sw = Stopwatch()..start();
    relay = await FragmentRelay.start(ip, port: port, size: defaultFragment.size, delay: defaultFragment.delay);
    plain = await Socket.connect(InternetAddress.loopbackIPv4, relay.port, timeout: timeout);
    secure = await SecureSocket.secure(plain, host: sni).timeout(timeout);
    return sw.elapsedMilliseconds;
  } catch (_) {
    return -1;
  } finally {
    secure?.destroy();
    plain?.destroy();
    await relay?.close();
  }
}

/// Lets a probe start only so often (the limit of probes a second of gentle mode).
class _Limiter {
  _Limiter(this.interval);
  final Duration interval;
  DateTime _next = DateTime.now();

  Future<void> take() async {
    if (interval == Duration.zero) return;
    final now = DateTime.now();
    final at = _next.isAfter(now) ? _next : now;
    _next = at.add(interval);
    final wait = at.difference(now);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
  }
}

/// Runs [job] for 0 until [count], [parallel] at a time, until [halted] says stop.
Future<void> _pool(int count, int parallel, Future<void> Function(int i) job, bool Function() halted) async {
  var next = 0;
  Future<void> worker() async {
    while (true) {
      if (halted()) return;
      final i = next++;
      if (i >= count) return;
      await job(i);
    }
  }

  await Future.wait([for (var i = 0; i < min(parallel, max(1, count)); i++) worker()]);
}

/// The addresses next to [ip] in its /24 (up to [reach] on each side), not [skip].
List<String> neighborsOf(String ip, {int reach = 8, Set<String> skip = const {}}) {
  final n = _ipInt(ip);
  if (n == null) return const [];
  final base = n & ~255;
  final out = <String>[];
  for (var d = 1; d <= reach; d++) {
    for (final m in [n - d, n + d]) {
      if ((m & ~255) != base) continue;
      final last = m & 255;
      if (last == 0 || last == 255) continue;
      final text = _ipText(m);
      if (!skip.contains(text)) out.add(text);
    }
  }
  return out;
}

// ---------------------------------------------------------------- the scan

/// Looks for addresses that answer. The addresses are the single ones in [addresses] plus
/// [options.count] drawn from [ranges] (or, with [resume], the ones that were left).
///
/// With a [server] (a link of a server behind a CDN) it is two stages: the addresses are tried by a
/// connection to the server's port (many at once; a TLS handshake for its name when the hello is
/// split); the fastest few get the real delay test with the server's own settings, which waits three
/// times as long as the timeout (at least 6 seconds). With [ScanOptions.skipFirst] every address goes
/// straight to the real test. The answer is the ones that answered the real test, the fastest first.
///
/// Without a server only the first stage is done, on [ScanOptions.ports]: by TCP, or, with
/// [ScanOptions.sni], by a TLS handshake. The answer is the best [ScanOptions.keep] open addresses
/// (the least loss, then the fastest).
///
/// [onResult] gets each good address as it is found; [onProgress] the stage (1 or 2), how many are
/// done and how many there are; [onCheckpoint] the state of the first stage every [checkpointEvery]
/// and when the scan is stopped, to be resumed later.
Future<List<CleanIp>> scanCleanIps({
  LinkFields? server,
  List<String> ranges = const [],
  List<String> addresses = const [],
  ScanOptions options = const ScanOptions(),
  ScanState? resume,
  Random? random,
  TcpProbe? tcp,
  DelayProbe? delay,
  SpeedProbe? speed,
  void Function(int stage, int done, int total)? onProgress,
  void Function(CleanIp result)? onResult,
  void Function(ScanState state)? onCheckpoint,
  Duration checkpointEvery = const Duration(seconds: 20),
  bool Function()? cancelled,
}) async {
  final o = options.normalized();
  final wait = Duration(seconds: o.gentle ? max(o.timeoutSeconds, gentleMinTimeout) : o.timeoutSeconds);
  final limiter = _Limiter(o.gentle ? Duration(microseconds: 1000000 ~/ gentleProbesPerSecond) : Duration.zero);
  final ports = server == null ? o.ports : [int.tryParse(server.port) ?? 443];
  final name = server == null ? (o.sni.isEmpty ? null : o.sni) : serverNameOf(server);
  final handshake = name != null && (server == null || (o.fragment && usesTls(server)));
  final probe = tcp ??
      (handshake
          ? (String ip, int p) => o.fragment ? fragmentedTlsProbe(ip, p, name, wait) : tlsProbe(ip, p, name, wait)
          : (String ip, int p) => tcpProbe(ip, p, wait));

  // The addresses.
  final List<String> list;
  if (resume != null) {
    list = resume.pending;
  } else {
    final drawn = ranges.isEmpty ? const <String>[] : pickScanAddresses(ranges, o.count, random ?? Random(), minBits: 8);
    list = {...addresses.take(cleanIpMaxList), ...drawn}.toList();
  }
  if (list.isEmpty) return const [];
  final workers = cleanIpWorkers(list.length * ports.length, gentle: o.gentle);

  var stop = false;
  bool halted() => stop || cancelled?.call() == true;
  final open = <CleanIp>[...?resume?.results];
  final tested = <String>{...open.map((r) => r.ip)};
  final remaining = <String>{...list};
  var done = 0, total = 0;

  ScanState snapshot() => ScanState(remaining.toList(), List.of(open));
  Timer? timer;
  if (onCheckpoint != null) timer = Timer.periodic(checkpointEvery, (_) => onCheckpoint(snapshot()));
  // Whatever happens in the scan (an error included), the saving of its state stops with it.
  try {

    /// The probes of one address on one port, [ScanOptions.samples] times; null when none answered.
    Future<CleanIp?> measure(String ip, int port) async {
      final times = <int>[];
      for (var s = 0; s < o.samples; s++) {
        if (halted()) break;
        await limiter.take();
        final ms = await probe(ip, port);
        if (ms >= 0) times.add(ms);
      }
      if (times.isEmpty) return null;
      times.sort();
      return CleanIp(ip, times[times.length ~/ 2], null,
          port: port, loss: (o.samples - times.length) / o.samples, jitterMs: times.last - times.first);
    }

    Future<void> firstStage(List<String> batch) async {
      final jobs = [
        for (final ip in batch)
          for (final p in ports) (ip, p),
      ];
      total += jobs.length;
      await _pool(jobs.length, workers, (i) async {
        final (ip, port) = jobs[i];
        final r = await measure(ip, port);
        tested.add(ip);
        if (port == ports.last) remaining.remove(ip);
        if (r != null) {
          open.add(r);
          // Shown at once, with a server too (the real test that follows replaces them).
          onResult?.call(r);
          if (server == null && o.stopAfter > 0 && open.length >= o.stopAfter) stop = true;
        }
        onProgress?.call(1, ++done, total);
      }, halted);
    }

    int byQuality(CleanIp a, CleanIp b) => a.loss != b.loss ? a.loss.compareTo(b.loss) : a.tcpMs.compareTo(b.tcpMs);

    if (server != null && o.skipFirst) {
      open
        ..clear()
        ..addAll(list.map((ip) => CleanIp(ip, 0, null, port: ports.first)));
    } else {
      await firstStage(list);
      // The addresses next to the best ones.
      if (o.neighbors && !halted() && open.isNotEmpty) {
        final best = [...open]..sort(byQuality);
        final extra = <String>{};
        for (final r in best.take(5)) {
          extra.addAll(neighborsOf(r.ip, skip: tested));
        }
        if (extra.isNotEmpty) {
          remaining.addAll(extra.take(40));
          await firstStage(extra.take(40).toList());
        }
      }
      timer?.cancel();
      // Stopped by the user: what is left can be taken up again.
      if (cancelled?.call() == true) onCheckpoint?.call(snapshot());
      if (cancelled?.call() == true || open.isEmpty) return open.isEmpty ? const [] : (server == null ? (open..sort(byQuality)).take(o.keep).toList() : const []);
      open.sort(byQuality);
      if (server == null) return open.take(o.keep).toList();
    }
    timer?.cancel();

    // The real test, with the server's own settings.
    final test = delay ??
        ((ProxyConfig c) => realDelay(c, timeout: Duration(seconds: max(6, wait.inSeconds * 3))));
    final best = open.take(o.skipFirst ? cleanIpMaxRealTests : o.delayCount).toList();
    stop = false;
    final answered = <CleanIp>[];
    var tested2 = 0;
    await _pool(best.length, o.gentle ? 2 : 3, (i) async {
      final fields = withCleanIp(server, best[i].ip);
      final config = fields == null ? null : parseLink(fields.build());
      var ms = -1;
      if (config != null) {
        try {
          ms = await test(config);
        } catch (_) {}
      }
      if (ms >= 0) {
        final r = CleanIp(best[i].ip, best[i].tcpMs, ms, port: best[i].port, loss: best[i].loss, jitterMs: best[i].jitterMs);
        answered.add(r);
        onResult?.call(r);
        if (o.stopAfter > 0 && answered.length >= o.stopAfter) stop = true;
      }
      onProgress?.call(2, ++tested2, best.length);
    }, halted);
    answered.sort((a, b) => a.delayMs!.compareTo(b.delayMs!));

    // The speed of the best addresses through the server, one at a time (they would take each other's
    // bandwidth). Each result is given as soon as it is measured.
    if (o.speedTest != 0 && answered.isNotEmpty) {
      final probe = speed ?? measureSpeedVia;
      final best = answered.take(o.speedCount).toList();
      var measured = 0;
      for (final r in best) {
        if (cancelled?.call() == true) break;
        final fields = withCleanIp(server, r.ip);
        final config = fields == null ? null : parseLink(fields.build());
        ({double? down, double? up}) got = (down: null, up: null);
        if (config != null) {
          try {
            got = await probe(config, o.speedTest & 1 != 0, o.speedTest & 2 != 0);
          } catch (_) {}
        }
        final updated = r.with_(downMbps: got.down, upMbps: got.up);
        answered[answered.indexOf(r)] = updated;
        onResult?.call(updated);
        onProgress?.call(3, ++measured, best.length);
      }
    }
    return answered;
  } finally {
    timer?.cancel();
  }
}

// ---------------------------------------------------------------- Cloudflare's data center and speed

/// What an HTTPS request to [ip]:[port] gave: the status, the start of the answer, the time to the
/// first byte and to the end, and how many bytes came. Null when it could not be made in time.
Future<({int status, String text, int ttfbMs, int totalMs, int bytes})?> httpsGet(
    String ip, int port, String sni, String host, String path, Duration timeout,
    {int maxBytes = 4096}) async {
  Socket? plain;
  SecureSocket? secure;
  try {
    plain = await Socket.connect(ip, port, timeout: timeout);
    secure = await SecureSocket.secure(plain, host: sni).timeout(timeout);
    final sw = Stopwatch()..start();
    secure.add(utf8.encode('GET $path HTTP/1.1\r\nHost: $host\r\nUser-Agent: Kumo\r\nConnection: close\r\n\r\n'));
    var ttfb = -1, bytes = 0;
    final head = BytesBuilder();
    await for (final chunk in secure.timeout(timeout)) {
      if (ttfb < 0) ttfb = sw.elapsedMilliseconds;
      bytes += chunk.length;
      if (head.length < maxBytes) head.add(chunk.length > maxBytes ? chunk.sublist(0, maxBytes) : chunk);
    }
    final text = utf8.decode(head.takeBytes(), allowMalformed: true);
    final status = int.tryParse(RegExp(r'^HTTP/\d\.\d (\d{3})').firstMatch(text)?[1] ?? '') ?? 0;
    return (status: status, text: text, ttfbMs: max(ttfb, 0), totalMs: sw.elapsedMilliseconds, bytes: bytes);
  } catch (_) {
    return null;
  } finally {
    secure?.destroy();
    plain?.destroy();
  }
}

/// The data center code of a Cloudflare address ("FRA"), from its trace page; null when it is not
/// Cloudflare or did not answer.
Future<String?> fetchColo(String ip, int port, Duration timeout) async {
  final r = await httpsGet(ip, port, 'www.cloudflare.com', 'www.cloudflare.com', '/cdn-cgi/trace', timeout);
  if (r == null || r.status != 200) return null;
  final colo = RegExp(r'^colo=([A-Za-z0-9]{2,5})\s*$', multiLine: true).firstMatch(r.text)?[1];
  return colo?.toUpperCase();
}

/// The speed of a download of [bytes] bytes from a Cloudflare address (the speed test of Cloudflare's
/// own site, which any of its addresses serves): Mbit/s and the time to the first byte.
Future<({double mbps, int ttfbMs})?> speedProbe(String ip, int port, Duration timeout, {int bytes = 2000000}) async {
  final r = await httpsGet(ip, port, 'speed.cloudflare.com', 'speed.cloudflare.com', '/__down?bytes=$bytes', timeout,
      maxBytes: 256);
  if (r == null || r.status != 200 || r.bytes < bytes ~/ 2) return null;
  final seconds = max(1, r.totalMs - r.ttfbMs) / 1000;
  return (mbps: r.bytes * 8 / 1e6 / seconds, ttfbMs: r.ttfbMs);
}

typedef ColoProbe = Future<String?> Function(String ip, int port);
typedef SpeedProbe = Future<({double mbps, int ttfbMs})?> Function(String ip, int port);

/// [results] with the data center ([colo]) and the download speed ([speed]) added for the first
/// [limit] of them (Cloudflare addresses only). [onProgress] gets how many are done and how many.
Future<List<CleanIp>> enrichResults(
  List<CleanIp> results, {
  bool colo = false,
  bool speed = false,
  int limit = 20,
  Duration timeout = const Duration(seconds: 6),
  ColoProbe? coloProbe,
  SpeedProbe? speedProbe_,
  void Function(int done, int total)? onProgress,
  bool Function()? cancelled,
}) async {
  if (!colo && !speed) return results;
  final out = [...results];
  final n = min(limit, out.length);
  var done = 0;
  await _pool(n, speed ? 2 : 4, (i) async {
    var r = out[i];
    if (colo) {
      final c = await (coloProbe ?? (ip, p) => fetchColo(ip, p, timeout))(r.ip, r.port);
      if (c != null) r = r.with_(colo: c);
    }
    if (speed) {
      final s = await (speedProbe_ ?? (ip, p) => speedProbe(ip, p, timeout * 3))(r.ip, r.port);
      if (s != null) r = r.with_(downMbps: s.mbps, ttfbMs: s.ttfbMs);
    }
    out[i] = r;
    onProgress?.call(++done, n);
  }, () => cancelled?.call() == true);
  return out;
}

// ---------------------------------------------------------------- Cloudflare's current ranges

List<String>? _liveRanges;

/// Cloudflare's published IPv4 ranges (cloudflare.com/ips-v4), asked for once per run of the app;
/// the built-in list when they cannot be had or do not look right.
Future<List<String>> liveCloudflareRanges({Future<String> Function(String url)? fetch}) async {
  final cached = _liveRanges;
  if (cached != null) return cached;
  try {
    final text = await (fetch ?? _get)('https://www.cloudflare.com/ips-v4');
    final lines = [
      for (final l in text.split(RegExp(r'\s+')))
        if (parseCidrV4(l.trim(), minBits: 8) != null) l.trim(),
    ];
    if (lines.length >= 5 && lines.length <= 64) return _liveRanges = lines;
  } catch (_) {}
  return cloudflareRanges;
}

Future<String> _get(String url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
  try {
    final req = await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 4));
    req.headers.set('User-Agent', 'Kumo');
    final res = await req.close().timeout(const Duration(seconds: 4));
    if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
    final bytes = BytesBuilder();
    await for (final c in res.timeout(const Duration(seconds: 4))) {
      bytes.add(c);
      if (bytes.length > 8192) throw const HttpException('too large');
    }
    return utf8.decode(bytes.toBytes());
  } finally {
    client.close(force: true);
  }
}

// ---------------------------------------------------------------- what to take away

/// The addresses as `ip:port`, one per line.
String endpointsText(List<CleanIp> results) => results.map((r) => '${r.ip}:${r.port}').join('\n');

/// The links of [server] for each address (a copy of the server that connects to it, named after it).
List<String> linksFor(LinkFields server, List<CleanIp> results) {
  final out = <String>[];
  for (final r in results) {
    final copy = withCleanIp(server, r.ip);
    if (copy == null) continue;
    copy.name = '${server.name} ${r.ip}'.trim();
    out.add(copy.build());
  }
  return out;
}

/// [links] as a subscription: one per line, in base64.
String subscriptionText(List<String> links) => base64.encode(utf8.encode(links.join('\n')));
