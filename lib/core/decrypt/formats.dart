part of '../config_decryptor.dart';

// The simpler container formats: HA Tunnel (.hat), NetMod (.nm), Happ, DarkTunnel
// (.dark), TLS Tunnel (.tls), ZedSecure (.zsx), sing-box (.bpf), HTTP Injector
// (.ehi) and the SlipNet variants.

// ------------------------------------------------------------------ HA Tunnel

String decryptHat(Uint8List payload) {
  final Uint8List ciphertext;
  try {
    ciphertext = _b64Strict(ascii.decode(payload).trim());
  } on FormatException catch (e) {
    throw ConfigDecryptError('base64 decode: $e');
  }
  final key =
      SHA1Digest().process(utf8.encode('8515D40BD04D8C97')).sublist(0, 16);
  final plain = _unpadSoft(_aes(ciphertext, key), 16);
  return _goIndent(plain) ?? _utf8(plain);
}

/// pkcs7Unpad from hat.go: strict check, falling back to trimming control bytes.
Uint8List _unpadSoft(Uint8List d, int block) {
  if (d.isEmpty) throw ConfigDecryptError('empty padding data');
  if (d.length % block != 0) {
    throw ConfigDecryptError('data length is not a multiple of block size');
  }
  final pad = d.last;
  if (pad >= 1 && pad <= block) {
    var ok = true;
    for (var i = d.length - pad; i < d.length; i++) {
      if (d[i] != pad) ok = false;
    }
    if (ok) return d.sublist(0, d.length - pad);
  }
  var end = d.length;
  while (end > 0 && (d[end - 1] < 32 || d[end - 1] == 0x20)) {
    end--;
  }
  return d.sublist(0, end);
}

// -------------------------------------------------------------------- NetMod

const _netmodKeys = [
  '<n3t5yn4^n3tm0d>',
  '_netsyna_netmod_',
  'nicetrybuddygoon'
];

String decryptNetmod(Uint8List payload, String proto) {
  final text = _utf8(payload).replaceAll(RegExp(r'[\n\r \t]'), '');
  final Uint8List ciphertext;
  try {
    ciphertext = _b64Strict(text);
  } on ConfigDecryptError catch (e) {
    throw ConfigDecryptError('base64 decode: $e');
  }
  Uint8List? plain;
  var last = 'no key';
  for (final key in _netmodKeys) {
    if (ciphertext.isEmpty || ciphertext.length % 16 != 0) {
      last = 'ciphertext length not multiple of block size';
      continue;
    }
    try {
      plain =
          _unpadStrict(_aes(ciphertext, Uint8List.fromList(utf8.encode(key))));
      break;
    } on ConfigDecryptError catch (e) {
      last = "key '$key': $e";
    }
  }
  if (plain == null) throw ConfigDecryptError('no netmod key matched: $last');
  var out = _goIndent(plain) ?? _utf8(plain);
  if (proto.isNotEmpty) {
    out = '$proto://${_netmodTrustServer(proto, out)}';
  }
  return out;
}

/// NetMod connects without checking the server's certificate, and its trojan / vless configs rely
/// on it: they name an SNI the server's certificate does not cover (a CDN front such as
/// `firefox.com` on a Fastly address), so with the check on, the same config never connects here.
/// The flag is added to the TLS ones that do not say otherwise.
String _netmodTrustServer(String proto, String body) {
  final scheme = proto.startsWith('nm-') ? proto.substring(3) : proto;
  if (scheme == 'vmess') return _netmodVmess(body);
  const known = {'trojan', 'vless', 'hysteria2', 'hy2', 'tuic'};
  if (!known.contains(scheme)) return body;
  final text = body.trim();
  if (text.startsWith('{') || text.startsWith('[')) return body;
  final hash = text.indexOf('#');
  final main = hash < 0 ? text : text.substring(0, hash);
  final tail = hash < 0 ? '' : text.substring(hash);
  final lower = main.toLowerCase();
  if (lower.contains('insecure=') ||
      lower.contains('security=none') ||
      lower.contains('security=reality') ||
      lower.contains('pcs=')) {
    return body;
  }
  // vless without a security parameter is plain TCP: nothing to verify.
  if (scheme == 'vless' && !lower.contains('security=tls')) return body;
  return '$main${main.contains('?') ? '&' : '?'}allowInsecure=1$tail';
}

/// A NetMod vmess config: the base64 JSON of a vmess link, or that JSON itself (which was
/// re-indented over several lines above). TLS ones get the same no-verification flag.
String _netmodVmess(String body) {
  var text = body.trim();
  var prefix = '';
  if (text.startsWith('vmess://')) {
    prefix = 'vmess://';
    text = text.substring(prefix.length).trim();
  }
  try {
    final isJson = text.startsWith('{');
    final json = jsonDecode(isJson
        ? text
        : utf8.decode(base64.decode(base64.normalize(
            text.replaceAll('-', '+').replaceAll('_', '/'))))) as Map;
    final map = Map<String, dynamic>.from(json);
    final secure = '${map['tls']}' == 'tls';
    final decided = map.containsKey('allowInsecure') ||
        map.containsKey('insecure') ||
        map.containsKey('pcs');
    if (!isJson && (!secure || decided)) return body;
    if (secure && !decided) map['allowInsecure'] = true;
    return '$prefix${base64.encode(utf8.encode(jsonEncode(map)))}';
  } catch (_) {
    return body;
  }
}

// ---------------------------------------------------------------------- Happ

Uint8List _b64UrlSafeWs(String s) {
  s = s
      .replaceAll(RegExp(r'[ \t\n\r]'), '')
      .replaceAll('-', '+')
      .replaceAll('_', '/');
  s = s.replaceAll(RegExp(r'=+$'), '');
  if (s.length % 4 != 0) s += '=' * (4 - s.length % 4);
  return _b64Strict(s);
}

RSAPrivateKey _rsaFromDer(Uint8List der) {
  var seq = ASN1Parser(der).nextObject() as ASN1Sequence;
  if (seq.elements![1] is ASN1Sequence) {
    // PKCS#8 wrapper around the PKCS#1 key
    final inner = seq.elements![2] as ASN1OctetString;
    seq = ASN1Parser(inner.valueBytes).nextObject() as ASN1Sequence;
  }
  BigInt n(int i) => (seq.elements![i] as ASN1Integer).integer!;
  return RSAPrivateKey(n(1), n(3), n(4), n(5));
}

Uint8List _rsaDecrypt(RSAPrivateKey key, Uint8List ct) {
  final engine = PKCS1Encoding(RSAEngine())
    ..init(false, PrivateKeyParameter<RSAPrivateKey>(key));
  return engine.process(ct);
}

