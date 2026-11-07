import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/usage/usage_endpoints.dart';
import 'package:kumo/core/usage/usage_ping.dart';
import 'package:kumo/core/usage/usage_reporter.dart';
import 'package:kumo/core/warp/warp_signature.dart';

typedef Call = ({String host, PingMethod method, Map<String, Object> body});

class Rig {
  Rig({this.tunnel = false, this.sysId = 'machine-guid-1', this.version = '1.12.0-beta.11'}) {
    reporter = UsageReporter(
      read: (n) async => files[n],
      write: (n, c) async => files[n] = c,
      send: (e, b, m) async {
        calls.add((host: e.host, method: m, body: b));
        return answer(e, m);
      },
      systemId: () async => sysId,
      os: 'windows',
      osVersion: () async => '"Windows 10 Pro" 10.0 (Build 26100)',
      appVersion: () async => version,
      tunnelUp: () => tunnel,
      endpoints: () => const [UsageEndpoint('a.example.com'), UsageEndpoint('b.example.com')],
      countryHint: () => 'IR',
      now: () => clock,
    );
  }

  final files = <String, String>{};
  final calls = <Call>[];
  late final UsageReporter reporter;
  bool tunnel;
  String? sysId;
  String version;
  DateTime clock = DateTime.utc(2026, 11, 7, 10);
  int? Function(UsageEndpoint, PingMethod) answer = (_, __) => 200;
}

