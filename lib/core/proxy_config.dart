import 'dart:convert';
import 'dart:io' show File, Platform;
import 'dart:isolate';

part 'link_extra.dart';
part 'xray_outbound.dart';

/// A single proxy server parsed from a share link (vmess://, vless://, ...).
///
/// [outbound] is the sing-box outbound object (without a `tag`) and [xrayOutbound] the Xray one.
/// A server can have both (then the user's core preference decides), or only one:
/// - only Xray can carry XHTTP, mKCP, TCP with HTTP headers, VLESS encryption ...: [outbound] is
///   empty and [needsXray] is true;
/// - only sing-box can carry TUIC, AnyTLS, Hysteria 1, SSH, QUIC transport ...: [xrayOutbound]
///   is null.
class ProxyConfig {
  ProxyConfig({
    required this.link,
    required this.protocol,
    required this.name,
    required this.host,
    required this.port,
    required this.outbound,
    this.xrayOutbound,
    this.inner = const [],
    this.xrayNote = 'xhttp',
  });

  final String link;
  final String protocol;
  final String name;
  final String host;
  final int port;
  final Map<String, dynamic> outbound;
  final Map<String, dynamic>? xrayOutbound;

  /// More sing-box outbounds this one is dialled through, nearest to this one first (e.g. the
  /// ShadowTLS layer under a Shadowsocks server).
  final List<Map<String, dynamic>> inner;

  /// What Xray is needed for, shown in lists ("xhttp", "kcp", "http header", "encryption").
  final String xrayNote;

  /// TCP connect time in ms, null = not tested, -1 = unreachable.
  int? latencyMs;

  bool get isAlive => (latencyMs ?? -1) >= 0;

  /// True when sing-box cannot carry this server (it needs Xray).
  bool get needsXray => outbound.isEmpty && xrayOutbound != null;

  /// True when sing-box can carry this server.
  bool get canSingBox => outbound.isNotEmpty;

  /// True when Xray can carry this server.
  bool get canXray => xrayOutbound != null;

  /// The same server under another link text (the one it was saved with).
  ProxyConfig withLink(String original) => ProxyConfig(
        link: original,
        protocol: protocol,
        name: name,
        host: host,
        port: port,
        outbound: outbound,
        xrayOutbound: xrayOutbound,
        inner: inner,
        xrayNote: xrayNote,
      )..latencyMs = latencyMs;

  /// Short text for lists, e.g. "vless" or "vless + xhttp".
  String get label => needsXray ? '$protocol + $xrayNote' : protocol;

  /// "host:port" with the host partly hidden, for lists (the real address stays in the link).
  String get maskedAddress => '${maskHost(host)}:$port';

  /// Same connection settings (server, credentials, transport, TLS) => same key; used to drop
  /// duplicates. The name is not part of it, and two entries that differ in e.g. the websocket
  /// path or SNI are different servers.
  late final String key = outbound.isEmpty
      ? 'xray|${link.split('#').first}'
      : '$protocol|${jsonEncode([outbound, inner])}';
}

/// Hides most of an address, keeping its start and its last part:
/// `sub.example.com` -> `sub***.com`, `185.1.2.187` -> `185.1.2.187` -> `185.1.***`.
String maskHost(String host) {
  if (host.isEmpty) return host;
  final v4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.\d{1,3}\.\d{1,3}$').firstMatch(host);
  if (v4 != null) return '${v4[1]}.${v4[2]}.***';
  final head = host.length > 3 ? host.substring(0, 3) : host;
  final sep = host.contains(':') && !host.contains('.') ? ':' : '.';
  final i = host.lastIndexOf(sep);
  if (i <= 3) return '$head***';
  return '$head***${host.substring(i)}';
}

const _supportedSchemes = [
  'vmess://',
  'vless://',
  'trojan://',
  'ss://',
  'hysteria2://',
  'hy2://',
  'tuic://',
  'anytls://',
  'hysteria://',
  'socks5://',
  'socks4://',
  'socks4a://',
  'socks://',
  'ssh://',
  'wireguard://',
  'wg://',
  'naive+https://',
  'naive+quic://',
];

