import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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

  test('ad blocking adds a reject rule and the rule-set when the list exists', () {
    final o = NetOptions()..blockAds = true;
    final c = build(o, sets: {adsTag: '/tmp/ads.srs'});
    final route = c['route'] as Map<String, dynamic>;
    expect((route['rule_set'] as List).single['tag'], adsTag);
    expect(
        (route['rules'] as List).any((r) => r['action'] == 'reject' && (r['rule_set'] as List?)?.first == adsTag),
        isTrue);
    // no list downloaded: nothing refers to it
    final none = build(o);
    expect((none['route'] as Map).containsKey('rule_set'), isFalse);
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
