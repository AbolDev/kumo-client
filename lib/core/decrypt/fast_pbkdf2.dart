import 'dart:typed_data';

/// PBKDF2 with HMAC-SHA-256, written for speed: the two halves of the key's padding are hashed once, so
/// every round costs two compressions of the hash instead of four, and nothing is allocated in the loop.
/// A password-locked export asks for hundreds of thousands of rounds, which used to take seconds.
Uint8List pbkdf2Sha256(List<int> password, List<int> salt, int iterations, int length) {
  if (iterations < 1) throw ArgumentError('iterations');
  var key = password;
  if (key.length > 64) key = _sha256(key);
  final ipad = Uint8List(64), opad = Uint8List(64);
  for (var i = 0; i < 64; i++) {
    final k = i < key.length ? key[i] : 0;
    ipad[i] = k ^ 0x36;
    opad[i] = k ^ 0x5c;
  }
  final inner = Uint32List.fromList(_iv), outer = Uint32List.fromList(_iv);
  final w = Uint32List(64);
  _load(w, ipad, 0);
  _compress(inner, w);
  _load(w, opad, 0);
  _compress(outer, w);

  final out = BytesBuilder();
  final u = Uint32List(8), t = Uint32List(8), a = Uint32List(8);
  for (var block = 1; out.length < length; block++) {
    // U1 = HMAC(password, salt || INT(block))
    final message = Uint8List.fromList([...salt, block >> 24, block >> 16, block >> 8, block]);
    a.setAll(0, inner);
    _finish(a, message, 64 + message.length, w);
    // the outer hash of a 32-byte digest is one block: digest, 0x80, zeros, 768 bits
    _digestRound(outer, a, w, u);
    t.setAll(0, u);
    for (var n = 1; n < iterations; n++) {
      _digestRound(inner, u, w, a);
      _digestRound(outer, a, w, u);
      for (var i = 0; i < 8; i++) {
        t[i] ^= u[i];
      }
    }
    for (final word in t) {
      out.add([word >> 24, word >> 16, word >> 8, word]);
    }
  }
  return Uint8List.fromList(out.toBytes().sublist(0, length));
}

/// The hash of a 32-byte value (as 8 words) that follows a 64-byte block already hashed into [from].
void _digestRound(Uint32List from, Uint32List value, Uint32List w, Uint32List into) {
  for (var i = 0; i < 8; i++) {
    w[i] = value[i];
  }
  w[8] = 0x80000000;
  for (var i = 9; i < 15; i++) {
    w[i] = 0;
  }
  w[15] = 768;
  into.setAll(0, from);
  _compress(into, w);
}

/// Hashes the last part of a message ([tail]) on top of [state]; [total] is the length of the whole
/// message in bytes, which goes into the padding.
void _finish(Uint32List state, Uint8List tail, int total, Uint32List w) {
  final padded = (tail.length + 9 + 63) ~/ 64 * 64;
  final data = Uint8List(padded)..setAll(0, tail);
  data[tail.length] = 0x80;
  final bits = total * 8;
  for (var i = 0; i < 8; i++) {
    data[padded - 1 - i] = (bits >> (8 * i)) & 0xff;
  }
  for (var off = 0; off < padded; off += 64) {
    _load(w, data, off);
    _compress(state, w);
  }
}

Uint8List _sha256(List<int> message) {
  final state = Uint32List.fromList(_iv);
  final w = Uint32List(64);
  final whole = message.length ~/ 64 * 64;
  final bytes = Uint8List.fromList(message);
  for (var off = 0; off < whole; off += 64) {
    _load(w, bytes, off);
    _compress(state, w);
  }
  _finish(state, bytes.sublist(whole), message.length, w);
  final out = Uint8List(32);
  for (var i = 0; i < 8; i++) {
    out[4 * i] = state[i] >> 24;
    out[4 * i + 1] = state[i] >> 16;
    out[4 * i + 2] = state[i] >> 8;
    out[4 * i + 3] = state[i];
  }
  return out;
}

void _load(Uint32List w, Uint8List data, int off) {
  for (var i = 0; i < 16; i++) {
    final p = off + 4 * i;
    w[i] = (data[p] << 24) | (data[p + 1] << 16) | (data[p + 2] << 8) | data[p + 3];
  }
}

const _m = 0xFFFFFFFF;

void _compress(Uint32List state, Uint32List w) {
  for (var i = 16; i < 64; i++) {
    final w15 = w[i - 15], w2 = w[i - 2];
    final s0 = (((w15 >>> 7) | (w15 << 25)) ^ ((w15 >>> 18) | (w15 << 14)) ^ (w15 >>> 3)) & _m;
    final s1 = (((w2 >>> 17) | (w2 << 15)) ^ ((w2 >>> 19) | (w2 << 13)) ^ (w2 >>> 10)) & _m;
    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
  }
  var a = state[0], b = state[1], c = state[2], d = state[3];
  var e = state[4], f = state[5], g = state[6], h = state[7];
  for (var i = 0; i < 64; i++) {
    final s1 = (((e >>> 6) | (e << 26)) ^ ((e >>> 11) | (e << 21)) ^ ((e >>> 25) | (e << 7))) & _m;
    final ch = (e & f) ^ (~e & g);
    final t1 = h + s1 + ch + _k[i] + w[i];
    final s0 = (((a >>> 2) | (a << 30)) ^ ((a >>> 13) | (a << 19)) ^ ((a >>> 22) | (a << 10))) & _m;
    final maj = (a & b) ^ (a & c) ^ (b & c);
    final t2 = s0 + maj;
    h = g;
    g = f;
    f = e;
    e = (d + t1) & _m;
    d = c;
    c = b;
    b = a;
    a = (t1 + t2) & _m;
  }
  state[0] += a;
  state[1] += b;
  state[2] += c;
  state[3] += d;
  state[4] += e;
  state[5] += f;
  state[6] += g;
  state[7] += h;
}

const _iv = [
  0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19, //
];

final _k = Uint32List.fromList(const [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, //
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, //
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, //
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, //
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, //
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, //
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, //
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2, //
]);
