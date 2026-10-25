import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/config_decryptor.dart';

// The fixtures are produced by a Python reference implementation: every case
// holds an encrypted sample and the text that implementation decrypts it to.

Uint8List _asset(String name) => File('assets/npvs/$name').readAsBytesSync();

NpvTables _tables() => NpvTables(_asset('tyboxes.bin'), _asset('mbl.bin'),
    _asset('tboxes_last.bin'), _asset('tboxes_last_v2.bin'), _asset('xor.bin'),
    gen2Z: _asset('gen2_tables.bin.z'), crypt5Json: _asset('crypt5-keys.json'));

List<String> _links(String text) => text
    .split('\n')
    .map((l) => l.trim())
    .where((l) => RegExp(r'^[a-z0-9+.-]+://').hasMatch(l))
    .toList();

void main() {
  final dir = Directory('test/fixtures/formats');
  final cases =
      (jsonDecode(File('${dir.path}/cases.json').readAsStringSync()) as List)
          .cast<Map<String, dynamic>>();
  final tables = _tables();

  for (final c in cases) {
    test('${c['name']} matches the reference output', () {
      final data = File('${dir.path}/${c['bin']}').readAsBytesSync();
      final name = c['file'] as String;
      final password = c['password'] as String;
      final expected = c['expected'] as String;
      final need = inspectProtected(data, name);
      expect(need == ProtectKind.password, password.isNotEmpty);
      final got = decryptProtected(data, name, password, tables: tables);
      switch (c['mode']) {
        case 'full':
          expect(got, expected);
        case 'links':
          expect(_links(got), _links(expected));
        default:
          expect(got.startsWith(expected), isTrue);
          expect(_links(got), (c['links'] as List).cast<String>());
      }
    });
  }

  test('wrong passphrase is reported as an error', () {
    final c = cases.firstWhere((c) => c['name'] == 'npvs_gen2_pass');
    final data = File('${dir.path}/${c['bin']}').readAsBytesSync();
    expect(() => decryptProtected(data, 'a.npvs', 'nope', tables: tables),
        throwsA(isA<ConfigDecryptError>()));
  });
}
