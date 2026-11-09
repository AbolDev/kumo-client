import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import '../widgets/kumo_mark.dart';

import '../l10n/extra.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'collector_info_page.dart';
import 'share_sheet.dart' show ToastKind, toast;
import 'warp_page.dart';

/// The free ways to connect, each one on or off, with a page to manage it. The public servers are on
/// by default; WARP is off until the user turns it on.
class FreeConnectionsPage extends StatelessWidget {
  const FreeConnectionsPage({super.key, required this.state});

  final AppState state;

  Widget _card({
    required BuildContext context,
    required IconData? icon, // null: the app's own cloud
    required String title,
    required String description,
    required String? status,
    required bool value,
    required bool busy,
    required ValueChanged<bool> onChanged,
    required VoidCallback onManage,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(children: [
        SwitchListTile(
          secondary: busy
              ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
              : icon == null
                  ? const KumoMark(size: 24)
                  : Icon(icon),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text([description, if (status != null) status].join('\n')),
          isThreeLine: status != null,
          value: value,
          onChanged: busy ? null : onChanged,
        ),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(end: 12, bottom: 8),
            child: TextButton.icon(
              onPressed: onManage,
              icon: Icon(Icons.tune, size: 18, color: scheme.primary),
              label: Text(tr(context, 'freeManage')),
            ),
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = S.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'freeConnections'))),
      body: ListenableBuilder(
        listenable: Listenable.merge([state, state.warp]),
        builder: (context, _) {
          final warp = state.warp;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(tr(context, 'freeConnectionsDesc'),
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ),
              _card(
                context: context,
                icon: Icons.public,
                title: t.showCollector,
                description: t.showCollectorDesc,
                status: state.showCollector ? '${state.collector.configs.length}' : null,
                value: state.showCollector,
                busy: false,
                onChanged: (v) => state.setFlag('showCollector', v),
                onManage: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(settings: const RouteSettings(name: '/CollectorInfoPage'), builder: (_) => CollectorInfoPage(state: state)),
                ),
              ),
              _card(
                context: context,
                icon: null,
                title: tr(context, 'warpTitle'),
                description: tr(context, 'freeWarpDesc'),
                status: warp.error ??
                    (warp.enabled
                        ? tr(context, 'warpMethod', {
                            'method': warp.currentMethod ?? '',
                            'address': warp.currentAddress ?? '',
                          })
                        : warp.account == null
                            ? tr(context, 'freeOnWillSetUp')
                            : null),
                value: warp.enabled,
                busy: warp.busy,
                onChanged: (v) => v ? warp.enable() : warp.disable(),
                onManage: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(settings: const RouteSettings(name: '/WarpPage'), builder: (_) => WarpPage(state: state)),
                ),
              ),
              // OpenVPN runs on Windows and Android for now.
              if (Platform.isWindows || Platform.isAndroid) _vpnGate(context),
            ],
          );
        },
      ),
    );
  }

  Widget _vpnGate(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: state.vpnGateBusy,
      // Laid out like the other cards: the text has the whole width, the action is below it (a button
      // beside the text left it a narrow column, one word a line).
      builder: (context, busy, _) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Column(children: [
          ListTile(
            leading: busy
                ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.vpn_lock_outlined),
            title: Text(tr(context, 'vpngateTitle'), style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(tr(context, 'vpngateDesc')),
          ),
          // What is there already, and when it came.
          if (state.vpnGateCount > 0)
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(72, 0, 16, 8),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  tr(context, 'vpngateStatus', {
                    'n': state.vpnGateCount,
                    'when': state.vpnGateUpdated == 0
                        ? '-'
                        : MaterialLocalizations.of(context).formatShortDate(DateTime.fromMillisecondsSinceEpoch(state.vpnGateUpdated)),
                  }),
                  style: TextStyle(color: Theme.of(context).colorScheme.primary),
                ),
              ),
            ),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Padding(
              padding: const EdgeInsetsDirectional.only(end: 12, bottom: 12),
              child: FilledButton.tonalIcon(
                icon: Icon(state.vpnGateCount > 0 ? Icons.refresh : Icons.download, size: 18),
                onPressed: busy
                ? null
                : () async {
                    final failed = tr(context, 'vpngateFailed');
                    String added(int n) => tr(context, 'vpngateAdded', {'n': '$n'});
                    String text;
                    try {
                      final n = await state.addVpnGate();
                      text = n == 0 ? failed : added(n);
                    } catch (_) {
                      text = failed;
                    }
                    if (context.mounted) toast(context, text, kind: text == failed ? ToastKind.error : ToastKind.ok);
                  },
                label: Text(tr(context, state.vpnGateCount > 0 ? 'vpngateUpdate' : 'vpngateGet')),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
