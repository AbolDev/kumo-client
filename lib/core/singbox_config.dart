import 'dart:convert';

import 'net_options.dart';
import 'proxy_config.dart';
import 'routing_rules.dart';
import 'rule_sets.dart' show adsTag;

/// Merges [extra] (a JSON object the user typed) into [target], map by map; lists and values from
/// [extra] replace the ones in [target].
Map<String, dynamic> mergeJson(Map<String, dynamic> target, Map<String, dynamic> extra) {
  final out = {...target};
  extra.forEach((key, value) {
    final current = out[key];
    out[key] = current is Map<String, dynamic> && value is Map<String, dynamic>
        ? mergeJson(current, value)
        : value;
  });
  return out;
}

/// The JSON object in [text], or null when it is empty or not a JSON object.
Map<String, dynamic>? parseExtraJson(String text) {
  final t = text.trim();
  if (t.isEmpty) return null;
  try {
    final v = jsonDecode(t);
    return v is Map<String, dynamic> ? v : null;
  } catch (_) {
    return null;
  }
}

/// Builds the Xray configuration for one server: a local SOCKS inbound on 127.0.0.1:[port] that
/// forwards everything to it. sing-box connects to that port.
String buildXrayConfig(ProxyConfig server, int port,
    {String logLevel = 'error', NetOptions? options}) {
  assert(server.canXray);
  final o = options ?? NetOptions();
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
  final settings = outbound['settings'] is Map<String, dynamic>
      ? outbound['settings'] as Map<String, dynamic>
      : <String, dynamic>{};
  final vnext = settings['vnext'] as List?;
  final stream = outbound['streamSettings'] is Map<String, dynamic>
      ? outbound['streamSettings'] as Map<String, dynamic>
      : null;
  final security = '${stream?['security'] ?? 'none'}';

  // The options of Settings that apply to Xray too.
  if (stream != null) {
    final tls = stream['tlsSettings'];
    if (tls is Map<String, dynamic> && o.fingerprint.isNotEmpty) {
      tls['fingerprint'] = o.fingerprint;
    }
    final reality = stream['realitySettings'];
    if (reality is Map<String, dynamic> && o.fingerprint.isNotEmpty) {
      reality['fingerprint'] = o.fingerprint;
    }
    final sockopt = <String, dynamic>{
      if (o.tcpFastOpen) 'tcpFastOpen': true,
      if (o.tcpMultiPath) 'tcpMptcp': true,
    };
    if (sockopt.isNotEmpty) {
      stream['sockopt'] = mergeJson(
          stream['sockopt'] is Map<String, dynamic>
              ? stream['sockopt'] as Map<String, dynamic>
              : <String, dynamic>{},
          sockopt);
    }
    // Splitting the TLS hello is a TCP final mask in Xray.
    if (o.tlsFragment && security == 'tls') {
      final fm = stream['finalmask'] is Map<String, dynamic>
          ? stream['finalmask'] as Map<String, dynamic>
          : <String, dynamic>{};
      final tcp = fm['tcp'] is List ? List.of(fm['tcp'] as List) : <dynamic>[];
      tcp.add({
        'type': 'fragment',
        'settings': {
          'packets': 'tlshello',
          'lengths': ['3-5', '6-8', '10-20'],
          'delays': ['10-20'],
          'maxSplit': '3-6',
        },
      });
      fm['tcp'] = tcp;
      stream['finalmask'] = fm;
    }
    final extra = parseExtraJson(o.extraXray);
    if (extra != null) {
      outbound['streamSettings'] = mergeJson(stream, extra);
    }
  }
  final protocol = outbound['protocol'];
  final hasFlow = vnext != null &&
      vnext.isNotEmpty &&
      ((vnext.first as Map)['users'] as List).any((u) => (u as Map)['flow'] != null);
  if (o.mux &&
      !hasFlow &&
      (protocol == 'vless' || protocol == 'vmess' || protocol == 'trojan' || protocol == 'shadowsocks')) {
    outbound['mux'] = {
      'enabled': true,
      'concurrency': 8,
      'xudpConcurrency': 16,
      'xudpProxyUDP443': 'reject',
    };
  }

  // Xray refuses VLESS without TLS (or encryption) towards a public address. Such servers are
  // reached through a loopback relay inside the same process, which Xray treats as private.
  final encrypted = vnext != null &&
      vnext.isNotEmpty &&
      ((vnext.first as Map)['users'] as List).any((u) {
        final e = '${(u as Map)['encryption'] ?? 'none'}';
        return e.isNotEmpty && e != 'none';
      });
  if (protocol == 'vless' &&
      vnext != null &&
      vnext.isNotEmpty &&
      !encrypted &&
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
      'loglevel': switch (options != null ? o.logLevel : logLevel) {
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

/// Applies the advanced options to one outbound. [dials] is true for the outbound that opens the
/// connection to the network (the last one of a chain), which gets the socket options.
Map<String, dynamic> _tweak(Map<String, dynamic> source, NetOptions o,
    {String? detour, bool dials = true, bool first = true}) {
  final out = {...source};
  final type = out['type'];
  final tls = out['tls'];
  if (first && tls is Map && tls['enabled'] == true && _tlsTcp.contains(type)) {
    final t = Map<String, dynamic>.from(tls);
    if (o.fingerprint.isNotEmpty) {
      t['utls'] = {'enabled': true, 'fingerprint': o.fingerprint};
    }
    if (t['reality'] == null) {
      if (o.tlsFragment) t['fragment'] = true;
      if (o.tlsRecordFragment) t['record_fragment'] = true;
    }
    out['tls'] = t;
  }
  if (first &&
      o.mux &&
      (_tlsTcp.contains(type) || type == 'shadowsocks') &&
      out['flow'] == null &&
      out['multiplex'] == null) {
    out['multiplex'] = {'enabled': true, 'protocol': o.muxProtocol, 'padding': true};
  }
  if (dials) {
    if (o.tcpFastOpen) out['tcp_fast_open'] = true;
    if (o.tcpMultiPath) out['tcp_multi_path'] = true;
    if (o.connectTimeout > 0) out['connect_timeout'] = '${o.connectTimeout}s';
  }
  if (detour != null) out['detour'] = detour;
  if (first) {
    final extra = parseExtraJson(o.extraSingbox);
    if (extra != null) {
      final protectedKeys = {'tag', 'type'};
      return mergeJson(out, {
        for (final e in extra.entries)
          if (!protectedKeys.contains(e.key)) e.key: e.value,
      });
    }
  }
  return out;
}

/// The DNS server for the chosen address: plain UDP, `tcp://`, `tls://` (DoT), `quic://` (DoQ),
/// `https://` (DoH) or `h3://` (DoH over HTTP/3). It is always reached through the proxy.
Map<String, dynamic> _dnsServer(String address, {String resolver = 'dns-local'}) {
  final scheme = RegExp(r'^(https|h3|tls|quic|tcp|udp)://').firstMatch(address)?[1];
  if (scheme == null) {
    return {
      'type': 'udp',
      'tag': 'dns-remote',
      'server': address,
      'domain_resolver': resolver,
      'detour': 'proxy',
    };
  }
  final uri = Uri.parse(address);
  return {
    'type': scheme,
    'tag': 'dns-remote',
    'server': uri.host,
    if (uri.hasPort) 'server_port': uri.port,
    if ((scheme == 'https' || scheme == 'h3') &&
        uri.path.isNotEmpty &&
        uri.path != '/dns-query')
      'path': uri.path,
    'domain_resolver': resolver,
    'detour': 'proxy',
  };
}

/// Splits stored rule texts into the sing-box rule fields they belong to.
class _RuleFields {
  final suffix = <String>[];
  final full = <String>[];
  final keyword = <String>[];
  final regex = <String>[];
  final cidr = <String>[];
  final ports = <int>[];
  final ranges = <String>[];

  _RuleFields(List<String> texts) {
    for (final t in texts) {
      final r = parseRouteRule(t);
      if (r == null) continue;
      switch (r.kind) {
        case RuleKind.domain:
          suffix.add(r.value);
        case RuleKind.full:
          full.add(r.value);
        case RuleKind.keyword:
          keyword.add(r.value);
        case RuleKind.regex:
          regex.add(r.value);
        case RuleKind.ip:
          cidr.add(r.value);
        case RuleKind.port:
          if (r.value.contains('-')) {
            ranges.add(r.value.replaceFirst('-', ':'));
          } else {
            ports.add(int.parse(r.value));
          }
      }
    }
  }

  bool get hasDomains =>
      suffix.isNotEmpty || full.isNotEmpty || keyword.isNotEmpty || regex.isNotEmpty;

  /// Rules sending what matches to [target] (an `outbound` or an `action`).
  List<Map<String, dynamic>> rules(Map<String, dynamic> target, {bool domainsOnly = false}) => [
        if (suffix.isNotEmpty) {'domain_suffix': suffix, ...target},
        if (full.isNotEmpty) {'domain': full, ...target},
        if (keyword.isNotEmpty) {'domain_keyword': keyword, ...target},
        if (regex.isNotEmpty) {'domain_regex': regex, ...target},
        if (!domainsOnly && cidr.isNotEmpty) {'ip_cidr': cidr, ...target},
        if (!domainsOnly && ports.isNotEmpty) {'port': ports, ...target},
        if (!domainsOnly && ranges.isNotEmpty) {'port_range': ranges, ...target},
      ];
}

/// Builds the full sing-box configuration: a local mixed (HTTP + SOCKS) proxy on
/// [NetOptions.proxyPort], a TUN inbound when the whole device is tunneled, and the selected
/// outbound(s).
///
/// One config => a plain outbound named `proxy`. Several => a `urltest` group
/// named `proxy` that always picks the fastest reachable member.
///
/// With [viaXray] (or a single server that only Xray can carry) the server is reached through the
/// local SOCKS inbound of Xray ([xrayPort]). [ruleSets] maps rule-set tags to downloaded files;
/// [apiPort] opens the local control API.
String buildSingBoxConfig(
  List<ProxyConfig> servers, {
  int? xrayPort,
  NetOptions? options,
  Map<String, String> ruleSets = const {},
  int? apiPort,
  String? apiSecret,
  bool windows = false,
  ProxyConfig? chain,
  bool viaXray = false,
}) {
  assert(servers.isNotEmpty);
  final o = options ?? NetOptions();
  final useChain = chain != null && !chain.needsXray && chain.outbound['type'] != 'wireguard';
  final detour = useChain ? 'chain-entry' : null;
  final outbounds = <Map<String, dynamic>>[];
  final endpoints = <Map<String, dynamic>>[];

  /// Adds one server (and the layers it is dialled through) under [tag].
  void addServer(ProxyConfig s, String tag) {
    final layers = [s.outbound, ...s.inner];
    if (layers.first['type'] == 'wireguard') {
      // WireGuard is an endpoint in sing-box, usable like an outbound by its tag.
      endpoints.add(_tweak({...layers.first, 'tag': tag}, o,
          detour: detour, first: false));
      return;
    }
    for (var i = 0; i < layers.length; i++) {
      final last = i == layers.length - 1;
      final layerTag = i == 0 ? tag : '$tag-l$i';
      outbounds.add(_tweak(
        {...layers[i], 'tag': layerTag},
        o,
        detour: last ? detour : '$tag-l${i + 1}',
        dials: last,
        first: i == 0,
      ));
    }
  }

  final useXray =
      viaXray || (servers.length == 1 && servers.first.needsXray);
  if (useXray) {
    outbounds.add({
      'type': 'socks',
      'tag': 'proxy',
      'server': '127.0.0.1',
      'server_port': xrayPort,
      'version': '5',
    });
  } else if (servers.length == 1) {
    addServer(servers.first, 'proxy');
  } else {
    final tags = <String>[];
    var n = 0;
    for (final s in servers) {
      if (!s.canSingBox) continue;
      final tag = 'server-${n++}';
      tags.add(tag);
      addServer(s, tag);
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
    outbounds.add(_tweak({...chain.outbound, 'tag': 'chain-entry'}, o, first: false));
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

  final sets = ruleSets.keys.where((t) => t != adsTag).toList();
  final adSet = o.blockAds && ruleSets.containsKey(adsTag) ? adsTag : null;
  final strict = o.strictDns;
  final iran = o.bypass.isNotEmpty;
  final suffixes = [for (final c in o.bypass) '.$c'];
  final block = _RuleFields(o.blockRules);
  final proxy = _RuleFields(o.proxyRules);
  final direct = _RuleFields(o.directRules);
  final wifi = !windows && o.directWifi.isNotEmpty;
  final fakeIp = o.fakeIp && o.tun;
  // The user's own rules come before everything else: what is blocked first, then "through the
  // VPN" (which wins over "direct" if a domain is in both lists), then "direct".
  final rules = <Map<String, dynamic>>[
    {'action': 'sniff'},
    {'protocol': 'dns', 'action': 'hijack-dns'},
    ...block.rules({'action': 'reject'}),
    if (adSet != null) {'rule_set': [adSet], 'action': 'reject'},
    // WebRTC would show the network's own address; DNS over TLS would skip the resolver above.
    if (o.blockStun) {'protocol': 'stun', 'action': 'reject'},
    if (strict) {'port': 853, 'network': 'tcp', 'action': 'reject'},
    if (wifi) {'wifi_ssid': o.directWifi, 'outbound': 'direct'},
    ...proxy.rules({'outbound': 'proxy'}),
    ...direct.rules({'outbound': 'direct'}),
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

  final dnsRules = <Map<String, dynamic>>[
    // blocked names fail at once
    ...block.rules({'action': 'reject'}, domainsOnly: true),
    if (adSet != null) {'rule_set': [adSet], 'action': 'reject'},
    if (wifi) {'wifi_ssid': o.directWifi, 'server': 'dns-local'},
    // names the user sends direct are also looked up locally, not through the VPN
    ...direct.rules({'server': 'dns-local'}, domainsOnly: true),
    if (iran) ...[
      {'domain_suffix': suffixes, 'server': 'dns-local'},
      if (sets.isNotEmpty) {'rule_set': sets, 'server': 'dns-local'},
    ],
    // Fake addresses for everything else (TUN only): the real lookup happens at the server.
    if (fakeIp) {'query_type': ['A', 'AAAA'], 'server': 'dns-fakeip'},
  ];

  final config = {
    'log': {'level': logLevels.contains(o.logLevel) ? o.logLevel : 'error'},
    if (o.certStore != 'system') 'certificate': {'store': o.certStore},
    if (o.ntp)
      'ntp': {
        'enabled': true,
        'server': 'time.cloudflare.com',
        'server_port': 123,
        'interval': '30m',
        'detour': 'direct',
      },
    'dns': {
      'servers': [
        _dnsServer(o.dnsAddress, resolver: strict ? 'dns-boot' : 'dns-local'),
        {'type': 'local', 'tag': 'dns-local'},
        // Looks up server names over encrypted DNS, straight out, so the network's resolver
        // never sees them.
        if (strict)
          {'type': 'https', 'tag': 'dns-boot', 'server': '1.1.1.1'},
        if (fakeIp)
          {
            'type': 'fakeip',
            'tag': 'dns-fakeip',
            'inet4_range': '198.18.0.0/15',
            'inet6_range': 'fc00::/18',
          },
      ],
      if (dnsRules.isNotEmpty) 'rules': dnsRules,
      'final': 'dns-remote',
    },
    'inbounds': inbounds,
    'outbounds': outbounds,
    if (endpoints.isNotEmpty) 'endpoints': endpoints,
    'route': {
      'rules': rules,
      if ((sets.isNotEmpty && iran) || adSet != null)
        'rule_set': [
          for (final e in ruleSets.entries)
            if (e.key == adSet || (iran && e.key != adsTag))
            {
              'type': 'local',
              'tag': e.key,
              'format': 'binary',
              'path': e.value,
            },
        ],
      'final': processRules && o.appMode == AppMode.only ? 'direct' : 'proxy',
      'auto_detect_interface': true,
      'default_domain_resolver': strict ? 'dns-boot' : 'dns-local',
      if (processRules) 'find_process': true,
      if (!windows && o.networkStrategy != 'default') ...{
        'default_network_strategy': o.networkStrategy,
        if (o.networkStrategy == 'fallback') 'default_fallback_delay': '300ms',
      },
    },
    if (apiPort != null || fakeIp)
      'experimental': {
        if (apiPort != null)
          'clash_api': {
            'external_controller': '127.0.0.1:$apiPort',
            if (apiSecret != null) 'secret': apiSecret,
          },
        // fake addresses must survive a restart of the core
        if (fakeIp) 'cache_file': {'enabled': true, 'store_fakeip': true},
      },
  };
  return const JsonEncoder.withIndent('  ').convert(config);
}
