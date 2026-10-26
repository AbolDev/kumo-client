import 'dart:convert';

import 'net_options.dart';
import 'proxy_config.dart';
import 'routing_rules.dart';

/// Builds the Xray configuration for one XHTTP server: a local SOCKS inbound on
/// 127.0.0.1:[port] that forwards everything to the server.
String buildXrayConfig(ProxyConfig server, int port, {String logLevel = 'error'}) {
  assert(server.needsXray);
  final outbound =
      jsonDecode(jsonEncode(server.xrayOutbound!)) as Map<String, dynamic>;
  final inbounds = <Map<String, dynamic>>[
    {
      'tag': 'socks-in',
      'listen': '127.0.0.1',
      'port': port,
      'protocol': 'socks',
      'settings': {'auth': 'noauth', 'udp': true},
    },
  ];
  final outbounds = <Map<String, dynamic>>[];
  final rules = <Map<String, dynamic>>[];
  // Xray refuses VLESS without TLS towards a public address. Such servers are reached
  // through a loopback relay inside the same process, which Xray treats as private.
  final vnext = outbound['settings'] is Map
      ? (outbound['settings']['vnext'] as List?)
      : null;
  final security =
      '${(outbound['streamSettings'] as Map?)?['security'] ?? 'none'}';
  if (outbound['protocol'] == 'vless' &&
      vnext != null &&
      vnext.isNotEmpty &&
      (security == 'none' || security.isEmpty)) {
    final node = vnext.first as Map<String, dynamic>;
    final relayPort = port == 65535 ? port - 1 : port + 1;
    inbounds.add({
      'tag': 'relay-in',
      'listen': '127.0.0.1',
      'port': relayPort,
      'protocol': 'dokodemo-door',
      'settings': {
        'address': node['address'],
        'port': node['port'],
        'network': 'tcp',
      },
    });
    outbounds.add({'protocol': 'freedom', 'tag': 'relay-out'});
    rules.add({
      'type': 'field',
      'inboundTag': ['relay-in'],
      'outboundTag': 'relay-out',
    });
    node['address'] = '127.0.0.1';
    node['port'] = relayPort;
  }
  final config = {
    // Xray names its levels differently; the default stays at warning as before.
    'log': {
      'loglevel': switch (logLevel) {
        'debug' => 'debug',
        'info' => 'info',
        _ => 'warning',
      }
    },
    'inbounds': inbounds,
    'outbounds': [
      {...outbound, 'tag': 'proxy'},
      ...outbounds,
    ],
    if (rules.isNotEmpty) 'routing': {'rules': rules},
  };
  return const JsonEncoder.withIndent('  ').convert(config);
}

/// Protocols that run over TLS on TCP, where uTLS and fragmenting apply.
const _tlsTcp = {'vless', 'vmess', 'trojan'};

/// Applies the advanced options to one outbound.
Map<String, dynamic> _tweak(Map<String, dynamic> source, NetOptions o,
    {String? detour}) {
  final out = {...source};
  final type = out['type'];
  final tls = out['tls'];
  if (tls is Map && tls['enabled'] == true && _tlsTcp.contains(type)) {
    final t = Map<String, dynamic>.from(tls);
    if (o.fingerprint.isNotEmpty) {
      t['utls'] = {'enabled': true, 'fingerprint': o.fingerprint};
    }
    if (o.tlsFragment && t['reality'] == null) t['fragment'] = true;
    out['tls'] = t;
  }
  if (o.mux &&
      (_tlsTcp.contains(type) || type == 'shadowsocks') &&
      out['flow'] == null &&
      out['multiplex'] == null) {
    out['multiplex'] = {'enabled': true, 'protocol': 'h2mux', 'padding': true};
  }
  if (detour != null) out['detour'] = detour;
  return out;
}

