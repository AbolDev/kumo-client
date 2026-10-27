import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/proxy_config.dart';
import 'package:kumo/l10n/strings.dart';
import 'package:kumo/screens/collector_info_page.dart';
import 'package:kumo/state/app_state.dart';

const _links = [
  'vless://11111111-1111-1111-1111-111111111111@a.example.com:443?security=tls&sni=a.example.com&allowInsecure=1&type=tcp#a',
  'vless://22222222-2222-2222-2222-222222222222@b.example.com:443?security=tls&sni=b.example.com&type=tcp#b',
];

Future<AppState> _show(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390 * 3, 844 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final state = AppState();
  state.collector.configs.addAll(parseLinks(_links, secure: !state.collectorAllowInsecure));
  state.collectorSource = 'https://cdn.jsdelivr.net/gh/x/y@main/All.txt';
  state.collector.updatedAt = DateTime(2026, 10, 27, 9, 5).millisecondsSinceEpoch;
  await tester.pumpWidget(MaterialApp(
    locale: const Locale('en'),
    supportedLocales: S.supportedLocales,
    localizationsDelegates: const [
      S.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    home: CollectorInfoPage(state: state),
  ));
  await tester.pump();
  return state;
}

void main() {
  testWidgets('shows the source, the date and how many servers skip the check', (tester) async {
    await _show(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('cdn.jsdelivr.net'), findsOneWidget);
    expect(find.text('2026-10-27 09:05'), findsOneWidget);
    expect(find.text('1 of 2 servers ask not to be checked.'), findsOneWidget);
  });

  testWidgets('the switch is off, and turning it on brings the option back to those servers',
      (tester) async {
    final state = await _show(tester);
    final tile = find.byType(SwitchListTile);
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
    expect((state.collector.configs.first.outbound['tls'] as Map)['insecure'], anyOf(isNull, false));

    await tester.runAsync(() async {
      await state.setCollectorInsecure(true);
    });
    await tester.pump();
    expect(state.collectorAllowInsecure, isTrue);
    expect((state.collector.configs.first.outbound['tls'] as Map)['insecure'], true);
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);

    await tester.runAsync(() async {
      await state.setCollectorInsecure(false);
    });
    await tester.pump();
    expect((state.collector.configs.first.outbound['tls'] as Map)['insecure'], anyOf(isNull, false));
    expect(state.collector.configs.map((c) => c.link), _links); // the saved links never change
  });
}
