part of '../config_decryptor.dart';

// NPV Tunnel .npvt: a comma separated list of tokens, each a 16 byte nonce followed
// by white-box AES-CTR data. The plaintext is a v2ray/xray JSON config (or a wrapper
// around one) that is turned back into share links.

Uint8List _npvtDecodeOne(String text) {
  text = text.replaceAll('NPVT1', '').replaceAll(RegExp(r'\s'), '');
  if (text.isEmpty) throw ConfigDecryptError('empty token');
  if (text.length.isEven && RegExp(r'^[0-9a-fA-F]+$').hasMatch(text)) {
    return _hex(text);
  }
  String pad(String s) => s.length % 4 == 0 ? s : s + '=' * (4 - s.length % 4);
  if (RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(text)) {
    try {
      return _b64Strict(pad(text));
    } on ConfigDecryptError {
      // try the URL alphabet
    }
  }
  if (RegExp(r'^[A-Za-z0-9\-_=]+$').hasMatch(text)) {
    try {
      return _b64Strict(pad(text).replaceAll('-', '+').replaceAll('_', '/'));
    } on ConfigDecryptError {
      // fall through
    }
  }
  throw ConfigDecryptError('could not parse token as hex or base64');
}

String decryptNpvt(Uint8List raw, NpvTables tables) {
  final wb = _WhiteBox(tables);
  final blobs = <Uint8List>[];
  for (var tok in _utf8(raw).trim().split(',')) {
    tok = tok.trim();
    if (tok.isNotEmpty) blobs.add(_npvtDecodeOne(tok));
  }
  final lines = <String>[];
  for (var i = 0; i < blobs.length; i++) {
    final data = blobs[i];
    final index = i + 1;
    if (data.length < 16) {
      lines.add(
          '// token $index: ${data.length} bytes, too short to hold a nonce');
      continue;
    }
    final pt = wb.ctr(data.sublist(0, 16), data.sublist(16), wb.tlast2);
    final uris = _npvtProcessBlob(pt);
    if (uris.isNotEmpty) {
      lines.addAll(uris);
      continue;
    }
    final trimmed = _stripBytes(pt);
    if (trimmed.isEmpty) continue;
    final pretty = _goIndent(trimmed, '  ');
    if (pretty != null) {
      lines.add(pretty);
      continue;
    }
    try {
      lines.add(utf8.decode(trimmed));
    } on FormatException {
      lines.add('// token $index: ${pt.length} bytes did not decrypt to text');
    }
  }
  return lines.join('\n');
}

String _npvtJoin(Object? v) {
  if (v is List) {
    return v.where((x) => x != null && x != '').map(_s).join(',');
  }
  return v == null ? '' : _s(v);
}

String _npvtHost(Map ws) {
  if (_t(ws['host'])) return _npvtJoin(ws['host']);
  final headers = _m(ws['headers']);
  if (_t(headers['Host'])) return _npvtJoin(headers['Host']);
  return _npvtJoin(headers['host'] ?? '');
}

/// (headerType, host, path) of a raw/tcp transport with an http header.
(String, String, String) _npvtTcpHttpHeader(Map ss) {
  final t =
      _t(ss['tcpSettings']) ? _m(ss['tcpSettings']) : _m(ss['rawSettings']);
  final header = _m(t['header']);
  final kind = _str(header['type']);
  if (kind != 'http') return (kind, '', '');
  final request = _m(header['request']);
  final headers = _m(request['headers']);
  final host = _npvtJoin(
      _t(headers['Host']) ? headers['Host'] : (headers['host'] ?? ''));
  return (kind, host, _npvtJoin(request['path'] ?? ''));
}

Map _npvtXhttp(Map ss) => _t(ss['xhttpSettings'])
    ? _m(ss['xhttpSettings'])
    : _m(ss['splithttpSettings']);