String _happCrypt1to4(String encryptedB64, RSAPrivateKey key) {
  if (encryptedB64.isEmpty) {
    throw ConfigDecryptError('encrypted payload cannot be empty');
  }
  final cipher = _b64UrlSafeWs(encryptedB64);
  final size = (key.modulus!.bitLength + 7) ~/ 8;
  if (cipher.length % size != 0) {
    throw ConfigDecryptError('cipher text data boundaries are not aligned');
  }
  final out = BytesBuilder();
  for (var i = 0; i < cipher.length; i += size) {
    out.add(_rsaDecrypt(key, cipher.sublist(i, i + size)));
  }
  return _utf8(out.toBytes());
}

Uint8List _happSwapAdjacent(Uint8List src) {
  final out = Uint8List.fromList(src);
  for (var i = 0; i < out.length - 1; i += 2) {
    final t = out[i];
    out[i] = out[i + 1];
    out[i + 1] = t;
  }
  return out;
}

Uint8List _happSwapBlockHalves(Uint8List src) {
  final out = Uint8List.fromList(src);
  for (var i = 0; i < out.length - 3; i += 4) {
    var t = out[i];
    out[i] = out[i + 2];
    out[i + 2] = t;
    t = out[i + 1];
    out[i + 1] = out[i + 3];
    out[i + 3] = t;
  }
  return out;
}

String _latin1(List<int> b) => latin1.decode(b);

String _crypt5Body(Uint8List body, RSAPrivateKey key, bool salted) {
  if (body.length < 13) throw ConfigDecryptError('crypt5 body is too short');
  final nonce = body.sublist(0, 12);
  var lengthStart = 12;
  var salt = Uint8List(0);
  if (salted) {
    if (body.length < 14 + 8 + 1) {
      throw ConfigDecryptError('crypt5 salted body is too short');
    }
    salt = body.sublist(14, 22);
    lengthStart = 22;
  }
  var lengthEnd = lengthStart;
  while (lengthEnd < body.length &&
      body[lengthEnd] >= 0x30 &&
      body[lengthEnd] <= 0x39) {
    lengthEnd++;
  }
  if (lengthEnd == lengthStart) {
    throw ConfigDecryptError('crypt5 segment length is missing');
  }
  final segmentLength =
      int.parse(_latin1(body.sublist(lengthStart, lengthEnd)));
  final packed = body.sublist(lengthEnd);
  if (packed.isEmpty || segmentLength > packed.length - 1) {
    throw ConfigDecryptError('crypt5 segment is truncated');
  }
  final sealedUrl = packed.sublist(1, segmentLength + 1);
  final rsaBlock = packed.sublist(segmentLength + 1);
  final rsaCt = _b64UrlSafeWs(_latin1(rsaBlock));
  final rsaPlain = _rsaDecrypt(key, rsaCt);
  var chachaKey = _b64UrlSafeWs(_latin1(_happSwapAdjacent(rsaPlain)));
  if (chachaKey.length != 32) {
    throw ConfigDecryptError(
        'crypt5 recovered key is not 32 bytes (got ${chachaKey.length})');
  }
  if (salt.isNotEmpty) {
    chachaKey = Uint8List.fromList(
        [for (var i = 0; i < 32; i++) chachaKey[i] ^ salt[i % salt.length]]);
  }
  final ciphertext = _b64UrlSafeWs(_latin1(sealedUrl));
  final intermediate = _chachaOpenOrThrow(chachaKey, nonce, ciphertext, null);
  final plain = _b64UrlSafeWs(_latin1(_happSwapAdjacent(intermediate)));
  return _utf8(plain);
}

String _decryptCrypt5(String payload, Map<String, String> keys) {
  final shuffled =
      _happSwapBlockHalves(Uint8List.fromList(utf8.encode(payload)));
  if (shuffled.length < 8)
    throw ConfigDecryptError('crypt5 payload is too short');
  final marker = _latin1(shuffled.sublist(0, 4)) +
      _latin1(shuffled.sublist(shuffled.length - 4));
  final der = keys[marker];
  if (der == null) {
    throw ConfigDecryptError(
        'crypt5 payload names a marker with no bundled key');
  }
  final key = _rsaFromDer(base64.decode(der));
  final body = shuffled.sublist(4, shuffled.length - 4);
  final salted = body.length > 12 && !(body[12] >= 0x30 && body[12] <= 0x39);
  ConfigDecryptError? first;
  for (final attempt in [salted, !salted]) {
    try {
      return _crypt5Body(body, key, attempt);
    } on ConfigDecryptError catch (e) {
      first ??= e;
    }
  }
  throw first!;
}

String decryptHapp(Uint8List payload, NpvTables tables) {
  final link = _utf8(payload).trim();
  if (link.isEmpty) throw ConfigDecryptError('cannot decrypt an empty link');
  final m =
      RegExp(r'^(?:happ://)?([^/]+)/(.+)$', dotAll: true).firstMatch(link);
  if (m == null) throw ConfigDecryptError('link format is invalid');
  final version = m.group(1)!, data = m.group(2)!;
  if (version == 'crypt5') {
    final raw = tables.crypt5Json;
    if (raw == null) throw ConfigDecryptError('Missing tables');
    final table = (jsonDecode(utf8.decode(raw)) as Map).cast<String, String>();
    return _decryptCrypt5(data, table);
  }
  Object last = ConfigDecryptError(
      'failed to decrypt data with any available key fallback');
  for (final kv in [version, ..._happKeyVersions]) {
    final idx = _happKeyVersions.indexOf(kv);
    if (idx < 0) continue;
    try {
      return _happCrypt1to4(
          data, _rsaFromDer(base64.decode(_happKeysB64[idx])));
    } catch (e) {
      last = e;
    }
  }
  throw last;
}

// ----------------------------------------------------------------- DarkTunnel

final _dtKey256 =
    Uint8List.fromList(utf8.encode(r'$B&E)H@McQfThWmZq4t7w!z%C*F-JaNd'));
final _dtKey192 = Uint8List.fromList(utf8.encode('F)J@NcRfUjXn2r4u7x!A%D*G'));
final _dtIv = _hex('232e39185523184a5723586242200e05');

Uint8List _b64DecodeSafe(String data) {
  var clean = data.replaceAll('-', '+').replaceAll('_', '/');
  if (clean.length % 4 != 0) clean += '=' * (4 - clean.length % 4);
  return _b64Strict(clean);
}

