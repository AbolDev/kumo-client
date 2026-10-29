import 'package:flutter/material.dart';

import '../l10n/extra.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'collector_info_page.dart';
import 'warp_page.dart';

/// The free ways to connect, each one on or off, with a page to manage it. The public servers are on
/// by default; WARP is off until the user turns it on.
class FreeConnectionsPage extends StatelessWidget {
  const FreeConnectionsPage({super.key, required this.state});

  final AppState state;

  Widget _card({
    required BuildContext context,
    required IconData icon,
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
                  MaterialPageRoute<void>(builder: (_) => CollectorInfoPage(state: state)),
                ),
              ),
              _card(
                context: context,
                icon: Icons.cloud_outlined,
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
                  MaterialPageRoute<void>(builder: (_) => WarpPage(state: state)),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
