part of 'proxy_config.dart';

// The links other apps make for DNS tunnels, read as Kumo's own (see dns_tunnel.dart). Each reader turns a link into the Kumo link of
// the same server; what Kumo shows and shares afterwards is that link. The formats are those of docs/dns-tunnels.md ("Links of other
// apps"): the `dnst://` of the net2share spec (both forms, and the JSON of dnstm), the URLs of Hiddify and Ghajar, the Soar links of
// Hiddify, WhiteDNS and soar-tunnel, Velta, the Slipstream links of Slipstreamplus and slipstream-client-android, the `dns://` of
// NetMod's generators, and the `rovunet://` of Rovunet (SlipNet's own format under another name). A kind Kumo has no tunnel for
// (MasterDNS and its forks, a Shadowsocks behind Slipstream, an encrypted link) is refused.

/// The resolvers used when a link of another app names none (they leave it to the app: Hiddify's `auto`).
const _foreignDefaultResolvers = ['udp://1.1.1.1:53', 'udp://8.8.8.8:53'];

String _enc(String s) => Uri.encodeComponent(s);

/// The Kumo link of [scheme] for a server, from its pieces. [query] holds the other keys (a key may come twice); empty values are
/// left out.
String _kumoLink(String scheme, String domain, String key, List<String> resolvers, List<MapEntry<String, String>> query, String name) {
  final parts = <String>[
    for (final r in (resolvers.isEmpty ? _foreignDefaultResolvers : resolvers)) 'resolver=${_enc(r)}',
    for (final e in query)
      if (e.value.isNotEmpty) '${_enc(e.key)}=${_enc(e.value)}',
  ];
  return '$scheme://${key.isEmpty ? '' : '${_enc(key)}@'}$domain?${parts.join('&')}#${_enc(name)}';
}

/// A resolver as another app writes it, in Kumo's way: `dot://` and `doh://` are `tls://` and `https://`; "auto" and empty are
/// none. A host without a port gets the port of its kind.
String? _foreignResolver(String raw) {
  var r = raw.trim();
  if (r.isEmpty || r.toLowerCase() == 'auto') return null;
  final m = RegExp(r'^([A-Za-z]+)://(.*)$').firstMatch(r);
  var kind = 'udp';
  if (m != null) {
    kind = switch (m[1]!.toLowerCase()) {
      'dot' || 'tls' => 'tls',
      'doh' || 'https' => 'https',
      'tcp' => 'tcp',
      _ => 'udp',
    };
    r = m[2]!;
  }
  if (kind == 'https') return r.startsWith('http') ? r : 'https://$r';
  final port = RegExp(r'(?:\]|[^:\]]):(\d{1,5})$').hasMatch(r) || (r.startsWith('[') && r.contains(']:'));
  if (!port) r = kind == 'tls' ? '$r:853' : '$r:53';
  return '$kind://$r';
}

/// The resolvers in [text] (a comma, space or semicolon list), in Kumo's way.
List<String> _foreignResolvers(Iterable<String> texts) => [
      for (final t in texts)
        for (final part in t.split(RegExp(r'[,;\s]+')))
          if (_foreignResolver(part) case final r?) r,
    ];

/// PEM text of a certificate or key from the base64url (DER or the body of the PEM) a link carries.
String _pemOf(String label, List<int> der) {
  final body = base64.encode(der);
  final lines = [for (var i = 0; i < body.length; i += 64) body.substring(i, i + 64 > body.length ? body.length : i + 64)];
  return '-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----\n';
}

/// The label of a private key given as DER (the spec's `pk`: the PEM body, base64url, no header): OpenSSH's own format, or PKCS#1
/// (RSA), PKCS#8 or SEC1 (EC) by the first thing inside the sequence.
String _keyLabel(List<int> der) {
  if (utf8.decode(der.take(14).toList(), allowMalformed: true) == 'openssh-key-v1') return 'OPENSSH PRIVATE KEY';
  if (der.length < 8 || der[0] != 0x30) return 'PRIVATE KEY';
  var i = 2;
  if (der[1] & 0x80 != 0) i += der[1] & 0x7f;
  // the version: INTEGER 0 or 1
  if (i + 3 >= der.length || der[i] != 0x02) return 'PRIVATE KEY';
  final next = der[i + 3];
  return switch (next) { 0x02 => 'RSA PRIVATE KEY', 0x04 => 'EC PRIVATE KEY', _ => 'PRIVATE KEY' };
}

