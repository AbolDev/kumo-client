import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/ad_lists.dart';
import 'package:kumo/core/net_options.dart';
import 'package:kumo/core/proxy_config.dart';
import 'package:kumo/core/rule_sets.dart';
import 'package:kumo/core/singbox_config.dart';
import 'package:kumo/core/stun.dart';

Map<String, dynamic> build(NetOptions o, {Map<String, String> sets = const {}}) =>
    jsonDecode(buildSingBoxConfig(
      [parseLink('trojan://pw@example.com:443?security=tls#t')!],
      options: o,
      ruleSets: sets,
      apiPort: 9999,
      apiSecret: 's',
      windows: false,
    )) as Map<String, dynamic>;

void main() {
  test('privacy options are off by default and survive a save', () {
    final o = NetOptions();
    expect(o.blockAds, isFalse);
    expect(o.strictDns, isFalse);
    expect(o.blockStun, isFalse);
    o
      ..blockAds = true
      ..strictDns = true
      ..blockStun = true;
    final back = NetOptions()..load(o.toJson());
    expect(back.blockAds && back.strictDns && back.blockStun, isTrue);
  });

  test('ad blocking rejects the built-in names even with no list, and the lists when they exist', () {
    final o = NetOptions()..blockAds = true;
    const tag = 'ads-hagezi-pro';
    final c = build(o, sets: {tag: '/tmp/ads.json', 'ads-category-ads-all': '/tmp/a.srs'});
    final route = c['route'] as Map<String, dynamic>;
    final defs = (route['rule_set'] as List).cast<Map>();
    expect(defs.firstWhere((d) => d['tag'] == tag)['format'], 'source');
    expect(defs.firstWhere((d) => d['tag'] == 'ads-category-ads-all')['format'], 'binary');
    final rules = (route['rules'] as List).cast<Map>();
    expect(rules.any((r) => r['action'] == 'reject' && (r['rule_set'] as List?)?.contains(tag) == true), isTrue);
    final dns = ((c['dns'] as Map)['rules'] as List).cast<Map>();
    expect(dns.any((r) => r['action'] == 'predefined' && r['rcode'] == 'NXDOMAIN'), isTrue);
    // no list downloaded: the built-in names are still refused, and nothing refers to a missing list
    final none = build(o);
    expect((none['route'] as Map).containsKey('rule_set'), isFalse);
    final builtIn = ((none['route'] as Map)['rules'] as List)
        .cast<Map>()
        .firstWhere((r) => r['action'] == 'reject' && r['domain_suffix'] != null);
    expect(builtIn['domain_suffix'], contains('doubleclick.net'));
    // off: none of it
    final off = build(NetOptions());
    expect((off['route']['rules'] as List).any((r) => r['domain_suffix'] != null && r['action'] == 'reject'), isFalse);
  });

  test('the strong level also refuses public encrypted-DNS servers, the standard one does not', () {
    bool refuses(NetOptions o) => (build(o)['route']['rules'] as List)
        .any((r) => r['action'] == 'reject' && (r['domain_suffix'] as List?)?.contains('dns.google') == true);
    expect(refuses(NetOptions()..blockAds = true..adsLevel = 'strong'), isTrue);
    expect(refuses(NetOptions()..blockAds = true..adsLevel = 'standard'), isFalse);
  });

  test('a list of domains becomes a rule-set, and a cut-off one is refused', () {
    final text = ['# a list', for (var i = 0; i < 1200; i++) '*.ads$i.example.com', 'bad entry', ''].join('\n');
    final json = jsonDecode(domainListToRuleSet(text)!) as Map;
    final suffixes = ((json['rules'] as List).single['domain_suffix'] as List);
    expect(json['version'], 3);
    expect(suffixes.length, 1200);
    expect(suffixes.first, 'ads0.example.com');
    expect(domainListToRuleSet('a.com\nb.com'), isNull);
  });
  test('strict DNS resolves names over encrypted DNS and refuses DNS over TLS', () {
    final c = build(NetOptions()..strictDns = true..blockStun = true);
    final servers = (c['dns'] as Map)['servers'] as List;
    expect(servers.any((s) => s['tag'] == 'dns-boot' && s['type'] == 'https'), isTrue);
    final route = c['route'] as Map<String, dynamic>;
    expect(route['default_domain_resolver'], 'dns-boot');
    final rules = route['rules'] as List;
    expect(rules.any((r) => r['port'] == 853 && r['action'] == 'reject'), isTrue);
    expect(rules.any((r) => r['protocol'] == 'stun' && r['action'] == 'reject'), isTrue);
  });

  test('the STUN answer is read', () {
    final id = Uint8List.fromList(List.generate(12, (i) => i + 1));
    // XOR-MAPPED-ADDRESS for 203.0.113.9:4000
    const cookie = [0x21, 0x12, 0xA4, 0x42];
    final ip = [203, 0, 113, 9];
    final data = Uint8List.fromList([
      0x01, 0x01, 0x00, 0x0C, 0x21, 0x12, 0xA4, 0x42, ...id,
      0x00, 0x20, 0x00, 0x08, 0x00, 0x01, 0x00, 0x00,
      for (var i = 0; i < 4; i++) ip[i] ^ cookie[i],
    ]);
    expect(parseStunResponse(data, id), '203.0.113.9');
    expect(parseStunResponse(Uint8List(5), id), isNull);
  });
}
