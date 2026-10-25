part of '../config_decryptor.dart';

// Helpers shared by the file-format decoders. They follow Python semantics
// (truthiness, str(), json.dumps, urllib.parse.quote) because the formats were
// specified against a Python reference.

/// Python truthiness.
bool _t(Object? v) {
  if (v == null || v == false) return false;
  if (v is num) return v != 0;
  if (v is String) return v.isNotEmpty;
  if (v is List) return v.isNotEmpty;
  if (v is Map) return v.isNotEmpty;
  return true;
}

Map _m(Object? v) => v is Map ? v : const {};

List _l(Object? v) => v is List ? v : const [];

/// Python `str(v)`.
String _s(Object? v) {
  if (v == null) return 'None';
  if (v is bool) return v ? 'True' : 'False';
  if (v is String) return v;
  if (v is num) return v.toString();
  return _goJson(v);
}

/// Python `d.get(k) or default` for strings.
String _str(Object? v) => v == null ? '' : (v is String ? v : _s(v));

/// json.dumps with Go's HTML escaping. Without [indent] it is json.Marshal:
/// compact and with sorted keys.
String _goJson(Object? v, {String? indent, bool sortKeys = false}) {
  final out = StringBuffer();
  void write(Object? x, int depth) {
    if (x == null) {
      out.write('null');
    } else if (x is bool) {
      out.write(x ? 'true' : 'false');
    } else if (x is num) {
      out.write(x.toString());
    } else if (x is String) {
      out.write(jsonEncode(x));
    } else if (x is List) {
      if (x.isEmpty) {
        out.write('[]');
        return;
      }
      out.write('[');
      for (var i = 0; i < x.length; i++) {
        if (i > 0) out.write(',');
        if (indent != null)
          out
            ..write('\n')
            ..write(indent * (depth + 1));
        write(x[i], depth + 1);
      }
      if (indent != null)
        out
          ..write('\n')
          ..write(indent * depth);
      out.write(']');
    } else if (x is Map) {
      if (x.isEmpty) {
        out.write('{}');
        return;
      }
      final keys = x.keys.map((k) => '$k').toList();
      if (indent == null || sortKeys) keys.sort();
      out.write('{');
      for (var i = 0; i < keys.length; i++) {
        if (i > 0) out.write(',');
        if (indent != null)
          out
            ..write('\n')
            ..write(indent * (depth + 1));
        out
          ..write(jsonEncode(keys[i]))
          ..write(indent == null ? ':' : ': ');
        write(x[keys[i]], depth + 1);
      }
      if (indent != null)
        out
          ..write('\n')
          ..write(indent * depth);
      out.write('}');
    } else {
      out.write(jsonEncode('$x'));
    }
  }

  write(v, 0);
  return out
      .toString()
      .replaceAll('<', '\\u003c')
      .replaceAll('>', '\\u003e')
      .replaceAll('&', '\\u0026');
}

/// Go json.Indent: reformat, or null when [raw] is not JSON.
String? _goIndent(Uint8List raw, [String indent = '    ']) {
  try {
    return _goJson(jsonDecode(utf8.decode(raw)), indent: indent);
  } catch (_) {
    return null;
  }
}

const _unreserved =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-~';

