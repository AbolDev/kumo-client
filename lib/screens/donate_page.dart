import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:qr_flutter/qr_flutter.dart';

import '../core/donate.dart';
import '../core/donate_sync.dart' show refreshWallets;
import '../l10n/extra.dart';
import 'share_sheet.dart' show ToastKind, toast;
import 'update_dialog.dart' show openLink;

/// The wallets of donations: the ones written in the app (or kept by the last download), and a newer list that carries the
/// signature of the project when GitHub has one (asked for at the start of the app and again when this page is opened).
class DonatePage extends StatefulWidget {
  const DonatePage({super.key, this.store, this.refresh});

  /// The wallets in use (a test gives its own).
  final WalletStore? store;

  /// Asks GitHub for a newer list (a test gives its own); the app's own by default.
  final Future<bool> Function()? refresh;

  @override
  State<DonatePage> createState() => _DonatePageState();
}

class _DonatePageState extends State<DonatePage> {
  WalletStore get _store => widget.store ?? walletStore;

  @override
  void initState() {
    super.initState();
    // The list the app started with is shown at once; a newer one takes its place when it comes.
    (widget.refresh ?? refreshWallets)().catchError((_) => false);
  }

  Future<void> _copy(Wallet w) async {
    await Clipboard.setData(ClipboardData(text: w.address));
    if (mounted) toast(context, tr(context, 'donateCopied'), kind: ToastKind.ok);
  }

  void _qr(Wallet w) => showDialog<void>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text('${w.coin} · ${w.network}', textDirection: TextDirection.ltr),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(12),
              child: QrImageView(key: ValueKey('donate-qr:${w.address}'), data: w.address, size: 220, backgroundColor: Colors.white),
            ),
            const SizedBox(height: 12),
            SelectableText(w.address, textDirection: TextDirection.ltr, textAlign: TextAlign.center),
          ]),
          actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('OK'))],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'donateTitle'))),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              Text(tr(context, 'donateDesc'), style: text.bodyLarge),
              const SizedBox(height: 8),
              Text(tr(context, 'donateIntro'), style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: 16),
              ValueListenableBuilder<List<Wallet>>(
                valueListenable: _store.wallets,
                builder: (context, wallets, _) => Column(children: [for (final w in wallets) _card(context, w)]),
              ),
              const SizedBox(height: 4),
              Text(tr(context, 'donateCheck'), style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: () => openLink('https://github.com/AbolDev/kumo-client#support-kumo'),
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: Text(tr(context, 'donateOpenReadme')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _card(BuildContext context, Wallet w) {
    final text = Theme.of(context).textTheme;
    return Card(
      key: ValueKey('wallet:${w.kind.name}'),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${w.coin} · ${w.network}', textDirection: TextDirection.ltr, style: text.titleMedium),
          const SizedBox(height: 6),
          SelectableText(w.address, textDirection: TextDirection.ltr, style: text.bodyMedium?.copyWith(fontFamily: 'monospace')),
          Row(children: [
            TextButton.icon(
              onPressed: () => _copy(w),
              icon: const Icon(Icons.copy, size: 18),
              label: Text(tr(context, 'donateCopy')),
            ),
            TextButton.icon(
              onPressed: () => _qr(w),
              icon: const Icon(Icons.qr_code_2, size: 20),
              label: Text(tr(context, 'donateQr')),
            ),
          ]),
        ]),
      ),
    );
  }
}
