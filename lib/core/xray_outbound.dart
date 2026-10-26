part of 'proxy_config.dart';

// Xray outbounds built from the same share-link parameters as the sing-box ones. Xray carries
// what sing-box cannot (XHTTP, mKCP, TCP with HTTP headers, VLESS encryption) and can also be
// chosen as the default core for everything it supports (Settings).

/// uTLS names Xray knows; others fall back to Chrome.
const _xrayFingerprints = {
  'chrome', 'firefox', 'safari', 'ios', 'android', 'edge', '360', 'qq', 'random',
  'randomized', 'randomizednoalpn', 'unsafe',
};

String _xrayFingerprint(String? v) {
  final name = (v ?? '').trim().toLowerCase();
  return _xrayFingerprints.contains(name) ? name : 'chrome';
}

/// An Xray outbound for a vless / vmess / trojan server. [settings] is the protocol part (`vnext`
/// or `servers`). Null when Xray cannot carry the transport (QUIC, h2).
Map<String, dynamic>? _xrayOutbound(
  String protocol,
  Map<String, dynamic> settings,
  Map<String, String?> q,
  String host, {
  required String type,
  required String security,
}) {
  final stream = _xrayStream(q, host, type: type, security: security);
  if (stream == null) return null;
  return {'protocol': protocol, 'settings': settings, 'streamSettings': stream};
}

/// Xray `streamSettings`: the transport and the TLS / REALITY layer.
Map<String, dynamic>? _xrayStream(
  Map<String, String?> q,
  String host, {
  required String type,
  required String security,
}) {
  String? s(String key) {
    final v = q[key];
    return v == null || v.isEmpty ? null : v;
  }

  final stream = <String, dynamic>{};
  final path = s('path');
  var serverName = s('sni') ?? s('peer') ?? '';
  if (serverName.isEmpty && !_isIp(host)) serverName = host;
  // The Android side swaps the server name for its IP, so the Host header is fixed here.
  final hostHeader = s('host') ?? (serverName.isNotEmpty ? serverName : null);
  final finalmask = <String, dynamic>{};

  switch (type) {
    case '':
    case 'tcp':
    case 'raw':
      stream['network'] = 'raw';
      if (s('headerType') == 'http') {
        stream['rawSettings'] = {
          'header': {
            'type': 'http',
            'request': {
              'version': '1.1',
              'method': 'GET',
              'path': (path ?? '/').split(','),
              'headers': {
                if (hostHeader != null) 'Host': hostHeader.split(','),
              },
            },
          },
        };
      }
    case 'ws':
      stream['network'] = 'ws';
      stream['wsSettings'] = {
        'path': path ?? '/',
        if (hostHeader != null) 'host': hostHeader,
      };
    case 'grpc':
      stream['network'] = 'grpc';
      stream['grpcSettings'] = {
        'serviceName': s('serviceName') ?? path ?? '',
        if (s('authority') != null) 'authority': s('authority'),
        'multiMode': s('mode') == 'multi',
      };
    case 'httpupgrade':
      stream['network'] = 'httpupgrade';
      stream['httpupgradeSettings'] = {
        'path': path ?? '/',
        if (hostHeader != null) 'host': hostHeader,
      };
    case 'xhttp':
    case 'splithttp':
      final xhttp = <String, dynamic>{
        'path': path ?? '/',
        'mode': s('mode') ?? 'auto',
      };
      if (hostHeader != null) xhttp['host'] = hostHeader;
      final extra = s('extra');
      if (extra != null) {
        try {
          xhttp['extra'] = jsonDecode(extra);
        } catch (_) {
          // an unreadable "extra" block only loses optional tuning
        }
      }
      stream['network'] = 'xhttp';
      stream['xhttpSettings'] = xhttp;
    case 'kcp':
    case 'mkcp':
      stream['network'] = 'kcp';
      stream['kcpSettings'] = <String, dynamic>{};
      // Xray moved the header disguise and the seed into the final mask.
      const headers = {
        'srtp': 'srtp',
        'utp': 'utp',
        'wechat-video': 'wechat',
        'dtls': 'dtls',
        'wireguard': 'wireguard',
        'dns': 'dns',
      };
      finalmask['udp'] = [
        {
          'type': 'mkcp-legacy',
          'settings': {
            'header': headers[s('headerType') ?? ''] ?? '',
            'value': s('seed') ?? '',
          },
        },
      ];
    default: // quic, h2, ...: removed from Xray
      return null;
  }

  final fm = s('fm') ?? s('finalmask');
  if (fm != null) {
    try {
      final extra = jsonDecode(fm);
      if (extra is Map<String, dynamic>) finalmask.addAll(extra);
    } catch (_) {}
  }
  if (finalmask.isNotEmpty) stream['finalmask'] = finalmask;

  if (security == 'tls') {
    stream['security'] = 'tls';
    final alpn = _alpn(q['alpn']);
    final pins = (q['pcs'] ?? q['pinSHA256'] ?? '')
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    stream['tlsSettings'] = {
      if (serverName.isNotEmpty) 'serverName': serverName,
      'fingerprint': _xrayFingerprint(q['fp']),
      if (alpn.isNotEmpty) 'alpn': alpn,
      // A pinned certificate replaces the chain check (see _tls); Xray can check the pin itself.
      if (_truthy(q['allowInsecure']) ||
          _truthy(q['insecure']) ||
          _truthy(q['allow_insecure']) ||
          pins.isNotEmpty)
        'allowInsecure': true,
      if (pins.isNotEmpty) 'pinnedPeerCertSha256': pins,
      if (s('ech') != null) 'echConfigList': s('ech'),
    };
  } else if (security == 'reality') {
    stream['security'] = 'reality';
    stream['realitySettings'] = {
      if (serverName.isNotEmpty) 'serverName': serverName,
      'fingerprint': _xrayFingerprint(q['fp']),
      'publicKey': q['pbk'] ?? '',
      'shortId': q['sid'] ?? '',
      'spiderX': q['spx'] ?? '',
      if (s('pqv') != null) 'mldsa65Verify': s('pqv'),
    };
  } else {
    stream['security'] = 'none';
  }
  return stream;
}

