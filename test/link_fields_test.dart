import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/link_fields.dart';
import 'package:kumo/core/proxy_config.dart';

void main() {
  test('vless link survives a form round trip', () {
    const link =
        'vless://11111111-2222-3333-4444-555555555555@example.com:443?security=tls&sni=a.com&type=ws&path=%2Fx#My%20Node';
    final f = LinkFields.parse(link)!;
    expect(f.host, 'example.com');
    expect(f.name, 'My Node');
    f.port = '8443';
    f.params['sni'] = 'b.com';
    final c = parseLink(f.build())!;
    expect(c.port, 8443);
    expect(c.name, 'My Node');
    expect(f.build(), contains('sni=b.com'));
  });

  test('vmess and shadowsocks round trip', () {
    final vmess = 'vmess://${base64.encode(utf8.encode(jsonEncode({
          'ps': 'n',
          'add': 'h.com',
          'port': '443',
          'id': 'u',
          'net': 'ws',
          'tls': 'tls'
        })))}';
    final v = LinkFields.parse(vmess)!;
    v.host = 'z.com';
    expect(parseLink(v.build())!.host, 'z.com');

    final user =
        base64Url.encode(utf8.encode('aes-256-gcm:secret')).replaceAll('=', '');
    final s = LinkFields.parse('ss://$user@1.2.3.4:8388#s')!;
    expect(s.secret, 'secret');
    s.port = '9000';
    final c = parseLink(s.build())!;
    expect(c.port, 9000);
    expect(c.outbound['password'], 'secret');
  });
}
