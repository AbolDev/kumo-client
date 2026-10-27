import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/extra.dart';
import '../state/app_state.dart';
import '../l10n/strings.dart';
import 'network_settings.dart' show pickOption;

String _size(int b) {
  if (b >= 1 << 40) return '${(b / (1 << 40)).toStringAsFixed(2)} TB';
  if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
  if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
  if (b >= 1 << 10) return '${(b / (1 << 10)).toStringAsFixed(0)} KB';
  return '$b B';
}

String _two(int n) => n.toString().padLeft(2, '0');

String _date(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.year}-${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';
}

/// Usage, update interval and the provider's routing rules of one subscription.
class SubscriptionInfoPage extends StatelessWidget {
  const SubscriptionInfoPage({super.key, required this.state, required this.group});

  final AppState state;
  final ServerGroup group;

  String _hours(BuildContext context, int h) =>
      tr(context, 'hoursShort').replaceAll('{n}', '$h');

  Future<void> _editInterval(BuildContext context) async {
    final current = group.intervalHours ?? state.subInterval;
    final options = <int>{1, 2, 3, 6, 12, 24, 48, 72, 168, current}.toList()..sort();
    final v = await pickOption<int>(context, tr(context, 'updateInterval'), current,
        {for (final h in options) h: _hours(context, h)});
    if (v != null) state.setSubscriptionInterval(group, v);
  }

  Widget _row(BuildContext context, IconData icon, String title, String? value,
      {VoidCallback? onTap, Widget? trailing, String? subtitle}) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: subtitle != null
          ? Text(subtitle)
          : (value != null ? Text(value) : null),
      trailing: trailing,
      onTap: onTap,
    );
  }

  Widget _link(BuildContext context, IconData icon, String title, String url) =>
      _row(context, icon, title, null,
          subtitle: ltr(url),
          trailing: const Icon(Icons.copy, size: 18),
          onTap: () {
            Clipboard.setData(ClipboardData(text: url));
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(SnackBar(content: Text(S.of(context).copied)));
          });

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
                  style: TextStyle(
                      color: scheme.primary, fontWeight: FontWeight.w600)),
            ),
            ...children,
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final info = group.info;
        final routing = group.routing;
        final hasRules = routing != null && !routing.isEmpty;
        final providerWants = group.routingByProvider;
        final interval = group.intervalHours ?? state.subInterval;
        final source = group.customInterval != null
            ? tr(context, 'intervalYours')
            : group.providerInterval != null
                ? tr(context, 'intervalProvider')
                : tr(context, 'intervalDefault');
        final busy = state.refreshing.contains(group.id);
        return Scaffold(
          appBar: AppBar(title: Text(group.name)),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              _card(context, tr(context, 'subUsage'), [
                if (info == null)
                  _row(context, Icons.info_outline, tr(context, 'noInfo'), null)
                else ...[
                  _row(context, Icons.arrow_downward, tr(context, 'downloaded'),
                      _size(info.download)),
                  _row(context, Icons.arrow_upward, tr(context, 'uploaded'),
                      _size(info.upload)),
                  _row(context, Icons.data_usage, tr(context, 'usedTotal'),
                      _size(info.used)),
                  _row(
                      context,
                      Icons.storage,
                      tr(context, 'volume'),
                      info.unlimitedData
                          ? tr(context, 'unlimited')
                          : _size(info.total)),
                  if (!info.unlimitedData)
                    _row(context, Icons.hourglass_bottom, tr(context, 'remaining'),
                        _size((info.total - info.used).clamp(0, 1 << 62).toInt())),
                  _row(
                      context,
                      Icons.event,
                      tr(context, 'expiry'),
                      info.unlimitedTime
                          ? tr(context, 'unlimited')
                          : _date(info.expire * 1000)),
                ],
              ]),
              _card(context, tr(context, 'updating'), [
                _row(
                    context,
                    Icons.history,
                    tr(context, 'lastUpdated'),
                    group.updatedAt == 0
                        ? tr(context, 'never')
                        : _date(group.updatedAt)),
                _row(context, Icons.timer_outlined, tr(context, 'updateInterval'), null,
                    subtitle: '${_hours(context, interval)} · $source',
                    trailing: const Icon(Icons.edit, size: 18),
                    onTap: () => _editInterval(context)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: group.customInterval == null
                            ? null
                            : () => state.setSubscriptionInterval(group, null),
                        icon: const Icon(Icons.settings_backup_restore),
                        label: Text(tr(context, 'intervalReset')),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: busy ? null : () => state.refreshSubscription(group),
                        icon: const Icon(Icons.refresh),
                        label: Text(tr(context, 'updateNow')),
                      ),
                    ],
                  ),
                ),
              ]),
              _card(context, tr(context, 'providerRouting'), [
                if (!hasRules)
                  _row(context, Icons.alt_route, tr(context, 'noRouting'), null,
                      subtitle: tr(context, 'noRoutingDesc'))
                else ...[
                  SwitchListTile(
                    secondary: const Icon(Icons.alt_route),
                    title: Text(tr(context, 'applyRouting')),
                    subtitle: Text(providerWants
                        ? tr(context, 'applyRoutingDesc')
                        : tr(context, 'routingDisabledByProvider')),
                    value: group.routingOn && providerWants,
                    onChanged: providerWants
                        ? (v) => state.setSubscriptionRouting(group, v)
                        : null,
                  ),
                  if (routing.name.isNotEmpty)
                    _row(context, Icons.label_outline, tr(context, 'routingName'),
                        routing.name),
                  _row(context, Icons.call_split, tr(context, 'routingRules'),
                      '${tr(context, 'routingDirect')}: ${routing.directSites.length + routing.directIp.length}'
                      ' · ${tr(context, 'routingProxy')}: ${routing.proxySites.length + routing.proxyIp.length}'
                      ' · ${tr(context, 'routingBlock')}: ${routing.blockSites.length + routing.blockIp.length}'),
                  _row(
                      context,
                      Icons.public,
                      tr(context, 'routingOthers'),
                      routing.globalProxy
                          ? tr(context, 'routingProxy')
                          : tr(context, 'routingDirect')),
                ],
              ]),
              if (group.supportUrl != null ||
                  group.webPage != null ||
                  (group.announce ?? '').isNotEmpty)
                _card(context, tr(context, 'provider'), [
                  if ((group.announce ?? '').isNotEmpty)
                    _row(context, Icons.campaign_outlined, tr(context, 'announcement'),
                        group.announce),
                  if (group.webPage != null)
                    _link(context, Icons.language, tr(context, 'webPage'),
                        group.webPage!),
                  if (group.supportUrl != null)
                    _link(context, Icons.support_agent, tr(context, 'supportLink'),
                        group.supportUrl!),
                ]),
              _card(context, tr(context, 'subscription'), [
                _row(context, Icons.dns_outlined, tr(context, 'serversCount'),
                    '${group.configs.length}'),
              ]),
            ],
          ),
        );
      },
    );
  }
}
