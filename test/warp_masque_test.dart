import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/proxy_config.dart';
import 'package:kumo/core/singbox_config.dart' show buildXrayConfig;
import 'package:kumo/core/warp/p256.dart';
import 'package:kumo/core/warp/warp_link.dart';
import 'package:kumo/core/warp/warp_profile.dart';
import 'package:kumo/core/warp/warp_register.dart';
import 'package:pointycastle/export.dart';

WarpProfile _profile() => WarpProfile(
      version: 1,
      issuedAt: DateTime.utc(2026, 1, 1),
      expiresAt: DateTime.utc(2030, 1, 1),
      keyId: 'k',
      message: const {},
      disabled: const {},
      fragmentSize: (1, 1),
      fragmentDelay: (1, 1),
      apiIps: const ['162.159.137.105'],
      endpoints: const [],
      methods: const [],
    );

// What the service answers to the sign-up of a MASQUE key (the part this app reads).
Map<String, dynamic> _config(String edgePem) => {
      'peers': [
        {
          'public_key': edgePem,
          'endpoint': {'v4': '162.159.198.2:0', 'v6': '[2606:4700:103::]:0', 'host': 'engage.cloudflareclient.com:2408'},
        },
      ],
      'interface': {
        'addresses': {'v4': '172.16.0.2', 'v6': '2606:4700:110:8a36:df92:102a:9602:fa18'},
      },
    };

String _pem(Uint8List der) {
  final b = base64.encode(der);
  final lines = [for (var i = 0; i < b.length; i += 64) b.substring(i, min(i + 64, b.length))];
  return '-----BEGIN PUBLIC KEY-----\n${lines.join('\n')}\n-----END PUBLIC KEY-----\n';
}

