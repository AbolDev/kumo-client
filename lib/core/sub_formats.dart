import 'dart:convert';
import 'dart:isolate';

import 'package:yaml/yaml.dart';

import 'config_decryptor.dart' show xrayJsonToLinks;
import 'ovpn/ovpn_profile.dart' show ovpnToLinks;
import 'proxy_config.dart' show extractLinks, wireguardConfToLinks;
import 'sub_surge.dart';

/// Turns the body of a subscription, in whichever format the provider serves it, into
/// share links: a plain or base64 list of links, a Clash / Mihomo YAML, a sing-box or
/// Xray / V2Ray JSON, a SIP008 Shadowsocks list, or a Surge / Loon / Stash profile.
List<String> extractSubscriptionLinks(String body, {int depth = 0}) {
  final text = body.trim();
  if (text.isEmpty) return const [];
  final links = extractLinks(text);
  if (links.isNotEmpty) return links;
  // The text of a WireGuard configuration file.
  final wireguard = wireguardConfToLinks(text);
  if (wireguard.isNotEmpty) return wireguard;
  // The text of an OpenVPN configuration file (.ovpn) with its certificates inside.
  final openvpn = ovpnToLinks(text);
  if (openvpn.isNotEmpty) return openvpn;
  // The `name = type, host, port, ...` lines of Surge, Loon and Stash profiles.
  if (text.contains('=') && !text.startsWith('{') && !text.startsWith('[{')) {
    final surge = surgeLinks(text);
    if (surge.isNotEmpty) return surge;
  }

  // Decrypted profiles (.bpf, .zsx ...) start with `// name: ...` comment lines before the JSON.
  final bare = text.startsWith('//')
      ? text
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n')
          .trim()
      : text;
  if (bare.startsWith('{') || bare.startsWith('[')) {
    try {
      final found = _fromJson(jsonDecode(bare));
      if (found.isNotEmpty) return found;
    } catch (_) {
      // not JSON after all
    }
  }
  if ((text.contains('proxies:') || text.contains('proxy-providers:')) && _yamlIsSafe(text)) {
    try {
      final found = _fromJson(_plain(loadYaml(text)));
      if (found.isNotEmpty) return found;
    } catch (_) {
      // not YAML
    }
  }
  // A base64 wrapper around one of the structured formats.
  if (depth == 0) {
    try {
      final inner = utf8.decode(
          base64.decode(base64.normalize(text.replaceAll(RegExp(r'\s'), ''))),
          allowMalformed: true);
      if (inner.trim().isNotEmpty && inner != text) {
        return extractSubscriptionLinks(inner, depth: 1);
      }
    } catch (_) {
      // not base64
    }
  }
  return const [];
}

/// A YAML document can expand a few lines into gigabytes by naming parts of itself again and
/// again (anchors and aliases, the "billion laughs" shape). The parser shares the parts, so the
/// harm is done when they are copied out (see [_plain], which counts what it copies); here only
/// a very large file is turned away.
bool _yamlIsSafe(String text) => text.length <= 8 * 1024 * 1024;

/// The most nodes copied out of one YAML document; a list of thousands of servers is far below it.
const _yamlBudget = 2000000;

/// Same, off the UI thread (a top-level function so nothing else is captured).
Future<List<String>> extractSubscriptionLinksInBackground(String body) =>
    Isolate.run(() => extractSubscriptionLinks(body));

/// YAML nodes -> plain Dart maps and lists. Throws when the document holds more than
/// [_yamlBudget] nodes once its aliases are written out.
Object? _plain(Object? v, [List<int>? left]) {
  final budget = left ?? [_yamlBudget];
  if (--budget[0] < 0) throw const FormatException('the YAML document expands too far');
  if (v is YamlMap) {
    final out = <String, Object?>{};
    Object? merge;
    for (final e in v.entries) {
      // `<<: *defaults` pulls the entries of another map in (Clash files use it to give every server
      // the same settings); the package does not do it itself. Entries written out stay as they are.
      if ('${e.key}' == '<<') {
        merge = e.value;
      } else {
        out['${e.key}'] = _plain(e.value, budget);
      }
    }
    void apply(Object? m) {
      final p = _plain(m, budget);
      if (p is Map<String, Object?>) p.forEach((k, val) => out.putIfAbsent(k, () => val));
    }

    if (merge is YamlList) {
      merge.forEach(apply);
    } else if (merge != null) {
      apply(merge);
    }
    return out;
  }
  if (v is YamlList) return [for (final e in v) _plain(e, budget)];
  return v;
}

