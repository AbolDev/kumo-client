import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/anti_filter_tuner.dart';
import 'package:kumo/core/latency_tester.dart' show delayConfigForTest;
import 'package:kumo/core/net_options.dart';
import 'package:kumo/core/proxy_config.dart';
import 'package:kumo/core/singbox_config.dart';
import 'package:kumo/core/warp/warp_scan.dart';

ProxyConfig tlsServer(String name, {int? ms, String type = 'vless', bool tls = true, bool xray = false}) =>
    ProxyConfig(
      link: '$type://$name',
      protocol: type,
      name: name,
      host: '$name.example.com',
      port: 443,
      outbound: xray
          ? const {}
          : {
              'type': type,
              'server': '$name.example.com',
              'server_port': 443,
              if (tls) 'tls': {'enabled': true, 'server_name': '$name.example.com'},
            },
      xrayOutbound: xray ? const {'protocol': 'vless'} : null,
    )..latencyMs = ms;

Map<String, dynamic> wg(String address) => {
      'type': 'wireguard',
      'address': ['172.16.0.2/32'],
      'private_key': 'k',
      'peers': [
        {'address': address, 'port': 2408, 'public_key': 'p', 'allowed_ips': ['0.0.0.0/0']}
      ],
    };

void main() {
  group('the tuner', () {
    test('it tries every option on every server, each from a copy of the user\'s options', () async {
      final base = NetOptions()..mux = false;
      final seen = <String>[];
      final servers = [tlsServer('a', ms: 50), tlsServer('b', ms: 80)];
      final scores = await runTuner(
        servers: servers,
        base: base,
        delay: (s, o) async {
          seen.add('${s.name}:${o.tlsFragment}:${o.fingerprint}:${o.mux}');
          return 100;
        },
      );
      expect(scores, hasLength(tuneVariants.length));
      expect(seen, hasLength(tuneVariants.length * 2));
      expect(seen, contains('a:true:chrome:false')); // fragment + chrome
      expect(seen, contains('b:false::true')); // mux
      expect(base.tlsFragment, isFalse); // the user's own options are not touched
      expect(base.fingerprint, '');
      expect(scores.first.variant.id, 'current');
      expect(scores.every((s) => s.ok == 2 && s.total == 2 && s.medianMs == 100), isTrue);
    });

    test('progress is reported and a cancel stops it', () async {
      final done = <int>[];
      var calls = 0;
      await runTuner(
        servers: [tlsServer('a')],
        base: NetOptions(),
        delay: (s, o) async => ++calls,
        onProgress: (d, t) => done.add(d),
        cancelled: () => calls >= 3,
        parallel: 1,
      );
      expect(calls, 3);
      expect(done, [1, 2, 3]);
    });

    test('a thrown error and a skipped test are not answers', () async {
      var n = 0;
      final scores = await runTuner(
        servers: [tlsServer('a')],
        base: NetOptions(),
        variants: [tuneVariants[0], tuneVariants[1], tuneVariants[2]],
        parallel: 1,
        delay: (s, o) async {
          n++;
          if (n == 1) throw StateError('boom');
          if (n == 2) return -2;
          return 120;
        },
      );
      expect(scores[0].ok, 0);
      expect(scores[0].total, 1);
      expect(scores[1].total, 0); // skipped: counted as no test at all
      expect(scores[2].ok, 1);
    });

    test('the verdicts', () {
      TuneScore score(int i, int ok, int? ms) => TuneScore(tuneVariants[i], ok, 3, ms);
      expect(recommend(const []).verdict, TuneVerdict.nothingWorks);
      expect(recommend([score(0, 0, null), score(1, 0, null)]).verdict, TuneVerdict.nothingWorks);
      // The user's own settings are as good as any.
      expect(recommend([score(0, 3, 200), score(1, 3, 190), score(2, 2, 100)]).verdict, TuneVerdict.currentIsBest);
      // More servers answer with another option.
      final more = recommend([score(0, 1, 300), score(1, 3, 400), score(2, 2, 100)]);
      expect(more.verdict, TuneVerdict.better);
      expect(more.best!.variant.id, 'fragment');
      // The same servers, clearly faster.
      final faster = recommend([score(0, 3, 600), score(3, 3, 300)]);
      expect(faster.verdict, TuneVerdict.better);
      expect(faster.best!.variant.id, 'chrome');
      // A small difference is not worth a change.
      expect(recommend([score(0, 3, 300), score(3, 3, 280)]).verdict, TuneVerdict.currentIsBest);
    });

    test('the servers it tries: TLS over TCP in sing-box, the chosen one first, then the fastest', () {
      final chosen = tlsServer('chosen', ms: 900);
      final all = [
        tlsServer('slow', ms: 700),
        tlsServer('fast', ms: 40),
        tlsServer('dead', ms: -1),
        tlsServer('plain', ms: 10, tls: false),
        tlsServer('needsxray', xray: true),
        tlsServer('ss', ms: 5, type: 'shadowsocks'),
        chosen,
        tlsServer('mid', ms: 300),
      ];
      expect(tuneServers(all, chosen).map((c) => c.name), ['chosen', 'fast', 'mid']);
      expect(tuneServers(all, null).map((c) => c.name), ['fast', 'mid', 'slow']);
      expect(tuneServers(all, null, max: 1), hasLength(1));
      expect(tuneServers([tlsServer('plain', ms: 10, tls: false)], null), isEmpty);
    });

    test('options of a test are put on the server the way a connection puts them', () {
      final o = NetOptions()
        ..tlsFragment = true
        ..fingerprint = 'chrome';
      final layers = tweakLayers([tlsServer('a').outbound], o);
      final tls = layers.first['tls'] as Map;
      expect(tls['fragment'], true);
      expect((tls['utls'] as Map)['fingerprint'], 'chrome');
      expect(copyOptions(o).tlsFragment, isTrue);
      expect(identical(copyOptions(o), o), isFalse);
    });
  });

  group('the scan of WARP', () {
    test('the ones that answer, the fastest first; at most 36 are tried', () async {
      final tried = <int>[];
      final found = await scanWarp(
        count: 100,
        test: (i) async {
          tried.add(i);
          return i % 4 == 0 ? 500 - i : -1;
        },
      );
      expect(tried, hasLength(warpScanLimit));
      expect(found.first.index, 32); // 468 ms, the lowest
      expect(found.map((f) => f.ms), orderedEquals([...found.map((f) => f.ms)]..sort()));
      expect(found.every((f) => f.index % 4 == 0), isTrue);
    });

    test('nothing answers: an empty list; a thrown error counts as no answer; a cancel stops it', () async {
      expect(await scanWarp(count: 5, test: (i) async => -1), isEmpty);
      expect(await scanWarp(count: 3, test: (i) async => throw StateError('x')), isEmpty);
      var n = 0;
      await scanWarp(count: 30, parallel: 1, test: (i) async => ++n, cancelled: () => n >= 4);
      expect(n, 4);
      expect(await scanWarp(count: 0, test: (i) async => 1), isEmpty);
    });
  });

  group('Warp-in-Warp in the configs', () {
    ProxyConfig twice() => ProxyConfig(
          link: 'wireguard://outer',
          protocol: 'wireguard',
          name: 'WARP in WARP',
          host: '162.159.192.1',
          port: 2408,
          outbound: wg('162.159.192.1'),
          inner: [wg('162.159.193.1')],
        );

    test('the connection: two endpoints, the first dialled through the second', () {
      final cfg = jsonDecode(buildSingBoxConfig([twice()])) as Map<String, dynamic>;
      final endpoints = (cfg['endpoints'] as List).cast<Map<String, dynamic>>();
      expect(endpoints.map((e) => e['tag']), ['proxy', 'proxy-l1']);
      expect(endpoints.first['detour'], 'proxy-l1');
      expect(endpoints.last.containsKey('detour'), isFalse);
    });

    test('one tunnel alone is as before', () {
      final one = ProxyConfig(
          link: 'wireguard://x', protocol: 'wireguard', name: 'WARP', host: '1.1.1.1', port: 2408, outbound: wg('162.159.192.1'));
      final cfg = jsonDecode(buildSingBoxConfig([one])) as Map<String, dynamic>;
      final endpoints = (cfg['endpoints'] as List).cast<Map<String, dynamic>>();
      expect(endpoints, hasLength(1));
      expect(endpoints.single['tag'], 'proxy');
      expect(endpoints.single.containsKey('detour'), isFalse);
    });

    test('the test core: the same two endpoints', () {
      final cfg = jsonDecode(delayConfigForTest([wg('162.159.192.1'), wg('162.159.193.1')])) as Map<String, dynamic>;
      final endpoints = (cfg['endpoints'] as List).cast<Map<String, dynamic>>();
      expect(endpoints.map((e) => e['tag']), ['proxy', 'proxy-l1']);
      expect(endpoints.first['detour'], 'proxy-l1');
      expect(cfg.containsKey('outbounds'), isFalse);
      final single = jsonDecode(delayConfigForTest([wg('162.159.192.1')])) as Map<String, dynamic>;
      expect((single['endpoints'] as List), hasLength(1));
    });
  });
}
