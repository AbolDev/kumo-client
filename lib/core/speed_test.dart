import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'latency_tester.dart' show socksWarmDelay;
import 'singbox_config.dart' show XrayAuth;
import 'socks_get.dart';

/// A place the speed is measured against: where a file is downloaded from, where an upload goes (not every
/// server takes one) and a small page for the delay.
class SpeedServer {
  const SpeedServer(this.id, this.name, this.host, this.downloadUrl, this.pingUrl, {this.uploadUrl});

  final String id, name, host;

  /// The address of the download; `{bytes}` and `{mb}` become the size asked for.
  final String downloadUrl;
  final String pingUrl;

  /// Null where the server takes no upload.
  final String? uploadUrl;

  bool get canUpload => uploadUrl != null;

  /// The address of a download of [bytes] (a server that takes the size in MB takes 4 at least).
  String download(int bytes) {
    final mb = (bytes / 1000000).ceil();
    return downloadUrl.replaceAll('{bytes}', '$bytes').replaceAll('{mb}', '${mb < 4 ? 4 : mb}');
  }
}

/// The places to choose from. Cloudflare is the first and the default; the others are for when it is slow
/// or blocked on the network. Every host here is named in PRIVACY.md.
const speedServers = <SpeedServer>[
  SpeedServer(
    'cloudflare',
    'Cloudflare',
    'speed.cloudflare.com',
    'https://speed.cloudflare.com/__down?bytes={bytes}',
    'https://speed.cloudflare.com/__down?bytes=0',
    uploadUrl: 'https://speed.cloudflare.com/__up',
  ),
  SpeedServer(
    'librespeed-fra',
    'LibreSpeed · Frankfurt',
    'fra.speedtest.clouvider.net',
    'https://fra.speedtest.clouvider.net/backend/garbage.php?ckSize={mb}',
    'https://fra.speedtest.clouvider.net/backend/empty.php',
    uploadUrl: 'https://fra.speedtest.clouvider.net/backend/empty.php',
  ),
  SpeedServer(
    'librespeed-ams',
    'LibreSpeed · Amsterdam',
    'ams.speedtest.clouvider.net',
    'https://ams.speedtest.clouvider.net/backend/garbage.php?ckSize={mb}',
    'https://ams.speedtest.clouvider.net/backend/empty.php',
    uploadUrl: 'https://ams.speedtest.clouvider.net/backend/empty.php',
  ),
  SpeedServer(
    'librespeed-lon',
    'LibreSpeed · London',
    'lon.speedtest.clouvider.net',
    'https://lon.speedtest.clouvider.net/backend/garbage.php?ckSize={mb}',
    'https://lon.speedtest.clouvider.net/backend/empty.php',
    uploadUrl: 'https://lon.speedtest.clouvider.net/backend/empty.php',
  ),
  // OVH only offers files to download: no upload here.
  SpeedServer(
    'ovh',
    'OVH · Roubaix',
    'proof.ovh.net',
    'https://proof.ovh.net/files/100Mb.dat',
    'https://proof.ovh.net/',
  ),
];

SpeedServer speedServerById(String? id) => speedServers.firstWhere((s) => s.id == id, orElse: () => speedServers.first);

/// How the test reaches the internet: straight (no VPN, or the tunnel carries the app's own traffic by
/// itself), through the local proxy of a computer in the proxy mode, or through Xray's SOCKS port (on the
/// phone the app is outside the VPN while Xray runs).
class SpeedRoute {
  const SpeedRoute({this.viaVpn = false, this.proxyPort, this.socksPort, this.auth});

  /// True when a VPN connection carries the test, which is what the result is the speed of.
  final bool viaVpn;
  final int? proxyPort, socksPort;
  final XrayAuth? auth;
}

/// What a test measured. A value that could not be had is null.
class SpeedResult {
  const SpeedResult({
    required this.at,
    required this.serverId,
    required this.viaVpn,
    this.via,
    this.pingMs,
    this.jitterMs,
    this.downMbps,
    this.upMbps,
  });

  final DateTime at;
  final String serverId;
  final bool viaVpn;

  /// The name of the VPN server the test went through, to tell tests apart in the history.
  final String? via;
  final int? pingMs, jitterMs;
  final double? downMbps, upMbps;