/// Minimal MessagePack reader (str as String, bin as bytes).
class _MsgPack {
  _MsgPack(this.b);
  final Uint8List b;
  int o = 0;

  Uint8List _take(int n) {
    if (o + n > b.length) throw const FormatException('msgpack: truncated');
    final r = b.sublist(o, o + n);
    o += n;
    return r;
  }

  int _uint(int n) {
    final v = _be(_take(n), 0, n);
    return v;
  }

  Object? read() {
    final t = _take(1)[0];
    if (t <= 0x7f) return t;
    if (t >= 0xe0) return t - 256;
    if (t >= 0xa0 && t <= 0xbf) return utf8.decode(_take(t & 0x1f));
    if (t >= 0x90 && t <= 0x9f) return _arr(t & 0x0f);
    if (t >= 0x80 && t <= 0x8f) return _map(t & 0x0f);
    switch (t) {
      case 0xc0:
        return null;
      case 0xc2:
        return false;
      case 0xc3:
        return true;
      case 0xc4:
        return _take(_uint(1));
      case 0xc5:
        return _take(_uint(2));
      case 0xc6:
        return _take(_uint(4));
      case 0xc7:
        {
          final n = _uint(1);
          _take(1);
          return _take(n);
        }
      case 0xc8:
        {
          final n = _uint(2);
          _take(1);
          return _take(n);
        }
      case 0xc9:
        {
          final n = _uint(4);
          _take(1);
          return _take(n);
        }
      case 0xca:
        return ByteData.sublistView(_take(4)).getFloat32(0);
      case 0xcb:
        return ByteData.sublistView(_take(8)).getFloat64(0);
      case 0xcc:
        return _uint(1);
      case 0xcd:
        return _uint(2);
      case 0xce:
        return _uint(4);
      case 0xcf:
        return ByteData.sublistView(_take(8)).getInt64(0);
      case 0xd0:
        return ByteData.sublistView(_take(1)).getInt8(0);
      case 0xd1:
        return ByteData.sublistView(_take(2)).getInt16(0);
      case 0xd2:
        return ByteData.sublistView(_take(4)).getInt32(0);
      case 0xd3:
        return ByteData.sublistView(_take(8)).getInt64(0);
      case 0xd4:
      case 0xd5:
      case 0xd6:
      case 0xd7:
      case 0xd8:
        {
          final n = 1 << (t - 0xd4);
          _take(1);
          return _take(n);
        }
      case 0xd9:
        return utf8.decode(_take(_uint(1)));
      case 0xda:
        return utf8.decode(_take(_uint(2)));
      case 0xdb:
        return utf8.decode(_take(_uint(4)));
      case 0xdc:
        return _arr(_uint(2));
      case 0xdd:
        return _arr(_uint(4));
      case 0xde:
        return _map(_uint(2));
      case 0xdf:
        return _map(_uint(4));
    }
    throw FormatException('msgpack: bad type 0x${t.toRadixString(16)}');
  }

  List<Object?> _arr(int n) => [for (var i = 0; i < n; i++) read()];

  Map<Object?, Object?> _map(int n) {
    final m = <Object?, Object?>{};
    for (var i = 0; i < n; i++) {
      final k = read();
      m[k] = read();
    }
    return m;
  }
}

bool _dtIsPrintable(Uint8List value) {
  if (value.isEmpty) return false;
  return !RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]').hasMatch(_utf8(value));
}

Object? _dtTryParseJsonString(String value) {
  final trimmed = value.trim();
  if (!((trimmed.startsWith('{') && trimmed.endsWith('}')) ||
      (trimmed.startsWith('[') && trimmed.endsWith(']')))) {
    return value;
  }
  final fixed = trimmed.replaceAllMapped(
      RegExp(r'(:\s*)(\$[A-Za-z0-9_]+)'), (m) => '${m[1]}"${m[2]}"');
  try {
    return _dtNormalize(jsonDecode(fixed));
  } catch (_) {
    return value;
  }
}

Object? _dtNormalize(Object? value) {
  if (value is Map) {
    return {for (final e in value.entries) '${e.key}': _dtNormalize(e.value)};
  }
  if (value is Uint8List) {
    return _dtIsPrintable(value)
        ? _dtTryParseJsonString(_utf8(value))
        : value.toList();
  }
  if (value is List) return [for (final v in value) _dtNormalize(v)];
  if (value is String) return _dtTryParseJsonString(value);
  return value;
}

Object? _dtCleanEncrypted(Object? value) {
  if (value is Map) {
    final cleaned = <Object?, Object?>{};
    for (final e in value.entries) {
      final v = e.value;
      if ('${e.key}'.startsWith('Encrypted') &&
          v is Uint8List &&
          v.isNotEmpty) {
        cleaned[e.key] = _aes(v, _dtKey192, mode: 'cfb', iv: _dtIv);
        continue;
      }
      cleaned[e.key] = _dtCleanEncrypted(v);
    }
    return cleaned;
  }
  if (value is List) return [for (final v in value) _dtCleanEncrypted(v)];
  return value;
}

String decryptDark(Uint8List payload) {
  final outerBytes = _b64DecodeSafe(_utf8(payload).trim());
  final Object? outer;
  try {
    outer = jsonDecode(utf8.decode(outerBytes));
  } catch (e) {
    throw ConfigDecryptError('outer json: $e');
  }
  if (outer is! Map || outer['encryptedLockedConfig'] is! String) {
    throw ConfigDecryptError('missing or invalid encryptedLockedConfig key');
  }
  final enc = _b64DecodeSafe(outer['encryptedLockedConfig'] as String);
  final decOuter = _aes(enc, _dtKey256, mode: 'cfb', iv: _dtIv);
  final unpackedOuter = _MsgPack(decOuter).read();
  if (unpackedOuter is Map &&
      unpackedOuter['EncryptedLockedConfig'] is Uint8List) {
    final inner = _aes(
        unpackedOuter['EncryptedLockedConfig'] as Uint8List, _dtKey192,
        mode: 'cfb', iv: _dtIv);
    unpackedOuter['EncryptedLockedConfig'] =
        _dtCleanEncrypted(_MsgPack(inner).read());
  }
  outer['encryptedLockedConfig'] = unpackedOuter;
  return _goJson(_dtNormalize(outer), indent: '    ', sortKeys: true);
}

// ----------------------------------------------------------------- TLS Tunnel

const _tlsPortSelections = ['AUTO', 'T 80', 'T 443', 'CUSTOM'];
const _tlsB64Alphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

String _reverseRunes(String s) =>
    String.fromCharCodes(s.runes.toList().reversed);

