import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/ovpn/ovpn_profile.dart';
import 'package:kumo/core/ovpn/ovpn_runner.dart';
import 'package:kumo/core/proxy_config.dart';

String _pem(String type) => '-----BEGIN $type-----\nMIIBfake\n-----END $type-----';

OvpnServer _server({bool login = false, String? user, String? pass}) {
  final text = '''
client
dev tun
remote 192.0.2.1 1194 udp
${login ? 'auth-user-pass' : ''}
<ca>
${_pem('CERTIFICATE')}
</ca>
${login ? '' : '<cert>\n${_pem('CERTIFICATE')}\n</cert>\n<key>\n${_pem('PRIVATE KEY')}\n</key>'}
''';
  return OvpnServer(parseOvpn(text), username: user, password: pass);
}

void main() {
  test('the adapters that openvpn lists are read', () {
    const out = "Available adapters [name, GUID, driver]:\n"
        "'Local Area Connection' {E64FDB88-5F19-4CD4-8329-7DF59B49CD2C} tap-windows6\n"
        "'KumoOpenVPN' {11111111-2222-3333-4444-555555555555} ovpn-dco\n"
        "garbage line\n";
    expect(parseAdapters(out), [('Local Area Connection', 'tap-windows6'), ('KumoOpenVPN', 'ovpn-dco')]);
    expect(parseAdapters(''), isEmpty);
  });

  test('the run adds the adapter, no routes from the server and a management port with a password file', () {
    final text = runConfig('client\ndev tun\n', managementPort: 41234, passwordFile: r'C:\Users\a b\mgmt.pw');
    expect(text, contains('dev-node KumoOpenVPN'));
    expect(text, contains('windows-driver tap-windows6'));
    expect(text, contains('route-nopull'));
    expect(text, contains('route 0.0.0.0 0.0.0.0 vpn_gateway 5000'));
    expect(text, contains(r'management 127.0.0.1 41234 "C:\\Users\\a b\\mgmt.pw"'));
    expect(text, contains('management-hold'));
    expect(text, contains('auth-retry nointeract'));
    expect(text, isNot(contains('redirect-gateway')));
  });

  group('the adapter and its driver', () {
    final dir = Directory.systemTemp.createTempSync('ovpn_driver');
    tearDownAll(() => dir.deleteSync(recursive: true));
    final exe = File('${dir.path}/openvpn.exe')..writeAsStringSync('x');
    final tapctl = File('${dir.path}/tapctl.exe')..writeAsStringSync('x');
    final driver = Directory('${dir.path}/driver')..createSync();
    File('${driver.path}/OemVista.inf').writeAsStringSync('x');

    const none = 'Available adapters [name, GUID, driver]:\n';
    const dco = "Available adapters [name, GUID, driver]:\n'KumoOpenVPN' {11111111-2222-3333-4444-555555555555} ovpn-dco\n";
    const have = "Available adapters [name, GUID, driver]:\n'KumoOpenVPN' {11111111-2222-3333-4444-555555555555} tap-windows6\n";

    /// A stand-in for the programs: [create] answers the successive `tapctl create` calls.
    ({OvpnRunner runner, List<String> calls, List<String> lines}) make(String adapters, List<int> create,
        {int pnputil = 0, bool withDriver = true}) {
      final calls = <String>[];
      final lines = <String>[];
      var n = 0;
      final runner = OvpnRunner(
        binary: exe.path,
        tapctl: tapctl.path,
        workDir: dir.path,
        driverDir: withDriver ? driver.path : null,
        run: (e, args) async {
          calls.add('${e.split(RegExp(r'[\\/]')).last} ${args.first}');
          lines.add('${e.split(RegExp(r'[\\/]')).last} ${args.join(' ')}');
          if (args.first == 'delete') return ProcessResult(0, 0, '', '');
          if (args.first == '--show-adapters') return ProcessResult(0, 0, adapters, '');
          if (args.first == 'create') return ProcessResult(0, create[n++], 'out', 'err');
          return ProcessResult(0, pnputil, 'installed', '');
        },
      );
      return (runner: runner, calls: calls, lines: lines);
    }

    test('an adapter that is there is used, and nothing is installed', () async {
      final m = make(have, []);
      await m.runner.ensureAdapter();
      expect(m.calls, ['openvpn.exe --show-adapters']);
    }, skip: !Platform.isWindows);

    test('the adapter is asked for with the TAP driver by name, whatever tapctl would choose', () async {
      final m = make(none, [0]);
      await m.runner.ensureAdapter();
      expect(m.lines.last, r'tapctl.exe create --name KumoOpenVPN --hwid root\tap0901');
    }, skip: !Platform.isWindows);

    test('an adapter of ours with another driver (ovpn-dco) is taken away and made again with TAP', () async {
      final m = make(dco, [0]);
      await m.runner.ensureAdapter();
      expect(m.lines, [
        'openvpn.exe --show-adapters',
        'tapctl.exe delete KumoOpenVPN',
        r'tapctl.exe create --name KumoOpenVPN --hwid root\tap0901',
      ]);
    }, skip: !Platform.isWindows);

    test('pnputil saying the package was there already (259) is not a failure', () async {
      final m = make(none, [1, 0], pnputil: 259);
      await m.runner.ensureAdapter();
      expect(m.calls.last, 'tapctl.exe create');
    }, skip: !Platform.isWindows);

    test('a missing adapter is made', () async {
      final m = make(none, [0]);
      await m.runner.ensureAdapter();
      expect(m.calls, ['openvpn.exe --show-adapters', 'tapctl.exe create']);
    }, skip: !Platform.isWindows);

    test('without the driver, it is put into Windows and the adapter is made again', () async {
      final m = make(none, [1, 0]);
      var said = false;
      m.runner.onInstallingDriver = () => said = true;
      await m.runner.ensureAdapter();
      expect(m.calls, ['openvpn.exe --show-adapters', 'tapctl.exe create', 'pnputil /add-driver', 'tapctl.exe create']);
      expect(said, isTrue);
    }, skip: !Platform.isWindows);

    test('a restart that is only advised (3010) is not a failure', () async {
      final m = make(none, [1, 0], pnputil: 3010);
      await m.runner.ensureAdapter();
      expect(m.calls.last, 'tapctl.exe create');
    }, skip: !Platform.isWindows);

    test('a driver that Windows refuses is the noDriver answer, with what Windows said', () async {
      final m = make(none, [1], pnputil: 5);
      try {
        await m.runner.ensureAdapter();
        fail('should throw');
      } on OvpnConnectException catch (e) {
        expect(e.failure, OvpnFailure.noDriver);
        expect(e.detail, contains('installed'));
      }
      expect(m.calls.where((c) => c == 'tapctl.exe create').length, 1, reason: 'no second try when the driver was refused');
    }, skip: !Platform.isWindows);

    test('no driver package next to the program is the noDriver answer', () async {
      final m = make(none, [1], withDriver: false);
      await expectLater(m.runner.ensureAdapter(),
          throwsA(isA<OvpnConnectException>().having((e) => e.failure, 'failure', OvpnFailure.noDriver)));
      expect(m.calls.where((c) => c.startsWith('pnputil')), isEmpty);
    }, skip: !Platform.isWindows);

    test('an adapter that still cannot be made after the driver went in is the noDriver answer', () async {
      final m = make(none, [1, 1]);
      await expectLater(m.runner.ensureAdapter(),
          throwsA(isA<OvpnConnectException>().having((e) => e.failure, 'failure', OvpnFailure.noDriver)));
    }, skip: !Platform.isWindows);
  });

  group('before anything is started', () {
    final dir = Directory.systemTemp.createTempSync('ovpn_runner');
    tearDownAll(() => dir.deleteSync(recursive: true));

    Future<OvpnFailure> failure(Future<Object?> Function() run) async {
      try {
        await run();
      } on OvpnConnectException catch (e) {
        return e.failure;
      }
      throw StateError('it did not fail');
    }

    test('a program that is not there', () async {
      final r = OvpnRunner(binary: '${dir.path}/nope.exe', tapctl: null, workDir: dir.path);
      expect(await failure(() => r.start(_server())), Platform.isWindows ? OvpnFailure.noBinary : OvpnFailure.unsupported);
    });

    test('a login that is not given is asked for, not tried', () async {
      final exe = File('${dir.path}/openvpn.exe')..writeAsStringSync('x');
      final r = OvpnRunner(binary: exe.path, tapctl: null, workDir: dir.path);
      expect(await failure(() => r.start(_server(login: true))), Platform.isWindows ? OvpnFailure.needsLogin : OvpnFailure.unsupported);
    });
  });

  // Needs the real OpenVPN (set KUMO_OVPN_BIN to its bin folder). Without the rights of an administrator
  // the adapter cannot be made, which is the "no driver" answer the screen shows.
  test('LIVE: the real program, without an adapter, is a clear failure and not a hang', () async {
    final bin = Platform.environment['KUMO_OVPN_BIN']!;
    final dir = Directory.systemTemp.createTempSync('ovpn_live');
    addTearDown(() => dir.deleteSync(recursive: true));
    final r = OvpnRunner(binary: '$bin\\openvpn.exe', tapctl: '$bin\\tapctl.exe', workDir: dir.path);
    try {
      await r.start(_server(), timeout: const Duration(seconds: 20));
      fail('it should not connect to a documentation address');
    } on OvpnConnectException catch (e) {
      expect([OvpnFailure.noDriver, OvpnFailure.timeout, OvpnFailure.exited], contains(e.failure), reason: '$e');
    }
    expect(r.running, isFalse);
    final run = Directory('${dir.path}/ovpn');
    expect(run.existsSync() ? run.listSync() : const [], isEmpty, reason: 'the files of the run (certificates) are removed');
  },
      skip: Platform.isWindows && Platform.environment['KUMO_OVPN_BIN'] != null
          ? false
          : 'needs KUMO_OVPN_BIN (the bin folder of an OpenVPN for Windows)',
      timeout: const Timeout(Duration(minutes: 1)));
}
