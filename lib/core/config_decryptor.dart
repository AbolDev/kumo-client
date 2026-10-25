import 'dart:convert';
import 'dart:io' show gzip, zlib;
import 'dart:typed_data';

import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';

part 'decrypt/constants.dart';
part 'decrypt/formats.dart';
part 'decrypt/gen2.dart';
part 'decrypt/npvt.dart';
part 'decrypt/util.dart';

/// Opens exported config files of the common tunnel apps: SlipNet, NPV Tunnel
/// (.npvs, .npvt), HA Tunnel (.hat), NetMod (.nm), Happ, DarkTunnel (.dark),
/// TLS Tunnel (.tls), ZedSecure (.zsx), sing-box (.bpf) and HTTP Injector (.ehi).
class ConfigDecryptError implements Exception {
  ConfigDecryptError(this.message);
  final String message;
  @override
  String toString() => message;
}

enum ProtectKind { password, noPassword, unsupported }

/// The lookup tables the formats need: the white-box tables of the NPV exports, the
/// second-generation NPV tables (zlib) and the Happ crypt5 key list (JSON).
class NpvTables {
  NpvTables(this.ty, this.mbl, this.tlast1, this.tlast2, this.xor,
      {this.gen2Z, this.crypt5Json});
  final Uint8List ty, mbl, tlast1, tlast2, xor;
  final Uint8List? gen2Z, crypt5Json;
}

const _slipBundleMarker = 'slipnet-bundle-enc://';
const _npvsPassKdf = 'pbkdf2-hmac-sha256';
const _npvsAppKdf = 'wbaes-ctr-sha256';
const _npvsWrapSize = 60;
const _npvsSaltSize = 16;
const _npvsSentinel = 'npvs1:';
const _npvsSentinelChars =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=_-';

enum _Format { slip, npvs, npvt, hat, nm, happ, dark, tls, zsx, bpf, ehi }

const _extensions = {
  '.slip': _Format.slip,
  '.npvs': _Format.npvs,
  '.npvt': _Format.npvt,
  '.hat': _Format.hat,
  '.nm': _Format.nm,
  '.happ': _Format.happ,
  '.dark': _Format.dark,
  '.tls': _Format.tls,
  '.zsx': _Format.zsx,
  '.bpf': _Format.bpf,
  '.ehi': _Format.ehi,
};

/// "proto://payload" -> (proto, payload); anything else -> ('', all of it).
(String, Uint8List) _splitContent(Uint8List content) {
  var start = 0;
  bool space(int c) => c == 32 || (c >= 9 && c <= 13);
  while (start < content.length && space(content[start])) {
    start++;
  }
  for (var i = start; i < content.length; i++) {
    final c = content[i];
    if (c == 0x3a) {
      if (i > start &&
          i + 2 < content.length &&
          content[i + 1] == 0x2f &&
          content[i + 2] == 0x2f) {
        return (
          latin1.decode(content.sublist(start, i)),
          content.sublist(i + 3)
        );
      }
      return ('', content);
    }
    final ok = (c >= 0x61 && c <= 0x7a) ||
        (c >= 0x41 && c <= 0x5a) ||
        (c >= 0x30 && c <= 0x39) ||
        c == 0x2b ||
        c == 0x2d ||
        c == 0x2e;
    if (!ok) return ('', content);
  }
  return ('', content);
}

_Format? _detect(Uint8List data, String fileName) {
  final name = fileName.toLowerCase();
  final dot = name.lastIndexOf('.');
  final byName = dot >= 0 ? _extensions[name.substring(dot)] : null;
  if (byName != null) return byName;
  final (proto, _) =
      _splitContent(data.length > 4096 ? data.sublist(0, 4096) : data);
  if (proto == 'slipnet-enc' ||
      proto == 'slipnet' ||
      proto == 'slipnet-bundle-enc') {
    return _Format.slip;
  }
  if (proto == 'NPVT1') return _Format.npvt;
  if (proto == 'NPVS') return _Format.npvs;
  if (proto.startsWith('nm-')) return _Format.nm;
  if (proto == 'happ') return _Format.happ;
  if (proto == 'darktunnel') return _Format.dark;
  if (proto == 'zedsecure') return _Format.zsx;
  if (proto == 'bpf') return _Format.bpf;
  if (_isOpenEnvelope(data)) return _Format.npvs;
  return null;
}

/// Whether [fileName] or the start of [data] looks like one of the protected formats.
bool isProtectedFile(String fileName, [Uint8List? data]) {
  final name = fileName.toLowerCase();
  final dot = name.lastIndexOf('.');
  if (dot >= 0 && _extensions.containsKey(name.substring(dot))) return true;
  return data != null && _detect(data, fileName) != null;
}

