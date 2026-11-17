import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/proxy_config.dart';
import 'package:kumo/core/singbox_config.dart';

const _pin = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

Map<String, dynamic> _stream(ProxyConfig c) => c.xrayOutbound!['streamSettings'] as Map<String, dynamic>;
Map<String, dynamic> _masque(ProxyConfig c) => _stream(c)['masqueSettings'] as Map<String, dynamic>;
Map<String, dynamic> _tls(ProxyConfig c) => _stream(c)['tlsSettings'] as Map<String, dynamic>;

void main() {
  group('the link of a MASQUE server', () {
    test('a login and a name: HTTP/2 by default, Xray only, no WARP keys', () {
      final c = parseLink('masque://alice:s3cret@vpn.example.com:8443#Home')!;
      expect(c.protocol, 'masque');
      expect(c.name, 'Home');
      expect(c.host, 'vpn.example.com');
      expect(c.port, 8443);
      expect(c.needsXray, isTrue);
      expect(c.canSingBox, isFalse);
      expect(c.label, 'masque + h2');
      expect(c.xrayOutbound!['protocol'], 'masque');
      expect(c.xrayOutbound!['settings'], {'address': 'vpn.example.com', 'port': 8443});
      expect(_stream(c)['network'], 'masque');
      expect(_masque(c), {'user': 'alice', 'pass': 's3cret'});
      expect(_masque(c).containsKey('warp'), isFalse);
      expect(_stream(c)['security'], 'tls');
      expect(_tls(c), {'serverName': 'vpn.example.com', 'alpn': ['h2']});
    });

    test('an e-mail address as the user name, the port 443 and a name when the link has none', () {
      final c = parseLink('masque://alice%40example.com:p%3Aw@vpn.example.com')!;
      expect(c.port, 443);
      expect(c.name, 'masque vpn.example.com:443');
      expect(_masque(c), {'user': 'alice@example.com', 'pass': 'p:w'});
    });

    test('HTTP/3 has no fingerprint, HTTP/2 takes one', () {
      final h3 = parseLink('masque://u:p@h.example.com?alpn=h3&fp=chrome')!;
      expect(_tls(h3)['alpn'], ['h3']);
      expect(_tls(h3).containsKey('fingerprint'), isFalse);
      expect(h3.label, 'masque + h3');
      final h2 = parseLink('masque://u:p@h.example.com?fp=chrome')!;
      expect(_tls(h2)['fingerprint'], 'chrome');
    });

    test('a server name of its own, and none for an address with no name given', () {
      expect(_tls(parseLink('masque://u:p@1.2.3.4:443?sni=front.example.com')!)['serverName'], 'front.example.com');
      expect(_tls(parseLink('masque://u:p@1.2.3.4:443')!).containsKey('serverName'), isFalse);
    });

    test('the path and the name of the request, only when Xray takes them', () {
      final c = parseLink('masque://u:p@h.example.com?path=%2F.well-known%2Fmasque%2Fip%2F%7Btarget%7D%2F%7Bipproto%7D%2F&host=real.example.com:8443')!;
      expect(_masque(c)['path'], '/.well-known/masque/ip/{target}/{ipproto}/');
      expect(_masque(c)['host'], 'real.example.com:8443');
      expect(parseLink('masque://u:p@h.example.com?path=nope'), isNull);
      expect(parseLink('masque://u:p@h.example.com?path=%2Fa%7Bwhat%7D'), isNull);
      expect(parseLink('masque://u:p@h.example.com?host=bad%20host'), isNull);
      expect(parseLink('masque://u:p@h.example.com?host=a.example.com:99999'), isNull);
      // The port of the scheme itself, as Dart would drop it, stays as it was written.
      expect(_masque(parseLink('masque://u:p@h.example.com?host=a.example.com:443')!)['host'], 'a.example.com:443');
      expect(_masque(parseLink('masque://u:p@h.example.com?host=%5B2001:db8::1%5D:8443')!)['host'], '[2001:db8::1]:8443');
    });

    test('a pinned certificate stands for the check of the chain; a skipped check is refused', () {
      final c = parseLink('masque://u:p@h.example.com?pcs=${_pin.toUpperCase()}')!;
      expect(_tls(c)['pinnedPeerCertSha256'], _pin);
      expect(c.pinned, isTrue);
      final colons = _pin.replaceAllMapped(RegExp(r'..'), (m) => '${m[0]}:').replaceFirst(RegExp(r':$'), '');
      expect(_tls(parseLink('masque://u:p@h.example.com?pinSHA256=$colons')!)['pinnedPeerCertSha256'], _pin);
      expect(parseLink('masque://u:p@h.example.com?pcs=abc'), isNull);
      // Xray 26 cannot skip the check of a certificate.
      expect(parseLink('masque://u:p@h.example.com?insecure=1'), isNull);
      expect(parseLink('masque://u:p@h.example.com?allowInsecure=1'), isNull);
    });

    test('without a user name, a password or a host there is no server', () {
      expect(parseLink('masque://h.example.com:443'), isNull);
      expect(parseLink('masque://u@h.example.com:443'), isNull);
      expect(parseLink('masque://:p@h.example.com:443'), isNull);
      expect(parseLink('masque://u:p@:443'), isNull);
    });

    test('the Xray configuration has the outbound, with the login and the TLS settings', () {
      final c = parseLink('masque://alice:s3cret@vpn.example.com:8443?pcs=$_pin')!;
      final j = jsonDecode(buildXrayConfig(c, 33000)) as Map<String, dynamic>;
      final out = (j['outbounds'] as List).firstWhere((o) => o['tag'] == 'proxy') as Map<String, dynamic>;
      expect(out['protocol'], 'masque');
      expect(out['settings']['address'], 'vpn.example.com');
      expect(out['streamSettings']['masqueSettings']['user'], 'alice');
      expect(out['streamSettings']['tlsSettings']['pinnedPeerCertSha256'], _pin);
    });
  });

  group('the two kinds of MASQUE link are never taken for each other', () {
    const warp = 'warp-masque://162.159.198.2:443?priv=PRIV&pub=PUB&address=172.16.0.2/32&alpn=h2&sni=cloudflareaccess.com#WARP';

    test('the link of WARP stays one, and its name does not make a masque:// link', () {
      expect(parseLink(warp)!.xrayOutbound!['streamSettings']['masqueSettings'].containsKey('warp'), isTrue);
      expect(extractLinks('$warp\nvless://11111111-1111-1111-1111-111111111111@v.example.com:443?security=tls#V')
          .where((l) => l.startsWith('masque://')), isEmpty);
    });

    test('a subscription with a MASQUE server line, among others, gives that link whole', () {
      const mine = 'masque://alice:s3cret@vpn.example.com:8443?alpn=h2#Home';
      final links = extractLinks('vless://11111111-1111-1111-1111-111111111111@v.example.com:443?security=tls#V\n$mine');
      expect(links, contains(mine));
      expect(links.length, 2);
      expect(parseLinks(links).map((c) => c.protocol), containsAll(['vless', 'masque']));
    });
  });
}
