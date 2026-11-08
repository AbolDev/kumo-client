import 'package:flutter/material.dart';

import '../core/clean_ip.dart' show withCleanIp;
import '../core/link_fields.dart';
import '../core/proxy_config.dart';
import '../l10n/extra.dart' show tr;
import '../l10n/strings.dart';
import 'clean_ip_page.dart';

const _choices = <String, List<String>>{
  'security': ['none', 'tls', 'reality'],
  'type': ['tcp', 'ws', 'grpc', 'http', 'httpupgrade', 'xhttp'],
  'net': ['tcp', 'ws', 'grpc', 'h2', 'httpupgrade', 'xhttp'],
  'tls': ['tls'],
  'fp': [
    'chrome',
    'firefox',
    'safari',
    'ios',
    'android',
    'edge',
    'random',
    'randomized'
  ],
  'mode': ['auto', 'packet-up', 'stream-up', 'stream-one'],
};

/// Edits a config with a form instead of the raw link. Pops with the new link,
/// or with null when cancelled.
class EditConfigPage extends StatefulWidget {
  const EditConfigPage({super.key, required this.config});

  final ProxyConfig config;

  @override
  State<EditConfigPage> createState() => _EditConfigPageState();
}

class _EditConfigPageState extends State<EditConfigPage> {
  late final LinkFields? _fields = LinkFields.parse(widget.config.link);
  final _controllers = <String, TextEditingController>{};
  String? _error;

  TextEditingController _c(String key, String value) =>
      _controllers.putIfAbsent(key, () => TextEditingController(text: value));

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final f = _fields!;
    final t = S.of(context);
    f.name = _c('name', f.name).text.trim();
    f.host = _c('host', f.host).text.trim();
    f.port = _c('port', f.port).text.trim();
    f.secret = _c('secret', f.secret).text.trim();
    for (final k in f.params.keys.toList()) {
      f.params[k] = _c('p:$k', f.params[k]!).text.trim();
    }
    final port = int.tryParse(f.port);
    if (f.host.isEmpty || port == null || port < 1 || port > 65535) {
      setState(() => _error = t.invalidConfig);
      return;
    }
    final link = f.build();
    if (parseLink(link) == null) {
      setState(() => _error = t.invalidConfig);
      return;
    }
    Navigator.pop(context, link);
  }

  /// The form's current values as a link's fields (without closing the page).
  LinkFields? _snapshot() {
    final f = _fields;
    if (f == null) return null;
    f.name = _c('name', f.name).text.trim();
    f.host = _c('host', f.host).text.trim();
    f.port = _c('port', f.port).text.trim();
    f.secret = _c('secret', f.secret).text.trim();
    for (final k in f.params.keys.toList()) {
      f.params[k] = _c('p:$k', f.params[k]!).text.trim();
    }
    return LinkFields.parse(f.build());
  }

  /// Opens "Find a clean IP"; the address picked goes into the form, with the old address kept as the
  /// TLS server name and the Host header where the server needs it.
  Future<void> _findCleanIp() async {
    final snap = _snapshot();
    if (snap == null || snap.host.isEmpty) return;
    final ip = await Navigator.push<String>(
      context,
      MaterialPageRoute(
          settings: const RouteSettings(name: '/CleanIpPage'), builder: (_) => CleanIpPage(server: snap)),
    );
    final out = ip == null ? null : withCleanIp(snap, ip);
    if (out == null || !mounted) return;
    setState(() {
      _c('host', '').text = out.host;
      for (final k in const ['sni', 'host']) {
        final v = out.params[k];
        if (v == null || v.isEmpty) continue;
        _fields!.params[k] = v;
        _c('p:$k', v).text = v;
      }
    });
  }

  Widget _field(String key, String label, String value,
      {TextInputType? keyboard, bool obscure = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: _c(key, value),
        keyboardType: keyboard,
        obscureText: obscure,
        textDirection: TextDirection.ltr,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _param(S t, String key, String value) {
    final options = _choices[key];
    if (options == null) return _field('p:$key', t.fieldLabel(key), value);
    final controller = _c('p:$key', value);
    final items = {...options, if (controller.text.isNotEmpty) controller.text};
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        value: controller.text.isEmpty ? '' : controller.text,
        decoration: InputDecoration(
          labelText: t.fieldLabel(key),
          border: const OutlineInputBorder(),
        ),
        items: [
          const DropdownMenuItem(value: '', child: Text('-')),
          for (final o in items) DropdownMenuItem(value: o, child: Text(o)),
        ],
        onChanged: (v) => controller.text = v ?? '',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = S.of(context);
    final f = _fields;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.editConfigTitle),
        actions: [
          TextButton(onPressed: f == null ? null : _save, child: Text(t.save)),
        ],
      ),
      body: f == null
          ? Center(child: Text(t.invalidConfig))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _field('name', t.fieldLabel('name'), f.name),
                _field('host', t.fieldLabel('address'), f.host),
                if (const {'vless', 'vmess', 'trojan'}.contains(f.scheme))
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: OutlinedButton.icon(
                        onPressed: _findCleanIp,
                        icon: const Icon(Icons.travel_explore),
                        label: Text(tr(context, 'cleanIpButton')),
                      ),
                    ),
                  ),
                _field('port', t.fieldLabel('port'), f.port,
                    keyboard: TextInputType.number),
                _field(
                    'secret',
                    t.fieldLabel(f.scheme == 'vless' || f.scheme == 'vmess'
                        ? 'uuid'
                        : 'password'),
                    f.secret),
                if (f.params.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(t.advanced,
                        style: Theme.of(context).textTheme.titleSmall),
                  ),
                  for (final e in f.params.entries) _param(t, e.key, e.value),
                ],
                if (_error != null)
                  Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
              ],
            ),
    );
  }
}
