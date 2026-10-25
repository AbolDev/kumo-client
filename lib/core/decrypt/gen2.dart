part of '../config_decryptor.dart';

// NPV Tunnel export, second generation (.npvs, header version 5) and the open
// container (NPVO1). Fields are sealed one by one; the profile is rebuilt from
// them into share links.

const _gen2BlockSize = 57344;
const _gen2BlockCount = 13;
const _gen2PageSize = 4096;
const _gen2TablesSize = _gen2BlockCount * _gen2BlockSize + _gen2PageSize;
const _gen2Sentinel = 0xFFFF;
const _gen2MethodRecipient = 0;
const _gen2MethodPass = 1;
const _gen2MethodAppKey = 2;
const _gen2KeyBlockOffset = 53;
const _gen2HeaderFixed = 135;
const _wbShiftRows = [0, 5, 10, 15, 4, 9, 14, 3, 8, 13, 2, 7, 12, 1, 6, 11];

class _Gen2Env {
  _Gen2Env(
      this.header, this.configId, this.creator, this.method, this.recipients);
  final Uint8List header, configId, creator;
  final int method, recipients;
  int iters = 0;
  Uint8List salt = Uint8List(0), wrap = Uint8List(0);
  Uint8List prefix = Uint8List(0), metaBlob = Uint8List(0);
  Uint8List nonce = Uint8List(0), body = Uint8List(0);
}

bool _isGen2Envelope(Uint8List b) =>
    b.length >= 9 && _utf8(b.sublist(0, 4)) == 'NPVS' && b[4] == 5;

_Gen2Env _parseGen2Envelope(Uint8List b) {
  if (!_isGen2Envelope(b)) {
    throw ConfigDecryptError('npvs gen2: not a v5 compact envelope');
  }
  final hdrLen = _be(b, 5, 4);
  if (hdrLen < _gen2HeaderFixed || 9 + hdrLen > b.length) {
    throw ConfigDecryptError('npvs gen2: bad header length $hdrLen');
  }
  final h = b.sublist(9, 9 + hdrLen);
  if (h[0] != 1) {
    throw ConfigDecryptError(
        'npvs gen2: compact header version ${h[0]} is unsupported');
  }
  final method = h[50];
  if (method != _gen2MethodRecipient &&
      method != _gen2MethodPass &&
      method != _gen2MethodAppKey) {
    throw ConfigDecryptError('npvs gen2: unknown unlock method $method');
  }
  final recipients = _be(h, 51, 2);
  if (recipients > 0x400) {
    throw ConfigDecryptError('npvs gen2: $recipients recipients is too many');
  }
  if (method == _gen2MethodRecipient && recipients == 0) {
    throw ConfigDecryptError('npvs gen2: invalid compact envelope header');
  }
  final env =
      _Gen2Env(h, h.sublist(1, 17), h.sublist(17, 50), method, recipients);
  var off = _gen2KeyBlockOffset + recipients * (32 + 0x5D);
  if (method == _gen2MethodPass) {
    if (off + 80 + 4 > h.length) {
      throw ConfigDecryptError('npvs gen2: truncated passphrase block');
    }
    env.iters = _be(h, off, 4);
    if (env.iters < 1 || env.iters > 10000000) {
      throw ConfigDecryptError(
          'npvs gen2: bad passphrase iteration count ${env.iters}');
    }
    env.salt = h.sublist(off + 4, off + 20);
    env.wrap = h.sublist(off + 20, off + 80);
    off += 80;
  } else if (method == _gen2MethodAppKey) {
    if (off + 78 + 4 > h.length) {
      throw ConfigDecryptError('npvs gen2: truncated app-key block');
    }
    if (_be(h, off, 2) != _gen2MethodAppKey) {
      throw ConfigDecryptError('npvs gen2: missing app-key block');
    }
    env.salt = h.sublist(off + 2, off + 18);
    env.wrap = h.sublist(off + 18, off + 78);
    off += 78;
  }
  if (off + 4 > h.length) {
    throw ConfigDecryptError('npvs gen2: truncated sealed metadata length');
  }
  final metaLen = _be(h, off, 4);
  if (metaLen < 16 || off + 4 + metaLen > h.length) {
    throw ConfigDecryptError('npvs gen2: bad sealed metadata length $metaLen');
  }
  env.prefix = h.sublist(0, off);
  env.metaBlob = h.sublist(off + 4, off + 4 + metaLen);
  off = 9 + hdrLen;
  if (off + 16 > b.length) {
    throw ConfigDecryptError('npvs gen2: truncated body header');
  }
  env.nonce = b.sublist(off, off + 12);
  final bodyLen = _be(b, off + 12, 4);
  off += 16;
  if (bodyLen < 32 || off + bodyLen + 64 > b.length) {
    throw ConfigDecryptError('npvs gen2: bad body length $bodyLen');
  }
  env.body = b.sublist(off, off + bodyLen);
  return env;
}

