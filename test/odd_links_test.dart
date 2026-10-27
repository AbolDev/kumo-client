import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/proxy_config.dart';

void main() {
  test('a vmess link with a #name after the base64 text is read', () {
    final json = jsonEncode({
      'v': '2',
      'ps': '',
      'add': '38.91.107.49',
      'port': '18000',
      'id': 'f8c8dc3d-0d37-46b0-8b34-a7232882fcfe',
      'aid': '0',
      'net': 'tcp',
    });
    final c = parseLink('vmess://${base64.encode(utf8.encode(json))}#My%20server');
    expect(c, isNotNull);
    expect(c!.host, '38.91.107.49');
    expect(c.port, 18000);
    expect(c.name, 'My server');
    // the name inside the JSON wins over the one after it
    final named = jsonEncode({'v': '2', 'ps': 'Inside', 'add': '1.2.3.4', 'port': 443, 'id': 'f8c8dc3d-0d37-46b0-8b34-a7232882fcfe', 'net': 'tcp'});
    expect(parseLink('vmess://${base64.encode(utf8.encode(named))}#Outside')!.name, 'Inside');
  });

  test('a trojan password with # and < written without escaping is kept whole', () {
    final c = parseLink("trojan://8r<[9'l6hAO#8ZQi@104.16.7.70:443?security=tls&type=ws&path=/tr&sni=a.example.dev#EPODON");
    expect(c, isNotNull);
    expect(c!.host, '104.16.7.70');
    expect(c.port, 443);
    expect(c.outbound['password'], "8r<[9'l6hAO#8ZQi");
  });

  test('a hysteria2 password with an @ in it is kept whole', () {
    final c = parseLink('hysteria2://Telegram@vpnjey@179.61.138.145:54759?insecure=1&sni=example.com');
    expect(c, isNotNull);
    expect(c!.host, '179.61.138.145');
    expect(c.port, 54759);
    expect(c.outbound['password'], 'Telegram@vpnjey');
  });

  test('normal links are read as before', () {
    final c = parseLink('trojan://pw@h1.example.com:443#a');
    expect(c!.host, 'h1.example.com');
    expect(c.name, 'a');
  });
}
