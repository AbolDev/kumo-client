import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/l10n/strings.dart';
import 'package:kumo/screens/tools_page.dart';
import 'package:kumo/screens/troubleshoot_page.dart';
import 'package:kumo/screens/tune_page.dart';
import 'package:kumo/state/app_state.dart';

Widget _app(Widget home) => MaterialApp(
      supportedLocales: S.supportedLocales,
      localizationsDelegates: const [
        S.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      home: home,
    );

void main() {
  testWidgets('the best settings for the network are a tool of their own, with the button on the page', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(ToolsPage(state: AppState())));
    await tester.pumpAndSettle();
    // Two cards, each under its own name and with its own line.
    expect(find.text('Find the best settings for my network'), findsOneWidget);
    expect(find.text("Why can't I connect?"), findsOneWidget);
    expect(find.textContaining('likely reason it does not connect'), findsOneWidget);
    await tester.tap(find.text('Find the best settings for my network'));
    await tester.pumpAndSettle();
    expect(find.byType(TunePage), findsOneWidget);
    expect(find.text('Find the best settings'), findsOneWidget);
  });

  testWidgets('the page of the checks is only the checks', (tester) async {
    await tester.pumpWidget(_app(TroubleshootPage(state: AppState(), autoRun: false)));
    await tester.pumpAndSettle();
    expect(find.text('Find the best settings'), findsNothing);
    expect(find.text('Find the best settings for my network'), findsNothing);
  });
}
