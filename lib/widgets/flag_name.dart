import 'dart:io' show Platform;

import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';

/// Splits a leading flag emoji (two regional-indicator letters) from [name]:
/// ("FI", "Finland CDN") for "🇫🇮 Finland CDN". The code is null when there is no flag.
(String?, String) splitFlag(String name) {
  final runes = name.runes.toList();
  bool indicator(int r) => r >= 0x1F1E6 && r <= 0x1F1FF;
  if (runes.length >= 2 && indicator(runes[0]) && indicator(runes[1])) {
    final code = String.fromCharCodes(
        [runes[0] - 0x1F1E6 + 0x41, runes[1] - 0x1F1E6 + 0x41]);
    return (code, String.fromCharCodes(runes.skip(2)).trimLeft());
  }
  return (null, name);
}

/// A server name. Windows has no flag emoji (they show as two letters), so there the flag is
/// drawn as a picture in front of the name.
class FlagName extends StatelessWidget {
  const FlagName(this.name, {super.key, this.style});

  final String name;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final (code, rest) = Platform.isWindows ? splitFlag(name) : (null, name);
    final text = Text(code == null ? name : rest,
        maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
    if (code == null) return text;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: CountryFlag.fromCountryCode(code, height: 16, width: 22),
      ),
      const SizedBox(width: 8),
      Flexible(child: text),
    ]);
  }
}