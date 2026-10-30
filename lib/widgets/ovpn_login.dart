import 'package:flutter/material.dart';

import '../core/proxy_config.dart';
import '../l10n/extra.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';

/// Asks for the user name and password of an OpenVPN server (and the passphrase of its private key
/// when it has one) and gives them to [state]. With [connect], the connection is tried again after.
Future<void> showOvpnLogin(BuildContext context, AppState state, ProxyConfig config,
    {bool connect = false}) async {
  final server = config.ovpn;
  if (server == null) return;
  final user = TextEditingController(text: server.username ?? '');
  final pass = TextEditingController(text: server.password ?? '');
  final key = TextEditingController(text: server.keyPassword ?? '');
  var hidden = true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialog) => StatefulBuilder(
      builder: (dialog, setState) => AlertDialog(
        title: Text(tr(dialog, 'ovpnLoginTitle')),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (server.profile.needsLogin) ...[
              TextField(
                controller: user,
                autofocus: true,
                autocorrect: false,
                decoration: InputDecoration(
                    labelText: tr(dialog, 'ovpnUser'), border: const OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: pass,
                obscureText: hidden,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: tr(dialog, 'ovpnPass'),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: tr(dialog, hidden ? 'a11yShowPassword' : 'a11yHidePassword'),
                    icon: Icon(hidden ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => hidden = !hidden),
                  ),
                ),
              ),
            ],
            if (server.profile.needsKeyPassword) ...[
              const SizedBox(height: 12),
              TextField(
                controller: key,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                    labelText: tr(dialog, 'ovpnKeyPass'), border: const OutlineInputBorder()),
              ),
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(S.of(dialog).cancel)),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(S.of(dialog).save)),
        ],
      ),
    ),
  );
  final u = user.text, p = pass.text, k = key.text;
  user.dispose();
  pass.dispose();
  key.dispose();
  if (ok != true) return;
  await state.setOvpnLogin(config, username: u, password: p, keyPassword: k.isEmpty ? null : k);
  if (connect) await state.toggle();
}

/// Shows the login dialog by itself when a connection needs one ([AppState.ovpnLoginRequest]).
class OvpnLoginHost extends StatefulWidget {
  const OvpnLoginHost({super.key, required this.state, required this.child});

  final AppState state;
  final Widget child;

  @override
  State<OvpnLoginHost> createState() => _OvpnLoginHostState();
}

class _OvpnLoginHostState extends State<OvpnLoginHost> {
  @override
  void initState() {
    super.initState();
    widget.state.ovpnLoginRequest.addListener(_asked);
  }

  @override
  void dispose() {
    widget.state.ovpnLoginRequest.removeListener(_asked);
    super.dispose();
  }

  void _asked() {
    final config = widget.state.ovpnLoginRequest.value;
    if (config == null) return;
    widget.state.ovpnLoginRequest.value = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) showOvpnLogin(context, widget.state, config, connect: true);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
