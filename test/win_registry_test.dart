import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/win_registry.dart';

void main() {
  const key = r'Software\KumoRegistryTest';

  tearDownAll(() async {
    if (Platform.isWindows) await Process.run('reg', ['delete', 'HKCU\\$key', '/f']);
  });

  test('strings and numbers are written, read back as reg.exe prints them, and deleted', () {
    WinRegistry.writeString(key, 'Server', '127.0.0.1:2080');
    WinRegistry.writeString(key, 'Empty', '');
    WinRegistry.writeString(key, 'Unicode', 'پروکسی ✓');
    WinRegistry.writeDword(key, 'Enable', 1);
    WinRegistry.writeDword(key, 'Big', 0xdeadbeef);
    expect(WinRegistry.read(key, 'Server'), '127.0.0.1:2080');
    expect(WinRegistry.read(key, 'Empty'), '');
    expect(WinRegistry.read(key, 'Unicode'), 'پروکسی ✓');
    expect(WinRegistry.read(key, 'Enable'), '0x1');
    expect(WinRegistry.read(key, 'Big'), '0xdeadbeef');
    expect(WinRegistry.read(key, 'Missing'), isNull);
    WinRegistry.writeString(key, 'Server', null);
    expect(WinRegistry.read(key, 'Server'), isNull);
    // Deleting what is not there is not an error.
    WinRegistry.writeString(key, 'Server', null);
    expect(WinRegistry.read(r'Software\KumoRegistryTest\NoSuchKey', 'x'), isNull);
  }, skip: !Platform.isWindows);

  test('reg.exe sees what the API wrote', () async {
    WinRegistry.writeString(key, 'Override', 'localhost;127.*;<local>');
    WinRegistry.writeDword(key, 'Flag', 0);
    final r = await Process.run('reg', ['query', 'HKCU\\$key']);
    expect('${r.stdout}', contains('localhost;127.*;<local>'));
    expect('${r.stdout}', matches(RegExp(r'Flag\s+REG_DWORD\s+0x0')));
  }, skip: !Platform.isWindows);

  test('much faster than a reg.exe process', () async {
    final sw = Stopwatch()..start();
    for (var i = 0; i < 20; i++) {
      WinRegistry.writeDword(key, 'Count', i);
      WinRegistry.read(key, 'Count');
    }
    final api = sw.elapsedMicroseconds;
    sw.reset();
    await Process.run('reg', ['query', 'HKCU\\$key', '/v', 'Count']);
    final one = sw.elapsedMicroseconds;
    expect(api, lessThan(one * 2), reason: '40 calls through the API: ${api}us; one reg.exe: ${one}us');
  }, skip: !Platform.isWindows);
}
