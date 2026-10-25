import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import '../l10n/extra.dart';

/// Shows [png] (a screenshot) full size and lets the user drag a rectangle over the part they
/// want. Returns that part as PNG bytes, or null if they cancel (Esc or the close button).
Future<Uint8List?> pickRegion(BuildContext context, Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final frame = await codec.getNextFrame();
  final size = Size(frame.image.width.toDouble(), frame.image.height.toDouble());
  frame.image.dispose();
  if (!context.mounted) return null;
  return Navigator.of(context).push<Uint8List>(PageRouteBuilder(
    opaque: true,
    pageBuilder: (_, __, ___) => _RegionPage(png: png, size: size),
  ));
}

class _RegionPage extends StatefulWidget {
  const _RegionPage({required this.png, required this.size});

  final Uint8List png;
  final Size size;

  @override
  State<_RegionPage> createState() => _RegionPageState();
}

class _RegionPageState extends State<_RegionPage> {
  Offset? _start;
  Offset? _end;
  var _busy = false;

  /// Where the screenshot sits inside the page (the largest centred fit).
  Rect _imageRect(Size box) {
    final scale = (box.width / widget.size.width) <
            (box.height / widget.size.height)
        ? box.width / widget.size.width
        : box.height / widget.size.height;
    final w = widget.size.width * scale;
    final h = widget.size.height * scale;
    return Rect.fromLTWH((box.width - w) / 2, (box.height - h) / 2, w, h);
  }

  Rect? get _selection =>
      _start == null || _end == null ? null : Rect.fromPoints(_start!, _end!);

  Future<void> _finish(Rect shown) async {
    final sel = _selection;
    if (sel == null || sel.width < 24 || sel.height < 24) {
      setState(() => _start = _end = null);
      return;
    }
    final area = sel.intersect(shown);
    final k = widget.size.width / shown.width;
    final x = ((area.left - shown.left) * k).round();
    final y = ((area.top - shown.top) * k).round();
    final w = (area.width * k).round();
    final h = (area.height * k).round();
    setState(() => _busy = true);
    final bytes = widget.png;
    final cropped = await Isolate.run(() {
      final image = img.decodeImage(bytes);
      if (image == null) return null;
      return Uint8List.fromList(
          img.encodePng(img.copyCrop(image, x: x, y: y, width: w, height: h)));
    });
    if (mounted) Navigator.of(context).pop(cropped);
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: LayoutBuilder(builder: (context, box) {
            final shown = _imageRect(box.biggest);
            return MouseRegion(
              cursor: SystemMouseCursors.precise,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (d) => setState(() {
                  _start = d.localPosition;
                  _end = d.localPosition;
                }),
                onPanUpdate: (d) => setState(() => _end = d.localPosition),
                onPanEnd: (_) => _finish(shown),
                child: Stack(children: [
                  Positioned.fromRect(
                    rect: shown,
                    child: Image.memory(widget.png,
                        fit: BoxFit.fill, gaplessPlayback: true),
                  ),
                  Positioned.fill(
                    child: CustomPaint(painter: _DimPainter(_selection)),
                  ),
                  PositionedDirectional(
                    top: 12,
                    start: 12,
                    end: 12,
                    child: Row(children: [
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: Colors.black87,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            _busy
                                ? '…'
                                : tr(context, 'selectQrArea'),
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ]),
                  ),
                ]),
              ),
            );
          }),
        ),
      ),
    );
  }
}

/// Darkens everything except the chosen rectangle and outlines it.
class _DimPainter extends CustomPainter {
  _DimPainter(this.selection);

  final Rect? selection;

  @override
  void paint(Canvas canvas, Size size) {
    final dim = Paint()..color = Colors.black.withValues(alpha: 0.55);
    final all = Offset.zero & size;
    final sel = selection;
    if (sel == null) {
      canvas.drawRect(all, dim);
      return;
    }
    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(all),
          Path()..addRect(sel)),
      dim,
    );
    canvas.drawRect(
        sel,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.white);
  }

  @override
  bool shouldRepaint(_DimPainter old) => old.selection != selection;
}
