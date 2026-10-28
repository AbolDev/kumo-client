import 'dart:convert';
import 'dart:io';

/// Routing rules a subscription's provider sends in the `routing` header, in the format the Happ
/// app uses: `happ://routing/onadd/<base64 of a JSON>`, with lists of sites and addresses that go
/// direct, through the VPN, or are blocked, and the order those lists are looked at.
class ProviderRouting {
  const ProviderRouting({
    this.name = '',
    this.globalProxy = true,
    this.order = const ['block', 'proxy', 'direct'],
    this.directSites = const [],
    this.directIp = const [],
    this.blockSites = const [],
    this.blockIp = const [],
    this.proxySites = const [],
    this.proxyIp = const [],
  });

  final String name;

  /// True: what no rule matches goes through the VPN. False: it goes direct.
  final bool globalProxy;

  /// Which list wins first, e.g. block, then proxy, then direct.
  final List<String> order;
  final List<String> directSites, directIp, blockSites, blockIp, proxySites, proxyIp;

  bool get isEmpty =>
      directSites.isEmpty &&
      directIp.isEmpty &&
      blockSites.isEmpty &&
      blockIp.isEmpty &&
      proxySites.isEmpty &&
      proxyIp.isEmpty &&
      globalProxy;

  int get ruleCount =>
      directSites.length +
      directIp.length +
      blockSites.length +
      blockIp.length +
      proxySites.length +
      proxyIp.length;

  /// Reads the value of the header: a `happ://routing/onadd/...` link, the base64 text alone, or
  /// the JSON itself. Null when it holds no rules that can be read.
  static ProviderRouting? parse(String? raw) {
    var text = (raw ?? '').trim();
    if (text.isEmpty) return null;
    final slash = text.indexOf('://');
    if (slash > 0) {
      // happ://routing/onadd/<data> or happ://routing/add/<data>: the data is the last part
      text = text.substring(text.lastIndexOf('/') + 1);
      try {
        text = Uri.decodeComponent(text);
      } catch (_) {}
    }
    Object? json;
    if (text.startsWith('{')) {
      try {
        json = jsonDecode(text);
      } catch (_) {}
    } else {
      try {
        final clean = text.replaceAll('-', '+').replaceAll('_', '/').replaceAll(RegExp(r'\s'), '');
        json = jsonDecode(utf8.decode(base64.decode(base64.normalize(clean))));
      } catch (_) {}
    }
    return json is Map ? fromJson(json) : null;
  }

  static ProviderRouting? fromJson(Map json) {
    Object? get(String key) {
      for (final e in json.entries) {
        if ('${e.key}'.toLowerCase() == key.toLowerCase()) return e.value;
      }
      return null;
    }

    List<String> list(String key) {
      final v = get(key);
      return v is List
          ? [
              for (final e in v)
                if ('$e'.trim().isNotEmpty) '$e'.trim(),
            ]
          : const [];
    }

    final global = get('GlobalProxy');
    final order = {
      for (final p in '${get('RouteOrder') ?? ''}'.toLowerCase().split(RegExp(r'[-_,\s]+')))
        if (const {'block', 'proxy', 'direct'}.contains(p)) p,
    }.toList();
    for (final p in const ['block', 'proxy', 'direct']) {
      if (!order.contains(p)) order.add(p);
    }
    final r = ProviderRouting(
      name: '${get('Name') ?? ''}',
      globalProxy: global == null ? true : '$global'.toLowerCase() != 'false' && '$global' != '0',
      order: order,
      directSites: list('DirectSites'),
      directIp: list('DirectIp'),
      blockSites: list('BlockSites'),
      blockIp: list('BlockIp'),
      proxySites: list('ProxySites'),
      proxyIp: list('ProxyIp'),
    );
    return r.isEmpty && r.name.isEmpty ? null : r;
  }

  Map<String, dynamic> toJson() => {
        'Name': name,
        'GlobalProxy': globalProxy,
        'RouteOrder': order.join('-'),
        'DirectSites': directSites,
        'DirectIp': directIp,
        'BlockSites': blockSites,
        'BlockIp': blockIp,
        'ProxySites': proxySites,
        'ProxyIp': proxyIp,
      };

  /// The rule-set files these rules need (`geosite-category-ir`, `geoip-ir` ...), which are
  /// downloaded before connecting.
  List<String> get ruleSetTags {
    final tags = <String>{};
    for (final e in [
      ...directSites,
      ...directIp,
      ...blockSites,
      ...blockIp,
      ...proxySites,
      ...proxyIp,
    ]) {
      final tag = _tagOf(e);
      if (tag != null) tags.add(tag);
    }
    return tags.toList();
  }
}

/// `geosite:xxx` -> `geosite-xxx`, `geoip:xxx` -> `geoip-xxx`; null for anything else. The private
/// lists and entries with attributes (`geosite:xxx@cn`) have no rule-set file.
String? _tagOf(String entry) {
  final m = RegExp(r'^(geosite|geoip):([A-Za-z0-9_.!-]+)$', caseSensitive: false).firstMatch(entry);
  if (m == null) return null;
  final name = m[2]!.toLowerCase();
  if (name == 'private') return null;
  return '${m[1]!.toLowerCase()}-$name';
}

