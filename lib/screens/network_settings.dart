import 'dart:io' show InternetAddress, InternetAddressType, NetworkInterface, ServerSocket;
import 'dart:math' show Random;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../core/net_options.dart';
import '../core/platform.dart';
import '../core/proxy_config.dart';
import '../core/singbox_config.dart' show parseExtraJson;
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
  final win = isDesktop; // the desktop has no per-phone options

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
      SwitchListTile(
        value: o.keepProxy,
        onChanged: (v) => state.updateNet((o) => o.keepProxy = v, reconnect: false),
        secondary: const Icon(Icons.hub_outlined),
        title: Text(tr(context, 'keepProxy')),
        subtitle: Text(tr(context, win ? 'keepProxyDesc' : 'keepProxyDescPhone', {'port': o.proxyPort})),
      ),
      ListTile(
        leading: const Icon(Icons.password),
        title: Text(tr(context, 'proxyLogin')),
        subtitle: Text(o.proxyUser.isEmpty || o.proxyPassword.isEmpty
            ? tr(context, 'proxyLoginOff')
            : tr(context, 'proxyLoginOn', {'user': o.proxyUser})),
        onTap: () => _editProxyLogin(context, state),
      ),      ListTile(
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
        trailing: o.directRules.length + o.proxyRules.length + o.blockRules.length == 0
            ? null
            : Text('${o.directRules.length + o.proxyRules.length + o.blockRules.length}'),
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
          child: _DnsField(state: state),
        ),
      flag(tr(context, 'fakeIp'), tr(context, 'fakeIpDesc'), o.fakeIp,
          (v) => o.fakeIp = v),
      flag(tr(context, 'strictDns'), tr(context, 'strictDnsDesc'), o.strictDns,
          (v) => o.strictDns = v),
      flag(tr(context, 'blockStun'), tr(context, 'blockStunDesc'), o.blockStun,
          (v) => o.blockStun = v),
      flag(tr(context, 'blockAds'), tr(context, 'blockAdsDesc'), o.blockAds,
          (v) => o.blockAds = v),
      if (o.blockAds)
        ListTile(
          leading: const Icon(Icons.shield_moon_outlined),
          title: Text(tr(context, 'adsLevel')),
          subtitle: Text(tr(context, o.adsLevel == 'strong' ? 'adsStrong' : 'adsStandard')),
          onTap: () async {
            final v = await pickOption<String>(context, tr(context, 'adsLevel'), o.adsLevel, {
              'standard': tr(context, 'adsStandard'),
              'strong': tr(context, 'adsStrong'),
            });
            if (v != null) await state.updateNet((o) => o.adsLevel = v);
          },
        ),      ListTile(
        leading: const Icon(Icons.travel_explore),
        title: Text(tr(context, 'dnsCheck')),
        onTap: () => _leakCheck(context, state),
      ),
    ]),
    section(Icons.tune, tr(context, 'advanced'), [
      flag(tr(context, 'tlsFragment'), tr(context, 'tlsFragmentDesc'),
          o.tlsFragment, (v) => o.tlsFragment = v),
      flag(tr(context, 'tlsRecordFragment'), tr(context, 'tlsRecordFragmentDesc'),
          o.tlsRecordFragment, (v) => o.tlsRecordFragment = v),
      flag(tr(context, 'mux'), tr(context, 'muxDesc'), o.mux,
          (v) => o.mux = v),
      if (o.mux)
        ListTile(
          leading: const Icon(Icons.call_split),
          title: Text(tr(context, 'muxProtocol')),
          trailing: Text(o.muxProtocol),
          onTap: () async {
            final v = await pickOption<String>(context, tr(context, 'muxProtocol'),
                o.muxProtocol, {for (final m in muxProtocols) m: m});
            if (v != null) await state.updateNet((o) => o.muxProtocol = v);
          },
        ),
      flag(tr(context, 'tcpFastOpen'), tr(context, 'tcpFastOpenDesc'), o.tcpFastOpen,
          (v) => o.tcpFastOpen = v),
      flag(tr(context, 'tcpMultiPath'), tr(context, 'tcpMultiPathDesc'), o.tcpMultiPath,
          (v) => o.tcpMultiPath = v),
      ListTile(
        leading: const Icon(Icons.timer_outlined),
        title: Text(tr(context, 'connectTimeout')),
        subtitle: Text(tr(context, 'connectTimeoutDesc')),
        trailing: Text(o.connectTimeout == 0 ? '—' : '${o.connectTimeout} s'),
        onTap: () => _editTimeout(context, state),
      ),
      if (!win)
        ListTile(
          leading: const Icon(Icons.swap_horiz),
          title: Text(tr(context, 'networkStrategy')),
          subtitle: Text(tr(context, 'networkStrategyDesc')),
          trailing: Text(tr(context, 'strategy_${o.networkStrategy}')),
          onTap: () async {
            final v = await pickOption<String>(
                context, tr(context, 'networkStrategy'), o.networkStrategy, {
              for (final s in networkStrategies) s: tr(context, 'strategy_$s'),
            });
            if (v != null) await state.updateNet((o) => o.networkStrategy = v);
          },
        ),
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
                tooltip: MaterialLocalizations.of(context).clearButtonTooltip,
                icon: const Icon(Icons.close),
                onPressed: () => state.updateNet((o) => o.chain = ''),
              ),
        onTap: () => _pickChain(context, state),
      ),
    ]),
  ];
}

