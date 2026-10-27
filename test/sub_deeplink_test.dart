import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/sub_formats.dart';
import 'package:kumo/core/sub_surge.dart';

void main() {
  group('deep links', () {
    const url = 'https://example.com/sub/abc?token=1';
    final enc = Uri.encodeComponent(url);

    test('url parameter', () {
      expect(subscriptionDeepLink('clash://install-config?url=$enc')?.url, url);
      expect(subscriptionDeepLink('sing-box://import-remote-profile?url=$enc#My%20plan')?.name, 'My plan');
      expect(subscriptionDeepLink('v2rayng://install-config?url=$enc')?.url, url);
    });

    test('address inside the path', () {
      expect(subscriptionDeepLink('hiddify://import/$url')?.url, url);
      expect(subscriptionDeepLink('happ://add/$url#Name')?.name, 'Name');
      expect(subscriptionDeepLink('streisand://import/$enc')?.url, url);
    });

    test('sub:// holds the address in base64', () {
      final b = base64.encode(utf8.encode('$url#Home'));
      final d = subscriptionDeepLink('sub://$b');
      expect(d?.url, url);
      expect(d?.name, 'Home');
    });

    test('server links and plain addresses are not deep links', () {
      expect(subscriptionDeepLink('vless://id@host:443?security=tls#x'), isNull);
      expect(subscriptionDeepLink(url), isNull);
    });
  });

  group('Surge, Loon and Stash text', () {
    test('ss, vmess, trojan and socks5 lines', () {
      const text = '''
[Proxy]
A = ss, 1.2.3.4, 8388, encrypt-method=aes-256-gcm, password=pw
B = vmess, b.example.com, 443, username=6eb0ab9f-e17e-4a59-86ac-083fa8b0decf, ws=true, ws-path=/ws, ws-headers=Host:cdn.example.com, tls=true, sni=b.example.com
C = trojan, c.example.com, 443, password=secret, sni=c.example.com, skip-cert-verify=true
D = socks5, 5.6.7.8, 1080, user, pass
[Rule]
FINAL,DIRECT
''';
      final links = extractSubscriptionLinks(text);
      expect(links.length, 4);
      expect(links[0], startsWith('ss://'));
      expect(links[1], startsWith('vmess://'));
      expect(links[2], startsWith('trojan://'));
      expect(links[2], contains('allowInsecure=1'));
      expect(links[3], 'socks5://user:pass@5.6.7.8:1080#D');
    });

    test('plain text without proxy lines gives nothing', () {
      expect(surgeLinks('a = b\nc = d, e'), isEmpty);
    });
  });
}
