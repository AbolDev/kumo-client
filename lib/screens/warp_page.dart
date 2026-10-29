import 'package:flutter/material.dart';

import '../core/usage_stats.dart' show formatBytes;
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
                      : const Icon(Icons.cloud_outlined),
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
                  leading: const Icon(Icons.swap_horiz),
                  title: Text(tr(context, 'warpTryNext')),
                  subtitle: Text(tr(context, 'warpTryNextDesc')),
                  onTap: warp.busy ? null : warp.nextMethod,
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
