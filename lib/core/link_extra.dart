part of 'proxy_config.dart';

// The less common protocols: AnyTLS, Hysteria 1, SOCKS, SSH, WireGuard and NaiveProxy (all
// sing-box; SOCKS, WireGuard and, through the hysteria2 code, Hysteria also run on Xray).

final _telegramSocks =
    RegExp(r'(?:tg://|https?://t\.me/)socks\?([^\s"<>]+)', caseSensitive: false);

/// Telegram's proxy links (`tg://socks?server=..&port=..&user=..&pass=..` and the t.me form)
/// become `socks5://` links. Done before the text is read as a subscription address.
String convertTelegramProxyLinks(String text) {
  if (!text.contains('socks?')) return text;
  return text.replaceAllMapped(_telegramSocks, (m) {
    try {
      final q = Uri.splitQueryString(m[1]!.replaceAll('&amp;', '&'));
      final server = q['server'], port = q['port'];
      if (server == null || port == null) return m[0]!;
      final user = q['user'] ?? '';
      final pass = q['pass'] ?? '';
      final auth = user.isEmpty
          ? ''
          : '${Uri.encodeComponent(user)}:${Uri.encodeComponent(pass)}@';
      return 'socks5://$auth$server:$port#${Uri.encodeComponent('Telegram $server')}';
    } catch (_) {
      return m[0]!;
    }
  });
}

/// "user:pass" from a link's user info, which may also be base64 of that.
(String, String) _userPass(String userInfo) {
  var info = _decode(userInfo);
  if (info.isEmpty) return ('', '');
  if (!info.contains(':')) {
    try {
      final decoded = _b64s(info);
      if (decoded.contains(':')) info = decoded;
    } catch (_) {}
  }
  final c = info.indexOf(':');
  return c < 0 ? (info, '') : (info.substring(0, c), info.substring(c + 1));
}

ProxyConfig? _socks(String link) {
  final scheme = link.substring(0, link.indexOf('://'));
  final u = Uri.parse(link);
  final port = u.hasPort ? u.port : 1080;
  final (user, pass) = _userPass(u.userInfo);
  final version = scheme == 'socks4' || scheme == 'socks4a' ? '4' : '5';
  final out = <String, dynamic>{
    'type': 'socks',
    'server': u.host,
    'server_port': port,
    'version': version,
    if (user.isNotEmpty) 'username': user,
    if (user.isNotEmpty) 'password': pass,
  };
  final xray = version == '5'
      ? {
          'protocol': 'socks',
          'settings': {
            'servers': [
              {
                'address': u.host,
                'port': port,
                if (user.isNotEmpty) 'users': [{'user': user, 'pass': pass}],
              },
            ],
          },
          'streamSettings': {'network': 'raw'},
        }
      : null;
  return _make(link, 'socks', _name(u, 'socks ${u.host}:$port'), u.host, port,
      outbound: out, xray: xray);
}

ProxyConfig? _anytls(String link) {
  final u = Uri.parse(link);
  final q = u.queryParameters;
  final out = <String, dynamic>{
    'type': 'anytls',
    'server': u.host,
    'server_port': u.port,
    'password': _decode(u.userInfo),
    'tls': _tls(q, u.host),
  };
  for (final key in const [
    'idle_session_check_interval',
    'idle_session_timeout',
  ]) {
    if ((q[key] ?? '').isNotEmpty) out[key] = _duration(q[key]!);
  }
  if (int.tryParse(q['min_idle_session'] ?? '') != null) {
    out['min_idle_session'] = int.parse(q['min_idle_session']!);
  }
  return _build(link, 'anytls', _name(u, 'anytls ${u.host}:${u.port}'), u.host,
      u.port, out);
}

/// Hysteria 1: `hysteria://host:port?auth=..&peer=..&insecure=1&upmbps=..&downmbps=..&alpn=..&obfsParam=..`.
ProxyConfig? _hysteria1(String link) {
  var hops = <String>[];
  var text = link;
  final hop = RegExp(r'(@?[^/?#@]+:\d+),([\d,\-]+)').firstMatch(text);
  if (hop != null) {
    hops = hop.group(2)!.split(',');
    text = text.replaceFirst(hop.group(0)!, hop.group(1)!);
  }
  final u = Uri.parse(text);
  final q = u.queryParameters;
  if ((q['protocol'] ?? 'udp') != 'udp') return null; // faketcp / wechat-video
  if ((q['mport'] ?? '').isNotEmpty) hops = q['mport']!.split(',');
  final auth = q['auth'] ?? q['auth_str'] ?? _decode(u.userInfo);
  final out = <String, dynamic>{
    'type': 'hysteria',
    'server': u.host,
    'server_port': u.port,
    'up_mbps': _mbps(q['upmbps'] ?? q['up'] ?? q['up_mbps']) ?? 20,
    'down_mbps': _mbps(q['downmbps'] ?? q['down'] ?? q['down_mbps']) ?? 100,
    if (auth.isNotEmpty) 'auth_str': auth,
    'tls': _tls(q, u.host, sni: q['peer'] ?? q['sni'], alpn: q['alpn'] ?? 'hysteria'),
  };
  final obfs = q['obfsParam'] ?? q['obfs-password'] ?? '';
  if (obfs.isNotEmpty) out['obfs'] = obfs;
  final ranges = [
    for (final h in hops)
      if (RegExp(r'^\d+(-\d+)?$').hasMatch(h.trim()))
        h.trim().contains('-') ? h.trim().replaceFirst('-', ':') : '${h.trim()}:${h.trim()}',
  ];
  if (ranges.isNotEmpty) out['server_ports'] = ranges;
  return _build(link, 'hysteria', _name(u, 'hysteria ${u.host}:${u.port}'),
      u.host, u.port, out);
}

