import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/ad_lists.dart';
import 'package:kumo/core/net_options.dart';
import 'package:kumo/core/proxy_config.dart';
import 'package:kumo/core/rule_sets.dart';
import 'package:kumo/core/singbox_config.dart';

ProxyConfig server() => ProxyConfig(
      link: 'vless://u@h.example.com:443',
      protocol: 'vless',
      name: 'n',
      host: 'h.example.com',
      port: 443,
      outbound: const {'type': 'vless', 'server': 'h.example.com', 'server_port': 443},
    );

Map<String, dynamic> config(NetOptions o, {Map<String, String> sets = const {}}) =>
    jsonDecode(buildSingBoxConfig([server()], options: o, ruleSets: sets)) as Map<String, dynamic>;

List<Map<String, dynamic>> routeRules(Map<String, dynamic> c) =>
    ((c['route'] as Map)['rules'] as List).cast<Map<String, dynamic>>();

List<Map<String, dynamic>> dnsRules(Map<String, dynamic> c) =>
    (((c['dns'] as Map)['rules'] ?? const []) as List).cast<Map<String, dynamic>>();

void main() {
  group('reading block lists', () {
    test('plain, wildcard, hosts and ad-block lines; exceptions and rules with paths', () {
      final p = parseBlocklist('''
[Adblock Plus]
! a comment
# another
ads.example.com
*.track.example.net
.pixel.example.org
0.0.0.0 hosts.example.com
127.0.0.1 hosts2.example.com
0.0.0.0 localhost
||abp.example.com^
||important.example.com^\$important
||third.example.com^\$third-party
@@||good.example.com^
||path.example.com/ads^
example.com/path
UPPER.Example.COM
nodot
''');
      expect(p.block, containsAll([
        'ads.example.com', 'track.example.net', 'pixel.example.org', 'hosts.example.com',
        'hosts2.example.com', 'abp.example.com', 'important.example.com', 'upper.example.com',
      ]));
      expect(p.block.contains('third.example.com'), isFalse);
      expect(p.block.contains('localhost'), isFalse);
      expect(p.block.contains('nodot'), isFalse);
      expect(p.block.any((d) => d.contains('/')), isFalse);
      expect(p.allow, {'good.example.com'});
    });

    test('merged lists: what any blocks, less what any allows', () {
      final m = mergeBlocklists(['a.com\nb.com\nc.com', '||c.com^\n@@||b.com^\nd.com']);
      expect(m, {'a.com', 'c.com', 'd.com'});
    });

    test('a list too short is no list; a rule-set is the domains under domain_suffix', () {
      expect(domainListToRuleSet('a.com\nb.com'), isNull);
      final rs = jsonDecode(domainListToRuleSet('a.com\nb.com', min: 2)!) as Map;
      expect(((rs['rules'] as List).single as Map)['domain_suffix'], containsAll(['a.com', 'b.com']));
    });

    test('names apps need are taken out of every list', () {
      final m = mergeBlocklists([
        'graph.facebook.com\nx.graph.facebook.com\nfacebook-graph.com\nads.example.com\nus1.list-manage.com',
      ]);
      expect(m, {'facebook-graph.com', 'ads.example.com'});
      final rs = domainListToRuleSet('youtubei.googleapis.com\na.com\nb.com', min: 2)!;
      expect(rs.contains('youtubei'), isFalse);
      // None of them is in the built-in lists either.
      for (final n in adNeverBlock) {
        expect(builtInAdDomains.any((d) => d == n || n.endsWith('.$d') || d.endsWith('.$n')), isFalse, reason: n);
      }
    });

    test('the never-block list is cleaned', () {
      expect(cleanAllowList(['  *.Example.com ', '.foo.org', 'https://bar.net/x', 'nodot', 'bad name.com', 'a.b.c']),
          ['example.com', 'foo.org', 'bar.net', 'a.b.c']);
      expect(cleanAllowList(List.generate(600, (i) => 's$i.example.com')), hasLength(500));
    });

    test('the levels and their lists', () {
      expect(adLevels, ['standard', 'strong', 'max']);
      expect(adSources('standard').map((s) => s.tag), contains('${adTagPrefix}hagezi-light'));
      expect(adSources('strong').map((s) => s.tag), contains('${adTagPrefix}hagezi-pro'));
      // At the max level the big lists are one merged rule-set instead.
      expect(adSources('max').any((s) => s.tag.contains('hagezi')), isFalse);
      expect(maxTextSources.map((s) => s.name), containsAll(['hagezi-ultimate', 'oisd-big', 'adguard-dns', 'persianblocker']));
      for (final s in maxTextSources) {
        expect(s.urls, isNotEmpty);
        expect(s.urls.every((u) => u.startsWith('https://')), isTrue);
      }
      expect(mainAdTag('standard'), '${adTagPrefix}hagezi-light');
      expect(mainAdTag('max'), adMaxTag);
    });
  });

  group('the rules in the configuration', () {
    test('ad rules without exceptions are plain', () {
      final o = NetOptions()..blockAds = true;
      final rules = routeRules(config(o, sets: {'${adTagPrefix}base': '/x/ads-base.json'}));
      expect(rules.where((r) => r['rule_set'] != null && (r['rule_set'] as List).contains('${adTagPrefix}base')), hasLength(1));
      expect(rules.any((r) => r['type'] == 'logical'), isFalse);
    });

    test('names never to block are left out of every ad rule, in the routes and in DNS', () {
      final o = NetOptions()
        ..blockAds = true
        ..adAllow = ['good.example.com'];
      final c = config(o, sets: {'${adTagPrefix}base': '/x/ads-base.json'});
      final logical = routeRules(c).where((r) => r['type'] == 'logical').toList();
      expect(logical, isNotEmpty);
      for (final r in logical) {
        expect(r['mode'], 'and');
        final inner = (r['rules'] as List).cast<Map>();
        expect(inner.last['domain_suffix'], ['good.example.com']);
        expect(inner.last['invert'], isTrue);
        expect(r['action'], 'reject');
      }
      final dns = dnsRules(c).where((r) => r['type'] == 'logical').toList();
      expect(dns, isNotEmpty);
      expect(dns.every((r) => r['action'] == 'predefined' && r['rcode'] == 'NXDOMAIN'), isTrue);
    });

    test('encrypted DNS by address is refused on its ports at the strong and max levels only', () {
      Map<String, dynamic>? ipRule(String level) => routeRules(config(NetOptions()
                ..blockAds = true
                ..adsLevel = level))
          .where((r) => r['ip_cidr'] != null && (r['ip_cidr'] as List).contains('1.1.1.1/32'))
          .firstOrNull;
      expect(ipRule('standard'), isNull);
      for (final level in ['strong', 'max']) {
        final r = ipRule(level)!;
        expect(r['port'], [443, 853]);
        expect(r['action'], 'reject');
      }
      expect(ipRule('strong')!['ip_cidr'], containsAll(['8.8.8.8/32', '2606:4700:4700::1111/128']));
    });

    test('cookie banners and affiliate links are blocked only when asked for', () {
      List<String> blocked(NetOptions o) => [
            for (final r in routeRules(config(o)))
              if (r['action'] == 'reject' && r['domain_suffix'] is List) ...(r['domain_suffix'] as List).cast<String>(),
          ];
      final plain = NetOptions()..blockAds = true;
      expect(blocked(plain), contains('doubleverify.com'));
      expect(blocked(plain).contains('cookiebot.com'), isFalse);
      expect(blocked(plain).contains('shareasale.com'), isFalse);
      final more = NetOptions()
        ..blockAds = true
        ..blockCookieBanners = true
        ..blockAffiliate = true;
      expect(blocked(more), containsAll(['cookiebot.com', 'cdn.cookielaw.org', 'shareasale.com', 'awin1.com']));
      // Nothing of it without ad blocking.
      final off = NetOptions()
        ..blockCookieBanners = true
        ..blockAffiliate = true;
      expect(blocked(off), isEmpty);
    });

    test('the options are saved and read back', () {
      final o = NetOptions()
        ..adsLevel = 'max'
        ..adAllow = ['a.example.com']
        ..blockCookieBanners = true
        ..blockAffiliate = true;
      final back = NetOptions()..load(o.toJson());
      expect(back.adsLevel, 'max');
      expect(back.adAllow, ['a.example.com']);
      expect(back.blockCookieBanners && back.blockAffiliate, isTrue);
      expect((NetOptions()..load({'adsLevel': 'nonsense', 'adAllow': 5})).adsLevel, defaultAdLevel);
    });
  });

  group('the lists on disk', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('kumo_ads_'));
    tearDown(() async => dir.delete(recursive: true));

    test('without the downloaded list, the built-in one stands in (and is made once)', () async {
      var loads = 0;
      Future<String> base() async {
        loads++;
        return List.generate(50, (i) => 'ad$i.example.com').join('\n');
      }

      final found = await ensureRuleSets(dir.path, const [], ads: true, wait: false, loadBase: base);
      expect(found.keys, contains(adBaseTag));
      final file = File(found[adBaseTag]!);
      expect(await file.exists(), isTrue);
      final rs = jsonDecode(await file.readAsString()) as Map;
      expect(((rs['rules'] as List).single as Map)['domain_suffix'], hasLength(50));
      final status = await adsStatus(dir.path, defaultAdLevel);
      expect(status.baseOnly, isTrue);
      expect(status.domains, 50);
      expect(status.lists, 0);
      // The same built-in list: not rebuilt.
      final before = await file.lastModified();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await ensureRuleSets(dir.path, const [], ads: true, wait: false, loadBase: base);
      expect(await file.lastModified(), before);
      expect(loads, 2);
    });

    test('with the main list there, the built-in one is not used', () async {
      final main = File('${dir.path}/rules/${mainAdTag(defaultAdLevel)}.json');
      await main.parent.create(recursive: true);
      await main.writeAsString(ruleSetOf(['x.example.com']));
      await File('${main.path}.count').writeAsString('1');
      final found = await ensureRuleSets(dir.path, const [], ads: true, wait: false, loadBase: () async => 'a.example.com');
      expect(found.keys, contains(mainAdTag(defaultAdLevel)));
      expect(found.keys.contains(adBaseTag), isFalse);
      final status = await adsStatus(dir.path, defaultAdLevel);
      expect(status.baseOnly, isFalse);
      expect(status.lists, 1);
      expect(status.domains, 1);
      expect(status.updated, isNotNull);
    });

    test('a connection never waits for a download: old lists are used, refreshed later', () async {
      // An old list (made long ago) of the level is there.
      final main = File('${dir.path}/rules/${mainAdTag(defaultAdLevel)}.json');
      await main.parent.create(recursive: true);
      await main.writeAsString(ruleSetOf(['x.example.com']));
      await File('${main.path}.count').writeAsString('1');
      await main.setLastModified(DateTime(2020));
      final sw = Stopwatch()..start();
      final found = await ensureRuleSets(dir.path, const [], ads: true, wait: false, refresh: false);
      expect(found.keys, contains(mainAdTag(defaultAdLevel)));
      expect(await main.lastModified(), DateTime(2020)); // not fetched again
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('the country lists the app carries are copied in, dated old so that they are refreshed', () async {
      final srs = Uint8List.fromList([0x53, 0x52, 0x53, 1, 2, 3, 4, 5]);
      final asked = <String>[];
      final found = await ensureRuleSets(dir.path, const ['ir'], wait: false, refresh: false, loadBundled: (tag) async {
        asked.add(tag);
        return tag == 'geoip-ir' ? srs : null;
      });
      expect(asked, containsAll(['geoip-ir', 'geosite-ir', 'geosite-ir-extra']));
      expect(found.keys, ['geoip-ir']);
      final f = File(found['geoip-ir']!);
      expect(await f.readAsBytes(), srs);
      expect((await f.lastModified()).isBefore(DateTime(2021)), isTrue);
      // Something that is not a rule-set is not copied.
      final again = await ensureRuleSets(dir.path, const ['cn'], wait: false, refresh: false,
          loadBundled: (tag) async => Uint8List.fromList(utf8.encode('<html>')));
      expect(again, isEmpty);
    });

    test('the bundled country lists are real rule-sets, and cover every country of the list', () {
      for (final c in bypassCountries.keys) {
        final f = File('assets/rules/geoip-$c.srs');
        expect(f.existsSync(), isTrue, reason: c);
        expect(f.readAsBytesSync().take(3), [0x53, 0x52, 0x53], reason: c);
      }
      expect(File('assets/rules/geosite-ir-extra.srs').existsSync(), isTrue);
    });

    test('JSON lists get a binary copy, which is used while it is current', () async {
      final json = File('${dir.path}/rules/${adTagPrefix}hagezi-pro.json');
      await json.parent.create(recursive: true);
      await json.writeAsString(ruleSetOf(['x.example.com']));
      await File('${json.path}.count').writeAsString('1');
      final made = <String>[];
      Future<bool> compile(String source, String output) async {
        made.add(source);
        await File(output).writeAsBytes([0x53, 0x52, 0x53, 9]);
        return true;
      }

      expect(await compileRuleSets(dir.path, compile), 1);
      expect(await compileRuleSets(dir.path, compile), 0); // current: not made again
      var found = await ensureRuleSets(dir.path, const [], ads: true, adsLevel: 'strong', wait: false, refresh: false);
      expect(found['${adTagPrefix}hagezi-pro'], endsWith('${adTagPrefix}hagezi-pro.bin.srs'));
      // A newer list: the old copy is not used, and a new one is made.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await json.writeAsString(ruleSetOf(['y.example.com']));
      await json.setLastModified(DateTime.now().add(const Duration(seconds: 5)));
      found = await ensureRuleSets(dir.path, const [], ads: true, adsLevel: 'strong', wait: false, refresh: false);
      expect(found['${adTagPrefix}hagezi-pro'], endsWith('.json'));
      // A compiler that fails leaves nothing behind.
      expect(await compileRuleSets(dir.path, (s, o) async => false), 0);
      expect(File('${dir.path}/rules/${adTagPrefix}hagezi-pro.bin.srs').existsSync(), isFalse);
    });

    test('nothing yet and no built-in list: an empty status', () async {
      final status = await adsStatus(dir.path, 'max');
      expect(status.lists, 0);
      expect(status.baseOnly, isFalse);
      expect(status.updated, isNull);
      expect(status.expected, adSources('max').length + 1);
    });
  });

  test('the built-in list is in the app and big enough', () {
    final text = File(adBaseAsset).readAsStringSync();
    expect(parseBlocklist(text).block.length, greaterThan(50000));
  });
}
