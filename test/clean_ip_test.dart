import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/clean_ip.dart';
import 'package:kumo/core/link_fields.dart';

LinkFields fields(String link) => LinkFields.parse(link)!;

const vlessWs =
    'vless://11111111-1111-1111-1111-111111111111@cdn.example.com:443?security=tls&type=ws&path=%2Fws#n';

void main() {
  group('a server with another address', () {
    test('TLS and WebSocket: the name stays as the server name and the Host header', () {
      final out = withCleanIp(fields(vlessWs), '104.16.5.9')!;
      expect(out.host, '104.16.5.9');
      expect(out.params['sni'], 'cdn.example.com');
      expect(out.params['host'], 'cdn.example.com');
      expect(out.params['path'], '/ws');
      expect(out.build(), contains('@104.16.5.9:443'));
      expect(out.build(), contains('sni=cdn.example.com'));
    });

    test('settings the link already has are kept', () {
      final link = 'vless://11111111-1111-1111-1111-111111111111@cdn.example.com:443?security=tls&type=ws&sni=front.example.org&host=ws.example.net#n';
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
    });

    test('vmess keeps its fields', () {
      final vmess = LinkFields.parse(
          'vmess://${base64Of('{"v":"2","ps":"n","add":"cdn.example.com","port":"443","id":"11111111-1111-1111-1111-111111111111","net":"ws","tls":"tls","path":"/p"}')}')!;
      final out = withCleanIp(vmess, '104.16.5.9')!;
      expect(out.host, '104.16.5.9');
      expect(out.params['sni'], 'cdn.example.com');
      expect(out.params['host'], 'cdn.example.com');
      expect(out.params['path'], '/p');
    });

    test('other kinds of server are not for this', () {
      expect(withCleanIp(fields('trojan://pw@h.example.com:443#n'), '1.2.3.4'), isNotNull);
      expect(withCleanIp(fields('hysteria2://pw@h.example.com:443#n'), '1.2.3.4'), isNull);
    });

    test('the original is not changed', () {
      final f = fields(vlessWs);
      withCleanIp(f, '1.2.3.4');
      expect(f.host, 'cdn.example.com');
      expect(f.params.containsKey('sni'), isFalse);
    });
  });

  group('the networks and the ranges', () {
    test('an address is told to its CDN', () {
      expect(cdnOf('104.16.5.9'), Cdn.cloudflare);
      expect(cdnOf('172.67.1.1'), Cdn.cloudflare);
      expect(cdnOf('151.101.1.1'), Cdn.fastly);
      expect(cdnOf('8.8.8.8'), isNull);
      expect(cdnOf('not an address'), isNull);
    });

    test('ranges typed in', () {
      expect(parseRanges('203.0.113.0/24\n198.51.100.0/22, 192.0.2.0/24'), ['203.0.113.0/24', '198.51.100.0/22', '192.0.2.0/24']);
      expect(parseRanges('  '), isEmpty);
      for (final bad in ['203.0.113.0', '203.0.113.0/33', '300.0.0.0/24', '10.0.0.0/4', 'hello']) {
        expect(() => parseRanges(bad), throwsFormatException, reason: bad);
      }
      expect(() => parseRanges(List.generate(maxCustomRanges + 1, (i) => '10.$i.0.0/16').join('\n')), throwsFormatException);
    });
  });

  group('the scan', () {
    final server = fields(vlessWs);

    test('the fastest open addresses get the real test, the fastest answers come first', () async {
      final tcpSeen = <String>[];
      final tested = <String>[];
      final found = await scanCleanIps(
        server: server,
        ranges: ['203.0.113.0/24'],
        random: Random(1),
        tcpCount: 30,
        delayCount: 5,
        tcp: (ip, port) async {
          expect(port, 443);
          tcpSeen.add(ip);
          // The last number decides: even ones are open, the lower the faster.
          final last = int.parse(ip.split('.').last);
          return last.isEven ? last : -1;
        },
        delay: (c) async {
          tested.add(c.host);
          expect(c.outbound['tls'], isA<Map>());
          // The server name is still the name, not the address.
          expect((c.outbound['tls'] as Map)['server_name'], 'cdn.example.com');
          return 1000 - int.parse(c.host.split('.').last);
        },
      );
      expect(tcpSeen, hasLength(30));
      expect(tested, hasLength(lessThanOrEqualTo(5)));
      expect(found, isNotEmpty);
      // The tested ones are the lowest TCP times among the open ones.
      final open = tcpSeen.where((ip) => int.parse(ip.split('.').last).isEven).toList()
        ..sort((a, b) => int.parse(a.split('.').last).compareTo(int.parse(b.split('.').last)));
      expect(tested.toSet(), open.take(tested.length).toSet());
      // Fastest answer first (the highest last number here).
      expect(found.map((r) => r.delayMs), orderedEquals([...found.map((r) => r.delayMs!)]..sort()));
      expect(found.first.ip, tested.reduce((a, b) => int.parse(a.split('.').last) > int.parse(b.split('.').last) ? a : b));
    });

    test('nothing open: an empty list and no real tests; a failing real test is no answer', () async {
      var delays = 0;
      expect(
          await scanCleanIps(
              server: server, ranges: ['203.0.113.0/24'], tcpCount: 10, tcp: (ip, p) async => -1, delay: (c) async => ++delays),
          isEmpty);
      expect(delays, 0);
      final none = await scanCleanIps(
          server: server, ranges: ['203.0.113.0/24'], tcpCount: 10, tcp: (ip, p) async => 20, delay: (c) async => throw StateError('x'));
      expect(none, isEmpty);
    });

    test('progress, a cancel, bad ranges, and a server that cannot sit behind a CDN', () async {
      final stages = <int>{};
      await scanCleanIps(
          server: server,
          ranges: ['203.0.113.0/24'],
          tcpCount: 8,
          delayCount: 2,
          tcp: (ip, p) async => 10,
          delay: (c) async => 50,
          onProgress: (s, d, t) => stages.add(s));
      expect(stages, {1, 2});
      var n = 0;
      await scanCleanIps(
          server: server,
          ranges: ['203.0.113.0/24'],
          tcpCount: 40,
          tcp: (ip, p) async => ++n,
          cancelled: () => n >= 5);
      expect(n, lessThan(40));
      expect(await scanCleanIps(server: server, ranges: const [], tcp: (ip, p) async => 1), isEmpty);
      expect(await scanCleanIps(server: fields('hysteria2://pw@h.example.com:443#n'), ranges: ['203.0.113.0/24'], tcpCount: 5, tcp: (ip, p) async => 10, delay: (c) async => 5), isEmpty);
    });
  });
}

String base64Of(String s) => base64Encode(utf8.encode(s));