/// Splits a subscription body into share links. Handles both plain text lists
/// and a single base64 blob.
List<String> extractLinks(String body) {
  var text = convertTelegramProxyLinks(body.trim());
  if (!_supportedSchemes.any(text.contains)) {
    try {
      text = utf8.decode(_b64(text), allowMalformed: true);
    } catch (_) {
      return const [];
    }
  }
  // Several links may share a line (separated by spaces or commas) or have text before them.
  final out = <String>[];
  for (final line in text.split(RegExp(r'[\r\n]+'))) {
    for (final piece in line.split(_schemeStart)) {
      final l = piece.trim().replaceFirst(RegExp(r'''[,;'"]+$'''), '');
      if (_supportedSchemes.any(l.startsWith)) out.add(l);
    }
  }
  return out;
}

/// Zero-width match in front of each `scheme://` (not in the middle of a word: `vless://` ends in `ss://`).
final _schemeStart = RegExp(
    r'(?<![A-Za-z0-9])(?=(?:vmess|vless|trojan|ss|hysteria2|hy2|tuic|anytls|hysteria|socks5|socks4a|socks4|socks|ssh|wireguard|wg|naive\+https|naive\+quic)://)');

/// Parses and shuffles thousands of links off the UI thread.
///
/// Kept as a top-level function on purpose: a closure created inside a class method would
/// capture `this`, and objects like the AppState (with its streams) cannot be sent to an isolate.
Future<List<ProxyConfig>> parseLinksInBackground(List<String> links,
        {bool shuffle = true, bool secure = false}) =>
    Isolate.run(() {
      final parsed = parseLinks(links, secure: secure);
      return shuffle ? (parsed..shuffle()) : parsed;
    });

/// Parses all links, dropping unsupported/broken ones and duplicates. With [secure] the part of a
/// link that asks for its TLS certificate not to be checked is ignored (the link itself is kept as
/// it was).
List<ProxyConfig> parseLinks(List<String> links, {bool secure = false}) {
  final seen = <String>{};
  final out = <ProxyConfig>[];
  for (final l in links) {
    var c = parseLink(secure ? secureLink(l) : l);
    if (c != null && c.link != l) c = c.withLink(l);
    if (c != null && seen.add(c.key)) out.add(c);
  }
  return out;
}

const _insecureKeys = {
  'allowinsecure',
  'insecure',
  'allow_insecure',
  'skip-cert-verify',
  'skipcertverify',
};

/// [link] without the part that asks for its TLS certificate not to be checked
/// (`allowInsecure=1`, `insecure=1` ...). A certificate pin (`pcs`, `pinSHA256`) stays: it is a
/// check of its own.
String secureLink(String link) {
  try {
    if (link.startsWith('vmess://')) {
      final hashAt = link.indexOf('#');
      final body = hashAt < 0 ? link.substring(8) : link.substring(8, hashAt);
      final j = jsonDecode(utf8.decode(_b64(body), allowMalformed: true));
      if (j is! Map<String, dynamic>) return link;
      final drop = j.keys.where((k) => _insecureKeys.contains(k.toLowerCase())).toList();
      if (drop.isEmpty) return link;
      drop.forEach(j.remove);
      return 'vmess://${base64.encode(utf8.encode(jsonEncode(j)))}${hashAt < 0 ? '' : link.substring(hashAt)}';
    }
    final hashAt = link.indexOf('#');
    final head = hashAt < 0 ? link : link.substring(0, hashAt);
    final tail = hashAt < 0 ? '' : link.substring(hashAt);
    final q = head.indexOf('?');
    if (q < 0) return link;
    final parts = head.substring(q + 1).split('&');
    final kept = [
      for (final p in parts)
        if (!_insecureKeys.contains(p.split('=').first.toLowerCase())) p,
    ];
    if (kept.length == parts.length) return link;
    final base = head.substring(0, q);
    return kept.isEmpty ? '$base$tail' : '$base?${kept.join('&')}$tail';
  } catch (_) {
    return link;
  }
}

/// Whether [link] asks for its TLS certificate not to be checked.
bool asksInsecure(String link) => secureLink(link) != link;

