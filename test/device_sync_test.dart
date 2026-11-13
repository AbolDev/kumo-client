import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/desktop_vpn.dart';
import 'package:kumo/core/device_sync.dart';
import 'package:kumo/screens/sync_page.dart';
import 'package:kumo/state/app_state.dart';

/// Gives the real HTTP client back (the test framework answers every request with its own otherwise).
class _RealHttp extends HttpOverrides {}

const _a = 'trojan://secret@a.example.com:443?sni=a.example.com#A';
const _b = 'trojan://secret@b.example.com:443?sni=b.example.com#B';
const _c = 'trojan://secret@c.example.com:443?sni=c.example.com#C';

Map<String, dynamic> _servers({List<String> manual = const [], List<Map<String, dynamic>> subs = const []}) => {
      'manual': manual,
      'clean': <String>[],
      'collector': ['trojan://public@p.example.com:443#public'],
      'subs': subs,
      'pings': {'abc': 10},
      'selected': manual.isEmpty ? null : manual.first,
    };

SyncCode _loop(SyncServer s) => SyncCode.parse(s.code!.text, allowLoopback: true)!;

/// Lets real sockets and files do their work and draws what follows, a few rounds. Not `pumpAndSettle`: a spinner
/// that is on the screen while something is fetched never lets it settle.
Future<void> _letIoRun(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('addresses and codes', () {
    test('only an address of a private network is a local one', () {
      for (final ok in ['10.0.0.5', '192.168.1.20', '172.16.0.1', '172.31.255.255', '169.254.3.4']) {
        expect(isPrivateIpv4(ok), isTrue, reason: ok);
      }
      for (final no in ['8.8.8.8', '172.32.0.1', '172.15.0.1', '127.0.0.1', '192.169.0.1', 'abc', '1.2.3', '256.1.1.1', '']) {
        expect(isPrivateIpv4(no), isFalse, reason: no);
      }
    });

    test('a code is read back as it was made, and anything else is not a code', () {
      final id = base64Url.encode(List.filled(16, 7)).replaceAll('=', '');
      final key = base64Url.encode(List.filled(32, 9)).replaceAll('=', '');
      final text = 'kumo-sync:1:s:192.168.1.20:41000:$id:$key';
      final code = SyncCode.parse(text)!;
      expect(code.mode, SyncMode.send);
      expect(code.host, '192.168.1.20');
      expect(code.port, 41000);
      expect(code.key.length, 32);
      expect(code.text, text);
      expect(SyncCode.parse(' $text \n')!.text, text);
      expect(SyncCode.parse(text.replaceFirst(':s:', ':r:'))!.mode, SyncMode.receive);
      // Not a code, another version, another mode, a short key, a port that is none.
      for (final bad in [
        '',
        'vless://abc',
        text.replaceFirst('kumo-sync:1', 'kumo-sync:2'),
        text.replaceFirst(':s:', ':x:'),
        text.replaceFirst(key, 'AAAA'),
        text.replaceFirst(id, 'AAAA'),
        text.replaceFirst(':41000:', ':0:'),
        text.replaceFirst(':41000:', ':70000:'),
        '$text:extra',
      ]) {
        expect(SyncCode.parse(bad), isNull, reason: bad);
      }
    });

    test('a code that names an address outside the local network is refused: it cannot send the data out', () {
      final id = base64Url.encode(List.filled(16, 7)).replaceAll('=', '');
      final key = base64Url.encode(List.filled(32, 9)).replaceAll('=', '');
      expect(SyncCode.parse('kumo-sync:1:r:8.8.8.8:41000:$id:$key'), isNull);
      expect(SyncCode.parse('kumo-sync:1:r:example.com:41000:$id:$key'), isNull);
      expect(SyncCode.parse('kumo-sync:1:r:127.0.0.1:41000:$id:$key'), isNull);
      expect(SyncCode.parse('kumo-sync:1:r:127.0.0.1:41000:$id:$key', allowLoopback: true), isNotNull);
    });
  });

  group('the sealing', () {
    final key = Uint8List.fromList(List.generate(32, (i) => i));

    test('what is sealed opens with the same key and code, and not otherwise', () {
      final body = sealSync(key, 'aad-1', 'servers and secrets');
      expect(body, isNot(contains('servers')));
      expect(openSync(key, 'aad-1', body), 'servers and secrets');
      // Another key, another code (the text it is tied to), a changed byte, and things that are not sealed data.
      expect(openSync(Uint8List.fromList(List.generate(32, (i) => i + 1)), 'aad-1', body), isNull);
      expect(openSync(key, 'aad-2', body), isNull);
      final j = jsonDecode(body) as Map<String, dynamic>;
      final c = base64.decode(j['c'] as String);
      c[0] ^= 1;
      expect(openSync(key, 'aad-1', jsonEncode({...j, 'c': base64.encode(c)})), isNull);
      for (final junk in ['', 'x', '{}', '{"v":2}', '{"v":1,"n":"AAAA","c":"AAAA"}', '[1]']) {
        expect(openSync(key, 'aad-1', junk), isNull, reason: junk);
      }
    });

    test('the same text is sealed differently each time', () {
      expect(sealSync(key, 'a', 'same'), isNot(sealSync(key, 'a', 'same')));
    });
  });

  group('the server and the other device', () {
    Future<T> real<T>(Future<T> Function() body) => HttpOverrides.runWithHttpOverrides(body, _RealHttp());

    test('a sender gives its data once, sealed, and then answers nothing', () => real(() async {
          final server = SyncServer(mode: SyncMode.send, payload: 'the data', bind: '127.0.0.1', allowLoopback: true);
          addTearDown(server.stop);
          final code = await server.start();
          expect(code, isNotNull);
          expect(code!.mode, SyncMode.send);
          expect(await syncFetch(_loop(server)), 'the data');
          expect(server.phase.value, SyncPhase.done);
          // The code was for one use.
          expect(await syncFetch(_loop(server)), isNull);
        }));

    test('what the sender gives cannot be read without the key of the code', () => real(() async {
          final server = SyncServer(mode: SyncMode.send, payload: 'the data', bind: '127.0.0.1', allowLoopback: true);
          addTearDown(server.stop);
          await server.start();
          final good = _loop(server);
          final wrongKey = SyncCode(mode: good.mode, host: good.host, port: good.port, id: good.id, key: Uint8List(32));
          expect(await syncFetch(wrongKey), isNull);
        }));

    test('a receiver takes sealed data once and hands it over', () => real(() async {
          final got = <String>[];
          final server = SyncServer(mode: SyncMode.receive, onReceived: got.add, bind: '127.0.0.1', allowLoopback: true);
          addTearDown(server.stop);
          await server.start();
          expect(await syncPush(_loop(server), 'sent data'), isTrue);
          expect(got, ['sent data']);
          expect(server.phase.value, SyncPhase.done);
          expect(await syncPush(_loop(server), 'again'), isFalse);
          expect(got, ['sent data']);
        }));

    test('data that does not open (changed, or sealed with another key) is refused and the code stays good', () => real(() async {
          final got = <String>[];
          final server = SyncServer(mode: SyncMode.receive, onReceived: got.add, bind: '127.0.0.1', allowLoopback: true);
          addTearDown(server.stop);
          await server.start();
          final good = _loop(server);
          final forged = SyncCode(mode: good.mode, host: good.host, port: good.port, id: good.id, key: Uint8List(32));
          expect(await syncPush(forged, 'evil'), isFalse);
          expect(got, isEmpty);
          expect(server.phase.value, SyncPhase.waiting);
          expect(await syncPush(good, 'honest'), isTrue);
          expect(got, ['honest']);
        }));

    test('after a few wrong requests the code ends', () => real(() async {
          final server = SyncServer(mode: SyncMode.send, payload: 'x', bind: '127.0.0.1', allowLoopback: true, maxFailures: 3);
          addTearDown(server.stop);
          await server.start();
          final good = _loop(server);
          final client = HttpClient();
          addTearDown(() => client.close(force: true));
          final statuses = <int>[];
          for (var i = 0; i < 3; i++) {
            final req = await client.getUrl(Uri.parse('http://127.0.0.1:${good.port}/not-the-id-$i'));
            final res = await req.close();
            statuses.add(res.statusCode);
            await res.drain<void>();
          }
          expect(statuses, [404, 404, 404]);
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(server.phase.value, SyncPhase.failed);
          expect(await syncFetch(good), isNull);
        }));

    test('a wrong way (a POST to a sender) is refused', () => real(() async {
          final server = SyncServer(mode: SyncMode.send, payload: 'x', bind: '127.0.0.1', allowLoopback: true);
          addTearDown(server.stop);
          await server.start();
          final good = _loop(server);
          final asReceiver = SyncCode(mode: SyncMode.receive, host: good.host, port: good.port, id: good.id, key: good.key);
          expect(await syncPush(asReceiver, 'data'), isFalse);
          // ... and it did not use up the code.
          expect(await syncFetch(good), 'x');
        }));

    test('a request from a loopback address is refused when only the local network is allowed', () => real(() async {
          final server = SyncServer(mode: SyncMode.send, payload: 'x', bind: '127.0.0.1');
          addTearDown(server.stop);
          await server.start();
          expect(await syncFetch(_loop(server)), isNull);
        }));

    test('the code ends when its time is up', () => real(() async {
          final server =
              SyncServer(mode: SyncMode.send, payload: 'x', bind: '127.0.0.1', allowLoopback: true, ttl: const Duration(milliseconds: 150));
          addTearDown(server.stop);
          await server.start();
          await Future<void>.delayed(const Duration(milliseconds: 400));
          expect(server.phase.value, SyncPhase.failed);
          expect(await syncFetch(_loop(server)), isNull);
        }));

    test('the code is not made twice the same', () async {
      final one = SyncServer(mode: SyncMode.receive, bind: '127.0.0.1');
      final two = SyncServer(mode: SyncMode.receive, bind: '127.0.0.1');
      addTearDown(one.stop);
      addTearDown(two.stop);
      await one.start();
      await two.start();
      expect(one.code!.id, isNot(two.code!.id));
      expect(one.code!.key, isNot(two.code!.key));
    });
  });

  group('what goes over', () {
    test('only the user\'s lists go, never the public list, the pings or the choice', () {
      final text = buildSyncPayload(_servers(manual: [_a]), null);
      final j = readSyncPayload(text)!;
      final s = j['servers'] as Map;
      expect(s.keys.toSet(), {'manual', 'clean', 'subs'});
      expect(text, isNot(contains('public')));
      expect(j.containsKey('settings'), isFalse);
    });

    test('settings that go are the ones of the list, and never the erase code, the disguise or the network options', () {
      final picked = pickSyncSettings({
        'theme': 'dark',
        'showSpeed': false,
        'panicCode': true,
        'appIcon': 'd_calc',
        'disguiseName': 'Calculator',
        'net': {'proxyPort': 1080, 'tun': true},
        'autoConnect': true,
        'onboarded': true,
      });
      expect(picked, {'theme': 'dark', 'showSpeed': false});
      for (final never in ['panicCode', 'appIcon', 'disguiseName', 'net', 'autoConnect', 'proxyUser']) {
        expect(syncSettingsKeys, isNot(contains(never)));
      }
    });

    test('a preview says what is in it, and a text that is not a payload has none', () {
      final text = buildSyncPayload(
          _servers(manual: [_a, _b], subs: [
            {'id': 's1', 'name': 'Work', 'url': 'https://w.example/sub', 'links': [_c]},
          ]),
          {'theme': 'dark'});
      final p = previewSyncPayload(text)!;
      expect(p.servers, 2);
      expect(p.subscriptions, ['Work']);
      expect(p.hasSettings, isTrue);
      expect(p.isEmpty, isFalse);
      expect(previewSyncPayload('{"v":2}'), isNull);
      expect(previewSyncPayload('nonsense'), isNull);
      expect(previewSyncPayload(buildSyncPayload({}, null))!.isEmpty, isTrue);
    });

    test('merging adds what is new, and removes and changes nothing', () {
      final current = _servers(manual: [_a], subs: [
        {'id': 's1', 'name': 'Mine', 'url': 'https://mine.example/sub', 'links': [_a]},
      ]);
      final incoming = pickSyncServers(_servers(manual: [_a, _b], subs: [
        {'id': 's1', 'name': 'Same address', 'url': 'https://mine.example/sub', 'links': [_c]},
        {'id': 's1', 'name': 'Other', 'url': 'https://other.example/sub', 'links': [_b, _c]},
      ]));
      final r = mergeSyncServers(current, incoming);
      expect(r.merged['manual'], [_a, _b]);
      // The subscription with the address that is there is left as it is; the other is added under a new id.
      final subs = r.merged['subs'] as List;
      expect(subs.length, 2);
      expect((subs[0] as Map)['name'], 'Mine');
      expect((subs[1] as Map)['name'], 'Other');
      expect((subs[1] as Map)['id'], isNot('s1'));
      expect(r.servers, 1 + 2);
      expect(r.subscriptions, 1);
      // What was the device's own stays.
      expect(r.merged['collector'], current['collector']);
      expect(r.merged['pings'], current['pings']);
      expect(r.merged['selected'], current['selected']);
    });

    test('replacing puts the other lists in place of the user\'s and keeps the device\'s own parts', () {
      final current = _servers(manual: [_a]);
      final r = replaceSyncServers(current, _servers(manual: [_b, _c]));
      expect(r['manual'], [_b, _c]);
      expect(r['collector'], current['collector']);
      expect(r['pings'], current['pings']);
    });
  });

  group('on the device', () {
    late Directory dir;
    final vpn = DesktopVpn.instance;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('kumo-sync');
      DesktopVpn.dataDirOverride = dir.path;
    });
    tearDown(() {
      DesktopVpn.dataDirOverride = null;
      dir.deleteSync(recursive: true);
    });

    Future<AppState> loaded({Map<String, dynamic>? settings}) async {
      await vpn.writeFile('servers.json', jsonEncode(_servers(manual: [_a])));
      await vpn.writeFile('settings.json', jsonEncode(settings ?? {'showSpeed': true, 'panicCode': false}));
      final s = AppState();
      await s.loadStoredForTest();
      return s;
    }

    test('the payload holds the lists of the device, as they are in memory', () async {
      final state = await loaded();
      final j = readSyncPayload(await state.syncPayload(settings: false))!;
      expect((j['servers'] as Map)['manual'], [_a]);
      expect(j.containsKey('settings'), isFalse);
      final withSettings = readSyncPayload(await state.syncPayload(settings: true))!;
      expect((withSettings['settings'] as Map).containsKey('showSpeed'), isTrue);
      expect((withSettings['settings'] as Map).containsKey('panicCode'), isFalse);
    });

    test('what comes is added by default, the lists are loaded again, and the settings stay as they are', () async {
      final state = await loaded();
      final text = buildSyncPayload(_servers(manual: [_a, _b, _c]), {'showSpeed': false, 'panicCode': true, 'appIcon': 'x'});
      final r = await state.applySync(text, replace: false, settings: false);
      expect(r, (servers: 2, subscriptions: 0));
      expect(state.manual.configs.length, 3);
      expect(state.showSpeed, isTrue);
      // The file has them too.
      final saved = jsonDecode((await vpn.readFile('servers.json'))!) as Map;
      expect((saved['manual'] as List).length, 3);
    });

    test('settings come only when asked for, and then only the safe ones: the erase code is never turned on by them', () async {
      final state = await loaded();
      final text = buildSyncPayload(_servers(manual: [_a]), {'showSpeed': false, 'panicCode': true, 'appIcon': 'd_calc', 'disguiseName': 'X'});
      expect(await state.applySync(text, replace: false, settings: true), isNotNull);
      expect(state.showSpeed, isFalse);
      // What the settings file holds afterwards has none of what must never come over.
      final saved = jsonDecode((await vpn.readFile('settings.json'))!) as Map;
      expect(saved['panicCode'], isNot(true));
      expect(saved['appIcon'], isNot('d_calc'));
      expect(saved['disguiseName'], isNot('X'));
    });

    test('replacing makes the lists those of the other device', () async {
      final state = await loaded();
      final r = await state.applySync(buildSyncPayload(_servers(manual: [_b, _c]), null), replace: true, settings: false);
      expect(r, isNotNull);
      expect(state.manual.configs.map((c) => c.link), [_b, _c]);
    });

    test('a text that is not a payload changes nothing', () async {
      final state = await loaded();
      expect(await state.applySync('{"v":9}', replace: true, settings: true), isNull);
      expect(await state.applySync('nonsense', replace: false, settings: false), isNull);
      expect(state.manual.configs.length, 1);
    });
  });

  group('the page', () {
    late Directory dir;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('kumo-sync-ui');
      DesktopVpn.dataDirOverride = dir.path;
    });
    tearDown(() {
      DesktopVpn.dataDirOverride = null;
      dir.deleteSync(recursive: true);
    });

    Widget app(Widget home) => MaterialApp(home: home);

    testWidgets('it tells how safe it is, and a computer has no scan', (tester) async {
      await tester.pumpWidget(app(SyncPage(state: AppState(), camera: false)));
      expect(find.byKey(const ValueKey('sync-security')), findsOneWidget);
      expect(find.textContaining('works once'), findsOneWidget);
      expect(find.byKey(const ValueKey('sync-scan')), findsNothing);
      expect(find.byKey(const ValueKey('sync-enter')), findsOneWidget);
      // The settings do not go unless asked for.
      expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('sync-settings'))).value, isFalse);
      await tester.pumpWidget(app(SyncPage(state: AppState(), camera: true)));
      expect(find.byKey(const ValueKey('sync-scan')), findsOneWidget);
    });

    testWidgets('a text that is not a code is said so, and nothing is asked', (tester) async {
      await tester.pumpWidget(app(SyncPage(state: AppState(), camera: false)));
      await tester.tap(find.byKey(const ValueKey('sync-enter')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('sync-code-field')), 'vless://not-a-code');
      await tester.tap(find.byKey(const ValueKey('sync-code-ok')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('not a Kumo code'), findsOneWidget);
    });

    testWidgets('showing a code lists a QR code and the time left, and cancelling ends the listening', (tester) async {
      await tester.pumpWidget(app(SyncPage(state: AppState(), camera: false, bind: '127.0.0.1', allowLoopback: true)));
      await tester.tap(find.byKey(const ValueKey('sync-receive')));
      await _letIoRun(tester);
      expect(find.byKey(const ValueKey('sync-qr')), findsOneWidget);
      expect(find.byKey(const ValueKey('sync-left')), findsOneWidget);
      expect(find.textContaining('Valid for'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sync-cancel')));
      await _letIoRun(tester);
      expect(find.byKey(const ValueKey('sync-code-card')), findsNothing);
    });

    testWidgets('a code scanned from a sender: first a question, then what came, then it is added', (tester) async {
      await HttpOverrides.runWithHttpOverrides(() async {
        // Real files and sockets only get their turn inside runAsync: awaited outside it, this never ends.
        await tester.runAsync(() => DesktopVpn.instance.writeFile('servers.json', jsonEncode(_servers(manual: [_a]))));
        final state = AppState();
        await tester.runAsync(state.loadStoredForTest);
        final server = SyncServer(
            mode: SyncMode.send,
            payload: buildSyncPayload(_servers(manual: [_a, _b]), null),
            bind: '127.0.0.1',
            allowLoopback: true);
        addTearDown(server.stop);
        late SyncCode code;
        await tester.runAsync(() async => code = (await server.start())!);
        await tester.pumpWidget(app(SyncPage(state: state, camera: true, allowLoopback: true, scan: () async => code.text)));
        await tester.tap(find.byKey(const ValueKey('sync-scan')));
        await _letIoRun(tester);
        // Nothing is fetched before the question is answered.
        expect(find.text('Get servers from 127.0.0.1?'), findsOneWidget);
        expect(server.phase.value, SyncPhase.waiting);
        await tester.tap(find.byKey(const ValueKey('sync-confirm')));
        await _letIoRun(tester);
        expect(find.byKey(const ValueKey('sync-preview')), findsOneWidget);
        expect(find.textContaining('2 servers'), findsOneWidget);
        // Nothing is changed before it is applied, and by default it is added.
        expect(state.manual.configs.length, 1);
        expect(tester.widget<RadioListTile<bool>>(find.byKey(const ValueKey('sync-add'))).groupValue, isFalse);
        await tester.tap(find.byKey(const ValueKey('sync-apply')));
        await _letIoRun(tester);
        expect(state.manual.configs.length, 2);
        expect(find.textContaining('Done: 1 servers'), findsOneWidget);
      }, _RealHttp());
    });
  });
}
