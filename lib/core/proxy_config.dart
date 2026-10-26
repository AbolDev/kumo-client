import 'dart:convert';
import 'dart:isolate';

/// A single proxy server parsed from a share link (vmess://, vless://, ...).
///
/// Most servers are described by [outbound], a sing-box outbound object (without a `tag`).
/// XHTTP servers are not supported by sing-box: for those [xrayOutbound] holds an Xray
/// outbound instead and [outbound] is empty (see [needsXray]).
class ProxyConfig {
  ProxyConfig({
    required this.link,
    required this.protocol,
    required this.name,
    required this.host,
    required this.port,
    required this.outbound,
    this.xrayOutbound,
  });

  final String link;
  final String protocol;
  final String name;
  final String host;
  final int port;
  final Map<String, dynamic> outbound;
  final Map<String, dynamic>? xrayOutbound;

  /// TCP connect time in ms, null = not tested, -1 = unreachable.
  int? latencyMs;

  bool get isAlive => (latencyMs ?? -1) >= 0;

  /// True for servers that only Xray-core can connect to (XHTTP transport).
  bool get needsXray => xrayOutbound != null;

  /// Short text for lists, e.g. "vless" or "vless + xhttp".
  String get label => needsXray ? '$protocol + xhttp' : protocol;

  /// "host:port" with the host partly hidden, for lists (the real address stays in the link).
  String get maskedAddress => '${maskHost(host)}:$port';

  /// Same connection settings (server, credentials, transport, TLS) => same key; used to drop
  /// duplicates. The name is not part of it, and two entries that differ in e.g. the websocket
  /// path or SNI are different servers.
  String get key {
    if (needsXray) return 'xray|${link.split('#').first}';
    return '$protocol|${jsonEncode(outbound)}';
  }
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
  'tuic://'
];

/// Splits a subscription body into share links. Handles both plain text lists
/// and a single base64 blob.
List<String> extractLinks(String body) {
  var text = body.trim();
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
    r'(?<![A-Za-z0-9])(?=(?:vmess|vless|trojan|ss|hysteria2|hy2|tuic)://)');

/// Parses and shuffles thousands of links off the UI thread.
///
/// Kept as a top-level function on purpose: a closure created inside a class method would
/// capture `this`, and objects like the AppState (with its streams) cannot be sent to an isolate.
Future<List<ProxyConfig>> parseLinksInBackground(List<String> links,
        {bool shuffle = true}) =>
    Isolate.run(() {
      final parsed = parseLinks(links);
      return shuffle ? (parsed..shuffle()) : parsed;
    });

/// Parses all links, dropping unsupported/broken ones and duplicates.
List<ProxyConfig> parseLinks(List<String> links) {
  final seen = <String>{};
  final out = <ProxyConfig>[];
  for (final l in links) {
    final c = parseLink(l);
    if (c != null && seen.add(c.key)) out.add(c);
  }
  return out;
}

ProxyConfig? parseLink(String link) {
  try {
    if (link.startsWith('vmess://')) return _vmess(link);
    if (link.startsWith('vless://')) return _vless(link);
    if (link.startsWith('trojan://')) return _trojan(link);
    if (link.startsWith('ss://')) return _shadowsocks(link);
    if (link.startsWith('hysteria2://') || link.startsWith('hy2://'))
      return _hysteria2(link);
    if (link.startsWith('tuic://')) return _tuic(link);
  } catch (_) {
    // malformed link: skip it
  }
  return null;
}

// ---------------------------------------------------------------- helpers

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
  } else if (fingerprint != null && fingerprint.isNotEmpty) {
    tls['utls'] = {'enabled': true, 'fingerprint': fingerprint};
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
    {String? path, String? host, String? serviceName, String? headerType}) {
  switch (type) {
    case '':
    case 'tcp':
      return headerType == 'http' ? _unsupported : null;
    case 'ws':
      return {
        'type': 'ws',
        'path': (path?.isNotEmpty ?? false) ? path : '/',
        if (host != null && host.isNotEmpty) 'headers': {'Host': host},
      };
    case 'grpc':
      return {'type': 'grpc', 'service_name': serviceName ?? path ?? ''};
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
    default: // xhttp, splithttp, kcp, quic, ... are not available in sing-box
      return _unsupported;
  }
}

ProxyConfig? _build(
  String link,
  String protocol,
  String name,
  String host,
  int port,
  Map<String, dynamic> outbound,
) {
  if (host.isEmpty || port <= 0 || port > 65535) return null;
  return ProxyConfig(
      link: link,
      protocol: protocol,
      name: name,
      host: host,
      port: port,
      outbound: outbound);
}

// ---------------------------------------------------------------- XHTTP (Xray)

bool _isXhttp(String? type) => type == 'xhttp' || type == 'splithttp';

