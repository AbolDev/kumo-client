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
