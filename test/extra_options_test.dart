import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/extra_options.dart';
import 'package:kumo/core/proxy_config.dart';
import 'package:kumo/core/singbox_config.dart' show parseExtraJson;
import 'package:kumo/l10n/strings.dart';
import 'package:kumo/screens/edit_config_page.dart';
import 'package:kumo/screens/extra_options_sheet.dart';

ExtraOption _opt(List<ExtraOption> all, String id) => all.firstWhere((o) => o.id == id);

void main() {
  group('the options as a map', () {
    test('a value is set, read and taken away again, and the branch goes with the last of it', () {
      final nodelay = _opt(xrayExtraOptions, 'sockopt.tcpNoDelay');
      var json = withOption(<String, dynamic>{}, nodelay, true);
      expect(json, {'sockopt': {'tcpNoDelay': true}});
      expect(readOption(json, nodelay), true);
      json = withOption(json, nodelay, false);
      expect(json, isEmpty);
      expect(readOption(json, nodelay), isNull);
      expect(encodeExtra(json), '');
    });

    test('what the fields do not know is kept', () {
      final idle = _opt(xrayExtraOptions, 'sockopt.tcpKeepAliveIdle');
      final own = <String, dynamic>{
        'sockopt': {'mark': 255},
        'other': {'a': 1},
      };
      final json = withOption(own, idle, 30);
      expect(json, {
        'sockopt': {'mark': 255, 'tcpKeepAliveIdle': 30},
        'other': {'a': 1},
      });
      expect(withOption(json, idle, null), own);
      // the map that came in is not changed
      expect(own['sockopt'], {'mark': 255});
    });

    test('a text is trimmed and an empty one is no value', () {
      final keep = _opt(singboxExtraOptions, 'tcp_keep_alive');
      expect(withOption(<String, dynamic>{}, keep, ' 30s '), {'tcp_keep_alive': '30s'});
      expect(withOption({'tcp_keep_alive': '30s'}, keep, '  '), isEmpty);
    });

    test('what is kept is a JSON object the core takes', () {
      var json = <String, dynamic>{};
      json = withOption(json, _opt(singboxExtraOptions, 'tcp_keep_alive'), '5m');
      json = withOption(json, _opt(singboxExtraOptions, 'udp_fragment'), true);
      expect(parseExtraJson(encodeExtra(json)), {'tcp_keep_alive': '5m', 'udp_fragment': true});
    });

    test('the ready-made final mask is the one the app uses to split the hello', () {
      final mask = jsonDecode(fragmentFinalMask()) as Map;
      final fragment = (mask['tcp'] as List).single as Map;
      expect(fragment['type'], 'fragment');
      expect((fragment['settings'] as Map)['packets'], 'tlshello');
    });
  });

  group('the sheet', () {
    Widget host(String initial, List<ExtraOption> options, void Function(String?) got) => MaterialApp(
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
                  onPressed: () async => got(await editExtraOptions(context,
                      title: 'Extra',
                      description: 'Fields',
                      jsonDescription: 'JSON',
                      initial: initial,
                      options: options)),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );

    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('a field and a switch give the JSON, and what was there before stays', (tester) async {
      String? got;
      await tester.pumpWidget(host('{"sockopt":{"mark":255}}', xrayExtraOptions, (v) => got = v));
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('xo:sockopt.tcpNoDelay:0')));
      await tester.enterText(find.byKey(const ValueKey('xo:sockopt.tcpKeepAliveIdle:0')), '30');
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(jsonDecode(got!), {
        'sockopt': {'mark': 255, 'tcpNoDelay': true, 'tcpKeepAliveIdle': 30},
      });
    });

    testWidgets('the fields show what is already set, and Save with nothing set gives an empty text', (tester) async {
      String? got;
      await tester.pumpWidget(host('{"tcp_keep_alive":"5m"}', singboxExtraOptions, (v) => got = v));
      await open(tester);
      expect(tester.widget<TextFormField>(find.byKey(const ValueKey('xo:tcp_keep_alive:0'))).initialValue, '5m');
      await tester.enterText(find.byKey(const ValueKey('xo:tcp_keep_alive:0')), '');
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(got, '');
    });

    testWidgets('Cancel gives nothing', (tester) async {
      String? got = 'unchanged';
      await tester.pumpWidget(host('', singboxExtraOptions, (v) => got = v));
      await open(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(got, isNull);
    });
  });

  group('the final mask of a server', () {
    const link = 'vless://11111111-1111-1111-1111-111111111111@v.example.com:443'
        '?security=tls&sni=v.example.com&type=ws&path=%2F#plain';

    testWidgets('a button fills in the mask that splits the hello, no JSON to write', (tester) async {
      String? saved;
      await tester.pumpWidget(MaterialApp(
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
                onPressed: () async => saved = await Navigator.push<String>(
                    context, MaterialPageRoute(builder: (_) => EditConfigPage(config: parseLink(link)!))),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      tester.view.physicalSize = const Size(900, 3200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Anti-filter settings (Xray)'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('anti:fm-fragment')));
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final fm = Uri.parse(saved!).queryParameters['fm']!;
      expect(jsonDecode(fm), jsonDecode(fragmentFinalMask()));
      expect(parseLink(saved!)!.preferXray, isTrue);
    });
  });
}