/// Builds an Xray outbound for an XHTTP server. [settings] is the protocol part
/// (`vnext` for vless/vmess, `servers` for trojan); [q] holds the share-link parameters.
ProxyConfig? _xhttp(
  String link,
  String protocol,
  String name,
  String host,
  int port,
  Map<String, dynamic> settings,
  Map<String, String?> q, {
  required String security,
}) {
  if (host.isEmpty || port <= 0 || port > 65535) return null;

  final xhttp = <String, dynamic>{
    'path': (q['path']?.isNotEmpty ?? false) ? q['path'] : '/',
    'mode': (q['mode']?.isNotEmpty ?? false) ? q['mode'] : 'auto',
  };
  // The native side swaps the server name for its IP, so the Host header must be pinned here.
  if (q['host']?.isNotEmpty ?? false) {
    xhttp['host'] = q['host'];
  } else if (!_isIp(host)) {
    xhttp['host'] = host;
  }
  final extra = q['extra'];
  if (extra != null && extra.isNotEmpty) {
    try {
      xhttp['extra'] = jsonDecode(extra);
    } catch (_) {
      // an unreadable "extra" block only loses optional tuning
    }
  }

  final stream = <String, dynamic>{
    'network': 'xhttp',
    'security': security,
    'xhttpSettings': xhttp,
  };
  if (security == 'tls' || security == 'reality') {
    var serverName = q['sni'] ?? q['peer'] ?? '';
    if (serverName.isEmpty && !_isIp(host)) serverName = host;
    final fingerprint = (q['fp']?.isNotEmpty ?? false) ? q['fp'] : 'chrome';
    if (security == 'tls') {
      final alpn = _alpn(q['alpn']);
      stream['tlsSettings'] = {
        if (serverName.isNotEmpty) 'serverName': serverName,
        'fingerprint': fingerprint,
        if (alpn.isNotEmpty) 'alpn': alpn,
        // a pinned certificate stands in for chain validation (see _tls)
        if (_truthy(q['allowInsecure']) ||
            _truthy(q['insecure']) ||
            (q['pcs'] ?? q['pinSHA256'] ?? '').trim().isNotEmpty)
          'allowInsecure': true,
      };
    } else {
      stream['realitySettings'] = {
        if (serverName.isNotEmpty) 'serverName': serverName,
        'fingerprint': fingerprint,
        'publicKey': q['pbk'] ?? '',
        'shortId': q['sid'] ?? '',
        'spiderX': q['spx'] ?? '',
      };
    }
  }

  return ProxyConfig(
    link: link,
    protocol: protocol,
    name: name,
    host: host,
    port: port,
    outbound: const {},
    xrayOutbound: {
      'protocol': protocol,
      'settings': settings,
      'streamSettings': stream
    },
  );
}

// ---------------------------------------------------------------- protocols

ProxyConfig? _vless(String link) {
  final u = Uri.parse(link);
  final q = u.queryParameters;
  final out = <String, dynamic>{
    'type': 'vless',
    'server': u.host,
    'server_port': u.port,
    'uuid': _decode(u.userInfo),
    'packet_encoding': 'xudp',
  };
  if ((q['flow'] ?? '').isNotEmpty) out['flow'] = q['flow'];

  final security = q['security'] ?? 'none';
  if (_isXhttp(q['type'])) {
    final user = <String, dynamic>{
      'id': _decode(u.userInfo),
      'encryption':
          (q['encryption']?.isNotEmpty ?? false) ? q['encryption'] : 'none',
      if ((q['flow'] ?? '').isNotEmpty) 'flow': q['flow'],
    };
    return _xhttp(
      link,
      'vless',
      _name(u, 'vless ${u.host}:${u.port}'),
      u.host,
      u.port,
      {
        'vnext': [
          {
            'address': u.host,
            'port': u.port,
            'users': [user]
          },
        ],
      },
      q,
      security: security,
    );
  }
  if (security == 'tls' || security == 'reality') {
    out['tls'] = _tls(q, u.host, reality: security == 'reality');
  }
  final t = _transport(
    q['type'] ?? 'tcp',
    path: q['path'],
    host: _hostHeader(q['host'], q['sni']),
    serviceName: q['serviceName'],
    headerType: q['headerType'],
  );
  if (t == _unsupported) return null;
  if (t != null) out['transport'] = t;
  return _build(link, 'vless', _name(u, 'vless ${u.host}:${u.port}'), u.host,
      u.port, out);
}

