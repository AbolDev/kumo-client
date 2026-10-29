import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/warp/warp_profile.dart';
import 'package:kumo/core/warp/warp_signature.dart';

Map<String, dynamic> _good() => {
      'schema': 1,
      'version': 3,
      'issued_at': '2026-11-01T10:00:00Z',
      'expires_at': '2026-12-01T10:00:00Z',
      'key_id': 'k1',
      'message': {'en': 'Hello', 'fa': 'سلام'},
      'disabled_methods': <String>[],
      'register': {
        'fragment': {
          'size': [5, 40],
          'delay_ms': [10, 10]
        },
        'api_ips': ['104.16.192.82', '104.16.24.84'],
      },
      'endpoints': [
        {
          'ip': '162.159.192.1',
          'ports': [2408, 500]
        },
      ],
      'methods': [
        {
          'id': 'wg-noise-a',
          'kind': 'wg-noise',
          'rank': 2,
          'platforms': ['windows', 'android'],
          'requires': ['wg.noise.v1', 'reg.fragment.v1'],
          'min_build': 30,
          'params': {
            'noise': [
              {
                'type': 'rand',
                'packet': [10, 30],
                'delay_ms': [5, 10]
              },
            ],
          },
        },
        {
          'id': 'wg-plain-a',
          'kind': 'wg-plain',
          'rank': 1,
          'requires': ['wg.plain.v1'],
        },
        {'id': 'future', 'kind': 'masque-h2', 'rank': 1, 'requires': ['masque.v1']},
      ],
    };

WarpProfile _parse(Map<String, dynamic> j) => parseWarpProfile(jsonEncode(j));

void _rejects(Map<String, dynamic> j, [String? why]) =>
    expect(() => _parse(j), throwsA(isA<WarpFormatException>()), reason: why);

void main() {
  group('reading the profile', () {
    test('a good file is read, and a kind this build does not know is skipped', () {
      final p = _parse(_good());
      expect(p.version, 3);
      expect(p.methods.map((m) => m.id), ['wg-noise-a', 'wg-plain-a']);
      expect(p.methods.first.noise.single.spec, 'rand~10-30~5-10');
      expect(p.fragmentSize, (5, 40));
    });

    test('a newer layout is refused as such', () {
      expect(() => _parse(_good()..['schema'] = 2), throwsA(isA<WarpSchemaTooNew>()));
    });

    test('values outside the limits make the whole file unusable', () {
      _rejects(_good()..['version'] = 0, 'version');
      _rejects(_good()..['expires_at'] = '2026-10-01T10:00:00Z', 'expires before issued');
      _rejects(_good()..['key_id'] = 'K 1', 'key id');
      _rejects(_good()..['message'] = {'en': '<b>x</b>'}, 'markup');
      _rejects(_good()..['message'] = {'en': 'see https://example.com'}, 'link');
      final badIp = _good();
      (badIp['register'] as Map)['api_ips'] = ['8.8.8.8'];
      _rejects(badIp, 'not Cloudflare');
      final badPort = _good();
      (badPort['endpoints'] as List)[0] = {'ip': '162.159.192.1', 'ports': [70000]};
      _rejects(badPort, 'port');
      final badFrag = _good();
      ((badFrag['register'] as Map)['fragment'] as Map)['size'] = [0, 500];
      _rejects(badFrag, 'fragment size');
      final bigNoise = _good();
      ((((bigNoise['methods'] as List)[0] as Map)['params'] as Map)['noise'] as List)[0] = {
        'type': 'rand',
        'packet': [10, 5000],
        'delay_ms': [5, 10]
      };
      _rejects(bigNoise, 'noise too big');
      final slowNoise = _good();
      ((((slowNoise['methods'] as List)[0] as Map)['params'] as Map)['noise'] as List)[0] = {
        'type': 'rand',
        'packet': [10, 30],
        'delay_ms': [5, 900]
      };
      _rejects(slowNoise, 'noise too slow');
      final dupe = _good();
      (dupe['methods'] as List).add({'id': 'wg-plain-a', 'kind': 'wg-plain', 'rank': 3});
      _rejects(dupe, 'duplicate id');
    });

    test('not JSON and an oversized file are refused', () {
      expect(() => parseWarpProfile('{'), throwsA(isA<WarpFormatException>()));
      expect(() => parseWarpProfile(' ' * 70000), throwsA(isA<WarpFormatException>()));
    });

    test('Cloudflare ranges', () {
      expect(isCloudflareV4('162.159.192.1'), isTrue);
      expect(isCloudflareV4('188.114.97.1'), isTrue);
      expect(isCloudflareV4('104.16.192.82'), isTrue);
      expect(isCloudflareV4('8.8.8.8'), isFalse);
      expect(isCloudflareV4('127.0.0.1'), isFalse);
      expect(isCloudflareV4('162.159.192.300'), isFalse);
      expect(isCloudflareV4('not an ip'), isFalse);
    });
  });

  group('which methods a build may use', () {
    final p = _parse(_good());
    List<String> ids(String platform, int build) =>
        p.usable(platform: platform, build: build).map((m) => m.id).toList();

    test('best rank first', () => expect(ids('windows', 30), ['wg-plain-a', 'wg-noise-a']));
    test('a platform that is not listed does not get the method',
        () => expect(ids('linux', 30), ['wg-plain-a']));
    test('a build below min_build does not', () => expect(ids('windows', 29), ['wg-plain-a']));

    test('a feature this build lacks, a disabled id and max_build leave a method out', () {
      final j = _good();
      (j['methods'] as List).add({
        'id': 'needs-more',
        'kind': 'wg-plain',
        'rank': 1,
        'requires': ['wg.something.v9'],
      });
      (j['methods'] as List).add({'id': 'old-only', 'kind': 'wg-plain', 'rank': 4, 'max_build': 20});
      j['disabled_methods'] = ['wg-noise-a'];
      final q = _parse(j);
      expect(q.usable(platform: 'windows', build: 30).map((m) => m.id), ['wg-plain-a']);
      expect(q.usable(platform: 'windows', build: 10).map((m) => m.id), ['wg-plain-a', 'old-only']);
    });
  });

  group('signature', () {
    final data = utf8.encode(jsonEncode(_good()));

    test('a signature checks with its own key only', () {
      final (priv, pub) = newWarpKeyPair();
      final (_, other) = newWarpKeyPair();
      final sig = signWarp(data, priv);
      expect(verifyWarpSignature(data, sig, pub), isTrue);
      expect(verifyWarpSignature(data, sig, other), isFalse);
    });

    test('a changed file does not check', () {
      final (priv, pub) = newWarpKeyPair();
      final sig = signWarp(data, priv);
      final changed = [...data]..[10] ^= 1;
      expect(verifyWarpSignature(changed, sig, pub), isFalse);
    });

    test('the same file always gets the same signature', () {
      final (priv, _) = newWarpKeyPair();
      expect(signWarp(data, priv), signWarp(data, priv));
    });

    test('garbage never throws', () {
      final (_, pub) = newWarpKeyPair();
      expect(verifyWarpSignature(data, '', pub), isFalse);
      expect(verifyWarpSignature(data, 'not base64!', pub), isFalse);
      expect(verifyWarpSignature(data, base64.encode(List.filled(64, 1)), 'AAAA'), isFalse);
    });
  });
}
