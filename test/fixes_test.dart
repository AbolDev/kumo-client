import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/latency_tester.dart';
import 'package:kumo/core/net_options.dart';
import 'package:kumo/core/proxy_config.dart';
import 'package:kumo/core/routing_rules.dart';
import 'package:kumo/core/singbox_config.dart';
import 'package:kumo/core/sources.dart';
import 'package:kumo/core/sub_formats.dart';
import 'package:kumo/state/app_state.dart';

void main() {
  group('the tunnel packet size', () {
    test('the default is 1500, and the old default 9000 moves to it', () {
      expect(NetOptions().mtu, 1500);
      final o = NetOptions()..load({'mtu': 9000});
      expect(o.mtu, 1500);
      expect((NetOptions()..load({'mtu': 1400})).mtu, 1400);
      // out of range: the default stays
      expect((NetOptions()..load({'mtu': 20000})).mtu, 1500);
      expect((NetOptions()..load({'mtu': 100})).mtu, 1500);
    });
  });

  group('DNS address', () {
    test('what is accepted and what is not', () {
      for (final ok in [
        'https://dns.example/dns-query',
        'tls://1.1.1.1',
        'quic://dns.adguard-dns.com',
        'tcp://8.8.8.8:5353',
        '1.1.1.1',
        '8.8.8.8:5353',
        'dns.google',
        '[2606:4700::1111]',
        '2606:4700:4700::1111',
      ]) {
        expect(isValidDnsAddress(ok), isTrue, reason: ok);
      }
      for (final bad in ['', ' ', 'two words', 'ftp://x.y', 'https://', 'tls://x:99999', 'host:0', 'a/b']) {
        expect(isValidDnsAddress(bad), isFalse, reason: bad);
      }
    });

    test('an address with a port is a plain server with that port', () {
      final cfg = jsonDecode(buildSingBoxConfig(
        parseLinks(['ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ@s.example.com:8388#ss']),
        options: NetOptions()
          ..dns = 'custom'
          ..customDns = '9.9.9.9:5353',
      )) as Map;
      final remote = ((cfg['dns'] as Map)['servers'] as List).firstWhere((s) => (s as Map)['tag'] == 'dns-remote') as Map;
      expect(remote['server'], '9.9.9.9');
      expect(remote['server_port'], 5353);
    });

    test('a bad address falls back to the first preset instead of failing', () {
      final cfg = jsonDecode(buildSingBoxConfig(
        parseLinks(['ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ@s.example.com:8388#ss']),
        options: NetOptions()
          ..dns = 'custom'
          ..customDns = 'not valid at all',
      )) as Map;
      final remote = ((cfg['dns'] as Map)['servers'] as List).firstWhere((s) => (s as Map)['tag'] == 'dns-remote') as Map;
      expect(remote['server'], '1.1.1.1');
    });
  });

  group('routing rules', () {
    test('patterns RE2 cannot read are refused', () {
      for (final bad in [r'(?=x)y', r'(?!x)y', r'(?<=a)b', r'(?<!a)b', r'(a)\1', r'a++', r'a*+', r'(?>a)']) {
        expect(normalizeRouteRule('regex:$bad'), isNull, reason: bad);
      }
      for (final good in [r'^ad[0-9]+\.', r'(?i)tracker', r'a{2,3}', r'\(literal\)', r'\\1', r'(?:x|y)z']) {
        expect(normalizeRouteRule('regex:$good'), 'regex:$good', reason: good);
      }
    });

    test('names in their own script become punycode', () {
      expect(punycodeLabel('münchen'), 'xn--mnchen-3ya');
      expect(punycodeLabel('example'), 'example');
      expect(normalizeRouteRule('münchen.de'), 'xn--mnchen-3ya.de');
      expect(normalizeRouteRule('https://www.münchen.de/path'), 'www.xn--mnchen-3ya.de');
      // "bücher" is a classic example of the RFC
      expect(punycodeLabel('bücher'), 'xn--bcher-kva');
    });
  });

  group('the login of the local Xray port', () {
    test('sing-box and Xray are given the same user and password', () {
      final server = parseLinks([
        'vless://11111111-1111-1111-1111-111111111111@x.example.com:443?security=tls&sni=x.example.com&type=xhttp&path=%2Fx#x',
      ]).single;
      const auth = (user: 'kabc', pass: 'p4ss');
      final box = jsonDecode(buildSingBoxConfig([server], xrayPort: 31000, viaXray: true, xrayAuth: auth)) as Map;
      final out = (box['outbounds'] as List).firstWhere((o) => (o as Map)['tag'] == 'proxy') as Map;
      expect(out['username'], 'kabc');
      expect(out['password'], 'p4ss');
      final xray = jsonDecode(buildXrayConfig(server, 31000, auth: auth)) as Map;
      final settings = ((xray['inbounds'] as List).first as Map)['settings'] as Map;
      expect(settings['accounts'], [
        {'user': 'kabc', 'pass': 'p4ss'}
      ]);
      // without a login nothing changes
      final plain = jsonDecode(buildXrayConfig(server, 31000)) as Map;
      expect((((plain['inbounds'] as List).first as Map)['settings'] as Map)['auth'], 'noauth');
    });

    test('the delay test speaks SOCKS5 with a user name and password', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final seen = <String>[];
      server.listen((s) {
        final buffer = <int>[];
        var step = 0;
        s.listen((data) {
          buffer.addAll(data);
          if (step == 0 && buffer.length >= 3) {
            seen.add('methods ${buffer.take(3).toList()}');
            buffer.removeRange(0, 3);
            s.add([5, 2]); // asks for a user name and password
            step = 1;
          }
          if (step == 1 && buffer.isNotEmpty && buffer.length >= 2 + buffer[1] + 1) {
            final ulen = buffer[1];
            final plen = buffer[2 + ulen];
            if (buffer.length >= 3 + ulen + plen) {
              seen.add('login ${utf8.decode(buffer.sublist(2, 2 + ulen))}/${utf8.decode(buffer.sublist(3 + ulen, 3 + ulen + plen))}');
              s.add([1, 0]);
              s.destroy();
              step = 2;
            }
          }
        }, onError: (_) {});
      });
      await socksWarmDelay(server.port, Uri.parse('http://example.com/'), const Duration(seconds: 2),
          auth: (user: 'kabc', pass: 'p4ss'));
      expect(seen, ['methods [5, 1, 2]', 'login kabc/p4ss']);
    });
  });

  group('downloads of subscriptions', () {
    late HttpServer http;
    var hits = 0;

    setUp(() async {
      hits = 0;
      http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      http.listen((r) {
        hits++;
        final path = r.uri.path;
        if (path == '/start') {
          r.response.statusCode = 302;
          r.response.headers.set('location', '/next');
        } else if (path == '/next') {
          r.response.write('ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ@s.example.com:8388#ss');
        } else if (path == '/loop') {
          r.response.statusCode = 302;
          r.response.headers.set('location', '/loop');
        }
        r.response.close();
      });
    });
    tearDown(() => http.close(force: true));

    test('a redirect on the same site is followed', () async {
      final f = await fetchSubscription('http://127.0.0.1:${http.port}/start');
      expect(f.body, contains('ss://'));
    });

    test('a redirect that never ends is given up on', () async {
      await expectLater(fetchSubscription('http://127.0.0.1:${http.port}/loop'), throwsA(anything));
      expect(hits, lessThan(40));
    });

    test('addresses on the local network are not followed from a list', () {
      expect(isPublicUrl('http://192.168.0.10/x'), isFalse);
      expect(isPublicUrl('https://sub.example.com/x'), isTrue);
    });
  });

  group('YAML subscriptions', () {
    test('a plain Clash file is read', () {
      const yaml = '''
proxies:
  - {name: a, type: ss, server: s.example.com, port: 8388, cipher: aes-256-gcm, password: pw}
''';
      expect(extractSubscriptionLinks(yaml), isNotEmpty);
    });

    test('anchors that repeat the same defaults over many servers are fine', () {
      final b = StringBuffer('base: &b {type: ss, cipher: aes-256-gcm, password: pw}\nproxies:\n');
      for (var i = 0; i < 300; i++) {
        b.writeln('  - {<<: *b, name: n$i, server: s$i.example.com, port: ${1000 + i}}');
      }
      expect(extractSubscriptionLinks(b.toString()).length, greaterThan(100));
    });

    test('a document that expands into millions of nodes is turned away', () {
      // each level names the previous one ten times: 10^8 nodes once written out
      final b = StringBuffer('l0: &l0 [x,x,x,x,x,x,x,x,x,x]\n');
      for (var i = 1; i < 9; i++) {
        b.writeln('l$i: &l$i [${List.filled(10, '*l${i - 1}').join(',')}]');
      }
      b.writeln('proxies: [*l8]');
      final clock = Stopwatch()..start();
      expect(extractSubscriptionLinks(b.toString()), isEmpty);
      expect(clock.elapsed, lessThan(const Duration(seconds: 20)));
    });
  });

  group('the list of servers', () {
    test('editing a server into one that is already there does not make a second', () async {
      final state = AppState();
      const a = 'ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ@s.example.com:8388#a';
      const b = 'ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ@t.example.com:8388#b';
      state.manual.configs.addAll(parseLinks([a, b]));
      final first = state.manual.configs[0], second = state.manual.configs[1];
      state.selected = second;
      final ok = await state.editConfig(state.manual, second, a.replaceAll('#a', '#renamed'));
      expect(ok, isTrue);
      expect(state.manual.configs.length, 1);
      expect(identical(state.selected, first), isTrue);
    });
  });
}
