import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/build_flavor.dart';

void main() {
  test('a normal build is not a store build and shows the donations', () {
    // (The builds for F-Droid and Google Play define FDROID and PLAY; nothing here does.)
    expect(fdroidBuild, isFalse);
    expect(playBuild, isFalse);
    expect(storeBuild, isFalse);
    expect(donationsInApp, isTrue);
  });
}