/// Says whether opening the file needs a password from the user.
ProtectKind inspectProtected(Uint8List data, String fileName) {
  final format = _detect(data, fileName);
  switch (format) {
    case null:
      return ProtectKind.unsupported;
    case _Format.slip:
      final (proto, _) = _splitContent(data);
      return proto == 'slipnet-bundle-enc'
          ? ProtectKind.password
          : ProtectKind.noPassword;
    case _Format.npvs:
      if (_isOpenEnvelope(data)) return ProtectKind.noPassword;
      final gen2 = _gen2NeedsPassphrase(data);
      if (gen2 != null) {
        return gen2 ? ProtectKind.password : ProtectKind.noPassword;
      }
      try {
        final header = _npvsHeader(data).$1;
        if (header['appKey'] != null) return ProtectKind.noPassword;
        if (header['passphrase'] != null) return ProtectKind.password;
      } on ConfigDecryptError {
        // fall through
      }
      return ProtectKind.unsupported;
    case _Format.zsx:
      return _zsxMode(data) == 1
          ? ProtectKind.password
          : ProtectKind.noPassword;
    default:
      return ProtectKind.noPassword;
  }
}

/// Decrypts any supported file to text: share links, one per line (plus comment lines).
String decryptProtected(Uint8List data, String fileName, String password,
    {NpvTables? tables}) {
  final format = _detect(data, fileName);
  if (format == null) throw ConfigDecryptError('Unsupported file type');
  try {
    return _withLinks(_decryptFormat(format, data, fileName, password, tables));
  } on ConfigDecryptError {
    rethrow;
  } on InvalidCipherTextException {
    throw ConfigDecryptError('Wrong password or damaged file');
  } catch (e) {
    throw ConfigDecryptError('Could not open this file ($e)');
  }
}

String _decryptFormat(_Format format, Uint8List data, String fileName,
    String password, NpvTables? tables) {
  final (proto, payload) = _splitContent(data);
  NpvTables need() {
    if (tables == null) throw ConfigDecryptError('Missing tables');
    return tables;
  }

  switch (format) {
    case _Format.slip:
      if (proto == 'slipnet-enc' || proto == 'slipnet') {
        return decryptSlipLink(proto, payload);
      }
      return decryptSlipBundle(data, password);
    case _Format.npvs:
      if (_isOpenEnvelope(data)) return decryptNpvsOpen(data);
      if (_isGen2Envelope(data)) return decryptNpvsGen2(data, password, need());
      return decryptNpvs(data, password, tables: tables);
    case _Format.npvt:
      return decryptNpvt(data, need());
    case _Format.hat:
      return decryptHat(payload);
    case _Format.nm:
      return decryptNetmod(payload, proto);
    case _Format.happ:
      return decryptHapp(payload, need());
    case _Format.dark:
      return decryptDark(payload);
    case _Format.tls:
      return decryptTls(data);
    case _Format.zsx:
      return decryptZsx(data, password);
    case _Format.bpf:
      return decryptBpf(data, fileName);
    case _Format.ehi:
      return decryptEhi(data);
  }
}

/// Share links for the servers in an Xray / V2Ray JSON document (one config or a list).
List<String> xrayJsonToLinks(Object? json) {
  final uris = <String>[];
  try {
    _npvtWalkJson(json, uris);
  } catch (_) {
    // unreadable parts are skipped
  }
  return uris;
}

/// Configs stored as xray JSON are turned into share links, which are added below.
String _withLinks(String text) {
  final body = text
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n')
      .trim();
  if (!body.startsWith('{') && !body.startsWith('[')) return text;
  final uris = <String>[];
  try {
    _npvtWalkJson(jsonDecode(body), uris);
  } catch (_) {
    return text;
  }
  return uris.isEmpty ? text : '$text\n${uris.join('\n')}';
}

String decryptSlipBundle(Uint8List data, String password) {
  var text = utf8.decode(data, allowMalformed: true).trim();
  if (!text.startsWith(_slipBundleMarker)) {
    throw ConfigDecryptError('Not a password-protected SlipNet bundle');
  }
  text = text.substring(_slipBundleMarker.length).replaceAll(RegExp(r'\s'), '');
  final Uint8List blob;
  try {
    blob = base64.decode(base64.normalize(text));
  } on FormatException {
    throw ConfigDecryptError('Invalid base64 data');
  }
  const saltLen = 16, ivLen = 12, tagLen = 16;
  if (blob.length < 1 + saltLen + ivLen + tagLen) {
    throw ConfigDecryptError('The bundle is truncated');
  }
  if (blob[0] != 0x01) {
    throw ConfigDecryptError('Unsupported bundle version');
  }
  final salt = blob.sublist(1, 1 + saltLen);
  final iv = blob.sublist(1 + saltLen, 1 + saltLen + ivLen);
  final sealed = blob.sublist(1 + saltLen + ivLen);
  final key = _pbkdf2(password, salt, 600000);
  try {
    return utf8.decode(_aesGcmOpen(key, iv, sealed, null),
        allowMalformed: true);
  } on InvalidCipherTextException {
    throw ConfigDecryptError('Wrong password or damaged file');
  }
}

