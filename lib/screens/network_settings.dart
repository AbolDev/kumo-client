import 'dart:io' show InternetAddressType, NetworkInterface, Platform;
import 'dart:math' show Random;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../core/net_options.dart';
import '../core/proxy_config.dart';
import '../core/vpn_channel.dart';
import '../l10n/extra.dart';
import '../state/app_state.dart';
import 'app_routing_page.dart';
import 'routing_rules_page.dart';
import 'share_sheet.dart';

typedef SectionBuilder = Widget Function(
    IconData icon, String title, List<Widget> children);

/// The Settings sections about how traffic is carried: tunnel, proxy port, per-app routing,
/// Iran bypass, kill switch, DNS, and the advanced protocol options.
List<Widget> networkSections(
    BuildContext context, AppState state, SectionBuilder section) {
  final o = state.net;
  final win = Platform.isWindows;

  Widget flag(String title, String desc, bool value, void Function(bool) set) =>
      SwitchListTile(
        value: value,
        onChanged: (v) => state.updateNet((o) => set(v)),
        title: Text(title),
        subtitle: Text(desc),
      );

  final modeText = switch (o.appMode) {
    AppMode.all => tr(context, 'appModeAll'),
    AppMode.only => tr(context, 'appModeOnly'),
    AppMode.except => tr(context, 'appModeExcept'),
  };

  return [
    section(Icons.lan, tr(context, 'network'), [
      // On Windows this switch lives on the home screen.
      if (!win)
        flag(tr(context, 'tun'), tr(context, 'tunDesc'), o.tun,
            (v) => o.tun = v),
      ListTile(
        leading: const Icon(Icons.numbers),
        title: Text(tr(context, 'proxyPort')),
        subtitle: Text(tr(context, 'proxyPortDesc', {'port': o.proxyPort})),
        onTap: () => _editPort(context, state),
      ),
      ListTile(
        leading: const Icon(Icons.apps_outage),
        title: Text(tr(context, 'appRouting')),
        subtitle: Text(modeText),
        trailing: o.apps.isEmpty ? null : Text('${o.apps.length}'),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute<void>(
              builder: (_) => AppRoutingPage(state: state)),
        ),
      ),
      ListTile(
        leading: const Icon(Icons.public),
        title: Text(tr(context, 'bypassCountries')),
        subtitle: Text(o.bypass.isEmpty
            ? tr(context, 'bypassCountriesDesc')
            : o.bypass.map((c) => bypassCountries[c] ?? c.toUpperCase()).join(', ')),
        onTap: () => _pickCountries(context, state),
      ),
      ListTile(
        leading: const Icon(Icons.alt_route),
        title: Text(tr(context, 'ruleTitle')),
        subtitle: Text(tr(context, 'ruleDesc')),
        trailing: o.directRules.length + o.proxyRules.length == 0
            ? null
            : Text('${o.directRules.length + o.proxyRules.length}'),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => RoutingRulesPage(state: state)),
        ),
      ),
      flag(tr(context, 'killSwitch'), tr(context, 'killSwitchDesc'),
          o.killSwitch, (v) => o.killSwitch = v),
      if (!win)
        ListTile(
          leading: const Icon(Icons.shield_outlined),
          title: Text(tr(context, 'vpnSettings')),
          onTap: VpnChannel.openVpnSettings,
        ),
      flag(tr(context, 'failover'), tr(context, 'failoverDesc'), o.failover,
          (v) => o.failover = v),
      SwitchListTile(
        value: o.shareLan,
        onChanged: (v) => state.updateNet((o) {
          o.shareLan = v;
          if (v && o.lanPassword.isEmpty) o.lanPassword = _newPassword();
          if (v && o.lanPort == o.proxyPort) o.lanPort = o.proxyPort + 1;
        }),
        secondary: const Icon(Icons.wifi_tethering),
        title: Text(tr(context, 'lanShare')),
        subtitle: Text(tr(context, 'lanShareDesc')),
      ),
      if (o.shareLan) ..._lanTiles(context, state),
    ]),
    section(Icons.dns, tr(context, 'dns'), [
      RadioGroupLike(
        value: o.dns,
        items: {
          for (final p in dnsPresets) p.id: p.name,
          'custom': tr(context, 'dnsCustom'),
        },
        onChanged: (v) => state.updateNet((o) => o.dns = v),
      ),
      if (o.dns == 'custom')
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextFormField(
            initialValue: o.customDns,
            textDirection: TextDirection.ltr,
            onFieldSubmitted: (v) => state.updateNet((o) => o.customDns = v),
            onTapOutside: (_) {},
            decoration: const InputDecoration(
                hintText: 'https://dns.example/dns-query',
                border: OutlineInputBorder()),
          ),
        ),
      ListTile(
        leading: const Icon(Icons.travel_explore),
        title: Text(tr(context, 'dnsCheck')),
        onTap: () => _leakCheck(context, state),
      ),
    ]),
    section(Icons.tune, tr(context, 'advanced'), [
      flag(tr(context, 'tlsFragment'), tr(context, 'tlsFragmentDesc'),
          o.tlsFragment, (v) => o.tlsFragment = v),
      flag(tr(context, 'mux'), tr(context, 'muxDesc'), o.mux,
          (v) => o.mux = v),
      ListTile(
        leading: const Icon(Icons.straighten),
        title: Text(tr(context, 'mtu')),
        trailing: Text('${o.mtu}'),
        onTap: () => _editMtu(context, state),
      ),
      ListTile(
        leading: const Icon(Icons.fingerprint),
        title: Text(tr(context, 'fingerprint')),
        trailing: DropdownButton<String>(
          value: o.fingerprint,
          underline: const SizedBox.shrink(),
          items: [
            for (final f in fingerprints)
              DropdownMenuItem(
                  value: f,
                  child: Text(f.isEmpty ? tr(context, 'fingerprintDefault') : f)),
          ],
          onChanged: (v) => state.updateNet((o) => o.fingerprint = v ?? ''),
        ),
      ),
      ListTile(
        leading: const Icon(Icons.link),
        title: Text(tr(context, 'chain')),
        subtitle: Text(o.chain.isEmpty
            ? tr(context, 'chainDesc')
            : (parseLink(o.chain)?.name ?? tr(context, 'chainNone'))),
        trailing: o.chain.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => state.updateNet((o) => o.chain = ''),
              ),
        onTap: () => _pickChain(context, state),
      ),
    ]),
  ];
}

