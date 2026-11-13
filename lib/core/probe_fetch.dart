import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// What came back from one address in the safety check of a server (see config_inspector.dart): the same on
/// the phone (libbox's Inspect gives it as JSON) and on a computer ([probeFetch] through a local proxy).
class ProbeResult {
  ProbeResult({
    required this.url,
    this.ok = false,
    this.status = 0,
    this.ms = 0,
    this.err = '',
    this.tls = false,
    this.verified,
    this.issuer = '',
    this.body = '',
  });

  final String url;

  /// An answer came (of any status).
  final bool ok;
  final int status;
  final int ms;
  final String err;

  /// An https address.
  final bool tls;

  /// Whether the certificate is valid for the name under the system's roots; null when that is not known
  /// (an http address, or no roots to judge by).
  final bool? verified;
  final String issuer;

  /// The first 4 KB of the page.
  final String body;

  factory ProbeResult.fromJson(Map<String, dynamic> j) => ProbeResult(
        url: '${j['url'] ?? ''}',
        ok: j['ok'] == true,
        status: (j['status'] as num?)?.toInt() ?? 0,
        ms: (j['ms'] as num?)?.toInt() ?? 0,
        err: '${j['err'] ?? ''}',
        tls: j['tls'] == true,
        verified: j['verified'] is bool ? j['verified'] as bool : null,
        issuer: '${j['issuer'] ?? ''}',
        body: '${j['body'] ?? ''}',
      );

  Map<String, dynamic> toJson() => {
        'url': url,
        'ok': ok,
        'status': status,
        'ms': ms,
        if (err.isNotEmpty) 'err': err,
        'tls': tls,
        if (verified != null) 'verified': verified,
        if (issuer.isNotEmpty) 'issuer': issuer,
        'size': body.length,
        if (body.isNotEmpty) 'body': body,
      };

  /// The list the phone's Inspect gives; empty when it is not one.
  static List<ProbeResult> listFromJson(String text) {
    try {
      final j = jsonDecode(text);
      if (j is! List) return const [];
      return [for (final e in j) if (e is Map) ProbeResult.fromJson(Map<String, dynamic>.from(e))];
    } catch (_) {
      return const [];
    }
  }
}

/// Fetches [uri] with a plain GET: through the HTTP proxy at 127.0.0.1:[proxyPort] when it is given, straight
/// from this device when not. A certificate that is not valid for the name does not stop it: it is noted in
/// [ProbeResult.verified] and the page is read all the same (nothing private is sent). The first 4 KB of the
/// page are kept.
Future<ProbeResult> probeFetch(Uri uri, {int? proxyPort, Duration timeout = const Duration(seconds: 10)}) async {
  final https = uri.scheme == 'https';
  bool? verified = https ? true : null;
  var issuer = '';
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..findProxy = (_) => proxyPort == null ? 'DIRECT' : 'PROXY 127.0.0.1:$proxyPort'
    ..badCertificateCallback = (cert, host, port) {
      verified = false;
      issuer = cert.issuer;
      return true;
    };
  final sw = Stopwatch()..start();
  try {
    final req = await client.getUrl(uri).timeout(timeout);
    req.followRedirects = false;
    req.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0 (compatible; Kumo)');
    final res = await req.close().timeout(timeout);
    final body = <int>[];
    await for (final chunk in res.timeout(timeout)) {
      body.addAll(chunk);
      if (body.length >= 4096) break;
    }
    if (issuer.isEmpty) issuer = res.certificate?.issuer ?? '';
    return ProbeResult(
      url: '$uri',
      ok: true,
      status: res.statusCode,
      ms: sw.elapsedMilliseconds,
      tls: https,
      verified: verified,
      issuer: issuer,
      body: utf8.decode(body.length > 4096 ? body.sublist(0, 4096) : body, allowMalformed: true),
    );
  } catch (e) {
    return ProbeResult(url: '$uri', err: '$e', tls: https);
  } finally {
    client.close(force: true);
  }
}
