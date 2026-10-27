import 'dart:convert';

/// Subscription and import forms that are not a plain list of share links: the app deep links
/// other clients hand out (`clash://install-config?url=...`, `sing-box://import-remote-profile?...`,
/// `hiddify://import/...`, `sub://...`) and the text format of Surge, Loon and Stash profiles.

/// The address (and the suggested name) inside a deep link, or null when [input] is not one.
({String url, String? name})? subscriptionDeepLink(String input) {
  final text = input.trim();
  final scheme = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*)://').firstMatch(text)?[1]?.toLowerCase();
  if (scheme == null || scheme == 'http' || scheme == 'https') return null;
  // Share links of single servers are not subscriptions.
  const servers = {
    'vmess', 'vless', 'trojan', 'ss', 'ssr', 'hysteria', 'hysteria2', 'hy2', 'tuic', 'anytls',
    'wireguard', 'wg', 'socks', 'socks5', 'socks4', 'ssh', 'naive', 'naive+https', 'tg',
  };
  if (servers.contains(scheme)) return null;

  String? name;
  var rest = text;
  final hash = rest.indexOf('#');
  if (hash >= 0) {
    try {
      name = Uri.decodeComponent(rest.substring(hash + 1)).trim();
    } catch (_) {
      name = rest.substring(hash + 1).trim();
    }
    rest = rest.substring(0, hash);
  }
  if (name != null && name.isEmpty) name = null;

  // sub://BASE64 (Shadowrocket): the address, optionally followed by #name, in base64.
  if (scheme == 'sub') {
    try {
      final inner = utf8.decode(base64.decode(base64.normalize(rest.substring(6).trim())));
      final h = inner.indexOf('#');
      final url = (h >= 0 ? inner.substring(0, h) : inner).trim();
      if (url.startsWith('http')) {
        return (url: url, name: h >= 0 ? inner.substring(h + 1).trim() : name);
      }
    } catch (_) {}
    return null;
  }

  // ...?url=ENCODED
  final query = rest.indexOf('?');
  if (query >= 0) {
    final params = Uri.splitQueryString(rest.substring(query + 1), encoding: utf8);
    for (final key in const ['url', 'link', 'sub', 'subscription', 'config']) {
      final v = params[key];
      if (v != null && v.startsWith('http')) return (url: v, name: params['name'] ?? name);
    }
  }
  // hiddify://import/https://host/path , happ://add/https://host/path
  final embedded = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://(?:[^/?#]*/)?(https?(?::|%3A).*)$', caseSensitive: false)
      .firstMatch(rest);
  if (embedded != null) {
    var url = embedded[1]!;
    if (url.toLowerCase().startsWith('http%3a')) {
      try {
        url = Uri.decodeComponent(url);
      } catch (_) {}
    }
    return (url: url, name: name);
  }
  return null;
}

// ------------------------------------------------------------ Surge / Loon / Stash text

/// Splits `a, b, "c d", e=f` at the commas that are outside quotes.
List<String> _fields(String s) {
  final out = <String>[];
  final b = StringBuffer();
  var quoted = false;
  for (final ch in s.split('')) {
    if (ch == '"') {
      quoted = !quoted;
    } else if (ch == ',' && !quoted) {
      out.add(b.toString().trim());
      b.clear();
    } else {
      b.write(ch);
    }
  }
  out.add(b.toString().trim());
  return out;
}

bool _true(String? v) => v != null && (v.toLowerCase() == 'true' || v == '1');

String _q(Map<String, String?> q) {
  final parts = [
    for (final e in q.entries)
      if (e.value != null && e.value!.isNotEmpty)
        '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value!)}',
  ];
  return parts.isEmpty ? '' : '?${parts.join('&')}';
}

String _h(String host) => host.contains(':') && !host.startsWith('[') ? '[$host]' : host;

