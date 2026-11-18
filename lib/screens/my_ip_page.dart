import 'dart:io' show Platform;

import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../core/ip_info.dart';
import '../core/network_path.dart' show ipOperator;
import '../l10n/extra.dart';
import '../state/app_state.dart';
import 'share_sheet.dart';

/// "What is my IP": the IPv4 and IPv6 addresses, the country and the city that public services
/// see for this connection (through the VPN when it is on).
class MyIpPage extends StatefulWidget {
  const MyIpPage({super.key, required this.state});

  final AppState state;

  @override
  State<MyIpPage> createState() => _MyIpPageState();
}

class _MyIpPageState extends State<MyIpPage> {
  IpView? _view;
  var _loading = true;
  var _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    IpView? view;
    try {
      view = await fetchIpView(proxyPort: widget.state.localProxyPort, connected: widget.state.connected);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _view = view;
      _failed = view == null;
      _loading = false;
    });
  }

  String _flag(String? code) {
    if (code == null || code.length != 2) return '';
    final up = code.toUpperCase().codeUnits;
    return String.fromCharCodes([for (final c in up) 0x1F1E6 + c - 0x41]);
  }

  /// The flag of a country: a picture where the system's font has no flag emoji (Windows shows the two
  /// letters instead, Linux often has no font), the emoji elsewhere. Null when the code is not one.
  Widget? _flagOf(String? code) {
    if (code == null || !RegExp(r'^[A-Za-z]{2}$').hasMatch(code)) return null;
    if (Platform.isWindows || Platform.isLinux) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: CountryFlag.fromCountryCode(code.toUpperCase(), height: 18, width: 26),
      );
    }
    return Text(_flag(code), style: const TextStyle(fontSize: 20));
  }

  Widget _row(IconData icon, String label, String? value, {bool copy = false, Widget? flag}) {
    final scheme = Theme.of(context).colorScheme;
    final text = value == null || value.isEmpty ? '—' : value;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: scheme.primaryContainer,
        child: flag ?? Icon(icon, color: scheme.onPrimaryContainer),
      ),
      title: Text(label),
      subtitle: SelectableText(text,
          textDirection: TextDirection.ltr,
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontWeight: FontWeight.w600)),
      trailing: copy && value != null && value.isNotEmpty
          ? IconButton(
              tooltip: MaterialLocalizations.of(context).copyButtonLabel,
              icon: const Icon(Icons.copy),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: value));
                toast(context, tr(context, 'ipCopied'));
              },
            )
          : null,
    );
  }

  /// The rows of one view of the connection, in a card; [heading] names it when there are two.
  Widget _infoCard(IpInfo info, {String? heading}) {
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (heading != null)
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 8, bottom: 6),
          child: Text(heading, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ),
      Card(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        child: Column(children: [
          _row(Icons.looks_4, 'IPv4', info.v4, copy: true),
          _row(Icons.looks_6, 'IPv6', info.v6 ?? tr(context, 'ipNoV6'), copy: info.v6 != null),
          _row(Icons.public, tr(context, 'ipCountry'), info.country, flag: _flagOf(info.countryCode)),
          _row(Icons.location_city, tr(context, 'ipCity'),
              [info.city, info.region].where((e) => e != null && e.isNotEmpty).join(', ')),
          // The operator with the name people know it by after it: Mobile Communication Company of Iran (MCI, Hamrah Aval).
          _row(Icons.business, tr(context, 'ipIsp'), ipOperator(info)),
        ]),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final view = _view;
    final info = view?.exit ?? view?.mine;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'menuMyIp')),
        actions: [
          IconButton(
            tooltip: tr(context, 'ipRefresh'),
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _failed || info == null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.cloud_off, size: 56, color: scheme.error),
                          const SizedBox(height: 12),
                          Text(tr(context, 'ipFailed'), textAlign: TextAlign.center),
                          const SizedBox(height: 16),
                          FilledButton.icon(
                              onPressed: _load,
                              icon: const Icon(Icons.refresh),
                              label: Text(tr(context, 'ipRefresh'))),
                        ]),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        if (view!.mine != null && view.exit != null) ...[
                          _infoCard(view.mine!, heading: tr(context, 'pathYou')),
                          const SizedBox(height: 12),
                          _infoCard(view.exit!, heading: tr(context, 'pathExit')),
                        ] else
                          _infoCard(info),
                        const SizedBox(height: 12),
                        Text(
                          tr(context, widget.state.connected ? 'ipThroughVpn' : 'ipNoVpn'),
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
}
