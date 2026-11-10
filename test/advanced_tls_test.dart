import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/proxy_config.dart';
import 'package:kumo/l10n/strings.dart';
import 'package:kumo/screens/edit_config_page.dart';

const _plain =
    'vless://11111111-1111-1111-1111-111111111111@v.example.com:443?security=tls&sni=v.example.com&type=ws&path=%2F#plain';

/// [_plain] with more parameters (before its name, which would take them in otherwise).
String _with(String extra) => _plain.replaceFirst('#plain', '&$extra#plain');

Map<String, dynamic> _tls(ProxyConfig c) =>
    (c.xrayOutbound!['streamSettings'] as Map<String, dynamic>)['tlsSettings'] as Map<String, dynamic>;

void main() {
  group('the TLS options that only Xray has', () {
    test('cipher suites and the unsafe fingerprint reach Xray, and make the server run on it', () {
      final c = parseLink(_with('fp=unsafe&alpn=http%2F1.1&cipherSuites=TLS_AES_128_GCM_SHA256%3ATLS_AES_256_GCM_SHA384'))!;
      expect(c.preferXray, isTrue);
      final tls = _tls(c);
      expect(tls['fingerprint'], 'unsafe');
      expect(tls['alpn'], ['http/1.1']);
      expect(tls['cipherSuites'], 'TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384');
    });

    test('a server with none of them stays as it was', () {
      final c = parseLink(_with('fp=chrome'))!;
      expect(c.preferXray, isFalse);
      expect(_tls(c).containsKey('cipherSuites'), isFalse);
      expect(_tls(c)['fingerprint'], 'chrome');
    });

    test('either of the two alone is enough', () {
      expect(parseLink(_with('fp=unsafe'))!.preferXray, isTrue);
      expect(parseLink(_with('cipherSuites=TLS_AES_128_GCM_SHA256'))!.preferXray, isTrue);
    });
  });

  group('the form', () {
    Widget host(void Function(String?) got) => MaterialApp(
          supportedLocales: S.supportedLocales,
          localizationsDelegates: const [
            S.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async => got(await Navigator.push<String>(
                      context, MaterialPageRoute(builder: (_) => EditConfigPage(config: parseLink(_plain)!)))),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );

    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 3200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // The texts of the app are loaded before the first page is drawn.
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Anti-filter settings (Xray)'));
      await tester.pumpAndSettle();
    }

    testWidgets('what is typed goes into the link, the mask in its short form', (tester) async {
      String? link;
      await tester.pumpWidget(host((v) => link = v));
      await open(tester);
      await tester.enterText(find.byKey(const ValueKey('anti:alpn')), 'http/1.1');
      await tester.enterText(find.byKey(const ValueKey('anti:fm')), '{ "tcp": [ {"type": "fragment"} ] }');
      await tester.enterText(find.byKey(const ValueKey('anti:cipherSuites')), 'TLS_AES_128_GCM_SHA256');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(link, isNotNull);
      final q = Uri.parse(link!).queryParameters;
      expect(q['alpn'], 'http/1.1');
      expect(q['cipherSuites'], 'TLS_AES_128_GCM_SHA256');
      expect(jsonDecode(q['fm']!), {'tcp': [{'type': 'fragment'}]});
      expect(q['fm']!.contains(' '), isFalse);
      // The new link is one the app runs on Xray.
      expect(parseLink(link!)!.preferXray, isTrue);
    });

    testWidgets('a mask that is not a JSON object is refused and the page stays', (tester) async {
      String? link;
      await tester.pumpWidget(host((v) => link = v));
      await open(tester);
      await tester.enterText(find.byKey(const ValueKey('anti:fm')), 'not json');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('The final mask must be a JSON object.'), findsOneWidget);
      expect(link, isNull);
    });

    testWidgets('left empty, nothing of it is in the link', (tester) async {
      String? link;
      await tester.pumpWidget(host((v) => link = v));
      await open(tester);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final q = Uri.parse(link!).queryParameters;
      expect(q.containsKey('fm') || q.containsKey('cipherSuites') || q.containsKey('alpn'), isFalse);
    });
  });
}
