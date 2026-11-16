import 'package:flutter/material.dart';
import '../widgets/kumo_mark.dart';

import '../core/net_options.dart' show fingerprints;
import '../core/usage_stats.dart' show formatBytes;
import '../core/warp/warp_profile.dart' show WarpMethod, isMasqueKind;
import '../core/warp/warp_store.dart';
import '../l10n/extra.dart';
import '../state/app_state.dart';
import '../state/warp_controller.dart';

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

  /// A sheet with every way of reaching WARP: the user picks one.
  Future<void> _pickMethod() async {
    final list = await warp.choices();
    if (!mounted || list.isEmpty) return;
    final now = warp.currentChoice(list);
    // One line per method: the ways of one method differ only in address and port, and the scan picks
    // those. The line stands for the first (best) way of its method.
    final firsts = <int>[];
    final seen = <String>{};
    for (var i = 0; i < list.length; i++) {
      if (seen.add(list[i].method.id)) firsts.add(i);
    }
    final nowId = now >= 0 ? list[now].method.id : warp.custom?.method;
    final index = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (c, scroll) => Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(tr(c, 'warpPickMethod'), style: Theme.of(c).textTheme.titleMedium),
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: scroll,
              itemCount: firsts.length,
              itemBuilder: (c, g) {
                final w = list[firsts[g]];
                final on = w.method.id == nowId;
                return ListTile(
                  selected: on,
                  leading: Icon(isMasqueKind(w.method.kind) ? Icons.hub_outlined : Icons.vpn_key_outlined),
                  title: Text(w.method.id, textDirection: TextDirection.ltr),
                  subtitle: Text(_kindText(c, w.method)),
                  trailing: on ? const Icon(Icons.check) : null,
                  onTap: () => Navigator.pop(c, firsts[g]),
                );
              },
            ),
          ),
        ]),
      ),
    );
    if (index != null && list[index].method.id != nowId) await warp.pick(index);
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

  /// A short description of how a method connects, for the list of methods.
  String _kindText(BuildContext context, WarpMethod m) => switch (m.kind) {
        'wg-plain' => tr(context, 'warpKindWg'),
        'wg-noise' => tr(context, 'warpKindNoise'),
        'masque-h2' => tr(context, m.id.endsWith('-alt') ? 'warpKindH2Alt' : 'warpKindH2'),
        'masque-h3' => tr(context, m.id.endsWith('-alt') ? 'warpKindH3Alt' : 'warpKindH3'),
        _ => m.kind,
      };

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
          final chosen = warp.config != null && identical(widget.state.selected, warp.config);
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
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr(context, 'warpDesc')),
                    const SizedBox(height: 8),
                    Text(tr(context, 'warpBeta'),
                        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
                  ]),
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
                )
              else ...[
                Card(
                  margin: EdgeInsets.zero,
                  child: Column(children: [
                    ListTile(
                      leading: const Icon(Icons.check_circle_outline),
                      title: Text(tr(context, 'warpReady')),
                      subtitle: Text(
                        tr(context, 'warpMethod', {
                          'method': warp.currentMethod ?? '',
                          'address': warp.currentAddress ?? '',
                        }),
                        textDirection: TextDirection.ltr,
                      ),
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
                const SizedBox(height: 8),
                ListTile(
                  leading: const Icon(Icons.list_alt),
                  title: Text(tr(context, 'warpPickMethod')),
                  subtitle: Text(tr(context, 'warpPickMethodDesc')),
                  onTap: warp.busy || warp.scanning ? null : _pickMethod,
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
                ListTile(
                  leading: const Icon(Icons.swap_horiz),
                  title: Text(tr(context, 'warpTryNext')),
                  subtitle: Text(tr(context, 'warpTryNextDesc')),
                  onTap: warp.busy || warp.scanning ? null : warp.nextMethod,
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
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(tr(context, 'warpScanNone'), style: TextStyle(color: scheme.error)),
                  ),
                for (final r in warp.scanResults)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(72, 0, 16, 4),
                    child: Text('${r.text}  ${r.ms} ms', textDirection: TextDirection.ltr),
                  ),
                SwitchListTile(
                  secondary: const Icon(Icons.layers_outlined),
                  title: Text(tr(context, 'warpInWarp')),
                  subtitle: Text(tr(context, 'warpInWarpDesc')),
                  value: warp.inWarp,
                  onChanged: warp.busy || warp.scanning ? null : warp.setInWarp,
                ),
              ],
              if (warp.error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(warp.error!, style: TextStyle(color: scheme.error)),
                ),
              if (warp.account != null) ...[
                const SizedBox(height: 8),
                Card(
                  margin: EdgeInsets.zero,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: Text(tr(context, 'warpUsed'),
                          style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w600)),
                    ),
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
                ),
              ],              const Divider(height: 24),
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
            ],
          );
        },
      ),
    );
  }
}
