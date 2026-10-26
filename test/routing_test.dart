import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/net_options.dart';
import 'package:kumo/core/proxy_config.dart';
import 'package:kumo/core/routing_rules.dart';
import 'package:kumo/core/singbox_config.dart';
import 'package:kumo/core/sources.dart';
import 'package:kumo/core/usage_alert.dart';

void main() {
  test('routing rules accept domains, links and addresses', () {
    expect(parseRouteRule('Example.COM')!.value, 'example.com');
    expect(parseRouteRule('https://www.Test.com:8443/a/b?c=d')!.value, 'www.test.com');
    expect(parseRouteRule('*.example.ir')!.value, 'example.ir');
    expect(parseRouteRule('10.0.0.0/8')!.ip, true);
    expect(parseRouteRule('8.8.8.8')!.value, '8.8.8.8/32');
    expect(parseRouteRule('2001:db8::1')!.value, '2001:db8::1/128');
    expect(parseRouteRule('localhost')!.ip, false);
    expect(parseRouteRule('300.1.1.1'), isNull);
    expect(parseRouteRule('10.0.0.0/40'), isNull);
    expect(parseRouteRule('not a domain'), isNull);
    expect(parseRouteRule(''), isNull);
  });

  test('manual rules and LAN sharing reach the sing-box config', () {
    final servers = parseLinks(['trojan://p@h1.example.com:443#a']);
    final o = NetOptions()
      ..directRules = ['example.ir', '10.0.0.0/8']
      ..proxyRules = ['openai.com']
      ..shareLan = true
      ..lanPassword = 'secret123';
    final cfg = jsonDecode(buildSingBoxConfig(servers, options: o)) as Map<String, dynamic>;
    final rules = (cfg['route']['rules'] as List).cast<Map>();
    // The user's rules come before the private-address rule and the country rules.
    final iProxy = rules.indexWhere((r) => r['outbound'] == 'proxy' && r['domain_suffix'] != null);
    final iDirect = rules.indexWhere((r) => r['domain_suffix'] != null && r['outbound'] == 'direct');
    final iPrivate = rules.indexWhere((r) => r['ip_is_private'] == true);
    expect(rules[iProxy]['domain_suffix'], ['openai.com']);
    expect(rules[iDirect]['domain_suffix'], ['example.ir']);
    expect(rules.firstWhere((r) => r['ip_cidr'] != null)['ip_cidr'], ['10.0.0.0/8']);
    expect(iProxy < iPrivate && iDirect < iPrivate, true);
    // A direct domain is also looked up locally.
    final dnsRules = (cfg['dns']['rules'] as List).cast<Map>();
    expect(dnsRules.first['domain_suffix'], ['example.ir']);
    expect(dnsRules.first['server'], 'dns-local');
    // The shared proxy has a login and listens on all addresses; the local one stays open.
    final inbounds = (cfg['inbounds'] as List).cast<Map>();
    final lan = inbounds.firstWhere((i) => i['tag'] == 'lan-in');
    expect(lan['listen'], '0.0.0.0');
    expect((lan['users'] as List).single['password'], 'secret123');
    expect(inbounds.firstWhere((i) => i['tag'] == 'mixed-in')['listen'], '127.0.0.1');
  });

  test('sharing needs a password and a port of its own', () {
    final servers = parseLinks(['trojan://p@h1.example.com:443#a']);
    List tags(NetOptions o) =>
        (jsonDecode(buildSingBoxConfig(servers, options: o))['inbounds'] as List)
            .map((i) => i['tag'])
            .toList();
    expect(tags(NetOptions()..shareLan = true), ['mixed-in']);
    expect(
        tags(NetOptions()
          ..shareLan = true
          ..lanPassword = 'x'
          ..lanPort = 2080),
        ['mixed-in']);
    final saved = NetOptions()
      ..directRules = ['a.com']
      ..shareLan = true
      ..lanPassword = 'pw';
    final back = NetOptions()..load(saved.toJson());
    expect(back.directRules, ['a.com']);
    expect(back.shareLan, true);
    expect(back.lanPassword, 'pw');
    expect(NetOptions()..load({'directRules': ['not valid!', 'ok.com']}), isA<NetOptions>());
  });

  test('usage alert levels', () {
    final now = DateTime(2026, 10, 26, 12);
    int secs(Duration d) => now.add(d).millisecondsSinceEpoch ~/ 1000;
    expect(usageLevels(const SubInfo(used: 50, total: 100), now: now).data, 0);
    expect(usageLevels(const SubInfo(used: 91, total: 100), now: now).data, 1);
    expect(usageLevels(const SubInfo(used: 100, total: 100), now: now).data, 2);
    expect(usageLevels(const SubInfo(used: 5), now: now).data, 0); // unlimited
    expect(usageLevels(SubInfo(expire: secs(const Duration(days: 10))), now: now).expiry, 0);
    expect(usageLevels(SubInfo(expire: secs(const Duration(days: 2))), now: now).expiry, 1);
    expect(usageLevels(SubInfo(expire: secs(const Duration(hours: 5))), now: now).expiry, 2);
    expect(usageLevels(SubInfo(expire: secs(const Duration(hours: -1))), now: now).expiry, 3);
    expect(const UsageLevels(1, 2).code, '12');
    expect(daysLeft(SubInfo(expire: secs(const Duration(days: 2, hours: 3))), now: now), 3);
  });
}