Uint8List _gen2Hkdf(Uint8List ikm, Uint8List salt, List<int> info) {
  if (salt.isEmpty) salt = Uint8List(32);
  final prk = _hmacSha256(salt, ikm);
  return _hmacSha256(prk, [...info, 1]);
}

Uint8List _gen2Tables(NpvTables t) {
  final z = t.gen2Z;
  if (z == null) throw ConfigDecryptError('Missing tables');
  final tables = Uint8List.fromList(zlib.decode(z));
  if (tables.length != _gen2TablesSize) {
    throw ConfigDecryptError('npvs: gen2 tables have the wrong size');
  }
  return tables;
}

Uint8List _gen2A16(Uint8List salt, Uint8List tables) {
  if (salt.length != 16) {
    throw ConfigDecryptError('npvs: gen2 salt must be 16 bytes');
  }
  var state = Uint8List.fromList(salt);
  for (var blk = 0; blk < _gen2BlockCount; blk++) {
    final block = Uint8List.sublistView(
        tables, blk * _gen2BlockSize, (blk + 1) * _gen2BlockSize);
    state = Uint8List.fromList([for (final i in _wbShiftRows) state[i]]);
    for (var j = 0; j < 4; j++) {
      _gen2Group(state, block, j);
    }
  }
  final page = Uint8List.sublistView(tables, _gen2BlockCount * _gen2BlockSize);
  return Uint8List.fromList(
      [for (var i = 0; i < 16; i++) page[0x100 * i + state[_wbShiftRows[i]]]]);
}

void _gen2Group(Uint8List state, Uint8List block, int j) {
  for (final half in const [0x6000, 0xA000]) {
    final base = half + 0x1000 * j;
    int be32(int off) => _be(block, off, 4);
    final out = _gen2Sub7dc0(
        block,
        j,
        be32(base + 4 * state[4 * j]),
        be32(base + 0x400 + 4 * state[4 * j + 1]),
        be32(base + 0x800 + 4 * state[4 * j + 2]),
        be32(base + 0xC00 + 4 * state[4 * j + 3]));
    state.setRange(4 * j, 4 * j + 4, out);
  }
}

class _Gen2Opened {
  _Gen2Opened(this.metadata, this.fields);
  final Uint8List metadata;
  final Map<int, Uint8List> fields;
}

