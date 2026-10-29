import 'dart:io' show Platform;

import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';

/// Cuts [name] into pieces: text, and the flag emoji in it (two regional-indicator letters) as their
/// country code. A piece is ("FI", "") for a flag and (null, "Finland CDN") for text, so
/// "🇫🇮 Finland CDN" gives [("FI", ""), (null, " Finland CDN")]. A flag may be anywhere in the name.
List<(String?, String)> splitFlags(String name) {
  final runes = name.runes.toList();
  bool indicator(int r) => r >= 0x1F1E6 && r <= 0x1F1FF;
  final pieces = <(String?, String)>[];
  final text = <int>[];
  void flush() {
    if (text.isEmpty) return;
    pieces.add((null, String.fromCharCodes(text)));
    text.clear();
  }

  var i = 0;
  while (i < runes.length) {
    if (i + 1 < runes.length && indicator(runes[i]) && indicator(runes[i + 1])) {
      flush();
      pieces.add((
        String.fromCharCodes([runes[i] - 0x1F1E6 + 0x41, runes[i + 1] - 0x1F1E6 + 0x41]),
        ''
      ));
      i += 2;
    } else {
      text.add(runes[i]);
      i++;
    }
  }
  flush();
  return pieces;
}

/// A server name. Windows has no flag emoji (they show as two letters) and Linux often lacks the
/// font, so there each flag in the name, wherever it stands, is drawn as a picture.
class FlagName extends StatelessWidget {
  const FlagName(this.name, {super.key, this.style, this.maxLines = 1});

  final String name;
  final TextStyle? style;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final pieces = Platform.isWindows || Platform.isLinux ? splitFlags(name) : const <(String?, String)>[];
    if (!pieces.any((p) => p.$1 != null)) {
      return Text(name, maxLines: maxLines, overflow: TextOverflow.ellipsis, style: style);
    }
    // A screen reader gets the name as it is written (the emoji has a spoken name); the pictures are
    // only for the eyes.
    return Semantics(
      label: name,
      excludeSemantics: true,
      child: Text.rich(
        TextSpan(children: [
          for (final (code, text) in pieces)
            if (code == null)
              TextSpan(text: text)
            else
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: CountryFlag.fromCountryCode(code, height: 16, width: 22),
                  ),
                ),
              ),
        ]),
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: style,
      ),
    );
  }
}