/// Shadowsocks over Xray (no plugins). Null for old ciphers Xray does not have.
Map<String, dynamic>? _xrayShadowsocks(
    String host, int port, String method, String password) {
  const known = {
    'aes-128-gcm',
    'aes-256-gcm',
    'chacha20-ietf-poly1305',
    'chacha20-poly1305',
    'xchacha20-ietf-poly1305',
    'xchacha20-poly1305',
    'none',
  };
  if (!known.contains(method) && !method.startsWith('2022-blake3-')) return null;
  return {
    'protocol': 'shadowsocks',
    'settings': {
      'servers': [
        {'address': host, 'port': port, 'method': method, 'password': password},
      ],
    },
    'streamSettings': {'network': 'raw'},
  };
}

/// Hysteria 2 over Xray: the hysteria transport with its final-mask extras (Salamander,
/// port hopping, fixed bandwidth).
Map<String, dynamic>? _xrayHysteria2(String host, int port, String password,
    Map<String, String?> q, List<String> ranges) {
  final fm = <String, dynamic>{};
  if (q['obfs'] == 'salamander') {
    fm['udp'] = [
      {
        'type': 'salamander',
        'settings': {'password': q['obfs-password'] ?? ''},
      },
    ];
  }
  final quic = <String, dynamic>{};
  if (ranges.isNotEmpty) {
    final interval = q['hop-interval'] ?? q['hop_interval'] ?? q['hopInterval'] ?? '';
    quic['udpHop'] = {
      'ports': ranges.map((r) => r.replaceAll(':', '-')).join(','),
      'interval': RegExp(r'^\d+(-\d+)?$').hasMatch(interval) ? interval : '5-10',
    };
  }
  final up = _mbps(q['upmbps'] ?? q['up'] ?? q['up_mbps']);
  final down = _mbps(q['downmbps'] ?? q['down'] ?? q['down_mbps']);
  if (up != null || down != null) {
    quic['congestion'] = 'force-brutal';
    if (up != null) quic['brutalUp'] = '$up mbps';
    if (down != null) quic['brutalDown'] = '$down mbps';
  }
  if (quic.isNotEmpty) fm['quicParams'] = quic;
  var serverName = q['sni'] ?? q['peer'] ?? '';
  if (serverName.isEmpty && !_isIp(host)) serverName = host;
  return {
    'protocol': 'hysteria',
    'settings': {'version': 2, 'address': host, 'port': port},
    'streamSettings': {
      'network': 'hysteria',
      'hysteriaSettings': {'version': 2, 'auth': password},
      'security': 'tls',
      'tlsSettings': {
        if (serverName.isNotEmpty) 'serverName': serverName,
        'alpn': _alpn(q['alpn']).isEmpty ? ['h3'] : _alpn(q['alpn']),
        if (_truthy(q['insecure']) ||
            _truthy(q['allowInsecure']) ||
            (q['pinSHA256'] ?? '').isNotEmpty)
          'allowInsecure': true,
        if ((q['pinSHA256'] ?? '').isNotEmpty)
          'pinnedPeerCertSha256': [q['pinSHA256']!.replaceAll(':', '').toLowerCase()],
      },
      if (fm.isNotEmpty) 'finalmask': fm,
    },
  };
}