ProxyConfig? parseLink(String link) {
  try {
    if (link.startsWith('vmess://')) return _vmess(link);
    if (link.startsWith('vless://')) return _vless(link);
    if (link.startsWith('trojan://')) return _trojan(link);
    if (link.startsWith('ss://')) return _shadowsocks(link);
    if (link.startsWith('hysteria2://') || link.startsWith('hy2://')) {
      return _hysteria2(link);
    }
    if (link.startsWith('tuic://')) return _tuic(link);
    if (link.startsWith('anytls://')) return _anytls(link);
    if (link.startsWith('hysteria://')) return _hysteria1(link);
    if (RegExp(r'^socks(5|4a|4)?://').hasMatch(link)) return _socks(link);
    if (link.startsWith('ssh://')) return _ssh(link);
    if (link.startsWith('wireguard://') || link.startsWith('wg://')) {
      return _wireguard(link);
    }
    if (link.startsWith('naive+')) return _naive(link);
  } catch (_) {
    // malformed link: skip it
  }
  return null;
}

// ---------------------------------------------------------------- helpers

/// Uri.parse that also copes with a user name or password written without escaping (a "#", an
/// "@", "<" ...), as some subscriptions have it: when the plain parse fails, everything before the
/// last "@" of the authority is escaped and the link is read again.
Uri _parseUri(String link) {
  try {
    return Uri.parse(link);
  } on FormatException {
    final scheme = link.indexOf('://');
    if (scheme < 0) rethrow;
    final start = scheme + 3;
    final q = link.indexOf('?', start);
    final end = q < 0 ? link.length : q;
    final at = link.lastIndexOf('@', end - 1);
    if (at < start) rethrow;
    final info = link
        .substring(start, at)
        .replaceAllMapped(RegExp(r'''[#@<>\[\]\s"^`{}|\\']'''),
            (m) => '%${m[0]!.codeUnitAt(0).toRadixString(16).toUpperCase().padLeft(2, '0')}');
    return Uri.parse('${link.substring(0, start)}$info${link.substring(at)}');
  }
}
List<int> _b64(String s) {
  var t = s.trim().replaceAll('-', '+').replaceAll('_', '/');
  t = t.padRight(t.length + (4 - t.length % 4) % 4, '=');
  return base64.decode(t);
}

String _b64s(String s) => utf8.decode(_b64(s), allowMalformed: true);

String _name(Uri u, String fallback) {
  if (u.fragment.isEmpty) return fallback;
  try {
    final n = Uri.decodeComponent(u.fragment).trim();
    return n.isEmpty ? fallback : n;
  } catch (_) {
    return u.fragment;
  }
}

String _decode(String s) {
  try {
    return Uri.decodeComponent(s);
  } catch (_) {
    return s;
  }
}

bool _isIp(String host) =>
    RegExp(r'^[\d.]+$').hasMatch(host) || host.contains(':');

bool _truthy(String? v) => v == '1' || v == 'true';

List<String> _alpn(String? v) => (v ?? '')
    .split(',')
    .map((e) => e.trim())
    .where((e) => e.isNotEmpty)
    .toList();

/// uTLS names sing-box knows. Any other value (`none`, `unsafe`, ...) would stop the core from
/// starting, so it is dropped.
const _fingerprints = {
  'chrome', 'firefox', 'edge', 'safari', '360', 'qq', 'ios', 'android', 'random', 'randomized',
};

String? _fingerprint(String? v) {
  final name = (v ?? '').trim().toLowerCase();
  return _fingerprints.contains(name) ? name : null;
}


final _domainName = RegExp(r'^(?:[A-Za-z0-9_-]+\.)+[A-Za-z]{2,}$');

/// Encrypted Client Hello from the `ech` share-link parameter: either a base64 ECHConfigList, or
/// (Xray style) a name, optionally with a DNS server (`front.example.com+https://1.1.1.1/dns-query`),
/// from which the core fetches the configuration itself.
Map<String, dynamic>? _ech(String? raw) {
  final v = (raw ?? '').trim();
  if (v.isEmpty) return null;
  if (v.contains('://') || _domainName.hasMatch(v)) {
    final name = v.split('+').first;
    return {
      'enabled': true,
      if (_domainName.hasMatch(name)) 'query_server_name': name,
    };
  }
  final b64 = v.replaceAll('-', '+').replaceAll('_', '/');
  final lines = <String>['-----BEGIN ECH CONFIGS-----'];
  for (var i = 0; i < b64.length; i += 64) {
    lines.add(b64.substring(i, i + 64 > b64.length ? b64.length : i + 64));
  }
  lines.add('-----END ECH CONFIGS-----');
  return {'enabled': true, 'config': lines};
}

