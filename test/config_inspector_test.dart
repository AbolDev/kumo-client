import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/config_inspector.dart';
import 'package:kumo/core/desktop_vpn.dart';
import 'package:kumo/core/probe_fetch.dart';
import 'package:kumo/core/proxy_config.dart';
import 'package:kumo/screens/safety_sheet.dart';
import 'package:kumo/state/app_state.dart';

/// Gives the real HTTP client back (the test framework answers every request with its own otherwise).
class _RealHttp extends HttpOverrides {}

String _url(int i) => inspectTargets[i].url;

ProbeResult _ok(int i, {String body = '', bool? verified, int status = 200}) {
  final url = _url(i);
  final https = url.startsWith('https');
  return ProbeResult(url: url, ok: true, status: status, tls: https, verified: https ? (verified ?? true) : null, body: body);
}

ProbeResult _fail(int i) => ProbeResult(url: _url(i), err: 'timeout', tls: _url(i).startsWith('https'));

/// What a server that changes nothing gives, for each address in turn.
List<ProbeResult> _clean({String ip = '203.0.113.9'}) => [
      _ok(0, body: 'fl=1\nip=$ip\nloc=DE\n'),
      _ok(1, status: 204),
      _ok(2, body: 'User-agent: *'),
      _ok(3, body: '<html><title>Example Domain</title></html>'),
      _ok(4, body: 'success\n'),
    ];