/// The sing-box rules made of a provider's routing, and the rule-sets they use.
class ProviderRules {
  const ProviderRules(this.route, this.dns, this.tags);

  /// Rules for `route.rules`, `dns.rules`, and the rule-set tags that are used.
  final List<Map<String, dynamic>> route;
  final List<Map<String, dynamic>> dns;
  final Set<String> tags;
}

bool _isAddress(String s) {
  final slash = s.indexOf('/');
  final ip = slash < 0 ? s : s.substring(0, slash);
  if (InternetAddress.tryParse(ip) == null) return false;
  if (slash < 0) return true;
  final bits = int.tryParse(s.substring(slash + 1));
  return bits != null && bits >= 0 && bits <= (ip.contains(':') ? 128 : 32);
}

/// Turns [r] into sing-box rules. [available] holds the rule-set tags whose files exist; the
/// ones that do not (a download failed) are left out. The categories are put in the provider's
/// order, so the first that matches wins.
ProviderRules providerRules(ProviderRouting r, Set<String> available) {
  final route = <Map<String, dynamic>>[];
  final dns = <Map<String, dynamic>>[];
  final used = <String>{};

  void category(String kind, List<String> sites, List<String> ips) {
    final action = switch (kind) {
      'block' => {'action': 'reject'},
      'proxy' => {'outbound': 'proxy'},
      _ => {'outbound': 'direct'},
    };
    final suffix = <String>[], full = <String>[], keyword = <String>[], regex = <String>[];
    final siteTags = <String>[];
    var private = false;
    for (final e in sites) {
      final lower = e.toLowerCase();
      final tag = _tagOf(e);
      if (lower == 'geosite:private') {
        private = true;
      } else if (tag != null) {
        if (available.contains(tag)) siteTags.add(tag);
      } else if (lower.startsWith('geosite:') || lower.startsWith('ext:')) {
        // a list this app has no file for
      } else if (lower.startsWith('domain:')) {
        suffix.add(e.substring(7).replaceFirst(RegExp(r'^\.'), ''));
      } else if (lower.startsWith('full:')) {
        full.add(e.substring(5));
      } else if (lower.startsWith('keyword:')) {
        keyword.add(e.substring(8));
      } else if (lower.startsWith('regexp:')) {
        regex.add(e.substring(7));
      } else if (lower.startsWith('regex:')) {
        regex.add(e.substring(6));
      } else if (_isAddress(e)) {
        // an address among the sites: handled with the addresses
        ips.add(e);
      } else if (e.contains('.')) {
        suffix.add(e.replaceFirst(RegExp(r'^\.'), ''));
      } else {
        keyword.add(e);
      }
    }
    final cidr = <String>[], ipTags = <String>[];
    for (final e in ips) {
      final lower = e.toLowerCase();
      final tag = _tagOf(e);
      if (lower == 'geoip:private') {
        private = true;
      } else if (tag != null) {
        if (available.contains(tag)) ipTags.add(tag);
      } else if (_isAddress(e)) {
        cidr.add(e);
      }
    }

    void add(Map<String, dynamic> match) => route.add({...match, ...action});
    if (suffix.isNotEmpty) add({'domain_suffix': suffix});
    if (full.isNotEmpty) add({'domain': full});
    if (keyword.isNotEmpty) add({'domain_keyword': keyword});
    if (regex.isNotEmpty) add({'domain_regex': regex});
    if (siteTags.isNotEmpty) {
      add({'rule_set': siteTags});
      used.addAll(siteTags);
    }
    if (cidr.isNotEmpty) add({'ip_cidr': cidr});
    if (ipTags.isNotEmpty) {
      add({'rule_set': ipTags});
      used.addAll(ipTags);
    }
    if (private) add({'ip_is_private': true});

    // Names: blocked ones fail at once, direct ones are looked up locally (not through the VPN).
    final dnsAction = kind == 'block'
        ? {'action': 'reject'}
        : kind == 'direct'
            ? {'server': 'dns-local'}
            : null;
    if (dnsAction != null) {
      void addDns(Map<String, dynamic> match) => dns.add({...match, ...dnsAction});
      if (suffix.isNotEmpty) addDns({'domain_suffix': suffix});
      if (full.isNotEmpty) addDns({'domain': full});
      if (keyword.isNotEmpty) addDns({'domain_keyword': keyword});
      if (regex.isNotEmpty) addDns({'domain_regex': regex});
      if (siteTags.isNotEmpty) addDns({'rule_set': siteTags});
    }
  }

  for (final kind in r.order) {
    switch (kind) {
      case 'block':
        category('block', List.of(r.blockSites), List.of(r.blockIp));
      case 'proxy':
        category('proxy', List.of(r.proxySites), List.of(r.proxyIp));
      case 'direct':
        category('direct', List.of(r.directSites), List.of(r.directIp));
    }
  }
  return ProviderRules(route, dns, used);
}
