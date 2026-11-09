import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/strings.dart';

/// What a message is about: it gets a mark and a colour.
enum ToastKind { info, ok, error }

/// A message at the bottom. [kind] gives it a mark (done, or went wrong); [actionLabel] and [onAction]
/// add a button (Undo), and the message stays longer then.
void toast(BuildContext context, String text,
    {ToastKind kind = ToastKind.info, String? actionLabel, VoidCallback? onAction}) {
  final scheme = Theme.of(context).colorScheme;
  final error = kind == ToastKind.error;
  final color = error ? scheme.onErrorContainer : null;
  final icon = switch (kind) {
    ToastKind.ok => Icons.check_circle_outline,
    ToastKind.error => Icons.error_outline,
    ToastKind.info => null,
  };
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      duration: Duration(seconds: onAction == null ? 4 : 7),
      backgroundColor: error ? scheme.errorContainer : null,
      content: Row(children: [
        if (icon != null) ...[Icon(icon, color: color ?? scheme.primary), const SizedBox(width: 12)],
        Expanded(child: Text(text, style: color == null ? null : TextStyle(color: color))),
      ]),
      action: onAction == null || actionLabel == null ? null : SnackBarAction(label: actionLabel, onPressed: onAction),
    ));
}

/// Bottom sheet with the ways to share [text] (a config link or a subscription link).
Future<void> showShareSheet(BuildContext context,
    {required String text, required String copyLabel}) {
  final t = S.of(context);
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.copy),
            title: Text(copyLabel),
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (!sheet.mounted) return;
              Navigator.pop(sheet);
              if (context.mounted) toast(context, t.copied);
            },
          ),
          ListTile(
            leading: const Icon(Icons.qr_code_2),
            title: Text(t.qrCode),
            onTap: () {
              Navigator.pop(sheet);
              showQrDialog(context, text);
            },
          ),
        ],
      ),
    ),
  );
}

/// Renders [data] as a QR code PNG with a white border (what gets shared or saved).
Future<Uint8List> renderQrPng(String data) async {
  const size = 1000.0, margin = 60.0;
  final painter = QrPainter(
    data: data,
    version: QrVersions.auto,
    errorCorrectionLevel: QrErrorCorrectLevel
        .L, // long links need the smallest, most readable code
    eyeStyle: const QrEyeStyle(color: Colors.black),
    dataModuleStyle: const QrDataModuleStyle(color: Colors.black),
  );
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
      const Rect.fromLTWH(0, 0, size, size), Paint()..color = Colors.white);
  canvas.translate(margin, margin);
  painter.paint(canvas, const Size(size - 2 * margin, size - 2 * margin));
  final image =
      await recorder.endRecording().toImage(size.toInt(), size.toInt());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

Future<void> showQrDialog(BuildContext context, String data) {
  return showDialog<void>(
    context: context,
    builder: (dialog) {
      final t = S.of(dialog);
      return AlertDialog(
        title: Text(t.qrCode),
        content: SizedBox(
          width: 280,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              QrImageView(
                data: data,
                size: 260,
                padding: const EdgeInsets.all(12),
                backgroundColor: Colors.white,
                errorCorrectionLevel: QrErrorCorrectLevel.L,
                errorStateBuilder: (_, __) => Text(t.invalidConfig),
              ),
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.share),
                    label: Text(t.shareImage),
                    onPressed: () => _shareImage(dialog, data),
                  ),
                  if (Platform.isAndroid)
                    OutlinedButton.icon(
                      icon: const Icon(Icons.download),
                      label: Text(t.saveToGallery),
                      onPressed: () => _saveImage(dialog, data),
                    ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog), child: Text(t.cancel))
        ],
      );
    },
  );
}

Future<void> _shareImage(BuildContext context, String data) async {
  try {
    final png = await renderQrPng(data);
    final file = File('${Directory.systemTemp.path}/kumo_qr.png');
    await file.writeAsBytes(png);
    await Share.shareXFiles([XFile(file.path, mimeType: 'image/png')]);
  } catch (e) {
    if (context.mounted) toast(context, S.of(context).saveFailed(e));
  }
}

Future<void> _saveImage(BuildContext context, String data) async {
  final t = S.of(context);
  try {
    final png = await renderQrPng(data);
    if (!await Gal.hasAccess()) await Gal.requestAccess();
    await Gal.putImageBytes(png,
        name: 'kumo_qr_${DateTime.now().millisecondsSinceEpoch}.png');
    if (context.mounted) toast(context, t.savedToGallery);
  } catch (e) {
    if (context.mounted) toast(context, t.saveFailed(e));
  }
}