String _newPassword() {
  const chars = 'abcdefghjkmnpqrstuvwxyz23456789';
  final r = Random.secure();
  return List.generate(12, (_) => chars[r.nextInt(chars.length)]).join();
}

Future<void> _copy(BuildContext context, String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) toast(context, tr(context, 'lanCopied'));
}

/// The details another device needs to use the shared connection.
List<Widget> _lanTiles(BuildContext context, AppState state) {
  final o = state.net;
  return [
    Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Text(tr(context, 'lanNote'), style: Theme.of(context).textTheme.bodySmall),
    ),
    _LanAddress(port: o.lanPort),
    ListTile(
      leading: const Icon(Icons.numbers),
      title: Text(tr(context, 'lanPort')),
      trailing: Text('${o.lanPort}'),
      onTap: () => _editLanPort(context, state),
    ),
    ListTile(
      leading: const Icon(Icons.person_outline),
      title: Text(tr(context, 'lanUser')),
      subtitle: Text(o.lanUser, textDirection: TextDirection.ltr),
      onTap: () => _copy(context, o.lanUser),
    ),
    ListTile(
      leading: const Icon(Icons.key),
      title: Text(tr(context, 'lanPassword')),
      subtitle: Text(o.lanPassword, textDirection: TextDirection.ltr),
      onTap: () => _copy(context, o.lanPassword),
      trailing: IconButton(
        tooltip: tr(context, 'lanNewPassword'),
        icon: const Icon(Icons.refresh),
        onPressed: () => state.updateNet((o) => o.lanPassword = _newPassword()),
      ),
    ),
  ];
}

Future<void> _editLanPort(BuildContext context, AppState state) async {
  final controller = TextEditingController(text: '${state.net.lanPort}');
  final port = await showDialog<int>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(tr(dialog, 'lanPort')),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(border: OutlineInputBorder()),
        onSubmitted: (v) => Navigator.pop(dialog, int.tryParse(v)),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('✕')),
        FilledButton(
            onPressed: () => Navigator.pop(dialog, int.tryParse(controller.text)),
            child: const Text('OK')),
      ],
    ),
  );
  controller.dispose();
  if (port == null) return;
  if (port < 1024 || port > 65535 || port == state.net.proxyPort) {
    if (context.mounted) toast(context, tr(context, 'lanPortInvalid'));
    return;
  }
  await state.updateNet((o) => o.lanPort = port);
}

/// The address of this device on the local network, with the port: tap to copy.
class _LanAddress extends StatelessWidget {
  const _LanAddress({required this.port});

  final int port;

  static Future<List<String>> _addresses() async {
    try {
      final list = await NetworkInterface.list(type: InternetAddressType.IPv4);
      return [
        for (final i in list)
          for (final a in i.addresses)
            // not loopback, not link-local, not this app's own tunnel
            if (!a.isLoopback &&
                !a.address.startsWith('169.254.') &&
                !a.address.startsWith('172.19.0.'))
              a.address,
      ];
    } catch (_) {
      return const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<String>>(
      future: _addresses(),
      builder: (context, snap) {
        final list = snap.data ?? const <String>[];
        return ListTile(
          leading: const Icon(Icons.lan_outlined),
          title: Text(tr(context, 'lanAddress')),
          subtitle: Text(
            snap.connectionState != ConnectionState.done
                ? '…'
                : (list.isEmpty
                    ? tr(context, 'lanNoNetwork')
                    : list.map((a) => '$a:$port').join('\n')),
            textDirection: TextDirection.ltr,
          ),
          onTap: list.isEmpty ? null : () => _copy(context, '${list.first}:$port'),
        );
      },
    );
  }
}

/// A column of radio buttons built from a value -> label map.
class RadioGroupLike extends StatelessWidget {
  const RadioGroupLike(
      {super.key,
      required this.value,
      required this.items,
      required this.onChanged});