_Gen2Opened _gen2Open(_Gen2Env env, String passphrase, NpvTables tables) {
  final Uint8List kdk;
  if (env.method == _gen2MethodAppKey) {
    final a16 = _gen2A16(env.salt, _gen2Tables(tables));
    kdk = _sha256(
        [...utf8.encode('npvtunnel/appkey/v2 '), ...a16, ...env.configId]);
  } else if (env.method == _gen2MethodPass) {
    if (passphrase.isEmpty) {
      throw ConfigDecryptError(
          'npvs gen2: passphrase required to open this config');
    }
    kdk = _pbkdf2(passphrase, env.salt, env.iters);
  } else {
    throw ConfigDecryptError(
        'npvs gen2: unlock method ${env.method} needs the recipient private key');
  }
  final Uint8List dek;
  try {
    dek = _chachaOpen(
        kdk, env.wrap.sublist(0, 12), env.wrap.sublist(12), env.salt);
  } on InvalidCipherTextException {
    throw ConfigDecryptError(env.method == _gen2MethodPass
        ? 'Wrong passphrase'
        : 'npvs gen2: app-key wrap did not open');
  }
  final metaKey = _gen2Hkdf(dek, env.nonce, utf8.encode('NPVS-v5/metadata'));
  final Uint8List metadata;
  try {
    metadata = _chachaOpen(metaKey, env.nonce, env.metaBlob, env.prefix);
  } on InvalidCipherTextException {
    throw ConfigDecryptError('npvs gen2: sealed metadata did not open');
  }

  final b = env.body;
  if (b.length < 32 + 2 + 32 || _utf8(b.sublist(0, 4)) != 'NPF\x01') {
    throw ConfigDecryptError('npvs gen2: bad NPF body');
  }
  final contentId = b.sublist(4, 36);
  final count = _be(b, 36, 2);
  var off = 38;
  final fields = <int, Uint8List>{};
  for (var n = 0; n < count; n++) {
    if (off + 6 > b.length) {
      throw ConfigDecryptError('npvs gen2: truncated NPF field header');
    }
    final seq = _be(b, off, 2);
    final blobLen = _be(b, off + 4, 2);
    if (off + 6 + blobLen > b.length) {
      throw ConfigDecryptError('npvs gen2: truncated NPF field blob');
    }
    final blob = b.sublist(off + 6, off + 6 + blobLen);
    off += 6 + blobLen;
    final ptLen = blob.length - 16;
    if (ptLen < 0) continue;
    final key = _gen2Hkdf(dek, contentId,
        [...utf8.encode('NPV-fields-v1/field/'), ..._be16(seq)]);
    final aad = _concat([
      utf8.encode('NPV-fields-v1/record/'),
      contentId,
      _be16(seq),
      _be32(ptLen),
    ]);
    try {
      fields[seq] = _chachaOpen(key, Uint8List(12), blob, aad);
    } on InvalidCipherTextException {
      // the reference skips records that do not open
    }
  }
  return _Gen2Opened(metadata, fields);
}

String _gen2FieldText(Uint8List raw) {
  final s = _utf8(raw).trim();
  if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
    try {
      return jsonDecode(s) as String;
    } catch (_) {
      return s.substring(1, s.length - 1);
    }
  }
  return s;
}

Object? _gen2Substitute(Object? v, Map<int, Uint8List> fields) {
  if (v is bool) return v;
  if (v is num) {
    final raw = fields[v.toInt() & 0xFFFF] ?? Uint8List(0);
    return _decodeSentinels(_gen2FieldText(raw));
  }
  if (v is Map) {
    return {for (final e in v.entries) e.key: _gen2Substitute(e.value, fields)};
  }
  if (v is List) return [for (final x in v) _gen2Substitute(x, fields)];
  return v;
}

String _gen2Text(Object? v) {
  if (v == null) return '';
  if (v is String) return v;
  if (v is bool) return v ? 'true' : 'false';
  if (v is double) return v == v.truncateToDouble() ? '${v.toInt()}' : '$v';
  if (v is int) return '$v';
  return _goJson(v);
}

Map<String, String> _gen2FlatMap(Map obj) =>
    {for (final e in obj.entries) '${e.key}': _gen2Text(e.value)};

int _gen2Int(String s) => int.tryParse(s.trim()) ?? 0;

String _gen2Or(String a, [String b = '', String c = '']) =>
    a.isNotEmpty ? a : (b.isNotEmpty ? b : c);

void _gen2Set(Map<String, dynamic> q, String key, String value) {
  if (value.isNotEmpty) q[key] = value;
}

