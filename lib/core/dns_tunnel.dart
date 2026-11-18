part of 'proxy_config.dart';

// DNS tunnels (DNSTT, VayDNS, NoizDNS, Soar) and SSH tunnels over other transports. A server of these is carried by kumo-dns (see
// tools/dnstunnels), which the core reaches through a local SOCKS5 port, as it reaches Xray. The links are Kumo's own; they are
// described in docs/dns-tunnels.md. The links of SlipNet (`slipnet://`) are read, and become the same servers; they are never
// written.

/// The key of the helper's configuration in the [ProxyConfig.xrayOutbound] of a server of these.
const dnsTunnelKey = '_kumoDns';

/// The schemes of the DNS tunnels.
const dnsTunnelSchemes = {'dnstt', 'vaydns', 'noizdns', 'slipstream', 'soar'};

/// The names the schemes are shown with.
const dnsTunnelNames = {'dnstt': 'DNSTT', 'vaydns': 'VayDNS', 'noizdns': 'NoizDNS', 'slipstream': 'Slipstream', 'soar': 'Soar', 'ssh': 'SSH'};

bool _dnsLink(String link) {
  final i = link.indexOf('://');
  return i > 0 && dnsTunnelSchemes.contains(link.substring(0, i).toLowerCase());
}

/// `scheme://PUBLIC_KEY@domain?resolver=..&resolver=..#name`: the keys of the query are in docs/dns-tunnels.md.
ProxyConfig? _dnsTunnel(String link) {
  final Uri u;
  try {
    u = Uri.parse(link);
  } catch (_) {
    return null;
  }
  final scheme = u.scheme.toLowerCase();
  if (!dnsTunnelSchemes.contains(scheme) || u.host.isEmpty) return null;
  final all = u.queryParametersAll;
  String q(String k) => (all[k]?.isNotEmpty ?? false) ? all[k]!.first : '';
  final key = _decode(u.userInfo).isNotEmpty ? _decode(u.userInfo) : q('key');
  final resolvers = [for (final r in all['resolver'] ?? const <String>[]) if (r.trim().isNotEmpty) r.trim()];
  // Soar may find resolvers itself; the others need one.
  final authoritative = [for (final r in all['authoritative'] ?? const <String>[]) if (r.trim().isNotEmpty) r.trim()];
  // Slipstream has no key (a certificate may pin the server's) and may have only authoritative resolvers.
  if (scheme != 'slipstream' && key.isEmpty) return null;
  if (resolvers.isEmpty && !(scheme == 'soar' && q('discovery').isNotEmpty) && !(scheme == 'slipstream' && authoritative.isNotEmpty)) return null;
  final spec = <String, dynamic>{
    'mode': scheme,
    'domain': u.host,
    if (key.isNotEmpty) 'pubkey': key,
    'resolvers': resolvers,
  };
  void number(String k, String name) {
    final n = int.tryParse(q(k));
    if (n != null && n > 0) spec[name] = n;
  }

  switch (scheme) {
    case 'vaydns':
      if (q('record').isNotEmpty) spec['record'] = q('record');
      number('qname', 'max_qname');
      number('clientid', 'client_id');
      final rps = double.tryParse(q('rps'));
      if (rps != null && rps > 0) spec['rps'] = rps;
    case 'noizdns':
      if (_truthy(q('stealth'))) spec['stealth'] = true;
      if (_truthy(q('authoritative'))) spec['authoritative'] = true;
      number('payload_size', 'max_payload');
    case 'slipstream':
      if (authoritative.isNotEmpty) spec['auth_resolvers'] = authoritative;
      if (['bbr', 'dcubic'].contains(q('cc'))) spec['cc'] = q('cc');
      if (q('cert').isNotEmpty) {
        // The certificate that pins the server's, as PEM in base64.
        try {
          spec['cert'] = utf8.decode(_b64(q('cert')));
        } catch (_) {
          return null;
        }
      }
    case 'soar':
      final d = q('discovery');
      if (d.isNotEmpty) {
        spec['discovery'] = true;
        if (d.length == 2) spec['country'] = d.toUpperCase();
      }
      if (['auto', 'on', 'only', 'off'].contains(q('tcp'))) spec['tcp_mode'] = q('tcp');
      number('safe_qname', 'safe_qname');
      if (all['candidate'] != null) spec['candidates'] = all['candidate'];
  }
  if (scheme != 'soar') {
    // What the tunnel ends at: a SOCKS5 server (with its login, if it has one) or an SSH server.
    if (q('socks_user').isNotEmpty) {
      spec['socks_user'] = q('socks_user');
      spec['socks_pass'] = q('socks_pass');
    }
  }
  if (q('utls').isNotEmpty && scheme != 'soar') spec['utls'] = q('utls');
  final ssh = _sshSpec(q, local: true);
  if (ssh != null) {
    if (ssh['_bad'] == true) return null;
    // (Soar's server dials the SSH server, so it must be told where it is.)
    if (scheme == 'soar' && (ssh['host'] ?? '').toString().isEmpty) return null;
    spec['ssh'] = ssh;
  } else if (_truthy(q('ssh'))) {
    return null;
  }
  return _dnsConfig(link, scheme, _name(u, '${dnsTunnelNames[scheme]} ${u.host}'), u.host, spec);
}