List<String> _fromJson(Object? json) {
  final out = <String>[];
  void visit(Object? v) {
    if (v is List) {
      for (final e in v) {
        visit(e);
      }
      return;
    }
    if (v is! Map) return;
    var handled = false;
    final proxies = v['proxies'];
    if (proxies is List && proxies.any((p) => p is Map && p['type'] != null)) {
      for (final p in proxies) {
        if (p is Map) {
          final l = _clashLink(p);
          if (l != null) out.add(l);
        }
      }
      handled = true;
    }
    final servers = v['servers'];
    if (servers is List &&
        servers.any((s) => s is Map && s['method'] != null)) {
      for (final s in servers) {
        if (s is Map) {
          final l = _sip008Link(s);
          if (l != null) out.add(l);
        }
      }
      handled = true;
    }
    final outbounds = v['outbounds'];
    if (outbounds is List) {
      final singbox = outbounds.where((o) => o is Map && o['type'] != null).cast<Map>().toList();
      if (singbox.isNotEmpty) {
        // The outbounds by their tag: a server can be reached through another one (`detour`), such as the
        // ShadowTLS layer under a Shadowsocks server.
        final byTag = {for (final o in singbox) if (_s(o['tag']) != null) _s(o['tag'])!: o};
        for (final o in singbox) {
          final l = _singBoxLink(o, byTag);
          if (l != null) out.add(l);
        }
        handled = true;
      }
    }
    // sing-box 1.11 and later list WireGuard servers as endpoints.
    final endpoints = v['endpoints'];
    if (endpoints is List) {
      for (final e in endpoints) {
        if (e is Map && _s(e['type'])?.toLowerCase() == 'wireguard') {
          final l = _singBoxWireguard(e);
          if (l != null) out.add(l);
          handled = true;
        }
      }
    }
    if (!handled && v['type'] != null && v['server'] != null) {
      final l = _singBoxLink(v, const {}) ?? _clashLink(v);
      if (l != null) {
        out.add(l);
        handled = true;
      }
    }
    if (!handled) out.addAll(xrayJsonToLinks(v));
  }

  visit(json);
  final seen = <String>{};
  return out.where(seen.add).toList();
}

// ------------------------------------------------------------------ builders

String? _s(Object? v) {
  if (v == null) return null;
  final s = '$v'.trim();
  return s.isEmpty ? null : s;
}

bool _on(Object? v) => v == true || '$v'.toLowerCase() == 'true' || '$v' == '1';

String _tag(Object? name) => Uri.encodeComponent(_s(name) ?? '');

String _query(Map<String, String?> q) {
  final parts = <String>[];
  q.forEach((k, v) {
    if (v != null && v.isNotEmpty) {
      parts
          .add('${Uri.encodeQueryComponent(k)}=${Uri.encodeQueryComponent(v)}');
    }
  });
  return parts.isEmpty ? '' : '?${parts.join('&')}';
}

String _host(String host) =>
    host.contains(':') && !host.startsWith('[') ? '[$host]' : host;

String _alpn(Object? v) =>
    v is List ? v.map((e) => '$e').join(',') : (_s(v) ?? '');

/// A Shadowsocks link; [plugin] is a SIP003 plugin with its options (`obfs-local;obfs=tls;obfs-host=..`).
String? _ssLink(String? method, String? password, String? server, Object? port,
    Object? name, {String? plugin}) {
  if (method == null ||
      password == null ||
      server == null ||
      _s(port) == null) {
    return null;
  }
  final userinfo = base64.encode(utf8.encode('$method:$password'));
  final query = plugin == null ? '' : '/?plugin=${Uri.encodeComponent(plugin)}';
  return 'ss://$userinfo@${_host(server)}:${_s(port)}$query#${_tag(name)}';
}

