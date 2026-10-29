import 'dart:io' show Platform;

import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/widgets/flag_name.dart';

void main() {
  test('flags are found anywhere in a name', () {
    expect(splitFlags('🇫🇮 Finland CDN'), [('FI', ''), (null, ' Finland CDN')]);
    expect(splitFlags('Finland 🇫🇮'), [(null, 'Finland '), ('FI', '')]);
    expect(splitFlags('انگلیسی 🇬🇧 - مستقیم'),
        [(null, 'انگلیسی '), ('GB', ''), (null, ' - مستقیم')]);
    expect(splitFlags('🇩🇪🇺🇸'), [('DE', ''), ('US', '')]);
    expect(splitFlags('No flag'), [(null, 'No flag')]);
    // One indicator letter alone is not a flag.
    expect(splitFlags('A 🇩 B'), [(null, 'A 🇩 B')]);
  });

  testWidgets('every flag of a name is drawn as a picture where the font has no flags',
      (tester) async {
    if (!Platform.isWindows && !Platform.isLinux) return;
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: FlagName('انگلیسی 🇬🇧 - مستقیم 🇺🇸')),
    ));
    expect(find.byType(CountryFlag), findsNWidgets(2));
  });
}