/// "30" -> "30s"; anything with a unit is kept.
String _duration(String v) {
  final t = v.trim();
  return RegExp(r'^\d+$').hasMatch(t) ? '${t}s' : t;
}

/// "100", "100mbps", "100 Mbps" -> 100.
int? _mbps(String? v) {
  final m = RegExp(r'^\s*(\d+)').firstMatch(v ?? '');
  return m == null ? null : int.parse(m[1]!);
}

/// Builds the sing-box `tls` object from share-link parameters.
Map<String, dynamic> _tls(
  Map<String, String?> q,
  String host, {
  bool reality = false,
  String? sni,
  String? alpn,
  String? fp,
}) {
  final serverName = sni ?? q['sni'] ?? q['peer'] ?? q['host'];
  final tls = <String, dynamic>{'enabled': true};
  if (serverName != null && serverName.isNotEmpty) {
    tls['server_name'] = serverName;
  } else if (!_isIp(host)) {
    tls['server_name'] = host;
  }
  // A pinned certificate (Xray's pinnedPeerCertSha256) replaces chain validation: such servers
  // present a self-signed certificate that never matches the SNI. sing-box can only pin a public
  // key, not a certificate hash, so the pin is dropped and the chain check is skipped instead.
  final pinned =
      (q['pcs'] ?? q['pinSHA256'] ?? '').trim().isNotEmpty && !reality;
  if (pinned ||
      _truthy(q['allowInsecure']) ||
      _truthy(q['insecure']) ||
      _truthy(q['allow_insecure'])) {
    tls['insecure'] = true;
  }
  if (_truthy(q['disable_sni'])) tls['disable_sni'] = true;
  final protos = _alpn(alpn ?? q['alpn']);
  if (protos.isNotEmpty) tls['alpn'] = protos;
  final fingerprint = _fingerprint(fp ?? q['fp']);
  if (reality) {
    tls['reality'] = {
      'enabled': true,
      'public_key': q['pbk'] ?? '',
      'short_id': q['sid'] ?? '',
    };
    tls['utls'] = {
      'enabled': true,
      'fingerprint': (fingerprint?.isNotEmpty ?? false) ? fingerprint : 'chrome'
    };
  } else {
    if (fingerprint != null && fingerprint.isNotEmpty) {
      tls['utls'] = {'enabled': true, 'fingerprint': fingerprint};
    }
    final ech = _ech(q['ech']);
    if (ech != null) tls['ech'] = ech;
  }
  return tls;
}

/// The Host header for ws/httpupgrade/http: the `host` parameter, else the SNI (clients such as
/// v2rayN and Xray do the same; without it the header would carry the server's IP).
String? _hostHeader(String? host, String? sni) =>
    (host?.isNotEmpty ?? false) ? host : sni;

/// Returns the transport object, null for plain TCP, or [_unsupported].
const Object _unsupported = Object();

Object? _transport(String type,
    {String? path,
    String? host,
    String? serviceName,
    String? headerType,
    Map<String, String?> q = const {}}) {
  switch (type) {
    case '':
    case 'tcp':
    case 'raw':
      return headerType == 'http' ? _unsupported : null;
    case 'ws':
      var p = (path?.isNotEmpty ?? false) ? path! : '/';
      // "?ed=2048" is the early-data convention of Xray and v2ray: it is a setting, not part of
      // the path.
      final ed = RegExp(r'[?&]ed=(\d+)').firstMatch(p);
      if (ed != null) {
        p = p
            .replaceFirst(RegExp(r'\?ed=\d+&'), '?')
            .replaceFirst(RegExp(r'[?&]ed=\d+'), '');
        if (p.isEmpty) p = '/';
      }
      return {
        'type': 'ws',
        'path': p,
        if (host != null && host.isNotEmpty) 'headers': {'Host': host},
        if (ed != null) 'max_early_data': int.parse(ed[1]!),
        if (ed != null) 'early_data_header_name': 'Sec-WebSocket-Protocol',
      };
    case 'grpc':
      return {
        'type': 'grpc',
        'service_name': serviceName ?? path ?? '',
        if ((q['idle_timeout'] ?? '').isNotEmpty)
          'idle_timeout': _duration(q['idle_timeout']!),
        if ((q['ping_timeout'] ?? '').isNotEmpty)
          'ping_timeout': _duration(q['ping_timeout']!),
        if (_truthy(q['permit_without_stream'])) 'permit_without_stream': true,
      };
    case 'httpupgrade':
      return {
        'type': 'httpupgrade',
        'path': (path?.isNotEmpty ?? false) ? path : '/',
        if (host != null && host.isNotEmpty) 'host': host,
      };
    case 'h2':
    case 'http':
      return {
        'type': 'http',
        'path': (path?.isNotEmpty ?? false) ? path : '/',
        if (host != null && host.isNotEmpty) 'host': host.split(','),
      };
    case 'quic':
      return {'type': 'quic'};
    default: // xhttp, splithttp, kcp ... are not available in sing-box
      return _unsupported;
  }
}