/// The box for a DNS address of one's own: checked as it is typed, and saved when it is valid and
/// the user presses Enter, leaves the box or leaves the page.
class _DnsField extends StatefulWidget {
  const _DnsField({required this.state});

  final AppState state;

  @override
  State<_DnsField> createState() => _DnsFieldState();
}

class _DnsFieldState extends State<_DnsField> {
  late final _controller = TextEditingController(text: widget.state.net.customDns);
  final _focus = FocusNode();
  bool _invalid = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _save();
    });
  }

  bool get _valid {
    final v = _controller.text.trim();
    return v.isEmpty || isValidDnsAddress(v);
  }

  void _save() {
    final v = _controller.text.trim();
    if (!_valid || v == widget.state.net.customDns) return;
    widget.state.updateNet((o) => o.customDns = v);
  }

  @override
  void dispose() {
    _save();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: _focus,
      textDirection: TextDirection.ltr,
      autocorrect: false,
      onChanged: (_) => setState(() => _invalid = !_valid),
      onSubmitted: (_) => _save(),
      onTapOutside: (_) => _focus.unfocus(),
      decoration: InputDecoration(
        hintText: 'https://dns.example/dns-query',
        errorText: _invalid ? tr(context, 'dnsInvalid') : null,
        border: const OutlineInputBorder(),
      ),
    );
  }
}

/// Whether nothing on this computer listens on [port] (it could be bound).
Future<bool> _portFree(int port) async {
  try {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    await socket.close();
    return true;
  } catch (_) {
    return false;
  }
}

/// Shows the options as radio buttons and returns the one the user picked (null if closed).
Future<T?> pickOption<T>(BuildContext context, String title, T current, Map<T, String> options) async {
  final picked = await showDialog<({T value})>(
    context: context,
    builder: (dialog) => SimpleDialog(
      title: Text(title),
      children: [
        for (final e in options.entries)
          RadioListTile<T>(
            value: e.key,
            groupValue: current,
            title: Text(e.value),
            onChanged: (v) => Navigator.pop(dialog, (value: e.key)),
          ),
      ],
    ),
  );
  return picked?.value;
}

/// A multi-line box for a JSON object; returns the text (empty = none), or null if cancelled.
Future<String?> editJson(BuildContext context, String title, String description, String initial) {
  final controller = TextEditingController(text: initial);
  String? error;
  return showDialog<String>(
    context: context,
    builder: (dialog) => StatefulBuilder(
      builder: (dialog, setState) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(description, style: Theme.of(dialog).textTheme.bodySmall),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              minLines: 5,
              maxLines: 10,
              autocorrect: false,
              textDirection: TextDirection.ltr,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: InputDecoration(
                hintText: '{ }',
                errorText: error,
                border: const OutlineInputBorder(),
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('✕')),
          FilledButton(
            onPressed: () {
              final text = controller.text.trim();
              if (text.isNotEmpty && parseExtraJson(text) == null) {
                setState(() => error = tr(dialog, 'jsonInvalid'));
                return;
              }
              Navigator.pop(dialog, text);
            },
            child: const Text('OK'),
          ),
        ],
      ),
    ),
  ).whenComplete(controller.dispose);
}