Map<String, dynamic> _npvtStreamQuery(Map ss) {
  final q = <String, dynamic>{};
  final network = _t(ss['network']) ? _s(ss['network']) : 'tcp';
  q['type'] = network;
  final security = _t(ss['security']) ? _s(ss['security']) : 'none';
  q['security'] = security;
  if (network == 'ws') {
    final ws = _m(ss['wsSettings']);
    if (_t(ws['path'])) q['path'] = ws['path'];
    final h = _npvtHost(ws);
    if (h.isNotEmpty) q['host'] = h;
  } else if (network == 'grpc') {
    final g = _m(ss['grpcSettings']);
    if (_t(g['serviceName'])) q['serviceName'] = g['serviceName'];
    q['mode'] = _t(g['multiMode']) ? 'multi' : 'gun';
    if (_t(g['authority'])) q['authority'] = g['authority'];
  } else if (network == 'kcp' || network == 'mkcp') {
    final k = _m(ss['kcpSettings']);
    if (_t(_m(k['header'])['type'])) q['headerType'] = _m(k['header'])['type'];
    if (_t(k['seed'])) q['seed'] = k['seed'];
  } else if (network == 'quic') {
    final k = _m(ss['quicSettings']);
    if (_t(k['security'])) q['quicSecurity'] = k['security'];
    if (_t(k['key'])) q['key'] = k['key'];
    if (_t(_m(k['header'])['type'])) q['headerType'] = _m(k['header'])['type'];
  } else if (network == 'httpupgrade') {
    final h = _m(ss['httpupgradeSettings']);
    if (_t(h['path'])) q['path'] = h['path'];
    if (_t(h['host'])) q['host'] = h['host'];
  } else if (network == 'xhttp' || network == 'splithttp') {
    final x = _npvtXhttp(ss);
    for (final key in ['path', 'host', 'mode']) {
      if (_t(x[key])) q[key] = _npvtJoin(x[key]);
    }
    if (_t(x['extra'])) {
      q['extra'] = x['extra'] is String ? x['extra'] : _goJson(x['extra']);
    }
  } else if (network == 'http' || network == 'h2') {
    final h = _m(ss['httpSettings']);
    if (_t(h['path'])) q['path'] = h['path'];
    if (_t(h['host'])) q['host'] = _npvtJoin(h['host']);
  } else if (network == 'tcp' || network == 'raw') {
    final (kind, host, path) = _npvtTcpHttpHeader(ss);
    if (kind == 'http') {
      q['headerType'] = kind;
      if (host.isNotEmpty) q['host'] = host;
      if (path.isNotEmpty) q['path'] = path;
    }
  }
  if (security == 'tls') {
    final t = _m(ss['tlsSettings']);
    if (_t(t['serverName'])) q['sni'] = t['serverName'];
    if (_t(t['fingerprint'])) q['fp'] = t['fingerprint'];
    if (_t(t['alpn'])) q['alpn'] = _npvtJoin(t['alpn']);
    if (_t(t['allowInsecure'])) q['allowInsecure'] = '1';
    if (_t(t['echConfigList'])) q['ech'] = t['echConfigList'];
    final pin = _npvtJoin(_t(t['pinnedPeerCertSha256'])
            ? t['pinnedPeerCertSha256']
            : (t['pinnedPeerCertificateChainSha256'] ?? ''))
        .trim();
    if (pin.isNotEmpty) {
      q['pinSHA256'] = pin;
      q['pcs'] = pin;
    }
  } else if (security == 'reality') {
    final t = _m(ss['realitySettings']);
    if (_t(t['serverName'])) q['sni'] = t['serverName'];
    if (_t(t['fingerprint'])) q['fp'] = t['fingerprint'];
    final pbk = _t(t['publicKey']) ? t['publicKey'] : t['password'];
    if (_t(pbk)) q['pbk'] = pbk;
    if (_t(t['shortId'])) q['sid'] = t['shortId'];
    if (_t(t['spiderX'])) q['spx'] = t['spiderX'];
    if (_t(t['mldsa65Verify'])) q['pqv'] = t['mldsa65Verify'];
  }
  return q;
}

List<Map> _npvtServers(Map settings, String listKey) {
  final entries = settings[listKey];
  if (entries is List && entries.isNotEmpty) {
    return [
      for (final e in entries)
        if (e is Map) e
    ];
  }
  if (_t(settings['address'])) return [settings];
  return [];
}

List<Map> _npvtUsers(Map server) {
  final users = server['users'];
  if (users is List && users.isNotEmpty) {
    return [
      for (final u in users)
        if (u is Map) u
    ];
  }
  if (_t(server['id'])) return [server];
  return [];
}

