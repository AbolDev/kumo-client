import 'package:flutter/material.dart';
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
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows),
        ),
      ]),
    );
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
                  // The scan: every way of reaching WARP is tried, the fastest one that answers is used.
                  ListTile(
                    leading: warp.scanning
                        ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.radar),
                    title: Text(warp.scanning
                        ? tr(context, 'warpScanning', {'done': warp.scanDone, 'total': warp.scanTotal})
                        : tr(context, 'warpScan')),
                    subtitle: Text(tr(context, 'warpScanDesc')),
                    trailing: warp.scanning
                        ? TextButton(
                            onPressed: warp.cancelScan,
                            child: Text(MaterialLocalizations.of(context).cancelButtonLabel))
                        : null,
                    onTap: warp.busy || warp.scanning ? null : warp.scan,
                  ),
                  ListTile(
                    leading: const Icon(Icons.travel_explore),
                    title: Text(tr(context, 'warpScanWide')),
                    subtitle: Text(tr(context, 'warpScanWideDesc')),
                    onTap: warp.busy || warp.scanning ? null : warp.scanWide,
                  ),
                  if (warp.scanFailed)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Text(tr(context, 'warpScanNone'), style: TextStyle(color: scheme.error)),
                    ),
                  for (final r in warp.scanResults)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(72, 0, 16, 6),
                      child: Text('${r.text}  ${r.ms} ms', textDirection: TextDirection.ltr),
                    ),
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
                  SwitchListTile(
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
