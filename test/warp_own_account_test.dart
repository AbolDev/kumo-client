import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/warp/p256.dart';
import 'package:kumo/core/warp/warp_profile.dart';
import 'package:kumo/core/warp/warp_register.dart';

final _priv = base64.encode(List<int>.generate(32, (i) => i + 1));
final _pub = base64.encode(List<int>.generate(32, (i) => 100 + i));

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

String _pem(List<int> der) {
  final b = base64.encode(der);
  return '-----BEGIN PUBLIC KEY-----\n$b\n-----END PUBLIC KEY-----\n';
}

Map<String, dynamic> _config(String edge) => {
      'peers': [
        {'public_key': edge, 'endpoint': {'v4': '162.159.198.2:0'}},
      ],
      'interface': {
        'addresses': {'v4': '172.16.0.2', 'v6': '2606:4700:110:8a36:df92:102a:9602:fa18'},
      },
    };

void main() {
  group('a WARP+ license key', () {
    test('has three groups of eight letters and digits', () {
      expect(warpLicenseOf('  aB3dE5gH-1b3D5f7H-9z8Y7x6W '), 'aB3dE5gH-1b3D5f7H-9z8Y7x6W');
      expect(warpLicenseOf('aB3dE5gH-1b3D5f7H'), isNull);
      expect(warpLicenseOf('aB3dE5gH-1b3D5f7H-9z8Y7x6W-extra'), isNull);
      expect(warpLicenseOf('aB3dE5g!-1b3D5f7H-9z8Y7x6W'), isNull);
      expect(warpLicenseOf(''), isNull);
    });

    test('is sent to the account of the device after it is made, before it is switched on', () async {
      final calls = <(String, String, Map<String, dynamic>, String?)>[];
      final edge = _pem(newP256Keys(Random(8)).publicSpki);
      await registerWarpMasque(
        _profile(),
        random: Random(9),
        license: 'aB3dE5gH-1b3D5f7H-9z8Y7x6W',
        call: (method, path, body, {String? token}) async {
          calls.add((method, path, body, token));
          if (method == 'POST') return {'id': 'abcdef12-3456', 'token': 'tok', 'config': _config('garbage')};
          return {'config': _config(edge)};
        },
      );
      expect(calls.map((c) => c.$1), ['POST', 'PATCH', 'PUT', 'PATCH']);
      expect(calls[2].$2, '/v0a4471/reg/abcdef12-3456/account');
      expect(calls[2].$3, {'license': 'aB3dE5gH-1b3D5f7H-9z8Y7x6W'});
      expect(calls[2].$4, 'tok');
      expect(calls[3].$3, {'warp_enabled': true});
    });

    test('a key the service refuses is a license error, and no license means no call', () async {
      await expectLater(
        registerWarpMasque(
          _profile(),
          license: 'aB3dE5gH-1b3D5f7H-9z8Y7x6W',
          call: (method, path, body, {String? token}) async {
            if (method == 'PUT') throw WarpRegisterException('the sign-up service answered 400: Invalid license');
            return {'id': 'abcdef12-3456', 'token': 'tok', 'config': _config('garbage')};
          },
        ),
        throwsA(isA<WarpLicenseException>()),
      );
      // A failure that is not an answer of the service stays what it was.
      await expectLater(
        registerWarpMasque(
          _profile(),
          license: 'aB3dE5gH-1b3D5f7H-9z8Y7x6W',
          call: (method, path, body, {String? token}) async {
            if (method == 'PUT') throw WarpRegisterException('no answer from the sign-up service');
            return {'id': 'abcdef12-3456', 'token': 'tok', 'config': _config('garbage')};
          },
        ),
        throwsA(predicate((e) => e is WarpRegisterException && e is! WarpLicenseException)),
      );
    });
  });

  group('the keys of an account the user brought', () {
    test('a WireGuard profile (what wgcf writes)', () {
      final r = parseWarpAccount('''
[Interface]
PrivateKey = $_priv
Address = 172.16.0.2/32
Address = 2606:4700:110:8a36:df92:102a:9602:fa18/128
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = $_pub
AllowedIPs = 0.0.0.0/0
Endpoint = engage.cloudflareclient.com:2408
''');
      expect(r.problem, isNull);
      final a = r.account!;
      expect(a.privateKey, _priv);
      expect(a.peerPublicKey, _pub);
      expect(a.v4, '172.16.0.2');
      expect(a.v6, '2606:4700:110:8a36:df92:102a:9602:fa18');
      expect(a.reserved, [0, 0, 0]);
    });

    test('the peer key is the one of Cloudflare when the profile has none, and the addresses may be on one line', () {
      final r = parseWarpAccount('PrivateKey = $_priv\nAddress = 172.16.0.2/32, 2606:4700:110::1/128\nReserved = 1, 2, 3');
      expect(r.account!.peerPublicKey, warpPeerPublicKey);
      expect(r.account!.reserved, [1, 2, 3]);
      expect(warpKeyOf(warpPeerPublicKey), warpPeerPublicKey);
    });

    test('JSON with the names the service and the tools use', () {
      final r = parseWarpAccount(jsonEncode({
        'private_key': _priv,
        'peer_public_key': _pub,
        'v4': '172.16.0.2',
        'v6': '2606:4700:110::1',
        'reserved': [12, 34, 56],
      }));
      expect(r.account!.reserved, [12, 34, 56]);
      expect(r.account!.v6, '2606:4700:110::1');
      // The account the app keeps is read back from its own file.
      expect(WarpAccount.fromJson(r.account!.toJson())!.privateKey, _priv);
    });

    test('the reserved field overrides the profile, and takes the client_id too', () {
      final text = 'PrivateKey = $_priv\nAddress = 172.16.0.2/32, 2606:4700:110::1/128\nReserved = 1,2,3';
      expect(parseWarpAccount(text, reserved: '9 8 7').account!.reserved, [9, 8, 7]);
      expect(parseWarpAccount(text, reserved: base64.encode([5, 6, 7])).account!.reserved, [5, 6, 7]);
      expect(parseWarpAccount(text, reserved: '1,2,300').problem, 'warpImportReserved');
      expect(parseWarpAccount(text, reserved: 'nonsense').problem, 'warpImportReserved');
      expect(parseWarpReserved(''), [0, 0, 0]);
      expect(parseWarpReserved('[7, 8, 9]'), [7, 8, 9]);
    });

    test('a key in the URL-safe form, without padding or with a space for the plus, is the same key', () {
      final bytes = List<int>.generate(32, (i) => 250 - i);
      final standard = base64.encode(bytes);
      expect(standard, contains('+'));
      expect(warpKeyOf(base64Url.encode(bytes)), standard);
      expect(warpKeyOf(standard.replaceAll('=', '')), standard);
      expect(warpKeyOf(standard.replaceAll('+', ' ')), standard);
      expect(warpKeyOf(base64.encode(List.filled(31, 1))), isNull);
      expect(warpKeyOf('not a key'), isNull);
    });

    test('says what is wrong', () {
      const addr = 'Address = 172.16.0.2/32, 2606:4700:110::1/128';
      expect(parseWarpAccount('   ').problem, 'warpImportEmpty');
      expect(parseWarpAccount('{not json').problem, 'warpImportEmpty');
      expect(parseWarpAccount(addr).problem, 'warpImportKey');
      expect(parseWarpAccount('PrivateKey = abc\n$addr').problem, 'warpImportKey');
      expect(parseWarpAccount('PrivateKey = $_priv\nPublicKey = abc\n$addr').problem, 'warpImportPeer');
      expect(parseWarpAccount('PrivateKey = $_priv\nAddress = 172.16.0.2/32').problem, 'warpImportAddr');
      expect(parseWarpAccount('PrivateKey = $_priv\nAddress = 2606:4700:110::1/128').problem, 'warpImportAddr');
      expect(parseWarpAccount('PrivateKey = $_priv\nAddress = 1.2.3, 2606:4700:110::1').problem, 'warpImportAddr');
    });
  });
}