/// A private key as the link of Kumo carries it (`ssh_key`: the PEM text in base64) from the PEM text or from the base64url body.
String _sshKeyOf(String key) {
  final text = key.trim();
  if (text.isEmpty) return '';
  if (text.contains('BEGIN')) return base64.encode(utf8.encode(text.endsWith('\n') ? text : '$text\n'));
  final der = _b64(text);
  return base64.encode(utf8.encode(_pemOf(_keyLabel(der), der)));
}

/// A certificate as the link of Kumo carries it (`cert`: the PEM text in base64) from the PEM text or from base64url DER.
String _certOf(String cert) {
  final text = cert.trim();
  if (text.isEmpty) return '';
  if (text.contains('BEGIN')) return base64.encode(utf8.encode(text.endsWith('\n') ? text : '$text\n'));
  return base64.encode(utf8.encode(_pemOf('CERTIFICATE', _b64(text))));
}

/// Reads the link of another app as the Kumo link of the same server; null when [link] is not of a format here (or is Kumo's own),
/// or is of a kind Kumo has no tunnel for.
String? foreignDnsToKumo(String link) {
  final i = link.indexOf('://');
  if (i <= 0) return null;
  final scheme = link.substring(0, i).toLowerCase();
  try {
    switch (scheme) {
      case 'dnst' || 'dnstm':
        return _fromDnst(link.substring(i + 3));
      case 'rovunet' || 'veyra':
        return 'slipnet://${link.substring(i + 3)}';
      case 'dns':
        return _fromNetmod(link.substring(i + 3));
      case 'velta':
        return _fromVelta(Uri.parse(link));
      case 'dnstt' || 'vaydns' || 'noizdns' || 'slipstream':
        return _fromUrlDialects(scheme, link);
      case 'soar':
        return _fromSoar(link);
    }
  } catch (_) {}
  return null;
}

/// The schemes whose links are another app's when [foreignDnsToKumo] says so, and always another's here.
bool _alwaysForeign(String scheme) => const {'dnst', 'dnstm', 'rovunet', 'veyra', 'dns', 'velta'}.contains(scheme);

// ---------------------------------------------------------------- dnst:// (the spec of net2share, and dnstm)

String? _fromDnst(String rest) {
  final cut = rest.indexOf(RegExp(r'[#?]'));
  final head = cut < 0 ? rest : rest.substring(0, cut);
  if (head.contains('/')) return _fromDnstReadable(Uri.parse('dnst://$rest'));
  // The second form: base64url of JSON, with the tag in the fragment too.
  final json = jsonDecode(utf8.decode(_b64(head)));
  if (json is! Map) return null;
  final t = json['transport'] is Map ? json['transport'] as Map : const {};
  final b = json['backend'] is Map ? json['backend'] as Map : const {};
  String s(Map m, String k) => m[k] is String ? m[k] as String : '';
  final fragment = rest.contains('#') ? _decode(rest.substring(rest.indexOf('#') + 1)) : '';
  final tag = s(json, 'tag').isNotEmpty ? s(json, 'tag') : fragment;
  return _dnstBuild(
    transport: s(t, 'type'),
    domain: s(t, 'domain'),
    pubkey: s(t, 'pubkey'),
    cert: s(t, 'cert'),
    record: s(t, 'record_type'),
    compat: t['dnstt_compat'] == true,
    clientId: '${t['clientid_size'] ?? ''}',
    resolvers: [
      for (final r in (json['resolvers'] is List ? json['resolvers'] as List : const [])) '$r',
      if (t['resolvers'] is List) for (final r in t['resolvers'] as List) '$r',
    ],
    backend: s(b, 'type'),
    user: s(b, 'user'),
    password: s(b, 'password'),
    pk: s(b, 'pk').isNotEmpty ? s(b, 'pk') : s(b, 'key'),
    tag: tag,
  );
}

String? _fromDnstReadable(Uri u) {
  final segments = u.pathSegments;
  if (segments.length < 2) return null;
  final q = u.queryParameters;
  return _dnstBuild(
    transport: segments[0],
    domain: u.host,
    pubkey: q['pubkey'] ?? '',
    cert: q['cert'] ?? '',
    record: q['record-type'] ?? '',
    compat: _truthy(q['dnstt-compat']),
    clientId: q['clientid-size'] ?? '',
    resolvers: [q['resolver'] ?? '', q['resolvers'] ?? ''],
    backend: segments[1],
    user: q['user'] ?? '',
    password: q['password'] ?? '',
    pk: q['pk'] ?? '',
    tag: _decode(u.fragment),
  );
}

