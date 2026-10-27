import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/proxy_config.dart';
import 'package:kumo/core/provider_routing.dart';
import 'package:kumo/core/singbox_config.dart';
import 'package:kumo/core/sources.dart';

const _json = {
  'Name': 'Iran Bypass',
  'GlobalProxy': 'true',
  'RouteOrder': 'block-proxy-direct',
  'DirectSites': ['geosite:private', 'domain:ir', 'geosite:category-ir'],
  'DirectIp': ['geoip:ir', 'geoip:private', '127.0.0.0/8', '10.0.0.0/8'],
  'BlockSites': ['geosite:category-ads-all'],
  'BlockIp': [],
  'ProxySites': [],
  'ProxyIp': [],
  'DomainStrategy': 'IPIfNonMatch',
};

String get _header => 'happ://routing/onadd/${base64.encode(utf8.encode(jsonEncode(_json)))}';

void main() {
  test('the routing header is read from a link, base64 or JSON', () {
    for (final raw in [_header, _header.split('/').last, jsonEncode(_json)]) {
      final r = ProviderRouting.parse(raw)!;
      expect(r.name, 'Iran Bypass');
      expect(r.globalProxy, true);
      expect(r.order, ['block', 'proxy', 'direct']);
      expect(r.directSites, contains('domain:ir'));
      expect(r.blockSites, ['geosite:category-ads-all']);
    }
    expect(ProviderRouting.parse(''), isNull);
    expect(ProviderRouting.parse('happ://routing/onadd/%%%'), isNull);
    expect(ProviderRouting.parse(null), isNull);
  });

  test('rule-set files are asked for the lists, not for private ones', () {
    final r = ProviderRouting.parse(_header)!;
    expect(r.ruleSetTags,
        unorderedEquals(['geosite-category-ir', 'geoip-ir', 'geosite-category-ads-all']));
  });

  test('rules follow the provider order and skip lists that are not there', () {
    final r = ProviderRouting.parse(_header)!;
    final full = providerRules(r, r.ruleSetTags.toSet());
    expect(full.route.first['action'], 'reject');
    expect(full.route.first['rule_set'], ['geosite-category-ads-all']);
    final direct = full.route.where((e) => e['outbound'] == 'direct').toList();
    expect(direct.any((e) => e['domain_suffix'] != null), true);
    expect(direct.any((e) => e['ip_cidr'] != null), true);
    expect(direct.any((e) => e['ip_is_private'] == true), true);
    expect(full.dns.any((e) => e['action'] == 'reject'), true);
    expect(full.dns.any((e) => e['server'] == 'dns-local'), true);

    final none = providerRules(r, <String>{});
    expect(none.tags, isEmpty);
    expect(none.route.any((e) => e['rule_set'] != null), false);
    expect(none.route.any((e) => e['domain_suffix'] != null), true);
  });

  test('the config uses the rules and sends the rest direct when asked', () {
    final servers = parseLinks(['trojan://p@h1.example.com:443#a']);
    final r = ProviderRouting.parse(_header)!;
    final cfg = jsonDecode(buildSingBoxConfig(servers, routing: r)) as Map<String, dynamic>;
    final rules = (cfg['route']['rules'] as List).cast<Map>();
    expect(rules.any((e) => e['domain_suffix'] is List && (e['domain_suffix'] as List).contains('ir')), true);
    expect(cfg['route']['final'], 'proxy');

    final direct = ProviderRouting.fromJson({..._json, 'GlobalProxy': 'false'})!;
    final cfg2 = jsonDecode(buildSingBoxConfig(servers, routing: direct)) as Map<String, dynamic>;
    expect(cfg2['route']['final'], 'direct');

    final plain = jsonDecode(buildSingBoxConfig(servers)) as Map<String, dynamic>;
    expect(plain['route']['final'], 'proxy');
  });

  test('the provider headers are read, with the interval kept per subscription', () {
    final headers = {
      'profile-update-interval': '1',
      'routing': _header,
      'routing-enable': 'false',
      'support-url': 'https://t.me/support',
      'announce': 'base64:${base64.encode(utf8.encode('Hello'))}',
    };
    final m = ProviderMeta.fromHeaders((n) => headers[n]);
    expect(m.intervalHours, 1);
    expect(m.routingEnabled, false);
    expect(m.supportUrl, 'https://t.me/support');
    expect(m.announce, 'Hello');
    expect(ProviderRouting.parse(m.routing)!.name, 'Iran Bypass');

    final none = ProviderMeta.fromHeaders((_) => null);
    expect(none.intervalHours, isNull);
    expect(none.routingEnabled, true);
  });

  test('upload and download are kept apart', () {
    final f = Fetched.fromHeaders('', null, null, 'upload=100; download=300; total=1000; expire=0');
    expect(f.info!.upload, 100);
    expect(f.info!.download, 300);
    expect(f.info!.used, 400);
  });
}
