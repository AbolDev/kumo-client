import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/clean_ip.dart' show withCleanIp;
import '../core/extra_options.dart' show fragmentFinalMask;
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
    '360',
    'qq',
    'random',
    'randomized',
    'randomizednoalpn',
    'unsafe'
  ],
  'mode': ['auto', 'packet-up', 'stream-up', 'stream-one'],
};

/// The parameters of the anti-filter section: the fingerprint, the ALPN, the final mask (JSON) and the
/// cipher suites of the TLS hello. They have a place of their own in the form for the servers that have a
/// TLS layer (the others have none of them).
const _antiKeys = ['fp', 'alpn', 'fm', 'cipherSuites'];
const _antiSchemes = {'vless', 'vmess', 'trojan'};

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

  @override
  void initState() {
    super.initState();
    final f = _fields;
    // The four have a field even when the link has none of them (an empty one is left out of the link).
    if (f != null && _antiSchemes.contains(f.scheme)) {
      for (final k in _antiKeys) {
        f.params.putIfAbsent(k, () => '');
      }
    }
  }

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
    // The final mask is JSON; it goes into the link in its short form.
    final mask = f.params['fm'] ?? '';
    if (mask.isNotEmpty) {
      try {
        final j = jsonDecode(mask);
        if (j is! Map) throw const FormatException('not an object');
        f.params['fm'] = jsonEncode(j);
      } catch (_) {
        setState(() => _error = tr(context, 'antiFmInvalid'));
        return;
      }
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

  /// A text field of the anti-filter section (its own key, for the tests); [lines] above one makes it a box.
  Widget _anti(String key, String label, String value, {int lines = 1, String? hint}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          key: ValueKey('anti:$key'),
          controller: _c('p:$key', value),
          minLines: lines,
          maxLines: lines == 1 ? 1 : lines + 4,
          textDirection: TextDirection.ltr,
          style: lines == 1 ? null : const TextStyle(fontFamily: 'monospace', fontSize: 13),
          decoration: InputDecoration(labelText: label, hintText: hint, border: const OutlineInputBorder()),
        ),
      );

  /// The fingerprint (with `unsafe`), the ALPN, the final mask and the cipher suites: what a network that filters
  /// the TLS hello may need. Closed unless the server already has one of them.
  Widget _antiFilter(S t, LinkFields f) {
    final open = _antiKeys.any((k) => (f.params[k] ?? '').isNotEmpty);
    return Card(
      margin: const EdgeInsets.only(top: 4, bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: open,
        shape: const Border(),
        collapsedShape: const Border(),
        title: Text(tr(context, 'antiTitle')),
        subtitle: Text(tr(context, 'antiDesc')),
        childrenPadding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        children: [
          _param(t, 'fp', f.params['fp'] ?? ''),
          _anti('alpn', 'ALPN', f.params['alpn'] ?? '', hint: 'h2,http/1.1'),
          _anti('fm', tr(context, 'antiFm'), f.params['fm'] ?? '', lines: 4),
          // Ready-made masks, so that nobody has to write the JSON of the usual one.
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Wrap(spacing: 8, runSpacing: 4, children: [
              ActionChip(
                key: const ValueKey('anti:fm-fragment'),
                avatar: const Icon(Icons.call_split, size: 18),
                label: Text(tr(context, 'antiFmFragment')),
                onPressed: () => setState(() => _c('p:fm', '').text = fragmentFinalMask()),
              ),
              ActionChip(
                key: const ValueKey('anti:fm-clear'),
                label: Text(tr(context, 'antiFmClear')),
                onPressed: () => setState(() => _c('p:fm', '').text = ''),
              ),
            ]),
          ),
          _anti('cipherSuites', tr(context, 'antiCipher'), f.params['cipherSuites'] ?? ''),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(tr(context, 'antiXrayNote'), style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
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
                  for (final e in f.params.entries)
                    if (!(_antiSchemes.contains(f.scheme) && _antiKeys.contains(e.key))) _param(t, e.key, e.value),
                ],
                if (_antiSchemes.contains(f.scheme)) _antiFilter(t, f),
                if (_error != null)
                  Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
              ],
            ),
    );
  }
}