String? _dnstBuild({
  required String transport,
  required String domain,
  required String pubkey,
  required String cert,
  required String record,
  required bool compat,
  required String clientId,
  required List<String> resolvers,
  required String backend,
  required String user,
  required String password,
  required String pk,
  required String tag,
}) {
  if (domain.isEmpty) return null;
  // MasterDNS has no tunnel here; Shadowsocks behind a tunnel and a backend of its own kind are not carried either.
  final scheme = switch (transport) {
    'dnstt' => 'dnstt',
    'vaydns' => compat ? 'dnstt' : 'vaydns',
    'slipstream' => 'slipstream',
    _ => null,
  };
  if (scheme == null || (scheme != 'slipstream' && pubkey.isEmpty)) return null;
  final q = <MapEntry<String, String>>[];
  if (scheme == 'vaydns') {
    q.add(MapEntry('record', record));
    q.add(MapEntry('clientid', clientId));
  }
  if (scheme == 'slipstream') q.add(MapEntry('cert', _certOf(cert)));
  switch (backend) {
    case 'socks':
      q.add(MapEntry('socks_user', user));
      if (user.isNotEmpty) q.add(MapEntry('socks_pass', password));
    case 'ssh':
      if (user.isEmpty) return null;
      q.add(const MapEntry('ssh', '1'));
      q.add(MapEntry('ssh_user', user));
      q.add(MapEntry('ssh_pass', password));
      q.add(MapEntry('ssh_key', _sshKeyOf(pk)));
    default:
      return null;
  }
  return _kumoLink(scheme, domain, scheme == 'slipstream' ? '' : pubkey, _foreignResolvers(resolvers), q,
      tag.isEmpty ? '${dnsTunnelNames[scheme]} $domain' : tag);
}

// ---------------------------------------------------------------- dnstt://, vaydns://, noizdns://, slipstream:// of other apps