/// The SIP003 plugin of a Clash Shadowsocks server (`plugin` and `plugin-opts`), as a link writes it. Null when it
/// has none; an empty text for a plugin the cores do not have (the server is then left out: without its plugin
/// it cannot work).
String? _clashSsPlugin(Map p) {
  final name = _s(p['plugin'])?.toLowerCase();
  if (name == null) return null;
  final o = p['plugin-opts'] is Map ? p['plugin-opts'] as Map : const {};
  String opts(Map<String, Object?> kv) => [
        for (final e in kv.entries)
          if (e.value == true) e.key else if (_s(e.value) != null) '${e.key}=${_s(e.value)}',
      ].join(';');
  switch (name) {
    case 'obfs' || 'obfs-local' || 'simple-obfs':
      final rest = opts({'obfs': _s(o['mode']) ?? 'http', 'obfs-host': o['host']});
      return 'obfs-local;$rest';
    case 'v2ray-plugin':
      final rest = opts({
        'mode': _s(o['mode']) ?? 'websocket',
        'tls': _on(o['tls']),
        'host': o['host'],
        'path': o['path'],
        'mux': _on(o['mux']) ? '1' : null,
      });
      return 'v2ray-plugin;$rest';
    case 'shadow-tls':
      final rest = opts({
        'host': o['host'],
        'password': o['password'],
        'version': o['version'] ?? 3,
        'fingerprint': p['client-fingerprint'],
      });
      return 'shadow-tls;$rest';
  }
  return '';
}

/// `http(s)://user:pass@host:port?sni=..&insecure=1#name`: an HTTP proxy (see `isHttpProxyLink`).
String? _httpLink(String server, String port, Object? name,
    {String? user, String? pass, bool tls = false, String? sni, String? insecure}) {
  final auth = user == null ? '' : '${Uri.encodeComponent(user)}:${Uri.encodeComponent(pass ?? '')}@';
  return '${tls ? 'https' : 'http'}://$auth${_host(server)}:$port${_query({
        if (tls) 'sni': sni,
        if (tls) 'insecure': insecure,
      })}#${_tag(name)}';
}

/// `wireguard://PRIVATE_KEY@host:port?publickey=..&address=..` from the parts of a WireGuard server.
String? _wireguardLink(String server, String port, Object? name,
    {String? privateKey,
    String? publicKey,
    List<String> addresses = const [],
    String? preSharedKey,
    Object? reserved,
    Object? mtu,
    Object? keepAlive,
    Object? allowedIps}) {
  if (privateKey == null || publicKey == null || addresses.isEmpty) return null;
  final res = reserved is List ? reserved.join(',') : _s(reserved);
  return 'wireguard://${Uri.encodeComponent(privateKey)}@${_host(server)}:$port${_query({
        'publickey': publicKey,
        'address': addresses.join(','),
        'presharedkey': preSharedKey,
        'reserved': res,
        'mtu': _s(mtu),
        'keepalive': _s(keepAlive),
        'allowedips': allowedIps is List ? allowedIps.join(',') : _s(allowedIps),
      })}#${_tag(name)}';
}

String? _sip008Link(Map s) => _ssLink(_s(s['method']), _s(s['password']),
    _s(s['server']), s['server_port'], s['remarks'] ?? s['name']);

