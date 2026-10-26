import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// How a service answered.
enum ServiceResult { works, blocked, originalsOnly }

/// One service to try: its name and how the answer is read.
class ServiceProbe {
  const ServiceProbe(this.name, this.url, {this.check});

  final String name;
  final String url;

  /// Reads the answer; the default is "any answer that is not a server error or a block".
  final ServiceResult Function(int status, String body)? check;
}

ServiceResult _reachable(int status, String body) =>
    status > 0 && status < 400 ? ServiceResult.works : ServiceResult.blocked;

/// A service that answers 2xx / 3xx / 404 when it is reachable, but 403 / 451 when blocked.
ServiceResult _notBlocked(int status, String body) =>
    status > 0 && status != 403 && status != 451 && status < 500
        ? ServiceResult.works
        : ServiceResult.blocked;

ServiceResult _chatGpt(int status, String body) {
  final lower = body.toLowerCase();
  if (status <= 0 || status >= 500) return ServiceResult.blocked;
  if (lower.contains('unsupported_country') ||
      lower.contains('not supported') && lower.contains('country')) {
    return ServiceResult.blocked;
  }
  return status == 403 && !lower.contains('cookie')
      ? ServiceResult.blocked
      : ServiceResult.works;
}

/// The services the test page tries. Netflix has its own two-step test below.
const serviceProbes = <ServiceProbe>[
  ServiceProbe('ChatGPT', 'https://api.openai.com/compliance/cookie_requirements', check: _chatGpt),
  ServiceProbe('YouTube', 'https://www.youtube.com/generate_204', check: _reachable),
  ServiceProbe('Telegram', 'https://web.telegram.org/', check: _notBlocked),
  ServiceProbe('Instagram', 'https://www.instagram.com/', check: _notBlocked),
  ServiceProbe('Google', 'https://www.google.com/generate_204', check: _reachable),
  ServiceProbe('GitHub', 'https://github.com/', check: _notBlocked),
  ServiceProbe('Spotify', 'https://open.spotify.com/', check: _notBlocked),
  ServiceProbe('Wikipedia', 'https://www.wikipedia.org/', check: _notBlocked),
];

const netflixFull = 'https://www.netflix.com/title/70143836';
const netflixOriginals = 'https://www.netflix.com/title/81280792';

/// A GET through the local proxy of the running connection. Returns the status (-1 on failure),
/// the start of the body and the time it took in ms.
Future<({int status, String body, int ms})> fetchThrough(
  String url, {
  required int proxyPort,
  Duration timeout = const Duration(seconds: 12),
}) async {
  final sw = Stopwatch()..start();
  final client = HttpClient()..connectionTimeout = timeout;
  client.findProxy = (_) => 'PROXY 127.0.0.1:$proxyPort';
  client.badCertificateCallback = (_, __, ___) => false;
  try {
    final req = await client.getUrl(Uri.parse(url)).timeout(timeout);
    req.followRedirects = true;
    req.maxRedirects = 5;
    req.headers.set(HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120 Safari/537.36');
    final res = await req.close().timeout(timeout);
    final bytes = <int>[];
    await for (final chunk in res.timeout(timeout)) {
      bytes.addAll(chunk);
      if (bytes.length > 4096) break;
    }
    return (
      status: res.statusCode,
      body: utf8.decode(bytes, allowMalformed: true),
      ms: sw.elapsedMilliseconds,
    );
  } catch (_) {
    return (status: -1, body: '', ms: sw.elapsedMilliseconds);
  } finally {
    client.close(force: true);
  }
}

/// Tries [probe] and returns how it answered with the time taken.
Future<({ServiceResult result, int ms})> runProbe(ServiceProbe probe, int proxyPort) async {
  final r = await fetchThrough(probe.url, proxyPort: proxyPort);
  final check = probe.check ?? _reachable;
  return (result: check(r.status, r.body), ms: r.ms);
}

/// Netflix shows a different catalogue to each country: the full title says everything is
/// available, the original says only Netflix's own productions are.
Future<({ServiceResult result, int ms})> runNetflix(int proxyPort) async {
  final full = await fetchThrough(netflixFull, proxyPort: proxyPort);
  if (full.status == 200) return (result: ServiceResult.works, ms: full.ms);
  final originals = await fetchThrough(netflixOriginals, proxyPort: proxyPort);
  if (originals.status == 200) {
    return (result: ServiceResult.originalsOnly, ms: originals.ms);
  }
  return (result: ServiceResult.blocked, ms: full.ms);
}