/// The SSH server of a link: the one a DNS tunnel ends at ([local]: its address is the tunnel's, only the login is given) or one
/// reached by a transport of its own. Null when the link names none.
Map<String, dynamic>? _sshSpec(String Function(String) q, {required bool local, String host = '', int port = 22}) {
  final transport = q('transport');
  if (local && !_truthy(q('ssh'))) return null;
  final user = q('ssh_user');
  if (user.isEmpty) return {'_bad': true};
  final key = q('ssh_key');
  String pem = '';
  if (key.isNotEmpty) {
    try {
      pem = utf8.decode(_b64(key));
    } catch (_) {
      return {'_bad': true};
    }
  }
  if (q('ssh_pass').isEmpty && pem.isEmpty) return {'_bad': true};
  final out = <String, dynamic>{
    'user': user,
    if (q('ssh_pass').isNotEmpty) 'pass': q('ssh_pass'),
    if (pem.isNotEmpty) 'key': pem,
    if (q('ssh_hostkey').isNotEmpty) 'host_key': q('ssh_hostkey'),
    if (!local) ...{'host': host, 'port': port},
    // A Soar server dials the SSH server itself, so the SSH server's address is given with the login.
    if (local && q('ssh_host').isNotEmpty) ...{'host': q('ssh_host'), 'port': int.tryParse(q('ssh_port')) ?? 22},
  };
  if (!local && transport.isNotEmpty) {
    if (!['tcp', 'tls', 'ws', 'http'].contains(transport)) return {'_bad': true};
    out['transport'] = transport;
    if (q('sni').isNotEmpty) out['sni'] = q('sni');
    if (transport == 'ws') {
      out['ws_path'] = q('ws_path').isEmpty ? '/' : q('ws_path');
      if (q('ws_host').isNotEmpty) out['ws_host'] = q('ws_host');
      if (_truthy(q('ws_tls'))) out['ws_tls'] = true;
    }
    if (transport == 'http') {
      final p = q('proxy');
      final i = p.lastIndexOf(':');
      final pp = i > 0 ? int.tryParse(p.substring(i + 1)) : null;
      if (pp == null) return {'_bad': true};
      out['proxy_host'] = p.substring(0, i);
      out['proxy_port'] = pp;
      if (q('proxy_host').isNotEmpty) out['proxy_as'] = q('proxy_host');
    }
  }
  if (q('payload').isNotEmpty) out['payload'] = q('payload');
  return out;
}

/// An SSH link that names a transport (`ssh://user:pass@host:port?transport=ws&ws_path=/x`) or a payload: the SSH server of
/// sing-box has neither, so kumo-dns carries it. Null when [u] is an ordinary SSH link.
ProxyConfig? _sshOverTransport(String link, Uri u) {
  final q = u.queryParameters;
  final t = q['transport'] ?? '';
  if (!(t == 'tls' || t == 'ws' || t == 'http') && (q['payload'] ?? '').isEmpty) return null;
  final (user, pass) = _userPass(u.userInfo);
  final port = u.hasPort ? u.port : 22;
  String get(String k) => k == 'ssh_user' ? user : (k == 'ssh_pass' ? pass : (q[k] ?? ''));
  final ssh = _sshSpec(get, local: false, host: u.host, port: port);
  if (ssh == null || ssh['_bad'] == true) return null;
  return _dnsConfig(link, 'ssh', _name(u, 'ssh ${u.host}:$port'), u.host, {'mode': 'ssh', 'ssh': ssh}, port: port);
}

ProxyConfig _dnsConfig(String link, String protocol, String name, String host, Map<String, dynamic> spec, {int port = 53}) =>
    ProxyConfig(
      link: link,
      protocol: protocol,
      name: name,
      host: host,
      port: port,
      outbound: const {},
      xrayOutbound: {dnsTunnelKey: spec},
      xrayNote: 'dns tunnel',
    );

/// The configuration of kumo-dns for [server] (a server of these): a SOCKS5 port on 127.0.0.1:[port], with a login when [auth] is
/// given, and the tunnel.
String dnsTunnelHelperConfig(ProxyConfig server, int port, {String? user, String? pass}) {
  final spec = Map<String, dynamic>.from(server.xrayOutbound![dnsTunnelKey] as Map);
  return jsonEncode({
    ...spec,
    'listen': '127.0.0.1:$port',
    if (user != null && user.isNotEmpty) ...{'user': user, 'pass': pass ?? ''},
  });
}