/// urllib.parse.quote(s, safe=[safe]).
String _quote(String s, [String safe = '']) {
  final out = StringBuffer();
  for (final b in utf8.encode(s)) {
    final c = String.fromCharCode(b);
    if (b < 128 && (_unreserved.contains(c) || safe.contains(c))) {
      out.write(c);
    } else {
      out
        ..write('%')
        ..write(b.toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
  }
  return out.toString();
}

String _quotePlus(String s) => _quote(s).replaceAll('%20', '+');

/// urlencode(sorted(q.items()), quote_via=quote_plus).
String _queryEncode(Map<String, dynamic> q) {
  final keys = q.keys.toList()..sort();
  return keys.map((k) => '${_quotePlus(k)}=${_quotePlus(_s(q[k]))}').join('&');
}

/// Go url.PathEscape.
String _pathEscape(String s) => _quote(s, r'$&+:=@');

/// Go url.Userinfo escaping.
String _userinfoEscape(String s) => _quote(s, r'$&+,;=');

String _joinHostPort(String addr, Object? port) {
  addr = addr.replaceAll(RegExp(r'^[\[\]]+|[\[\]]+$'), '');
  final p = _s(port);
  return addr.contains(':') ? '[$addr]:$p' : '$addr:$p';
}

String _b64Std(String s) => base64.encode(utf8.encode(s));

Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// Strict standard base64 (padding required, no stray characters).
Uint8List _b64Strict(String s) {
  if (s.length % 4 != 0 || !RegExp(r'^[A-Za-z0-9+/]*={0,2}$').hasMatch(s)) {
    throw ConfigDecryptError('invalid base64');
  }
  return base64.decode(s);
}

Uint8List _concat(List<List<int>> parts) {
  final out = BytesBuilder(copy: false);
  for (final p in parts) {
    out.add(p);
  }
  return out.toBytes();
}

Uint8List _sha256(List<int> data) =>
    SHA256Digest().process(Uint8List.fromList(data));

Uint8List _hmacSha256(List<int> key, List<int> data) {
  final h = HMac(SHA256Digest(), 64)
    ..init(KeyParameter(Uint8List.fromList(key)));
  return h.process(Uint8List.fromList(data));
}

int _be(Uint8List d, int o, int n) {
  var v = 0;
  for (var i = 0; i < n; i++) {
    v = (v << 8) | d[o + i];
  }
  return v;
}

Uint8List _be32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v);

Uint8List _be16(int v) => Uint8List(2)..buffer.asByteData().setUint16(0, v);

/// AES with a raw mode: 'ecb', 'cbc' or 'cfb'.
Uint8List _aes(Uint8List data, Uint8List key,
    {String mode = 'ecb', Uint8List? iv}) {
  BlockCipher engine = AESEngine();
  if (mode == 'cbc') {
    final c = CBCBlockCipher(engine)
      ..init(false, ParametersWithIV(KeyParameter(key), iv!));
    return _blocks(c, data);
  }
  if (mode == 'cfb') {
    final c = CFBBlockCipher(engine, 16)
      ..init(false, ParametersWithIV(KeyParameter(key), iv!));
    final out = Uint8List(data.length);
    var o = 0;
    while (o < data.length) {
      final n = o + 16 <= data.length ? 16 : data.length - o;
      if (n == 16) {
        c.processBlock(data, o, out, o);
      } else {
        // CFB is a stream mode: pad the last block, keep the used part
        final pad = Uint8List(16)..setRange(0, n, data, o);
        final tmp = Uint8List(16);
        c.processBlock(pad, 0, tmp, 0);
        out.setRange(o, o + n, tmp);
      }
      o += n;
    }
    return out;
  }
  engine.init(false, KeyParameter(key));
  return _blocks(engine, data);
}

Uint8List _blocks(BlockCipher c, Uint8List data) {
  if (data.length % 16 != 0) {
    throw ConfigDecryptError('ciphertext length is not a multiple of 16');
  }
  final out = Uint8List(data.length);
  for (var o = 0; o < data.length; o += 16) {
    c.processBlock(data, o, out, o);
  }
  return out;
}

/// PKCS#7 removal that throws when the padding is wrong.
Uint8List _unpadStrict(Uint8List d, [int block = 16]) {
  if (d.isEmpty || d.length % block != 0) {
    throw ConfigDecryptError('data length is not a multiple of block size');
  }
  final pad = d.last;
  if (pad < 1 || pad > block)
    throw ConfigDecryptError('invalid padding length $pad');
  for (var i = d.length - pad; i < d.length; i++) {
    if (d[i] != pad) throw ConfigDecryptError('invalid padding bytes');
  }
  return d.sublist(0, d.length - pad);
}

Uint8List _argon2id(List<int> secret, List<int> salt, int time, int memory,
    int parallelism, int hashLen) {
  final gen = Argon2BytesGenerator()
    ..init(Argon2Parameters(
        Argon2Parameters.ARGON2_id, Uint8List.fromList(salt),
        desiredKeyLength: hashLen,
        iterations: time,
        memory: memory,
        lanes: parallelism,
        version: Argon2Parameters.ARGON2_VERSION_13));
  final out = Uint8List(hashLen);
  gen.deriveKey(Uint8List.fromList(secret), 0, out, 0);
  return out;
}

Uint8List _chachaOpenOrThrow(
    Uint8List key, Uint8List nonce, Uint8List sealed, Uint8List? aad) {
  try {
    return _chachaOpen(key, nonce, sealed, aad ?? Uint8List(0));
  } on InvalidCipherTextException {
    throw ConfigDecryptError('chacha20poly1305 open failed');
  }
}

Uint8List _gcmOpenOrThrow(
    Uint8List key, Uint8List nonce, Uint8List sealed, Uint8List? aad) {
  try {
    return _aesGcmOpen(key, nonce, sealed, aad);
  } on InvalidCipherTextException {
    throw ConfigDecryptError('aes-gcm open failed');
  }
}

String _utf8(List<int> b) => utf8.decode(b, allowMalformed: true);

/// Python `bytes.strip()` on ASCII whitespace.
Uint8List _stripBytes(Uint8List b) {
  bool ws(int c) => c == 32 || (c >= 9 && c <= 13);
  var a = 0, z = b.length;
  while (a < z && ws(b[a])) {
    a++;
  }
  while (z > a && ws(b[z - 1])) {
    z--;
  }
  return b.sublist(a, z);
}
