import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../l10n/strings.dart';
import 'share_sheet.dart';

/// Camera preview that returns the text of the first QR code it sees.
/// A button at the bottom picks an image from the gallery instead.
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final _controller =
      MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  var _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _finish(BarcodeCapture? capture) {
    final value = capture?.barcodes
        .map((b) => b.rawValue)
        .whereType<String>()
        .firstOrNull;
    if (value == null || _done) return;
    _done = true;
    Navigator.pop(context, value);
  }

  Future<void> _pickFromGallery() async {
    final t = S.of(context);
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    final capture = await _controller.analyzeImage(picked.path);
    if (!mounted) return;
    if (capture == null || capture.barcodes.isEmpty) {
      toast(context, t.noQrFound);
      return;
    }
    _finish(capture);
  }

  @override
  Widget build(BuildContext context) {
    final t = S.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.scanTitle)),
      body: LayoutBuilder(
        builder: (context, box) {
          final side = box.biggest.shortestSide * 0.7;
          final window = Rect.fromCenter(
              center: box.biggest.center(Offset.zero),
              width: side,
              height: side);
          return Stack(
            fit: StackFit.expand,
            children: [
              MobileScanner(
                controller: _controller,
                onDetect: _finish,
                scanWindow: window,
                errorBuilder: (context, error, child) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(t.cameraDenied, textAlign: TextAlign.center),
                  ),
                ),
              ),
              CustomPaint(painter: _FramePainter(window)),
              Positioned(
                left: 24,
                right: 24,
                top: window.bottom + 20,
                child: Text(
                  t.scanHint,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      shadows: [Shadow(blurRadius: 6)]),
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: FilledButton.icon(
                      icon: const Icon(Icons.photo_library),
                      label: Text(t.pickFromGallery),
                      onPressed: _pickFromGallery,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Dims everything outside the square and draws its corners.
class _FramePainter extends CustomPainter {
  _FramePainter(this.window);

  final Rect window;

  @override
  void paint(Canvas canvas, Size size) {
    final hole = RRect.fromRectAndRadius(window, const Radius.circular(20));
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addRRect(hole),
      Paint()..color = Colors.black54,
    );
    final corner = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    const len = 34.0;
    final r = window;
    for (final (origin, dx, dy) in [
      (r.topLeft, 1.0, 1.0),
      (r.topRight, -1.0, 1.0),
      (r.bottomLeft, 1.0, -1.0),
      (r.bottomRight, -1.0, -1.0),
    ]) {
      canvas.drawLine(origin, origin + Offset(dx * len, 0), corner);
      canvas.drawLine(origin, origin + Offset(0, dy * len), corner);
    }
  }

  @override
  bool shouldRepaint(_FramePainter old) => old.window != window;
}