(Uint8List, int) _tlsDecryptConfig(Uint8List raw) {
  final clean = <int>[
    for (var i = raw.length - 1; i >= 0; i--)
      if (_tlsB64Alphabet.contains(String.fromCharCode(raw[i]))) raw[i]
  ];
  if (clean.isEmpty) throw ConfigDecryptError('no base64 payload found');
  final text = String.fromCharCodes(clean);
  final blob = base64.decode(base64.normalize(text));
  const overhead = 12 + 36 + 84;
  if (blob.length < overhead + 32) {
    throw ConfigDecryptError('payload too short: ${blob.length} bytes');
  }
  final half = (blob.length - overhead) ~/ 2;
  List<int> rev(List<int> l) => l.reversed.toList();
  final iv = Uint8List.fromList([
    ...rev(blob.sublist(half + 12, half + 12 + 18)),
    ...rev(blob.sublist(blob.length - 102, blob.length - 84)),
  ]);
  final ciphertext = Uint8List.fromList([
    ...rev(blob.sublist(12, half + 12)),
    ...rev(blob.sublist(half + 18 + 12, blob.length - 102)),
  ]);
  for (var index = 0; index < _tlsKeyLiterals.length; index++) {
    final key =
        Uint8List.fromList(utf8.encode(_reverseRunes(_tlsKeyLiterals[index])));
    try {
      return (_aesGcmOpen(key, iv, ciphertext, null), index);
    } catch (_) {
      continue;
    }
  }
  throw ConfigDecryptError('no TLS Tunnel key authenticated this config');
}

String _tlsDecodeField(int kind, String stored) {
  stored = stored.trim();
  if (stored.isEmpty || kind != 1) return stored;
  try {
    final bare = stored.replaceAll(RegExp(r'=+$'), '');
    final padded = bare + '=' * ((4 - bare.length % 4) % 4);
    return utf8.decode(_b64Strict(padded));
  } catch (_) {
    return stored;
  }
}

String _tlsRenderValue(int kind, String stored) {
  final value = _tlsDecodeField(kind, stored);
  if (kind == 2) {
    if (value.toLowerCase() == 'true') return '✅ TRUE';
    if (value.toLowerCase() == 'false') return '❌ FALSE';
    return value;
  }
  if (kind == 3) {
    final idx = int.tryParse(stored.trim());
    if (idx != null && idx >= 0 && idx < _tlsPortSelections.length) {
      return '${_tlsPortSelections[idx]} ($idx)';
    }
    return stored;
  }
  return value;
}

String decryptTls(Uint8List data) {
  final (plain, keyIndex) = _tlsDecryptConfig(data);
  var text = _utf8(plain);
  if (text.startsWith('﻿')) text = text.substring(1);
  text = text.replaceAll(RegExp(r'\x00+$'), '');
  final fields = text.split(':');
  if (fields.length < _tlsFields.length) {
    throw ConfigDecryptError(
        'expected at least ${_tlsFields.length} fields, got ${fields.length}');
  }
  final tag = int.tryParse(fields[0].trim()) ?? 0;
  final documented = tag == 506 || tag == 507;
  final rows = <(String, String)>[];
  if (documented) {
    final ssh = fields[3].trim().toLowerCase() == 'true';
    rows.add(('Connection', ssh ? 'Private Server (SSH)' : 'Official servers'));
  }
  for (var i = 0; i < _tlsFields.length; i++) {
    final (name, label, kind) = _tlsFields[i];
    final String rowLabel, value;
    if (documented) {
      if (name == 'sshServer') continue;
      rowLabel = label;
      value = _tlsRenderValue(kind, fields[i]);
    } else {
      rowLabel = 'Field $i';
      value = fields[i].trim();
    }
    if (value.isEmpty) continue;
    rows.add((rowLabel, value));
  }
  for (var i = _tlsFields.length; i < fields.length; i++) {
    if (fields[i].trim().isNotEmpty) rows.add(('Field $i', fields[i].trim()));
  }
  final sb = <String>[
    '\n[+] TLS Tunnel profile (tag $tag, key #$keyIndex of ${_tlsKeyLiterals.length})',
    '${'FIELD'.padRight(30)} | VALUE',
    '-' * 80,
  ];
  for (final (label, value) in rows) {
    final lines = value.split('\n');
    final indent = ' ' * 33;
    for (var j = 1; j < lines.length; j++) {
      lines[j] = indent + lines[j].trim();
    }
    sb.add('${label.padRight(30)} | ${lines.join('\n')}');
  }
  return '${sb.join('\n')}\n';
}

// ---------------------------------------------------------------- ZedSecure

final _zsxOpenKey = _sha256(utf8.encode('ZedSecure .zsx v2'));
const _zedScheme = 'zedsecure://';

Uint8List _zsxB64(String value) {
  final clean = value.trim();
  try {
    return _b64Strict(clean);
  } on ConfigDecryptError {
    final bare = clean.replaceAll(RegExp(r'=+$'), '');
    return base64.decode(base64.normalize(bare));
  }
}

Map _parseZsxOuter(Uint8List data) {
  if (data.length < 4 + 1 + 12 + 16) {
    throw ConfigDecryptError('file is too short to be a .zsx vault');
  }
  if (_latin1(data.sublist(0, 4)) != 'ZSX1')
    throw ConfigDecryptError('bad magic');
  final ver = data[4];
  if (ver == 1) {
    throw ConfigDecryptError(
        'this vault was made by an older ZedSecure version');
  }
  if (ver != 2) throw ConfigDecryptError('unsupported .zsx version $ver');
  final nonce = data.sublist(5, 17);
  final plain =
      _gcmOpenOrThrow(_zsxOpenKey, nonce, data.sublist(17), data.sublist(0, 5));
  final Object? inner;
  try {
    inner = jsonDecode(utf8.decode(plain));
  } catch (e) {
    throw ConfigDecryptError('metadata parse: $e');
  }
  if (inner is! Map) throw ConfigDecryptError('metadata parse: not an object');
  if (inner['mode'] != 0 && inner['mode'] != 1) {
    throw ConfigDecryptError('unsupported unlock mode ${inner['mode']}');
  }
  return inner;
}

/// 0 = open, 1 = password protected, null = not a vault.
int? _zsxMode(Uint8List data) {
  try {
    return _parseZsxOuter(data)['mode'] as int;
  } catch (_) {
    return null;
  }
}

