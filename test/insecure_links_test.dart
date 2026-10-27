import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/proxy_config.dart';

Map<String, dynamic>? _tls(ProxyConfig c) => c.outbound['tls'] as Map<String, dynamic>?;

void main() {
  const vless =
      'vless://11111111-1111-1111-1111-111111111111@example.com:443?security=tls&sni=example.com&allowInsecure=1&type=tcp#My%20server';
  const hy2 = 'hysteria2://pass@example.com:443?sni=example.com&insecure=1#hy';
  const trojan = 'trojan://pw@example.com:443?allow_insecure=1&sni=example.com';

  test('the part that skips the certificate check is taken out, the rest stays', () {
    expect(secureLink(vless),
        'vless://11111111-1111-1111-1111-111111111111@example.com:443?security=tls&sni=example.com&type=tcp#My%20server');
    expect(secureLink(hy2), 'hysteria2://pass@example.com:443?sni=example.com#hy');
    expect(secureLink(trojan), 'trojan://pw@example.com:443?sni=example.com');
    expect(secureLink('trojan://pw@example.com:443?insecure=1#x'), 'trojan://pw@example.com:443#x');
  });

  test('a link without the option is not touched', () {
    const plain = 'vless://u@example.com:443?security=tls&sni=example.com#n';
    expect(secureLink(plain), plain);
    expect(asksInsecure(plain), isFalse);
    expect(asksInsecure(vless), isTrue);
    expect(secureLink('not a link'), 'not a link');
  });

  test('vmess keeps its name and loses the option', () {
    final json = jsonEncode({
      'v': '2', 'ps': 'vm', 'add': 'example.com', 'port': '443', 'id': '11111111-1111-1111-1111-111111111111',
      'net': 'tcp', 'tls': 'tls', 'sni': 'example.com', 'allowInsecure': true,
    });
    final link = 'vmess://${base64.encode(utf8.encode(json))}';
    expect(asksInsecure(link), isTrue);
    final safe = secureLink(link);
    final back = jsonDecode(utf8.decode(base64.decode(safe.substring(8)))) as Map;
    expect(back.containsKey('allowInsecure'), isFalse);
    expect(back['add'], 'example.com');
  });

  test('parsed in secure mode the certificate is checked, and the saved link is the original', () {
    final loose = parseLinks([vless, hy2, trojan]);
    expect(loose.map((c) => _tls(c)?['insecure']), everyElement(true));

    final strict = parseLinks([vless, hy2, trojan], secure: true);
    expect(strict.length, 3);
    expect(strict.map((c) => _tls(c)?['insecure']), everyElement(anyOf(isNull, false)));
    // The link is kept as it came, so turning the option on later brings the old behaviour back.
    expect(strict.map((c) => c.link), [vless, hy2, trojan]);
    expect(strict.first.name, 'My server');
  });

  test('a pinned certificate stays: the pin is a check of its own', () {
    const pinned =
        'vless://u@example.com:443?security=tls&sni=example.com&pcs=abcdef0123&allowInsecure=1&type=tcp#p';
    final c = parseLinks([pinned], secure: true).single;
    expect(_tls(c)?['insecure'], true);
  });
}