  SpeedResult copyWith({int? pingMs, int? jitterMs, double? downMbps, double? upMbps}) => SpeedResult(
        at: at,
        serverId: serverId,
        viaVpn: viaVpn,
        via: via,
        pingMs: pingMs ?? this.pingMs,
        jitterMs: jitterMs ?? this.jitterMs,
        downMbps: downMbps ?? this.downMbps,
        upMbps: upMbps ?? this.upMbps,
      );

  Map<String, dynamic> toJson() => {
        'at': at.millisecondsSinceEpoch,
        'server': serverId,
        'vpn': viaVpn,
        if (via != null) 'via': via,
        if (pingMs != null) 'ping': pingMs,
        if (jitterMs != null) 'jitter': jitterMs,
        if (downMbps != null) 'down': downMbps,
        if (upMbps != null) 'up': upMbps,
      };

  static SpeedResult? fromJson(Object? j) {
    if (j is! Map) return null;
    final at = j['at'];
    final server = j['server'];
    if (at is! num || server is! String) return null;
    return SpeedResult(
      at: DateTime.fromMillisecondsSinceEpoch(at.toInt()),
      serverId: server,
      viaVpn: j['vpn'] == true,
      via: j['via'] is String ? j['via'] as String : null,
      pingMs: (j['ping'] as num?)?.toInt(),
      jitterMs: (j['jitter'] as num?)?.toInt(),
      downMbps: (j['down'] as num?)?.toDouble(),
      upMbps: (j['up'] as num?)?.toDouble(),
    );
  }
}

/// The last tests, newest first, at most [keep]. [list] is not changed.
List<SpeedResult> addToHistory(List<SpeedResult> list, SpeedResult r, {int keep = 30}) =>
    [r, ...list].take(keep).toList();

/// The file of the tests; [capMb] is the choice of the most data a test may use.
String encodeHistory(List<SpeedResult> list, {int? capMb}) =>
    jsonEncode({'tests': [for (final r in list) r.toJson()], if (capMb != null) 'capMb': capMb});

/// The choice of the most data kept in the file, or the default.
int decodeCapMb(String? text) {
  try {
    final j = jsonDecode(text ?? '');
    final v = j is Map ? j['capMb'] : null;
    return v is int && speedMbChoices.contains(v) ? v : speedDefaultMb;
  } catch (_) {
    return speedDefaultMb;
  }
}

/// The saved tests; whatever cannot be read is left out, and a damaged file gives an empty list.
List<SpeedResult> decodeHistory(String? text) {
  if (text == null || text.isEmpty) return [];
  try {
    final j = jsonDecode(text);
    if (j is! Map || j['tests'] is! List) return [];
    return [
      for (final e in j['tests'] as List)
        if (SpeedResult.fromJson(e) case final r?) r
    ];
  } catch (_) {
    return [];
  }
}

/// The stage a test is in.
enum SpeedStage { ping, download, upload }

/// The most data the download and the upload of a test may use each, in MB: the choices and the default.
const speedMbChoices = [20, 50, 100, 250, 500];
const speedDefaultMb = 50;

/// Counts the bytes of all the connections of a stage and says, every [every], how fast they went over the
/// last [span] (in Mbit/s), with the time since the start: the live number of a test.
class LiveRate {
  LiveRate(this.onRate, {this.every = const Duration(milliseconds: 250), this.span = const Duration(seconds: 1)});

  final void Function(double mbps, Duration elapsed) onRate;
  final Duration every, span;
  var _bytes = 0;
  final _clock = Stopwatch();
  final _samples = <(int, int)>[];
  Timer? _timer;

  int get total => _bytes;

  void add(int n) => _bytes += n;

  void start() {
    _clock.start();
    _samples.add((0, 0));
    _timer = Timer.periodic(every, (_) => tick());
  }

  /// One reading (the timer's; called by hand in tests).
  void tick() {
    final now = _clock.elapsedMicroseconds;
    _samples.add((now, _bytes));
    while (_samples.length > 2 && now - _samples.first.$1 > span.inMicroseconds) {
      _samples.removeAt(0);
    }
    final first = _samples.first;
    final dt = now - first.$1;
    if (dt <= 0) return;
    onRate((_bytes - first.$2) * 8 / (dt / 1e6) / 1e6, _clock.elapsed);
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _clock.stop();
  }
}

