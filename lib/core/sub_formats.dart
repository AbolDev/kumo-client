import 'dart:convert';
import 'dart:isolate';

import 'package:yaml/yaml.dart';

import 'config_decryptor.dart' show xrayJsonToLinks;
import 'proxy_config.dart' show extractLinks;

/// Turns the body of a subscription, in whichever format the provider serves it, into
/// share links: a plain or base64 list of links, a Clash / Mihomo YAML, a sing-box or
/// Xray / V2Ray JSON, or a SIP008 Shadowsocks list.
List<String> extractSubscriptionLinks(String body, {int depth = 0}) {
  final text = body.trim();
  if (text.isEmpty) return const [];
  final links = extractLinks(text);
  if (links.isNotEmpty) return links;

  if (text.startsWith('{') || text.startsWith('[')) {
    try {
      final found = _fromJson(jsonDecode(text));
      if (found.isNotEmpty) return found;
    } catch (_) {
      // not JSON after all
    }
  }
  if (text.contains('proxies:') || text.contains('proxy-providers:')) {
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

/// Same, off the UI thread (a top-level function so nothing else is captured).
Future<List<String>> extractSubscriptionLinksInBackground(String body) =>
    Isolate.run(() => extractSubscriptionLinks(body));

/// YAML nodes -> plain Dart maps and lists.
Object? _plain(Object? v) {
  if (v is YamlMap)
    return {for (final e in v.entries) '${e.key}': _plain(e.value)};
  if (v is YamlList) return [for (final e in v) _plain(e)];
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
      final singbox = outbounds.where((o) => o is Map && o['type'] != null);
      if (singbox.isNotEmpty) {
        for (final o in singbox) {
          final l = _singBoxLink(o as Map);
          if (l != null) out.add(l);
        }
        handled = true;
      }
    }
    if (!handled && v['type'] != null && v['server'] != null) {
      final l = _singBoxLink(v) ?? _clashLink(v);
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

String? _ssLink(String? method, String? password, String? server, Object? port,
    Object? name) {
  if (method == null ||
      password == null ||
      server == null ||
      _s(port) == null) {
    return null;
  }
  final userinfo = base64.encode(utf8.encode('$method:$password'));
  return 'ss://$userinfo@${_host(server)}:${_s(port)}#${_tag(name)}';
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
      return _ssLink(_s(p['cipher']), _s(p['password']), server, port, name);
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

/// One sing-box outbound.
String? _singBoxLink(Map o) {
  final type = _s(o['type'])?.toLowerCase();
  final server = _s(o['server']);
  final port = _s(o['server_port']);
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
      return _ssLink(_s(o['method']), _s(o['password']), server, port, name);
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