String? _fromUrlDialects(String scheme, String link) {
  final u = Uri.parse(link);
  final q = u.queryParameters;
  String get(List<String> keys) {
    for (final k in keys) {
      if ((q[k] ?? '').isNotEmpty) return q[k]!;
    }
    return '';
  }

  if (scheme == 'slipstream') {
    // Slipstreamplus: SLIPSTREAM://[user:pass@]domain:53?dns=ip,ip#name
    if (q.containsKey('dns') && u.host.isNotEmpty) {
      final port = u.hasPort ? u.port : 53;
      final (user, pass) = _userPass(u.userInfo);
      return _kumoLink(
          'slipstream',
          u.host,
          '',
          [for (final ip in q['dns']!.split(RegExp(r'[,;\s]+'))) if (ip.isNotEmpty) _foreignResolver(_withPort(ip, port))!],
          [MapEntry('socks_user', user), if (user.isNotEmpty) MapEntry('socks_pass', pass)],
          _name(u, 'Slipstream ${u.host}'));
    }
    // slipstream-client-android: slipstream://base64url({"id","name","domain","socksAuthEnabled","username","password"})
    final payload = link.substring('slipstream://'.length).split(RegExp(r'[#?]')).first;
    if (payload.isNotEmpty && !payload.contains('.')) {
      final j = jsonDecode(utf8.decode(_b64(payload)));
      if (j is! Map || '${j['domain'] ?? ''}'.isEmpty) return null;
      final auth = j['socksAuthEnabled'] == true && '${j['username'] ?? ''}'.isNotEmpty;
      return _kumoLink('slipstream', '${j['domain']}', '', const [],
          [if (auth) MapEntry('socks_user', '${j['username']}'), if (auth) MapEntry('socks_pass', '${j['password'] ?? ''}')],
          '${j['name'] ?? ''}'.isEmpty ? 'Slipstream ${j['domain']}' : '${j['name']}');
    }
  }

  // Hiddify and Ghajar: the key is in the query (`pubkey`), the resolvers in `resolver` (a comma list, with `dot://` and `https://`
  // for the other transports) or in Ghajar's `transport`, `resolver` and `doh`.
  final key = get(['pubkey', 'publickey', 'serverpublickey']);
  final ours = u.userInfo.isNotEmpty && key.isEmpty;
  if (ours || (key.isEmpty && scheme != 'slipstream')) return null;
  if (scheme == 'slipstream' && key.isEmpty && !(q.containsKey('transport') || q.containsKey('upstream') || q.containsKey('doh') || q.containsKey('resolvers'))) {
    return null; // Kumo's own
  }
  final domain = u.host.isNotEmpty ? u.host : get(['domain', 'serveraddress', 'address']);
  if (domain.isEmpty) return null;
  var resolvers = <String>[];
  final transport = (q['transport'] ?? '').toLowerCase();
  if (transport == 'doh' && (q['doh'] ?? '').isNotEmpty) {
    resolvers = [_foreignResolver(q['doh']!)!];
  } else {
    final raw = get(['resolver', 'resolvers']);
    resolvers = _foreignResolvers([if (transport == 'dot') ...raw.split(RegExp(r'[,;\s]+')).map((e) => e.contains('://') ? e : 'dot://$e') else raw]);
  }
  final compat = _truthy(q['dnstt-compat']) || _truthy(q['compat']);
  // Hiddify's dnstt:// is VayDNS unless `dnstt-compat` says it speaks the original wire format; the other schemes are what they say.
  final kind = switch (scheme) {
    'dnstt' => q.containsKey('dnstt-compat') && !compat ? 'vaydns' : 'dnstt',
    _ => scheme,
  };
  final extra = <MapEntry<String, String>>[];
  if (kind == 'vaydns') {
    extra.add(MapEntry('record', get(['record-type', 'record'])));
    extra.add(MapEntry('qname', get(['max-qname-len', 'qname'])));
    extra.add(MapEntry('clientid', get(['clientid-size', 'clientid'])));
    extra.add(MapEntry('rps', get(['rps'])));
  }
  if (kind == 'noizdns') {
    if (_truthy(get(['stealth', 'noiz']))) extra.add(const MapEntry('stealth', '1'));
    if (_truthy(q['authoritative'])) extra.add(const MapEntry('authoritative', '1'));
  }
  if (kind == 'slipstream') {
    extra.add(MapEntry('cc', get(['cc'])));
    extra.add(MapEntry('cert', _certOf(get(['cert']))));
  }
  if (get(['utls']).isNotEmpty) extra.add(MapEntry('utls', get(['utls'])));
  // Ghajar: user:pass in the user part belongs to what the tunnel ends at.
  final (user, pass) = _userPass(u.userInfo);
  final upstream = (q['upstream'] ?? '').toLowerCase();
  if (user.isNotEmpty) {
    if (upstream == 'ssh') {
      extra
        ..add(const MapEntry('ssh', '1'))
        ..add(MapEntry('ssh_user', user))
        ..add(MapEntry('ssh_pass', pass));
    } else {
      extra
        ..add(MapEntry('socks_user', user))
        ..add(MapEntry('socks_pass', pass));
    }
  }
  return _kumoLink(kind, domain, kind == 'slipstream' ? '' : key, resolvers, extra, _name(u, '${dnsTunnelNames[kind]} $domain'));
}

// ---------------------------------------------------------------- Soar

