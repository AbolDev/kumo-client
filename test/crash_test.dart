import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/usage/crash_hub.dart';
import 'package:kumo/core/usage/crash_report.dart';
import 'package:kumo/core/usage/crash_scrub.dart';
import 'package:kumo/core/usage/usage_endpoints.dart';
import 'package:kumo/core/usage/usage_ping.dart';
import 'package:kumo/core/usage/usage_reporter.dart' show PingMethod;

class CrashRig {
  CrashRig({this.on = true, this.os = 'windows', this.maxPerRun = 5, this.maxPerDay = 10, this.maxQueue = 10}) {
    reporter = _make();
  }

  bool on;
  final String os;
  final int maxPerRun, maxPerDay, maxQueue;
  final files = <String, String>{};
  final sent = <({String host, PingMethod method, Map<String, Object> body})>[];
  DateTime clock = DateTime.utc(2026, 11, 8, 10);
  Future<int?> Function(UsageEndpoint, PingMethod) answer = (_, __) async => 200;
  String? screen = '/LogsPage';
  String? vpn = 'connected';
  List<String> logLines = ['10:00:01 Connected', '10:00:02 Tick'];
  List<String> hosts = ['secret-server.example.net'];
  late CrashReporter reporter;

  CrashReporter _make() => CrashReporter(
        read: (n) async => files[n],
        write: (n, c) async => files[n] = c,
        send: (e, b, m) {
          sent.add((host: e.host, method: m, body: b));
          return answer(e, m);
        },
        enabled: () => on,
        deviceId: () async => 'a' * 64,
        os: os,
        osVersion: () async => '10.0 (Build 26100)',
        appVersion: () async => '1.12.1',
        endpoints: () => const [UsageEndpoint('a.example.com'), UsageEndpoint('b.example.com')],
        facts: () async => const DeviceFacts(arch: 'x64', brand: 'Dell Inc.', model: 'XPS 15', build: 'kumo-windows-x64-setup.exe', lang: 'fa'),
        screen: () => screen,
        vpnState: () => vpn,
        logLines: () => logLines,
        hosts: () => hosts,
        now: () => clock,
        maxPerRun: maxPerRun,
        maxPerDay: maxPerDay,
        maxQueue: maxQueue,
      );