// ---------------------------------------------------------------- the link of SlipNet (read only)

/// A `slipnet://` link (SlipNet's own: base64 of fields joined by `|`) as the Kumo link of the same server; null when it is of a
/// kind Kumo has no tunnel for. The fields are the ones SlipNet's app exports.
String? slipnetToKumoLink(String link) {
  final text = link.trim();
  if (!text.startsWith('slipnet://')) return null;
  final String raw;
  try {
    raw = utf8.decode(_b64(text.substring('slipnet://'.length).replaceAll(RegExp(r'\s'), '')));
  } catch (_) {
    return null;
  }
  final f = raw.split('|');
  String at(int i) => i < f.length ? f[i].trim() : '';
  if (f.length < 12) return null;
  final type = at(1);
  final scheme = switch (type) {
    'dnstt' || 'dnstt_ssh' => 'dnstt',
    'sayedns' || 'sayedns_ssh' => 'noizdns',
    'slipstream' || 'slipstream_ssh' => 'slipstream',
    'vaydns' || 'vaydns_ssh' => 'vaydns',
    'soar' || 'soar_ssh' => 'soar',
    'ssh' => 'ssh',
    _ => null,
  };
  if (scheme == null) return null;
  final name = at(2).isEmpty ? (dnsTunnelNames[scheme] ?? scheme) : at(2);
  final query = <MapEntry<String, String>>[];
  void add(String k, String v) {
    if (v.isNotEmpty) query.add(MapEntry(k, v));
  }

  String enc(String s) => Uri.encodeComponent(s);
  String tail() => '${query.map((e) => '${enc(e.key)}=${enc(e.value)}').join('&')}#${enc(name)}';

  if (scheme == 'ssh') {
    final host = at(19).isEmpty ? at(3) : at(19);
    final port = int.tryParse(at(17)) ?? 22;
    if (host.isEmpty || at(15).isEmpty) return null;
    if (at(50) == '1') {
      add('transport', 'tls');
      add('sni', at(51));
    } else if (at(55) == '1') {
      add('transport', 'ws');
      add('ws_path', at(56));
      if (at(57) == '1') add('ws_tls', '1');
      add('ws_host', at(58));
    } else if (at(52).isNotEmpty) {
      add('transport', 'http');
      add('proxy', '${at(52)}:${at(53)}');
      add('proxy_host', at(54));
    }
    add('payload', at(59));
    return 'ssh://${enc(at(15))}:${enc(at(16))}@$host:$port?${tail()}';
  }

  // The resolvers: "host:port:authoritative" separated by commas, in the transport of field 22 (DoH has its own address).
  final transport = at(22).isEmpty ? 'udp' : at(22);
  if (transport == 'https' || transport == 'doh') {
    add('resolver', at(21));
  } else {
    for (final r in at(4).split(',')) {
      final p = r.split(':');
      if (p.isEmpty || p[0].trim().isEmpty) continue;
      final addr = p.length > 1 && p[1].isNotEmpty ? '${p[0]}:${p[1]}' : p[0];
      // A resolver SlipNet marks as authoritative is one its user runs himself (Slipstream paces its polling by it).
      if (scheme == 'slipstream' && p.length > 2 && p[2] == '1') {
        add('authoritative', addr);
      } else {
        add('resolver', transport == 'tcp' ? 'tcp://$addr' : (transport == 'tls' ? 'tls://$addr' : 'udp://$addr'));
      }
    }
  }
  if (scheme == 'noizdns' && at(38) == '1') add('stealth', '1');
  if (scheme == 'slipstream') add('cc', at(7));
  if (scheme == 'vaydns') {
    add('record', at(42));
    final qn = int.tryParse(at(43)) ?? 0;
    if (qn > 0) add('qname', '$qn');
    final rps = double.tryParse(at(44)) ?? 0;
    if (rps > 0) add('rps', '$rps');
  }
  if (scheme == 'soar') {
    if (at(79) == '1') add('discovery', at(80).length == 2 ? at(80).toUpperCase() : '1');
    add('tcp', at(81));
  } else {
    add('socks_user', at(12));
    add('socks_pass', at(13));
  }
  if (at(14) == '1' && at(15).isNotEmpty) {
    add('ssh', '1');
    add('ssh_user', at(15));
    add('ssh_pass', at(16));
    add('ssh_key', at(24)); // the private key, in base64
    if (scheme == 'soar') {
      add('ssh_host', at(19));
      add('ssh_port', at(17));
    }
  }
  final key = at(11);
  if (at(3).isEmpty || (scheme != 'slipstream' && key.isEmpty)) return null;
  return '$scheme://${key.isEmpty ? '' : '${enc(key)}@'}${at(3)}?${tail()}';
}
