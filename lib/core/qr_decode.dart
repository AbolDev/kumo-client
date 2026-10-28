import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

// Reading the screen and the clipboard goes through the system calls in win_capture.dart.
export 'win_capture.dart' show captureScreen, clipboardImage;

/// Reads the text of the first QR code found in an image (PNG, JPEG, ...), or null.
/// Large pictures such as screenshots are also tried at smaller sizes, which helps the
/// detector as much as it costs; the work runs off the UI thread.
Future<String?> decodeQr(Uint8List bytes) => Isolate.run(() => _decode(bytes));

String? _decode(Uint8List bytes) {
  final source = img.decodeImage(bytes);
  if (source == null) return null;
  final widths = <int>{source.width};
  for (final w in [1800, 1200, 800]) {
    if (w < source.width) widths.add(w);
  }
  for (final w in widths) {
    final image = w == source.width ? source : img.copyResize(source, width: w);
    final pixels = image
        .convert(numChannels: 4)
        .getBytes(order: img.ChannelOrder.abgr)
        .buffer
        .asInt32List();
    final luminance = RGBLuminanceSource(image.width, image.height, pixels);
    for (final binarizer in [
      HybridBinarizer(luminance),
      GlobalHistogramBinarizer(luminance),
    ]) {
      try {
        return QRCodeReader().decode(BinaryBitmap(binarizer)).text;
      } catch (_) {
        // nothing readable at this size, try the next one
      }
    }
  }
  return null;
}