  /// A new run of the app: the same files, a new reporter.
  CrashRig restarted() {
    final r = CrashRig(on: on, os: os, maxPerRun: maxPerRun, maxPerDay: maxPerDay, maxQueue: maxQueue);
    r.files.addAll(files);
    r.clock = clock;
    return r;
  }
}

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('the scrubber', () {
    test('links keep only their scheme', () {
      expect(scrubText('failed vless://abc@host.example:443?x=1#name now'), 'failed vless://<redacted> now');
      expect(scrubText('GET https://sub.example.com/api/sub?token=abc123 failed'), 'GET https://<redacted> failed');
    });

    test('addresses, e-mail, uuid', () {
      expect(scrubText('connect 203.0.113.7:443 failed'), 'connect <ip> failed');
      expect(scrubText('to 2001:db8::1 and ::1 and fe80::1ff:fe23:4567:890a'), 'to <ip> and <ip> and <ip>');
      expect(scrubText('mail me@example.com ok'), 'mail <email> ok');
      expect(scrubText('id 123e4567-e89b-12d3-a456-426614174000 end'), 'id <uuid> end');
    });

    test('long tokens go, ordinary text, times and versions stay', () {
      expect(scrubText('key ${'a1' * 20}'), contains('<token>'));
      expect(scrubText('Authorization: Bearer abc'), contains('<redacted>'));
      expect(scrubText('12:34:56 Connected 1.12.1 (Build 26100) 10.0.26300'), '12:34:56 Connected 1.12.1 (Build 26100) 10.0.26300');
      expect(scrubText('some_long_name_of_a_function_without_digits_in_it_at_all'), 'some_long_name_of_a_function_without_digits_in_it_at_all');
      expect(scrubText('300.1.1.1 stays'), '300.1.1.1 stays');
    });

    test('user names in folder paths', () {
      expect(scrubText(r'C:\Users\Bagheri\AppData\x'), r'C:\Users\<user>\AppData\x');
      expect(scrubText('C:/Users/Ali Reza/x'), contains('C:/Users/<user>'));
      expect(scrubText('/Users/sara/Library/x'), '/Users/<user>/Library/x');
      expect(scrubText('/home/bob/.config/kumo'), '/home/<user>/.config/kumo');
    });

    test('the names of the user\'s servers, with their port', () {
      expect(scrubText('handshake with Secret-Server.example.net:8443 failed', hosts: ['secret-server.example.net']),
          'handshake with <host> failed');
      expect(scrubText('dns for my-sub.example.org', hosts: ['my-sub.example.org', 'ab']), 'dns for <host>');
    });

    test('passwords and keys', () {
      expect(scrubText('password=hunter2 next'), 'password=<redacted> next');
      expect(scrubText('{"uuid":"x","password":"p@ss w0rd","a":1}'), contains('"password":<redacted>'));
      expect(scrubText('secret: abc'), 'secret: <redacted>');
    });

    test('code locations, error types and build ids survive', () {
      const stack = '''
#0      _AppState.log (package:kumo/state/app_state.dart:145:5)
#1      UsageReporter.tick (package:kumo/core/usage/usage_reporter.dart:228:14)
#2      _rootRun (dart:async/zone.dart:1399:13)
*** *** ***
build_id: '0123456789abcdef0123456789abcdef01234567'
#00 abs 00007ff6c8b9d2e8 virt 00000000009d12e8 _kDartIsolateSnapshotInstructions+0x1a2b3c
at app.kumo.vpn.BoxVpnService.start(BoxVpnService.kt:12)''';
      expect(scrubText(stack), stack);
      expect(scrubText('StateError: Bad state (package:kumo/main.dart:12:3)'), 'StateError: Bad state (package:kumo/main.dart:12:3)');
    });
  });

  group('the body of a report', () {
    Map<String, Object> make({String? stack, String? log, String message = 'boom', String kind = 'StateError', String os = 'windows', String? screen, String? vpn, DeviceFacts facts = const DeviceFacts()}) =>
        buildCrashBody(
            os: os,
            appVersion: '1.12.1',
            kind: kind,
            message: message,
            id: 'b' * 64,
            osVersion: '10.0 (Build 26100)',
            facts: facts,
            screen: screen,
            vpnState: vpn,
            core: '1.11.4',
            stack: stack,
            log: log);

    test('every field passes the patterns', () {
      final b = make(
          stack: '#0 main (package:kumo/main.dart:1:1)',
          log: '10:00:00 hello',
          screen: '/LogsPage',
          vpn: 'connected',
          facts: const DeviceFacts(arch: 'x64', brand: 'Dell Inc.', model: 'XPS 15', build: 'kumo-windows-x64-setup.exe', lang: 'fa'));
      expect(b['v'], 1);
      expect(b['os'], 'windows');
      expect(b['app_version'], '1.12.1');
      expect(b['kind'], 'StateError');
      expect(b['fatal'], false);
      expect(b['id'], matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(b['screen'], '/LogsPage');
      expect(b['vpn_state'], 'connected');
      expect(b['core'], '1.11.4');
      expect(b['arch'], 'x64');
      expect(b['brand'], 'Dell Inc.');
      expect(b['model'], 'XPS 15');
      expect(b['build'], 'kumo-windows-x64-setup.exe');
      expect(b.containsKey('lang'), isFalse); // the language is not part of a report
      expect(utf8.encode(jsonEncode(b)).length, lessThanOrEqualTo(crashMaxBytes));
    });

    test('texts are cut: message and stack keep the start, the log keeps the end', () {
      final b = make(message: 'm' * 3000, stack: 's' * 20000, log: 'a' * 6000 + 'END');
      expect((b['message'] as String).length, crashMaxMessage);
      expect((b['stack'] as String).length, crashMaxStack);
      final log = b['log'] as String;
      expect(log.length, crashMaxLog);
      expect(log.endsWith('END'), isTrue);
    });

    test('a body of other scripts still fits the limit of the server', () {
      final b = make(message: 'خ' * 1000, stack: 'ب' * 8000, log: 'ج' * 4000);
      expect(utf8.encode(jsonEncode(b)).length, lessThanOrEqualTo(crashMaxBytes));
      expect(b['message'], isNotEmpty);
    });

    test('kind, screen and vpn state are made to fit; needed fields are checked', () {
      expect(cleanKind('_Map<String, dynamic>'), '_Map_String_dynamic');
      expect(cleanKind(''), 'Error');
      expect(cleanKind('x' * 200), hasLength(80));
      expect(cleanScreen('/servers?id=7&x=1'), '/servers');
      expect(cleanScreen('page#dialog'), 'page#dialog');
      expect(cleanScreen('a b'), 'a_b');
      expect(cleanScreen('x' * 100), hasLength(60));
      expect(make(vpn: 'weird')['vpn_state'], 'unknown');
      expect(make(vpn: null)['vpn_state'], 'unknown');
      expect(() => buildCrashBody(os: 'plan9', appVersion: '1.0.0', kind: 'k', message: 'm'), throwsA(isA<PingException>()));
      expect(() => buildCrashBody(os: 'linux', appVersion: 'x', kind: 'k', message: 'm'), throwsA(isA<PingException>()));
      expect(make(message: '')['message'], 'StateError'); // never empty
    });

    test('a build of another system is dropped, and the texts are scrubbed', () {
      final b = make(
          message: 'failed vless://u@h.example:1 for me@example.com',
          stack: '#0 f (package:kumo/a.dart:1:2)\nat C:\\Users\\Bob\\x',
          log: 'ip 203.0.113.9',
          facts: const DeviceFacts(build: 'kumo-android-universal.apk'));
      expect(b.containsKey('build'), isFalse);
      expect(b['message'], 'failed vless://<redacted> for <email>');
      expect(b['stack'], contains(r'C:\Users\<user>'));
      expect(b['log'], 'ip <ip>');
      expect(jsonEncode(b), isNot(contains('Bob')));
    });
  });

  group('the queue and the limits', () {
    test('a fatal crash is written to disk and sent at the next start', () async {
      final r = CrashRig()..answer = (_, __) async => null; // offline
      await r.reporter.record(kind: 'native_crash', message: 'boom', stack: '#0 f (package:kumo/a.dart:1:1)', fatal: true);
      await settle();
      expect(r.reporter.queued, hasLength(1));
      final saved = jsonDecode(r.files[CrashReporter.file]!) as Map;
      expect((saved['queue'] as List).single['fatal'], true);
      // The next run, online:
      final next = r.restarted();
      expect(await next.reporter.flush(), isTrue);
      expect(next.sent, hasLength(1));
      expect(next.sent.single.body['kind'], 'native_crash');
      expect(next.reporter.queued, isEmpty);
      final after = jsonDecode(next.files[CrashReporter.file]!) as Map;
      expect(after['queue'], isEmpty);
    });

    test('the report carries the page, the VPN state and the log, scrubbed of the server name', () async {
      final r = CrashRig()
        ..logLines = ['10:00:01 connecting secret-server.example.net:443', '10:00:02 failed']
        ..screen = '/#dialog';
      await r.reporter.record(kind: 'StateError', message: 'bad secret-server.example.net');
      await settle();
      final b = r.sent.single.body;
      expect(b['screen'], '/#dialog');
      expect(b['vpn_state'], 'connected');
      expect(b['log'], '10:00:01 connecting <host>\n10:00:02 failed');
      expect(b['message'], 'bad <host>');
    });

    test('the queue holds ten, the oldest dropped', () async {
      final r = CrashRig(maxPerRun: 99, maxPerDay: 99)..answer = (_, __) async => null;
      for (var i = 0; i < 13; i++) {
        await r.reporter.record(kind: 'E$i', message: 'm$i');
      }
      expect(r.reporter.queued, hasLength(10));
      expect(r.reporter.queued.first['kind'], 'E3');
      expect(r.reporter.queued.last['kind'], 'E12');
    });

    test('the same error is reported once per run', () async {
      final r = CrashRig();
      for (var i = 0; i < 4; i++) {
        await r.reporter.record(kind: 'StateError', message: 'same', stack: '#0 f (package:kumo/a.dart:1:1)');
      }
      await settle();
      expect(r.sent, hasLength(1));
      await r.reporter.record(kind: 'StateError', message: 'other');
      await settle();
      expect(r.sent, hasLength(2));
    });

    test('at most 5 a run, and 10 a day (a new day starts again)', () async {
      final r = CrashRig();
      for (var i = 0; i < 9; i++) {
        await r.reporter.record(kind: 'E$i', message: 'm$i');
      }
      await settle();
      expect(r.sent, hasLength(5));
      // Runs 2 and 3 of the same day: 5 more get through, then the day's 10 are used.
      final run2 = r.restarted();
      for (var i = 10; i < 17; i++) {
        await run2.reporter.record(kind: 'E$i', message: 'm$i');
      }
      await settle();
      expect(run2.sent, hasLength(5));
      final run3 = run2.restarted();
      await run3.reporter.record(kind: 'late', message: 'x');
      await settle();
      expect(run3.sent, isEmpty);
      // Tomorrow:
      final tomorrow = run3.restarted()..clock = DateTime.utc(2026, 11, 9, 1);
      await tomorrow.reporter.record(kind: 'new', message: 'x');
      await settle();
      expect(tomorrow.sent, hasLength(1));
    });
  });

  group('the switch', () {
    test('off: nothing is queued or sent', () async {
      final r = CrashRig(on: false);
      await r.reporter.record(kind: 'E', message: 'm', fatal: true);
      await settle();
      expect(r.sent, isEmpty);
      expect(r.reporter.queued, isEmpty);
      expect(r.files[CrashReporter.file], isNull);
    });

    test('a waiting report is dropped when the user turned it off before it was sent', () async {
      final r = CrashRig()..answer = (_, __) async => null;
      await r.reporter.record(kind: 'E', message: 'm');
      await settle();
      expect(r.reporter.queued, hasLength(1));
      final next = r.restarted()..on = false;
      r.sent.clear();
      expect(await next.reporter.flush(), isTrue);
      expect(next.sent, isEmpty);
      expect(next.reporter.queued, isEmpty);
      expect(((jsonDecode(next.files[CrashReporter.file]!) as Map)['queue'] as List), isEmpty);
    });

    test('discard() empties the queue and the file', () async {
      final r = CrashRig()..answer = (_, __) async => null;
      await r.reporter.record(kind: 'E', message: 'm');
      await settle();
      await r.reporter.discard();
      expect(r.reporter.queued, isEmpty);
      expect(((jsonDecode(r.files[CrashReporter.file]!) as Map)['queue'] as List), isEmpty);
    });
  });

  group('failures', () {
    test('offline: the report stays, nothing throws, the next flush sends it', () async {
      final r = CrashRig()..answer = (_, __) async => null;
      await r.reporter.record(kind: 'E', message: 'm');
      await settle();
      expect(r.reporter.queued, hasLength(1));
      expect(await r.reporter.flush(), isFalse);
      r.answer = (_, __) async => 200;
      expect(await r.reporter.flush(), isTrue);
      expect(r.reporter.queued, isEmpty);
    });

    test('400: the report is dropped, not sent again', () async {
      final r = CrashRig()..answer = (_, __) async => 400;
      await r.reporter.record(kind: 'E', message: 'm');
      await settle();
      expect(r.sent, hasLength(1));
      expect(r.reporter.queued, isEmpty);
    });

    test('429: one request, no other route, the report stays for the normal schedule', () async {
      final r = CrashRig()..answer = (_, __) async => 429;
      await r.reporter.record(kind: 'E', message: 'm');
      await settle();
      expect(r.sent, hasLength(1));
      expect(r.reporter.queued, hasLength(1));
      expect(await r.reporter.flush(), isFalse);
      expect(r.sent, hasLength(2)); // one request per flush, never a loop
    });

    test('5xx and a thrown error move on to the next route, then keep the report', () async {
      final r = CrashRig();
      r.answer = (e, m) async => e.host == 'a.example.com' && m == PingMethod.direct ? 503 : throw StateError('x');
      await r.reporter.record(kind: 'E', message: 'm');
      await settle();
      expect(r.sent.length, 4); // two addresses, direct and fragmented
      expect(r.reporter.queued, hasLength(1));
    });

    test('a later route is used when the first fails', () async {
      final r = CrashRig()..answer = (e, m) async => m == PingMethod.direct ? null : 200;
      await r.reporter.record(kind: 'E', message: 'm');
      await settle();
      expect(r.sent.last.method, PingMethod.fragment);
      expect(r.reporter.queued, isEmpty);
    });

    test('recording does not wait for the network', () async {
      final r = CrashRig();
      final never = Completer<int?>();
      r.answer = (_, __) => never.future;
      await r.reporter.record(kind: 'E', message: 'm').timeout(const Duration(seconds: 2));
      expect(r.reporter.queued, hasLength(1));
    });

    test('record never throws, whatever the parts do', () async {
      final r = CrashReporter(
        read: (n) async => throw StateError('read'),
        write: (n, c) async => throw StateError('write'),
        send: (e, b, m) async => throw StateError('send'),
        enabled: () => true,
        deviceId: () async => throw StateError('id'),
        os: 'linux',
        osVersion: () async => throw StateError('os'),
        appVersion: () async => '1.12.1',
        endpoints: () => const [UsageEndpoint('a.example.com')],
        facts: () async => throw StateError('facts'),
        hosts: () => throw StateError('hosts'),
      );
      await r.record(kind: 'E', message: 'm');
    });
  });

  group('crashes of the phone\'s own process', () {
    const text = 'Sat Nov 08 10:00:00 GMT 2026 main\njava.lang.NullPointerException: boom\n\tat app.kumo.vpn.App.x(App.kt:5)';

    test('queued once as a fatal report, and not again for the same crash', () async {
      final r = CrashRig(os: 'linux')..answer = (_, __) async => null;
      await r.reporter.importNative(text);
      expect(r.reporter.queued, hasLength(1));
      final b = r.reporter.queued.single;
      expect(b['kind'], 'native_crash');
      expect(b['fatal'], true);
      expect(b['message'], 'java.lang.NullPointerException: boom');
      expect(b['stack'], contains('app.kumo.vpn.App.x(App.kt:5)'));
      final next = r.restarted();
      await next.reporter.importNative(text);
      expect(next.reporter.queued, hasLength(1)); // the one that was waiting, not a second
      await next.reporter.importNative(null);
      await next.reporter.importNative('  ');
      expect(next.reporter.queued, hasLength(1));
    });
  });

  group('the page the user is on', () {
    testWidgets('named pages, and a dialog on top of one', (tester) async {
      final tracker = RouteTracker();
      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(WidgetsApp(
        color: const Color(0xFF000000),
        navigatorKey: key,
        navigatorObservers: [tracker],
        builder: (context, child) => child!,
        onGenerateRoute: (s) => PageRouteBuilder<void>(
            settings: s, pageBuilder: (_, __, ___) => const SizedBox()),
      ));
      expect(tracker.current, '/');
      key.currentState!.push(PageRouteBuilder<void>(
          settings: const RouteSettings(name: '/LogsPage'), pageBuilder: (_, __, ___) => const SizedBox()));
      await tester.pumpAndSettle();
      expect(tracker.current, '/LogsPage');
      key.currentState!.push(RawDialogRoute<void>(pageBuilder: (_, __, ___) => const SizedBox()));
      await tester.pumpAndSettle();
      expect(tracker.current, '/LogsPage#dialog');
      key.currentState!.pop();
      await tester.pumpAndSettle();
      key.currentState!.pop();
      await tester.pumpAndSettle();
      expect(tracker.current, '/');
    });

    test('CrashHub without a reporter does nothing', () {
      CrashHub.sink = null;
      CrashHub.report(StateError('x'), StackTrace.current);
    });
  });
}