ProxyConfig? _ssh(String link) {
  final u = Uri.parse(link);
  final q = u.queryParameters;
  final port = u.hasPort ? u.port : 22;
  final (user, pass) = _userPass(u.userInfo);
  if (user.isEmpty) return null;
  final out = <String, dynamic>{
    'type': 'ssh',
    'server': u.host,
    'server_port': port,
    'user': user,
    if (pass.isNotEmpty) 'password': pass,
    if ((q['private_key'] ?? '').isNotEmpty) 'private_key': q['private_key'],
    if ((q['private_key_passphrase'] ?? '').isNotEmpty)
      'private_key_passphrase': q['private_key_passphrase'],
    if ((q['host_key'] ?? '').isNotEmpty) 'host_key': q['host_key']!.split(','),
  };
  if (pass.isEmpty && !out.containsKey('private_key')) return null;
  return _build(link, 'ssh', _name(u, 'ssh ${u.host}:$port'), u.host, port, out);
}

/// Whether the core can run NaiveProxy here: it loads Chromium's network stack from a library that
/// sits next to the app. The Android build of the core does not include it.
bool _naiveAvailable() {
  if (Platform.isAndroid || Platform.isIOS) return false;
  try {
    final dir = File(Platform.resolvedExecutable).parent.path;
    final name = Platform.isWindows
        ? 'libcronet.dll'
        : (Platform.isMacOS ? 'libcronet.dylib' : 'libcronet.so');
    return File('$dir${Platform.pathSeparator}$name').existsSync() ||
        File('$dir${Platform.pathSeparator}lib${Platform.pathSeparator}$name').existsSync();
  } catch (_) {
    return false;
  }
}

/// NaiveProxy: `naive+https://user:pass@host:port?padding=1#name`.
ProxyConfig? _naive(String link) {
  if (!_naiveAvailable()) return null;
  final quic = link.startsWith('naive+quic://');
  final u = Uri.parse(link.replaceFirst(RegExp(r'^naive\+(https|quic)://'), 'https://'));
  final q = u.queryParameters;
  final port = u.hasPort ? u.port : 443;
  final (user, pass) = _userPass(u.userInfo);
  final out = <String, dynamic>{
    'type': 'naive',
    'server': u.host,
    'server_port': port,
    if (user.isNotEmpty) 'username': user,
    if (user.isNotEmpty) 'password': pass,
    'tls': {
      'enabled': true,
      'server_name': (q['sni'] ?? '').isNotEmpty ? q['sni'] : u.host,
    },
    if (quic) 'quic': true,
  };
  return _build(link, 'naive', _name(u, 'naive ${u.host}:$port'), u.host, port, out);
}

String _withMask(String address) {
  final a = address.trim();
  if (a.contains('/')) return a;
  return a.contains(':') ? '$a/128' : '$a/32';
}

List<int>? _reserved(String? v) {
  final parts = (v ?? '')
      .split(RegExp(r'[,\s]+'))
      .where((e) => e.isNotEmpty)
      .map(int.tryParse)
      .toList();
  if (parts.length != 3 || parts.any((e) => e == null || e < 0 || e > 255)) return null;
  return parts.cast<int>();
}

