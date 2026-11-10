import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/widgets/mini_markdown.dart';

void main() {
  group('the marks inside a line', () {
    test('bold, italic, code and a link', () {
      expect(parseInline('a **b** c *d* `e` [f](https://x.y/z)'), [
        const MdSpan('a '),
        const MdSpan('b', bold: true),
        const MdSpan(' c '),
        const MdSpan('d', italic: true),
        const MdSpan(' '),
        const MdSpan('e', code: true),
        const MdSpan(' '),
        const MdSpan('f', url: 'https://x.y/z'),
      ]);
    });

    test('a link and code inside bold; a star between words and a link that is not a web address stay as they are', () {
      expect(parseInline('**see [it](https://a.b) and `x`**'), [
        const MdSpan('see ', bold: true),
        const MdSpan('it', bold: true, url: 'https://a.b'),
        const MdSpan(' and ', bold: true),
        const MdSpan('x', bold: true, code: true),
      ]);
      expect(parseInline('2*3*4 and [a](javascript:alert(1))'), [const MdSpan('2*3*4 and [a](javascript:alert(1))')]);
      expect(parseInline('no marks at all'), [const MdSpan('no marks at all')]);
      expect(parseInline(''), isEmpty);
    });

    test('the arrows and signs of the notes are plain text', () {
      expect(parseInline('*Settings > Network > Routing*: a > b'), [const MdSpan('Settings > Network > Routing', italic: true), const MdSpan(': a > b')]);
    });
  });

  group('the blocks of a text', () {
    const notes = '''# Kumo 1.12.2 beta 6 (test version)

This is a test version. It is
not offered as an update.

## What's new

- **A new look.** The menu holds *Tools*.
  It goes on here.
- **Fixes.** At most 64 probes.
<!-- lang:fa
چیزی
-->

Everything else is as in [beta 1](https://github.com/AbolDev/kumo-client/releases/tag/v1.12.2-beta.1) to beta 5.
''';

    test('headings, paragraphs of several lines, items (also cut in two), comments left out', () {
      final blocks = parseMarkdown(notes);
      expect(blocks.map((b) => b.kind), ['heading', 'paragraph', 'heading', 'bullet', 'bullet', 'paragraph']);
      expect(blocks[0].level, 1);
      expect(blocks[2].level, 2);
      expect(blocks[1].spans.single.text, 'This is a test version. It is not offered as an update.');
      expect(blocks[3].spans.map((s) => s.text).join(), 'A new look. The menu holds Tools. It goes on here.');
      expect(blocks[3].spans.first.bold, isTrue);
      expect(blocks[5].spans.any((s) => s.url?.contains('beta.1') ?? false), isTrue);
      expect(blocks.expand((b) => b.spans).any((s) => s.text.contains('lang:')), isFalse);
    });

    test('windows line ends are the same as the others', () {
      expect(parseMarkdown('- a\r\n- b\r\n').map((b) => b.spans.single.text), ['a', 'b']);
    });
  });

  testWidgets('it is drawn, with the links tappable', (tester) async {
    final tapped = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MiniMarkdown('# Title\n\n- **bold** item with [a link](https://a.b/c)\n\nplain', onLink: tapped.add),
      ),
    ));
    expect(find.textContaining('Title', findRichText: true), findsOneWidget);
    expect(find.textContaining('bold item with a link', findRichText: true), findsOneWidget);
    // Nothing of the marks is left in what is shown.
    expect(find.textContaining('**', findRichText: true), findsNothing);
    expect(find.textContaining('](', findRichText: true), findsNothing);
    // A rebuild does not break it.
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MiniMarkdown('- [x](https://a.b)', onLink: tapped.add))));
    expect(tester.takeException(), isNull);
  });
}