String? _fromSoar(String link) {
  final u = Uri.parse(link);
  final q = u.queryParameters;
  final head = link.substring('soar://'.length).split(RegExp(r'[#?]')).first;
  // soar-tunnel: soar://profile?domains=a,b&key=KEY&port=N  and  soar://locked?data=base64({"name","domains","key","port"})
  if (u.host == 'profile' && (q['key'] ?? '').isNotEmpty) {
    final domain = (q['domains'] ?? '').split(',').first.trim();
    return domain.isEmpty ? null : _kumoLink('soar', domain, q['key']!, const [], const [MapEntry('discovery', '1')], _name(u, 'Soar $domain'));
  }
  if (u.host == 'locked' && (q['data'] ?? '').isNotEmpty) {
    final j = jsonDecode(utf8.decode(_b64(q['data']!)));
    if (j is! Map) return null;
    final domains = j['domains'] is List ? j['domains'] as List : const [];
    if (domains.isEmpty || '${j['key'] ?? ''}'.isEmpty) return null;
    return _kumoLink('soar', '${domains.first}', '${j['key']}', const [], const [MapEntry('discovery', '1')],
        '${j['name'] ?? ''}'.isEmpty ? 'Soar ${domains.first}' : '${j['name']}');
  }
  // WhiteDNS: soar://base64url({"schema":"whitedns.profile","version":1,"profile":{"name","server":{"domain","public_key"},"resolvers":[..],"soarSettings":{..}}})
  if (head.isNotEmpty && !head.contains('.') && !head.contains('@') && head.length > 30) {
    final j = jsonDecode(utf8.decode(_b64(head)));
    if (j is! Map || j['profile'] is! Map) return null;
    final p = j['profile'] as Map;
    final server = p['server'] is Map ? p['server'] as Map : const {};
    final settings = p['soarSettings'] is Map ? p['soarSettings'] as Map : const {};
    final domain = '${server['domain'] ?? ''}';
    final key = '${server['public_key'] ?? ''}';
    if (domain.isEmpty || key.isEmpty) return null;
    final country = '${settings['country'] ?? ''}';
    final discovery = settings['discovery'] == true;
    final transport = '${settings['transport'] ?? ''}';
    return _kumoLink(
        'soar',
        domain,
        key,
        _foreignResolvers([for (final r in (p['resolvers'] is List ? p['resolvers'] as List : const [])) '$r']),
        [
          if (discovery) MapEntry('discovery', country.length == 2 ? country : '1'),
          if (['auto', 'on', 'only', 'off'].contains(transport)) MapEntry('tcp', transport),
          MapEntry('safe_qname', '${settings['safeQName'] ?? ''}'.replaceFirst(RegExp(r'^0$'), '')),
        ],
        '${p['name'] ?? ''}'.isEmpty ? 'Soar $domain' : '${p['name']}');
  }
  // Hiddify: soar://domain?pk=KEY&resolvers=a,b&country=ir   and   soar://KEY@domain?resolvers=a,b
  final key = (q['pk'] ?? q['publickey'] ?? '').isNotEmpty ? (q['pk'] ?? q['publickey'])! : (q.containsKey('resolvers') ? _decode(u.userInfo) : '');
  if (key.isEmpty || u.host.isEmpty) return null; // Kumo's own, or not a Soar link
  final country = (q['country'] ?? '').toUpperCase();
  return _kumoLink(
      'soar',
      u.host,
      key,
      _foreignResolvers([q['resolvers'] ?? '']),
      [
        if (_truthy(q['discovery']) || country.length == 2) MapEntry('discovery', country.length == 2 ? country : '1'),
        if (['auto', 'on', 'only', 'off'].contains(q['tcp'])) MapEntry('tcp', q['tcp']!),
        MapEntry('safe_qname', q['safe_qname'] ?? ''),
      ],
      _name(u, 'Soar ${u.host}'));
}

/// Velta Tunnel: velta://tunnel?v=1&zone=ZONE&key=KEY (a Soar server; the resolvers are found by Soar itself).
String? _fromVelta(Uri u) {
  final zone = u.queryParameters['zone'] ?? '', key = u.queryParameters['key'] ?? '';
  if (u.host != 'tunnel' || zone.isEmpty || key.isEmpty) return null;
  return _kumoLink('soar', zone, key, const [], const [MapEntry('discovery', '1')], _name(u, 'Velta $zone'));
}

// ---------------------------------------------------------------- NetMod's generators

/// dns://base64({"ps": name, "addr": "ip:port" (the resolver), "ns": the tunnel's domain, "pubkey", "user", "pass"}): DNSTT, with
/// SSH when there is a login. (The format as the generators of NetMod profiles write it; not NetMod's own word.)
String? _fromNetmod(String rest) {
  final head = rest.split(RegExp(r'[#?]')).first;
  final j = jsonDecode(utf8.decode(_b64(head)));
  if (j is! Map) return null;
  final ns = '${j['ns'] ?? ''}', key = '${j['pubkey'] ?? ''}';
  if (ns.isEmpty || key.isEmpty) return null;
  final user = '${j['user'] ?? ''}';
  return _kumoLink(
      'dnstt',
      ns,
      key,
      _foreignResolvers(['${j['addr'] ?? ''}']),
      [
        if (user.isNotEmpty) ...[
          const MapEntry('ssh', '1'),
          MapEntry('ssh_user', user),
          MapEntry('ssh_pass', '${j['pass'] ?? ''}'),
        ],
      ],
      '${j['ps'] ?? ''}'.isEmpty ? 'DNSTT $ns' : '${j['ps']}');
}

/// "ip" as "ip:port" ("[v6]:port" for an IPv6 address), and left as it is when it has a port.
String _withPort(String ip, int port) {
  if (ip.startsWith('[') || RegExp(r'^[^:]+:\d+$').hasMatch(ip)) return ip;
  return ip.contains(':') ? '[$ip]:$port' : '$ip:$port';
}
