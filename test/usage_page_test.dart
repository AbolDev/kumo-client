import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/usage_stats.dart';
import 'package:kumo/l10n/extra.dart';
import 'package:kumo/l10n/strings.dart';
import 'package:kumo/core/vpn_channel.dart';
import 'package:kumo/screens/usage_page.dart';
import 'package:kumo/state/app_state.dart';

Future<void> _show(WidgetTester tester, AppState state, Locale locale,
    {bool rtl = false}) async {
  tester.view.physicalSize = const Size(390 * 3, 844 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    locale: locale,
    supportedLocales: [locale],
    builder: (context, child) =>
        Directionality(textDirection: rtl ? TextDirection.rtl : TextDirection.ltr, child: child!),
    home: UsagePage(state: state),
  ));
  await tester.pump();
}

AppState _filled() {
  final s = AppState();
  final now = DateTime.now();
  for (var i = 0; i < 40; i++) {
    final d = dayKey(DateTime(now.year, now.month, now.day - i));
    if (i % 3 != 2) s.dayUsage[d] = [i * 9000000, i * 700000, i * 120];
  }
  s.serverUsage['Germany very long server name that must be cut with an ellipsis'] =
      [800000000, 90000000, 7300, DateTime.now().millisecondsSinceEpoch];
  s.serverUsage['Old total only'] = [0, 0, 0, 0, 5000000];
  s.serverUsage['Japan'] = [30000000, 2000000, 600, 1];
  for (var i = 0; i < 120; i++) {
    s.downHistory.add(i * 20000);
    s.upHistory.add(i * 3000);
  }
  s.traffic.value = const Traffic(2500, 180000, 4000000, 90000000);
  return s;
}

void main() {
  // The material delegates have no Persian, so the language is forced and the page is shown
  // right-to-left by hand.
  for (final lang in const ['en', 'fa', 'ar', 'ru']) {
    testWidgets('page with data fits a phone ($lang)', (tester) async {
      S.forcedLanguage = lang;
      addTearDown(() => S.forcedLanguage = null);
      await _show(tester, _filled(), const Locale('en'), rtl: lang == 'fa' || lang == 'ar');
      expect(tester.takeException(), isNull);
      // Every period redraws without overflow.
      for (final p in ['usePeriod30', 'usePeriodAll', 'usePeriodToday', 'usePeriod7']) {
        await tester.tap(find.text(trFor(lang, p)).first);
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -2000));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('every part follows the traffic samples without reopening', (tester) async {
    final state = AppState();
    final today = dayKey(DateTime.now());
    state.dayUsage[today] = [1048576, 0, 60]; // 1.0 MB, 1 min
    state.serverUsage['Live'] = [1048576, 0, 60, DateTime.now().millisecondsSinceEpoch];
    await _show(tester, state, const Locale('en'));
    expect(find.text('1.0 MB'), findsWidgets);
    expect(find.text('1 min'), findsWidgets);

    // What _onTraffic does once a second: add to the totals, then publish the sample.
    state.dayUsage[today] = [3 * 1048576, 0, 125];
    state.serverUsage['Live'] = [3 * 1048576, 0, 125, DateTime.now().millisecondsSinceEpoch];
    state.traffic.value = const Traffic(0, 5000, 0, 3 * 1048576);
    await tester.pump();
    expect(find.text('1.0 MB'), findsNothing);
    expect(find.text('3.0 MB'), findsWidgets);
    expect(find.text('2 min'), findsWidgets);
    expect(find.textContaining('4 KB/s'), findsWidgets);
  });

  testWidgets('empty page shows the hint, not charts', (tester) async {
    await _show(tester, AppState(), const Locale('en'));
    expect(tester.takeException(), isNull);
    expect(find.text('No usage yet'), findsOneWidget);
  });
}
