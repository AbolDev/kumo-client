import 'package:flutter/material.dart';

import '../l10n/extra.dart';
import '../l10n/strings.dart';
import '../core/usage_stats.dart' show formatBytes;
import '../state/app_state.dart';

String _two(int n) => n.toString().padLeft(2, '0');

String _date(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.year}-${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';
}

/// The public servers list: where it comes from, when it was downloaded, and whether servers that
/// ask for their TLS certificate not to be checked are used (off by default).
class CollectorInfoPage extends StatelessWidget {
  const CollectorInfoPage({super.key, required this.state});

  final AppState state;

  Widget _card(BuildContext context, String title, List<Widget> children) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(title,
                  style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w600)),
            ),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _row(IconData icon, String title, String value) => ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(value, textDirection: TextDirection.ltr),
      );

  @override
  Widget build(BuildContext context) {
    final t = S.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([state, state.traffic]),
      builder: (context, _) {
        final group = state.collector;
        final source = state.collectorSource;
        final host = source == null ? null : (Uri.tryParse(source)?.host ?? source);
        final asking = state.collectorInsecureCount;
        final busy = state.refreshing.contains(group.id);
        return Scaffold(
          appBar: AppBar(title: Text(t.collectorGroup)),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              _card(context, tr(context, 'subscription'), [
                _row(Icons.dns_outlined, tr(context, 'serversCount'), '${group.configs.length}'),
                _row(Icons.history, tr(context, 'lastUpdated'),
                    group.updatedAt == 0 ? tr(context, 'never') : _date(group.updatedAt)),
                _row(Icons.cloud_download_outlined, tr(context, 'collSource'),
                    host ?? tr(context, 'collNotYet')),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: FilledButton.tonalIcon(
                      onPressed: busy ? null : state.refreshCollector,
                      icon: const Icon(Icons.refresh),
                      label: Text(tr(context, 'updateNow')),
                    ),
                  ),
                ),
              ]),
              _card(context, tr(context, 'pubUsage'), [
                _row(Icons.arrow_downward, tr(context, 'pubDown'),
                    formatBytes(state.publicUsage[0])),
                _row(Icons.arrow_upward, tr(context, 'pubUp'), formatBytes(state.publicUsage[1])),
                _row(Icons.swap_vert, tr(context, 'pubTotal'),
                    formatBytes(state.publicUsage[0] + state.publicUsage[1])),
              ]),
              _card(context, tr(context, 'collSecurity'), [
                SwitchListTile(
                  secondary: Icon(state.collectorAllowInsecure
                      ? Icons.gpp_maybe_outlined
                      : Icons.verified_user_outlined),
                  title: Text(tr(context, 'collAllowInsecure')),
                  subtitle: Text(tr(context, 'collAllowInsecureDesc')),
                  value: state.collectorAllowInsecure,
                  onChanged: state.setCollectorInsecure,
                ),
                if (group.configs.isNotEmpty)
                  ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: Text(tr(context, 'collInsecureCount',
                        {'n': asking, 'total': group.configs.length})),
                  ),
              ]),
            ],
          ),
        );
      },
    );
  }
}