/// A server that sing-box ([outbound]) and/or Xray ([xray]) can carry. Null when neither can.
ProxyConfig? _make(
  String link,
  String protocol,
  String name,
  String host,
  int port, {
  Map<String, dynamic>? outbound,
  Map<String, dynamic>? xray,
  List<Map<String, dynamic>> inner = const [],
  String xrayNote = 'xhttp',
}) {
  if (host.isEmpty || port <= 0 || port > 65535) return null;
  if ((outbound == null || outbound.isEmpty) && xray == null) return null;
  return ProxyConfig(
    link: link,
    protocol: protocol,
    name: name,
    host: host,
    port: port,
    outbound: outbound ?? const {},
    xrayOutbound: xray,
    inner: inner,
    xrayNote: xrayNote,
  );
}

ProxyConfig? _build(
  String link,
  String protocol,
  String name,
  String host,
  int port,
  Map<String, dynamic> outbound,
) =>
    _make(link, protocol, name, host, port, outbound: outbound);

bool _isXhttp(String? type) => type == 'xhttp' || type == 'splithttp';

/// What Xray is needed for when sing-box cannot carry a vless / vmess / trojan server.
String _xrayNoteFor(String type, String? headerType, {String? encryption}) {
  if (encryption != null && encryption.isNotEmpty && encryption != 'none') {
    return 'encryption';
  }
  if (_isXhttp(type)) return 'xhttp';
  if (type == 'kcp' || type == 'mkcp') return 'kcp';
  if ((type == 'tcp' || type == 'raw' || type.isEmpty) && headerType == 'http') {
    return 'http header';
  }
  return type;
}

// ---------------------------------------------------------------- protocols

ProxyConfig? _vless(String link) {
  final u = _parseUri(link);
  final q = u.queryParameters;
  final id = _decode(u.userInfo);
  final type = (q['type'] ?? 'tcp').toLowerCase();
  final security = q['security'] ?? 'none';
  final encryption = q['encryption'] ?? 'none';
  final name = _name(u, 'vless ${u.host}:${u.port}');

  final xray = _xrayOutbound(
    'vless',
    {
      'vnext': [
        {
          'address': u.host,
          'port': u.port,
          'users': [
            {
              'id': id,
              'encryption': encryption.isEmpty ? 'none' : encryption,
              if ((q['flow'] ?? '').isNotEmpty) 'flow': q['flow'],
            },
          ],
        },
      ],
    },
    q,
    u.host,
    type: type,
    security: security,
  );

  // sing-box has no VLESS encryption (ML-KEM) and no XHTTP, mKCP or TCP header obfuscation.
  Map<String, dynamic>? box;
  if ((encryption.isEmpty || encryption == 'none') && !_isXhttp(type)) {
    final out = <String, dynamic>{
      'type': 'vless',
      'server': u.host,
      'server_port': u.port,
      'uuid': id,
      'packet_encoding': 'xudp',
    };
    // "xtls-rprx-vision-udp443" is the same flow without blocking QUIC; sing-box has one name.
    if ((q['flow'] ?? '').startsWith('xtls-rprx-vision')) {
      out['flow'] = 'xtls-rprx-vision';
    } else if ((q['flow'] ?? '').isNotEmpty) {
      out['flow'] = q['flow'];
    }
    if (security == 'tls' || security == 'reality') {
      out['tls'] = _tls(q, u.host, reality: security == 'reality');
    }
    final t = _transport(
      type,
      path: q['path'],
      host: _hostHeader(q['host'], q['sni']),
      serviceName: q['serviceName'],
      headerType: q['headerType'],
      q: q,
    );
    if (t != _unsupported) {
      if (t != null) out['transport'] = t;
      box = out;
    }
  }
  return _make(link, 'vless', name, u.host, u.port,
      outbound: box,
      xray: xray,
      xrayNote: _xrayNoteFor(type, q['headerType'], encryption: encryption));
}

