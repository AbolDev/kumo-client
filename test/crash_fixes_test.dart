import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/desktop_vpn.dart' show coreSpawnProblem, coreStartMessage, isTunAdapterFailure, stripAnsi;
import 'package:kumo/core/proxy_config.dart';
import 'package:kumo/core/singbox_config.dart';
import 'package:kumo/core/usage/crash_hub.dart';

const _pin = 'vless://11111111-1111-1111-1111-111111111111@v.example.com:443'
    '?security=tls&sni=v.example.com&type=ws&path=%2F&pcs=AA11%2Cbb22#pinned';

String _reality(String pbk, [String sid = '0123abcd']) =>
    'vless://11111111-1111-1111-1111-111111111111@r.example.com:443'
    '?security=reality&sni=example.com&type=tcp&flow=xtls-rprx-vision&pbk=$pbk&sid=$sid#r';

void main() {
  group('what the crash reports showed', () {
    test('an error of the network is not a crash, whatever it is', () {
      expect(isNetworkError(const SocketException('Connection reset by peer')), isTrue);
      expect(isNetworkError(const HandshakeException('handshake')), isTrue);
      expect(isNetworkError(const HttpException('closed')), isTrue);
      expect(isNetworkError(TimeoutException('late')), isTrue);
      expect(isNetworkError(const FormatException('bad')), isFalse);
      // The image picker saying it is open already is not a fault either; another picker error is.
      expect(isPickerBusy(PlatformException(code: 'already_active', message: 'Image picker is already active')), isTrue);
      expect(isPickerBusy(PlatformException(code: 'photo_access_denied')), isFalse);
      expect(isPickerBusy(const FormatException('already_active')), isFalse);
      expect(isNetworkError(StateError('x')), isFalse);
    });

    test('the kind is the name of the error, not the one a release build gives its class', () {
      expect(errorKind(const SocketException('x')), 'SocketException');
      expect(errorKind(const HandshakeException('x')), 'HandshakeException');
      expect(errorKind(TimeoutException('x')), 'TimeoutException');
      expect(errorKind(const FormatException('x')), 'FormatException');
      expect(errorKind(RangeError('x')), 'RangeError');
      expect(errorKind(StateError('x')), 'StateError');
      expect(errorKind(FlutterError('x')), 'FlutterError');
    });

    test('the pinned certificate goes to Xray as one text, not a list', () {
      final c = parseLink(_pin)!;
      final tls = (c.xrayOutbound!['streamSettings'] as Map)['tlsSettings'] as Map;
      expect(tls['pinnedPeerCertSha256'], 'AA11,bb22');
      // Xray 26 removed "allowInsecure" and does not start when it is there.
      expect(tls.containsKey('allowInsecure'), isFalse);
    });

    test('an insecure link gives Xray no "allowInsecure" key', () {
      const link = 'vless://11111111-1111-1111-1111-111111111111@v.example.com:443'
          '?security=tls&sni=v.example.com&type=ws&path=%2F&allowInsecure=1#insecure';
      final c = parseLink(link)!;
      final tls = (c.xrayOutbound!['streamSettings'] as Map)['tlsSettings'] as Map;
      expect(tls.containsKey('allowInsecure'), isFalse);
    });

    test('a server with a pinned certificate runs on Xray, the only core that checks the pin', () {
      final c = parseLink(_pin)!;
      expect(c.pinned, isTrue);
      expect(c.preferXray, isTrue);
      expect(c.useXray('singbox'), isTrue);
      const plain = 'vless://11111111-1111-1111-1111-111111111111@v.example.com:443'
          '?security=tls&sni=v.example.com&type=ws&path=%2F#plain';
      final p = parseLink(plain)!;
      expect(p.pinned, isFalse);
      expect(p.useXray('singbox'), isFalse);
      expect(p.useXray('xray'), isTrue);
    });

    test('an insecure server without a pin stays on sing-box even when Xray is the core', () {
      const link = 'vless://11111111-1111-1111-1111-111111111111@v.example.com:443'
          '?security=tls&sni=v.example.com&type=ws&path=%2F&allowInsecure=1#insecure';
      final c = parseLink(link)!;
      expect(c.pinned, isFalse);
      expect(c.xrayCannotSkipCheck, isTrue);
      expect(c.useXray('xray'), isFalse);
      // A server only Xray can carry still goes to Xray.
      expect(parseLink(_pin)!.xrayCannotSkipCheck, isFalse);
    });

    test('a failure that names the network is not a crash report', () {
      expect(isNetworkFailureText('Unable to resolve host "x.example": No address associated with hostname'), isTrue);
      expect(isNetworkFailureText('dial tcp: lookup x.example: no such host'), isTrue);
      expect(isNetworkFailureText('connect: Network is unreachable'), isTrue);
      expect(isNetworkFailureText('start inbound/mixed[mixed-in]: listen tcp: bind: address already in use'), isFalse);
      expect(isNetworkFailureText('unknown method: x'), isFalse);
    });

    test('an error that came only as text is still known as the network\'s', () {
      // What another isolate hands over is the text of the error, not the error.
      expect(isNetworkErrorText('SocketException: Connection reset by peer (OS Error: Connection reset by peer, errno = 104), address = h.example, port = 1'), isTrue);
      expect(isNetworkErrorText('  TimeoutException after 0:00:08.000000: Future not completed'), isTrue);
      expect(isNetworkErrorText('Unable to resolve host "x.example": No address associated with hostname'), isTrue);
      expect(isNetworkErrorText('Bad state: no element'), isFalse);
      expect(isNetworkErrorText('FormatException: not json'), isFalse);
    });

    test('a connection the user was told the reason of is not a crash report', () {
      // Report 93 (Android): the OpenVPN server refused the login.
      expect(isExpectedCoreFailure('ovpn:auth'), isTrue);
      expect(isExpectedCoreFailure('ovpn:handshake|blocked'), isTrue);
      expect(isExpectedCoreFailure('ovpn:timeout|TLS: Initial packet'), isTrue);
      expect(isExpectedCoreFailure('ovpn:permission'), isTrue);
      // A program that stopped for no known reason is one.
      expect(isExpectedCoreFailure('ovpn:exited|exit code 1'), isFalse);
      expect(isExpectedCoreFailure('ovpn:nobinary'), isFalse);
      expect(isExpectedCoreFailure('create service: initialize outbound[3]: invalid public_key'), isFalse);
    });

    test('a Shadowsocks cipher is given to sing-box by the name it knows', () {
      String? methodOf(String link) => parseLink(link)?.outbound['method'] as String?;
      final user = base64Url.encode(utf8.encode('chacha20-poly1305:pw')).replaceAll('=', '');
      expect(methodOf('ss://$user@h.example.com:8388#a'), 'chacha20-ietf-poly1305');
      final ok = base64Url.encode(utf8.encode('aes-256-gcm:pw')).replaceAll('=', '');
      expect(methodOf('ss://$ok@h.example.com:8388#a'), 'aes-256-gcm');
      // A cipher sing-box does not have: the server is left out instead of stopping the core.
      final odd = base64Url.encode(utf8.encode('rot13:pw')).replaceAll('=', '');
      expect(parseLink('ss://$odd@h.example.com:8388#a'), isNull);
      expect(singboxSsMethod('XChaCha20-Poly1305'), 'xchacha20-ietf-poly1305');
      expect(singboxSsMethod('2022-blake3-aes-256-gcm'), '2022-blake3-aes-256-gcm');
    });

    test('a Reality key or short id the core would refuse is told apart', () {
      final good = 'A' * 43;
      expect(parseLink(_reality(good))!.badRealityKey, isFalse);
      expect(parseLink(_reality(good, ''))!.badRealityKey, isFalse);
      expect(parseLink(_reality('short'))!.badRealityKey, isTrue);
      expect(parseLink(_reality('${'A' * 42}%2B'))!.badRealityKey, isTrue);
      expect(parseLink(_reality(good, 'xyz'))!.badRealityKey, isTrue);
      expect(parseLink(_reality(good, 'abc'))!.badRealityKey, isTrue);
      // A server without Reality has no such key.
      expect(parseLink(_pin)!.badRealityKey, isFalse);
    });

    test('the colour codes of the core are taken out of its message', () {
      expect(stripAnsi('\x1B[31mFATAL\x1B[0m[0000] create service: invalid public_key'),
          'FATAL[0000] create service: invalid public_key');
      expect(stripAnsi('plain [text]'), 'plain [text]');
    });

    test('a tunnel adapter that could not be made is known by the words of the core', () {
      // Report 85 (Windows, the system's own words in Portuguese).
      const report = 'WARN[0010] inbound/tun[tun-in]: open interface take too much time to finish!\n'
          'FATAL[0016] start service: start inbound/tun[tun-in]: configure tun interface: '
          '(create adapter: Não é possível criar um arquivo já existente. | open existing adapter: Elemento não encontrado.)';
      expect(isTunAdapterFailure(report), isTrue);
      expect(isTunAdapterFailure('start inbound/tun[tun-in]: open interface take too much time to finish!'), isTrue);
      expect(isTunAdapterFailure('FATAL start service: configure tun interface: (create adapter: x)'), isTrue);
      // Other failures of the core are not.
      expect(isTunAdapterFailure('start inbound/mixed[mixed-in]: listen tcp: bind: address already in use'), isFalse);
      expect(isTunAdapterFailure('create service: initialize outbound[3]: invalid public_key'), isFalse);
      expect(isTunAdapterFailure(''), isFalse);
    });
  });

  group('the crash reports of 18 to 20 November', () {
    test('an XHTTP link with 20.0 in its "extra" gives Xray 20, not 20.0 (reports 125, 126)', () {
      final extra = Uri.encodeComponent('{"xmux":{"hKeepAlivePeriod":20.0,"maxConcurrency":"16-32"},"scMaxEachPostBytes":1000000,"noGRPCHeader":false}');
      final server = parseLinks([
        'vless://11111111-1111-1111-1111-111111111111@x.example.com:443'
            '?security=tls&sni=x.example.com&type=xhttp&path=%2Fx&extra=$extra#x',
      ]).single;
      final text = buildXrayConfig(server, 31000);
      expect(RegExp(r'"hKeepAlivePeriod":\s*20(?![.\d])').hasMatch(text), isTrue, reason: text);
      expect(text.contains('20.0'), isFalse);
      // The other values of the block stay as they were.
      final out = ((jsonDecode(text) as Map)['outbounds'] as List).cast<Map>().firstWhere((o) => o['streamSettings'] != null);
      final xhttp = (out['streamSettings'] as Map)['xhttpSettings'] as Map;
      expect((xhttp['extra'] as Map)['xmux']['maxConcurrency'], '16-32');
      expect((xhttp['extra'] as Map)['noGRPCHeader'], false);
    });

    test('only a number without a fraction is made an integer', () {
      expect(wholeNumbers({'a': 20.0, 'b': 0.5, 'c': [1.0, 2.5, 'x'], 'd': {'e': 3.0}}),
          {'a': 20, 'b': 0.5, 'c': [1, 2.5, 'x'], 'd': {'e': 3}});
      expect(wholeNumbers(7), 7);
      expect(wholeNumbers('20.0'), '20.0');
    });

    test('a WireGuard key written URL-safe, without padding or with its "+" turned into a space is accepted (reports 143-145)', () {
      final bytes = [0xfb, 0xff, 0xbf, ...List<int>.generate(29, (i) => 255 - i * 7)];
      final std = base64.encode(bytes);
      expect(std, contains('+'));
      final urlSafe = std.replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
      final unpadded = std.replaceAll('=', '');
      final spaced = std.replaceAll('+', ' ');
      for (final key in [std, urlSafe, unpadded, spaced]) {
        final link = 'wireguard://x@1.2.3.4:51820?privatekey=${key.replaceAll(' ', '+')}&publickey=${Uri.encodeComponent(key)}&address=10.0.0.2';
        final c = parseLink(link);
        expect(c, isNotNull, reason: key);
        expect(c!.outbound['private_key'], std, reason: key);
        expect(((c.outbound['peers'] as List).single as Map)['public_key'], std, reason: key);
        final secret = ((c.xrayOutbound!['settings']) as Map)['secretKey'];
        expect(secret, std, reason: key);
      }
    });

    test('a WireGuard key that is no 32 bytes refuses the link instead of stopping a core', () {
      final good = base64.encode(List<int>.filled(32, 7));
      final short = base64.encode(List<int>.filled(31, 7));
      expect(parseLink('wireguard://x@1.2.3.4:51820?privatekey=${Uri.encodeComponent(short)}&publickey=${Uri.encodeComponent(good)}&address=10.0.0.2'), isNull);
      expect(parseLink('wireguard://x@1.2.3.4:51820?privatekey=${Uri.encodeComponent(good)}&publickey=not%20a%20key!&address=10.0.0.2'), isNull);
      expect(parseLink('wireguard://x@1.2.3.4:51820?privatekey=${Uri.encodeComponent(good)}&publickey=${Uri.encodeComponent(good)}&presharedkey=zz&address=10.0.0.2'), isNull);
    });

    test('a core that did not answer says what was seen (report 109)', () {
      const wait = Duration(seconds: 25);
      expect(coreStartMessage('FATAL start service: boom', exited: true, exitCode: 1, apiPort: 9090, waited: wait), 'FATAL start service: boom');
      final stopped = coreStartMessage('', exited: true, exitCode: -1073741819, apiPort: 9090, waited: wait);
      expect(stopped, contains('exit code -1073741819'));
      final silent = coreStartMessage('  ', exited: false, apiPort: 9090, waited: wait);
      expect(silent, contains('9090'));
      expect(silent, contains('25 s'));
      expect(silent, isNot(equals('sing-box did not start')));
    });

    test('a core the user may not run is told in words and is no crash report (reports 107, 108, 129)', () {
      final denied = coreSpawnProblem(
          const ProcessException('/opt/kumo/kumo-core', ['run'], 'Permission denied', 13), '/opt/kumo/kumo-core');
      expect(denied, contains('usermod -aG kumo'));
      expect(denied, contains('/opt/kumo/kumo-core'));
      expect(isExpectedCoreFailure(denied), isTrue);
      // Another reason to fail keeps its own words, and is still a report.
      final missing = coreSpawnProblem(
          const ProcessException('/opt/kumo/kumo-core', ['run'], 'No such file or directory', 2), '/opt/kumo/kumo-core');
      expect(missing, contains('No such file'));
      expect(isExpectedCoreFailure(missing), isFalse);
    });
  });
}
