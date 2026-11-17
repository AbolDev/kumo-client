import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/desktop_vpn.dart';
import 'package:kumo/state/app_state.dart';

const _link =
    'vless://11111111-1111-1111-1111-111111111111@example.com:443?security=tls&sni=example.com&type=tcp#n1';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  final vpn = DesktopVpn.instance;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('kumo-store');
    DesktopVpn.dataDirOverride = dir.path;
  });
  tearDown(() {
    DesktopVpn.dataDirOverride = null;
    dir.deleteSync(recursive: true);
  });

  String path(String name) => '${dir.path}${Platform.pathSeparator}$name';

  test('a saved file is whole, leaves no temporary file, and the last good copy stays', () async {
    await vpn.writeFile('servers.json', '{"v":1}');
    expect(await vpn.readFile('servers.json'), '{"v":1}');
    await vpn.writeFile('servers.json', '{"v":2}');
    expect(await vpn.readFile('servers.json'), '{"v":2}');
    expect(await vpn.readFile('servers.json.bak'), '{"v":1}');
    expect(File(path('servers.json.tmp')).existsSync(), isFalse);
  });

  test('a damaged file does not replace the good copy', () async {
    await vpn.writeFile('servers.json', '{"v":1}');
    await vpn.writeFile('servers.json', '{"v":2}');
    await File(path('servers.json')).writeAsString('{"v":'); // cut off
    await vpn.writeFile('servers.json', '{"v":3}');
    expect(await vpn.readFile('servers.json.bak'), '{"v":1}');
  });

  test('a file that cannot be decrypted is an error, not "no file"', () async {
    await File(path('servers.json')).writeAsString('kumo-dpapi1:AAAA');
    await expectLater(vpn.readFile('servers.json'), throwsA(isA<FileSystemException>()));
    expect(await vpn.readFile('missing.json'), isNull);
  }, skip: !Platform.isWindows);

  test('moveAside keeps the file under another name', () async {
    await File(path('servers.json')).writeAsString('precious');
    await vpn.moveAside('servers.json');
    expect(File(path('servers.json')).existsSync(), isFalse);
    expect(File(path('servers.json.broken')).readAsStringSync(), 'precious');
  });

  test('one broken subscription does not take the others down', () async {
    await vpn.writeFile(
        'servers.json',
        jsonEncode({
          'manual': [_link],
          'subs': [
            {'id': 's1', 'name': 'A', 'url': 'https://a.example', 'links': [_link]},
            {'id': 's2', 'name': 'B'}, // no links
            {'id': 's3', 'name': 'C', 'url': 'https://c.example', 'links': []},
          ],
        }));
    final state = AppState();
    await state.loadStoredForTest();
    expect(state.manual.configs.length, 1);
    expect(state.subscriptions.map((s) => s.id), ['s1', 's3']);
    expect(state.storeLockedForTest, isFalse);
  });

  test('a damaged file is read from its last good copy', () async {
    await vpn.writeFile('servers.json', jsonEncode({'manual': [_link]}));
    await vpn.writeFile('servers.json', jsonEncode({'manual': [_link, _link.replaceAll('n1', 'n2')]}));
    await File(path('servers.json')).writeAsString('{"manual":'); // cut off
    final state = AppState();
    await state.loadStoredForTest();
    expect(state.manual.configs.length, 1); // the copy: one server
    expect(state.storeLockedForTest, isFalse);
  });

  test('a file nothing can read is set aside before a new one is written', () async {
    await File(path('servers.json')).writeAsString('this is not json');
    final state = AppState();
    await state.loadStoredForTest();
    expect(state.storeLockedForTest, isTrue);
    expect(state.manual.configs, isEmpty);
    // Nothing was written over it while it was only loaded.
    expect(File(path('servers.json')).readAsStringSync(), 'this is not json');
    // The first save sets it aside.
    state.clearTestResults();
    await state.flushStore();
    expect(File(path('servers.json.broken')).readAsStringSync(), 'this is not json');
    expect(jsonDecode((await vpn.readFile('servers.json'))!), isA<Map>());
  });

  test('one damaged day or server does not take the other statistics down', () async {
    await vpn.writeFile(
        'usage.json',
        jsonEncode({
          'days': {
            '2026-10-24': [10, 20, 30],
            '2026-10-25': 'broken',
            '2026-10-26': [1, 2],
          },
          'servers': {
            'A': [5, 6, 7, 8],
            'B': ['x'],
            'C': 99, // an older version: only the total
          },
          'public': [3, 4],
          'warp': 'broken',
          'peak': [7, 9],
        }));
    final state = AppState();
    await state.loadUsageForTest();
    expect(state.dayUsage['2026-10-24'], [10, 20, 30]);
    expect(state.dayUsage.containsKey('2026-10-25'), isFalse);
    expect(state.dayUsage['2026-10-26'], [1, 2, 0]);
    expect(state.serverUsage['A'], [5, 6, 7, 8]);
    expect(state.serverUsage.containsKey('B'), isFalse);
    expect(state.serverUsage['C'], [0, 0, 0, 0, 99]);
    expect(state.publicUsage, [3, 4]);
    expect(state.warpUsage, [0, 0]);
    expect(state.peakDown, 7);
    expect(state.peakUp, 9);
  });

  test('a statistics file nothing can read is kept aside, not written over', () async {
    await File(path('usage.json')).writeAsString('not json at all');
    final state = AppState();
    await state.loadUsageForTest();
    expect(state.dayUsage, isEmpty);
    expect(File(path('usage.json.broken')).readAsStringSync(), 'not json at all');
  });

  test('nothing is set aside when there was no file', () async {
    final state = AppState();
    await state.loadStoredForTest();
    expect(state.storeLockedForTest, isFalse);
  });
}