const _trojan = 'trojan://secret@t.example.com:443?sni=t.example.com#Japan';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the verdict', () {
    test('nothing changed: nothing found, and the address the world sees is told', () {
      final r = judgeInspection(_clean(), {});
      expect(r.verdict, InspectVerdict.clean);
      expect(r.passed, 5);
      expect(r.exitIp, '203.0.113.9');
      expect(r.exitCountry, 'DE');
      expect(r.findings, isEmpty);
    });

    test('a bad certificate that the network does not get is danger', () {
      final via = _clean()..[1] = _ok(1, verified: false);
      final r = judgeInspection(via, {_url(1): _ok(1)});
      expect(r.verdict, InspectVerdict.danger);
      expect(r.findings.single.kind, FindingKind.badCertificate);
      expect(r.findings.single.host, 'www.gstatic.com');
    });

    test('a bad certificate that the network gets too is the network\'s, not the server\'s', () {
      final via = _clean()..[1] = _ok(1, verified: false);
      final r = judgeInspection(via, {_url(1): _ok(1, verified: false)});
      expect(r.verdict, InspectVerdict.clean);
      expect(r.findings, isEmpty);
      expect(r.passed, 4);
    });

    test('a bad certificate with no answer of the network to tell is only suspicious', () {
      final via = _clean()..[2] = _ok(2, verified: false);
      final r = judgeInspection(via, {_url(2): _fail(2)});
      expect(r.verdict, InspectVerdict.suspicious);
      expect(r.findings.single.kind, FindingKind.badCertificateUnconfirmed);
      expect(judgeInspection(via, {}).verdict, InspectVerdict.suspicious);
    });

    test('a plain page with something added is danger when the network gets it as it is', () {
      final via = _clean()..[3] = _ok(3, body: '<html><title>Example Domain</title><script src="//ads"></script></html>');
      final r = judgeInspection(via, {_url(3): _ok(3, body: '<title>Example Domain</title>')});
      expect(r.verdict, InspectVerdict.danger);
      expect(r.findings.single.kind, FindingKind.pageChanged);
    });

    test('the one-word page of the captive-portal check is held to being one word', () {
      final via = _clean()..[4] = _ok(4, body: 'success\n<iframe src="x"></iframe>');
      expect(judgeInspection(via, {_url(4): _ok(4, body: 'success\n')}).verdict, InspectVerdict.danger);
      expect(judgeInspection(via, {_url(4): _ok(4, body: 'login here')}).verdict, InspectVerdict.clean);
    });

    test('the same address as the device\'s own is suspicious, another is not', () {
      expect(judgeInspection(_clean(), {}, directIp: '203.0.113.9').verdict, InspectVerdict.suspicious);
      expect(judgeInspection(_clean(), {}, directIp: '198.51.100.7').verdict, InspectVerdict.clean);
      expect(judgeInspection(_clean(), {}).verdict, InspectVerdict.clean);
    });

    test('an address that does not open through the server but does on the network is told, and is no danger', () {
      final via = _clean()..[2] = _fail(2);
      final r = judgeInspection(via, {_url(2): _ok(2)});
      expect(r.verdict, InspectVerdict.clean);
      expect(r.findings.single.kind, FindingKind.blocked);
    });

    test('nothing came through the server: no result, not a verdict', () {
      final r = judgeInspection([for (var i = 0; i < inspectTargets.length; i++) _fail(i)], {});
      expect(r.verdict, InspectVerdict.unknown);
      expect(r.findings.map((f) => f.kind), contains(FindingKind.noAnswer));
    });

    test('answers that do not match the addresses asked are no result', () {
      expect(judgeInspection([_ok(0)], {}).verdict, InspectVerdict.unknown);
    });

    test('Cloudflare\'s trace page gives the address and the country', () {
      final t = parseTrace('fl=29f\nh=www.cloudflare.com\nip=2001:db8::1\nloc=NL\ntls=TLSv1.3');
      expect(t.ip, '2001:db8::1');
      expect(t.country, 'NL');
      expect(parseTrace('nothing').ip, isNull);
    });
  });

  group('what is kept', () {
    test('a note is read back, and one that is not a note is not', () {
      final n = SafetyNote.fromJson(const SafetyNote(InspectVerdict.danger, 123).toJson())!;
      expect(n.verdict, InspectVerdict.danger);
      expect(n.at, 123);
      expect(SafetyNote.fromJson(null), isNull);
      expect(SafetyNote.fromJson({'v': 99, 'at': 1}), isNull);
      expect(SafetyNote.fromJson('x'), isNull);
    });

    test('the answers of the phone are read, and a garbled one gives nothing', () {
      final list = ProbeResult.listFromJson(jsonEncode([
        {'url': 'https://a.example', 'ok': true, 'status': 200, 'ms': 40, 'tls': true, 'verified': false, 'issuer': 'X', 'body': 'hi'},
        {'url': 'http://b.example', 'ok': false, 'err': 'timeout'},
      ]));
      expect(list.length, 2);
      expect(list[0].verified, isFalse);
      expect(list[0].body, 'hi');
      expect(list[1].ok, isFalse);
      expect(list[1].verified, isNull);
      expect(ProbeResult.listFromJson('not json'), isEmpty);
      expect(ProbeResult.listFromJson('{"a":1}'), isEmpty);
      final again = ProbeResult.fromJson(list[0].toJson());
      expect(again.verified, isFalse);
      expect(again.issuer, 'X');
    });
  });

  group('inspectServer', () {
    ProxyConfig server() => parseLinks([_trojan]).single;

    test('through a server that changes nothing, with the network open: the address is compared with the network\'s', () async {
      final asked = <String>[];
      final r = await inspectServer(server(),
          networkIsOpen: true,
          via: (_) async => _clean(),
          fetch: (uri) async {
            asked.add('$uri');
            return _ok(0, body: 'ip=203.0.113.9\nloc=IR\n');
          });
      // Only the trace page was asked of the network (to know its address): everything else was right.
      expect(asked, [_url(0)]);
      expect(r.verdict, InspectVerdict.suspicious);
      expect(r.findings.single.kind, FindingKind.sameAddress);
    });

    test('with a connection up, the network\'s address is not compared', () async {
      final r = await inspectServer(server(),
          networkIsOpen: false, via: (_) async => _clean(), fetch: (_) => throw StateError('nothing to ask'));
      expect(r.verdict, InspectVerdict.clean);
    });

    test('only the addresses that did not look right are asked of the network', () async {
      final asked = <String>[];
      final r = await inspectServer(server(),
          networkIsOpen: false,
          via: (_) async => _clean()..[2] = _ok(2, verified: false),
          fetch: (uri) async {
            asked.add('$uri');
            return _ok(2);
          });
      expect(asked, [_url(2)]);
      expect(r.verdict, InspectVerdict.danger);
    });

    test('a test that could not run (skipped) or came back empty is no result', () async {
      final skipped = await inspectServer(server(), networkIsOpen: true, via: (_) async => null);
      expect(skipped.verdict, InspectVerdict.unknown);
      expect(skipped.findings.single.kind, FindingKind.busy);
      final empty = await inspectServer(server(), networkIsOpen: true, via: (_) async => const []);
      expect(empty.verdict, InspectVerdict.unknown);
      expect(empty.findings.single.kind, FindingKind.noAnswer);
    });
  });

  group('the fetch of the app', () {
    test('a page is read as far as 4 KB, an http page has no certificate to judge, a closed port is a failure', () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((req) {
          req.response
            ..statusCode = req.uri.path == '/none' ? 204 : 200
            ..write(req.uri.path == '/big' ? 'a' * 10000 : 'hello');
          req.response.close();
        });
        final base = 'http://127.0.0.1:${server.port}';
        final small = await probeFetch(Uri.parse('$base/x'));
        expect(small.ok, isTrue);
        expect(small.status, 200);
        expect(small.body, 'hello');
        expect(small.verified, isNull);
        expect(small.tls, isFalse);
        final big = await probeFetch(Uri.parse('$base/big'));
        expect(big.body.length, lessThanOrEqualTo(4096));
        expect(big.body.length, greaterThan(0));
        final port = server.port;
        await server.close(force: true);
        final closed = await probeFetch(Uri.parse('http://127.0.0.1:$port/'), timeout: const Duration(seconds: 2));
        expect(closed.ok, isFalse);
        expect(closed.err, isNotEmpty);
      }, _RealHttp());
    });
  });

  group('kept with the servers', () {
    late Directory dir;
    final vpn = DesktopVpn.instance;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('kumo-safety');
      DesktopVpn.dataDirOverride = dir.path;
    });
    tearDown(() {
      DesktopVpn.dataDirOverride = null;
      dir.deleteSync(recursive: true);
    });

    test('the note of a server is read from the saved file, and written back with it', () async {
      final link = parseLinks([_trojan]).single.link;
      await vpn.writeFile(
          'servers.json',
          jsonEncode({
            'manual': [link],
            'safety': {pingKey(link): const SafetyNote(InspectVerdict.danger, 5).toJson(), 'gone': const SafetyNote(InspectVerdict.danger, 5).toJson()},
          }));
      final state = AppState();
      await state.loadStoredForTest();
      final c = state.manual.configs.single;
      expect(state.isDangerous(c), isTrue);
      expect(state.safetyOf(c)!.at, 5);
      state.clearTestResults();
      await state.flushStore();
      final saved = jsonDecode((await vpn.readFile('servers.json'))!) as Map;
      // The note of the server that is in a list stays; one of a server that is not is dropped.
      expect((saved['safety'] as Map).keys, [pingKey(link)]);
    });

    test('a server nobody checked is not dangerous', () async {
      final state = AppState();
      final c = parseLinks([_trojan]).single;
      expect(state.isDangerous(c), isFalse);
      expect(state.safetyOf(c), isNull);
    });
  });

  group('the sheet', () {
    Widget app(Widget child) => MaterialApp(home: Scaffold(body: child));

    testWidgets('it says what is running, then what was found, and always what the check cannot find', (tester) async {
      final done = Completer<InspectReport?>();
      final state = AppState();
      final config = parseLinks([_trojan]).single;
      await tester.pumpWidget(app(SafetySheet(state: state, config: config, check: (_) => done.future)));
      await tester.pump();
      expect(find.byKey(const ValueKey('safety-running')), findsOneWidget);
      expect(find.byKey(const ValueKey('safety-limits')), findsOneWidget);
      done.complete(InspectReport(InspectVerdict.danger, [const Finding(FindingKind.badCertificate, 'www.gstatic.com')], passed: 4));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('safety-danger')), findsOneWidget);
      expect(find.text('Dangerous'), findsOneWidget);
      expect(find.textContaining('www.gstatic.com'), findsOneWidget);
      expect(find.byKey(const ValueKey('safety-limits')), findsOneWidget);
      expect(find.byKey(const ValueKey('safety-again')), findsOneWidget);
    });

    testWidgets('a clean result is worded as "nothing found", never as "safe"', (tester) async {
      final state = AppState();
      final config = parseLinks([_trojan]).single;
      await tester.pumpWidget(app(SafetySheet(
          state: state,
          config: config,
          check: (_) async => InspectReport(InspectVerdict.clean, const [], exitIp: '203.0.113.9', exitCountry: 'DE', passed: 5))));
      await tester.pump();
      await tester.pump();
      expect(find.text('Nothing found'), findsOneWidget);
      expect(find.textContaining('5 of 5'), findsOneWidget);
      expect(find.textContaining('203.0.113.9'), findsOneWidget);
      expect(find.textContaining('safe'), findsNothing);
    });

    testWidgets('a check that cannot start now says to disconnect first', (tester) async {
      final state = AppState();
      final config = parseLinks([_trojan]).single;
      await tester.pumpWidget(app(SafetySheet(state: state, config: config, check: (_) async => null)));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('safety-busy')), findsOneWidget);
    });

    testWidgets('a dangerous server is not picked without asking: "Use anyway" says yes, cancel says no', (tester) async {
      Future<bool?> ask(WidgetTester t, String button) async {
        bool? answer;
        await t.pumpWidget(app(Builder(
            builder: (context) => TextButton(
                onPressed: () async => answer = await confirmDangerous(context), child: const Text('go')))));
        await t.tap(find.text('go'));
        await t.pumpAndSettle();
        expect(find.text('This server was found dangerous'), findsOneWidget);
        await t.tap(find.text(button));
        await t.pumpAndSettle();
        return answer;
      }

      expect(await ask(tester, 'Use anyway'), isTrue);
      expect(await ask(tester, 'Cancel'), isFalse);
    });
  });
}