/// One entry of a Clash / Mihomo `proxies` list.
String? _clashLink(Map p) {
  final type = _s(p['type'])?.toLowerCase();
  final server = _s(p['server']);
  final port = _s(p['port']);
  if (type == null || server == null || port == null) return null;
  final name = p['name'];
  final network = _s(p['network']) ?? 'tcp';
  final tls = _on(p['tls']);
  final sni = _s(p['servername'] ?? p['sni']);
  final insecure = _on(p['skip-cert-verify']) ? '1' : null;
  final reality = p['reality-opts'] is Map ? p['reality-opts'] as Map : null;

  Map<String, String?> transport() {
    final q = <String, String?>{'type': network};
    final ws = p['ws-opts'] is Map ? p['ws-opts'] as Map : const {};
    final grpc = p['grpc-opts'] is Map ? p['grpc-opts'] as Map : const {};
    final h2 = p['h2-opts'] is Map ? p['h2-opts'] as Map : const {};
    final xhttp = p['xhttp-opts'] is Map ? p['xhttp-opts'] as Map : const {};
    final http = p['http-opts'] is Map ? p['http-opts'] as Map : const {};
    final headers = ws['headers'] is Map ? ws['headers'] as Map : const {};
    switch (network) {
      case 'ws':
        q['path'] = _s(ws['path']) ?? _s(p['ws-path']);
        q['host'] = _s(headers['Host'] ?? headers['host']) ??
            _s((p['ws-headers'] as Map?)?['Host']);
      case 'grpc':
        q['serviceName'] = _s(grpc['grpc-service-name']);
      case 'h2':
        q['path'] = _s(h2['path']);
        q['host'] = h2['host'] is List
            ? (h2['host'] as List).join(',')
            : _s(h2['host']);
      case 'xhttp':
        q['path'] = _s(xhttp['path']);
        q['host'] = _s(xhttp['host']);
        q['mode'] = _s(xhttp['mode']);
      case 'http':
        final path = http['path'];
        q['path'] =
            path is List && path.isNotEmpty ? '${path.first}' : _s(path);
    }
    return q;
  }

  Map<String, String?> secure() => {
        'security': reality != null ? 'reality' : (tls ? 'tls' : 'none'),
        'sni': sni,
        'fp': _s(p['client-fingerprint']),
        'alpn': _alpn(p['alpn']),
        'allowInsecure': insecure,
        'pbk': _s(reality?['public-key']),
        'sid': _s(reality?['short-id']),
      };

  switch (type) {
    case 'ss':
      final plugin = _clashSsPlugin(p);
      if (plugin != null && plugin.isEmpty) return null;
      return _ssLink(_s(p['cipher']), _s(p['password']), server, port, name, plugin: plugin);
    case 'http':
      return _httpLink(server, port, name,
          user: _s(p['username']), pass: _s(p['password']), tls: tls, sni: sni, insecure: insecure);
    case 'ssh':
      final user = _s(p['username']);
      if (user == null) return null;
      return 'ssh://${Uri.encodeComponent(user)}:${Uri.encodeComponent(_s(p['password']) ?? '')}@${_host(server)}:$port${_query({
            'private_key': _s(p['private-key']),
            'private_key_passphrase': _s(p['private-key-passphrase']),
            'host_key': p['host-key'] is List ? (p['host-key'] as List).join(',') : _s(p['host-key']),
          })}#${_tag(name)}';
    case 'wireguard':
      // Mihomo writes the peer in the server itself, or in a list of peers.
      final peer = p['peers'] is List && (p['peers'] as List).isNotEmpty && (p['peers'] as List).first is Map
          ? (p['peers'] as List).first as Map
          : p;
      final peerServer = _s(peer['server']) ?? server;
      final peerPort = _s(peer['port']) ?? port;
      return _wireguardLink(peerServer, peerPort, name,
          privateKey: _s(p['private-key']),
          publicKey: _s(peer['public-key']),
          addresses: [
            if (_s(p['ip']) != null) _s(p['ip'])!,
            if (_s(p['ipv6']) != null) _s(p['ipv6'])!,
          ],
          preSharedKey: _s(peer['pre-shared-key']),
          reserved: peer['reserved'],
          mtu: p['mtu'],
          keepAlive: p['persistent-keepalive'],
          allowedIps: peer['allowed-ips']);
    case 'vmess':
      final ws = p['ws-opts'] is Map ? p['ws-opts'] as Map : const {};
      final headers = ws['headers'] is Map ? ws['headers'] as Map : const {};
      final grpc = p['grpc-opts'] is Map ? p['grpc-opts'] as Map : const {};
      final json = {
        'v': '2',
        'ps': _s(name) ?? '',
        'add': server,
        'port': port,
        'id': _s(p['uuid']) ?? '',
        'aid': _s(p['alterId']) ?? '0',
        'scy': _s(p['cipher']) ?? 'auto',
        'net': network,
        'type': 'none',
        'host': _s(headers['Host']) ?? '',
        'path': network == 'grpc'
            ? (_s(grpc['grpc-service-name']) ?? '')
            : (_s(ws['path']) ?? ''),
        'tls': tls ? 'tls' : '',
        'sni': sni ?? '',
        'alpn': _alpn(p['alpn']),
        'fp': _s(p['client-fingerprint']) ?? '',
      };
      return 'vmess://${base64.encode(utf8.encode(jsonEncode(json)))}';
    case 'vless':
      final id = _s(p['uuid']);
      if (id == null) return null;
      return 'vless://$id@${_host(server)}:$port${_query({
            'encryption': _s(p['encryption']) ?? 'none',
            ...secure(),
            ...transport(),
            'flow': _s(p['flow']),
          })}#${_tag(name)}';
    case 'trojan':
      final pw = _s(p['password']);
      if (pw == null) return null;
      return 'trojan://${Uri.encodeComponent(pw)}@${_host(server)}:$port${_query({
            ...secure(),
            if (!tls && reality == null) 'security': 'tls',
            ...transport(),
          })}#${_tag(name)}';
    case 'hysteria2' || 'hy2':
      final pw = _s(p['password']);
      if (pw == null) return null;
      return 'hysteria2://${Uri.encodeComponent(pw)}@${_host(server)}:$port${_query({
            'sni': sni,
            'insecure': insecure,
            'obfs': _s(p['obfs']),
            'obfs-password': _s(p['obfs-password']),
            'alpn': _alpn(p['alpn']),
            'mport': _s(p['ports'] ?? p['mport']),
          })}#${_tag(name)}';
    case 'anytls':
      final pw = _s(p['password']);
      if (pw == null) return null;
      return 'anytls://${Uri.encodeComponent(pw)}@${_host(server)}:$port${_query({
            'sni': sni,
            'insecure': insecure,
            'alpn': _alpn(p['alpn']),
            'fp': _s(p['client-fingerprint']),
          })}#${_tag(name)}';
    case 'socks5' || 'socks':
      final user = _s(p['username']);
      final auth = user == null
          ? ''
          : '${Uri.encodeComponent(user)}:${Uri.encodeComponent(_s(p['password']) ?? '')}@';
      return 'socks5://$auth${_host(server)}:$port#${_tag(name)}';
    case 'hysteria':
      return 'hysteria://${_host(server)}:$port${_query({
            'auth': _s(p['auth-str'] ?? p['auth_str']),
            'peer': sni,
            'insecure': insecure,
            'upmbps': _s(p['up']),
            'downmbps': _s(p['down']),
            'alpn': _alpn(p['alpn']),
            'obfsParam': _s(p['obfs']),
          })}#${_tag(name)}';
    case 'tuic':
      final id = _s(p['uuid']);
      if (id == null) return null;
      final pw = _s(p['password']) ?? '';
      return 'tuic://$id:${Uri.encodeComponent(pw)}@${_host(server)}:$port${_query({
            'sni': sni,
            'allow_insecure': insecure,
            'congestion_control': _s(p['congestion-controller']),
            'udp_relay_mode': _s(p['udp-relay-mode']),
            'alpn': _alpn(p['alpn']),
          })}#${_tag(name)}';
  }
  return null;
}

