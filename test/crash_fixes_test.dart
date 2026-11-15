import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/desktop_vpn.dart' show stripAnsi;
import 'package:kumo/core/proxy_config.dart';
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
  });
}
