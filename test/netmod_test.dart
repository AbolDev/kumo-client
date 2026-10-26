import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/config_decryptor.dart';
import 'package:kumo/core/proxy_config.dart';
import 'package:kumo/core/sub_formats.dart';
import 'package:pointycastle/export.dart';

// A NetMod trojan config over websocket: the SNI (firefox.com) is a CDN front that the server's
// certificate does not cover, so it only connects without certificate verification.
const _nm =
    'nm-trojan://5gty1J000R3vZf5iVpcRJbgM+meqViDK+ADX0pC6b16L0WaXmET5CEOHcVj443ekzkGkqyHVIBMqwg+HOhizb7C6YdwFJZBU0IR1iMjxcXwBO2B3Rrz/hc576iGYODiIR4yH4W4ZxxjPYmrXjWswX7RWPG8oYihCE/CPlBihM6w0dF83w/VjCzWyBsh7+Is8ls9YWFcZp1uKhHx8XxeOS59Cx8rU/E60ae5whLm6otnWJeHblqoLpW1bwXIRHY8dO0PX9HZIZBMVPJrWEI5ERJmakNF5LM/Ybc+jm8yL8k76J7EbzGGiXRi63b+80w4gMhSJpbIftXrbzOvv+7327W6Lvq0XlNy6DTRnFHI0qB+DB/Wb/kTPm+x3JR7mgBxJ3//Oas2+/1kFHhTfRXIVgz2ZHonLLZgqqgWHP+rBxXU7NA4wNnJtsOPIfDkZHQZBhGOQjcMdb0IVCoANlePUp6LTWk0eMV1sfEnmlkLCeR5EzMMYC6TUjMiJWhZR9IbM4jjlUuOUuzGlNukqdy6eKPtOcSji150o7i0EYoQ4Se8V7ecPxL8RmvRt6Jr+VOI3SxqLkPQTJjQBcM1hLX/4dQ==';

/// Builds a NetMod file the way the app reads it: AES-ECB with PKCS#7 padding, then base64.
String _seal(String proto, String plain) {
  final data = utf8.encode(plain);
  final pad = 16 - data.length % 16;
  final padded = Uint8List.fromList([...data, ...List.filled(pad, pad)]);
  final aes = AESEngine()
    ..init(true, KeyParameter(Uint8List.fromList(utf8.encode('<n3t5yn4^n3tm0d>'))));
  final out = Uint8List(padded.length);
  for (var o = 0; o < padded.length; o += 16) {
    aes.processBlock(padded, o, out, o);
  }
  return '$proto://${base64.encode(out)}';
}

List<ProxyConfig> _open(String file) {
  final text = decryptProtected(
      Uint8List.fromList(utf8.encode(file)), 'clipboard.txt', '');
  return parseLinks(extractSubscriptionLinks(text));
}

bool? _insecure(ProxyConfig c) => (c.outbound['tls'] as Map)['insecure'] as bool?;

void main() {
  test('a NetMod trojan config is imported without certificate verification', () {
    final c = _open(_nm).single;
    expect(c.protocol, 'trojan');
    expect(_insecure(c), true);
    expect((c.outbound['tls'] as Map)['server_name'], 'firefox.com');
    expect(c.name, startsWith('@MiTiVPN'));
  });

  test('NetMod vmess (base64 or plain JSON), vless, hysteria2 and tuic are handled alike', () {
    final vmess = jsonEncode({
      'v': '2', 'ps': 'n', 'add': 'h.example.com', 'port': '443', 'id': 'u',
      'aid': '0', 'net': 'ws', 'path': '/p', 'tls': 'tls', 'sni': 'front.com',
    });
    expect(_insecure(_open(_seal('nm-vmess', base64.encode(utf8.encode(vmess)))).single), true);
    expect(_insecure(_open(_seal('nm-vmess', vmess)).single), true);
    expect(_insecure(_open(_seal('nm-vless',
            'id@h.example.com:443?security=tls&sni=front.com&type=ws#v')).single),
        true);
    expect(_insecure(_open(_seal('nm-hysteria2', 'pw@h.example.com:443?sni=front.com#h')).single), true);
    expect(_insecure(_open(_seal('nm-tuic', 'id:pw@h.example.com:443?sni=front.com#t')).single), true);
  });

  test('NetMod configs that already say how to verify, or have no TLS, are left alone', () {
    final reality = _open(_seal('nm-vless',
        'id@h.example.com:443?security=reality&pbk=K&sni=front.com#r')).single;
    expect((reality.outbound['tls'] as Map)['insecure'], isNull);
    final plain = _open(_seal('nm-vless', 'id@h.example.com:443?type=tcp#p')).single;
    expect(plain.outbound['tls'], isNull);
  });

  test('a decrypted sing-box profile with a comment header is read', () {
    const text = '// ---- sing-box profile ----\n// name: prof\n\n'
        '{"outbounds":[{"type":"vless","tag":"x","server":"h.example.com",'
        '"server_port":443,"uuid":"u"}]}';
    expect(parseLinks(extractSubscriptionLinks(text)), hasLength(1));
  });
}
