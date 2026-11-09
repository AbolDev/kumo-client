import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/clean_ip.dart';
import 'package:kumo/core/link_fields.dart';

LinkFields fields(String link) => LinkFields.parse(link)!;

const vlessWs =
    'vless://11111111-1111-1111-1111-111111111111@cdn.example.com:443?security=tls&type=ws&path=%2Fws#n';

int last(String ip) => int.parse(ip.split('.').last);

void main() {
  group('a server with another address', () {
    test('TLS and WebSocket: the name stays as the server name and the Host header', () {
      final out = withCleanIp(fields(vlessWs), '104.16.5.9')!;
      expect(out.host, '104.16.5.9');
      expect(out.params['sni'], 'cdn.example.com');
      expect(out.params['host'], 'cdn.example.com');
      expect(out.params['path'], '/ws');
      expect(out.build(), contains('@104.16.5.9:443'));
    });

    test('settings the link already has are kept', () {
      final link =
          'vless://11111111-1111-1111-1111-111111111111@cdn.example.com:443?security=tls&type=ws&sni=front.example.org&host=ws.example.net#n';
      final out = withCleanIp(fields(link), '104.16.5.9')!;
      expect(out.params['sni'], 'front.example.org');
      expect(out.params['host'], 'ws.example.net');
    });

    test('without TLS no server name is added; trojan is TLS by default; plain TCP needs no Host', () {
      final plain = withCleanIp(fields('vless://11111111-1111-1111-1111-111111111111@cdn.example.com:80?type=ws#n'), '1.2.3.4')!;
      expect(plain.params.containsKey('sni'), isFalse);
      expect(plain.params['host'], 'cdn.example.com');
      final trojan = withCleanIp(fields('trojan://pw@cdn.example.com:443?type=tcp#n'), '1.2.3.4')!;
      expect(trojan.params['sni'], 'cdn.example.com');
      expect(trojan.params.containsKey('host'), isFalse);
      expect(usesTls(fields(vlessWs)), isTrue);
      expect(usesTls(fields('vless://u@h.example.com:80?type=ws#n')), isFalse);
    });

    test('vmess keeps its fields', () {
      final vmess = LinkFields.parse(
          'vmess://${base64Encode(utf8.encode('{"v":"2","ps":"n","add":"cdn.example.com","port":"443","id":"11111111-1111-1111-1111-111111111111","net":"ws","tls":"tls","path":"/p"}'))}')!;
      final out = withCleanIp(vmess, '104.16.5.9')!;
      expect(out.host, '104.16.5.9');
      expect(out.params['sni'], 'cdn.example.com');
      expect(out.params['host'], 'cdn.example.com');
      expect(out.params['path'], '/p');
    });

    test('other kinds of server are not for this, and the original is not changed', () {
      expect(withCleanIp(fields('hysteria2://pw@h.example.com:443#n'), '1.2.3.4'), isNull);
      final f = fields(vlessWs);
      withCleanIp(f, '1.2.3.4');
      expect(f.host, 'cdn.example.com');
      expect(f.params.containsKey('sni'), isFalse);
      expect(serverNameOf(fields(vlessWs)), 'cdn.example.com');
      expect(serverNameOf(fields('vless://u@1.2.3.4:443?security=tls#n')), isNull);
    });
  });

  group('the networks and the lists', () {
    test('an address is told to its CDN', () {
      expect(cdnOf('104.16.5.9'), Cdn.cloudflare);
      expect(cdnOf('151.101.1.1'), Cdn.fastly);
      expect(cdnOf('8.8.8.8'), isNull);
      expect(cdnOf('not an address'), isNull);
    });

    test('ranges typed in', () {
      expect(parseRanges('203.0.113.0/24\n198.51.100.0/22, 192.0.2.0/24'), ['203.0.113.0/24', '198.51.100.0/22', '192.0.2.0/24']);
      for (final bad in ['203.0.113.0', '203.0.113.0/33', '300.0.0.0/24', '10.0.0.0/4', 'hello']) {
        expect(() => parseRanges(bad), throwsFormatException, reason: bad);
      }
    });

    test('a list: addresses, spans, CIDR, names, comments, and what cannot be read', () {
      final t = parseTargets('''
# my list
1.2.3.4, 1.2.3.4  5.6.7.8
10.0.0.5-10.0.0.8
10.0.1.250-253
203.0.113.0/24
Example.COM;sub.example.org
nonsense 300.1.1.1 1.2.3.4-1.2.3.1 10.0.0.1-999 1.2.3.0/40
''');
      expect(t.ips, ['1.2.3.4', '5.6.7.8', '10.0.0.5', '10.0.0.6', '10.0.0.7', '10.0.0.8', '10.0.1.250', '10.0.1.251', '10.0.1.252', '10.0.1.253']);
      expect(t.ranges, ['203.0.113.0/24']);
      expect(t.domains, ['example.com', 'sub.example.org']);
      expect(t.bad, ['nonsense', '300.1.1.1', '1.2.3.4-1.2.3.1', '10.0.0.1-999', '1.2.3.0/40']);
      expect(t.isEmpty, isFalse);
      expect(parseTargets('  \n# only a comment').isEmpty, isTrue);
    });

    test('limits: a span of more than 4096 is refused, a list is cut at 2000', () {
      expect(parseTargets('10.0.0.0-10.0.20.0').bad, ['10.0.0.0-10.0.20.0']);
      expect(parseTargets('10.0.0.0-10.0.15.255').ips, hasLength(cleanIpMaxList.clamp(0, 4096)));
      final many = parseTargets(List.generate(3000, (i) => '10.${i ~/ 250}.${i % 250}.1').join('\n'));
      expect(many.ips, hasLength(cleanIpMaxList));
    });

    test('names are looked up, the addresses are joined with the single ones', () async {
      final t = parseTargets('1.1.1.1\na.example.com\nb.example.com');
      final seen = <String>[];
      final ips = await resolveTargets(t, lookup: (h) async {
        seen.add(h);
        return h == 'a.example.com' ? ['203.0.113.1', '203.0.113.2', '1.1.1.1'] : <String>[];
      });
      expect(seen, ['a.example.com', 'b.example.com']);
      expect(ips, ['1.1.1.1', '203.0.113.1', '203.0.113.2']);
    });

    test('the addresses next to one stay in its /24', () {
      final n = neighborsOf('10.0.0.3', reach: 4);
      expect(n, containsAll(['10.0.0.2', '10.0.0.4', '10.0.0.1', '10.0.0.5', '10.0.0.7']));
      expect(n.contains('10.0.0.0'), isFalse);
      expect(neighborsOf('10.0.0.254', reach: 3).contains('10.0.0.255'), isFalse);
      expect(neighborsOf('10.0.0.5', skip: {'10.0.0.6'}).contains('10.0.0.6'), isFalse);
      expect(neighborsOf('nope'), isEmpty);
    });
  });

  group('the options', () {
    test('values are brought inside their limits, and saved and read back', () {
      final o = const ScanOptions(count: 1, timeoutSeconds: 99, ports: [0, 443, 70000, 8443], samples: 0, stopAfter: -3).normalized();
      expect(o.count, cleanIpMinCount);
      expect(o.timeoutSeconds, cleanIpMaxTimeout);
      expect(o.ports, [443, 8443]);
      expect(o.samples, 1);
      expect(o.stopAfter, 0);
      expect(const ScanOptions(ports: [0]).normalized().ports, [443]);
      final back = ScanOptions.fromJson(const ScanOptions(count: 50, gentle: true, ports: [2053], sni: 'a.example', neighbors: true, samples: 3, fragment: true).toJson());
      expect(back.count, 50);
      expect(back.gentle, isTrue);
      expect(back.ports, [2053]);
      expect(back.sni, 'a.example');
      expect(back.neighbors && back.fragment, isTrue);
      expect(back.samples, 3);
      expect(ScanOptions.fromJson('junk').count, cleanIpTcpCount);
    });

    test('a stopped scan is saved and read back; bad entries are dropped', () {
      final s = ScanState(['1.2.3.4', '5.6.7.8'], [const CleanIp('9.9.9.9', 40, null, port: 8443, loss: 0.5, jitterMs: 7)]);
      final back = ScanState.fromJson(jsonDecode(jsonEncode(s.toJson())))!;
      expect(back.pending, ['1.2.3.4', '5.6.7.8']);
      expect(back.results.single.ip, '9.9.9.9');
      expect(back.results.single.port, 8443);
      expect(back.results.single.loss, 0.5);
      expect(ScanState.fromJson({'pending': ['not an ip', '1.1.1.1'], 'results': [1, 'x']})!.pending, ['1.1.1.1']);
      expect(ScanState.fromJson('x'), isNull);
    });
  });

  group('the scan of addresses', () {
    test('the fastest open ones, on every given port, nothing else is run', () async {
      final ports = <int>{};
      final found = await scanCleanIps(
        ranges: ['203.0.113.0/24'],
        options: const ScanOptions(count: 40, ports: [2053, 8443], keep: 5),
        random: Random(3),
        tcp: (ip, p) async {
          ports.add(p);
          return last(ip).isEven ? last(ip) : -1;
        },
        delay: (c) async => throw StateError('no real test without a server'),
      );
      expect(ports, {2053, 8443});
      expect(found, hasLength(lessThanOrEqualTo(5)));
      expect(found, isNotEmpty);
      expect(found.every((r) => r.delayMs == null), isTrue);
      expect(found.map((r) => r.tcpMs), orderedEquals([...found.map((r) => r.tcpMs)]..sort()));
    });

    test('the number of addresses is kept between the limits', () async {
      var seen = 0;
      Future<int> probe(String ip, int p) async {
        seen++;
        return -1;
      }

      await scanCleanIps(ranges: ['10.0.0.0/8'], options: const ScanOptions(count: 1), tcp: probe);
      expect(seen, cleanIpMinCount);
      seen = 0;
      await scanCleanIps(ranges: ['10.0.0.0/8'], options: const ScanOptions(count: 100000), tcp: probe);
      expect(seen, cleanIpMaxCount);
    });

    test('a list of addresses is all tried, with the ones drawn from ranges', () async {
      final seen = <String>[];
      await scanCleanIps(
          addresses: ['1.1.1.1', '2.2.2.2'],
          ranges: ['203.0.113.0/24'],
          options: const ScanOptions(count: 10),
          tcp: (ip, p) async {
            seen.add(ip);
            return -1;
          });
      expect(seen, containsAll(['1.1.1.1', '2.2.2.2']));
      expect(seen, hasLength(12));
      expect(await scanCleanIps(tcp: (ip, p) async => 1), isEmpty);
    });

    test('good addresses are given as they are found, and the scan can stop after some', () async {
      final live = <String>[];
      var probes = 0;
      final found = await scanCleanIps(
        addresses: [for (var i = 1; i <= 100; i++) '10.0.0.$i'],
        options: const ScanOptions(stopAfter: 3),
        tcp: (ip, p) async {
          probes++;
          await Future<void>.delayed(const Duration(milliseconds: 2));
          return 10;
        },
        onResult: (r) => live.add(r.ip),
      );
      expect(live.length, greaterThanOrEqualTo(3));
      expect(live.length, lessThan(40)); // it stopped well before the 100
      expect(probes, lessThan(100));
      expect(found, isNotEmpty);
    });

    test('several probes per address give loss and jitter, and fewer losses rank first', () async {
      final calls = <String, int>{};
      final found = await scanCleanIps(
        addresses: ['10.0.0.1', '10.0.0.2', '10.0.0.3'],
        options: const ScanOptions(samples: 4),
        tcp: (ip, p) async {
          final n = calls[ip] = (calls[ip] ?? 0) + 1;
          switch (ip) {
            case '10.0.0.1': // always answers, slowly
              return 80 + n;
            case '10.0.0.2': // answers half of the time, quickly
              return n.isEven ? 10 : -1;
            default: // never answers
              return -1;
          }
        },
      );
      expect(found.map((r) => r.ip), ['10.0.0.1', '10.0.0.2']); // no loss first, though slower
      expect(found.first.loss, 0);
      expect(found.first.jitterMs, 3);
      expect(found.last.loss, 0.5);
    });

    test('gentle mode: few at once and the longer timeout', () async {
      var now = 0, most = 0;
      final stopwatch = Stopwatch()..start();
      await scanCleanIps(
        addresses: [for (var i = 1; i <= 60; i++) '10.0.0.$i'],
        options: const ScanOptions(gentle: true),
        tcp: (ip, p) async {
          now++;
          most = max(most, now);
          await Future<void>.delayed(const Duration(milliseconds: 40));
          now--;
          return 5;
        },
      );
      expect(most, lessThanOrEqualTo(gentleWorkers));
      // 60 probes at 40 a second cannot take less than a second and a bit.
      expect(stopwatch.elapsedMilliseconds, greaterThan(1300));
      // And an ordinary scan goes as wide as 24.
      now = 0;
      most = 0;
      await scanCleanIps(
        addresses: [for (var i = 1; i <= 60; i++) '10.0.0.$i'],
        tcp: (ip, p) async {
          now++;
          most = max(most, now);
          await Future<void>.delayed(const Duration(milliseconds: 40));
          now--;
          return 5;
        },
      );
      expect(most, greaterThan(gentleWorkers));
      expect(most, lessThanOrEqualTo(24));
    });

    test('a big scan runs more probes at once, up to 64', () {
      expect(cleanIpWorkers(60), 24);
      expect(cleanIpWorkers(2000), 50);
      expect(cleanIpWorkers(10000), 64);
      expect(cleanIpWorkers(10000, gentle: true), gentleWorkers);
      expect(cleanIpCountChoices.last, cleanIpMaxCount);
      expect(cleanIpCountChoices, contains(cleanIpTcpCount));
    });

    test('the neighbors of the best addresses are tried too', () async {
      final seen = <String>{};
      final found = await scanCleanIps(
        addresses: ['10.0.5.100', '10.0.9.1'],
        options: const ScanOptions(neighbors: true),
        tcp: (ip, p) async {
          seen.add(ip);
          return ip == '10.0.5.100' ? 5 : (ip.startsWith('10.0.5.') ? 20 : -1);
        },
      );
      expect(seen, containsAll(['10.0.5.101', '10.0.5.99', '10.0.5.108']));
      expect(found.map((r) => r.ip), containsAll(['10.0.5.100', '10.0.5.101']));
      // Off by default.
      final none = <String>{};
      await scanCleanIps(addresses: ['10.0.5.100'], tcp: (ip, p) async {
        none.add(ip);
        return 5;
      });
      expect(none, {'10.0.5.100'});
    });

    test('a stopped scan leaves what is left, and can be taken up again', () async {
      ScanState? saved;
      var cancel = false;
      var n = 0;
      await scanCleanIps(
        addresses: [for (var i = 1; i <= 80; i++) '10.0.0.$i'],
        tcp: (ip, p) async {
          if (++n >= 20) cancel = true;
          return last(ip) % 3 == 0 ? 7 : -1;
        },
        onCheckpoint: (s) => saved = s,
        cancelled: () => cancel,
      );
      expect(saved, isNotNull);
      expect(saved!.pending, isNotEmpty);
      expect(saved!.pending.length, lessThan(80));
      final done = 80 - saved!.pending.length;
      expect(saved!.results.length, lessThanOrEqualTo(done));
      final again = <String>{};
      final found = await scanCleanIps(
        resume: saved,
        tcp: (ip, p) async {
          again.add(ip);
          return last(ip) % 3 == 0 ? 7 : -1;
        },
      );
      expect(again, saved!.pending.toSet()); // only what was left
      // Together: every third address of the 80.
      expect(found.map((r) => r.ip).toSet(), {for (var i = 3; i <= 78; i += 3) '10.0.0.$i'});
    });

    test('a probe that is too slow is no answer: the timeout reaches the probe', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = <Socket>[];
      server.listen(accepted.add);
      try {
        final sw = Stopwatch()..start();
        expect(await tlsProbe('127.0.0.1', server.port, 'example.com', const Duration(seconds: 1)), -1);
        expect(sw.elapsedMilliseconds, lessThan(3000));
        expect(await tcpProbe('127.0.0.1', server.port, const Duration(seconds: 1)), greaterThanOrEqualTo(0));
        expect(await tcpProbe('127.0.0.1', 1, const Duration(seconds: 1)), -1);
      } finally {
        for (final s in accepted) {
          s.destroy();
        }
        await server.close();
      }
    });
  });

  group('the scan with a server', () {
    final server = fields(vlessWs);

    test('the fastest open addresses get the real test, the fastest answers come first', () async {
      final tested = <String>[];
      final live = <int?>[];
      final found = await scanCleanIps(
        server: server,
        ranges: ['203.0.113.0/24'],
        options: const ScanOptions(count: 30, delayCount: 5),
        random: Random(1),
        tcp: (ip, port) async {
          expect(port, 443);
          return last(ip).isEven ? last(ip) : -1;
        },
        delay: (c) async {
          tested.add(c.host);
          expect((c.outbound['tls'] as Map)['server_name'], 'cdn.example.com');
          return 1000 - last(c.host);
        },
        onResult: (r) => live.add(r.delayMs),
      );
      expect(tested, hasLength(lessThanOrEqualTo(5)));
      expect(found, isNotEmpty);
      expect(live, hasLength(found.length)); // each answer was given as it came
      expect(found.map((r) => r.delayMs), orderedEquals([...found.map((r) => r.delayMs!)]..sort()));
    });

    test('skipping the first stage: no connection tests, every address gets the real test', () async {
      var tcp = 0;
      final tested = <String>[];
      final found = await scanCleanIps(
        server: server,
        addresses: [for (var i = 1; i <= 80; i++) '10.0.0.$i'],
        options: const ScanOptions(skipFirst: true),
        tcp: (ip, p) async {
          tcp++;
          return 1;
        },
        delay: (c) async {
          tested.add(c.host);
          return last(c.host) % 2 == 0 ? 100 + last(c.host) : -1;
        },
      );
      expect(tcp, 0);
      expect(tested, hasLength(cleanIpMaxRealTests)); // at most 60 are tried
      expect(found.every((r) => last(r.ip).isEven), isTrue);
    });

    test('the real tests can stop after some good answers', () async {
      var tests = 0;
      final found = await scanCleanIps(
        server: server,
        addresses: [for (var i = 1; i <= 50; i++) '10.0.0.$i'],
        options: const ScanOptions(skipFirst: true, stopAfter: 2),
        delay: (c) async {
          tests++;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return 50;
        },
      );
      expect(found.length, greaterThanOrEqualTo(2));
      expect(tests, lessThan(20));
    });

    test('nothing open, or a failing real test: an empty list', () async {
      var delays = 0;
      expect(
          await scanCleanIps(
              server: server, ranges: ['203.0.113.0/24'], options: const ScanOptions(count: 10), tcp: (ip, p) async => -1, delay: (c) async => ++delays),
          isEmpty);
      expect(delays, 0);
      expect(
          await scanCleanIps(
              server: server,
              ranges: ['203.0.113.0/24'],
              options: const ScanOptions(count: 10),
              tcp: (ip, p) async => 20,
              delay: (c) async => throw StateError('x')),
          isEmpty);
    });

    test('progress in both stages, a cancel, and a server that cannot sit behind a CDN', () async {
      final stages = <int>{};
      await scanCleanIps(
          server: server,
          ranges: ['203.0.113.0/24'],
          options: const ScanOptions(count: 10, delayCount: 2),
          tcp: (ip, p) async => 10,
          delay: (c) async => 50,
          onProgress: (s, d, t) => stages.add(s));
      expect(stages, {1, 2});
      var n = 0;
      await scanCleanIps(
          server: server, ranges: ['203.0.113.0/24'], options: const ScanOptions(count: 40), tcp: (ip, p) async => ++n, cancelled: () => n >= 5);
      expect(n, lessThan(40));
      expect(
          await scanCleanIps(
              server: fields('hysteria2://pw@h.example.com:443#n'),
              ranges: ['203.0.113.0/24'],
              options: const ScanOptions(count: 10),
              tcp: (ip, p) async => 10,
              delay: (c) async => 5),
          isEmpty);
    });
  });

  group('data center and speed', () {
    test('added for the first of the results only, and only what is asked for', () async {
      final results = [for (var i = 1; i <= 5; i++) CleanIp('10.0.0.$i', 10 * i, null)];
      var colos = 0, speeds = 0;
      final out = await enrichResults(
        results,
        colo: true,
        speed: true,
        limit: 3,
        coloProbe: (ip, p) async {
          colos++;
          return ip == '10.0.0.2' ? null : 'FRA';
        },
        speedProbe_: (ip, p) async {
          speeds++;
          return (mbps: 25.5, ttfbMs: 40);
        },
      );
      expect(colos, 3);
      expect(speeds, 3);
      expect(out[0].colo, 'FRA');
      expect(out[1].colo, isNull);
      expect(out[0].downMbps, 25.5);
      expect(out[0].ttfbMs, 40);
      expect(out[3].colo, isNull); // beyond the limit
      expect(out[0].tcpMs, 10); // the rest is kept
      expect(identical(await enrichResults(results), results), isTrue);
    });
  });

  group('the ranges of Cloudflare and what to take away', () {
    test('the current ranges are used when they look right, the built-in ones when not', () async {
      final bad = await liveCloudflareRanges(fetch: (u) async => '<html>nope</html>');
      expect(bad, isNotEmpty);
      expect(bad.length, greaterThan(5)); // the built-in list
      final failing = await liveCloudflareRanges(fetch: (u) async => throw const SocketException('offline'));
      expect(failing, bad);
      final good = await liveCloudflareRanges(
          fetch: (u) async => '173.245.48.0/20\n103.21.244.0/22\n103.22.200.0/22\n103.31.4.0/22\n141.101.64.0/18\n108.162.192.0/18\n');
      expect(good, hasLength(6));
      // Remembered for the rest of the run.
      expect(await liveCloudflareRanges(fetch: (u) async => throw StateError('not asked')), good);
    });

    test('endpoints, links and a subscription', () {
      final list = [const CleanIp('104.16.5.9', 30, 100, port: 443), const CleanIp('104.16.5.10', 40, 120, port: 8443)];
      expect(endpointsText(list), '104.16.5.9:443\n104.16.5.10:8443');
      final links = linksFor(fields(vlessWs), list);
      expect(links, hasLength(2));
      expect(links.first, contains('@104.16.5.9:443'));
      expect(LinkFields.parse(links.first)!.name, 'n 104.16.5.9');
      expect(LinkFields.parse(links.first)!.params['sni'], 'cdn.example.com');
      expect(utf8.decode(base64.decode(subscriptionText(links))).split('\n'), links);
      expect(linksFor(fields('hysteria2://pw@h.example.com:443#n'), list), isEmpty);
    });
  });
}
