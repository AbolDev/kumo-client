import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/proxy_config.dart';
import 'package:kumo/core/singbox_config.dart';
import 'package:kumo/core/vpn_channel.dart';
import 'package:kumo/core/warp/warp_keys.dart';
import 'package:kumo/core/warp/warp_link.dart';
import 'package:kumo/core/warp/warp_profile.dart';
import 'package:kumo/core/warp/warp_register.dart';
import 'package:kumo/core/warp/warp_signature.dart';
import 'package:kumo/core/warp/x25519.dart';
import 'package:kumo/core/desktop_vpn.dart';
import 'package:kumo/state/app_state.dart';

List<int> _hex(String h) => [for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)];

const _account = WarpAccount(
  privateKey: 'yOe8Js2xW3Qq6x1VY0m8m7mCzJ8h0o4xkq1o2m8x2E8=',
  v4: '172.16.0.2',
  v6: '2606:4700:110:8e06:c070:af46:245b:5f84',
  peerPublicKey: 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=',
  reserved: [219, 200, 184],
);

WarpProfile _profile() => parseWarpProfile(File('docs/warp/profile.json').readAsStringSync());

void main() {
  // The tests keep their files in a folder of their own: AppState saves the servers and the usage, and
  // that must never reach the files of the user who runs the tests.
  late Directory dataDir;
  setUpAll(() {
    dataDir = Directory.systemTemp.createTempSync('kumo_test_data');
    DesktopVpn.dataDirOverride = dataDir.path;
  });
  tearDownAll(() {
    DesktopVpn.dataDirOverride = null;
    try {
      dataDir.deleteSync(recursive: true);
    } catch (_) {}
  });
  test('X25519 gives the answers of RFC 7748', () {
    final alice = _hex('77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a');
    final bob = _hex('5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb');
    final base = Uint8List(32)..[0] = 9;
    expect(x25519(alice, base), _hex('8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a'));
    expect(x25519(bob, base), _hex('de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f'));
    expect(
        x25519(alice, _hex('de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f')),
        _hex('4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742'));
  });

  test('a new WireGuard key pair has 32-byte keys', () {
    final (priv, pub) = newWireGuardKeys();
    expect(base64.decode(priv).length, 32);
    expect(base64.decode(pub).length, 32);
  });

  group('the profile in the repository', () {
    test('is signed with a key the app holds, and is valid', () {
      final data = File('docs/warp/profile.json').readAsBytesSync();
      final sig = File('docs/warp/profile.json.sig').readAsStringSync();
      final p = parseWarpProfile(utf8.decode(data));
      expect(verifyWarpSignature(data, sig, warpPublicKeys[p.keyId]!), isTrue);
      expect(p.usable(platform: 'windows', build: 30), isNotEmpty);
    });

    test('has no line ending git could change', () {
      expect(File('docs/warp/profile.json').readAsStringSync().contains('\r'), isFalse);
      expect(File('.gitattributes').readAsStringSync(), contains('docs/warp/* -text'));
    });
  });

  group('the link of an account', () {
    final p = _profile();
    final noise = p.usable(platform: 'windows', build: 30).firstWhere((m) => m.kind == 'wg-noise');
    final plain = p.usable(platform: 'windows', build: 30).firstWhere((m) => m.kind == 'wg-plain');

    test('with noise it is carried by Xray only', () {
      final link = warpLink(_account, noise, p.endpoints.first, 0);
      final c = parseLink(link)!;
      expect(c.needsXray, isTrue);
      expect(c.canSingBox, isFalse);
      expect(c.label, 'wireguard + noise');
      expect(c.host, p.endpoints.first.ip);
      expect(c.name, 'WARP');
    });

    test('without noise it is a plain WireGuard server for both cores', () {
      final c = parseLink(warpLink(_account, plain, p.endpoints.first, 0))!;
      expect(c.canSingBox, isTrue);
      expect(c.canXray, isTrue);
      expect(c.outbound['type'], 'wireguard');
      expect((c.outbound['peers'] as List).first['reserved'], [219, 200, 184]);
    });

    test('the port index wraps round the ports of the endpoint', () {
      final e = p.endpoints.first;
      expect(parseLink(warpLink(_account, plain, e, e.ports.length))!.port, e.ports.first);
      expect(parseLink(warpLink(_account, plain, e, 1))!.port, e.ports[1]);
    });

    test('noise outside the limits makes the link unusable', () {
      final link = warpLink(_account, plain, p.endpoints.first, 0).split('#').first;
      expect(parseLink('$link&noise=rand~10-9000~5-10'), isNull);
      expect(parseLink('$link&noise=rand~10-30~5-900'), isNull);
      expect(parseLink('$link&noise=zip~10-30~5-10'), isNull);
      expect(parseLink('$link&noise=${List.filled(6, 'rand~1-2~1-2').join(',')}'), isNull);
    });

    test('the Xray configuration sends the noise through a relay of its own', () {
      final c = parseLink(warpLink(_account, noise, p.endpoints.first, 0))!;
      final j = jsonDecode(buildXrayConfig(c, 31000)) as Map<String, dynamic>;
      final relay = (j['inbounds'] as List).firstWhere((i) => i['tag'] == 'noise-in');
      expect(relay['protocol'], 'dokodemo-door');
      expect(relay['port'], 31001);
      expect(relay['settings'], {'address': '162.159.192.1', 'port': 2408, 'network': 'udp'});
      final out = (j['outbounds'] as List).firstWhere((o) => o['tag'] == 'noise-out');
      expect(out['protocol'], 'freedom');
      expect(out['settings']['noises'], [
        {'type': 'rand', 'packet': '10-30', 'delay': '5-10'},
      ]);
      final wg = (j['outbounds'] as List).firstWhere((o) => o['tag'] == 'proxy');
      expect(wg['protocol'], 'wireguard');
      expect(wg['settings']['peers'][0]['endpoint'], '127.0.0.1:31001');
      expect(wg['settings']['reserved'], [219, 200, 184]);
      expect(wg.containsKey('_noise'), isFalse);
      expect(jsonEncode(j['routing']), contains('noise-out'));
    });
  });

  group('the WARP group', () {
    final p = _profile();
    final method = p.usable(platform: 'windows', build: 30).firstWhere((m) => m.kind == 'wg-noise');

    ProxyConfig make(int port) => parseLink(warpLink(_account, method, p.endpoints.first, port))!;

    AppState on() {
      final s = AppState();
      s.warp.enabled = true;
      return s;
    }

    test('is a group of its own while WARP is on, and not while it is off', () {
      final s = on();
      s.setWarpServer(make(0));
      expect(s.groups.map((g) => g.kind), contains(GroupKind.warp));
      expect(s.manual.configs, isEmpty);
      s.warp.enabled = false;
      expect(s.groups.map((g) => g.kind), isNot(contains(GroupKind.warp)));
    });

    test('is replaced by the next one and stays the chosen one', () {
      final s = on();
      final first = make(0);
      s.setWarpServer(first, choose: true);
      expect(identical(s.selected, first), isTrue);
      final second = make(1);
      s.setWarpServer(second);
      expect(s.warpGroup.configs, [second]);
      expect(identical(s.selected, second), isTrue);
    });

    test('an unchosen one stays unchosen; emptying the group drops the choice of it', () {
      final s = on();
      final first = make(0);
      s.setWarpServer(first);
      expect(s.selected, isNull);
      s.setWarpServer(first, choose: true);
      s.setWarpServer(null);
      expect(s.warpGroup.configs, isEmpty);
      expect(s.selected, isNull);
    });

    test('a copy kept by hand by an earlier version moves to the group, with the choice', () {
      final s = on();
      final old = make(0);
      s.manual.configs.add(old);
      s.selected = old;
      s.restoreWarpServer(make(0));
      expect(s.manual.configs, isEmpty);
      expect(s.warpGroup.configs.length, 1);
      expect(identical(s.selected, s.warpGroup.configs.first), isTrue);
    });

    test('what goes through the chosen WARP server is counted, and nothing else', () {
      final s = on();
      s.collector.configs.addAll(parseLinks(['vless://11111111-1111-1111-1111-111111111111@v.example.com:443?security=tls#Free one']));
      s.setWarpServer(make(0), choose: true);
      s.onTrafficForTest(const Traffic(0, 0, 100, 1000));
      s.onTrafficForTest(const Traffic(0, 0, 300, 5000));
      expect(s.warpUsage, [5000, 300]);
      expect(s.publicUsage, [0, 0]);
      s.selected = s.collector.configs.first;
      s.onTrafficForTest(const Traffic(0, 0, 400, 7000));
      expect(s.warpUsage, [5000, 300]);
      expect(s.publicUsage, [2000, 100]);
      s.resetUsage();
      expect(s.warpUsage, [0, 0]);
    });
  });
  group('the sign-up connection', () {
    test('the first bytes go out in small pieces and everything arrives in order', () async {
      final received = <List<int>>[];
      final all = BytesBuilder();
      final done = Completer<void>();
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((s) {
        s.setOption(SocketOption.tcpNoDelay, true);
        s.listen((d) {
          received.add(d);
          all.add(d);
          if (all.length >= 300 + 5) done.complete();
        });
      });
      final relay = await FragmentRelay.start('127.0.0.1',
          port: server.port, size: (5, 40), delay: (1, 2));
      final client = await Socket.connect(InternetAddress.loopbackIPv4, relay.port);
      final hello = List<int>.generate(300, (i) => i % 251);
      client.add(hello);
      await client.flush();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      client.add([1, 2, 3, 4, 5]);
      await client.flush();
      await done.future.timeout(const Duration(seconds: 10));
      expect(all.toBytes(), [...hello, 1, 2, 3, 4, 5]);
      // The hello is not in one piece (the TCP stack may join a few, but not all of them).
      expect(received.length, greaterThan(2));
      await client.close();
      await relay.close();
      await server.close();
    });

    test('an answer with a length, in chunks, or not finished yet', () {
      Uint8List b(String s) => Uint8List.fromList(latin1.encode(s));
      final withLength = parseHttpResponse(b('HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello'))!;
      expect((withLength.status, utf8.decode(withLength.body)), (200, 'hello'));
      final chunked = parseHttpResponse(
          b('HTTP/1.1 401 Unauthorized\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n'))!;
      expect((chunked.status, utf8.decode(chunked.body)), (401, 'abcde'));
      expect(parseHttpResponse(b('HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhel')), isNull);
      expect(parseHttpResponse(b('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nab')), isNull);
      expect(parseHttpResponse(b('HTTP/1.1 200 OK\r\nContent-Le')), isNull);
    });

    test('an account is read back from what was saved, and only if it is whole', () {
      final back = WarpAccount.fromJson(jsonDecode(jsonEncode(_account.toJson())))!;
      expect(back.reserved, [219, 200, 184]);
      expect(back.privateKey, _account.privateKey);
      expect(WarpAccount.fromJson({'private_key': 'x'}), isNull);
      expect(WarpAccount.fromJson({..._account.toJson(), 'reserved': [1, 2]}), isNull);
      expect(WarpAccount.fromJson({..._account.toJson(), 'reserved': [1, 2, 300]}), isNull);
    });
  });

  // Needs the internet (and the cores of a Windows build): KUMO_WARP_LIVE=1 flutter test test/warp_test.dart
  test('LIVE: sign up, connect through Xray with noise and see warp=on', () async {
    final p = _profile();
    final account = await registerWarp(p);
    final method = p.usable(platform: 'windows', build: 30).firstWhere((m) => m.kind == 'wg-noise');
    final c = parseLink(warpLink(account, method, p.endpoints.first, 0))!;
    final dir = await Directory.systemTemp.createTemp('warp_live');
    final cfg = File('${dir.path}/xray.json')..writeAsStringSync(buildXrayConfig(c, 38801));
    final xray = await Process.start(File('windows/core/kumo-xray.exe').absolute.path, ['run', '-c', cfg.path]);
    try {
      await Future<void>.delayed(const Duration(seconds: 3));
      final r = await Process.run('curl.exe',
          ['-s', '-m', '12', '-x', 'socks5h://127.0.0.1:38801', 'https://cloudflare.com/cdn-cgi/trace']);
      expect('${r.stdout}', contains('warp=on'));
    } finally {
      xray.kill();
      await dir.delete(recursive: true);
    }
  },
      skip: Platform.environment['KUMO_WARP_LIVE'] == '1' && Platform.isWindows
          ? false
          : 'needs KUMO_WARP_LIVE=1 and a Windows build of the cores',
      timeout: const Timeout(Duration(minutes: 2)));
}
