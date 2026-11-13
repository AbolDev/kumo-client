import 'package:flutter/material.dart';

import '../l10n/extra.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'logs_page.dart';
import 'clean_ip_page.dart';
import 'dns_leak_page.dart';
import 'my_ip_page.dart';
import 'service_test_page.dart';
import 'speed_test_page.dart';
import 'troubleshoot_page.dart';
import 'tune_page.dart';

/// The tools of the app, each with a line about what it does: what the internet sees of the user, a check
/// for leaks, the services, the best settings for the network and clean addresses.
class ToolsPage extends StatelessWidget {
  const ToolsPage({super.key, required this.state});

  final AppState state;

  Widget _card(BuildContext context, IconData icon, String title, String text, String route, Widget Function() page) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        contentPadding: const EdgeInsetsDirectional.fromSTEB(16, 8, 12, 8),
        leading: CircleAvatar(
          backgroundColor: scheme.primaryContainer,
          child: Icon(icon, color: scheme.onPrimaryContainer),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(text),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute<void>(settings: RouteSettings(name: route), builder: (_) => page()),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(tr(context, 'toolsTitle'))),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            _card(context, Icons.my_location, tr(context, 'menuMyIp'), tr(context, 'toolsMyIpDesc'), '/MyIpPage',
                () => MyIpPage(state: state)),
            _card(context, Icons.dns_outlined, tr(context, 'menuDnsLeak'), tr(context, 'toolsDnsLeakDesc'),
                '/DnsLeakPage', () => DnsLeakPage(state: state)),
            _card(context, Icons.public, tr(context, 'menuServices'), tr(context, 'toolsServicesDesc'),
                '/ServiceTestPage', () => ServiceTestPage(state: state)),
            _card(context, Icons.speed, tr(context, 'speedTitle'), tr(context, 'toolsSpeedDesc'), '/SpeedTestPage',
                () => SpeedTestPage(state: state)),
            _card(context, Icons.tune, tr(context, 'tuneTitle'), tr(context, 'toolsTuneDesc'), '/TunePage',
                () => TunePage(state: state)),
            _card(context, Icons.help_outline, tr(context, 'menuTroubleshoot'), tr(context, 'toolsTroubleshootDesc'),
                '/TroubleshootPage', () => TroubleshootPage(state: state)),
            _card(context, Icons.travel_explore, tr(context, 'cleanIpButton'), tr(context, 'toolsCleanIpDesc'),
                '/CleanIpPage', () => CleanIpPage(state: state)),
            _card(context, Icons.receipt_long, S.of(context).logs, tr(context, 'toolsLogsDesc'), '/LogsPage',
                () => LogsPage(state: state)),
          ],
        ),
      );
}