void main() {
  group('P-256 keys', () {
    test('the two forms hold the same key, and the key is a point of the curve', () {
      final k = newP256Keys(Random(7));
      expect(k.privateSec1.length, 121);
      expect(k.publicSpki.length, 91);
      // SubjectPublicKeyInfo of an EC key on prime256v1, then the uncompressed point.
      expect(k.publicSpki.sublist(0, 26), [
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, //
        0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
      ]);
      final point = k.publicSpki.sublist(26);
      expect(point[0], 4);
      // The private key carries the same point at its end.
      expect(k.privateSec1.sublist(121 - 65), point);

      final curve = ECCurve_secp256r1();
      final decoded = curve.curve.decodePoint(point);
      expect(decoded, isNotNull);
      var d = BigInt.zero;
      for (final b in k.privateSec1.sublist(7, 39)) {
        d = (d << 8) | BigInt.from(b);
      }
      final q = (curve.G * d)!;
      expect(q.x!.toBigInteger(), decoded!.x!.toBigInteger());
      expect(q.y!.toBigInteger(), decoded.y!.toBigInteger());
    });

    test('two keys are not the same', () {
      expect(newP256Keys(Random(1)).privateBase64, isNot(newP256Keys(Random(2)).privateBase64));
    });

    test('the edge key is taken from a PEM text or from base64, and nothing else', () {
      final der = newP256Keys(Random(3)).publicSpki;
      final b64 = base64.encode(der);
      expect(edgeKeyBase64(_pem(der)), b64);
      expect(edgeKeyBase64(b64), b64);
      expect(edgeKeyBase64(''), isNull);
      expect(edgeKeyBase64('not a key'), isNull);
      expect(edgeKeyBase64(base64.encode([1, 2, 3])), isNull);
    });
  });

  group('the MASQUE account', () {
    test('is read from the answer of the service', () {
      final edge = newP256Keys(Random(4)).publicSpki;
      final a = masqueAccountFrom('PRIV', _config(_pem(edge)))!;
      expect(a.privateKey, 'PRIV');
      expect(a.edgeKey, base64.encode(edge));
      expect(a.v4, '172.16.0.2');
      expect(a.v6, startsWith('2606:4700:110:8a36'));
      expect(a.endpoint, '162.159.198.2');
    });

    test('an answer without the edge key or the addresses is refused', () {
      final edge = _pem(newP256Keys(Random(5)).publicSpki);
      expect(masqueAccountFrom('P', _config('garbage')), isNull);
      expect(masqueAccountFrom('P', {'peers': [], 'interface': {}}), isNull);
      final noV6 = _config(edge)..['interface'] = {'addresses': {'v4': '172.16.0.2'}};
      expect(masqueAccountFrom('P', noV6), isNull);
      expect(masqueAccountFrom('P', null), isNull);
    });

    test('an endpoint outside Cloudflare is not used', () {
      final edge = _pem(newP256Keys(Random(6)).publicSpki);
      final c = _config(edge);
      ((c['peers'] as List).first as Map)['endpoint'] = {'v4': '10.0.0.1:0'};
      expect(masqueAccountFrom('P', c)!.endpoint, masqueDefaultEndpoint);
    });

    test('is kept and read back', () {
      const a = WarpMasqueAccount(privateKey: 'p', edgeKey: 'e', v4: '1.2.3.4', v6: '::1', endpoint: '162.159.198.2');
      final b = WarpMasqueAccount.fromJson(jsonDecode(jsonEncode(a.toJson())))!;
      expect([b.privateKey, b.edgeKey, b.v4, b.v6, b.endpoint], ['p', 'e', '1.2.3.4', '::1', '162.159.198.2']);
      expect(WarpMasqueAccount.fromJson({'private_key': ''}), isNull);
      expect(WarpMasqueAccount.fromJson(null), isNull);
    });
  });

  group('the sign-up', () {
    test('registers a device, then gives it a P-256 key of the type masque', () async {
      final calls = <(String, String, Map<String, dynamic>, String?)>[];
      final edge = _pem(newP256Keys(Random(8)).publicSpki);
      final account = await registerWarpMasque(
        _profile(),
        random: Random(9),
        call: (method, path, body, {String? token}) async {
          calls.add((method, path, body, token));
          if (method == 'POST') return {'id': 'abcdef12-3456', 'token': 'tok', 'config': _config('garbage')};
          return {'config': _config(edge)};
        },
      );
      expect(calls.length, 3);
      expect(calls[0].$1, 'POST');
      expect(calls[0].$2, '/v0a4471/reg');
      expect(calls[0].$3['tunnel_type'], 'wireguard');
      expect(calls[0].$4, isNull);
      expect(calls[1].$1, 'PATCH');
      expect(calls[1].$2, '/v0a4471/reg/abcdef12-3456');
      expect(calls[1].$3['key_type'], 'secp256r1');
      expect(calls[1].$3['tunnel_type'], 'masque');
      expect(calls[1].$4, 'tok');
      // The key sent is the public half of the private key kept.
      final sent = base64.decode(calls[1].$3['key'] as String);
      expect(sent.length, 91);
      expect(calls[2].$3, {'warp_enabled': true});
      expect(account.v4, '172.16.0.2');
      expect(base64.decode(account.privateKey).length, 121);
      expect(base64.decode(account.privateKey).sublist(121 - 65), sent.sublist(26));
    });

    test('the ways to reach the service start with the profile\'s cut and go on with bigger pieces', () {
      final p = WarpProfile(
        version: 1,
        issuedAt: DateTime.utc(2026, 1, 1),
        expiresAt: DateTime.utc(2030, 1, 1),
        keyId: 'k',
        message: const {},
        disabled: const {},
        fragmentSize: (5, 40),
        fragmentDelay: (10, 10),
        apiIps: const ['104.16.192.82', '104.16.24.84'],
        endpoints: const [],
        methods: const [],
      );
      final tries = signUpTries(p);
      expect(tries.first, ('104.16.192.82', (5, 40), (10, 10)));
      expect(tries[1].$1, '104.16.24.84');
      expect(tries.map((t) => t.$2).toSet(), {(5, 40), (20, 60), (50, 100)});
      expect(tries.length, 12);
      // Raced in two waves: every cut and address once, then a second go.
      final waves = signUpWaves(p);
      expect(waves.length, 2);
      expect(waves.first.length, 6);
      expect(waves.first.map((t) => (t.$1, t.$2)).toSet().length, 6);
      expect([...waves.first, ...waves.last], tries);
    });

    test('goes on when switching the account on is refused', () async {
      final edge = _pem(newP256Keys(Random(10)).publicSpki);
      final account = await registerWarpMasque(
        _profile(),
        random: Random(11),
        call: (method, path, body, {String? token}) async {
          if (method == 'POST') return {'id': 'abcdef12-3456', 'token': 'tok'};
          if (body.containsKey('warp_enabled')) throw WarpRegisterException('refused');
          return {'config': _config(edge)};
        },
      );
      expect(account.edgeKey, isNotEmpty);
    });

    test('stops when the answer has no account or an incomplete config', () async {
      await expectLater(
        registerWarpMasque(_profile(), call: (m, p, b, {String? token}) async => {'id': 'x'}),
        throwsA(isA<WarpRegisterException>()),
      );
      await expectLater(
        registerWarpMasque(_profile(), call: (m, p, b, {String? token}) async {
          return m == 'POST' ? {'id': 'abcdef12-3456', 'token': 't'} : {'config': {}};
        }),
        throwsA(isA<WarpRegisterException>()),
      );
    });
  });

  group('the server', () {
    final edge = base64.encode(newP256Keys(Random(12)).publicSpki);
    final account = WarpMasqueAccount(
        privateKey: base64.encode(newP256Keys(Random(13)).privateSec1),
        edgeKey: edge,
        v4: '172.16.0.2',
        v6: '2606:4700:110:8a36::2');

    test('the MASQUE ways are known and come with the kinds', () {
      expect(masqueMethods.map((m) => m.id), ['masque-h2', 'masque-h2-alt', 'masque-h3', 'masque-h3-alt']);
      expect(masqueMethods.every((m) => isMasqueKind(m.kind)), isTrue);
      expect(isMasqueKind('wg-plain'), isFalse);
      expect(isMasqueKind('wg-noise'), isFalse);
    });

    test('the link becomes a server only Xray carries', () {
      final c = parseLink(masqueLink(account, masqueMethods.first))!;
      expect(c.protocol, 'masque');
      expect(c.needsXray, isTrue);
      expect(c.canSingBox, isFalse);
      expect(c.host, masqueDefaultEndpoint);
      expect(c.port, 443);
      final out = c.xrayOutbound!;
      expect(out['protocol'], 'masque');
      expect((out['settings'] as Map)['address'], masqueDefaultEndpoint);
      final stream = out['streamSettings'] as Map;
      expect(stream['network'], 'masque');
      expect(stream['security'], 'tls');
      // The name that passes where the name of Cloudflare's MASQUE service is cut (checked on a network that cuts it).
      expect((stream['tlsSettings'] as Map)['serverName'], 'cloudflareaccess.com');
      expect((stream['tlsSettings'] as Map)['alpn'], ['h2']);
      final warp = (stream['masqueSettings'] as Map)['warp'] as Map;
      // The keys come back as they went in, whatever characters base64 uses.
      expect(warp['privateKey'], account.privateKey);
      expect(warp['publicKey'], edge);
      expect(warp['address'], ['172.16.0.2/32', '2606:4700:110:8a36::2/128']);
    });

    test('the HTTP/3 way asks for h3', () {
      final c = parseLink(masqueLink(account, masqueMethods.firstWhere((m) => m.id == 'masque-h3')))!;
      final tls = (c.xrayOutbound!['streamSettings'] as Map)['tlsSettings'] as Map;
      expect(tls['alpn'], ['h3']);
      expect(tls['serverName'], 'cloudflareaccess.com');
    });

    test('a fingerprint is passed to the hello over HTTP/2 only, and only a known one', () {
      Map tlsOf(String id, String fp) {
        final m = masqueMethods.firstWhere((m) => m.id == id);
        final c = parseLink(masqueLink(account, m, fingerprint: fp))!;
        return (c.xrayOutbound!['streamSettings'] as Map)['tlsSettings'] as Map;
      }

      expect(tlsOf('masque-h2', 'firefox')['fingerprint'], 'firefox');
      expect(tlsOf('masque-h2-alt', 'chrome')['fingerprint'], 'chrome');
      expect(tlsOf('masque-h2', '').containsKey('fingerprint'), isFalse);
      expect(tlsOf('masque-h2', 'nonsense').containsKey('fingerprint'), isFalse);
      // Xray does not use it over HTTP/3.
      expect(tlsOf('masque-h3', 'firefox').containsKey('fingerprint'), isFalse);
    });

    test('the -alt ways use the name of Cloudflare\'s own MASQUE service', () {
      for (final id in ['masque-h2-alt', 'masque-h3-alt']) {
        final m = masqueMethods.firstWhere((m) => m.id == id);
        final c = parseLink(masqueLink(account, m))!;
        final tls = (c.xrayOutbound!['streamSettings'] as Map)['tlsSettings'] as Map;
        expect(tls['serverName'], 'consumer-masque.cloudflareclient.com');
        expect(tls['alpn'], [id.contains('h3') ? 'h3' : 'h2']);
      }
    });

    test('a link without a key or an address is not a server', () {
      expect(parseLink('warp-masque://162.159.198.2:443?pub=abc&address=1.2.3.4#x'), isNull);
      expect(parseLink('warp-masque://162.159.198.2:443?priv=abc&address=1.2.3.4#x'), isNull);
      expect(parseLink('warp-masque://162.159.198.2:443?priv=a&pub=b#x'), isNull);
    });

    test('Xray gets a configuration with the MASQUE outbound', () {
      final c = parseLink(masqueLink(account, masqueMethods.first))!;
      final json = jsonDecode(buildXrayConfig(c, 40000)) as Map<String, dynamic>;
      final outbounds = json['outbounds'] as List;
      expect(outbounds.any((o) => (o as Map)['protocol'] == 'masque'), isTrue);
    });
  });
}