/// Share links for the `name = type, host, port, ...` lines of a Surge, Loon or Stash profile.
/// Servers of other kinds are skipped.
List<String> surgeLinks(String text) {
  final out = <String>[];
  final line = RegExp(r'^\s*([^=#;\[][^=]*?)\s*=\s*(ss|vmess|vless|trojan|socks5|socks5-tls|hysteria2|hy2)\s*,\s*(.+)$',
      caseSensitive: false);
  for (final raw in text.split('\n')) {
    final m = line.firstMatch(raw.trim());
    if (m == null) continue;
    final name = m[1]!.trim();
    final type = m[2]!.toLowerCase();
    final all = _fields(m[3]!);
    final pos = <String>[];
    final kv = <String, String>{};
    for (final f in all) {
      final i = f.indexOf('=');
      if (i > 0 && !f.startsWith('"')) {
        kv[f.substring(0, i).trim().toLowerCase()] = f.substring(i + 1).trim();
      } else {
        pos.add(f);
      }
    }
    if (pos.length < 2) continue;
    final host = pos[0];
    final port = int.tryParse(pos[1]);
    if (host.isEmpty || port == null) continue;
    final tag = Uri.encodeComponent(name);
    final insecure = _true(kv['skip-cert-verify']) ? '1' : null;
    final sni = kv['sni'] ?? kv['tls-name'];
    final ws = _true(kv['ws']) || kv['transport'] == 'ws';
    final wsPath = kv['ws-path'] ?? kv['path'];
    final wsHost = kv['ws-headers']?.replaceFirst(RegExp(r'^[Hh]ost:\s*'), '').split('|').first.trim() ?? kv['host'];
    final tls = _true(kv['tls']) || _true(kv['over-tls']) || type == 'trojan' || type == 'socks5-tls';

    switch (type) {
      case 'ss':
        final method = kv['encrypt-method'] ?? (pos.length > 2 ? pos[2] : null);
        final password = kv['password'] ?? (pos.length > 3 ? pos[3] : null);
        if (method == null || password == null) continue;
        final userinfo = base64.encode(utf8.encode('$method:$password'));
        final obfs = kv['obfs'];
        final plugin = obfs == null
            ? null
            : 'obfs-local;obfs=$obfs${kv['obfs-host'] != null ? ';obfs-host=${kv['obfs-host']}' : ''}';
        out.add('ss://$userinfo@${_h(host)}:$port${_q({'plugin': plugin})}#$tag');
      case 'vmess':
        final id = kv['username'] ?? (pos.length > 2 ? pos[2] : null);
        if (id == null) continue;
        final json = {
          'v': '2',
          'ps': name,
          'add': host,
          'port': '$port',
          'id': id,
          'aid': kv['alterid'] ?? '0',
          'scy': kv['encrypt-method'] ?? 'auto',
          'net': ws ? 'ws' : 'tcp',
          'type': 'none',
          'host': wsHost ?? '',
          'path': wsPath ?? '',
          'tls': tls ? 'tls' : '',
          'sni': sni ?? '',
        };
        out.add('vmess://${base64.encode(utf8.encode(jsonEncode(json)))}');
      case 'vless':
        final id = kv['username'] ?? (pos.length > 2 ? pos[2] : null);
        if (id == null) continue;
        out.add('vless://$id@${_h(host)}:$port${_q({
              'encryption': 'none',
              'security': tls ? 'tls' : 'none',
              'sni': sni,
              'allowInsecure': insecure,
              'type': ws ? 'ws' : 'tcp',
              'path': wsPath,
              'host': wsHost,
              'flow': kv['flow'],
            })}#$tag');
      case 'trojan':
        final pw = kv['password'] ?? (pos.length > 2 ? pos[2] : null);
        if (pw == null) continue;
        out.add('trojan://${Uri.encodeComponent(pw)}@${_h(host)}:$port${_q({
              'security': 'tls',
              'sni': sni,
              'allowInsecure': insecure,
              'type': ws ? 'ws' : 'tcp',
              'path': wsPath,
              'host': wsHost,
            })}#$tag');
      case 'socks5' || 'socks5-tls':
        final user = kv['username'] ?? (pos.length > 3 ? pos[2] : null);
        final pw = kv['password'] ?? (pos.length > 3 ? pos[3] : '');
        final auth = user == null ? '' : '${Uri.encodeComponent(user)}:${Uri.encodeComponent(pw)}@';
        out.add('socks5://$auth${_h(host)}:$port#$tag');
      case 'hysteria2' || 'hy2':
        final pw = kv['password'];
        if (pw == null) continue;
        out.add('hysteria2://${Uri.encodeComponent(pw)}@${_h(host)}:$port${_q({
              'sni': sni,
              'insecure': insecure,
              'obfs': kv['obfs'],
              'obfs-password': kv['obfs-password'],
            })}#$tag');
    }
  }
  return out;
}