/// `wireguard://PRIVATE_KEY@host:port?publickey=..&address=10.0.0.2/32,fd00::2/128&mtu=1280&reserved=1,2,3#name`.
/// sing-box runs it as an endpoint; Xray as a WireGuard outbound.
ProxyConfig? _wireguard(String link) {
  final u = Uri.parse(link.replaceFirst(RegExp(r'^wg://'), 'wireguard://'));
  final q = u.queryParameters;
  final priv = (q['privatekey'] ?? q['private_key'] ?? _decode(u.userInfo)).trim();
  final pub = (q['publickey'] ?? q['public_key'] ?? q['peer_public_key'] ?? '').trim();
  final addresses = (q['address'] ?? q['ip'] ?? '')
      .split(',')
      .where((e) => e.trim().isNotEmpty)
      .map(_withMask)
      .toList();
  if (priv.isEmpty || pub.isEmpty || addresses.isEmpty || u.host.isEmpty) return null;
  final port = u.hasPort ? u.port : 51820;
  final allowed = (q['allowedips'] ?? q['allowed_ips'] ?? '0.0.0.0/0,::/0')
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
  final reserved = _reserved(q['reserved']);
  final mtu = int.tryParse(q['mtu'] ?? '');
  final psk = (q['presharedkey'] ?? q['psk'] ?? '').trim();
  final keepAlive = int.tryParse(q['keepalive'] ?? q['persistentkeepalive'] ?? '');
  final out = <String, dynamic>{
    'type': 'wireguard',
    'address': addresses,
    'private_key': priv,
    if (mtu != null) 'mtu': mtu,
    'peers': [
      {
        'address': u.host,
        'port': port,
        'public_key': pub,
        'allowed_ips': allowed,
        if (psk.isNotEmpty) 'pre_shared_key': psk,
        if (reserved != null) 'reserved': reserved,
        if (keepAlive != null && keepAlive > 0) 'persistent_keepalive_interval': keepAlive,
      },
    ],
  };
  final hostPort = u.host.contains(':') ? '[${u.host}]:$port' : '${u.host}:$port';
  final xray = {
    'protocol': 'wireguard',
    'settings': {
      'secretKey': priv,
      'address': addresses.map((a) => a.split('/').first).toList(),
      'peers': [
        {
          'endpoint': hostPort,
          'publicKey': pub,
          'allowedIPs': allowed,
          if (psk.isNotEmpty) 'preSharedKey': psk,
          if (keepAlive != null) 'keepAlive': keepAlive,
        },
      ],
      'mtu': mtu ?? 1420,
      if (reserved != null) 'reserved': reserved,
    },
  };
  // noise= (a WARP link): the packets sent before the first one of the tunnel, so that its start
  // does not look like WireGuard. Only Xray can send them, through a relay of its own.
  final noiseText = q['noise'];
  if (noiseText != null && noiseText.isNotEmpty) {
    final noise = <WarpNoise>[];
    for (final spec in noiseText.split(',')) {
      final n = parseWarpNoise(spec);
      if (n == null || noise.length >= 5) return null;
      noise.add(n);
    }
    xray['_noise'] = [for (final n in noise) n.toXray()];
    return _make(link, 'wireguard', _name(u, 'wireguard ${u.host}:$port'), u.host, port,
        xray: xray, xrayNote: 'noise');
  }
  return _make(link, 'wireguard', _name(u, 'wireguard ${u.host}:$port'), u.host,
      port,
      outbound: out, xray: xray);
}

/// Turns the text of a WireGuard `.conf` file into `wireguard://` links (one per [Peer]).
List<String> wireguardConfToLinks(String text) {
  if (!text.contains('[Interface]') || !text.contains('[Peer]')) return const [];
  final iface = <String, String>{};
  final peers = <Map<String, String>>[];
  Map<String, String>? current;
  for (final raw in text.split(RegExp(r'[\r\n]+'))) {
    final line = raw.split('#').first.trim();
    if (line.isEmpty) continue;
    if (line.toLowerCase() == '[interface]') {
      current = iface;
    } else if (line.toLowerCase() == '[peer]') {
      current = <String, String>{};
      peers.add(current);
    } else if (line.contains('=') && current != null) {
      final i = line.indexOf('=');
      current[line.substring(0, i).trim().toLowerCase()] = line.substring(i + 1).trim();
    }
  }
  final out = <String>[];
  for (final p in peers) {
    final endpoint = p['endpoint'] ?? '';
    final colon = endpoint.lastIndexOf(':');
    if (colon <= 0 || (iface['privatekey'] ?? '').isEmpty || (p['publickey'] ?? '').isEmpty) {
      continue;
    }
    final host = endpoint.substring(0, colon);
    final port = endpoint.substring(colon + 1);
    final params = <String, String>{
      'publickey': p['publickey']!,
      'address': (iface['address'] ?? '').replaceAll(' ', ''),
      if ((p['allowedips'] ?? '').isNotEmpty) 'allowedips': p['allowedips']!.replaceAll(' ', ''),
      if ((iface['mtu'] ?? '').isNotEmpty) 'mtu': iface['mtu']!,
      if ((p['presharedkey'] ?? '').isNotEmpty) 'presharedkey': p['presharedkey']!,
      if ((p['persistentkeepalive'] ?? '').isNotEmpty) 'keepalive': p['persistentkeepalive']!,
      if ((p['reserved'] ?? iface['reserved'] ?? '').isNotEmpty)
        'reserved': (p['reserved'] ?? iface['reserved'])!.replaceAll(' ', ''),
    };
    final query = params.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    out.add('wireguard://${Uri.encodeComponent(iface['privatekey']!)}@$host:$port'
        '?$query#${Uri.encodeComponent('WireGuard $host')}');
  }
  return out;
}