ProxyConfig? _vmess(String link) {
  // Some exporters add "#name" after the base64 text: it is not part of it.
  final rest = link.substring('vmess://'.length);
  final hash = rest.indexOf('#');
  final j = jsonDecode(_b64s(hash < 0 ? rest : rest.substring(0, hash)).trim())
      as Map<String, dynamic>;
  var fragment = hash < 0 ? '' : rest.substring(hash + 1);
  try {
    fragment = Uri.decodeComponent(fragment);
  } catch (_) {}
  final host = '${j['add'] ?? ''}';
  final port = int.tryParse('${j['port']}') ?? 0;
  final type = '${j['net'] ?? 'tcp'}'.toLowerCase();
  final tlsOn = '${j['tls'] ?? ''}' == 'tls';
  final ps = '${j['ps'] ?? ''}'.trim();
  final name = ps.isNotEmpty ? ps : (fragment.trim().isNotEmpty ? fragment.trim() : 'vmess $host:$port');
  final scy = ('${j['scy'] ?? ''}').isEmpty ? 'auto' : '${j['scy']}';

  // The same fields as the query of a vless link, for the Xray side.
  final q = <String, String?>{
    'sni': '${j['sni'] ?? ''}',
    'host': '${j['host'] ?? ''}',
    'path': '${j['path'] ?? ''}',
    'alpn': '${j['alpn'] ?? ''}',
    'fp': '${j['fp'] ?? ''}',
    'headerType': '${j['type'] ?? ''}',
    'serviceName': '${j['path'] ?? ''}',
    'seed': '${j['path'] ?? ''}',
    'mode': '${j['type'] ?? ''}',
    if (_truthy('${j['allowInsecure'] ?? j['insecure'] ?? ''}')) 'insecure': '1',
    'pcs': '${j['pcs'] ?? j['pinSHA256'] ?? ''}',
    'ech': '${j['ech'] ?? ''}',
  };
  final xray = _xrayOutbound(
    'vmess',
    {
      'vnext': [
        {
          'address': host,
          'port': port,
          'users': [
            {
              'id': '${j['id'] ?? ''}',
              'alterId': int.tryParse('${j['aid'] ?? 0}') ?? 0,
              'security': scy,
            },
          ],
        },
      ],
    },
    q,
    host,
    type: type,
    security: tlsOn ? 'tls' : 'none',
  );

  Map<String, dynamic>? box;
  if (!_isXhttp(type)) {
    final out = <String, dynamic>{
      'type': 'vmess',
      'server': host,
      'server_port': port,
      'uuid': '${j['id'] ?? ''}',
      'security': scy,
      'alter_id': int.tryParse('${j['aid'] ?? 0}') ?? 0,
    };
    final pe = '${j['pe'] ?? j['packetEncoding'] ?? ''}';
    if (pe == 'xudp' || pe == 'packetaddr') out['packet_encoding'] = pe;
    if (tlsOn) {
      out['tls'] = _tls(q, host, alpn: '${j['alpn'] ?? ''}', fp: '${j['fp'] ?? ''}');
    }
    final t = _transport(
      type,
      path: '${j['path'] ?? ''}',
      host: _hostHeader('${j['host'] ?? ''}', '${j['sni'] ?? ''}'),
      serviceName: '${j['path'] ?? ''}',
      headerType: '${j['type'] ?? ''}',
      q: q,
    );
    if (t != _unsupported) {
      if (t != null) out['transport'] = t;
      box = out;
    }
  }
  return _make(link, 'vmess', name, host, port,
      outbound: box, xray: xray, xrayNote: _xrayNoteFor(type, '${j['type'] ?? ''}'));
}