/// A sing-box WireGuard endpoint (sing-box 1.11 and later): the first of its peers.
String? _singBoxWireguard(Map e) {
  final peers = e['peers'];
  if (peers is! List || peers.isEmpty || peers.first is! Map) return null;
  final peer = peers.first as Map;
  final server = _s(peer['address']);
  final port = _s(peer['port']);
  if (server == null || port == null) return null;
  final address = e['address'];
  return _wireguardLink(server, port, e['tag'],
      privateKey: _s(e['private_key']),
      publicKey: _s(peer['public_key']),
      addresses: address is List ? [for (final a in address) if (_s(a) != null) _s(a)!] : [if (_s(address) != null) _s(address)!],
      preSharedKey: _s(peer['pre_shared_key']),
      reserved: peer['reserved'],
      mtu: e['mtu'],
      keepAlive: peer['persistent_keepalive_interval'],
      allowedIps: peer['allowed_ips']);
}

/// One sing-box outbound; [byTag] holds the others, for one it is dialled through.
String? _singBoxLink(Map o, Map<String, Map> byTag) {
  var type = _s(o['type'])?.toLowerCase();
  var server = _s(o['server']);
  var port = _s(o['server_port']);
  // A Shadowsocks server behind ShadowTLS: the address is the ShadowTLS layer's, which a link writes as the
  // shadow-tls plugin.
  String? shadowTls;
  final under = byTag[_s(o['detour'])];
  if (type == 'shadowsocks' && under != null && _s(under['type'])?.toLowerCase() == 'shadowtls') {
    final t = under['tls'] is Map ? under['tls'] as Map : const {};
    final u = t['utls'] is Map ? t['utls'] as Map : const {};
    server = _s(under['server']);
    port = _s(under['server_port']);
    shadowTls = [
      'shadow-tls',
      if (_s(t['server_name']) != null) 'host=${_s(t['server_name'])}',
      if (_s(under['password']) != null) 'password=${_s(under['password'])}',
      'version=${_s(under['version']) ?? '3'}',
      if (_s(u['fingerprint']) != null) 'fingerprint=${_s(u['fingerprint'])}',
    ].join(';');
  } else if (under != null && _s(under['type'])?.toLowerCase() != 'direct') {
    // Another kind of chain cannot be written as one link (going out directly is no chain).
    return null;
  }
  if (type == null || server == null || port == null) return null;
  final name = o['tag'];
  final tlsMap = o['tls'] is Map ? o['tls'] as Map : const {};
  final tls = _on(tlsMap['enabled']);
  final sni = _s(tlsMap['server_name']);
  final insecure = _on(tlsMap['insecure']) ? '1' : null;
  final realityMap =
      tlsMap['reality'] is Map && _on((tlsMap['reality'] as Map)['enabled'])
          ? tlsMap['reality'] as Map
          : null;
  final utls = tlsMap['utls'] is Map ? tlsMap['utls'] as Map : const {};
  final tr = o['transport'] is Map ? o['transport'] as Map : const {};
  final network = _s(tr['type']) ?? 'tcp';
  final headers = tr['headers'] is Map ? tr['headers'] as Map : const {};

  Map<String, String?> transport() => {
        'type': network,
        'path': _s(tr['path']),
        'host': _s(headers['Host'] ??
            headers['host'] ??
            (tr['host'] is List ? (tr['host'] as List).join(',') : tr['host'])),
        'serviceName': _s(tr['service_name']),
      };

  Map<String, String?> secure() => {
        'security': realityMap != null ? 'reality' : (tls ? 'tls' : 'none'),
        'sni': sni,
        'fp': _s(utls['fingerprint']),
        'alpn': _alpn(tlsMap['alpn']),
        'allowInsecure': insecure,
        'pbk': _s(realityMap?['public_key']),
        'sid': _s(realityMap?['short_id']),
      };

  switch (type) {
    case 'shadowsocks':
      var plugin = shadowTls;
      final pname = _s(o['plugin'])?.toLowerCase();
      if (plugin == null && pname != null) {
        // obfs-local and v2ray-plugin, the two sing-box has built in; another one cannot work.
        if (pname != 'obfs-local' && pname != 'v2ray-plugin') return null;
        plugin = [pname, if (_s(o['plugin_opts']) != null) _s(o['plugin_opts'])].join(';');
      }
      return _ssLink(_s(o['method']), _s(o['password']), server, port, name, plugin: plugin);
    case 'http':
      // A path or headers of its own cannot be written in a link.
      if (_s(o['path']) != null || o['headers'] is Map && (o['headers'] as Map).isNotEmpty) return null;
      return _httpLink(server, port, name,
          user: _s(o['username']), pass: _s(o['password']), tls: tls, sni: sni, insecure: insecure);
    case 'naive':
      return '${_on(o['quic']) ? 'naive+quic' : 'naive+https'}://'
          '${_s(o['username']) == null ? '' : '${Uri.encodeComponent(_s(o['username'])!)}:${Uri.encodeComponent(_s(o['password']) ?? '')}@'}'
          '${_host(server)}:$port${_query({'sni': sni})}#${_tag(name)}';
    case 'vmess':
      final json = {
        'v': '2',
        'ps': _s(name) ?? '',
        'add': server,
        'port': port,
        'id': _s(o['uuid']) ?? '',
        'aid': _s(o['alter_id']) ?? '0',
        'scy': _s(o['security']) ?? 'auto',
        'net': network,
        'type': 'none',
        'host': _s(headers['Host']) ?? '',
        'path': network == 'grpc'
            ? (_s(tr['service_name']) ?? '')
            : (_s(tr['path']) ?? ''),
        'tls': tls ? 'tls' : '',
        'sni': sni ?? '',
        'alpn': _alpn(tlsMap['alpn']),
        'fp': _s(utls['fingerprint']) ?? '',
      };
      return 'vmess://${base64.encode(utf8.encode(jsonEncode(json)))}';
    case 'vless':
      final id = _s(o['uuid']);
      if (id == null) return null;
      return 'vless://$id@${_host(server)}:$port${_query({
            'encryption': 'none',
            ...secure(),
            ...transport(),
            'flow': _s(o['flow']),
          })}#${_tag(name)}';
    case 'trojan':
      final pw = _s(o['password']);
      if (pw == null) return null;
      return 'trojan://${Uri.encodeComponent(pw)}@${_host(server)}:$port${_query({
            ...secure(),
            ...transport(),
          })}#${_tag(name)}';
    case 'hysteria2':
      final pw = _s(o['password']);
      if (pw == null) return null;
      final obfs = o['obfs'] is Map ? o['obfs'] as Map : const {};
      return 'hysteria2://${Uri.encodeComponent(pw)}@${_host(server)}:$port${_query({
            'sni': sni,
            'insecure': insecure,
            'obfs': _s(obfs['type']),
            'obfs-password': _s(obfs['password']),
            'alpn': _alpn(tlsMap['alpn']),
            // port hopping: sing-box writes ranges as "5000:6000"
            'mport': o['server_ports'] is List
                ? (o['server_ports'] as List)
                    .map((e) => '$e'.replaceAll(':', '-'))
                    .join(',')
                : null,
          })}#${_tag(name)}';
    case 'anytls':
      final pw = _s(o['password']);
      if (pw == null) return null;
      return 'anytls://${Uri.encodeComponent(pw)}@${_host(server)}:$port${_query({
            'sni': sni,
            'insecure': insecure,
            'alpn': _alpn(tlsMap['alpn']),
            'fp': _s(utls['fingerprint']),
          })}#${_tag(name)}';
    case 'socks':
      final user = _s(o['username']);
      final auth = user == null
          ? ''
          : '${Uri.encodeComponent(user)}:${Uri.encodeComponent(_s(o['password']) ?? '')}@';
      return 'socks5://$auth${_host(server)}:$port#${_tag(name)}';
    case 'hysteria':
      return 'hysteria://${_host(server)}:$port${_query({
            'auth': _s(o['auth_str']),
            'peer': sni,
            'insecure': insecure,
            'upmbps': _s(o['up_mbps']),
            'downmbps': _s(o['down_mbps']),
            'alpn': _alpn(tlsMap['alpn']),
            'obfsParam': _s(o['obfs']),
          })}#${_tag(name)}';
    case 'ssh':
      final user = _s(o['user']);
      if (user == null) return null;
      return 'ssh://${Uri.encodeComponent(user)}:${Uri.encodeComponent(_s(o['password']) ?? '')}@${_host(server)}:$port#${_tag(name)}';
    case 'tuic':
      final id = _s(o['uuid']);
      if (id == null) return null;
      return 'tuic://$id:${Uri.encodeComponent(_s(o['password']) ?? '')}@${_host(server)}:$port${_query({
            'sni': sni,
            'allow_insecure': insecure,
            'congestion_control': _s(o['congestion_control']),
            'udp_relay_mode': _s(o['udp_relay_mode']),
            'alpn': _alpn(tlsMap['alpn']),
          })}#${_tag(name)}';
  }
  return null;
}