String _openZsxPayload(Map inner, String password) {
  var key = _zsxOpenKey;
  if (inner['mode'] == 1) {
    if (password.isEmpty)
      throw ConfigDecryptError('this vault is password protected');
    final kdf = inner['kdf'];
    if (kdf is! Map)
      throw ConfigDecryptError('password vault has no KDF parameters');
    final salt = _zsxB64(_str(kdf['salt']));
    if (salt.length < 8)
      throw ConfigDecryptError('kdf salt is only ${salt.length} bytes');
    key = _argon2id(utf8.encode(password), salt, 3, 65536, 1, 32);
  }
  final nonce = _zsxB64(_str(inner['cfgNonce']));
  if (nonce.length != 12) {
    throw ConfigDecryptError('config nonce is ${nonce.length} bytes, want 12');
  }
  final cipher = _zsxB64(_str(inner['cfgCipher']));
  try {
    return _utf8(_aesGcmOpen(
        key, nonce, cipher, Uint8List.fromList(utf8.encode('zsx-cfg-v1'))));
  } on InvalidCipherTextException {
    throw ConfigDecryptError(inner['mode'] == 1
        ? 'incorrect password'
        : 'config failed to authenticate');
  }
}

String? _zedLinkBody(String text) {
  final trimmed = text.trim();
  if (trimmed.length < _zedScheme.length ||
      !trimmed.toLowerCase().startsWith(_zedScheme)) {
    return null;
  }
  return trimmed.substring(_zedScheme.length).split('#').first.trim();
}

String _zsxComment(String key, String value) {
  final lines = value.replaceAll(RegExp(r'[\r\n]+$'), '').split('\n');
  return [
    for (var i = 0; i < lines.length; i++)
      i == 0 ? '// $key: ${lines[i]}' : '// ${' ' * key.length}   ${lines[i]}'
  ].join('\n');
}

String _formatZedLink(String text) {
  final body = _zedLinkBody(text);
  if (body == null) throw ConfigDecryptError('not a zedsecure:// link');
  final Object? payload;
  try {
    payload = jsonDecode(utf8.decode(_b64UrlSafeWs(body)));
  } catch (e) {
    throw ConfigDecryptError('link JSON: $e');
  }
  final p = _m(payload);
  final source = _m(p['s']);
  final kind = _t(source['kind']) ? _s(source['kind']) : 'unknown';
  final sb = <String>[
    '// ---- ZedSecure shared profile ----',
    _zsxComment('version', p.containsKey('v') ? _s(p['v']) : ''),
    _zsxComment('name', p.containsKey('n') ? _s(p['n']) : ''),
    _zsxComment('source', kind),
  ];
  final members = p['m'];
  if (members is List && members.isNotEmpty) {
    sb.add(_zsxComment('members', '${members.length}'));
  }
  sb
    ..add('')
    ..add(_goJson(payload, indent: '  '))
    ..add('');
  return sb.join('\n');
}

String _utcStamp(num ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms.toInt(), isUtc: true);
  String p(int n) => n.toString().padLeft(2, '0');
  return '${d.year.toString().padLeft(4, '0')}-${p(d.month)}-${p(d.day)}T'
      '${p(d.hour)}:${p(d.minute)}:${p(d.second)}Z';
}

String _formatZsxVault(Map inner, String payload) {
  final sb = <String>['// ---- ZedSecure vault profile ----'];
  if (_t(inner['nameEn'])) sb.add(_zsxComment('name', _s(inner['nameEn'])));
  if (_t(inner['nameFa']) && inner['nameFa'] != inner['nameEn']) {
    sb.add(_zsxComment('name (fa)', _s(inner['nameFa'])));
  }
  if (_t(inner['note'])) sb.add(_zsxComment('note', _s(inner['note'])));
  final createdAt = inner['createdAt'];
  if (createdAt is num && createdAt > 0) {
    sb.add(_zsxComment('created', _utcStamp(createdAt)));
  }
  final expiresAt = inner['expiresAt'];
  if (expiresAt is num && expiresAt > 0) {
    var expires = _utcStamp(expiresAt);
    if (expiresAt < DateTime.now().millisecondsSinceEpoch)
      expires += ' (expired)';
    sb.add(_zsxComment('expires', expires));
  } else {
    sb.add(_zsxComment('expires', 'not set'));
  }
  sb.add(_zsxComment('password', inner['mode'] == 1 ? 'required' : 'not set'));
  const known = {
    'mode',
    'kdf',
    'cfgNonce',
    'cfgCipher',
    'nameEn',
    'nameFa',
    'note',
    'createdAt',
    'expiresAt'
  };
  final keys = inner.keys.map((k) => '$k').toList()..sort();
  for (final key in keys) {
    final v = inner[key];
    if (known.contains(key) ||
        v == null ||
        v == '' ||
        (v is List && v.isEmpty) ||
        (v is Map && v.isEmpty)) {
      continue;
    }
    sb.add(_zsxComment(key, v is String ? v : _goJson(v)));
  }
  final trimmed = payload.trim();
  if (trimmed.isEmpty) {
    sb.add(_zsxComment('payload', 'empty'));
    return sb.join('\n');
  }
  if (_zedLinkBody(trimmed) != null) {
    var kind = '';
    try {
      final obj =
          jsonDecode(utf8.decode(_b64UrlSafeWs(_zedLinkBody(trimmed)!)));
      kind = _str(_m(_m(obj)['s'])['kind']);
    } catch (_) {
      kind = '';
    }
    sb
      ..add(_zsxComment(
          'payload', 'ZedSecure link${kind.isNotEmpty ? ' ($kind)' : ''}'))
      ..add('');
    try {
      sb.add(_formatZedLink(trimmed)
          .replaceFirst('// ---- ZedSecure shared profile ----\n', ''));
    } on ConfigDecryptError {
      sb
        ..add(trimmed)
        ..add('');
    }
  } else {
    Object? parsed;
    var isJson = true;
    try {
      parsed = jsonDecode(trimmed);
    } catch (_) {
      isJson = false;
    }
    if (isJson) {
      sb
        ..add(_zsxComment('payload', 'JSON config'))
        ..add('')
        ..add(_goJson(parsed, indent: '  '))
        ..add('');
    } else {
      sb
        ..add(_zsxComment('payload', 'share link'))
        ..add('')
        ..add(trimmed)
        ..add('');
    }
  }
  return sb.join('\n');
}

String decryptZsx(Uint8List data, String password) {
  if (_zedLinkBody(_utf8(data)) != null) return _formatZedLink(_utf8(data));
  final inner = _parseZsxOuter(data);
  return _formatZsxVault(inner, _openZsxPayload(inner, password));
}

// ------------------------------------------------------------------ sing-box