ProxyConfig? _trojan(String link) {
  final u = _parseUri(link);
  final q = u.queryParameters;
  final type = (q['type'] ?? 'tcp').toLowerCase();
  final security = q['security'] ?? 'tls';
  final password = _decode(u.userInfo);
  final name = _name(u, 'trojan ${u.host}:${u.port}');
  final xray = _xrayOutbound(
    'trojan',
    {
      'servers': [
        {'address': u.host, 'port': u.port, 'password': password},
      ],
    },
    q,
    u.host,
    type: type,
    security: security,
  );

  Map<String, dynamic>? box;
  if (!_isXhttp(type)) {
    final out = <String, dynamic>{
      'type': 'trojan',
      'server': u.host,
      'server_port': u.port,
      'password': password,
    };
    if (security != 'none') {
      out['tls'] = _tls(q, u.host, reality: security == 'reality');
    }
    final t = _transport(
      type,
      path: q['path'],
      host: _hostHeader(q['host'], q['sni']),
      serviceName: q['serviceName'],
      headerType: q['headerType'],
      q: q,
    );
    if (t != _unsupported) {
      if (t != null) out['transport'] = t;
      box = out;
    }
  }
  return _make(link, 'trojan', name, u.host, u.port,
      outbound: box, xray: xray, xrayNote: _xrayNoteFor(type, q['headerType']));
}

ProxyConfig? _shadowsocks(String link) {
  var body = link.substring('ss://'.length);
  var name = '';
  final hash = body.indexOf('#');
  if (hash >= 0) {
    name = _decode(body.substring(hash + 1)).trim();
    body = body.substring(0, hash);
  }
  final qm = body.indexOf('?');
  var query = <String, String>{};
  if (qm >= 0) {
    try {
      query = Uri.splitQueryString(body.substring(qm + 1));
    } catch (_) {}
    body = body.substring(0, qm);
  }
  body = body.replaceAll(RegExp(r'/$'), '');

  String userInfo;
  String hostPort;
  final at = body.lastIndexOf('@');
  if (at >= 0) {
    userInfo = body.substring(0, at);
    hostPort = body.substring(at + 1);
    userInfo = _decode(userInfo);
    if (!userInfo.contains(':')) userInfo = _b64s(userInfo);
  } else {
    final decoded = _b64s(body);
    final i = decoded.lastIndexOf('@');
    if (i < 0) return null;
    userInfo = decoded.substring(0, i);
    hostPort = decoded.substring(i + 1);
  }
  final colon = userInfo.indexOf(':');
  if (colon < 0) return null;
  final u = Uri.parse('ss://$hostPort');
  final method = userInfo.substring(0, colon);
  final password = userInfo.substring(colon + 1);
  final out = <String, dynamic>{
    'type': 'shadowsocks',
    'server': u.host,
    'server_port': u.port,
    'method': method,
    'password': password,
  };
  if (_truthy(query['uot']) || _truthy(query['udp-over-tcp'])) {
    out['udp_over_tcp'] = {'enabled': true, 'version': 2};
  }

  // SIP003 plugins: sing-box has obfs-local and v2ray-plugin built in, and ShadowTLS as a layer
  // under the Shadowsocks outbound. Xray has no plugins, so those servers are sing-box only.
  var inner = const <Map<String, dynamic>>[];
  final plugin = (query['plugin'] ?? '').trim();
  if (plugin.isNotEmpty) {
    final parts = plugin.split(';');
    final pname = parts.first;
    final opts = parts.skip(1).join(';');
    if (pname == 'obfs-local' || pname == 'simple-obfs') {
      out['plugin'] = 'obfs-local';
      out['plugin_opts'] = opts;
    } else if (pname == 'v2ray-plugin') {
      out['plugin'] = 'v2ray-plugin';
      out['plugin_opts'] = opts;
    } else if (pname == 'shadow-tls') {
      final o = <String, String>{
        for (final p in parts.skip(1))
          if (p.contains('=')) p.substring(0, p.indexOf('=')): p.substring(p.indexOf('=') + 1),
      };
      final version = int.tryParse(o['version'] ?? '3') ?? 3;
      final sni = o['host'] ?? o['sni'] ?? '';
      inner = [
        {
          'type': 'shadowtls',
          'server': u.host,
          'server_port': u.port,
          'version': version,
          if (version > 1) 'password': o['passwd'] ?? o['password'] ?? '',
          'tls': {
            'enabled': true,
            if (sni.isNotEmpty) 'server_name': sni,
            if (_fingerprint(o['fingerprint'] ?? o['fp']) != null)
              'utls': {
                'enabled': true,
                'fingerprint': _fingerprint(o['fingerprint'] ?? o['fp']),
              },
            if (_alpn(o['alpn']).isNotEmpty) 'alpn': _alpn(o['alpn']),
          },
        },
      ];
    } else {
      return null;
    }
  }
  final xray = plugin.isNotEmpty
      ? null
      : _xrayShadowsocks(u.host, u.port, method, password);
  return _make(link, 'ss', name.isEmpty ? 'ss ${u.host}:${u.port}' : name,
      u.host, u.port,
      outbound: out, xray: xray, inner: inner);
}