(Map<String, dynamic>, Uint8List, int) _npvsHeader(Uint8List data) {
  if (data.length < 89 ||
      utf8.decode(data.sublist(0, 4), allowMalformed: true) != 'NPVS') {
    throw ConfigDecryptError('Not a supported NPV export');
  }
  final headerLen = _u32(data, 5);
  if (9 + headerLen + 16 > data.length) {
    throw ConfigDecryptError('Invalid header');
  }
  final raw = data.sublist(9, 9 + headerLen);
  final Object? header;
  try {
    header = jsonDecode(utf8.decode(raw));
  } on FormatException {
    throw ConfigDecryptError('Unsupported NPV export version');
  }
  if (header is! Map) throw ConfigDecryptError('Invalid header');
  return (header.cast<String, dynamic>(), raw, 9 + headerLen);
}

String decryptNpvs(Uint8List data, String password, {NpvTables? tables}) {
  final (header, headerRaw, bodyStart) = _npvsHeader(data);

  final Uint8List dek;
  final app = header['appKey'];
  final pass = header['passphrase'];
  if (app is Map) {
    if (tables == null) throw ConfigDecryptError('Missing tables');
    dek = _unwrapAppKey(app, tables);
  } else if (pass is Map) {
    dek = _unwrapPassphrase(pass, password);
  } else {
    throw ConfigDecryptError('This NPV export type is not supported');
  }

  var off = bodyStart;
  final nonce = data.sublist(off, off + 12);
  final bodyLen = _u32(data, off + 12);
  off += 16;
  if (bodyLen < 16 || off + bodyLen > data.length) {
    throw ConfigDecryptError('Invalid body');
  }
  final Uint8List plain;
  try {
    plain =
        _chachaOpen(dek, nonce, data.sublist(off, off + bodyLen), headerRaw);
  } on InvalidCipherTextException {
    throw ConfigDecryptError('The file is damaged');
  }
  return _decodeSentinels(utf8.decode(plain, allowMalformed: true));
}

Uint8List _unwrapPassphrase(Map pass, String password) {
  if (pass['kdf'] != _npvsPassKdf) throw ConfigDecryptError('Unsupported KDF');
  final iters = pass['iters'];
  if (iters is! int || iters < 1 || iters > 10000000) {
    throw ConfigDecryptError('Invalid iteration count');
  }
  final salt = _b64Url('${pass['salt'] ?? ''}');
  final wrap = _b64Url('${pass['wrap'] ?? ''}');
  if (wrap.length != _npvsWrapSize)
    throw ConfigDecryptError('Invalid key data');
  try {
    return _chachaOpen(_pbkdf2(password, salt, iters), wrap.sublist(0, 12),
        wrap.sublist(12), salt);
  } on InvalidCipherTextException {
    throw ConfigDecryptError('Wrong passphrase');
  }
}

Uint8List _unwrapAppKey(Map app, NpvTables tables) {
  if (app['kdf'] != _npvsAppKdf || app['keyId'] != 1) {
    throw ConfigDecryptError('This NPV export type is not supported');
  }
  final salt = _b64Url('${app['salt'] ?? ''}');
  final wrap = _b64Url('${app['wrap'] ?? ''}');
  if (salt.length != _npvsSaltSize || wrap.length != _npvsWrapSize) {
    throw ConfigDecryptError('Invalid key data');
  }
  final wb = _WhiteBox(tables);
  for (final tlast in [wb.tlast1, wb.tlast2]) {
    final stream = wb.ctr(salt.sublist(0, 16), Uint8List(16), tlast);
    final kdk = SHA256Digest().process(Uint8List.fromList(
        [...utf8.encode('npvtunnel/appkey/v1 '), ...stream]));
    try {
      return _chachaOpen(kdk, wrap.sublist(0, 12), wrap.sublist(12), salt);
    } on InvalidCipherTextException {
      continue;
    }
  }
  throw ConfigDecryptError('Could not open this NPV export');
}

/// Table-based AES-CTR keystream used by NPV exports that have no passphrase.
class _WhiteBox {
  _WhiteBox(NpvTables t)
      : xor = t.xor,
        ty = _words(t.ty),
        mbl = _words(t.mbl),
        tlast1 = t.tlast1,
        tlast2 = t.tlast2;

  final Uint8List xor, tlast1, tlast2;
  final List<Uint32List> ty, mbl;

  static const _shift = [0, 5, 10, 15, 4, 9, 14, 3, 8, 13, 2, 7, 12, 1, 6, 11];

