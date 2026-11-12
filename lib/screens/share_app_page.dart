import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../core/share_text.dart';
import '../l10n/extra.dart';
import '../widgets/kumo_mark.dart';
import 'share_sheet.dart' show ToastKind, toast;

/// Share Kumo: a message ready to send, in the language the user picks (the app's own at first), and a QR code
/// of the address of Kumo's site in that language, for someone who is next to them.
///
/// The language buttons, the code and the buttons to send are where they are whatever language is picked (only
/// the message under the code changes its length), so nothing moves when another language is chosen.
class ShareAppPage extends StatefulWidget {
  const ShareAppPage({super.key});

  @override
  State<ShareAppPage> createState() => _ShareAppPageState();
}

class _ShareAppPageState extends State<ShareAppPage> {
  ShareLang? _lang;
  final _qrKey = GlobalKey();

  ShareLang get _chosen {
    if (_lang != null) return _lang!;
    final l = Localizations.localeOf(context);
    return shareLangFor(l.languageCode, l.scriptCode);
  }

  Future<void> _copy(ShareLang l) async {
    await Clipboard.setData(ClipboardData(text: l.message()));
    if (mounted) toast(context, tr(context, 'shareCopied'), kind: ToastKind.ok);
  }

  Future<void> _send(ShareLang l) async {
    try {
      await Share.share(l.message());
    } catch (_) {}
  }

  /// The card with the code, as it is drawn on the page, as a picture to send.
  Future<void> _sendQr() async {
    try {
      final boundary = _qrKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return;
      final image = await boundary.toImage(pixelRatio: 3);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) return;
      final file = File('${Directory.systemTemp.path}/kumo_site_qr.png');
      await file.writeAsBytes(bytes.buffer.asUint8List());
      await Share.shareXFiles([XFile(file.path, mimeType: 'image/png')]);
    } catch (_) {}
  }

  /// The languages as buttons of one size, in rows of the same number: the one chosen is only coloured, never
  /// given a tick, so no button grows and the rows do not change.
  Widget _languages(BuildContext context, ShareLang chosen) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, box) {
      const gap = 8.0;
      final cols = box.maxWidth >= 480 ? 4 : 3;
      final width = (box.maxWidth - gap * (cols - 1)) / cols;
      return Wrap(spacing: gap, runSpacing: gap, children: [
        for (final option in shareLangs)
          SizedBox(
            key: ValueKey('lang:${option.code}'),
            width: width,
            height: 48,
            child: Semantics(
              button: true,
              selected: option.code == chosen.code,
              child: Material(
                color: option.code == chosen.code ? scheme.primaryContainer : scheme.surfaceContainerLow,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(
                      color: option.code == chosen.code ? scheme.primary : scheme.outlineVariant,
                      width: option.code == chosen.code ? 2 : 1),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => setState(() => _lang = option),
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Text(
                        option.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: option.code == chosen.code ? FontWeight.w700 : FontWeight.w500,
                          color: option.code == chosen.code ? scheme.onPrimaryContainer : scheme.onSurface,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ]);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final l = _chosen;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'shareTitle'))),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            children: [
              Text(tr(context, 'shareDesc'), style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: 16),
              Text(tr(context, 'shareLang'), style: text.titleSmall),
              const SizedBox(height: 8),
              _languages(context, l),
              const SizedBox(height: 20),
              Center(child: KumoQrCard(boundaryKey: _qrKey, site: l.site)),
              const SizedBox(height: 8),
              Text(tr(context, 'shareQrHint'),
                  textAlign: TextAlign.center, style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
              Center(
                child: TextButton.icon(
                  onPressed: _sendQr,
                  icon: const Icon(Icons.image_outlined),
                  label: Text(tr(context, 'shareQrSend')),
                ),
              ),
              const SizedBox(height: 12),
              // The message, as it will be read: in its own direction, whatever the app's language is.
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Directionality(
                  textDirection: l.rtl ? TextDirection.rtl : TextDirection.ltr,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SelectableText(l.text, style: text.bodyLarge),
                    const SizedBox(height: 8),
                    SelectableText(l.site,
                        textDirection: TextDirection.ltr, style: text.bodyMedium?.copyWith(color: scheme.primary)),
                  ]),
                ),
              ),
            ],
          ),
        ),
      ),
      // The buttons stay at the bottom whatever the length of the message above.
      bottomNavigationBar: SafeArea(
        child: Align(
          heightFactor: 1,
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                    onPressed: () => _copy(l),
                    icon: const Icon(Icons.copy),
                    label: Text(tr(context, 'shareCopy')),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                    onPressed: () => _send(l),
                    icon: const Icon(Icons.share),
                    label: Text(tr(context, 'shareSend')),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// A card made to be looked at and sent as a picture: a QR code of round dots in a teal gradient on a white
/// plate, rounded eyes, the Kumo cloud in the middle (the code is at the highest error correction, so the cloud
/// does not stop it from being read) and the address under it. Its colours are Kumo's own, light or dark theme.
class KumoQrCard extends StatelessWidget {
  const KumoQrCard({super.key, required this.site, this.boundaryKey});

  final String site;

  /// Marks the card so that it can be turned into a picture.
  final GlobalKey? boundaryKey;

  static const _deep = Color(0xFF04302C);
  static const _teal = Color(0xFF0B7A6E);

  @override
  Widget build(BuildContext context) {
    const qr = 216.0;
    return RepaintBoundary(
      key: boundaryKey,
      child: Container(
        width: 300,
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(32),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF16B8A4), Color(0xFF0B6E64), Color(0xFF053A35)],
          ),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 24, offset: const Offset(0, 10)),
          ],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            KumoMark(size: 26),
            SizedBox(width: 8),
            Text('Kumo',
                textDirection: TextDirection.ltr,
                style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
          ]),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(26)),
            child: Stack(alignment: Alignment.center, children: [
              // The dots are drawn black on nothing and given the gradient: it is only where there is a dot.
              ShaderMask(
                blendMode: BlendMode.srcIn,
                shaderCallback: (rect) => const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [_teal, _deep],
                ).createShader(rect),
                child: QrImageView(
                  // The key holds what the code says, so a test can tell which one is drawn.
                  key: ValueKey('share-qr:$site'),
                  data: site,
                  size: qr,
                  padding: EdgeInsets.zero,
                  backgroundColor: Colors.transparent,
                  errorCorrectionLevel: QrErrorCorrectLevel.H,
                  eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.circle, color: Colors.black),
                  dataModuleStyle: const QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.circle, color: Colors.black),
                ),
              ),
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: _teal.withValues(alpha: 0.25), width: 2),
                ),
                alignment: Alignment.center,
                child: const KumoMark(size: 34),
              ),
            ]),
          ),
          const SizedBox(height: 14),
          Text(site.replaceFirst('https://', ''),
              textDirection: TextDirection.ltr,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}
