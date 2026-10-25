import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'proxy_config.dart';
import 'sub_formats.dart';

/// Where the config list is downloaded from, in order of preference.
///
/// raw.githubusercontent.com is often slow or blocked in Iran, so the list is
/// published somewhere reachable first and GitHub is only the last resort.
/// Put your own published list (e.g. a domain/IP reachable inside Iran) in
/// [kOwnSources]; it is tried before everything else.
const kOwnSources = <String>[];

const kMirrorSources = <String>[
  'https://cdn.jsdelivr.net/gh/barry-far/V2ray-Config@main/All_Configs_Sub.txt',
  'https://gcore.jsdelivr.net/gh/barry-far/V2ray-Config@main/All_Configs_Sub.txt',
  'https://fastly.jsdelivr.net/gh/barry-far/V2ray-Config@main/All_Configs_Sub.txt',
  'https://raw.githubusercontent.com/barry-far/V2ray-config/main/All_Configs_Sub.txt',
];

class FetchResult {
  FetchResult(this.links, this.source);
  final List<String> links;
  final String source;
}

class AllSourcesFailed implements Exception {
  AllSourcesFailed(this.errors);
  final List<String> errors;
  @override
  String toString() => 'هیچ‌کدام از منابع در دسترس نبود';
}

/// A downloaded subscription: its body and the name its provider gave it, if any.
class Fetched {
  Fetched(this.body, this.title, [this.info]);
  final String body;
  final String? title;
  final SubInfo? info;

  /// Builds the result from the raw response headers (also used for downloads the
  /// background job made).
  factory Fetched.fromHeaders(String body, String? profileTitle,
          String? disposition, String? userinfo) =>
      Fetched(body, subscriptionTitle(profileTitle, disposition, body),
          SubInfo.parse(userinfo));
}

/// Data volume and expiry that a provider reports in the `subscription-userinfo` header.
/// A missing or zero [total] / [expire] means unlimited.
class SubInfo {
  const SubInfo({this.used = 0, this.total = 0, this.expire = 0});

  final int used;
  final int total;

  /// Unix time in seconds, 0 = never.
  final int expire;

  bool get unlimitedData => total <= 0;
  bool get unlimitedTime => expire <= 0;

  static SubInfo? parse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final values = <String, int>{};
    for (final part in raw.split(';')) {
      final kv = part.split('=');
      if (kv.length != 2) continue;
      final n = num.tryParse(kv[1].trim());
      if (n != null) values[kv[0].trim().toLowerCase()] = n.toInt();
    }
    if (values.isEmpty) return null;
    return SubInfo(
      used: (values['upload'] ?? 0) + (values['download'] ?? 0),
      total: values['total'] ?? 0,
      expire: values['expire'] ?? 0,
    );
  }

  Map<String, int> toJson() => {'used': used, 'total': total, 'expire': expire};

  static SubInfo? fromJson(Object? j) => j is Map
      ? SubInfo(
          used: (j['used'] as num?)?.toInt() ?? 0,
          total: (j['total'] as num?)?.toInt() ?? 0,
          expire: (j['expire'] as num?)?.toInt() ?? 0)
      : null;
}

String? _decodeTitle(String raw) {
  var v = raw.trim();
  if (v.isEmpty) return null;
  try {
    if (v.startsWith('base64:')) {
      v = utf8.decode(base64.decode(base64.normalize(v.substring(7))));
    } else if (v.contains('%')) {
      v = Uri.decodeComponent(v);
    }
  } catch (_) {
    return null;
  }
  v = v.trim();
  return v.isEmpty ? null : v;
}

/// The subscription's own name: the profile-title header, the file name of the download,
/// or a `#profile-title:` line in the body.
String? subscriptionTitle(
    String? profileTitle, String? disposition, String body) {
  final title = profileTitle;
  if (title != null) {
    final t = _decodeTitle(title);
    if (t != null) return t;
  }
  if (disposition != null) {
    final m =
        RegExp("filename\\*?=(?:UTF-8'')?\"?([^\";]+)\"?", caseSensitive: false)
            .firstMatch(disposition);
    if (m != null) {
      var name = m.group(1)!;
      try {
        name = Uri.decodeComponent(name);
      } catch (_) {}
      name =
          name.replaceFirst(RegExp(r'\.(txt|yaml|yml|json|conf)$'), '').trim();
      if (name.isNotEmpty) return name;
    }
  }
  final line = RegExp(r'^#\s*profile-title:\s*(.+)$', multiLine: true)
      .firstMatch(body.length > 2000 ? body.substring(0, 2000) : body);
  return line == null ? null : _decodeTitle(line.group(1)!);
}

/// Downloads a subscription body. Throws on timeout / bad status.
Future<String> fetchText(String url,
        {Duration timeout = const Duration(seconds: 15)}) async =>
    (await fetchSubscription(url, timeout: timeout)).body;

/// Clients a provider may tailor its answer to; the next one is tried when a response
/// holds no servers.
const _clients = ['Mozilla/5.0', 'v2rayN/7.0', 'clash.meta', 'sing-box'];

Future<Fetched> fetchSubscription(String url,
    {Duration timeout = const Duration(seconds: 15),
    bool allowInsecure = false}) async {
  Fetched? first;
  Object? error;
  for (final agent in _clients) {
    try {
      final f = await _fetchOnce(url, agent, timeout, allowInsecure);
      first ??= f;
      if (extractSubscriptionLinks(f.body).isNotEmpty) return f;
    } catch (e) {
      error ??= e;
      if (first == null && agent == _clients.first && e is TimeoutException) {
        break;
      }
    }
  }
  if (first != null) return first;
  throw error ?? HttpException('No answer', uri: Uri.parse(url));
}

Future<Fetched> _fetchOnce(
    String url, String agent, Duration timeout, bool allowInsecure) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  if (allowInsecure) client.badCertificateCallback = (_, __, ___) => true;
  try {
    final req = await client.getUrl(Uri.parse(url)).timeout(timeout);
    req.headers
      ..set(HttpHeaders.userAgentHeader, agent)
      ..set(HttpHeaders.acceptHeader, 'application/json, text/plain, */*');
    final res = await req.close().timeout(timeout);
    if (res.statusCode != 200)
      throw HttpException('HTTP ${res.statusCode}', uri: Uri.parse(url));
    final body = await res.transform(utf8.decoder).join().timeout(timeout * 2);
    return Fetched.fromHeaders(
        body,
        res.headers.value('profile-title'),
        res.headers.value('content-disposition'),
        res.headers.value('subscription-userinfo'));
  } finally {
    client.close(force: true);
  }
}

/// Tries each source in turn and returns the first one that has configs.
Future<FetchResult> fetchFromSources({List<String>? sources}) async {
  final errors = <String>[];
  for (final url in sources ?? [...kOwnSources, ...kMirrorSources]) {
    try {
      final links = extractLinks(await fetchText(url));
      if (links.isNotEmpty) return FetchResult(links, url);
      errors.add('$url: empty');
    } catch (e) {
      errors.add('$url: $e');
    }
  }
  throw AllSourcesFailed(errors);
}