bool _gen2AllowInsecure(Map<String, String> p) {
  for (final key in const ['tlsAllowInsecure', 'insecure']) {
    final val = (p[key] ?? '').trim().toLowerCase();
    if (const ['true', '1', 'yes'].contains(val)) return true;
    if (const ['false', '0', 'no'].contains(val)) return false;
  }
  return false;
}

String _g(Map<String, String> p, String k) => p[k] ?? '';

Map<String, dynamic> _gen2StreamQuery(Map<String, String> p) {
  final network = _gen2Or(_g(p, 'network'), 'tcp');
  final security = _gen2Or(_g(p, 'security'), 'none');
  final q = <String, dynamic>{'type': network, 'security': security};
  if (network == 'ws') {
    _gen2Set(q, 'path', _g(p, 'path'));
    _gen2Set(q, 'host', _g(p, 'host'));
  } else if (network == 'grpc') {
    _gen2Set(q, 'serviceName', _g(p, 'serviceName'));
    _gen2Set(q, 'mode', _gen2Or(_g(p, 'mode'), _g(p, 'xhttpMode'), 'gun'));
    _gen2Set(q, 'authority', _g(p, 'authority'));
  } else if (network == 'kcp') {
    _gen2Set(q, 'headerType', _g(p, 'headerType'));
    _gen2Set(q, 'seed', _g(p, 'seed'));
  } else if (network == 'quic') {
    _gen2Set(q, 'key', _g(p, 'key'));
    _gen2Set(q, 'headerType', _g(p, 'headerType'));
  } else if (network == 'xhttp' || network == 'httpupgrade') {
    _gen2Set(q, 'path', _g(p, 'path'));
    _gen2Set(q, 'host', _g(p, 'host'));
    _gen2Set(q, 'mode', _gen2Or(_g(p, 'xhttpMode'), _g(p, 'mode')));
    _gen2Set(q, 'extra', _g(p, 'xhttpExtra'));
  } else if (network == 'http' || network == 'h2') {
    _gen2Set(q, 'path', _g(p, 'path'));
    _gen2Set(q, 'host', _g(p, 'host'));
  } else if (network == 'tcp' || network == 'raw') {
    final headerType = _g(p, 'headerType');
    if (headerType.isNotEmpty && headerType != 'none') {
      q['headerType'] = headerType;
      _gen2Set(q, 'host', _g(p, 'host'));
      _gen2Set(q, 'path', _g(p, 'path'));
    }
  }
  if (security == 'tls') {
    _gen2Set(q, 'sni', _g(p, 'sni'));
    _gen2Set(q, 'fp', _g(p, 'fingerPrint'));
    _gen2Set(q, 'alpn', _g(p, 'alpn'));
    if (_gen2AllowInsecure(p)) q['allowInsecure'] = '1';
    final pin = _g(p, 'pinnedPeerCertSha256').trim();
    if (pin.isNotEmpty &&
        !const ['false', '0', 'none'].contains(pin.toLowerCase())) {
      q['pinSHA256'] = pin;
      q['pcs'] = pin;
    }
  } else if (security == 'reality') {
    _gen2Set(q, 'sni', _g(p, 'sni'));
    _gen2Set(q, 'fp', _g(p, 'fingerPrint'));
    _gen2Set(q, 'alpn', _g(p, 'alpn'));
    _gen2Set(q, 'pbk', _g(p, 'publicKey'));
    _gen2Set(q, 'sid', _g(p, 'shortId'));
    _gen2Set(q, 'spx', _g(p, 'spiderX'));
  }
  return q;
}

String _gen2VlessLink(
    String host, int port, String remarks, Map<String, String> p) {
  final q = _gen2StreamQuery(p);
  final method = _g(p, 'method');
  q['encryption'] = method.trim().isNotEmpty ? method : 'none';
  _gen2Set(q, 'flow', _g(p, 'flow'));
  return 'vless://${_g(p, 'password')}@${_joinHostPort(host, port)}?'
      '${_queryEncode(q)}#${_pathEscape(remarks)}';
}