  static List<Uint32List> _words(Uint8List b) {
    final view = ByteData.sublistView(b);
    return [
      for (var i = 0; i < 16; i++)
        Uint32List.fromList(
            [for (var j = 0; j < 256; j++) view.getUint32(i * 1024 + j * 4)])
    ];
  }

  int _x(int t, int a, int b) => xor[(t << 8) + (a << 4) + b];

  int _mix(int grp, int k, int a, int b, int c, int d) {
    final t = grp * 24 + k * 6;
    final hi = 28 - 8 * k, lo = 24 - 8 * k;
    final p1 = _x(t, (a >> hi) & 15, (b >> hi) & 15);
    final p2 = _x(t + 1, (c >> hi) & 15, (d >> hi) & 15);
    final p3 = _x(t + 2, (a >> lo) & 15, (b >> lo) & 15);
    final p4 = _x(t + 3, (c >> lo) & 15, (d >> lo) & 15);
    return (_x(t + 4, p1, p2) << 4) | _x(t + 5, p3, p4);
  }

  void _row(Uint8List s, int base, List<Uint32List> tab, int grp) {
    final a = tab[base][s[base]];
    final b = tab[base + 1][s[base + 1]];
    final c = tab[base + 2][s[base + 2]];
    final d = tab[base + 3][s[base + 3]];
    for (var k = 0; k < 4; k++) {
      s[base + k] = _mix(grp, k, a, b, c, d);
    }
  }

  Uint8List _block(Uint8List input, Uint8List tlast) {
    var s = Uint8List.fromList([for (final i in _shift) input[i]]);
    for (var grp = 0; grp < 4; grp++) {
      _row(s, grp * 4, ty, grp);
      _row(s, grp * 4, mbl, grp);
    }
    s = Uint8List.fromList([for (final i in _shift) s[i]]);
    return Uint8List.fromList(
        [for (var i = 0; i < 16; i++) tlast[i * 256 + s[i]]]);
  }

  Uint8List ctr(Uint8List nonce, Uint8List data, Uint8List tlast) {
    final counter = Uint8List.fromList(nonce.sublist(0, 16));
    final out = Uint8List(data.length);
    for (var i = 0; i < data.length; i += 16) {
      final ks = _block(counter, tlast);
      for (var j = 0; j < 16 && i + j < data.length; j++) {
        out[i + j] = data[i + j] ^ ks[j];
      }
      for (var p = 15; p >= 0; p--) {
        counter[p] = (counter[p] + 1) & 0xFF;
        if (counter[p] != 0) break;
      }
    }
    return out;
  }
}

String _decodeSentinels(String s) {
  final out = StringBuffer();
  while (true) {
    final i = s.indexOf(_npvsSentinel);
    if (i < 0) {
      out.write(s);
      return out.toString();
    }
    out.write(s.substring(0, i));
    s = s.substring(i + _npvsSentinel.length);
    var j = 0;
    while (j < s.length && _npvsSentinelChars.contains(s[j])) {
      j++;
    }
    final token = s.substring(0, j);
    s = s.substring(j);
    try {
      out.write(utf8.decode(_b64Url(token), allowMalformed: true));
    } on FormatException {
      out
        ..write(_npvsSentinel)
        ..write(token);
    }
  }
}

Uint8List _pbkdf2(String password, Uint8List salt, int iterations) {
  final kdf = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(salt, iterations, 32));
  return kdf.process(Uint8List.fromList(utf8.encode(password)));
}

Uint8List _aesGcmOpen(
    Uint8List key, Uint8List iv, Uint8List sealed, Uint8List? aad) {
  final cipher = GCMBlockCipher(AESEngine())
    ..init(
        false, AEADParameters(KeyParameter(key), 128, iv, aad ?? Uint8List(0)));
  return cipher.process(sealed);
}

Uint8List _chachaOpen(
    Uint8List key, Uint8List nonce, Uint8List sealed, Uint8List aad) {
  final cipher = ChaCha20Poly1305(ChaCha7539Engine(), Poly1305())
    ..init(false, AEADParameters(KeyParameter(key), 128, nonce, aad));
  try {
    final out = Uint8List(cipher.getOutputSize(sealed.length));
    var n = cipher.processBytes(sealed, 0, sealed.length, out, 0);
    n += cipher.doFinal(out, n);
    return out.sublist(0, n);
  } on ArgumentError {
    throw InvalidCipherTextException('mac check failed');
  }
}

Uint8List _b64Url(String s) {
  final t = s.replaceAll('-', '+').replaceAll('_', '/').replaceAll('=', '');
  return base64.decode(base64.normalize(t));
}

int _u32(Uint8List d, int o) =>
    (d[o] << 24) | (d[o + 1] << 16) | (d[o + 2] << 8) | d[o + 3];