Map<String, dynamic> _dnsServer(String address) {
  if (address.startsWith('https://') || address.startsWith('tls://')) {
    final uri = Uri.parse(address);
    final https = uri.scheme == 'https';
    return {
      'type': https ? 'https' : 'tls',
      'tag': 'dns-remote',
      'server': uri.host,
      if (uri.hasPort) 'server_port': uri.port,
      if (https && uri.path.isNotEmpty && uri.path != '/dns-query')
        'path': uri.path,
      'domain_resolver': 'dns-local',
      'detour': 'proxy',
    };
  }
  return {
    'type': 'udp',
    'tag': 'dns-remote',
    'server': address,
    'domain_resolver': 'dns-local',
    'detour': 'proxy',
  };
}

/// Builds the full sing-box configuration: a local mixed (HTTP + SOCKS) proxy on
/// [NetOptions.proxyPort], a TUN inbound when the whole device is tunneled, and the selected
/// outbound(s).
///
/// One config => a plain outbound named `proxy`. Several => a `urltest` group
/// named `proxy` that always picks the fastest reachable member.
///
/// A single XHTTP server is reached through the local SOCKS inbound of Xray ([xrayPort]).
/// [ruleSets] maps rule-set tags to downloaded files; [apiPort] opens the local control API.
String buildSingBoxConfig(
  List<ProxyConfig> servers, {
  int? xrayPort,
  NetOptions? options,
  Map<String, String> ruleSets = const {},
  int? apiPort,
  String? apiSecret,
  bool windows = false,
  ProxyConfig? chain,
}) {
  assert(servers.isNotEmpty);
  final o = options ?? NetOptions();
  final useChain = chain != null && !chain.needsXray;
  final detour = useChain ? 'chain-entry' : null;
  final outbounds = <Map<String, dynamic>>[];
  if (servers.length == 1 && servers.first.needsXray) {
    outbounds.add({
      'type': 'socks',
      'tag': 'proxy',
      'server': '127.0.0.1',
      'server_port': xrayPort,
      'version': '5',
    });
  } else if (servers.length == 1) {
    outbounds
        .add(_tweak({...servers.first.outbound, 'tag': 'proxy'}, o, detour: detour));
  } else {
    final tags = <String>[];
    for (var i = 0; i < servers.length; i++) {
      final tag = 'server-$i';
      tags.add(tag);
      outbounds
          .add(_tweak({...servers[i].outbound, 'tag': tag}, o, detour: detour));
    }
    outbounds.insert(0, {
      'type': 'urltest',
      'tag': 'proxy',
      'outbounds': tags,
      'url': 'https://www.gstatic.com/generate_204',
      // Probing less often keeps the radio asleep; it also pauses after 30 idle minutes.
      'interval': '10m',
      'idle_timeout': '30m',
      'tolerance': 80,
    });
  }
  if (useChain) {
    outbounds.add(_tweak({...chain.outbound, 'tag': 'chain-entry'}, o));
  }
  outbounds.add({'type': 'direct', 'tag': 'direct'});

  final inbounds = <Map<String, dynamic>>[
    {
      'type': 'mixed',
      'tag': 'mixed-in',
      'listen': '127.0.0.1',
      'listen_port': o.proxyPort,
    },
  ];
  // A second proxy for other devices on the network. It always needs the user name and password,
  // and the local one above stays open for this device (the Windows system proxy has no login).
  if (o.shareLan && o.lanPassword.isNotEmpty && o.lanPort != o.proxyPort) {
    inbounds.add({
      'type': 'mixed',
      'tag': 'lan-in',
      'listen': '0.0.0.0',
      'listen_port': o.lanPort,
      'users': [
        {'username': o.lanUser, 'password': o.lanPassword},
      ],
    });
  }
  final apps = o.apps;
  if (o.tun) {
    inbounds.add({
      'type': 'tun',
      'tag': 'tun-in',
      'address': ['172.19.0.1/30', 'fdfe:dcba:9876::1/126'],
      'mtu': o.mtu,
      'auto_route': true,
      'strict_route': true,
      'stack': 'mixed',
      if (!windows && o.appMode == AppMode.only && apps.isNotEmpty)
        'include_package': apps,
      if (!windows && o.appMode == AppMode.except && apps.isNotEmpty)
        'exclude_package': apps,
    });
  }

  final sets = ruleSets.keys.toList();
  final iran = o.bypass.isNotEmpty;
  final suffixes = [for (final c in o.bypass) '.$c'];
  // The user's own rules come before everything else; "through the VPN" wins over "direct" if a
  // domain is in both lists.
  List<String> ofKind(List<String> list, {required bool ip}) => [
        for (final r in list)
          if (parseRouteRule(r) case final rule? when rule.ip == ip) rule.value,
      ];
  final directDomains = ofKind(o.directRules, ip: false);
  final directIps = ofKind(o.directRules, ip: true);
  final proxyDomains = ofKind(o.proxyRules, ip: false);
  final proxyIps = ofKind(o.proxyRules, ip: true);
  final rules = <Map<String, dynamic>>[
    {'action': 'sniff'},
    {'protocol': 'dns', 'action': 'hijack-dns'},
    if (proxyDomains.isNotEmpty) {'domain_suffix': proxyDomains, 'outbound': 'proxy'},
    if (proxyIps.isNotEmpty) {'ip_cidr': proxyIps, 'outbound': 'proxy'},
    if (directDomains.isNotEmpty) {'domain_suffix': directDomains, 'outbound': 'direct'},
    if (directIps.isNotEmpty) {'ip_cidr': directIps, 'outbound': 'direct'},
    {'ip_is_private': true, 'outbound': 'direct'},
  ];
  final processRules = windows && o.tun && apps.isNotEmpty;
  if (processRules && o.appMode == AppMode.except) {
    rules.add({'process_name': apps, 'outbound': 'direct'});
  }
  if (processRules && o.appMode == AppMode.only) {
    rules.add({'process_name': apps, 'outbound': 'proxy'});
  }
  if (iran) {
    rules.add({'domain_suffix': suffixes, 'outbound': 'direct'});
    if (sets.isNotEmpty) {
      rules.add({'rule_set': sets, 'outbound': 'direct'});
    }
  }

  final config = {
    'log': {'level': logLevels.contains(o.logLevel) ? o.logLevel : 'error'},
    'dns': {
      'servers': [
        _dnsServer(o.dnsAddress),
        {'type': 'local', 'tag': 'dns-local'},
      ],
      if (iran || directDomains.isNotEmpty)
        'rules': [
          // names the user sends direct are also looked up locally, not through the VPN
          if (directDomains.isNotEmpty)
            {'domain_suffix': directDomains, 'server': 'dns-local'},
          if (iran) ...[
            {
              'domain_suffix': suffixes,
              'server': 'dns-local',
            },
            if (sets.isNotEmpty) {'rule_set': sets, 'server': 'dns-local'},
          ],
        ],
      'final': 'dns-remote',
    },
    'inbounds': inbounds,
    'outbounds': outbounds,
    'route': {
      'rules': rules,
      if (sets.isNotEmpty && iran)
        'rule_set': [
          for (final e in ruleSets.entries)
            {
              'type': 'local',
              'tag': e.key,
              'format': 'binary',
              'path': e.value,
            },
        ],
      'final': processRules && o.appMode == AppMode.only ? 'direct' : 'proxy',
      'auto_detect_interface': true,
      'default_domain_resolver': 'dns-local',
      if (processRules) 'find_process': true,
    },
    if (apiPort != null)
      'experimental': {
        'clash_api': {
          'external_controller': '127.0.0.1:$apiPort',
          if (apiSecret != null) 'secret': apiSecret,
        },
      },
  };
  return const JsonEncoder.withIndent('  ').convert(config);
}