class _BpfReader {
  _BpfReader(this.b);
  final Uint8List b;
  int off = 0;

  Uint8List take(int n) {
    if (n < 0 || n > b.length - off) {
      throw ConfigDecryptError('truncated at offset $off');
    }
    final r = b.sublist(off, off + n);
    off += n;
    return r;
  }

  int readByte() => take(1)[0];

  int readUvarint() {
    var value = 0;
    for (var i = 0; i < 10; i++) {
      final x = readByte();
      if (i == 9 && x > 1)
        throw ConfigDecryptError('uvarint overflows 64 bits');
      value |= (x & 0x7F) << (7 * i);
      if (x & 0x80 == 0) return value;
    }
    throw ConfigDecryptError('uvarint is too long');
  }

  String readString() {
    final n = readUvarint();
    if (n > 1 << 20)
      throw ConfigDecryptError('field length $n exceeds the limit');
    return _utf8(take(n));
  }

  int readInt32() => ByteData.sublistView(take(4)).getInt32(0);

  int readInt64() => ByteData.sublistView(take(8)).getInt64(0);
}

String decryptBpf(Uint8List raw, String fileName) {
  if (raw.length < 2)
    throw ConfigDecryptError('file is too small to be a .bpf profile');
  if (raw[0] != 0x03) throw ConfigDecryptError('unexpected message type');
  final version = raw[1];
  if (version > 1)
    throw ConfigDecryptError(
        'container version $version is newer than supported');
  final Uint8List body;
  try {
    body = Uint8List.fromList(gzip.decode(raw.sublist(2)));
  } catch (e) {
    throw ConfigDecryptError('payload is not a gzip stream');
  }
  if (body.length > 4 << 20)
    throw ConfigDecryptError('inflated payload is too large');
  final r = _BpfReader(body);
  final name = r.readString();
  final kind = r.readInt32();
  if (kind == 1) {
    throw ConfigDecryptError(
        '$name is an iCloud profile, recover it from iCloud');
  }
  if (kind != 0 && kind != 2)
    throw ConfigDecryptError('unknown profile type $kind');
  final config = r.readString();
  final sb = <String>[
    '// ---- sing-box profile ----',
    '// name: ${name.isNotEmpty ? name : fileName.replaceAll(RegExp(r'\.bpf$'), '')}',
    '// type: ${kind == 0 ? 'local' : 'remote'} (container version $version)',
  ];
  if (kind == 2) {
    final source = r.readString();
    final auto = r.readByte() != 0;
    final minutes = version >= 1 ? r.readInt32() : 0;
    final last = r.readInt64();
    sb.add('// source: $source');
    if (!auto) {
      sb.add('// auto-update: off');
    } else if (minutes > 0) {
      sb.add('// auto-update: every $minutes min');
    } else {
      sb.add('// auto-update: on');
    }
    if (last > 0) sb.add('// last updated: ${_utcStamp(last)}');
  }
  sb.add('');
  final trimmed = config.trim();
  if (trimmed.isEmpty) {
    sb.add('// (the profile carries no config of its own)');
  } else {
    try {
      sb.add(_goJson(jsonDecode(trimmed), indent: '  '));
    } catch (_) {
      sb.add(config);
    }
  }
  sb.add('');
  return sb.join('\n');
}

// ------------------------------------------------------------ HTTP Injector

final _ehiL1Key = Uint8List.fromList([
  0x7e, 0x12, 0x10, 0xf7, 0xaa, 0xb9, 0x56, 0xf7, 0xa6, 0x68, 0xbd, 0xa6, //
  0xe5, 0x7f, 0xed, 0xdb, 0x7f, 0x84, 0xad, 0x84, 0x0a, 0xef, 0x8d, 0x27,
  0xb1, 0xb9, 0x69, 0x95, 0x9b, 0xe3, 0xab, 0x6c
]);
final _ehiL2Key = Uint8List.fromList([
  0xb2, 0xbc, 0x61, 0x7c, 0x32, 0xd8, 0xb9, 0xeb, 0x19, 0x43, 0xa5, 0xff, //
  0xa8, 0x05, 0x1e, 0xea
]);
final _ehiMasterKey = Uint8List.fromList(utf8.encode('null=V5kU5+FFrY') + [0]);
final _ehiIvs = <Uint8List>[
  _hex('221d572349555f1d112133236b1f4a3f'),
  _hex('5543494c53443e3f4a6a4539384e776a'),
  _hex('374c2541575e4d531a3c327b75431e5f'),
  _hex('2c5d1147bbad422b3b334d4d235f1a53'),
  _hex('522b01433a5e8b2fc7549e1ad368e541'),
  _hex('337a1035aaedf3458ca167e92d74b839'),
];
const _ehiCustomAlphabet =
    'RkLC2QaVMPYgGJW/A4f7qzDb9e+t6Hr0Zp8OlNyjuxKcTw1o5EIimhBn3UvdSFXs';
const _stdAlphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

String _pyStr(Object? v) {
  if (v == null) return '';
  if (v is bool) return v ? 'True' : 'False';
  if (v is double && v == v.truncateToDouble()) return '${v.toInt()}';
  return _s(v);
}

Uint8List _ehiMasterKeyFor(Map config) {
  const fields = [
    ('configAesKey', false),
    ('configIdentifier', false),
    ('configSalt', false),
    ('configTimestamp', true),
    ('configExpiryTimestamp', true),
    ('lockModes', false),
    ('lockModesHash', false),
    ('configHwid', false),
    ('configLockMobileOperatorId', false),
  ];
  final sb = StringBuffer();
  for (final (key, alwaysString) in fields) {
    final exists = config.containsKey(key);
    Object? val = config[key];
    if (alwaysString) {
      if (!exists) val = 0;
      sb.write(_pyStr(val));
      continue;
    }
    if (!exists) val = '';
    if (val != null && val != '' && val != false && !(val is num && val == 0)) {
      sb.write(_pyStr(val));
    }
  }
  return _sha256(utf8.encode(sb.toString()));
}

Uint8List _ehiCustomB64Decode(String encoded) {
  var clean = encoded.replaceAll('?', '');
  if (clean.length % 4 != 0) clean += '=' * (4 - clean.length % 4);
  final out = StringBuffer();
  for (final ch in clean.split('')) {
    final i = _ehiCustomAlphabet.indexOf(ch);
    out.write(i >= 0 ? _stdAlphabet[i] : ch);
  }
  return _b64Strict(out.toString());
}