List<String> _npvtVlessUris(Map settings, Map ss, String remarks) {
  final links = <String>[];
  for (final v in _npvtServers(settings, 'vnext')) {
    for (final u in _npvtUsers(v)) {
      final q = _npvtStreamQuery(ss);
      q['encryption'] = _t(u['encryption']) ? u['encryption'] : 'none';
      if (_t(u['flow'])) q['flow'] = u['flow'];
      links.add(
          'vless://${_s(u['id'])}@${_joinHostPort(_s(v['address']), v['port'])}'
          '?${_queryEncode(q)}#${_pathEscape(remarks)}');
    }
  }
  if (links.isEmpty) throw ConfigDecryptError('vless: missing vnext/user');
  return links;
}

(String, String, String) _npvtVmessTransport(Map ss, String network) {
  var kind = 'none';
  var host = '', path = '';
  if (network == 'ws') {
    final ws = _m(ss['wsSettings']);
    path = _str(ws['path']);
    host = _npvtHost(ws);
  } else if (network == 'grpc') {
    final g = _m(ss['grpcSettings']);
    path = _str(g['serviceName']);
    host = _str(g['authority']);
    kind = _t(g['multiMode']) ? 'multi' : 'gun';
  } else if (network == 'httpupgrade') {
    final h = _m(ss['httpupgradeSettings']);
    path = _str(h['path']);
    host = _str(h['host']);
  } else if (network == 'xhttp' || network == 'splithttp') {
    final x = _npvtXhttp(ss);
    path = _npvtJoin(x['path']);
    host = _npvtJoin(x['host']);
    kind = _t(x['mode']) ? _s(x['mode']) : 'none';
  } else if (network == 'http' || network == 'h2') {
    final h = _m(ss['httpSettings']);
    path = _str(h['path']);
    host = _npvtJoin(h['host']);
  } else if (network == 'kcp' || network == 'mkcp') {
    final k = _m(ss['kcpSettings']);
    final ht = _m(k['header'])['type'];
    kind = _t(ht) ? _s(ht) : 'none';
    path = _str(k['seed']);
  } else if (network == 'quic') {
    final k = _m(ss['quicSettings']);
    final ht = _m(k['header'])['type'];
    kind = _t(ht) ? _s(ht) : 'none';
    host = _str(k['security']);
    path = _str(k['key']);
  } else if (network == 'tcp' || network == 'raw') {
    final (headerKind, h, p) = _npvtTcpHttpHeader(ss);
    kind = headerKind.isNotEmpty ? headerKind : 'none';
    host = h;
    path = p;
  }
  return (kind, host, path);
}

List<String> _npvtVmessUris(Map settings, Map ss, String remarks) {
  final network = _t(ss['network']) ? _s(ss['network']) : 'tcp';
  final security = ss['security'];
  final tlsFlag = security == 'tls' || security == 'reality' ? 'tls' : '';
  final (kind, host, path) = _npvtVmessTransport(ss, network);
  var sni = '', fp = '', alpn = '';
  var insecure = false;
  final t = ss[security == 'reality' ? 'realitySettings' : 'tlsSettings'];
  if (_t(t)) {
    final tm = _m(t);
    sni = _str(tm['serverName']);
    fp = _str(tm['fingerprint']);
    if (_t(tm['alpn'])) alpn = _npvtJoin(tm['alpn']);
    insecure = _t(tm['allowInsecure']);
  }
  final links = <String>[];
  for (final v in _npvtServers(settings, 'vnext')) {
    for (final u in _npvtUsers(v)) {
      final obj = <String, dynamic>{
        'v': '2',
        'ps': remarks,
        'add': v['address'] ?? '',
        'port': _s(v['port'] ?? 0),
        'id': u['id'] ?? '',
        'aid': _s(u['alterId'] ?? 0),
        'scy': u['security'] ?? '',
        'net': network,
        'type': kind,
        'host': host,
        'path': path,
        'tls': tlsFlag,
        'sni': sni,
        'fp': fp,
        'alpn': alpn,
        if (insecure) 'insecure': '1',
      };
      links.add('vmess://${_b64Std(_goJson(obj))}');
    }
  }
  if (links.isEmpty) throw ConfigDecryptError('vmess: missing vnext/user');
  return links;
}

List<String> _npvtTrojanUris(Map settings, Map ss, String remarks) {
  final links = <String>[];
  for (final s in _npvtServers(settings, 'servers')) {
    final q = _npvtStreamQuery(ss);
    if (_t(s['flow'])) q['flow'] = s['flow'];
    links.add('trojan://${_pathEscape(_str(s['password']))}'
        '@${_joinHostPort(_s(s['address']), s['port'])}'
        '?${_queryEncode(q)}#${_pathEscape(remarks)}');
  }
  if (links.isEmpty) throw ConfigDecryptError('trojan: missing server');
  return links;
}

