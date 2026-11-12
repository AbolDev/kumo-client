import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/share_text.dart';
import 'package:kumo/screens/share_app_page.dart';
import 'package:kumo/screens/update_dialog.dart' show notesLanguages, releaseNotesFor;

void main() {
  group('the message that shares Kumo', () {
    test('there is one for each language of the app, with the address of the site in it', () {
      expect(shareLangs.map((l) => l.code), ['en', 'fa', 'ar', 'ru', 'vi', 'zh', 'zh-Hant']);
      for (final l in shareLangs) {
        expect(l.text.length, greaterThan(40), reason: l.code);
        expect(l.message(), contains(l.site));
        expect(l.site, startsWith('https://kumo-client.ir'));
        // Every one says what Kumo opens, by the names the protocols and the cores go by.
        expect(l.text, contains('V2Ray'));
        expect(l.text, contains('sing-box'));
      }
      expect(shareLangs.map((l) => l.site).toSet().length, shareLangs.length);
      expect(shareLangs.where((l) => l.rtl).map((l) => l.code), ['fa', 'ar']);
    });

    test('the app language picks its message, Traditional Chinese by its script, English when none', () {
      expect(shareLangFor('fa').code, 'fa');
      expect(shareLangFor('zh').code, 'zh');
      expect(shareLangFor('zh', 'Hant').code, 'zh-Hant');
      expect(shareLangFor('de').code, 'en');
    });

    testWidgets('the page shows the message and a QR code of the site, and follows the language chosen', (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: ShareAppPage()));
      expect(find.textContaining('free, open-source VPN client'), findsOneWidget);
      expect(find.byKey(const ValueKey('share-qr:https://kumo-client.ir')), findsOneWidget);
      await tester.tap(find.text('فارسی'));
      await tester.pump();
      expect(find.textContaining('رایگان و متن‌باز'), findsOneWidget);
      expect(find.byKey(const ValueKey('share-qr:https://kumo-client.ir/fa/')), findsOneWidget);
      await tester.tap(find.text('繁體中文'));
      await tester.pump();
      expect(find.byKey(const ValueKey('share-qr:https://kumo-client.ir/zh-hant/')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('the notes of a release in another language', () {
    const raw = '''# Kumo 1.2.3

## What's new

- **English item.** It is shown by default.

<!-- lang:fa
- **مورد فارسی.** این فارسی است.
-->

<!-- lang:ru
- **Пункт.** Это русский.
-->
''';

    test('the languages the notes have, English first', () {
      expect(notesLanguages(raw), ['en', 'fa', 'ru']);
      expect(notesLanguages('just English'), ['en']);
      expect(notesLanguages('English\n---\nفارسی'), ['en', 'fa']);
      expect(notesLanguages('<!-- lang:en -->\nA\n<!-- lang:fa -->\nB'), ['en', 'fa']);
    });

    test('each language gives its own text, and one the notes lack gives English', () {
      expect(releaseNotesFor(raw, 'en'), contains('English item'));
      expect(releaseNotesFor(raw, 'en'), isNot(contains('فارسی')));
      expect(releaseNotesFor(raw, 'fa'), contains('مورد فارسی'));
      expect(releaseNotesFor(raw, 'fa'), isNot(contains('English item')));
      expect(releaseNotesFor(raw, 'ru'), contains('русский'));
      expect(releaseNotesFor(raw, 'vi'), contains('English item'));
    });
  });
}
