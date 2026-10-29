import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// X25519 (RFC 7748), for the key pair of a WireGuard peer. Only used when a WARP account is made.
final _p = (BigInt.one << 255) - BigInt.from(19);
final _a24 = BigInt.from(121665);

BigInt _le(List<int> bytes) {
  var n = BigInt.zero;
  for (var i = bytes.length - 1; i >= 0; i--) {
    n = (n << 8) | BigInt.from(bytes[i]);
  }
  return n;
}

Uint8List _leBytes(BigInt n) {
  final out = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    out[i] = (n & BigInt.from(0xFF)).toInt();
    n >>= 8;
  }
  return out;
}

BigInt _inv(BigInt x) => x.modPow(_p - BigInt.two, _p);

/// [scalar] times the point [u] (both 32 bytes, as in the RFC).
Uint8List x25519(List<int> scalar, List<int> u) {
  final k = Uint8List.fromList(scalar);
  k[0] &= 248;
  k[31] &= 127;
  k[31] |= 64;
  final kn = _le(k);
  final x1 = _le(u) & ((BigInt.one << 255) - BigInt.one);
  var x2 = BigInt.one, z2 = BigInt.zero, x3 = x1, z3 = BigInt.one;
  var swap = false;
  for (var t = 254; t >= 0; t--) {
    final kt = ((kn >> t) & BigInt.one) == BigInt.one;
    if (swap != kt) {
      (x2, x3) = (x3, x2);
      (z2, z3) = (z3, z2);
    }
    swap = kt;
    final a = (x2 + z2) % _p;
    final aa = (a * a) % _p;
    final b = (x2 - z2) % _p;
    final bb = (b * b) % _p;
    final e = (aa - bb) % _p;
    final c = (x3 + z3) % _p;
    final d = (x3 - z3) % _p;
    final da = (d * a) % _p;
    final cb = (c * b) % _p;
    final s = (da + cb) % _p, df = (da - cb) % _p;
    x3 = (s * s) % _p;
    z3 = (x1 * ((df * df) % _p)) % _p;
    x2 = (aa * bb) % _p;
    z2 = (e * ((aa + _a24 * e) % _p)) % _p;
  }
  if (swap) {
    (x2, x3) = (x3, x2);
    (z2, z3) = (z3, z2);
  }
  return _leBytes((x2 * _inv(z2)) % _p);
}

/// A new WireGuard key pair: (private, public), both base64 as WireGuard writes them.
(String, String) newWireGuardKeys([Random? random]) {
  final r = random ?? Random.secure();
  final priv = Uint8List.fromList([for (var i = 0; i < 32; i++) r.nextInt(256)]);
  priv[0] &= 248;
  priv[31] &= 127;
  priv[31] |= 64;
  final base = Uint8List(32)..[0] = 9;
  return (base64.encode(priv), base64.encode(x25519(priv, base)));
}