String _ehiXorLayer(String ciphertext, String key) {
  if (ciphertext.trim().isEmpty) return ciphertext;
  final hexBytes =
      _ehiCustomB64Decode(String.fromCharCodes(ciphertext.codeUnits.reversed));
  var hexStr = _latin1(hexBytes).replaceAll(RegExp(r'\s'), '');
  if (hexStr.length.isOdd) hexStr = '0$hexStr';
  if (!RegExp(r'^[0-9a-fA-F]*$').hasMatch(hexStr)) {
    throw ConfigDecryptError('hex decode failed');
  }
  final raw = _hex(hexStr);
  final keyB = utf8.encode(key);
  final out = <int>[];
  for (var i = 0; i < raw.length; i++) {
    final x = raw[i] ^ keyB[i % keyB.length];
    if (x != 0) out.add(x);
  }
  if (out.isNotEmpty) {
    final bad = out.where((c) => c < 32 && c != 9 && c != 10 && c != 13).length;
    if (bad / out.length > 0.5)
      throw ConfigDecryptError('entropy check failed');
  }
  return _utf8(out);
}

String _ehiDecodeConfigMessage(String ciphertext) {
  if (ciphertext.trim().isEmpty) return ciphertext;
  var padded = ciphertext;
  if (padded.length % 4 != 0) padded += '=' * (4 - padded.length % 4);
  final Uint8List raw;
  try {
    raw = _b64Strict(padded);
  } on ConfigDecryptError {
    return ciphertext;
  }
  const keyChars = 'EHIMSG';
  final units = _utf8(raw).codeUnits;
  return String.fromCharCodes([
    for (var i = 0; i < units.length; i++) units[i] ^ keyChars.codeUnitAt(i % 6)
  ]);
}

Uint8List _xxteaDecrypt(Uint8List data, Uint8List key) {
  if (data.isEmpty) return Uint8List(0);
  if (data.length % 4 != 0) {
    data = Uint8List.fromList([...data, ...Uint8List(4 - data.length % 4)]);
  }
  const m = 0xFFFFFFFF;
  final pk = Uint8List(16)..setRange(0, key.length < 16 ? key.length : 16, key);
  final k = [for (var i = 0; i < 4; i++) _leU32(pk, i * 4)];
  final n = data.length ~/ 4;
  final v = [for (var i = 0; i < n; i++) _leU32(data, i * 4)];
  const delta = 0x9E3779B9;
  final rounds = 6 + 52 ~/ n;
  var total = (rounds * delta) & m;
  var y = v[0];
  while (total != 0) {
    final e = (total >> 2) & 3;
    for (var p = n - 1; p > 0; p--) {
      final z = v[p - 1];
      final mx = ((((z >> 5) ^ ((y << 2) & m)) + ((y >> 3) ^ ((z << 4) & m)))) ^
          ((total ^ y) + (k[(p & 3) ^ e] ^ z));
      v[p] = (v[p] - mx) & m;
      y = v[p];
    }
    final z = v[n - 1];
    final mx = ((((z >> 5) ^ ((y << 2) & m)) + ((y >> 3) ^ ((z << 4) & m)))) ^
        ((total ^ y) + (k[0 ^ e] ^ z));
    v[0] = (v[0] - mx) & m;
    y = v[0];
    total = (total - delta) & m;
  }
  final out = Uint8List(n * 4);
  for (var i = 0; i < n; i++) {
    out.buffer.asByteData().setUint32(i * 4, v[i], Endian.little);
  }
  final length = v[n - 1];
  if (length > 0 && length <= n * 4) return out.sublist(0, length);
  var end = out.length;
  while (end > 0 && out[end - 1] == 0) {
    end--;
  }
  return out.sublist(0, end);
}

int _leU32(Uint8List d, int o) =>
    d[o] | (d[o + 1] << 8) | (d[o + 2] << 16) | (d[o + 3] << 24);

Uint8List _ehiParseFile(Uint8List f) {
  var off = 0;
  void readUtf() {
    if (off + 2 > f.length) throw ConfigDecryptError('truncated readUTF');
    final l = _be(f, off, 2);
    off += 2;
    if (off + l > f.length) throw ConfigDecryptError('truncated readUTF body');
    off += l;
  }

  readUtf();
  off += 8;
  readUtf();
  off += 8;
  if (off + 4 > f.length) throw ConfigDecryptError('truncated payload length');
  final pLen = _be(f, off, 4);
  off += 4;
  off += 8;
  if (off + pLen > f.length) throw ConfigDecryptError('truncated payload');
  return f.sublist(off, off + pLen);
}

/// XChaCha20-Poly1305: HChaCha20 derives a subkey from the first 16 nonce bytes.
Uint8List _xchachaOpen(
    Uint8List key, Uint8List nonce24, Uint8List sealed, Uint8List aad) {
  final sub = _hchacha20(key, nonce24.sublist(0, 16));
  final nonce = Uint8List(12)..setRange(4, 12, nonce24, 16);
  return _chachaOpenOrThrow(sub, nonce, sealed, aad);
}

Uint8List _hchacha20(Uint8List key, Uint8List n16) {
  final s = Uint32List(16);
  s[0] = 0x61707865;
  s[1] = 0x3320646e;
  s[2] = 0x79622d32;
  s[3] = 0x6b206574;
  for (var i = 0; i < 8; i++) {
    s[4 + i] = _leU32(key, i * 4);
  }
  for (var i = 0; i < 4; i++) {
    s[12 + i] = _leU32(n16, i * 4);
  }
  int rotl(int v, int c) => ((v << c) | (v >> (32 - c))) & 0xFFFFFFFF;
  void qr(int a, int b, int c, int d) {
    s[a] = (s[a] + s[b]) & 0xFFFFFFFF;
    s[d] = rotl(s[d] ^ s[a], 16);
    s[c] = (s[c] + s[d]) & 0xFFFFFFFF;
    s[b] = rotl(s[b] ^ s[c], 12);
    s[a] = (s[a] + s[b]) & 0xFFFFFFFF;
    s[d] = rotl(s[d] ^ s[a], 8);
    s[c] = (s[c] + s[d]) & 0xFFFFFFFF;
    s[b] = rotl(s[b] ^ s[c], 7);
  }

  for (var i = 0; i < 10; i++) {
    qr(0, 4, 8, 12);
    qr(1, 5, 9, 13);
    qr(2, 6, 10, 14);
    qr(3, 7, 11, 15);
    qr(0, 5, 10, 15);
    qr(1, 6, 11, 12);
    qr(2, 7, 8, 13);
    qr(3, 4, 9, 14);
  }
  final out = Uint8List(32);
  final bd = out.buffer.asByteData();
  for (var i = 0; i < 4; i++) {
    bd.setUint32(i * 4, s[i], Endian.little);
    bd.setUint32(16 + i * 4, s[12 + i], Endian.little);
  }
  return out;
}