void main() {
  group('the ping body', () {
    final id = hashDeviceId('abc');

    test('the id is a salted SHA-256: 64 lower-case hex characters, not the raw id', () {
      expect(id, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(id, isNot(contains('abc')));
      expect(hashDeviceId(' ABC '), id);
      expect(hashDeviceId('abd'), isNot(id));
    });

    test('a valid body fits the limits of the server', () {
      final b = buildPing(
          event: 'ping', id: id, os: 'android', appVersion: '1.12.0', osVersion: '14 (API 34)');
      expect(b, {
        'v': 1,
        'event': 'ping',
        'id': id,
        'os': 'android',
        'os_version': '14 (API 34)',
        'app_version': '1.12.0',
        'via_tunnel': false,
      });
      expect(utf8.encode(jsonEncode(b)).length, lessThanOrEqualTo(pingMaxBytes));
    });

    test('what the server would refuse is never built', () {
      expect(() => buildPing(event: 'x', id: id, os: 'windows', appVersion: '1.0.0'), throwsA(isA<PingException>()));
      expect(() => buildPing(event: 'ping', id: 'ABC', os: 'windows', appVersion: '1.0.0'), throwsA(isA<PingException>()));
      expect(() => buildPing(event: 'ping', id: id, os: 'beos', appVersion: '1.0.0'), throwsA(isA<PingException>()));
      expect(() => buildPing(event: 'ping', id: id, os: 'linux', appVersion: '1.0'), throwsA(isA<PingException>()));
      expect(isPingAppVersion('1.12.0-beta.7'), isTrue);
      expect(isPingAppVersion('1.12.0-beta.11+43'), isTrue);
      expect(isPingAppVersion('v1.12.0'), isFalse);
    });

    test('the system version is cut to the characters and the length the server takes', () {
      expect(cleanOsVersion('"Windows 10 Pro" 10.0 (Build 26100)'), 'Windows 10 Pro 10.0 (Build 26100)');
      expect(cleanOsVersion('x' * 100)!.length, 64);
      expect(cleanOsVersion('<>'), isNull);
      expect(cleanOsVersion(null), isNull);
      final b = buildPing(event: 'ping', id: id, os: 'linux', appVersion: '1.0.0', osVersion: '<script>');
      expect(b['os_version'], 'script');
    });

    test('the country goes only with a ping from inside the tunnel, and only a real one', () {
      Map<String, Object> make(bool tunnel, String? c) =>
          buildPing(event: 'ping', id: id, os: 'linux', appVersion: '1.0.0', viaTunnel: tunnel, country: c);
      expect(make(false, 'IR').containsKey('country'), isFalse);
      expect(make(true, 'IR')['country'], 'IR');
      expect(make(true, 'XX').containsKey('country'), isFalse);
      expect(make(true, 'T1').containsKey('country'), isFalse);
      expect(make(true, 'ir').containsKey('country'), isFalse);
      expect(make(true, null).containsKey('country'), isFalse);
      expect(make(true, 'IR')['via_tunnel'], isTrue);
    });
  });

  group('sending', () {
    test('a first ping goes out, once, and the same day it is not repeated', () async {
      final r = Rig();
      expect(await r.reporter.tick(), isTrue);
      expect(r.calls, hasLength(1));
      expect(r.calls.first.body['event'], 'ping');
      expect(r.calls.first.body['id'], hashDeviceId('machine-guid-1'));
      expect(await r.reporter.tick(), isTrue);
      expect(r.calls, hasLength(1));
    });

    test('the next day it goes again, and the same day again after a new version', () async {
      final r = Rig();
      await r.reporter.tick();
      r.clock = DateTime.utc(2026, 11, 8, 1);
      await r.reporter.tick();
      expect(r.calls, hasLength(2));
      r.version = '1.12.0';
      await r.reporter.tick();
      expect(r.calls, hasLength(3));
      expect(r.calls.last.body['app_version'], '1.12.0');
      await r.reporter.tick();
      expect(r.calls, hasLength(3));
    });

    test('the once-a-day record survives a restart', () async {
      final r = Rig();
      await r.reporter.tick();
      final again = Rig()..files.addAll(r.files);
      await again.reporter.tick();
      expect(again.calls, isEmpty);
    });

    test('with no system id a random one is kept and stays the same', () async {
      final r = Rig(sysId: null);
      await r.reporter.tick();
      final id = r.calls.first.body['id'] as String;
      expect(id, matches(RegExp(r'^[0-9a-f]{64}$')));
      final again = Rig(sysId: null)..files.addAll(r.files);
      again.clock = DateTime.utc(2026, 11, 9);
      await again.reporter.tick();
      expect(again.calls.first.body['id'], id);
    });

    test('turning it off sends one opt_out and then nothing, even after a restart', () async {
      final r = Rig();
      await r.reporter.tick();
      await r.reporter.setEnabled(false);
      r.calls.clear();
      expect(await r.reporter.tick(), isTrue);
      expect(r.calls, hasLength(1));
      expect(r.calls.first.body['event'], 'opt_out');
      expect(r.calls.first.body['id'], hashDeviceId('machine-guid-1'));
      r.clock = DateTime.utc(2026, 12, 1);
      await r.reporter.tick();
      await r.reporter.tick();
      expect(r.calls, hasLength(1));
      final again = Rig()..files.addAll(r.files);
      await again.reporter.tick();
      expect(again.calls, isEmpty);
      expect(again.reporter.enabled, isFalse);
    });

    test('an opt_out that did not get through is tried again, not forgotten', () async {
      final r = Rig()..answer = (_, __) => null;
      await r.reporter.setEnabled(false);
      expect(await r.reporter.tick(), isFalse);
      r.answer = (_, __) => 200;
      r.calls.clear();
      expect(await r.reporter.tick(), isTrue);
      expect(r.calls.single.body['event'], 'opt_out');
    });

    test('turned on again, a ping is sent again the same day', () async {
      final r = Rig();
      await r.reporter.tick();
      await r.reporter.setEnabled(false);
      await r.reporter.tick();
      await r.reporter.setEnabled(true);
      r.calls.clear();
      await r.reporter.tick();
      expect(r.calls.single.body['event'], 'ping');
    });

    test('off from the start sends nothing but the one opt_out', () async {
      final r = Rig();
      r.files[UsageReporter.file] = jsonEncode({'enabled': false, 'opt_out_sent': true});
      await r.reporter.tick();
      expect(r.calls, isEmpty);
    });
  });

  group('the way a ping travels', () {
    test('outside the tunnel: direct on the first endpoint, then the second, then fragmented', () async {
      final r = Rig()..answer = (_, __) => null;
      expect(await r.reporter.tick(), isFalse);
      expect([for (final c in r.calls) '${c.host}/${c.method.name}'], [
        'a.example.com/direct',
        'b.example.com/direct',
        'a.example.com/fragment',
        'b.example.com/fragment',
      ]);
      expect(r.calls.every((c) => c.body['via_tunnel'] == false && !c.body.containsKey('country')), isTrue);
    });

    test('a later route is used when the earlier ones fail, and a success stops the tries', () async {
      final r = Rig()..answer = (e, m) => m == PingMethod.fragment && e.host == 'a.example.com' ? 200 : null;
      expect(await r.reporter.tick(), isTrue);
      expect(r.calls, hasLength(3));
      expect(await r.reporter.tick(), isTrue);
      expect(r.calls, hasLength(3));
    });

    test('a failure is not recorded, so the ping is tried again', () async {
      final r = Rig()..answer = (_, __) => 503;
      expect(await r.reporter.tick(), isFalse);
      r.answer = (_, __) => 200;
      r.calls.clear();
      expect(await r.reporter.tick(), isTrue);
      expect(r.calls, hasLength(1));
    });

    test('a refusal by the server (400) is final for the day: no other route, no retry', () async {
      final r = Rig()..answer = (_, __) => 400;
      expect(await r.reporter.tick(), isTrue);
      expect(r.calls, hasLength(1));
      await r.reporter.tick();
      expect(r.calls, hasLength(1));
    });

    test('through the tunnel the ping says so and carries the last country seen outside it', () async {
      final r = Rig();
      await r.reporter.tick(); // outside: remembers the country
      r.tunnel = true;
      r.clock = DateTime.utc(2026, 11, 8);
      await r.reporter.tick();
      final last = r.calls.last.body;
      expect(last['via_tunnel'], isTrue);
      expect(last['country'], 'IR');
    });

    test('an exception in the transport never escapes', () async {
      final r = Rig()..answer = (_, __) => throw StateError('boom');
      expect(await r.reporter.tick(), isFalse);
    });
  });

  group('the signed list of addresses', () {
    final (priv, pub) = newWarpKeyPair();
    final other = newWarpKeyPair();
    String list({int version = 2, String expires = '2099-01-01T00:00:00Z', String keyId = 't1', String host = 'x.example.com'}) =>
        jsonEncode({
          'schema': 1,
          'version': version,
          'issued_at': '2026-11-01T00:00:00Z',
          'expires_at': expires,
          'key_id': keyId,
          'endpoints': [
            {'host': host},
          ],
        });

    UsageEndpointStore store(Map<String, String> files, Map<String, String> net, {Map<String, String>? keys}) =>
        UsageEndpointStore(
          read: (n) async => files[n],
          write: (n, c) async => files[n] = c,
          fetch: (u) async => net[u] ?? (throw Exception('offline')),
          keys: keys ?? {'t1': pub},
          now: () => DateTime.utc(2026, 11, 7),
        );

    test('the built-in list holds the two addresses, workers.dev first', () {
      expect([for (final e in builtInUsageEndpoints.endpoints) e.host],
          ['kumo-api.kumoapp.workers.dev', 'api.kumo-client.ir']);
    });

    test('a list signed by the known key is taken, and kept for the next start', () async {
      final text = list(), url = usageEndpointUrls.first;
      final files = <String, String>{};
      final s = store(files, {url: text, '$url.sig': signWarp(utf8.encode(text), priv)});
      expect(await s.update(), isTrue);
      expect(s.current.endpoints.single.host, 'x.example.com');
      final next = store(files, {});
      await next.load();
      expect(next.current.version, 2);
    });

    test('a list with a wrong signature, an unknown key, an old version or past its date is refused', () async {
      final url = usageEndpointUrls.first;
      Future<bool> tryList(String text, String sig, {Map<String, String>? keys}) =>
          store({}, {url: text, '$url.sig': sig}, keys: keys).update();
      final good = list();
      expect(await tryList(good, signWarp(utf8.encode(good), other.$1)), isFalse);
      expect(await tryList(good, signWarp(utf8.encode(good), priv), keys: {}), isFalse);
      expect(await tryList(good.replaceAll('x.example', 'evil.example'), signWarp(utf8.encode(good), priv)), isFalse);
      final old = list(version: 0 + 1);
      final s = store({}, {url: old, '$url.sig': signWarp(utf8.encode(old), priv)});
      s.current = UsageEndpoints(
          version: 5,
          issuedAt: DateTime.utc(2026),
          expiresAt: DateTime.utc(2099),
          keyId: 't1',
          endpoints: const [UsageEndpoint('keep.example.com')]);
      expect(await s.update(), isFalse);
      expect(s.current.endpoints.single.host, 'keep.example.com');
      final expired = list(expires: '2026-11-02T00:00:00Z');
      expect(await tryList(expired, signWarp(utf8.encode(expired), priv)), isFalse);
    });

    test('the file is checked: only https hosts, nothing else', () {
      expect(() => parseUsageEndpoints(list(host: 'http://x.example.com')), throwsA(isA<UsageFormatException>()));
      expect(() => parseUsageEndpoints(list(host: 'x.example.com/path')), throwsA(isA<UsageFormatException>()));
      expect(() => parseUsageEndpoints(list(host: 'localhost')), throwsA(isA<UsageFormatException>()));
      expect(parseUsageEndpoints(list()).endpoints.single.host, 'x.example.com');
    });

    test('the second source is used when the first is not reachable', () async {
      final text = list(), sig = signWarp(utf8.encode(text), priv), url = usageEndpointUrls.last;
      final s = store({}, {url: text, '$url.sig': sig});
      expect(await s.update(), isTrue);
    });
  });
}
