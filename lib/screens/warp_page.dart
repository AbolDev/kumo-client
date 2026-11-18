import 'package:flutter/material.dart';

import '../widgets/option_tile.dart' show SwitchOption;
import '../widgets/kumo_mark.dart';

import '../core/net_options.dart' show fingerprints;
import '../core/proxy_config.dart' show parseLink;
import '../core/usage_stats.dart' show formatBytes;
import '../core/warp/warp_store.dart';
import '../l10n/extra.dart';
import '../state/app_state.dart';
import '../state/warp_controller.dart';
import 'network_settings.dart' show pickChain;

/// The progress of the making of a WARP account: a bar and how far it is, with a word that it can take a while.
class WarpSetupProgress extends StatelessWidget {
  const WarpSetupProgress({super.key, required this.value});

  /// 0 to 1.
  final double value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final percent = (value * 100).round().clamp(0, 100);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(value: value <= 0 ? null : value, minHeight: 6),
      ),
      const SizedBox(height: 6),
      Text(tr(context, 'warpSetupProgress', {'percent': percent}),
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
    ]);
  }
}

/// Cloudflare WARP: makes the account on this device, puts the server in the list, and lets the user
/// switch to another way of connecting or fetch newer methods.
class WarpPage extends StatefulWidget {
  const WarpPage({super.key, required this.state});

  final AppState state;

  @override
  State<WarpPage> createState() => _WarpPageState();
}

class _WarpPageState extends State<WarpPage> {
  WarpController get warp => widget.state.warp;

  @override
  void initState() {
    super.initState();
    warp.load();
  }