  final String value;
  final Map<String, String> items;
  final void Function(String) onChanged;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          for (final e in items.entries)
            RadioListTile<String>(
              value: e.key,
              groupValue: value,
              onChanged: (v) => onChanged(v!),
              title: Text(e.value),
              dense: true,
            ),
        ],
      );
}

Future<void> _editPort(BuildContext context, AppState state) async {
  final controller = TextEditingController(text: '${state.net.proxyPort}');
  final port = await showDialog<int>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(tr(dialog, 'proxyPort')),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(border: OutlineInputBorder()),
        onSubmitted: (v) => Navigator.pop(dialog, int.tryParse(v)),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(dialog), child: const Text('✕')),
        FilledButton(
            onPressed: () =>
                Navigator.pop(dialog, int.tryParse(controller.text)),
            child: const Text('OK')),
      ],
    ),
  );
  controller.dispose();
  if (port == null) return;
  if (port < 1024 || port > 65535) {
    if (context.mounted) toast(context, tr(context, 'invalidPort'));
    return;
  }
  await state.updateNet((o) => o.proxyPort = port);
}

Future<void> _editMtu(BuildContext context, AppState state) async {
  final controller = TextEditingController(text: '${state.net.mtu}');
  final mtu = await showDialog<int>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(tr(dialog, 'mtu')),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
            hintText: '1280 – 9000', border: OutlineInputBorder()),
        onSubmitted: (v) => Navigator.pop(dialog, int.tryParse(v)),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(dialog), child: const Text('✕')),
        FilledButton(
            onPressed: () =>
                Navigator.pop(dialog, int.tryParse(controller.text)),
            child: const Text('OK')),
      ],
    ),
  );
  controller.dispose();
  if (mtu == null || mtu < 1280 || mtu > 9000) return;
  await state.updateNet((o) => o.mtu = mtu);
}

Future<void> _leakCheck(BuildContext context, AppState state) async {
  toast(context, tr(context, 'dnsChecking'));
  final r = await state.checkLeak();
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).hideCurrentSnackBar();
  final text = r == null
      ? tr(context, 'dnsFailed')
      : '${tr(context, 'dnsResult', {
              'ip': r.ip,
              'country': r.country,
              'dns': state.net.dnsAddress,
            })}';
  await showDialog<void>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(tr(dialog, 'dnsCheck')),
      content: SelectableText(text, textDirection: TextDirection.ltr),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(dialog), child: const Text('OK')),
      ],
    ),
  );
}

Future<void> _pickChain(BuildContext context, AppState state) async {
  final choices = [
    for (final g in state.groups)
      if (g.kind != GroupKind.collector)
        for (final c in g.configs)
          if (!c.needsXray) c,
  ];
  final picked = await showDialog<ProxyConfig>(
    context: context,
    builder: (dialog) {
      var query = '';
      return StatefulBuilder(
        builder: (context, setState) {
          final shown = choices
              .where((c) => c.name.toLowerCase().contains(query.toLowerCase()))
              .take(200)
              .toList();
          return AlertDialog(
            title: Text(tr(context, 'chainPick')),
            content: SizedBox(
              width: 360,
              height: 420,
              child: Column(children: [
                TextField(
                  onChanged: (v) => setState(() => query = v),
                  decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      border: OutlineInputBorder()),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView(children: [
                    for (final c in shown)
                      ListTile(
                        dense: true,
                        title: Text(c.name, maxLines: 1),
                        subtitle: Text('${c.label} · ${c.maskedAddress}',
                            textDirection: TextDirection.ltr),
                        onTap: () => Navigator.pop(dialog, c),
                      ),
                  ]),
                ),
              ]),
            ),
          );
        },
      );
    },
  );
  if (picked != null) await state.updateNet((o) => o.chain = picked.link);
}

/// Chooses the countries whose sites go direct.
Future<void> _pickCountries(BuildContext context, AppState state) async {
  final chosen = state.net.bypass.toSet();
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialog) => StatefulBuilder(
      builder: (dialog, setState) => AlertDialog(
        title: Text(tr(dialog, 'bypassCountries')),
        content: SizedBox(
          width: 360,
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(tr(dialog, 'bypassCountriesDesc'),
                    style: Theme.of(dialog).textTheme.bodySmall),
              ),
              for (final e in bypassCountries.entries)
                CheckboxListTile(
                  dense: true,
                  value: chosen.contains(e.key),
                  title: Text(e.value),
                  secondary: Text(e.key.toUpperCase()),
                  onChanged: (v) => setState(() {
                    v == true ? chosen.add(e.key) : chosen.remove(e.key);
                  }),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text(MaterialLocalizations.of(dialog).cancelButtonLabel)),
          FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(MaterialLocalizations.of(dialog).okButtonLabel)),
        ],
      ),
    ),
  );
  if (ok == true) {
    state.updateNet((o) => o.bypass = bypassCountries.keys.where(chosen.contains).toList());
  }
}
