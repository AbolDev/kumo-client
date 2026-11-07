import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/l10n/strings.dart';
import 'package:kumo/widgets/prompt_dialog.dart';

Future<void> _open(WidgetTester tester, void Function(Future<String?>) got,
    {bool secret = false, Future<String?> Function(String)? check, String? message}) async {
  await tester.pumpWidget(MaterialApp(
    locale: const Locale('en'),
    supportedLocales: S.supportedLocales,
    localizationsDelegates: const [S.delegate, GlobalMaterialLocalizations.delegate, GlobalWidgetsLocalizations.delegate],
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => got(showPrompt(context,
              icon: Icons.lock_outline,
              title: 'Password',
              message: message,
              label: 'Password',
              secret: secret,
              check: check)),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('says what it is for, has a labelled field and gives back what was typed', (tester) async {
    late Future<String?> result;
    await _open(tester, (f) => result = f, message: 'This file is locked.');
    expect(find.text('This file is locked.'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Password'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'secret');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(await result, 'secret');
  });

  testWidgets('a secret can be shown, and Cancel gives null', (tester) async {
    late Future<String?> result;
    await _open(tester, (f) => result = f, secret: true);
    TextField field() => tester.widget<TextField>(find.byType(TextField));
    expect(field().obscureText, isTrue);
    await tester.tap(find.byIcon(Icons.visibility_outlined));
    await tester.pump();
    expect(field().obscureText, isFalse);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await result, isNull);
  });

  testWidgets('a wrong answer is told under the field and the dialog stays, then the right one closes it', (tester) async {
    late Future<String?> result;
    await _open(tester, (f) => result = f, secret: true, check: (v) async => v == 'right' ? null : 'Wrong password.');
    await tester.enterText(find.byType(TextField), 'nope');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Wrong password.'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
    // typing again takes the message away
    await tester.enterText(find.byType(TextField), 'right');
    await tester.pump();
    expect(find.text('Wrong password.'), findsNothing);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(await result, 'right');
  });
}