  Future<void> _remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        content: Text(tr(c, 'warpRemoveAsk')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(MaterialLocalizations.of(c).cancelButtonLabel)),
          TextButton(onPressed: () => Navigator.pop(c, true), child: Text(tr(c, 'warpRemove'))),
        ],
      ),
    );
    if (ok == true) await warp.remove();
  }

  /// The uTLS fingerprint of the MASQUE ways over HTTP/2 (some networks cut one name of client and pass another).
  Future<void> _pickFingerprint() async {
    final now = warp.masqueFingerprint;
    final picked = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: Text(tr(c, 'warpFingerprint')),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(tr(c, 'warpFingerprintDesc'), style: Theme.of(c).textTheme.bodySmall),
          ),
          for (final f in fingerprints)
            ListTile(
              selected: f == now,
              title: Text(f.isEmpty ? tr(c, 'warpFingerprintDefault') : f, textDirection: TextDirection.ltr),
              trailing: f == now ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(c, f),
            ),
        ],
      ),
    );
    if (picked != null && picked != now) await warp.setMasqueFingerprint(picked);
  }

  /// A titled card of rows: the page is made of these, so that what belongs together reads together.
  Widget _section(BuildContext context, String title, List<Widget> rows) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 12, bottom: 6),
          child: Text(title, style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w600)),
        ),
        Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          // A thin line between the rows, so each option stands apart.
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final (i, row) in rows.indexed) ...[
              if (i > 0) Divider(height: 1, indent: 16, endIndent: 16, color: scheme.outlineVariant),
              row,
            ],
          ]),
        ),
      ]),
    );
  }

  /// One of the two scans: its row, and under it, while it runs, what it is doing (a bar, how many ways were
  /// tried and answered, about how long is left, the fastest so far, the last ways tried and a button to stop),
  /// and when it is over, the ways that answered or that none did.
  Widget _scanTile(BuildContext context, {required bool wide}) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final running = warp.scanning && warp.scanIsWide == wide;
    final last = !warp.scanning && warp.scanIsWide == wide;
    final small = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    Widget way(({String text, int ms}) r, {bool inUse = false}) => Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(children: [
            Icon(r.ms >= 0 ? Icons.check_circle : Icons.cancel_outlined,
                size: 16, color: r.ms >= 0 ? Colors.green : scheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(r.text,
                  textDirection: TextDirection.ltr,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
            ),
            if (inUse)
              Container(
                margin: const EdgeInsetsDirectional.only(end: 8),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(10)),
                child: Text(tr(context, 'warpScanInUse'),
                    style: text.labelSmall?.copyWith(color: scheme.onPrimaryContainer)),
              ),
            Text(r.ms >= 0 ? '${r.ms} ms' : tr(context, 'warpScanNoAnswer'),
                textDirection: r.ms >= 0 ? TextDirection.ltr : null, style: small),
          ]),
        );

    final details = <Widget>[];
    if (running) {
      final done = warp.scanDone, total = warp.scanTotal;
      String status = tr(context, 'warpScanStatus', {'done': done, 'total': total, 'ok': warp.scanAnswered});
      final started = warp.scanStarted;
      if (started != null && done > 0 && done < total) {
        final perTry = DateTime.now().difference(started).inMilliseconds / done;
        status += ' · ${tr(context, 'warpScanLeft', {'s': (perTry * (total - done) / 1000).ceil()})}';
      }
      final best = warp.scanBest;
      details.addAll([
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(value: total == 0 ? null : done / total, minHeight: 6),
        ),
        const SizedBox(height: 8),
        Text(status, style: small),
        if (best != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(tr(context, 'warpScanBest', {'way': best.text, 'ms': best.ms}),
                style: text.bodySmall?.copyWith(color: Colors.green, fontWeight: FontWeight.w600)),
          ),
        for (final r in warp.scanRecent) way(r),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: TextButton.icon(
            onPressed: warp.cancelScan,
            icon: const Icon(Icons.stop_circle_outlined, size: 18),
            label: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
        ),
      ]);
    } else if (last && warp.scanFailed) {
      details.add(Text(tr(context, 'warpScanNone'), style: text.bodySmall?.copyWith(color: scheme.error)));
    } else if (last && warp.scanResults.isNotEmpty) {
      details.addAll([
        Text(tr(context, 'warpScanFound'), style: small?.copyWith(fontWeight: FontWeight.w600)),
        for (final (i, r) in warp.scanResults.indexed) way(r, inUse: i == 0),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ListTile(
        leading: running
            ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(wide ? Icons.travel_explore : Icons.radar),
        title: Text(running
            ? tr(context, 'warpScanning', {'done': warp.scanDone, 'total': warp.scanTotal})
            : tr(context, wide ? 'warpScanWide' : 'warpScan')),
        subtitle: Text(tr(context, wide ? 'warpScanWideDesc' : 'warpScanDesc')),
        onTap: warp.busy || warp.scanning ? null : (wide ? warp.scanWide : warp.scan),
      ),
      if (details.isNotEmpty)
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(72, 0, 16, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: details),
        ),
    ]);
  }

  String? _updateText(BuildContext context) => switch (warp.lastUpdate) {
        WarpUpdateResult.updated => tr(context, 'warpUpdated'),
        WarpUpdateResult.current => tr(context, 'warpCurrent'),
        WarpUpdateResult.failed => tr(context, 'warpFailed'),
        WarpUpdateResult.needsNewerApp => tr(context, 'warpNeedsApp'),
        null => null,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'warpTitle'))),
      body: ListenableBuilder(
        listenable: Listenable.merge([widget.state, warp]),
        builder: (context, _) {
          final p = warp.profile;
          final chosen = warp.isChosen;
          final language = Localizations.localeOf(context).languageCode;
          final note = warp.note(language);
          final update = _updateText(context);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(tr(context, 'warpDesc')),
                ),
              ),
              const SizedBox(height: 12),
              if (warp.account == null)
                FilledButton.icon(
                  onPressed: warp.busy || p == null ? null : warp.setUp,
                  icon: warp.busy
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const KumoMark(size: 20),
                  label: Text(tr(context, warp.busy ? 'warpSettingUp' : 'warpSetUp')),
                ),
              // The sign-up tries several ways of reaching Cloudflare and can take a while: the bar shows it moves.
              if (warp.setupProgress != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 4),
                  child: WarpSetupProgress(value: warp.setupProgress!),
                ),
              if (warp.account != null) ...[
                Card(
                  margin: EdgeInsets.zero,
                  child: Column(children: [
                    ListTile(
                      leading: const Icon(Icons.check_circle_outline),
                      title: Text(tr(context, 'warpReady')),
                    ),
                    if (!chosen)
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: Padding(
                          padding: const EdgeInsetsDirectional.only(end: 12, bottom: 8),
                          child: TextButton(
                              onPressed: warp.choose, child: Text(tr(context, 'warpChoose'))),
                        ),
                      ),
                  ]),
                ),
                if (warp.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(warp.error!, style: TextStyle(color: scheme.error)),
                  ),
                // Finding a way that works: every method is a server of the WARP group on the main screen (tested
                // and picked there); these move the one in use to another address or port.
                _section(context, tr(context, 'warpSecWays'), [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(tr(context, 'warpWaysHint'),
                        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
                  ),
                  // The scans: every way of the profile, or addresses outside it; the fastest that answers is used.
                  _scanTile(context, wide: false),
                  _scanTile(context, wide: true),
                ]),
                _section(context, tr(context, 'warpSecMore'), [
                  // Two hops: WARP is reached through another server (the same setting as the proxy chain of the
                  // network options). The chain is for the WireGuard ways: the MASQUE ones go through Xray, which
                  // does not take it.
                  ListTile(
                    leading: const Icon(Icons.alt_route),
                    title: Text(tr(context, 'warpChain')),
                    subtitle: Text(widget.state.net.chain.isEmpty
                        ? tr(context, 'warpChainDesc')
                        : (parseLink(widget.state.net.chain)?.name ?? tr(context, 'chainNone'))),
                    trailing: widget.state.net.chain.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () => widget.state.updateNet((o) => o.chain = ''),
                          ),
                    onTap: warp.busy || warp.scanning ? null : () => pickChain(context, widget.state),
                  ),
                  if (widget.state.net.chain.isNotEmpty && (warp.currentMethod ?? '').startsWith('masque'))
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Text(tr(context, 'warpChainMasque'), style: TextStyle(color: scheme.error)),
                    ),
                  ListTile(
                    leading: const Icon(Icons.fingerprint),
                    title: Text(tr(context, 'warpFingerprint')),
                    subtitle: Text(
                      warp.masqueFingerprint.isEmpty
                          ? tr(context, 'warpFingerprintDefault')
                          : warp.masqueFingerprint,
                      textDirection: TextDirection.ltr,
                    ),
                    onTap: warp.busy || warp.scanning ? null : _pickFingerprint,
                  ),
                  // AmneziaWG: the name is shown, so that the user knows what WARP is reached with and that it is supported.
                  SwitchOption(
                    secondary: const Icon(Icons.shield_moon_outlined),
                    title: Text(tr(context, 'warpAmnezia')),
                    subtitle: Text(tr(context, 'warpAmneziaDesc')),
                    value: warp.amnezia,
                    onChanged: warp.busy || warp.scanning ? null : warp.setAmnezia,
                  ),
                  SwitchOption(
                    secondary: const Icon(Icons.layers_outlined),
                    title: Text(tr(context, 'warpInWarp')),
                    subtitle: Text(tr(context, 'warpInWarpDesc')),
                    value: warp.inWarp,
                    onChanged: warp.busy || warp.scanning ? null : warp.setInWarp,
                  ),
                ]),
                _section(context, tr(context, 'warpUsed'), [
                  ListTile(
                    leading: const Icon(Icons.arrow_downward),
                    title: Text(tr(context, 'warpDown')),
                    subtitle: Text(formatBytes(widget.state.warpUsage[0]), textDirection: TextDirection.ltr),
                  ),
                  ListTile(
                    leading: const Icon(Icons.arrow_upward),
                    title: Text(tr(context, 'warpUp')),
                    subtitle: Text(formatBytes(widget.state.warpUsage[1]), textDirection: TextDirection.ltr),
                  ),
                  ListTile(
                    leading: const Icon(Icons.swap_vert),
                    title: Text(tr(context, 'warpTotal')),
                    subtitle: Text(formatBytes(widget.state.warpUsage[0] + widget.state.warpUsage[1]),
                        textDirection: TextDirection.ltr),
                  ),
                ]),
              ],
              if (warp.account == null && warp.error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(warp.error!, style: TextStyle(color: scheme.error)),
                ),
              _section(context, tr(context, 'warpSecProfile'), [
                ListTile(
                  leading: warp.busy && warp.account != null
                      ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.sync),
                  title: Text(tr(context, 'warpUpdate')),
                  subtitle: Text([
                    if (p != null)
                      tr(context, 'warpProfileInfo', {
                        'version': p.version,
                        'source': tr(context, warp.store.source == 'saved' ? 'warpDownloaded' : 'warpBuiltIn'),
                      }),
                    if (update != null) update,
                  ].join('\n')),
                  onTap: warp.busy ? null : warp.updateProfile,
                ),
                if (note != null && note.isNotEmpty)
                  ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: Text(tr(context, 'warpNote', {'text': note})),
                  ),
                if (warp.account != null)
                  ListTile(
                    leading: Icon(Icons.delete_outline, color: scheme.error),
                    title: Text(tr(context, 'warpRemove'), style: TextStyle(color: scheme.error)),
                    onTap: warp.busy ? null : _remove,
                  ),
              ]),
            ],
          );
        },
      ),
    );
  }
}
