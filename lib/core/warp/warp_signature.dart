import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// The signature of the WARP profile: ECDSA over P-256 with SHA-256. The public key is the 65 bytes
/// of the uncompressed point (base64), the private key the 32 bytes of the number (base64), the
/// signature the 64 bytes r || s (base64). The private key is kept offline by the maintainer; the
/// app only holds public keys, and a profile whose signature does not fit one of them is dropped.
final _curve = ECCurve_secp256r1();

BigInt _number(List<int> bytes) {
  var n = BigInt.zero;
  for (final b in bytes) {
    n = (n << 8) | BigInt.from(b);
  }
  return n;
}

Uint8List _bytes(BigInt n, int length) {
  final out = Uint8List(length);
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (n & BigInt.from(0xFF)).toInt();
    n >>= 8;
  }
  return out;
}

/// True when [signature] (base64) is [data]'s signature under [publicKey] (base64). Never throws.
bool verifyWarpSignature(List<int> data, String signature, String publicKey) {
  try {
    final sig = base64.decode(signature.trim());
    final key = base64.decode(publicKey.trim());
    if (sig.length != 64 || key.length != 65 || key[0] != 4) return false;
    final point = _curve.curve.decodePoint(key);
    if (point == null) return false;
    final signer = ECDSASigner(SHA256Digest())
      ..init(false, PublicKeyParameter<ECPublicKey>(ECPublicKey(point, _curve)));
    return signer.verifySignature(
        Uint8List.fromList(data), ECSignature(_number(sig.sublist(0, 32)), _number(sig.sublist(32))));
  } catch (_) {
    return false;
  }
}

/// A new key pair: (private, public), both base64.
(String, String) newWarpKeyPair() {
  final seed = Random.secure();
  final random = FortunaRandom()
    ..seed(KeyParameter(Uint8List.fromList([for (var i = 0; i < 32; i++) seed.nextInt(256)])));
  final generator = ECKeyGenerator()
    ..init(ParametersWithRandom(ECKeyGeneratorParameters(_curve), random));
  final pair = generator.generateKeyPair();
  final priv = pair.privateKey as ECPrivateKey;
  final pub = pair.publicKey as ECPublicKey;
  return (base64.encode(_bytes(priv.d!, 32)), base64.encode(pub.Q!.getEncoded(false)));
}

/// Signs [data] with [privateKey] (base64). The nonce is derived from the data (RFC 6979), so no
/// random numbers are needed and the same file always gets the same signature.
String signWarp(List<int> data, String privateKey) {
  final d = _number(base64.decode(privateKey.trim()));
  final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))
    ..init(true, PrivateKeyParameter<ECPrivateKey>(ECPrivateKey(d, _curve)));
  final sig = signer.generateSignature(Uint8List.fromList(data)) as ECSignature;
  return base64.encode([..._bytes(sig.r, 32), ..._bytes(sig.s, 32)]);
}
