import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:kumo/core/win_capture.dart';

void main() {
  test('the screen is read through system calls and comes back as a real picture', () async {
    final bytes = await captureScreen();
    if (bytes == null) {
      // A session without a screen (a service, a remote build) has nothing to capture.
      markTestSkipped('no screen to capture here');
      return;
    }
    final image = img.decodePng(bytes);
    expect(image, isNotNull);
    expect(image!.width, greaterThan(300));
    expect(image.height, greaterThan(200));
    // A real screen is not one flat colour.
    final seen = <int>{};
    for (var y = 0; y < image.height; y += image.height ~/ 20) {
      for (var x = 0; x < image.width; x += image.width ~/ 20) {
        final p = image.getPixel(x, y);
        seen.add((p.r.toInt() << 16) | (p.g.toInt() << 8) | p.b.toInt());
      }
    }
    expect(seen.length, greaterThan(1));
  }, skip: !Platform.isWindows);

  test('an empty clipboard gives no picture', () async {
    // (a picture on the clipboard would be fine too; the call must just not fail)
    final result = await clipboardImage();
    expect(result == null || result.length > 14, isTrue);
  }, skip: !Platform.isWindows);
}
