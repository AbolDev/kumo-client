import 'package:flutter/material.dart';

import '../core/ip_info.dart';
import '../l10n/extra.dart';
import '../state/app_state.dart';

/// The DNS leak test: which DNS servers answer the names this device looks up, and whether
/// they are in the same country as the VPN address.
class DnsLeakPage extends StatefulWidget {
  const DnsLeakPage({super.key, required this.state});

  final AppState state;

  @override
  State<DnsLeakPage> createState() => _DnsLeakPageState();
}

class _DnsLeakPageState extends State<DnsLeakPage> {
  DnsLeakResult? _result;
  var _loading = true;
  var _failed = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    DnsLeakResult? result;
    try {
      result = await runDnsLeakTest(proxyPort: widget.state.localProxyPort);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _result = result;
      _failed = result == null;
      _loading = false;
    });
  }

  Widget _entry(DnsLeakEntry e, DnsEntryKind kind, ColorScheme scheme) {
    final (icon, color, label) = switch (kind) {
      DnsEntryKind.safe => (Icons.check_circle, Colors.green.shade600, 'dnsKindSafe'),
      DnsEntryKind.publicDns => (Icons.public, Colors.orange.shade700, 'dnsKindPublic'),
      DnsEntryKind.leak => (Icons.warning_amber_rounded, scheme.error, 'dnsKindLeak'),
    };
    final name = publicDnsName(e);
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: color.withValues(alpha: 0.15),
        child: Icon(icon, color: color),
      ),
      title: SelectableText(e.ip, textDirection: TextDirection.ltr),
      subtitle: Text(
          [e.country, if (name != null) name else e.org, if (e.asn.isNotEmpty) e.asn]
              .where((s) => s.isNotEmpty)
              .join(' · '),
          textDirection: TextDirection.ltr),
      trailing: Text(tr(context, label), style: TextStyle(color: color, fontWeight: FontWeight.w600)),
    );
  }

  Widget _address(DnsLeakEntry e) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: scheme.primaryContainer,
        child: Icon(Icons.public, color: scheme.onPrimaryContainer),
      ),
      title: SelectableText(e.ip, textDirection: TextDirection.ltr),
      subtitle: Text([e.country, e.org].where((s) => s.isNotEmpty).join(' · '),
          textDirection: TextDirection.ltr),
    );
  }
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final r = _result;
    final judged = r == null ? null : judgeDnsLeak(r);
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'menuDnsLeak')),
        actions: [
          IconButton(
            tooltip: tr(context, 'ipRefresh'),
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _run,
          ),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: _loading
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(tr(context, 'dnsLeakRunning')),
                  ]),
                )
              : _failed || r == null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.cloud_off, size: 56, color: scheme.error),
                          const SizedBox(height: 12),
                          Text(tr(context, 'ipFailed'), textAlign: TextAlign.center),
                          const SizedBox(height: 16),
                          FilledButton.icon(
                              onPressed: _run,
                              icon: const Icon(Icons.refresh),
                              label: Text(tr(context, 'ipRefresh'))),
                        ]),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        _verdict(judged!.verdict, scheme),
                        const SizedBox(height: 16),
                        if (r.address != null) ...[
                          Text(tr(context, 'dnsLeakYourAddress'),
                              style: Theme.of(context).textTheme.titleSmall),
                          _address(r.address!),
                          const SizedBox(height: 8),
                        ],
                        Text(tr(context, 'dnsLeakServers', {'n': r.resolvers.length}),
                            style: Theme.of(context).textTheme.titleSmall),
                        if (r.resolvers.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(tr(context, 'dnsLeakNone')),
                          ),
                        for (final e in r.resolvers)
                          _entry(e, judged!.kinds[e] ?? DnsEntryKind.safe, scheme),
                        const SizedBox(height: 12),
                        Text(
                          tr(context, 'dnsLeakNote'),
                          textAlign: TextAlign.center,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
        ),
      ),
    );
  }

  Widget _verdict(DnsLeakVerdict v, ColorScheme scheme) {
    final (icon, color, title, text) = switch (v) {
      DnsLeakVerdict.unknown => (Icons.help_outline, scheme.outline, 'dnsLeakUnknown', 'dnsLeakUnknownDesc'),
      DnsLeakVerdict.leak => (Icons.warning_amber_rounded, scheme.error, 'dnsLeakYes', 'dnsLeakYesDesc'),
      DnsLeakVerdict.possible => (Icons.info_outline, Colors.orange.shade700, 'dnsLeakPossible', 'dnsLeakPossibleDesc'),
      DnsLeakVerdict.ok => (Icons.verified_user, Colors.green.shade600, 'dnsLeakNo', 'dnsLeakNoDesc'),
    };    return Card(
      elevation: 0,
      color: color.withValues(alpha: 0.12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: color.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(children: [
          Icon(icon, size: 48, color: color),
          const SizedBox(height: 8),
          Text(tr(context, title),
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700, color: color)),
          const SizedBox(height: 6),
          Text(tr(context, text), textAlign: TextAlign.center),
        ]),
      ),
    );
  }
}
