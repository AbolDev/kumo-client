import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/app_icon.dart';
import 'package:kumo/core/desktop_vpn.dart';
import 'package:kumo/screens/privacy_page.dart';
import 'package:kumo/state/app_state.dart';
import 'package:kumo/widgets/hold_to_confirm.dart';

Widget _app(Widget home) => MaterialApp(home: home);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('kumo-disguise');
    DesktopVpn.dataDirOverride = dir.path;
  });
  tearDown(() {
    DesktopVpn.dataDirOverride = null;
    dir.deleteSync(recursive: true);
  });

  group('hold to confirm', () {
    testWidgets('a tap, or a hold that is let go early, confirms nothing; a whole hold confirms once', (tester) async {
      var confirmed = 0;
      await tester.pumpWidget(_app(Scaffold(
          body: Center(child: SizedBox(width: 240, child: HoldToConfirm(label: 'Hold', onConfirmed: () => confirmed++))))));
      // A tap.
      await tester.tap(find.text('Hold'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(confirmed, 0);
      // Held for two seconds of three, then let go: the bar empties and nothing happens.
      final g = await tester.startGesture(tester.getCenter(find.text('Hold')));
      await tester.pump(const Duration(seconds: 2));
      final half = tester.getSize(find.byKey(const ValueKey('hold-fill'))).width;
      expect(half, greaterThan(100));
      await g.up();
      await tester.pump(const Duration(milliseconds: 400));
      expect(confirmed, 0);
      expect(tester.getSize(find.byKey(const ValueKey('hold-fill'))).width, 0);
      // Held for the whole time.
      final h = await tester.startGesture(tester.getCenter(find.text('Hold')));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(confirmed, 0);
      await tester.pump(const Duration(milliseconds: 1100));
      expect(confirmed, 1);
      await h.up();
      await tester.pump(const Duration(seconds: 4));
      expect(confirmed, 1);
    });

    testWidgets('the long press of a screen reader confirms', (tester) async {
      var confirmed = 0;
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_app(Scaffold(body: HoldToConfirm(label: 'Hold', onConfirmed: () => confirmed++))));
      tester.semantics.performAction(find.bySemanticsLabel('Hold'), SemanticsAction.longPress);
      await tester.pump();
      expect(confirmed, 1);
      handle.dispose();
    });
  });

  group('the icons', () {
    test('the icons of the picker have a picture; a disguise and "hidden" do not', () {
      expect(AppIcon.isPicture('teal_night'), isTrue);
      expect(AppIcon.isPicture('classic'), isTrue);
      for (final d in AppIcon.disguises) {
        expect(AppIcon.isPicture(d), isFalse, reason: d);
      }
      expect(AppIcon.isPicture(AppIcon.hidden), isFalse);
      expect(AppIcon.disguises.length, 6);
    });

    test('an icon that is not known is the default one', () {
      expect(AppIcon.normalize('nothing'), AppIcon.defaultId);
      expect(AppIcon.normalize(null), AppIcon.defaultId);
      expect(AppIcon.normalize('mint'), 'mint');
    });
  });

  group('what is kept', () {
    test('the name of the disguise and the erase code are read from the settings and written back', () async {
      await DesktopVpn.instance.writeFile('settings.json', jsonEncode({'disguiseName': 'Calculator', 'panicCode': true}));
      final state = AppState();
      await state.loadStoredForTest();
      expect(state.disguiseName, 'Calculator');
      expect(state.panicCode, isTrue);
      state.setPanicCode(false);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final saved = jsonDecode((await DesktopVpn.instance.readFile('settings.json'))!) as Map;
      expect(saved['panicCode'], false);
      expect(saved['disguiseName'], 'Calculator');
    });

    test('the erase code is off by default', () {
      expect(AppState().panicCode, isFalse);
      expect(AppState().disguiseName, isEmpty);
    });

    test('an erase of the data folder leaves only the settings it was given', () async {
      final sub = Directory('${dir.path}${Platform.pathSeparator}subcache')..createSync();
      File('${sub.path}${Platform.pathSeparator}a.json').writeAsStringSync('{}');
      File('${dir.path}${Platform.pathSeparator}servers.json').writeAsStringSync('{"manual":["vless://x"]}');
      File('${dir.path}${Platform.pathSeparator}servers.json.bak').writeAsStringSync('old');
      File('${dir.path}${Platform.pathSeparator}settings.json').writeAsStringSync('{"proxyUser":"me"}');
      await DesktopVpn.instance.wipeData('{"appIcon":"teal","panicCode":false}');
      final left = [for (final e in dir.listSync()) e.uri.pathSegments.where((s) => s.isNotEmpty).last];
      expect(left, ['settings.json']);
      expect(File('${dir.path}${Platform.pathSeparator}settings.json').readAsStringSync(), contains('"appIcon":"teal"'));
      expect(File('${dir.path}${Platform.pathSeparator}settings.json').readAsStringSync(), isNot(contains('proxyUser')));
    });
  });

  group('the page', () {
    testWidgets('on a phone it shows the looks, the hiding and the erase; on a computer only the erase', (tester) async {
      await tester.pumpWidget(_app(PrivacyPage(state: AppState(), android: true)));
      expect(find.byKey(const ValueKey('look:kumo')), findsOneWidget);
      for (final id in ['d_calc', 'd_notes', 'd_clock', 'd_weather', 'd_calendar', 'd_files', 'custom']) {
        expect(find.byKey(ValueKey('look:$id')), findsOneWidget, reason: id);
      }
      expect(find.text('Calculator'), findsOneWidget);
      expect(find.byKey(const ValueKey('hide-switch')), findsOneWidget);
      expect(find.byKey(const ValueKey('code-switch')), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const ValueKey('erase-button')), 200);
      expect(find.byKey(const ValueKey('erase-button')), findsOneWidget);

      await tester.pumpWidget(_app(PrivacyPage(state: AppState(), android: false)));
      await tester.pump();
      expect(find.byKey(const ValueKey('disguise-android-only')), findsOneWidget);
      expect(find.byKey(const ValueKey('look:d_calc')), findsNothing);
      expect(find.byKey(const ValueKey('code-switch')), findsNothing);
      expect(find.byKey(const ValueKey('erase-button')), findsOneWidget);
    });

    testWidgets('a look gives the card of the recent apps its name', (tester) async {
      final state = AppState();
      await tester.pumpWidget(_app(PrivacyPage(state: state, android: true)));
      await tester.tap(find.byKey(const ValueKey('look:d_calc')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(state.disguiseName, 'Calculator');
    });

    testWidgets('hiding the icon asks first, and says how to open the app', (tester) async {
      final state = AppState();
      await tester.pumpWidget(_app(PrivacyPage(state: state, android: true)));
      await tester.tap(find.byKey(const ValueKey('hide-switch')));
      await tester.pumpAndSettle();
      expect(find.text('Hide Kumo?'), findsOneWidget);
      expect(find.textContaining('*#*#5866#*#*'), findsWidgets);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(state.disguiseName, isEmpty);
    });

    testWidgets('the erase code is only turned on after a question, and off again at once', (tester) async {
      final state = AppState();
      await tester.pumpWidget(_app(PrivacyPage(state: state, android: true)));
      await tester.scrollUntilVisible(find.byKey(const ValueKey('code-switch')), 200);
      await tester.tap(find.byKey(const ValueKey('code-switch')));
      await tester.pumpAndSettle();
      expect(find.text('Turn on the erase code?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(state.panicCode, isFalse);
      await tester.tap(find.byKey(const ValueKey('code-switch')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('code-yes')));
      await tester.pumpAndSettle();
      expect(state.panicCode, isTrue);
      await tester.tap(find.byKey(const ValueKey('code-switch')));
      await tester.pumpAndSettle();
      expect(state.panicCode, isFalse);
    });

    testWidgets('an erase takes a question and a hold: neither a tap nor cancel erases', (tester) async {
      var erased = 0;
      await tester.pumpWidget(_app(PrivacyPage(state: AppState(), android: false, erase: () async => erased++)));
      await tester.tap(find.byKey(const ValueKey('erase-button')));
      await tester.pumpAndSettle();
      expect(find.text('Erase everything?'), findsOneWidget);
      // A tap on the hold button does nothing.
      await tester.tap(find.byKey(const ValueKey('hold-erase')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(erased, 0);
      expect(find.text('Erase everything?'), findsOneWidget);
      // Cancel closes it and nothing is erased.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(erased, 0);
      // Asked again and held for the whole time: erased once.
      await tester.tap(find.byKey(const ValueKey('erase-button')));
      await tester.pumpAndSettle();
      final g = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('hold-erase'))));
      await tester.pump(const Duration(seconds: 2));
      expect(erased, 0);
      await tester.pump(const Duration(milliseconds: 1200));
      await tester.pumpAndSettle();
      await g.up();
      await tester.pump();
      expect(erased, 1);
    });
  });
}