ProxyConfig? _vmess(String link) {
  final j = jsonDecode(_b64s(link.substring('vmess://'.length)).trim())
      as Map<String, dynamic>;
  final host = '${j['add'] ?? ''}';
  final port = int.tryParse('${j['port']}') ?? 0;
  final out = <String, dynamic>{
    'type': 'vmess',
    'server': host,
    'server_port': port,
    'uuid': '${j['id'] ?? ''}',
    'security': ('${j['scy'] ?? ''}').isEmpty ? 'auto' : '${j['scy']}',
    'alter_id': int.tryParse('${j['aid'] ?? 0}') ?? 0,
  };
  if (_isXhttp('${j['net']}')) {
    final q = <String, String?>{
      'sni': '${j['sni'] ?? ''}',
      'host': '${j['host'] ?? ''}',
      'path': '${j['path'] ?? ''}',
      'alpn': '${j['alpn'] ?? ''}',
      'fp': '${j['fp'] ?? ''}',
    };
    final ps = '${j['ps'] ?? ''}'.trim();
    return _xhttp(
      link,
      'vmess',
      ps.isEmpty ? 'vmess $host:$port' : ps,
      host,
      port,
      {
        'vnext': [
          {
            'address': host,
            'port': port,
            'users': [
              {
                'id': '${j['id'] ?? ''}',
                'alterId': int.tryParse('${j['aid'] ?? 0}') ?? 0,
                'security':
                    ('${j['scy'] ?? ''}').isEmpty ? 'auto' : '${j['scy']}',
              },
            ],
          },
        ],
      },
      q,
      security: '${j['tls'] ?? ''}' == 'tls' ? 'tls' : 'none',
    );
  }
  if ('${j['tls'] ?? ''}' == 'tls') {
    final q = <String, String?>{
      'sni': '${j['sni'] ?? ''}',
      'host': '${j['host'] ?? ''}',
      if (_truthy('${j['allowInsecure'] ?? j['insecure'] ?? ''}')) 'insecure': '1',
      'pcs': '${j['pcs'] ?? j['pinSHA256'] ?? ''}',
    };
    out['tls'] =
        _tls(q, host, alpn: '${j['alpn'] ?? ''}', fp: '${j['fp'] ?? ''}');
  }
  final t = _transport(
    '${j['net'] ?? 'tcp'}',
    path: '${j['path'] ?? ''}',
    host: _hostHeader('${j['host'] ?? ''}', '${j['sni'] ?? ''}'),
    serviceName: '${j['path'] ?? ''}',
    headerType: '${j['type'] ?? ''}',
  );
  if (t == _unsupported) return null;
  if (t != null) out['transport'] = t;
  final ps = '${j['ps'] ?? ''}'.trim();
  return _build(
      link, 'vmess', ps.isEmpty ? 'vmess $host:$port' : ps, host, port, out);
}

ProxyConfig? _trojan(String link) {
  final u = Uri.parse(link);
  final q = u.queryParameters;
  final out = <String, dynamic>{
    'type': 'trojan',
    'server': u.host,
    'server_port': u.port,
    'password': _decode(u.userInfo),
  };
  if (_isXhttp(q['type'])) {
    return _xhttp(
      link,
      'trojan',
      _name(u, 'trojan ${u.host}:${u.port}'),
      u.host,
      u.port,
      {
        'servers': [
          {'address': u.host, 'port': u.port, 'password': _decode(u.userInfo)},
        ],
      },
      q,
      security: q['security'] ?? 'tls',
    );
  }
  if ((q['security'] ?? 'tls') != 'none') {
    out['tls'] = _tls(q, u.host, reality: q['security'] == 'reality');
  }
  final t = _transport(
    q['type'] ?? 'tcp',
    path: q['path'],
    host: _hostHeader(q['host'], q['sni']),
    serviceName: q['serviceName'],
    headerType: q['headerType'],
  );
  if (t == _unsupported) return null;
  if (t != null) out['transport'] = t;
  return _build(link, 'trojan', _name(u, 'trojan ${u.host}:${u.port}'), u.host,
      u.port, out);
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
  if (qm >= 0) {
    // plugins (obfs, v2ray-plugin, ...) are not supported
    if (body.substring(qm).contains('plugin=')) return null;
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
  final out = <String, dynamic>{
    'type': 'shadowsocks',
    'server': u.host,
    'server_port': u.port,
    'method': userInfo.substring(0, colon),
    'password': userInfo.substring(colon + 1),
  };
  return _build(link, 'ss', name.isEmpty ? 'ss ${u.host}:${u.port}' : name,
      u.host, u.port, out);
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
  final u = Uri.parse(text);
  final q = u.queryParameters;
  if ((q['mport'] ?? '').isNotEmpty) hops = q['mport']!.split(',');
  final out = <String, dynamic>{
    'type': 'hysteria2',
    'server': u.host,
    'server_port': u.port,
    'password': _decode(u.userInfo),
    'tls': _tls(q, u.host, alpn: q['alpn'] ?? 'h3'),
  };
  final ranges = [
    for (final h in hops)
      if (RegExp(r'^\d+(-\d+)?$').hasMatch(h.trim()))
          h.trim().contains('-') ? h.trim().replaceFirst('-', ':') : '${h.trim()}:${h.trim()}',
  ];
  if (ranges.isNotEmpty) out['server_ports'] = ranges;
  if (q['obfs'] == 'salamander') {
    out['obfs'] = {'type': 'salamander', 'password': q['obfs-password'] ?? ''};
  }
  return _build(link, 'hysteria2', _name(u, 'hysteria2 ${u.host}:${u.port}'),
      u.host, u.port, out);
}

ProxyConfig? _tuic(String link) {
  final u = Uri.parse(link);
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
    'udp_relay_mode': q['udp_relay_mode'] ?? 'native',
    'tls': _tls(q, u.host, alpn: q['alpn'] ?? 'h3'),
  };
  return _build(
      link, 'tuic', _name(u, 'tuic ${u.host}:${u.port}'), u.host, u.port, out);
}
