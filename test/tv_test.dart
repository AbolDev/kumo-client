import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/proxy_config.dart';
import 'package:kumo/core/tv.dart';
import 'package:kumo/core/tv_pair.dart';
import 'package:kumo/l10n/strings.dart';
import 'package:kumo/screens/home_page.dart';
import 'package:kumo/screens/tv_pair_page.dart';
import 'package:kumo/state/app_state.dart';

/// Gives the real HTTP client back (the test framework answers every request with its own otherwise).
class _RealHttp extends HttpOverrides {}

Widget _app(Widget home) => MaterialApp(
      theme: tvTheme(ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFF0E9F8E))),
      // As the app does on a television: the arrows of the remote move the focus.
      builder: (context, child) => TvKeys(child: child!),
      supportedLocales: S.supportedLocales,
      localizationsDelegates: const [
        S.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      home: home,
    );

AppState _state({bool servers = true}) {
  final s = AppState()..serversLoaded = true;
  if (servers) {
    s.collector.configs.addAll(parseLinks([
      'vless://11111111-1111-1111-1111-111111111111@v.example.com:443?security=tls&sni=v.example.com&type=ws&path=%2F#Germany%20CDN',
      'trojan://secret@t.example.com:443?sni=t.example.com#Japan',
    ]));
    s.collector.configs[0].latencyMs = 120;
  }
  return s;
}

void _television(WidgetTester tester) {
  isTv = true;
  addTearDown(() => isTv = false);
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
}