String _gen2TrojanLink(
    String host, int port, String remarks, Map<String, String> p) {
  final q = _gen2StreamQuery(p);
  _gen2Set(q, 'flow', _g(p, 'flow'));
  return 'trojan://${_pathEscape(_g(p, 'password'))}@${_joinHostPort(host, port)}?'
      '${_queryEncode(q)}#${_pathEscape(remarks)}';
}

String _gen2ShadowsocksLink(
    String host, int port, String remarks, Map<String, String> p) {
  final userinfo = _b64Std('${_g(p, 'method')}:${_g(p, 'password')}');
  return 'ss://$userinfo@${_joinHostPort(host, port)}#${_pathEscape(remarks)}';
}

String _gen2VmessLink(
    String host, int port, String remarks, Map<String, String> p) {
  var headerType = _gen2Or(_g(p, 'headerType'), 'none');
  var hostHeader = _g(p, 'host'), path = _g(p, 'path');
  final n = _g(p, 'network').trim().toLowerCase();
  final network = const [
    'tcp',
    'kcp',
    'ws',
    'httpupgrade',
    'xhttp',
    'http',
    'h2',
    'grpc'
  ].contains(n)
      ? n
      : 'tcp';
  if (network == 'kcp') {
    path = _gen2Or(path, _g(p, 'seed'));
  } else if (network == 'grpc') {
    headerType = _g(p, 'mode');
    path = _gen2Or(path, _g(p, 'serviceName'));
    hostHeader = _gen2Or(hostHeader, _g(p, 'authority'));
  }
  final security = p['security'];
  final obj = <String, dynamic>{
    'v': '2',
    'ps': remarks,
    'add': host,
    'port': '$port',
    'id': _g(p, 'password'),
    'aid': '${_gen2Int(_g(p, 'alterId'))}',
    'scy': _gen2Or(_g(p, 'method'), 'auto'),
    'net': _gen2Or(_g(p, 'network'), 'tcp'),
    'type': headerType,
    'host': hostHeader,
    'path': path,
    'tls': security == 'tls' || security == 'reality' ? 'tls' : '',
    'sni': _g(p, 'sni'),
    'fp': _g(p, 'fingerPrint'),
    'alpn': _g(p, 'alpn'),
    'insecure': security != 'tls' ? '' : (_gen2AllowInsecure(p) ? '1' : '0'),
  };
  return 'vmess://${_b64Std(_goJson(obj))}';
}

String _gen2KeyValues(Map<String, String> p) {
  final keys = p.keys.toList()..sort();
  return [
    for (final k in keys)
      if (p[k]!.isNotEmpty) '$k=${p[k]}'
  ].join(' ');
}

String _gen2V2rayLink(String remarks, String address, Map<String, String> p) {
  final host = _gen2Or(_g(p, 'server'), address);
  final port = _gen2Int(_g(p, 'serverPort')) != 0
      ? _gen2Int(_g(p, 'serverPort'))
      : _gen2Int(_g(p, 'port'));
  switch (_gen2Int(_g(p, 'configType'))) {
    case 1:
      return _gen2VmessLink(host, port, remarks, p);
    case 5:
      return _gen2VlessLink(host, port, remarks, p);
    case 6:
      return _gen2TrojanLink(host, port, remarks, p);
    case 3:
      return _gen2ShadowsocksLink(host, port, remarks, p);
  }
  return _gen2KeyValues(p);
}

String _gen2SshText(String remarks, Map<String, String> s) {
  var target = _g(s, 'sshHost');
  if (_g(s, 'sshPort').isNotEmpty)
    target = _joinHostPort(target, _g(s, 'sshPort'));
  final query = <String, dynamic>{};
  _gen2Set(query, 'remarks', remarks);
  _gen2Set(query, 'sshConfigType', _g(s, 'sshConfigType'));
  _gen2Set(query, 'httpProxy', _g(s, 'httpProxy'));
  final user = _userinfoEscape(_g(s, 'sshUsername'));
  final pwd = _userinfoEscape(_g(s, 'sshPassword'));
  return 'ssh://$user:$pwd@$target?${_queryEncode(query)}#${_g(s, 'payload')}';
}

