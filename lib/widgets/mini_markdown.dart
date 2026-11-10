import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// A piece of a line of text with its style: bold, italic, code, or a link to [url].
class MdSpan {
  const MdSpan(this.text, {this.bold = false, this.italic = false, this.code = false, this.url});

  final String text;
  final bool bold, italic, code;
  final String? url;

  @override
  bool operator ==(Object other) =>
      other is MdSpan &&
      other.text == text &&
      other.bold == bold &&
      other.italic == italic &&
      other.code == code &&
      other.url == url;

  @override
  int get hashCode => Object.hash(text, bold, italic, code, url);

  @override
  String toString() => 'MdSpan($text${bold ? ', bold' : ''}${italic ? ', italic' : ''}${code ? ', code' : ''}${url == null ? '' : ', $url'})';
}

/// A block of a text: a heading (of [level] 1 to 3), an item of a list, or a paragraph.
class MdBlock {
  const MdBlock(this.kind, this.spans, {this.level = 0});

  /// 'heading', 'bullet' or 'paragraph'.
  final String kind;
  final List<MdSpan> spans;
  final int level;
}

final _inline = RegExp(
    r'\*\*(.+?)\*\*' // bold
    r'|`([^`\n]+)`' // code
    r'|\[([^\]\n]+)\]\((https?://[^)\s]+)\)' // a link
    r'|(?<![\w*])\*([^*\s][^*\n]*?)\*(?![\w*])' // italic
    );

/// The spans of one line: `**bold**`, `*italic*`, `` `code` `` and `[text](https://link)`. What is
/// inside bold or italic is read again, so a link or code can sit in bold. Anything else is plain.
List<MdSpan> parseInline(String line, {bool bold = false, bool italic = false}) {
  final out = <MdSpan>[];
  var at = 0;
  for (final m in _inline.allMatches(line)) {
    if (m.start > at) out.add(MdSpan(line.substring(at, m.start), bold: bold, italic: italic));
    if (m[1] != null) {
      out.addAll(parseInline(m[1]!, bold: true, italic: italic));
    } else if (m[2] != null) {
      out.add(MdSpan(m[2]!, bold: bold, italic: italic, code: true));
    } else if (m[3] != null) {
      out.add(MdSpan(m[3]!, bold: bold, italic: italic, url: m[4]));
    } else {
      out.addAll(parseInline(m[5]!, bold: bold, italic: true));
    }
    at = m.end;
  }
  if (at < line.length) out.add(MdSpan(line.substring(at), bold: bold, italic: italic));
  return out;
}

/// The blocks of a text in Markdown (the part of it a release's notes use): `#` headings, `-` or `*`
/// items, paragraphs (lines that follow each other are one paragraph), and the inline marks of
/// [parseInline]. Blank lines separate blocks; HTML comments are left out.
List<MdBlock> parseMarkdown(String text) {
  final clean = text.replaceAll('\r', '').replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');
  final blocks = <MdBlock>[];
  final paragraph = <String>[];
  void flush() {
    if (paragraph.isEmpty) return;
    blocks.add(MdBlock('paragraph', parseInline(paragraph.join(' '))));
    paragraph.clear();
  }

  for (final raw in clean.split('\n')) {
    final line = raw.trimRight();
    if (line.trim().isEmpty) {
      flush();
      continue;
    }
    final heading = RegExp(r'^(#{1,3})\s+(.*)$').firstMatch(line.trim());
    final bullet = RegExp(r'^\s*[-*]\s+(.*)$').firstMatch(line);
    if (heading != null) {
      flush();
      blocks.add(MdBlock('heading', parseInline(heading[2]!), level: heading[1]!.length));
    } else if (bullet != null) {
      flush();
      blocks.add(MdBlock('bullet', parseInline(bullet[1]!)));
    } else if (RegExp(r'^\s+\S').hasMatch(line) && blocks.isNotEmpty && blocks.last.kind == 'bullet' && paragraph.isEmpty) {
      // The next line of an item that was cut in two.
      final last = blocks.removeLast();
      blocks.add(MdBlock('bullet', [...last.spans, ...parseInline(' ${line.trim()}')]));
    } else {
      paragraph.add(line.trim());
    }
  }
  flush();
  return blocks;
}

/// A text in Markdown, drawn: headings, lists, bold, italic, code and links ([onLink] gets the address of a
/// link that was tapped).
class MiniMarkdown extends StatefulWidget {
  const MiniMarkdown(this.text, {super.key, required this.onLink, this.style});

  final String text;
  final void Function(String url) onLink;
  final TextStyle? style;

  @override
  State<MiniMarkdown> createState() => _MiniMarkdownState();
}

class _MiniMarkdownState extends State<MiniMarkdown> {
  final _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  TextSpan _span(MdSpan s, TextStyle base, ColorScheme scheme) {
    var style = base;
    if (s.bold) style = style.copyWith(fontWeight: FontWeight.w700);
    if (s.italic) style = style.copyWith(fontStyle: FontStyle.italic);
    if (s.code) {
      style = style.copyWith(
          fontFamily: 'monospace', backgroundColor: scheme.surfaceContainerHighest, fontSize: (base.fontSize ?? 14) * 0.92);
    }
    TapGestureRecognizer? tap;
    if (s.url != null) {
      final url = s.url!;
      tap = TapGestureRecognizer()..onTap = () => widget.onLink(url);
      _recognizers.add(tap);
      style = style.copyWith(color: scheme.primary, decoration: TextDecoration.underline, decorationColor: scheme.primary);
    }
    return TextSpan(text: s.text, style: style, recognizer: tap);
  }

  @override
  Widget build(BuildContext context) {
    // The recognizers of the last build are not used any more.
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final base = widget.style ?? text.bodyMedium ?? const TextStyle();
    final blocks = parseMarkdown(widget.text);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      for (final (i, b) in blocks.indexed)
        Padding(
          padding: EdgeInsets.only(top: i == 0 ? 0 : (b.kind == 'bullet' ? 6 : 12)),
          child: switch (b.kind) {
            'heading' => Text.rich(
                TextSpan(children: [
                  for (final s in b.spans)
                    _span(s, (b.level == 1 ? text.titleLarge : (b.level == 2 ? text.titleMedium : text.titleSmall)) ?? base, scheme)
                ]),
              ),
            'bullet' => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(padding: const EdgeInsetsDirectional.only(end: 8, top: 1), child: Text('•', style: base)),
                Expanded(child: Text.rich(TextSpan(children: [for (final s in b.spans) _span(s, base, scheme)]))),
              ]),
            _ => Text.rich(TextSpan(children: [for (final s in b.spans) _span(s, base, scheme)])),
          },
        ),
    ]);
  }
}