/// A page's delay: two requests over one connection, the second counts (the first opens everything on the
/// way, as in a real delay), in ms; -1 on failure.
Future<int> _ping(Uri uri, SpeedRoute route, Duration timeout) async {
  if (route.socksPort != null) return socksWarmDelay(route.socksPort!, uri, timeout, auth: route.auth);
  final client = HttpClient()..connectionTimeout = timeout;
  if (route.proxyPort != null) client.findProxy = (_) => 'PROXY 127.0.0.1:${route.proxyPort}';
  final sw = Stopwatch();
  try {
    for (var i = 0; i < 2; i++) {
      sw
        ..reset()
        ..start();
      final req = await client.getUrl(uri).timeout(timeout);
      final res = await req.close().timeout(timeout);
      await res.drain<void>().timeout(timeout);
    }
    return sw.elapsedMilliseconds;
  } catch (_) {
    return -1;
  } finally {
    client.close(force: true);
  }
}

/// How fast data goes through [route] to [url], in Mbit/s, over a plain connection or the local proxy; -1
/// when it could not be measured. A download counts what arrives until it ends or [window] has passed, minus
/// the [warmup]; an upload sends [bytes] of zeros and counts the time until the server has answered.
Future<double> httpSpeed(
  String url, {
  int? proxyPort,
  required bool upload,
  int bytes = 2000000,
  Duration window = const Duration(seconds: 8),
  Duration warmup = Duration.zero,
  int? maxBytes,
  void Function(int bytes)? onBytes,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty || (uri.scheme != 'http' && uri.scheme != 'https')) return -1;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  if (proxyPort != null) client.findProxy = (_) => 'PROXY 127.0.0.1:$proxyPort';

  Future<double> run() async {
    if (upload) {
      final req = await client.postUrl(uri);
      req.headers
        ..contentLength = bytes
        ..contentType = ContentType.binary;
      final chunk = Uint8List(32768);
      final sw = Stopwatch()..start();
      var left = bytes;
      var sinceFlush = 0;
      while (left > 0) {
        final n = left < chunk.length ? left : chunk.length;
        req.add(n == chunk.length ? chunk : Uint8List.sublistView(chunk, 0, n));
        left -= n;
        sinceFlush += n;
        onBytes?.call(n);
        if (sinceFlush >= 262144) {
          await req.flush();
          sinceFlush = 0;
        }
      }
      final res = await req.close();
      await res.drain<void>();
      sw.stop();
      if (res.statusCode >= 400) return -1;
      return bytes * 8 / (sw.elapsedMicroseconds / 1e6) / 1e6;
    }
    final req = await client.getUrl(uri);
    final res = await req.close();
    if (res.statusCode != 200) {
      await res.drain<void>();
      return -1;
    }
    final meter = RateMeter(warmup: warmup);
    final it = StreamIterator<List<int>>(res);
    while (true) {
      final left = meter.started ? window - meter.elapsed : window;
      if (left <= Duration.zero) break;
      final more = await it.moveNext().timeout(left, onTimeout: () => false);
      if (!more) break;
      meter.add(it.current.length);
      onBytes?.call(it.current.length);
      if (maxBytes != null && meter.total >= maxBytes) break;
    }
    return meter.mbps();
  }

  try {
    return await run().timeout(timeout, onTimeout: () => -1);
  } catch (_) {
    return -1;
  } finally {
    client.close(force: true);
  }
}

/// Runs [count] things at once and adds up what they give: the speed of several connections is what the
/// line carries (one connection alone often does not fill it). The ones that failed (below zero) are left
/// out; null when all failed.
Future<double?> _sum(int count, Future<double> Function(int i) one) async {
  final all = await Future.wait([for (var i = 0; i < count; i++) one(i)]);
  final good = all.where((v) => v >= 0).toList();
  return good.isEmpty ? null : good.fold<double>(0, (a, b) => a + b);
}

