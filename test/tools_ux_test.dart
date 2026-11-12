import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/ip_info.dart';
import 'package:kumo/core/service_check.dart';
import 'package:kumo/l10n/strings.dart';
import 'package:kumo/screens/dns_leak_page.dart';
import 'package:kumo/screens/service_test_page.dart';
import 'package:kumo/screens/share_app_page.dart';
import 'package:kumo/screens/troubleshoot_page.dart';
import 'package:kumo/state/app_state.dart';
import 'package:kumo/widgets/kumo_mark.dart';

Widget _app(Widget home) => MaterialApp(
      supportedLocales: S.supportedLocales,
      localizationsDelegates: const [
        S.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      home: home,
    );

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Gives the real HTTP client back (the test framework answers every request with its own otherwise).
class _RealHttp extends HttpOverrides {}

DnsLeakEntry _resolver(String ip, String country, String org) => DnsLeakEntry(ip, country, org, 'AS200');

void main() {
  group('the service test with the VPN off', () {
    test('with no proxy the request goes straight out, with a proxy it goes through the proxy', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) {
        req.response
          ..statusCode = 200
          ..write('hello');
        req.response.close();
      });
      // The test framework answers every request itself: here the real client is wanted.
      await HttpOverrides.runWithHttpOverrides(() async {
        final direct = await fetchThrough('http://127.0.0.1:${server.port}/', proxyPort: null);
        expect(direct.status, 200);
        expect(direct.body, 'hello');
        // The same address through a proxy nobody listens on: the request is sent there, and fails.
        final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final deadPort = dead.port;
        await dead.close();
        final proxied = await fetchThrough('http://127.0.0.1:${server.port}/', proxyPort: deadPort);
        expect(proxied.status, -1);
      }, _RealHttp());
    });

    testWidgets('the page says it is testing without the VPN, and has no "connect first" wall', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_app(ServiceTestPage(state: AppState(), autoRun: false)));
      await tester.pumpAndSettle();
      expect(find.text('Without the VPN: what your network lets through'), findsOneWidget);
      expect(find.textContaining('Connect first'), findsNothing);
      // Every service has a row from the start, in the same order.
      for (final name in ['ChatGPT', 'Netflix', 'YouTube', 'Telegram', 'GitHub', 'Wikipedia']) {
        expect(find.text(name), findsOneWidget, reason: name);
      }
    });
  });

  group('the DNS leak test shows what it finds as it finds it', () {
    testWidgets('a server is on the page before the test is over, and the verdict is final at the end', (tester) async {
      _tall(tester);
      final finish = Completer<DnsLeakResult>();
      void Function(DnsLeakResult)? push;
      const vpn = DnsLeakEntry('203.0.113.1', 'Germany', 'Hetzner', 'AS100');
      await tester.pumpWidget(_app(DnsLeakPage(
        state: AppState(),
        runTest: ({int? proxyPort, void Function(DnsLeakResult)? onResult, void Function(DnsLeakStep)? onStep}) {
          push = onResult;
          onStep?.call(DnsLeakStep.asking);
          return finish.future;
        },
      )));
      await tester.pump();
      expect(find.text('Testing the DNS servers…'), findsOneWidget);
      push!(DnsLeakResult(vpn, [_resolver('203.0.113.9', 'Germany', 'Hetzner')], ''));
      await tester.pump(const Duration(milliseconds: 500));
      // Still running: the server is shown, and the page says what the verdict is so far.
      expect(find.text('203.0.113.9'), findsOneWidget);
      expect(find.textContaining('DNS servers seen'), findsOneWidget);
      expect(find.text('So far: No DNS leak found'), findsOneWidget);
      // A second one, from another country, joins it.
      push!(DnsLeakResult(vpn, [_resolver('203.0.113.9', 'Germany', 'Hetzner'), _resolver('198.51.100.7', 'Iran', 'Some ISP')], ''));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('198.51.100.7'), findsOneWidget);
      expect(find.text('So far: DNS may be leaking'), findsOneWidget);
      finish.complete(DnsLeakResult(vpn, [_resolver('203.0.113.9', 'Germany', 'Hetzner'), _resolver('198.51.100.7', 'Iran', 'Some ISP')], ''));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('DNS may be leaking'), findsOneWidget);
      expect(find.textContaining('So far'), findsNothing);
      expect(find.text('Test again'), findsOneWidget);
    });
  });

  group('Why can\'t I connect?', () {
    testWidgets('every check has a row from the start, waiting', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_app(TroubleshootPage(state: AppState(), autoRun: false)));
      await tester.pumpAndSettle();
      for (final title in ['Internet access', 'Name lookup (DNS)', 'Servers in the list', 'Reaching the server', 'Clock', 'Last connection error']) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
      expect(find.text('Waiting…'), findsNWidgets(6));
      expect(find.text('Start the check'), findsOneWidget);
    });
  });

  group('Share Kumo', () {
    testWidgets('nothing moves when another language is picked, and the code has the Kumo cloud in it', (tester) async {
      _tall(tester);
      await tester.pumpWidget(const MaterialApp(home: ShareAppPage()));
      await tester.pumpAndSettle();
      Offset at(Finder f) => tester.getTopLeft(f);
      Size size(Finder f) => tester.getSize(f);
      final card = find.byType(KumoQrCard);
      final copy = find.text('Copy');
      final before = {
        for (final code in ['en', 'fa', 'ar', 'ru', 'vi', 'zh', 'zh-Hant'])
          code: (at(find.byKey(ValueKey('lang:$code'))), size(find.byKey(ValueKey('lang:$code')))),
        'card': (at(card), size(card)),
        'copy': (at(copy), size(copy)),
      };
      for (final code in ['fa', 'ar', 'zh-Hant', 'en']) {
        await tester.tap(find.byKey(ValueKey('lang:$code')));
        await tester.pumpAndSettle();
        for (final e in before.entries) {
          final f = switch (e.key) {
            'card' => card,
            'copy' => copy,
            _ => find.byKey(ValueKey('lang:${e.key}')),
          };
          expect((at(f), size(f)), e.value, reason: '${e.key} after $code');
        }
      }
      // The cloud is in the middle of the code.
      expect(find.descendant(of: card, matching: find.byType(KumoMark)), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });
  });
}