void main() {
  group('television', () {
    testWidgets('the home page is two panes, and the remote starts on the power button', (tester) async {
      _television(tester);
      await tester.pumpWidget(_app(HomePage(state: _state())));
      await tester.pump(const Duration(milliseconds: 500));
      // The connect card and the server list side by side, as on a computer: the title of the list is to the
      // right of the card that is 380 wide.
      expect(tester.getTopLeft(find.byIcon(Icons.dns_outlined)).dx, greaterThan(380));
      // OK (select) on the power button is what the remote does: the focus is on the button itself (128 wide),
      // not on the page around it.
      final focus = FocusManager.instance.primaryFocus;
      expect(focus, isNotNull);
      expect(focus!.debugLabel, 'power');
      expect(focus.rect.width, 128);
    });

    testWidgets('the right arrow goes from the power button on to the lists', (tester) async {
      _television(tester);
      await tester.pumpWidget(_app(HomePage(state: _state())));
      await tester.pump(const Duration(milliseconds: 500));
      final power = FocusManager.instance.primaryFocus!;
      // The traversal itself finds something to the right of the button.
      final scope = power.nearestScope!;
      final candidates = scope.traversalDescendants.where((n) => n.canRequestFocus && n != power).toList();
      expect(candidates.any((n) => n.rect.center.dx >= power.rect.right), isTrue,
          reason: 'power ${power.rect}; nodes ${candidates.map((n) => '${n.debugLabel} ${n.rect}').join(' | ')}');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      final first = FocusManager.instance.primaryFocus;
      expect(first, isNot(same(power)), reason: 'still on ${power.rect}');
      // It went to the right.
      expect(first!.rect.center.dx, greaterThan(power.rect.right), reason: '${first.debugLabel} ${first.rect}');
      // And back with the left arrow.
      String nodes() => scope.traversalDescendants
          .where((n) => n.canRequestFocus)
          .map((n) => '${n.debugLabel} ${n.rect} ${n.context?.widget.runtimeType}')
          .join('\n');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, isNotNull);
      expect(FocusManager.instance.primaryFocus!.rect.center.dx, lessThan(first.rect.center.dx),
          reason: 'on ${first.debugLabel} ${first.rect} ${first.context?.widget.runtimeType}; nodes:\n${nodes()}');
    });

    testWidgets('the add menu offers a phone, not the camera or a file', (tester) async {
      _television(tester);
      await tester.pumpWidget(_app(HomePage(state: _state())));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      expect(find.text('Add from your phone'), findsOneWidget);
      expect(find.text('Scan QR code'), findsNothing);
      expect(find.text('Add from file'), findsNothing);
    });

    testWidgets('with no server the first thing offered is a phone', (tester) async {
      _television(tester);
      await tester.pumpWidget(_app(HomePage(state: _state(servers: false))));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Add from your phone'), findsWidgets);
    });

    test('a button with the focus is drawn with a ring', () {
      final theme = tvTheme(ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFF0E9F8E)));
      final side = theme.filledButtonTheme.style!.side!;
      expect(side.resolve({WidgetState.focused})?.width, 3);
      expect(side.resolve({}), isNull);
      expect(theme.focusColor.a, greaterThan(0.3));
    });
  });

  group('adding from a phone', () {
    test('only a private network address is given to the phone', () {
      for (final ok in ['192.168.1.20', '10.0.0.5', '172.16.4.1', '172.31.255.1']) {
        expect(isLocalNetworkAddress(ok), isTrue, reason: ok);
      }
      for (final no in ['8.8.8.8', '172.32.0.1', '172.15.0.1', '127.0.0.1', '169.254.1.1', 'abc', '1.2.3']) {
        expect(isLocalNetworkAddress(no), isFalse, reason: no);
      }
    });

    test('the text a phone sends is read from the form, or as it is, and a huge or empty one is refused', () {
      expect(tvPairText('text=vless%3A%2F%2Fabc%40h%3A1%23x'), 'vless://abc@h:1#x');
      expect(tvPairText('text=a+b'), 'a b');
      expect(tvPairText('vless://plain'), 'vless://plain');
      expect(tvPairText('text='), isNull);
      expect(tvPairText('   '), isNull);
      expect(tvPairText('x' * (64 * 1024 + 1)), isNull);
    });

    test('the page of the phone has a box, and says when it was sent', () {
      expect(tvPairPage(), contains('<textarea'));
      expect(tvPairPage(), isNot(contains('class="ok"')));
      expect(tvPairPage(sent: true), contains('class="ok"'));
      expect(tvPairPage(failed: true), contains('class="bad"'));
    });

    test('a phone with the address sends a text and the television gets it; any other path gets nothing', () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final got = <String>[];
        final server = TvPairServer(maxTexts: 2);
        final url = await server.start(got.add);
        // A computer with no private network address (a runner in a container) cannot give one: nothing to try.
        if (url == null) return;
        addTearDown(server.stop);
        final uri = Uri.parse(url.replaceFirst(RegExp(r'//[^:]+:'), '//127.0.0.1:'));
        final client = HttpClient();
        addTearDown(() => client.close(force: true));

        Future<(int, String)> send(Uri to, String method, [String? body]) async {
          final req = await client.openUrl(method, to);
          if (body != null) {
            req.headers.contentType = ContentType('application', 'x-www-form-urlencoded');
            req.write(body);
          }
          final res = await req.close();
          return (res.statusCode, await res.transform(const SystemEncoding().decoder).join());
        }

        final page = await send(uri, 'GET');
        expect(page.$1, 200);
        expect(page.$2, contains('<textarea'));
        // A wrong secret is not found.
        expect((await send(uri.replace(path: '/wrong'), 'GET')).$1, 404);
        expect((await send(uri.replace(path: '/'), 'GET')).$1, 404);
        expect((await send(uri, 'POST', 'text=vless%3A%2F%2Fone')).$1, 200);
        expect((await send(uri, 'POST', 'text=https%3A%2F%2Fsub.example%2Fx')).$1, 200);
        // Past the limit of the session, and an empty text: refused.
        expect((await send(uri, 'POST', 'text=third')).$1, 400);
        expect((await send(uri, 'POST', 'text=')).$1, 400);
        expect(got, ['vless://one', 'https://sub.example/x']);
        await server.stop();
        await expectLater(send(uri, 'GET'), throwsA(anything));
      }, _RealHttp());
    });

    testWidgets('the page shows the address and the steps, and a text that comes is handed over', (tester) async {
      _television(tester);
      final server = _FakeServer();
      final got = <String>[];
      await tester.pumpWidget(_app(TvPairPage(
        server: server,
        onText: (context, text) async => got.add(text),
      )));
      // One pump for the page to ask the server, one for it to draw the answer.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Add from your phone'), findsWidgets);
      expect(find.byKey(const ValueKey('pair-url')), findsOneWidget);
      expect(find.byKey(const ValueKey('pair-qr:http://192.168.1.50:5000/secret')), findsOneWidget);
      expect(find.text('Waiting for your phone…'), findsOneWidget);
      server.push('vless://hello');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(got, ['vless://hello']);
      expect(find.text('Received from your phone: 1'), findsOneWidget);
      // Leaving the page stops listening.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      expect(server.stopped, isTrue);
    });

    testWidgets('with no local network the page says so', (tester) async {
      _television(tester);
      await tester.pumpWidget(_app(TvPairPage(server: _FakeServer(url: null), onText: (c, t) async {})));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('not on a local network'), findsOneWidget);
    });
  });
}

class _FakeServer extends TvPairServer {
  _FakeServer({this.url = 'http://192.168.1.50:5000/secret'});

  @override
  final String? url;
  void Function(String text)? _on;
  var stopped = false;

  @override
  Future<String?> start(void Function(String text) onText) async {
    _on = onText;
    return url;
  }

  void push(String text) => _on?.call(text);

  @override
  Future<void> stop() async => stopped = true;
}
