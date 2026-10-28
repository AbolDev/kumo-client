import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/l10n/strings.dart';
import 'package:kumo/screens/home_page.dart';
import 'package:kumo/state/app_state.dart';

Widget _app(AppState state, GlobalKey<NavigatorState> navigator, {required bool withBar}) {
  return MaterialApp(
    navigatorKey: navigator,
    supportedLocales: S.supportedLocales,
    localizationsDelegates: const [
      S.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    // The same shape as in main.dart: the buttons sit above the Navigator.
    builder: (context, child) => Column(children: [
      if (withBar) SizedBox(height: 36, child: Row(children: [const Spacer(), HomeTitleActions(state: state, navigator: navigator)])),
      Expanded(child: child!),
    ]),
    home: HomePage(state: state),
  );
}

/// An icon inside the buttons of the title row (the list below has icons of its own).
Finder inRow(IconData icon) =>
    find.descendant(of: find.byType(HomeTitleActions), matching: find.byIcon(icon));

void main() {
  testWidgets('on Windows the home screen has no bar of its own; its buttons are in the title row', (tester) async {
    tester.view.physicalSize = const Size(900 * 2, 700 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final state = AppState();
    await tester.pumpWidget(_app(state, GlobalKey<NavigatorState>(), withBar: true));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(AppBar), findsNothing);
    expect(inRow(Icons.add), findsOneWidget);
    expect(inRow(Icons.more_vert), findsOneWidget);
    expect(inRow(Icons.settings), findsOneWidget);
  }, skip: !Platform.isWindows);

  testWidgets('the menus open from the title row and a page opens from the settings button', (tester) async {
    tester.view.physicalSize = const Size(900 * 2, 700 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final state = AppState();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(_app(state, navigator, withBar: true));
    await tester.pump();

    await tester.tap(inRow(Icons.add));
    await tester.pumpAndSettle();
    expect(find.text('Add from clipboard'), findsOneWidget);
    // the menu opens under the button, inside the window
    final menu = tester.getRect(find.text('Add from clipboard'));
    expect(menu.top, greaterThan(30));
    expect(menu.right, lessThan(900));
    await tester.tapAt(const Offset(10, 600)); // closes it
    await tester.pumpAndSettle();
    expect(find.text('Add from clipboard'), findsNothing);

    await tester.tap(inRow(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.network_check), findsWidgets);
    await tester.tapAt(const Offset(10, 600));
    await tester.pumpAndSettle();

    await tester.tap(inRow(Icons.settings));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsWidgets);
  }, skip: !Platform.isWindows);
}