String _gen2ProxyText(
    String remarks, String address, String kind, Map<String, String> p) {
  var scheme = kind;
  if (scheme.endsWith('Config'))
    scheme = scheme.substring(0, scheme.length - 6);
  if (scheme.endsWith('Profile'))
    scheme = scheme.substring(0, scheme.length - 7);
  var target = _gen2Or(_g(p, 'server'), _gen2Or(_g(p, 'host'), address));
  final port =
      _gen2Or(_g(p, 'serverPort'), _gen2Or(_g(p, 'port'), _g(p, 'localPort')));
  if (port.isNotEmpty) target = _joinHostPort(target, port);
  final query = <String, dynamic>{};
  _gen2Set(query, 'remarks', remarks);
  for (final key in (p.keys.toList()..sort())) {
    if (const ['remarks', 'server', 'host', 'port', 'serverPort', 'localPort']
        .contains(key)) {
      continue;
    }
    _gen2Set(query, key, p[key]!);
  }
  var userinfo = '';
  final user = _g(p, 'username');
  if (user.isNotEmpty) {
    userinfo =
        '${_userinfoEscape(user)}:${_userinfoEscape(_g(p, 'password'))}@';
  } else if (_g(p, 'password').isNotEmpty) {
    userinfo = '${_userinfoEscape(_g(p, 'password'))}@';
  }
  return '$scheme://$userinfo$target?${_queryEncode(query)}';
}

/// One decoded profile (a JSON object) as a share link.
String _gen2Link(Object? cfg) {
  if (cfg is! Map) return _gen2Text(cfg);
  final remarks = _gen2Text(cfg['name']);
  final address = _gen2Text(cfg['address']);
  final profile = cfg['v2rayProfile'];
  if (profile is Map) {
    return _gen2V2rayLink(remarks, address, _gen2FlatMap(profile));
  }
  final ssh = cfg['sshConfig'];
  if (ssh is Map) return _gen2SshText(remarks, _gen2FlatMap(ssh));
  for (final kind in const [
    'socksConfig',
    'socksProfile',
    'httpConfig',
    'httpProfile',
    'proxyConfig'
  ]) {
    final sub = cfg[kind];
    if (sub is Map)
      return _gen2ProxyText(remarks, address, kind, _gen2FlatMap(sub));
  }
  return _gen2KeyValues(_gen2FlatMap(cfg));
}

String _gen2CreatorMessage(Object? meta) {
  final policy = _m(_m(meta)['policy']);
  final parts = <String>[];
  for (final m in [policy['displayMessage'], policy['customServerMessage']]) {
    if (m is String && m.replaceAll('\r\n', '\n').trim().isNotEmpty) {
      parts.add(m.replaceAll('\r\n', '\n').trim());
    }
  }
  return parts.join('\n');
}

/// Whether a v5 file needs a passphrase, or null when it is not a v5 file.
bool? _gen2NeedsPassphrase(Uint8List data) {
  try {
    return _parseGen2Envelope(data).method == _gen2MethodPass;
  } on ConfigDecryptError {
    return null;
  }
}

