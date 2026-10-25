import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

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

/// Windows: a screenshot of the whole screen (all monitors) as PNG bytes, or null.
Future<Uint8List?> captureScreen() => _powershellImage(r'''
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$b = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
$bmp.Save($args[0], [System.Drawing.Imaging.ImageFormat]::Png)
''');

/// Windows: the image currently on the clipboard as PNG bytes, or null.
Future<Uint8List?> clipboardImage() => _powershellImage(r'''
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$i = [System.Windows.Forms.Clipboard]::GetImage()
if ($i -ne $null) { $i.Save($args[0], [System.Drawing.Imaging.ImageFormat]::Png) }
''');

Future<Uint8List?> _powershellImage(String script) async {
  final dir = await Directory.systemTemp.createTemp('kumo-qr');
  try {
    final out = '${dir.path}\\image.png';
    final file = File('${dir.path}\\run.ps1');
    await file.writeAsString(script);
    await Process.run('powershell',
        ['-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', file.path, out]);
    final png = File(out);
    return await png.exists() ? await png.readAsBytes() : null;
  } catch (_) {
    return null;
  } finally {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }
}
