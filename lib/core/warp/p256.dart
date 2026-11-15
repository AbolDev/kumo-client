import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// A P-256 (secp256r1) key pair for a WARP account that uses MASQUE: Cloudflare takes the public key as
/// the DER of a SubjectPublicKeyInfo, and Xray takes the private key as the DER of a SEC1 ECPrivateKey
/// (in base64). Only used when such an account is made.
class P256Keys {
  const P256Keys(this.privateSec1, this.publicSpki);

  /// DER of an ECPrivateKey (RFC 5915) with the public key inside.
  final Uint8List privateSec1;

  /// DER of a SubjectPublicKeyInfo (the form Cloudflare's sign-up takes).
  final Uint8List publicSpki;

  String get privateBase64 => base64.encode(privateSec1);
  String get publicBase64 => base64.encode(publicSpki);
}

// SEQUENCE { SEQUENCE { id-ecPublicKey, prime256v1 }, BIT STRING (0, then the 65 bytes of the point) }
const _spkiPrefix = [
  0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, //
  0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
];

// SEQUENCE { version 1, OCTET STRING (32), [0] prime256v1, [1] BIT STRING (point) }
const _sec1Prefix = [0x30, 0x77, 0x02, 0x01, 0x01, 0x04, 0x20];
const _sec1Curve = [0xa0, 0x0a, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07];
const _sec1Point = [0xa1, 0x44, 0x03, 0x42, 0x00];

Uint8List _fixed32(BigInt n) {
  final out = Uint8List(32);
  var v = n;
  for (var i = 31; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xFF)).toInt();
    v >>= 8;
  }
  return out;
}

/// The two DER forms of the key pair of the private number [d] and the point ([x], [y]).
P256Keys p256KeysFrom(BigInt d, BigInt x, BigInt y) {
  final point = Uint8List.fromList([0x04, ..._fixed32(x), ..._fixed32(y)]);
  return P256Keys(
    Uint8List.fromList([..._sec1Prefix, ..._fixed32(d), ..._sec1Curve, ..._sec1Point, ...point]),
    Uint8List.fromList([..._spkiPrefix, ...point]),
  );
}

/// A new key pair. [random] is for tests; the app uses the system's.
P256Keys newP256Keys([Random? random]) {
  final source = random ?? Random.secure();
  final rng = FortunaRandom()
    ..seed(KeyParameter(Uint8List.fromList([for (var i = 0; i < 32; i++) source.nextInt(256)])));
  final generator = ECKeyGenerator()
    ..init(ParametersWithRandom(ECKeyGeneratorParameters(ECCurve_secp256r1()), rng));
  final pair = generator.generateKeyPair();
  final d = (pair.privateKey as ECPrivateKey).d!;
  final q = (pair.publicKey as ECPublicKey).Q!;
  return p256KeysFrom(d, q.x!.toBigInteger()!, q.y!.toBigInteger()!);
}

/// The public key of an endpoint as Xray wants it (base64 of the SubjectPublicKeyInfo), from what Cloudflare
/// sends: a PEM text, or the base64 already. Null when it is neither.
String? edgeKeyBase64(String text) {
  final body = text
      .replaceAll(RegExp(r'-----[A-Z ]+-----'), '')
      .replaceAll(RegExp(r'\s'), '');
  if (body.isEmpty) return null;
  try {
    final der = base64.decode(base64.normalize(body));
    // 91 bytes: SubjectPublicKeyInfo of a P-256 key.
    return der.length == 91 && der[0] == 0x30 ? base64.encode(der) : null;
  } catch (_) {
    return null;
  }
}
