import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/win_dpapi.dart';

void main() {
  final onWindows = Platform.isWindows;

  test('sealed text is unreadable but opens to the same text', () {
    const text = '{"servers":[{"name":"سرور","password":"p@ss"}]}';
    final sealed = WinDpapi.seal(text)!;
    expect(WinDpapi.isSealed(sealed), isTrue);
    expect(sealed.contains('p@ss'), isFalse);
    expect(WinDpapi.open(sealed), text);
  }, skip: !onWindows);

  test('empty text and large text round-trip', () {
    expect(WinDpapi.open(WinDpapi.seal('')!), '');
    final big = 'x' * 500000;
    expect(WinDpapi.open(WinDpapi.seal(big)!), big);
  }, skip: !onWindows);

  test('damaged or foreign data gives null, plain text is not sealed', () {
    expect(WinDpapi.open('${WinDpapi.prefix}AAAA'), isNull);
    expect(WinDpapi.open('${WinDpapi.prefix}!!!not base64'), isNull);
    expect(WinDpapi.isSealed('{"a":1}'), isFalse);
  }, skip: !onWindows);
}
