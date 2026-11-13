import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/l10n/strings.dart';
import 'package:kumo/screens/routing_rules_page.dart';
import 'package:kumo/state/app_state.dart';

const _open = '“', _close = '”';

/// [rtl] shows the page right-to-left by hand: the material delegates have no Persian, so the language is
/// forced (see usage_page_test).
Widget _host(AppState state, {bool rtl = false, Brightness brightness = Brightness.light}) => MaterialApp(
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFF0E9F8E), brightness: brightness),
      builder: (context, child) =>
          Directionality(textDirection: rtl ? TextDirection.rtl : TextDirection.ltr, child: child!),
      supportedLocales: S.supportedLocales,
      localizationsDelegates: const [
        S.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      // The change is made on the options directly: saving them and restarting a connection belong to the app.
      home: RoutingRulesPage(state: state, update: (change) async => change(state.net)),
    );

AppState _seeded() {
  final s = AppState();
  s.net.blockRules = ['keyword:ads'];
  s.net.proxyRules = ['service:telegram'];
  s.net.directRules = ['10.0.0.0/8', 'service:telegram'];
  return s;
}

void _size(WidgetTester tester, [Size size = const Size(900, 2400)]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('before the first rule it teaches: the order, and an example for each list', (tester) async {
    _size(tester);
    await tester.pumpWidget(_host(AppState()));
    await tester.pumpAndSettle();
    expect(find.text('No rules yet.'), findsOneWidget);
    expect(find.text('How the rules are applied'), findsOneWidget);
    // The three lists, in the order they are applied.
    expect(find.text('1. Always blocked'), findsOneWidget);
    expect(find.text('2. Always through the VPN'), findsOneWidget);
    expect(find.text('3. Always direct'), findsOneWidget);
    expect(find.textContaining('For example your banking app'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsOneWidget);
    // No search box for an empty page.
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('a rule is typed, understood as it is typed, and lands in the chosen list', (tester) async {
    _size(tester);
    final state = AppState();
    await tester.pumpWidget(_host(state));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.text('What should happen to it?'), findsOneWidget);
    await tester.tap(find.text('Block'));
    await tester.pump();
    // (Once under the page's list, once in the sheet.)
    expect(find.text('Cut off: these never connect.'), findsNWidgets(2));

    await tester.enterText(find.byKey(const ValueKey('rl-text')), 'ads.example.com');
    await tester.pump();
    expect(find.text('Website and its sub-sites: ads.example.com'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('rl-add')));
    await tester.pump();
    expect(state.net.blockRules, ['ads.example.com']);
    expect(find.text('Added: ads.example.com'), findsOneWidget);

    // A bare number is a port; the same rule twice is said to be there already.
    await tester.enterText(find.byKey(const ValueKey('rl-text')), '443');
    await tester.pump();
    expect(find.text('Port: port:443'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('rl-text')), 'ads.example.com');
    await tester.pump();
    expect(find.text('Already in ${_open}Always blocked$_close.'), findsOneWidget);
    // Something that is no rule says so, and cannot be added.
    await tester.enterText(find.byKey(const ValueKey('rl-text')), 'not a rule!');
    await tester.pump();
    expect(find.textContaining('Not understood'), findsOneWidget);

    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('ads.example.com'), findsOneWidget);
    expect(find.text('1. Always blocked'), findsOneWidget);
  });

  testWidgets('services are chosen from a list in groups, with a search, and added to the list', (tester) async {
    _size(tester);
    final state = AppState();
    await tester.pumpWidget(_host(state));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Popular services'));
    await tester.pumpAndSettle();
    expect(find.text('Choose services'), findsOneWidget);
    expect(find.text('Social and messages'), findsOneWidget);
    expect(find.text('Choose what to add'), findsOneWidget);
    await tester.tap(find.text('Telegram'));
    await tester.tap(find.text('YouTube'));
    await tester.pump();
    expect(find.text('Add 2'), findsOneWidget);
    // The search narrows the list.
    await tester.enterText(find.byType(TextField), 'spot');
    await tester.pump();
    expect(find.text('Spotify'), findsOneWidget);
    expect(find.text('Telegram'), findsNothing);
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    await tester.tap(find.text('Add 2'));
    await tester.pumpAndSettle();
    expect(state.net.directRules, ['service:telegram', 'service:youtube']);
    expect(find.text('Added 2 rules'), findsOneWidget);
  });

  testWidgets('the rules are in their lists; one that another list overrides says so', (tester) async {
    _size(tester);
    await tester.pumpWidget(_host(_seeded()));
    await tester.pumpAndSettle();
    expect(find.text('keyword:ads'), findsOneWidget);
    expect(find.text('10.0.0.0/8'), findsOneWidget);
    // Telegram is in two lists.
    expect(find.text('Telegram'), findsNWidgets(2));
    expect(find.text('Overridden: it is also in ${_open}Always through the VPN$_close, which comes first.'), findsOneWidget);
    expect(find.text('Names that contain it'), findsOneWidget);
  });

  testWidgets('removing a rule can be undone', (tester) async {
    _size(tester);
    final state = _seeded();
    await tester.pumpWidget(_host(state));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Remove').first);
    await tester.pumpAndSettle();
    expect(state.net.blockRules, isEmpty);
    expect(find.text('Removed: keyword:ads'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(state.net.blockRules, ['keyword:ads']);
    expect(find.text('keyword:ads'), findsOneWidget);
  });

  testWidgets('swiping a rule away removes it', (tester) async {
    _size(tester);
    final state = _seeded();
    await tester.pumpWidget(_host(state));
    await tester.pumpAndSettle();
    await tester.drag(find.text('10.0.0.0/8'), const Offset(-700, 0));
    await tester.pumpAndSettle();
    expect(state.net.directRules, ['service:telegram']);
    expect(find.text('Removed: 10.0.0.0/8'), findsOneWidget);
  });

  testWidgets('a rule can be moved to another list', (tester) async {
    _size(tester);
    final state = _seeded();
    await tester.pumpWidget(_host(state));
    await tester.pumpAndSettle();
    await tester.tap(find.text('10.0.0.0/8'));
    await tester.pumpAndSettle();
    expect(find.text('Move to ${_open}Always blocked$_close'), findsOneWidget);
    expect(find.text('Move to ${_open}Always direct$_close'), findsNothing);
    await tester.tap(find.text('Move to ${_open}Always through the VPN$_close'));
    await tester.pumpAndSettle();
    expect(state.net.directRules, ['service:telegram']);
    expect(state.net.proxyRules, ['service:telegram', '10.0.0.0/8']);
    expect(find.text('Moved to ${_open}Always through the VPN$_close'), findsOneWidget);
  });

  testWidgets('the test says what happens to a name, and which other rules would also match', (tester) async {
    _size(tester);
    await tester.pumpWidget(_host(_seeded()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Test what happens'));
    await tester.pumpAndSettle();
    expect(find.text('Type something to see what would happen to it.'), findsOneWidget);

    final field = find.byKey(const ValueKey('rl-test-text'));
    await tester.enterText(field, 'https://web.telegram.org/k');
    await tester.pump();
    expect(find.text('Goes through the VPN'), findsOneWidget);
    expect(find.text('Because of this rule:'), findsOneWidget);
    expect(find.text('Also matches, but comes later:'), findsOneWidget);

    await tester.enterText(field, 'cheap-ads.net');
    await tester.pump();
    expect(find.text('Blocked'), findsOneWidget);
    expect(find.text('Also matches, but comes later:'), findsNothing);

    await tester.enterText(field, '10.9.8.7');
    await tester.pump();
    expect(find.text('Goes direct, without the VPN'), findsOneWidget);

    await tester.enterText(field, 'nothing.example');
    await tester.pump();
    expect(find.text('No rule matches'), findsOneWidget);
    expect(find.textContaining('Your other settings decide'), findsOneWidget);
  });

  testWidgets('with many rules a search appears; what is typed can be added from there', (tester) async {
    _size(tester);
    final state = AppState();
    state.net.blockRules = ['keyword:ads', 'ads.example.com'];
    state.net.proxyRules = ['service:telegram', 'service:youtube'];
    state.net.directRules = ['bank.ir', '10.0.0.0/8'];
    await tester.pumpWidget(_host(state));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'bank');
    await tester.pump();
    expect(find.text('bank.ir'), findsOneWidget);
    expect(find.text('10.0.0.0/8'), findsNothing);
    // A list with nothing found is left out.
    expect(find.text('1. Always blocked'), findsNothing);
    expect(find.text('3. Always direct'), findsOneWidget);
    // Services are found by their websites.
    await tester.enterText(find.byType(TextField), 'youtu.be');
    await tester.pump();
    expect(find.text('YouTube'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'zzz.org');
    await tester.pump();
    expect(find.text('No rule matches ${_open}zzz.org$_close.'), findsOneWidget);
    expect(find.text('Add ${_open}zzz.org$_close as a rule:'), findsOneWidget);
    await tester.tap(find.text('Block'));
    await tester.pumpAndSettle();
    expect(state.net.blockRules, ['keyword:ads', 'ads.example.com', 'zzz.org']);
  });

  testWidgets('rules for apps warn when the tunnel is off, and only then', (tester) async {
    _size(tester);
    final state = AppState();
    state.net.blockRules = ['app:com.annoying'];
    state.net.tun = false;
    await tester.pumpWidget(_host(state));
    await tester.pumpAndSettle();
    expect(find.textContaining('that is off now'), findsOneWidget);
    state.net.tun = true;
    await tester.pumpWidget(_host(state));
    await tester.pumpAndSettle();
    expect(find.textContaining('that is off now'), findsNothing);
  });

  testWidgets('rules can be imported from a text, and the page says what was found first', (tester) async {
    _size(tester);
    final state = AppState();
    await tester.pumpWidget(_host(state));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import rules'));
    await tester.pumpAndSettle();
    expect(find.text('Nothing to import yet.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '[block]\nads.example.com\n[proxy]\nservice:telegram\nbad line!!');
    await tester.pump();
    expect(find.text('2 rules found: 1 blocked, 1 through the VPN, 0 direct.'), findsOneWidget);
    expect(find.text('1 lines are not rules and will be skipped.'), findsOneWidget);
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();
    expect(state.net.blockRules, ['ads.example.com']);
    expect(state.net.proxyRules, ['service:telegram']);
    expect(find.text('Added 2 rules'), findsOneWidget);
    // Importing the same again finds nothing new.
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import rules'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '[block]\nads.example.com');
    await tester.pump();
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();
    expect(find.text('These rules are all here already.'), findsOneWidget);
  });

  testWidgets('all the rules can be copied, and all can be removed with a way back', (tester) async {
    _size(tester);
    final state = _seeded();
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(_host(state));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy all rules'));
    await tester.pumpAndSettle();
    expect(find.text('The rules are copied.'), findsOneWidget);
    expect(copied, allOf(contains('[block]\nkeyword:ads\n'), contains('[proxy]\nservice:telegram\n'), contains('[direct]\n10.0.0.0/8\nservice:telegram\n')));

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove all rules'));
    await tester.pumpAndSettle();
    expect(state.net.blockRules, isEmpty);
    expect(state.net.proxyRules, isEmpty);
    expect(state.net.directRules, isEmpty);
    expect(find.text('Removed 4 rules'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(state.net.blockRules, ['keyword:ads']);
    expect(state.net.proxyRules, ['service:telegram']);
    expect(state.net.directRules, ['10.0.0.0/8', 'service:telegram']);
  });

  for (final lang in ['en', 'fa']) {
    for (final brightness in Brightness.values) {
      testWidgets('it fits a narrow screen in $lang, ${brightness.name}', (tester) async {
        S.forcedLanguage = lang;
        addTearDown(() => S.forcedLanguage = null);
        _size(tester, const Size(320, 640));
        final state = _seeded();
        state.net.blockRules = ['keyword:ads', 'app:com.annoying', 'ads.example.com'];
        state.net.proxyRules = ['service:telegram', 'service:youtube'];
        state.net.directRules = ['10.0.0.0/8', 'service:telegram', 'bank.ir'];
        await tester.pumpWidget(_host(state, rtl: lang == 'fa', brightness: brightness));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.byType(FloatingActionButton));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip(lang == 'fa' ? 'آزمایش: چه می‌شود؟' : 'Test what happens'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const ValueKey('rl-test-text')), 'web.telegram.org');
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }
  }
}
