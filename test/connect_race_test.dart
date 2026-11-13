import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/connect_race.dart';
import 'package:kumo/core/proxy_config.dart';

/// A probe that answers after the given time (ms), or fails (-1) after it, by the port of the target.
RaceProbe _probe(Map<int, int> answers) => (host, port, timeout) async {
      final ms = answers[port] ?? -1;
      await Future<void>.delayed(Duration(milliseconds: ms < 0 ? 5 : ms));
      return ms;
    };

({String host, int port}) _t(int port) => (host: '10.0.0.$port', port: port);

void main() {
  group('raceOrder', () {
    test('a server that does not answer is left out, and the ranking of the others is kept', () async {
      // Ranked 0..3; the first is dead, the third answers before the second.
      final order = await raceOrder([_t(1), _t(2), _t(3), _t(4)],
          probe: _probe({1: -1, 2: 60, 3: 20, 4: 40}), grace: const Duration(milliseconds: 100));
      expect(order, [1, 2, 3]);
    });

    test('a server still silent when the first answers and a moment has passed goes after the ones that answered', () async {
      final order = await raceOrder([_t(1), _t(2), _t(3)],
          probe: _probe({1: 900, 2: 10, 3: 30}),
          timeout: const Duration(seconds: 2),
          grace: const Duration(milliseconds: 80));
      expect(order, [1, 2, 0]);
    });

    test('nothing answers: the order is not changed', () async {
      final order = await raceOrder([_t(1), _t(2), _t(3)],
          probe: _probe({}), grace: const Duration(milliseconds: 50));
      expect(order, [0, 1, 2]);
    });

    test('a server that cannot be tried (null) stays, after the ones that answered and before the silent ones', () async {
      final order = await raceOrder([null, _t(2), _t(3), _t(4)],
          probe: _probe({2: 10, 3: 700, 4: -1}),
          timeout: const Duration(seconds: 2),
          grace: const Duration(milliseconds: 60));
      expect(order, [1, 0, 2]);
    });

    test('with only servers that cannot be tried the order stays, and nothing is asked', () async {
      var asked = 0;
      final order = await raceOrder([null, null], probe: (h, p, t) async {
        asked++;
        return 1;
      });
      expect(order, [0, 1]);
      expect(asked, 0);
    });

    test('at least two servers remain, so that the connection is still a group', () async {
      final order = await raceOrder([_t(1), _t(2), _t(3)],
          probe: _probe({1: -1, 2: 10, 3: -1}), grace: const Duration(milliseconds: 50));
      expect(order, [1, 0]);
    });

    test('a probe that throws counts as a failure', () async {
      final order = await raceOrder([_t(1), _t(2)], probe: (host, port, timeout) async {
        if (port == 1) throw StateError('boom');
        return 5;
      }, grace: const Duration(milliseconds: 30));
      expect(order, [1, 0]);
    });
  });

  group('the target of a server', () {
    ProxyConfig one(String link) => parseLinks([link]).single;

    test('an address is tried, a name is not (the system resolver may lie about it)', () {
      final byAddress = one('vless://11111111-1111-1111-1111-111111111111@1.2.3.4:8443?security=tls&sni=a.example&type=ws&path=%2F#a');
      expect(raceTarget(byAddress), (host: '1.2.3.4', port: 8443));
      final byName = one('trojan://secret@t.example.com:443?sni=t.example.com#t');
      expect(raceTarget(byName), isNull);
    });

    test('a server on UDP is not tried with a TCP connect', () {
      final udp = one('hysteria2://pass@5.6.7.8:443?sni=h.example#h');
      expect(raceTarget(udp), isNull);
    });
  });

  group('raceGroup', () {
    test('puts the servers that answer first, in the group and in its resolved copy alike', () async {
      final group = parseLinks([
        'trojan://a@1.1.1.1:1001?sni=x.example#dead',
        'trojan://b@2.2.2.2:1002?sni=x.example#ok-slow',
        'trojan://c@3.3.3.3:1003?sni=x.example#ok-fast',
      ]);
      final raced = await raceGroup(group, group,
          probe: _probe({1001: -1, 1002: 40, 1003: 10}), grace: const Duration(milliseconds: 80));
      expect([for (final c in raced.group) c.name], ['ok-slow', 'ok-fast']);
      expect([for (final c in raced.resolved) c.name], ['ok-slow', 'ok-fast']);
      expect(raced.answered, 2);
      expect(raced.total, 3);
    });

    test('one server, or two lists that do not match, are left alone', () async {
      final group = parseLinks(['trojan://a@1.1.1.1:1001?sni=x.example#only']);
      expect((await raceGroup(group, group, probe: _probe({1001: 5}))).group, group);
      final two = parseLinks([
        'trojan://a@1.1.1.1:1001?sni=x.example#a',
        'trojan://b@2.2.2.2:1002?sni=x.example#b',
      ]);
      expect((await raceGroup(two, [two.first], probe: _probe({}))).group, two);
    });
  });

  test('a real connect: a listening port answers, a closed one fails', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final open = await tcpProbe('127.0.0.1', server.port, const Duration(seconds: 2));
    expect(open, greaterThanOrEqualTo(0));
    final port = server.port;
    await server.close();
    expect(await tcpProbe('127.0.0.1', port, const Duration(seconds: 2)), -1);
  });
}
