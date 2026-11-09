import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/net_options.dart';
import 'package:kumo/core/proxy_config.dart';
import 'package:kumo/core/server_resolver.dart';

ProxyConfig server(String host, {Map<String, dynamic>? extra}) => ProxyConfig(
      link: 'vless://$host',
      protocol: 'vless',
      name: host,
      host: host,
      port: 443,
      outbound: {
        'type': 'vless',
        'server': host,
        'server_port': 443,
        'tls': {'enabled': true, 'server_name': ''},
        ...?extra,
      },
    );

void main() {
  group('looking a name up', () {
    test('encrypted DNS first; the system resolver only when it does not answer', () async {
      final calls = <String>[];
      final r = NameResolver(
        doh: (h) async {
          calls.add('doh:$h');
          return h == 'a.example.com' ? '203.0.113.1' : null;
        },
        system: (h) async {
          calls.add('sys:$h');
          return '198.51.100.7';
        },
      );
      expect(await r.lookup('a.example.com'), '203.0.113.1');
      expect(calls, ['doh:a.example.com']);
      expect(await r.lookup('b.example.com'), '198.51.100.7');
      expect(calls, ['doh:a.example.com', 'doh:b.example.com', 'sys:b.example.com']);
    });

    test('the answer is remembered for a while', () async {
      var now = DateTime(2026, 11, 8, 10);
      var n = 0;
      final r = NameResolver(doh: (h) async => '203.0.113.${++n}', system: (h) async => null, now: () => now);
      expect(await r.lookup('A.example.com'), '203.0.113.1');
      expect(await r.lookup('a.example.com'), '203.0.113.1'); // same name, other case: from memory
      now = now.add(const Duration(minutes: 11));
      expect(await r.lookup('a.example.com'), '203.0.113.2');
    });

    test('when encrypted DNS did not answer it is not asked again for a few minutes', () async {
      var now = DateTime(2026, 11, 8, 10);
      var dohCalls = 0;
      final r = NameResolver(
          doh: (h) async {
            dohCalls++;
            return null;
          },
          system: (h) async => '198.51.100.9',
          now: () => now);
      await r.lookup('a.example.com');
      await r.lookup('b.example.com');
      await r.lookup('c.example.com');
      expect(dohCalls, 1);
      now = now.add(const Duration(minutes: 6));
      await r.lookup('d.example.com');
      expect(dohCalls, 2);
    });

    test('the first encrypted resolver to answer wins; a slow or failing one does not hold it back', () async {
      Future<String?> after(int ms, String? ip) => Future.delayed(Duration(milliseconds: ms), () => ip);
      expect(await firstAnswer([after(200, '203.0.113.1'), after(10, '203.0.113.2')]), '203.0.113.2');
      expect(await firstAnswer([after(10, null), after(30, '203.0.113.3')]), '203.0.113.3');
      expect(await firstAnswer([Future.error(Exception('blocked')), after(10, '203.0.113.4')]), '203.0.113.4');
      expect(await firstAnswer([after(5, null), Future.error(Exception('x'))]), isNull);
      expect(await firstAnswer([]), isNull);
    });

    test('encrypted DNS that takes too long gives way to the system resolver', () async {
      final r = NameResolver(
        doh: (h) => Future<String?>.delayed(const Duration(seconds: 5), () => '203.0.113.1'),
        system: (h) async => '198.51.100.7',
        dohWait: const Duration(milliseconds: 50),
      );
      final sw = Stopwatch()..start();
      expect(await r.lookup('a.example.com'), '198.51.100.7');
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('nothing answers: null, and nothing is remembered', () async {
      final r = NameResolver(doh: (h) async => null, system: (h) async => null);
      expect(await r.lookup('x.example.com'), isNull);
    });

    test('the answer of a DNS-over-HTTPS service', () {
      expect(firstARecord('{"Status":0,"Answer":[{"name":"a","type":5,"data":"b."},{"name":"b","type":1,"data":"203.0.113.5"}]}'), '203.0.113.5');
      expect(firstARecord('{"Status":3}'), isNull);
      expect(firstARecord('{"Answer":[{"type":28,"data":"2001:db8::1"}]}'), isNull);
      expect(firstARecord('{"Answer":[{"type":1,"data":"not an address"}]}'), isNull);
      expect(firstARecord('not json'), isNull);
    });
  });

  group('the server in the settings', () {
    Future<String?> found(String h) async => h == 'cdn.example.com' ? '203.0.113.9' : null;

    test('the name becomes the address and stays where the server needs it', () async {
      final out = await resolveOutbound(server('cdn.example.com').outbound, found);
      expect(out['server'], '203.0.113.9');
      expect((out['tls'] as Map)['server_name'], 'cdn.example.com');
      final ws = await resolveOutbound(
          server('cdn.example.com', extra: {'transport': {'type': 'ws', 'path': '/x'}}).outbound, found);
      expect(((ws['transport'] as Map)['headers'] as Map)['Host'], 'cdn.example.com');
      final own = await resolveOutbound(
          server('cdn.example.com', extra: {'tls': {'enabled': true, 'server_name': 'front.example.org'}}).outbound, found);
      expect((own['tls'] as Map)['server_name'], 'front.example.org');
    });

    test('an address, or a name nobody answers, is left as it is', () async {
      final ip = await resolveOutbound(server('198.51.100.1').outbound, found);
      expect(ip['server'], '198.51.100.1');
      final nobody = await resolveOutbound(server('other.example.com').outbound, found);
      expect(nobody['server'], 'other.example.com');
    });

    test('a WireGuard peer is looked up too', () async {
      final out = await resolveOutbound({
        'type': 'wireguard',
        'peers': [
          {'address': 'cdn.example.com', 'port': 2408}
        ],
      }, found);
      expect(((out['peers'] as List).first as Map)['address'], '203.0.113.9');
    });
  });

  group('the servers of a connection', () {
    NameResolver resolver() => NameResolver(doh: (h) async => '203.0.113.9', system: (h) async => null);

    test('their names are looked up, the rest of each server kept', () async {
      final list = await resolveServers([server('cdn.example.com')..latencyMs = 80], resolver());
      expect(list.single.outbound['server'], '203.0.113.9');
      expect(list.single.name, 'cdn.example.com');
      expect(list.single.link, 'vless://cdn.example.com');
      expect(list.single.latencyMs, 80);
    });

    test('a big group (the automatic mode) is left to the core', () async {
      final many = [for (var i = 0; i < resolveAheadLimit + 1; i++) server('h$i.example.com')];
      final list = await resolveServers(many, resolver());
      expect(identical(list, many), isTrue);
    });

    test('a lookup that takes too long gives the servers back as they were', () async {
      final slow = NameResolver(
          doh: (h) => Future<String?>.delayed(const Duration(seconds: 2), () => '203.0.113.9'), system: (h) async => null);
      final servers = [server('cdn.example.com')];
      final list = await resolveServers(servers, slow, budget: const Duration(milliseconds: 50));
      expect(identical(list, servers), isTrue);
    });

    test('it is a setting, on by default, saved and read back; strict DNS keeps its own way', () {
      final o = NetOptions();
      expect(o.encryptedLookup, isTrue);
      o.encryptedLookup = false;
      expect((NetOptions()..load(o.toJson())).encryptedLookup, isFalse);
      expect((NetOptions()..load({})).encryptedLookup, isTrue);
    });
  });
}