ProxyConfig? _hysteria2(String link) {
  // `host:443,5000-6000` lists extra ports for port hopping, which Uri cannot read.
  var hops = <String>[];
  var text = link.replaceFirst('hy2://', 'hysteria2://');
  final hop = RegExp(r'(@[^/?#@]+:\d+),([\d,\-]+)').firstMatch(text);
  if (hop != null) {
    hops = hop.group(2)!.split(',');
    text = text.replaceFirst(hop.group(0)!, hop.group(1)!);
  }
  final u = _parseUri(text);
  final q = u.queryParameters;
  if ((q['mport'] ?? '').isNotEmpty) hops = q['mport']!.split(',');
  final password = _decode(u.userInfo);
  final out = <String, dynamic>{
    'type': 'hysteria2',
    'server': u.host,
    'server_port': u.port,
    'password': password,
    'tls': _tls(q, u.host, alpn: q['alpn'] ?? 'h3'),
  };
  final ranges = [
    for (final h in hops)
      if (RegExp(r'^\d+(-\d+)?$').hasMatch(h.trim()))
          h.trim().contains('-') ? h.trim().replaceFirst('-', ':') : '${h.trim()}:${h.trim()}',
  ];
  if (ranges.isNotEmpty) out['server_ports'] = ranges;
  final hopInterval = q['hop-interval'] ?? q['hop_interval'] ?? q['hopInterval'];
  if (ranges.isNotEmpty && (hopInterval ?? '').isNotEmpty) {
    out['hop_interval'] = _duration(hopInterval!);
  }
  final up = _mbps(q['upmbps'] ?? q['up'] ?? q['up_mbps']);
  final down = _mbps(q['downmbps'] ?? q['down'] ?? q['down_mbps']);
  if (up != null) out['up_mbps'] = up;
  if (down != null) out['down_mbps'] = down;
  if (q['obfs'] == 'salamander') {
    out['obfs'] = {'type': 'salamander', 'password': q['obfs-password'] ?? ''};
  }
  final xray = _xrayHysteria2(u.host, u.port, password, q, ranges);
  return _make(link, 'hysteria2', _name(u, 'hysteria2 ${u.host}:${u.port}'),
      u.host, u.port,
      outbound: out, xray: xray, xrayNote: 'hysteria');
}

ProxyConfig? _tuic(String link) {
  final u = _parseUri(link);
  final q = u.queryParameters;
  final parts = u.userInfo.split(':');
  if (parts.length < 2) return null;
  final out = <String, dynamic>{
    'type': 'tuic',
    'server': u.host,
    'server_port': u.port,
    'uuid': _decode(parts[0]),
    'password': _decode(parts.sublist(1).join(':')),
    'congestion_control': q['congestion_control'] ?? 'bbr',
    'tls': _tls(q, u.host, alpn: q['alpn'] ?? 'h3'),
  };
  if (_truthy(q['udp_over_stream'])) {
    out['udp_over_stream'] = true;
  } else {
    out['udp_relay_mode'] = q['udp_relay_mode'] ?? 'native';
  }
  if (_truthy(q['zero_rtt_handshake']) ||
      _truthy(q['reduce_rtt']) ||
      _truthy(q['zero_rtt'])) {
    out['zero_rtt_handshake'] = true;
  }
  if ((q['heartbeat'] ?? '').isNotEmpty) out['heartbeat'] = _duration(q['heartbeat']!);
  return _build(
      link, 'tuic', _name(u, 'tuic ${u.host}:${u.port}'), u.host, u.port, out);
}
