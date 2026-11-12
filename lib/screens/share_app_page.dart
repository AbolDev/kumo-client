import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../core/share_text.dart';
import '../l10n/extra.dart';
import 'share_sheet.dart' show ToastKind, renderQrPng, toast;

/// Share Kumo: a message ready to send, in the language the user picks (the app's own at first), and a QR code
/// of the address of Kumo's site in that language, for someone who is next to them.
class ShareAppPage extends StatefulWidget {
  const ShareAppPage({super.key});

  @override
  State<ShareAppPage> createState() => _ShareAppPageState();
}

class _ShareAppPageState extends State<ShareAppPage> {
  ShareLang? _lang;

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

  Future<void> _sendQr(ShareLang l) async {
    try {
      final png = await renderQrPng(l.site);
      final file = File('${Directory.systemTemp.path}/kumo_site_qr.png');
      await file.writeAsBytes(png);
      await Share.shareXFiles([XFile(file.path, mimeType: 'image/png')]);
    } catch (_) {}
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
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Text(tr(context, 'shareLang'), style: text.titleSmall),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final option in shareLangs)
                  ChoiceChip(
                    label: Text(option.name),
                    selected: option.code == l.code,
                    onSelected: (_) => setState(() => _lang = option),
                  ),
              ]),
              const SizedBox(height: 16),
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
                        textDirection: TextDirection.ltr,
                        style: text.bodyMedium?.copyWith(color: scheme.primary)),
                  ]),
                ),
              ),
              const SizedBox(height: 12),
              Row(children: [
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
              const SizedBox(height: 24),
              Center(
                child: Container(
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
                  child: QrImageView(
                    // The key holds what the code says, so a test can tell which one is drawn.
                    key: ValueKey('share-qr:${l.site}'),
                    data: l.site,
                    size: 240,
                    padding: const EdgeInsets.all(16),
                    backgroundColor: Colors.white,
                    errorCorrectionLevel: QrErrorCorrectLevel.M,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(tr(context, 'shareQrHint'),
                  textAlign: TextAlign.center, style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: 8),
              Center(
                child: TextButton.icon(
                  onPressed: () => _sendQr(l),
                  icon: const Icon(Icons.qr_code_2),
                  label: Text(tr(context, 'shareQrSend')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