List<String> _npvtShadowsocksUris(Map settings, String remarks) {
  final links = <String>[];
  for (final s in _npvtServers(settings, 'servers')) {
    final userinfo = _b64Std('${_str(s['method'])}:${_str(s['password'])}');
    links.add('ss://$userinfo@${_joinHostPort(_s(s['address']), s['port'])}'
        '#${_pathEscape(remarks)}');
  }
  if (links.isEmpty) throw ConfigDecryptError('shadowsocks: missing server');
  return links;
}

List<String> _npvtOutboundToUris(
    String protocol, Object? settings, Object? stream, String remarks) {
  final ss = _m(stream);
  final st = _m(settings);
  switch (protocol) {
    case 'vless':
      return _npvtVlessUris(st, ss, remarks);
    case 'vmess':
      return _npvtVmessUris(st, ss, remarks);
    case 'trojan':
      return _npvtTrojanUris(st, ss, remarks);
    case 'shadowsocks':
      return _npvtShadowsocksUris(st, remarks);
  }
  throw ConfigDecryptError('unsupported protocol: $protocol');
}

List<String> _npvtOutboundLines(Map ob, String remarks) {
  final protocol = _str(ob['protocol']);
  if (const ['freedom', 'blackhole', 'dns', ''].contains(protocol)) {
    final settings = _m(ob['settings']);
    if (protocol == 'freedom' &&
        (_t(settings['fragment']) || _t(settings['noises']))) {
      return ['// outbound freedom: ${_goJson(ob)}'];
    }
    return [];
  }
  try {
    return _npvtOutboundToUris(
        protocol, ob['settings'], ob['streamSettings'], remarks);
  } catch (e) {
    return ['// unconverted-outbound $protocol ($e): ${_goJson(ob)}'];
  }
}

List<String> _npvtExtractFromConfig(Uint8List pt) {
  final Object? cfg;
  try {
    cfg = jsonDecode(utf8.decode(pt));
  } catch (e) {
    throw ConfigDecryptError('config json: $e');
  }
  if (cfg is! Map) throw ConfigDecryptError('config not an object');
  final uris = <String>[];
  for (final ob in _l(cfg['outbounds'])) {
    if (ob is! Map) continue;
    final remarks = _t(cfg['remarks']) ? _s(cfg['remarks']) : _str(ob['tag']);
    uris.addAll(_npvtOutboundLines(ob, remarks));
  }
  return uris;
}

void _npvtWalkJson(Object? v, List<String> uris) {
  if (v is Map) {
    final done = <String>{};
    final raw = v['v2rayJson'];
    if (raw is String) {
      try {
        uris.addAll(
            _npvtExtractFromConfig(Uint8List.fromList(utf8.encode(raw))));
      } on ConfigDecryptError {
        // not a config
      }
    } else if (raw is Map) {
      done.add('v2rayJson');
      try {
        uris.addAll(_npvtExtractFromConfig(
            Uint8List.fromList(utf8.encode(_goJson(raw)))));
      } on ConfigDecryptError {
        // not a config
      }
    }
    if (v.containsKey('outbounds')) {
      done.add('outbounds');
      try {
        uris.addAll(_npvtExtractFromConfig(
            Uint8List.fromList(utf8.encode(_goJson(v)))));
      } on ConfigDecryptError {
        // not a config
      }
    }
    for (final e in v.entries) {
      if (!done.contains(e.key)) _npvtWalkJson(e.value, uris);
    }
  } else if (v is List) {
    for (final x in v) {
      _npvtWalkJson(x, uris);
    }
  }
}

List<String> _npvtProcessBlob(Uint8List pt) {
  Object? root;
  try {
    root = jsonDecode(utf8.decode(pt));
  } catch (_) {
    root = null;
  }
  if (root != null) {
    final uris = <String>[];
    _npvtWalkJson(root, uris);
    if (uris.isNotEmpty) return uris;
  }
  try {
    final sub = _npvtExtractFromConfig(pt);
    if (sub.isNotEmpty) return sub;
  } on ConfigDecryptError {
    // nothing to extract
  }
  return [];
}
