import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/config_decryptor.dart';

Uint8List _hex(String h) => Uint8List.fromList([
      for (var i = 0; i < h.length; i += 2)
        int.parse(h.substring(i, i + 2), radix: 16)
    ]);

const _npvs =
    '4e50565301000000cb7b22636f6e6669674964223a202278222c202270617373706872617365223a207b226b6466223a202270626b6466322d686d61632d736861323536222c20226974657273223a20313030302c202273616c74223a20224d6a4d304e5459334f446b364f7a7739506a39415151222c202277726170223a202241414543417751464267634943516f4c7a466141525458547070313957613637704a6b4b6f7863305a6e725773543937614949796e736f44705a6d42635a732d4d2d6d61327275347744595a4569667a227d7d1e1f2021222324252627282900000045d5c73cf67ac6be4bc654bc78125f595f0ffd8a76f1310c9d00300a3adbdf3d7e6c706e1f92a0aac1ee073c16075d33e94fa358ac334a1cd2df97305391ebfbf0f3a0076d0700000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000';
const _npvsApp =
    '4e50565301000000c27b22636f6e6669674964223a202279222c20226170704b6579223a207b226b6466223a202277626165732d6374722d736861323536222c20226b65794964223a20312c202273616c74223a20224277674a4367734d4451345045424553457851564667222c202277726170223a202241414543417751464267634943516f4c475348516649683552764f666178533055766f533946587a53444565784f7a753878486f46524f5331614b39644d396749485f7a466746593779704f32363771227d7d1e1f202122232425262728290000003087e7666137fc8020650511a2529f7dc67193624c568696fc180b06f7f2f7d7307b791a7c2d2759b2aa9d17664d25fa7c00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000';
const _slip =
    'slipnet-bundle-enc://AQABAgMEBQYHCAkKCwwNDg9kZWZnaGlqa2xtbm8978acZLuur4PHn18n9lo6wEQsByhVZR8l7CwqVU1JxjJab9ibOSriHUPHjHDyVZBHKdIKJSrodb6HTw7hv2S+m1XX2AFE1CbVuhboUXISqQ==';

void main() {
  test('slip bundle opens with the right password', () {
    final text =
        decryptSlipBundle(Uint8List.fromList(utf8.encode(_slip)), 'pass123');
    expect(text, contains('vless://u@example.com:443'));
    expect(text, contains('trojan://p@h.com:443#b'));
  });

  test('slip bundle rejects a wrong password', () {
    expect(
        () => decryptSlipBundle(Uint8List.fromList(utf8.encode(_slip)), 'nope'),
        throwsA(isA<ConfigDecryptError>()));
  });

  test('npvs passphrase export opens and sentinels are decoded', () {
    expect(decryptNpvs(_hex(_npvs), 'pass123'),
        'vless://u@secret-host.example.com:443#n');
  });

  test('npvs rejects a wrong passphrase', () {
    expect(() => decryptNpvs(_hex(_npvs), 'nope'),
        throwsA(isA<ConfigDecryptError>()));
  });

  test('npvs without a passphrase is detected and opens with the tables', () {
    expect(inspectProtected(_hex(_npvsApp), 'a.npvs'), ProtectKind.noPassword);
    expect(inspectProtected(_hex(_npvs), 'a.npvs'), ProtectKind.password);
    Uint8List f(String n) => File('assets/npvs/$n').readAsBytesSync();
    final tables = NpvTables(f('tyboxes.bin'), f('mbl.bin'),
        f('tboxes_last.bin'), f('tboxes_last_v2.bin'), f('xor.bin'));
    expect(decryptNpvs(_hex(_npvsApp), '', tables: tables),
        'vless://u@h.example.com:443#nopw');
  });
}