String decryptNpvsGen2(Uint8List data, String password, NpvTables tables) {
  final env = _parseGen2Envelope(data);
  final opened = _gen2Open(env, password, tables);
  final fields = opened.fields;
  final sentinel = fields[_gen2Sentinel];
  final links = <String>[];
  if (sentinel != null) {
    final Object? spec;
    try {
      spec = jsonDecode(utf8.decode(sentinel));
    } catch (e) {
      throw ConfigDecryptError('npvs gen2: sentinel table: $e');
    }
    for (final cfg in _l(_m(spec)['configs'])) {
      links.add(_gen2Link(_gen2Substitute(cfg, fields)));
    }
  }
  Object? meta;
  try {
    meta = jsonDecode(utf8.decode(opened.metadata));
  } catch (_) {
    meta = null;
  }
  final sb = StringBuffer();
  final msg = _gen2CreatorMessage(meta);
  if (msg.isNotEmpty) sb.write('// ---- creator message ----\n$msg\n\n');
  if (links.isNotEmpty) {
    sb.write(links.join('\n'));
  } else {
    final seqs = fields.keys.where((s) => s != _gen2Sentinel).toList()..sort();
    sb.write([
      for (final s in seqs)
        '// seq=${s.toString().padRight(5)} ${_gen2FieldText(fields[s]!)}'
    ].join('\n'));
  }
  return sb.toString();
}

/// The open container: a plain JSON list of profiles behind an NPVO1 marker.
bool _isOpenEnvelope(Uint8List b) =>
    _utf8(b.length > 64 ? b.sublist(0, 64) : b).trimLeft().startsWith('NPVO1');

String decryptNpvsOpen(Uint8List data) {
  if (data.length > 8 << 20) {
    throw ConfigDecryptError('npvs open: file too large');
  }
  var body = _utf8(data);
  body = body.replaceAll('NPVO1\n', '').replaceAll('NPVO1', '');
  if (body.trim().isEmpty) {
    throw ConfigDecryptError('npvs open: empty payload after marker');
  }
  final Object? env;
  try {
    env = jsonDecode(body);
  } catch (e) {
    throw ConfigDecryptError('npvs open: payload is not a config list');
  }
  final configs = _l(_m(env)['configs']);
  if (configs.isEmpty)
    throw ConfigDecryptError('npvs open: payload has no configs');
  return configs.map((c) => _gen2Link(_openDecodeSentinels(c))).join('\n');
}

Object? _openDecodeSentinels(Object? v) {
  if (v is String) return _decodeSentinels(v);
  if (v is Map) {
    return {for (final e in v.entries) e.key: _openDecodeSentinels(e.value)};
  }
  if (v is List) return [for (final x in v) _openDecodeSentinels(x)];
  return v;
}