Future<void> _editTimeout(BuildContext context, AppState state) async {
  final controller = TextEditingController(text: '${state.net.connectTimeout}');
  final seconds = await showDialog<int>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(tr(dialog, 'connectTimeout')),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(hintText: '0 – 120', border: OutlineInputBorder()),
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
  if (seconds == null || seconds < 0 || seconds > 120) return;
  await state.updateNet((o) => o.connectTimeout = seconds);
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
      child: Text('${tr(context, 'lanNote')}\n${tr(context, 'lanPlainWarn')}',
          style: Theme.of(context).textTheme.bodySmall),
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
    _LanPassword(
      password: o.lanPassword,
      onCopy: () => _copy(context, o.lanPassword),
      onNew: () => state.updateNet((o) => o.lanPassword = _newPassword()),
    ),
  ];
}

/// The password of the shared connection: hidden until the eye is pressed, so it is not read off
/// the screen by someone looking over the shoulder.
class _LanPassword extends StatefulWidget {
  const _LanPassword({required this.password, required this.onCopy, required this.onNew});

  final String password;
  final VoidCallback onCopy;
  final VoidCallback onNew;

  @override
  State<_LanPassword> createState() => _LanPasswordState();
}

class _LanPasswordState extends State<_LanPassword> {
  bool _show = false;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.key),
      title: Text(tr(context, 'lanPassword')),
      subtitle: Text(_show ? widget.password : '•' * widget.password.length,
          textDirection: TextDirection.ltr),
      onTap: widget.onCopy,
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          tooltip: tr(context, _show ? 'a11yHidePassword' : 'a11yShowPassword'),
          icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
          onPressed: () => setState(() => _show = !_show),
        ),
        IconButton(
          tooltip: tr(context, 'lanNewPassword'),
          icon: const Icon(Icons.refresh),
          onPressed: widget.onNew,
        ),
      ]),
    );
  }
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
class _LanAddress extends StatefulWidget {
  const _LanAddress({required this.port});

  final int port;

  @override
  State<_LanAddress> createState() => _LanAddressState();
}

class _LanAddressState extends State<_LanAddress> {
  // Asked for once, not at every redraw: the list would otherwise flicker back to "…".
  late final Future<List<String>> _future = _addresses();

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
    final port = widget.port;
    return FutureBuilder<List<String>>(
      future: _future,
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

Future<void> _editProxyLogin(BuildContext context, AppState state) async {
  final user = TextEditingController(text: state.net.proxyUser);
  final pass = TextEditingController(text: state.net.proxyPassword);
  var show = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialog) => StatefulBuilder(
      builder: (dialog, setState) => AlertDialog(
        title: Text(tr(dialog, 'proxyLogin')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(tr(dialog, 'proxyLoginDesc')),
            const SizedBox(height: 12),
            TextField(
              controller: user,
              autofocus: true,
              textDirection: TextDirection.ltr,
              decoration: InputDecoration(
                  labelText: tr(dialog, 'proxyUser'), border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: pass,
              obscureText: !show,
              enableSuggestions: false,
              autocorrect: false,
              textDirection: TextDirection.ltr,
              decoration: InputDecoration(
                labelText: tr(dialog, 'proxyPass'),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: tr(dialog, show ? 'a11yHidePassword' : 'a11yShowPassword'),
                  icon: Icon(show ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => show = !show),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('✕')),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('OK')),
        ],
      ),
    ),
  );
  final u = user.text.trim(), p = pass.text;
  user.dispose();
  pass.dispose();
  if (ok != true) return;
  // Both or none: a half login would lock everything out.
  final both = u.isNotEmpty && p.isNotEmpty;
  await state.updateNet((o) {
    o.proxyUser = both ? u : '';
    o.proxyPassword = both ? p : '';
  });
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
  // The port of the shared connection (LAN) is another one; and a port that something else
  // holds would stop the proxy from starting with an unclear error.
  if (state.net.shareLan && port == state.net.lanPort) {
    if (context.mounted) toast(context, tr(context, 'lanPortInvalid'));
    return;
  }
  if (port != state.net.proxyPort && !await _portFree(port)) {
    if (context.mounted) toast(context, tr(context, 'portBusy'));
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
              'ip': ltr(r.ip),
              'country': r.country,
              'dns': ltr(state.net.dnsAddress),
            })}\n\n${r.webrtc == null ? tr(context, 'webrtcNone') : r.webrtc == r.ip ? tr(context, 'webrtcSame', {'ip': ltr(r.webrtc!)}) : tr(context, 'webrtcLeak', {'ip': ltr(r.webrtc!)})}';
  await showDialog<void>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(tr(dialog, 'dnsCheck')),
      content: SelectableText(text),
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
          if (c.canSingBox && c.outbound['type'] != 'wireguard') c,
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