Map _ehiCleanInner(Map config, String saltKey) {
  final cleaned = <String, Object?>{};
  for (final e in config.entries) {
    final k = '${e.key}', v = e.value;
    if (v is! String || v.trim().isEmpty) {
      cleaned[k] = v;
      continue;
    }
    String decrypted;
    var err = false;
    if (k == 'configMessage') {
      decrypted = _ehiDecodeConfigMessage(v);
    } else {
      try {
        decrypted = _ehiXorLayer(v, saltKey);
      } on ConfigDecryptError {
        decrypted = '';
        err = true;
      }
    }
    cleaned[k] = !err && decrypted != '' ? decrypted : v;
  }
  return cleaned;
}

String decryptEhi(Uint8List file) {
  final payload = _ehiParseFile(file);
  if (payload.isEmpty) throw ConfigDecryptError('failed parsing EHI structure');
  Map? config;
  var isBypass = false;
  for (var idx = 0; idx < _ehiIvs.length; idx++) {
    try {
      final l1 =
          _unpadStrict(_aes(payload, _ehiL1Key, mode: 'cbc', iv: _ehiIvs[idx]));
      final parts = _latin1(l1).split(':');
      if (parts.length < 3) continue;
      final iv2 = _b64Strict(parts[0]);
      final garbageRaw = _b64Strict(parts[2]);
      final garbage =
          _unpadStrict(_aes(garbageRaw, _ehiL2Key, mode: 'cbc', iv: iv2));
      final finalRaw = _xxteaDecrypt(garbage, _ehiMasterKey);
      final start = finalRaw.indexOf(0x7b);
      if (start == -1) continue;
      final parsed = jsonDecode(utf8.decode(finalRaw.sublist(start)));
      if (parsed is! Map) continue;
      config = parsed;
      isBypass = idx < 3;
      break;
    } catch (_) {
      continue;
    }
  }
  if (config == null) {
    throw ConfigDecryptError(
        'decryption signature mismatch across standard matrix maps');
  }
  final saltRaw = config['configSalt'];
  final targetSalt =
      _t(saltRaw) ? (saltRaw is String ? saltRaw : _pyStr(saltRaw)) : 'EVZJNI';

  Map parsedFinal;
  if (isBypass) {
    parsedFinal = config;
  } else {
    final targetData =
        config['configData'] is String ? config['configData'] as String : '';
    final String aaa;
    try {
      aaa = _ehiXorLayer(targetData, targetSalt);
    } on ConfigDecryptError catch (e) {
      throw ConfigDecryptError('xor layer decryption failure: $e');
    }
    final raw = _b64Strict(aaa);
    if (raw.length <= 50) {
      throw ConfigDecryptError(
          'malformed secondary raw payload length parameters');
    }
    final timeCost = _leU32(raw, 1), memoryCost = _leU32(raw, 5);
    final parallelism = raw[9];
    final salt = raw.sublist(0x0A, 0x1A);
    final nonce = raw.sublist(0x1A, 0x32);
    final aad = raw.sublist(0, 0x1A);
    final argonKey = _argon2id(
        _ehiMasterKeyFor(config), salt, timeCost, memoryCost, parallelism, 32);
    final dec = _xchachaOpen(argonKey, nonce, raw.sublist(0x32), aad);
    try {
      parsedFinal = jsonDecode(utf8.decode(dec)) as Map;
    } catch (e) {
      throw ConfigDecryptError('inner json: $e');
    }
  }
  final cleaned = _ehiCleanInner(parsedFinal, targetSalt);
  for (final field in const ['v2rRawJson', 'overwriteServerData']) {
    final rawVal = cleaned[field];
    if (rawVal is String) {
      final s = rawVal.indexOf('{'), e = rawVal.lastIndexOf('}');
      if (s != -1 && e != -1 && e > s) {
        try {
          var parsed = jsonDecode(rawVal.substring(s, e + 1));
          if (parsed is String) {
            try {
              parsed = jsonDecode(parsed);
            } catch (_) {}
          }
          cleaned[field] = parsed;
        } catch (_) {}
      }
    }
  }
  return _goJson(cleaned, indent: '    ', sortKeys: true);
}

// ------------------------------------------------------------------- SlipNet

const _slipnetKeyHex =
    '214F052025B2F949605A5429EC3D5FA80C2022C168AD946E68852D447214DBD3';

String _slipnetProfile(String decrypted) {
  if (decrypted.endsWith('|'))
    decrypted = decrypted.substring(0, decrypted.length - 1);
  final parts = decrypted.split('|');
  if (parts.isEmpty || parts[0].isEmpty) return '[!] Empty decrypted text';
  final ver = parts[0];
  final schema = _slipSchemas[ver];
  final sb = <String>[
    '\n[+] Detected Profile Version: $ver',
    '${'FIELD'.padRight(30)} | VALUE',
    '-' * 80,
  ];
  for (var i = 0; i < parts.length; i++) {
    final value = parts[i];
    var label = schema != null && i < schema.length ? schema[i] : '';
    if (label.isEmpty) label = 'Field $i';
    var display = value.isEmpty ? '(empty)' : value;
    if (_slipLockedLabels.contains(label) &&
        (value == '' || value == '0' || value == '1')) {
      display =
          value == '1' ? '\u{1f512} YES / ✅ TRUE' : '\u{1f513} NO / ❌ FALSE';
    } else if (_slipTrueFalseLabels.contains(label) &&
        (value == '0' || value == '1')) {
      display = value == '1' ? '✅ TRUE' : '❌ FALSE';
    }
    sb.add('${label.padRight(30)} | $display');
  }
  return '${sb.join('\n')}\n';
}

/// slipnet-enc:// (fixed key) and slipnet:// (plain) links.
String decryptSlipLink(String proto, Uint8List payload) {
  final text = _utf8(payload).trim();
  final Uint8List data;
  try {
    data = _b64Strict(text);
  } on ConfigDecryptError catch (e) {
    throw ConfigDecryptError('base64 decode: $e');
  }
  if (proto == 'slipnet') return _slipnetProfile(_utf8(data));
  if (data.length < 13) throw ConfigDecryptError('blob too short');
  final plain = _gcmOpenOrThrow(
      _hex(_slipnetKeyHex), data.sublist(1, 13), data.sublist(13), null);
  return _slipnetProfile(_utf8(plain));
}