Uint8List _gen2Sub7dc0(Uint8List block, int i, int x3, int x4, int x5, int x6) {
  int m32(int v) => v & 0xFFFFFFFF;
  int at(int a) => block[a];
  final out = Uint8List(4);
  int x0 = 0;
  int x2 = i, x8, x9, x10, x11, x12, x13, x14, x15, x16, x17;
  x3 = m32(x3);
  x4 = m32(x4);
  x5 = m32(x5);
  x6 = m32(x6);
  x8 = m32(x2 + m32(x2 << 1));
  x12 = m32(x3 >> 0x14);
  x11 = m32(x3 >> 0x18);
  x13 = (x4 >> 0x18) & 0xF;
  x14 = m32(x5 >> 0x18);
  x10 = x6;
  x9 = m32(x8 << 3);
  x8 = x4;
  x12 &= 0xF0;
  x12 += x13;
  x13 = m32(x5 >> 0x14);
  x16 = x8 >> 0x1C;
  x9 &= 0xFFFFFFFF;
  x11 &= 0xF0;
  x14 &= 0xF0;
  x15 = m32(x6 >> 0x18) & 0xF;
  x13 &= 0xF0;
  x17 = m32(x3 >> 0x10);
  x9 <<= 8;
  x8 &= 0xF;
  x13 += x15;
  x17 &= 0xF0;
  x11 = x9 + x11;
  x14 = x9 + x14;
  x12 = x9 + x12;
  x16 = at(x11 + x16);
  x14 += x10 >> 28;
  x12 = at(x12 + 0x200);
  x13 = x9 + x13;
  x0 = m32(x6 >> 0x14) & 0xF;
  x14 = at(x14 + 0x100);
  x15 = x9 + (x16 << 4);
  x13 = at(x13 + 0x300);
  x12 = x9 + (x12 << 4);
  x16 = m32(x4 >> 0x14) & 0xF;
  x10 &= 0xF;
  x14 = x15 + x14;
  x15 = m32(x5 >> 0x10);
  x12 += x13;
  x13 = m32(x3 >> 0xC);
  x14 = at(x14 + 0x400);
  x12 = at(x12 + 0x500);
  x15 &= 0xF0;
  x16 = x17 + x16;
  x15 += x0;
  x0 = m32(x4 >> 0x10) & 0xF;
  x17 = m32(x5 >> 0xC);
  x12 |= x14 << 4;
  x13 &= 0xF0;
  x14 = m32(x6 >> 0x10) & 0xF;
  x13 += x0;
  x17 &= 0xF0;
  x16 = x9 + x16;
  out[0] = x12 & 0xFF;
  x13 = x9 + x13;
  x12 = x17 + x14;
  x14 = at(x16 + 0x600);
  x13 = at(x13 + 0x800);
  x15 = x9 + x15;
  x12 = x9 + x12;
  x15 = at(x15 + 0x700);
  x16 = m32(x5 >> 8);
  x12 = at(x12 + 0x900);
  x14 = x9 + (x14 << 4);
  x13 = x9 + (x13 << 4);
  x0 = m32(x6 >> 0xC) & 0xF;
  x17 = m32(x3 >> 8);
  x14 += x15;
  x12 = x13 + x12;
  x13 = x16 & 0xF0;
  x14 = at(x14 + 0xA00);
  x12 = at(x12 + 0xB00);
  x15 = m32(x3 >> 4);
  x13 += x0;
  x0 = m32(x4 >> 8) & 0xF;
  x16 = m32(x4 >> 0xC) & 0xF;
  x12 |= x14 << 4;
  x14 = x15 & 0xF0;
  x17 &= 0xF0;
  x14 += x0;
  x15 = x9 + 0xC00;
  x0 = m32(x5 >> 4);
  x17 = x15 + x17;
  out[1] = x12 & 0xFF;
  x12 = m32(x6 >> 8) & 0xF;
  x16 = at(x17 + x16);
  x14 = x9 + x14;
  x17 = x0 & 0xF0;
  x14 = at(x14 + 0xE00);
  x12 = x17 + x12;
  x13 = x15 + x13;
  x12 = x9 + x12;
  x13 = at(x13 + 0x100);
  x15 = x9 + (x16 << 4);
  x12 = at(x12 + 0xF00);
  x14 = x9 + (x14 << 4);
  x16 = 0x1000;
  x13 = x15 + x13;
  x17 = m32(x6 >> 4) & 0xF;
  x0 = x5 & 0xF0;
  x12 = x14 + x12;
  x14 = 0x1100;
  x13 = at(x13 + x16);
  x12 = at(x12 + x14);
  x14 = 0x1200;
  x15 = m32(x4 >> 4) & 0xF;
  x16 = x3 & 0xF0;
  x17 = x0 + x17;
  x14 = x9 + x14;
  x12 |= x13 << 4;
  x13 = (x3 & 0xF) << 4;
  x16 = x14 + x16;
  out[2] = x12 & 0xFF;
  x8 = x13 + x8;
  x12 = x14 + x17;
  x14 = (x5 & 0xF) << 4;
  x13 = at(x16 + x15);
  x8 = x9 + x8;
  x15 = 0x1400;
  x12 = at(x12 + 0x100);
  x8 = at(x8 + x15);
  x10 = x14 + x10;
  x14 = 0x1500;
  x10 = x9 + x10;
  x13 = x9 + (x13 << 4);
  x10 = at(x10 + x14);
  x8 = x9 + (x8 << 4);
  x9 = x13 + x12;
  x12 = 0x1600;
  x8 += x10;
  x10 = 0x1700;
  x9 = at(x9 + x12);
  x8 = at(x8 + x10);
  x8 |= x9 << 4;
  out[3] = x8 & 0xFF;
  return out;
}
