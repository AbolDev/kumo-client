import 'dart:async';
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
      expect(tls['allowInsecure'], isTrue);
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