/// Tests the speed against [server] through [route]: the delay (the middle of [pings] tries, and how much
/// it moves), the download and the upload, each of them over [streams] connections for [window]. A
/// download leaves its first [warmup] out. Neither the download nor the upload uses more than [maxMb] MB (the
/// connections share it); a smaller share is cheaper and less exact on a fast line. [onStage] is told what is being measured and [onResult] gets
/// the numbers as they come, [onLive] the speed of the download or the upload while it runs (four times a second);
/// [cancelled] is asked between the stages and the result so far is returned.
Future<SpeedResult> runSpeedTest(
  SpeedServer server,
  SpeedRoute route, {
  String? via,
  int pings = 5,
  int streams = 4,
  int maxMb = speedDefaultMb,
  Duration window = const Duration(seconds: 8),
  Duration warmup = const Duration(seconds: 2),
  void Function(SpeedStage stage)? onStage,
  void Function(SpeedResult partial)? onResult,
  void Function(SpeedStage stage, double mbps, Duration elapsed)? onLive,
  bool Function()? cancelled,
  DateTime? now,
}) async {
  var r = SpeedResult(at: now ?? DateTime.now(), serverId: server.id, viaVpn: route.viaVpn, via: via);
  bool stop() => cancelled?.call() ?? false;
  // What each connection may use of the most.
  final share = (maxMb * 1000000 / streams).floor();

  Future<double> down(int bytes, LiveRate live) => route.socksPort != null
      ? socksSpeed(server.download(bytes), route.socksPort!,
          auth: route.auth,
          upload: false,
          window: window,
          warmup: warmup,
          maxBytes: bytes,
          onBytes: live.add,
          timeout: window + const Duration(seconds: 20))
      : httpSpeed(server.download(bytes),
          proxyPort: route.proxyPort,
          upload: false,
          window: window,
          warmup: warmup,
          maxBytes: bytes,
          onBytes: live.add,
          timeout: window + const Duration(seconds: 20));
  Future<double> up(int bytes, LiveRate live) => route.socksPort != null
      ? socksSpeed(server.uploadUrl!, route.socksPort!,
          auth: route.auth, upload: true, bytes: bytes, onBytes: live.add, timeout: window + const Duration(seconds: 25))
      : httpSpeed(server.uploadUrl!,
          proxyPort: route.proxyPort, upload: true, bytes: bytes, onBytes: live.add, timeout: window + const Duration(seconds: 25));

  // The delay.
  onStage?.call(SpeedStage.ping);
  final times = <int>[];
  final pingUri = Uri.parse(server.pingUrl);
  for (var i = 0; i < pings && !stop(); i++) {
    final ms = await _ping(pingUri, route, const Duration(seconds: 6));
    if (ms >= 0) times.add(ms);
  }
  if (times.isNotEmpty) {
    final sorted = [...times]..sort();
    var jitter = 0;
    if (times.length > 1) {
      var sum = 0;
      for (var i = 1; i < times.length; i++) {
        sum += (times[i] - times[i - 1]).abs();
      }
      jitter = (sum / (times.length - 1)).round();
    }
    r = r.copyWith(pingMs: sorted[sorted.length ~/ 2], jitterMs: jitter);
    onResult?.call(r);
  }
  if (stop()) return r;

  // The download: each connection asks for more than the window can carry.
  onStage?.call(SpeedStage.download);
  final liveDown = LiveRate((v, e) => onLive?.call(SpeedStage.download, v, e))..start();
  final d = await _sum(streams, (_) => down(share, liveDown));
  liveDown.stop();
  if (d != null) {
    r = r.copyWith(downMbps: d);
    onResult?.call(r);
  }
  if (stop() || !server.canUpload) return r;

  // The upload: a small try tells how much each connection may send in the window, so a slow line is not
  // asked for minutes and a fast one is not asked for too little to count.
  onStage?.call(SpeedStage.upload);
  final liveUp = LiveRate((v, e) => onLive?.call(SpeedStage.upload, v, e))..start();
  try {
  final probe = await up(300000, liveUp);
  if (probe >= 0 && !stop()) {
    // (The try is slow because the connection is still speeding up, so twice what it says is asked for.)
    final perStream = (probe * 1e6 / 8 * window.inSeconds * 2 / streams).clamp(100000, share < 8000000 ? share : 8000000).toInt();
    final u = await _sum(streams, (_) => up(perStream, liveUp));
    if (u != null) {
      r = r.copyWith(upMbps: u);
      onResult?.call(r);
    }
  }
  } finally {
    liveUp.stop();
  }
  return r;
}
