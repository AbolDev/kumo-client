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

/// An HTTP proxy, `http://user:pass@host:port#name`, or one reached over TLS, `https://...?sni=..&insecure=1`
/// (see [isHttpProxyLink]). Both cores carry it; Xray cannot skip the check of a certificate, so a proxy that
/// asks for that runs on sing-box only.
ProxyConfig? _httpProxy(String link) {
  final u = Uri.parse(link.trim());
  final tls = u.scheme == 'https';
  final port = u.port;
  final (user, pass) = _userPass(u.userInfo);
  final q = u.queryParameters;
  final tlsOut = tls ? _tls(q, u.host) : null;
  final out = <String, dynamic>{
    'type': 'http',
    'server': u.host,
    'server_port': port,
    if (user.isNotEmpty) 'username': user,
    if (user.isNotEmpty) 'password': pass,
    if (tlsOut != null) 'tls': tlsOut,
  };
  final insecure = tlsOut?['insecure'] == true;
  final xray = insecure
      ? null
      : {
          'protocol': 'http',
          'settings': {
            'servers': [
              {
                'address': u.host,
                'port': port,
                if (user.isNotEmpty) 'users': [{'user': user, 'pass': pass}],
              },
            ],
          },
          'streamSettings': {
            'network': 'raw',
            if (tls) 'security': 'tls',
            if (tls && tlsOut?['server_name'] != null) 'tlsSettings': {'serverName': tlsOut!['server_name']},
          },
        };
  return _make(link, u.scheme, _name(u, '${u.scheme} ${u.host}:$port'), u.host, port, outbound: out, xray: xray);
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
  final u = Uri.parse(link.replaceFirst(RegExp(r'^(wg|awg|amneziawg)://'), 'wireguard://'));
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
  // AmneziaWG: the settings of its obfuscation beside the ones of WireGuard (a setting that is not valid refuses the link).
  final awg = awgOptions(q);
  if (awg == null) return null;
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
  if (awg.isNotEmpty) {
    // Neither WARP's noise nor Xray carries it: only the core of the phone, as an endpoint of its own type.
    if ((q['noise'] ?? '').isNotEmpty) {
      awgProblem = 'WARP noise cannot be used with AmneziaWG';
      return null;
    }
    out.addAll(awg);
    for (final p in out['peers'] as List) {
      (p as Map<String, dynamic>).remove('reserved');
    }
    final name = _name(u, 'amneziawg ${u.host}:$port');
    // On the phone the core has the endpoint. On a computer kumo-awg has it, as Xray has what the core cannot do: the server is
    // one that only a helper carries, and its endpoint is what that helper is given (see buildXrayConfig).
    if (!amneziaInCore) return _make(link, amneziaProtocol, name, u.host, port, xray: out, xrayNote: 'awg');
    return _make(link, amneziaProtocol, name, u.host, port, outbound: out);
  }
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

/// The name of the server in the TLS hello of a MASQUE link that names none (see `masqueSniFor`).
const masqueSni = 'cloudflareaccess.com';

/// `warp-masque://host:443?priv=BASE64&pub=BASE64&address=172.16.0.2/32,2606:..::2/128&alpn=h2#name`: the WARP
/// server that Kumo builds itself for a MASQUE account (see warp_link.dart). Only Xray carries it: a tunnel of
/// CONNECT-IP (RFC 9484) over HTTP/2 (`alpn=h2`) or HTTP/3 (`alpn=h3`), the client certificate made from the
/// private key (P-256) and the edge's certificate checked against its public key.
ProxyConfig? _masque(String link) {
  final u = Uri.parse(link);
  final q = u.queryParameters;
  final priv = (q['priv'] ?? '').trim();
  final pub = (q['pub'] ?? '').trim();
  final addresses = (q['address'] ?? '')
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .map(_withMask)
      .toList();
  if (priv.isEmpty || pub.isEmpty || addresses.isEmpty || u.host.isEmpty) return null;
  final port = u.hasPort ? u.port : 443;
  final alpn = (q['alpn'] ?? 'h2').trim().toLowerCase() == 'h3' ? 'h3' : 'h2';
  final sni = (q['sni'] ?? '').trim().isEmpty ? masqueSni : q['sni']!.trim();
  // Xray applies the fingerprint to the HTTP/2 hello only; over HTTP/3 it is not used.
  final fp = alpn == 'h2' ? _fingerprint(q['fp']) : null;
  final xray = {
    'protocol': 'masque',
    'settings': {
      'address': u.host,
      'port': port,
      // Names are asked through the tunnel, of Cloudflare's own resolvers.
      'remoteDNS': ['1.1.1.1', '1.0.0.1'],
    },
    'streamSettings': {
      'network': 'masque',
      'masqueSettings': {
        'warp': {'privateKey': priv, 'publicKey': pub, 'address': addresses},
      },
      'security': 'tls',
      'tlsSettings': {
        'serverName': sni,
        'alpn': [alpn],
        if (fp != null) 'fingerprint': fp,
      },
    },
  };
  return _make(link, 'masque', _name(u, 'WARP masque-$alpn'), u.host, port, xray: xray, xrayNote: alpn);
}

/// The variables of the path of a MASQUE server that Xray fills in itself (RFC 6570 templates of RFC 9484).
const _masquePathVariables = [
  '{target}',
  '{ipproto}',
  '{?target,ipproto}',
  '{?ipproto,target}',
  '{&target,ipproto}',
  '{&ipproto,target}',
];

/// `masque://user:pass@host:443?sni=..&alpn=h2&path=/.well-known/masque/ip/{target}/{ipproto}/&host=..&fp=chrome&pcs=SHA256#name`:
/// a server that speaks MASQUE (CONNECT-IP, RFC 9484), such as the MASQUE inbound of Xray, with the login of
/// its HTTP Basic authentication in the link (a user name or an e-mail address, written with `%40` for `@`).
/// Only Xray carries it. `alpn` is `h2` (HTTP/2 over TCP, the default, which passes where UDP is cut) or `h3`
/// (HTTP/3 over UDP); the certificate of the server is checked, against the chain or, with `pcs`, against the
/// SHA-256 of the certificate (a self-signed server). Xray 26 cannot skip the check, so a link that asks for
/// `insecure` is not accepted. Not the link of WARP (`warp-masque://`, see [_masque]).
ProxyConfig? _masqueServer(String link) {
  final u = Uri.parse(link);
  final q = u.queryParameters;
  final (user, pass) = _userPass(u.userInfo);
  if (u.host.isEmpty || user.isEmpty || pass.isEmpty || user.contains(':')) return null;
  final port = u.hasPort ? u.port : 443;
  if (_truthy(q['insecure']) || _truthy(q['allowInsecure']) || _truthy(q['allow_insecure'])) return null;
  final alpn = (q['alpn'] ?? 'h2').trim().toLowerCase() == 'h3' ? 'h3' : 'h2';
  var serverName = (q['sni'] ?? '').trim();
  if (serverName.isEmpty && !_isIp(u.host)) serverName = u.host;
  // The path: only what Xray accepts, or the core would not start.
  final path = (q['path'] ?? '').trim();
  if (path.isNotEmpty) {
    var rest = path;
    for (final v in _masquePathVariables) {
      rest = rest.replaceAll(v, '');
    }
    if (!path.startsWith('/') || rest.contains('{') || rest.contains('}')) return null;
  }
  // The name the request is made to, when it is not the address of the server.
  final authority = (q['host'] ?? '').trim();
  if (authority.isNotEmpty) {
    // A name, an IPv4 address or an IPv6 one in brackets, with a port or without (written the way Xray reads it).
    final m = RegExp(r'^(?:[A-Za-z0-9._-]+|\[[0-9A-Fa-f:.]+\])(?::(\d{1,5}))?$').firstMatch(authority);
    final authorityPort = m == null ? null : int.tryParse(m[1] ?? '1');
    if (m == null || authorityPort == null || authorityPort < 1 || authorityPort > 65535) return null;
  }
  // A pinned certificate: SHA-256 in hex (with or without colons), several separated by commas.
  final pins = [
    for (final p in (q['pcs'] ?? q['pinSHA256'] ?? '').split(','))
      if (p.trim().isNotEmpty) p.replaceAll(':', '').trim().toLowerCase(),
  ];
  if (pins.any((p) => !RegExp(r'^[0-9a-f]{64}$').hasMatch(p))) return null;
  // Xray applies the fingerprint to the HTTP/2 hello only; over HTTP/3 it is not used.
  final fp = alpn == 'h2' ? _fingerprint(q['fp']) : null;
  final xray = {
    'protocol': 'masque',
    // The names asked through the tunnel use Xray's own default resolvers (Cloudflare's).
    'settings': {'address': u.host, 'port': port},
    'streamSettings': {
      'network': 'masque',
      'masqueSettings': {
        'user': user,
        'pass': pass,
        if (path.isNotEmpty) 'path': path,
        if (authority.isNotEmpty) 'host': authority,
      },
      'security': 'tls',
      'tlsSettings': {
        if (serverName.isNotEmpty) 'serverName': serverName,
        'alpn': [alpn],
        if (fp != null) 'fingerprint': fp,
        if (pins.isNotEmpty) 'pinnedPeerCertSha256': pins.join(','),
      },
    },
  };
  return _make(link, 'masque', _name(u, 'masque ${u.host}:$port'), u.host, port,
      xray: xray, xrayNote: alpn, pinned: pins.isNotEmpty);
}

/// The DNS servers a WireGuard link names (`dns=1.1.1.1, 8.8.8.8`): the addresses, in their order. Names and
/// anything that is not an address are left out. Empty for a link with none, or of another kind.
List<String> wireguardLinkDns(String link) {
  if (!RegExp(r'^(wireguard|wg|awg|amneziawg)://').hasMatch(link)) return const [];
  try {
    final q = Uri.parse(link.replaceFirst(RegExp(r'^(wg|awg|amneziawg)://'), 'wireguard://')).queryParameters;
    return [
      for (final part in (q['dns'] ?? '').split(RegExp(r'[,\s]+')))
        if (InternetAddress.tryParse(part.trim()) != null) part.trim(),
    ];
  } catch (_) {
    return const [];
  }
}

/// Turns the text of a WireGuard `.conf` file (or one of AmneziaWG, which has more keys in [Interface]) into
/// `wireguard://` links (one per [Peer]).
List<String> wireguardConfToLinks(String text) {
  if (!text.contains('[Interface]') || !text.contains('[Peer]')) return const [];
  final iface = <String, String>{};
  final peers = <Map<String, String>>[];
  Map<String, String>? current;
  String? comment;
  for (final raw in text.split(RegExp(r'[\r\n]+'))) {
    // A comment on a line of its own, just above a [Peer], names that server.
    if (raw.trimLeft().startsWith('#')) {
      comment = raw.trimLeft().substring(1).trim();
      continue;
    }
    final line = raw.split('#').first.trim();
    if (line.isEmpty) continue;
    if (line.toLowerCase() == '[interface]') {
      current = iface;
    } else if (line.toLowerCase() == '[peer]') {
      current = <String, String>{if (comment != null && comment.isNotEmpty) '#name': comment};
      comment = null;
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
      if ((iface['dns'] ?? '').isNotEmpty) 'dns': iface['dns']!.replaceAll(' ', ''),
      if ((p['presharedkey'] ?? '').isNotEmpty) 'presharedkey': p['presharedkey']!,
      if ((p['persistentkeepalive'] ?? '').isNotEmpty) 'keepalive': p['persistentkeepalive']!,
      if ((p['reserved'] ?? iface['reserved'] ?? '').isNotEmpty)
        'reserved': (p['reserved'] ?? iface['reserved'])!.replaceAll(' ', ''),
      // AmneziaWG: the settings of the obfuscation, as the configuration writes them (a signature packet keeps its spaces).
      for (final e in iface.entries)
        if (isAwgSetting(e.key) && e.value.isNotEmpty) e.key: e.value,
    };
    final query = params.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    final name = p['#name'] ?? 'WireGuard $host';
    out.add('wireguard://${Uri.encodeComponent(iface['privatekey']!)}@$host:$port'
        '?$query#${Uri.encodeComponent(name)}');
  }
  return out;
}

/// The user name and password (and the passphrase of the private key) with which an OpenVPN profile is
/// used. They are kept in the link, which is stored encrypted like the rest of the servers.
class OvpnServer {
  const OvpnServer(this.profile, {this.username, this.password, this.keyPassword});

  final OvpnProfile profile;
  final String? username;
  final String? password;
  final String? keyPassword;

  /// What is still missing before it can connect.
  bool get needsLogin => profile.needsLogin && ((username ?? '').isEmpty || password == null);
  bool get needsKeyPassword => profile.needsKeyPassword && (keyPassword ?? '').isEmpty;
}

/// `openvpn://BASE64URL(configuration)?user=..&pass=..&kpass=..#name`. The configuration is read again
/// here (it is not trusted because a link says it was checked): only what [parseOvpn] keeps is used.
ProxyConfig? _openvpn(String link) {
  final hash = link.indexOf('#');
  final head = hash < 0 ? link : link.substring(0, hash);
  final tail = hash < 0 ? '' : link.substring(hash + 1);
  final q = head.indexOf('?');
  final body = head.substring('openvpn://'.length, q < 0 ? head.length : q);
  final query = q < 0 ? <String, String>{} : Uri.splitQueryString(head.substring(q + 1));
  final String text;
  try {
    text = utf8.decode(base64Url.decode(base64Url.normalize(body)));
  } catch (_) {
    return null;
  }
  final OvpnProfile profile;
  try {
    profile = parseOvpn(text);
  } on OvpnException {
    return null;
  }
  final first = profile.remotes.first;
  var name = first.host;
  try {
    final decoded = Uri.decodeComponent(tail).trim();
    if (decoded.isNotEmpty) name = decoded;
  } catch (_) {}
  return ProxyConfig(
    link: link,
    protocol: 'openvpn',
    name: name,
    host: first.host,
    port: first.port,
    outbound: const {},
    ovpn: OvpnServer(profile,
        username: query['user'] ?? profile.username,
        password: query['pass'] ?? profile.password,
        keyPassword: query['kpass']),
  );
}
