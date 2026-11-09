import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/decrypt/fast_pbkdf2.dart';
import 'package:pointycastle/export.dart';

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List _reference(List<int> password, List<int> salt, int iterations, int length) {
  final kdf = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))..init(Pbkdf2Parameters(Uint8List.fromList(salt), iterations, length));
  return kdf.process(Uint8List.fromList(password));
}

void main() {
  test('the published test vectors', () {
    List<int> p(String s) => utf8.encode(s);
    expect(_hex(pbkdf2Sha256(p('password'), p('salt'), 1, 32)), '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b');
    expect(_hex(pbkdf2Sha256(p('password'), p('salt'), 2, 32)), 'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43');
    expect(_hex(pbkdf2Sha256(p('password'), p('salt'), 4096, 32)), 'c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a');
  });

  test('the same as the library for passwords and salts of every size, and for more than one block', () {
    for (final plen in [0, 1, 15, 55, 56, 63, 64, 65, 100]) {
      for (final slen in [0, 1, 16, 55, 56, 64, 80]) {
        final password = List<int>.generate(plen, (i) => (i * 7 + 3) & 0xff);
        final salt = List<int>.generate(slen, (i) => (i * 13 + 5) & 0xff);
        for (final length in [32, 20, 48]) {
          expect(_hex(pbkdf2Sha256(password, salt, 37, length)), _hex(_reference(password, salt, 37, length)),
              reason: 'password $plen salt $slen length $length');
        }
      }
    }
  });

  test('hundreds of thousands of rounds are quick (and right)', () {
    final password = utf8.encode('@V2RAY_SPATIAL'), salt = List<int>.generate(16, (i) => i);
    final sw = Stopwatch()..start();
    final fast = pbkdf2Sha256(password, salt, 600000, 32);
    final fastMs = sw.elapsedMilliseconds;
    sw.reset();
    final slow = _reference(password, salt, 600000, 32);
    final slowMs = sw.elapsedMilliseconds;
    // ignore: avoid_print
    print('600000 rounds: fast $fastMs ms, library $slowMs ms');
    expect(_hex(fast), _hex(slow));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
