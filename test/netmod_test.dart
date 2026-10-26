import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/config_decryptor.dart';
import 'package:kumo/core/proxy_config.dart';
import 'package:kumo/core/sub_formats.dart';

// A NetMod trojan config over websocket: the SNI (firefox.com) is a CDN front that the server's
// certificate does not cover, so it only connects without certificate verification.
const _nm =
    'nm-trojan://5gty1J000R3vZf5iVpcRJbgM+meqViDK+ADX0pC6b16L0WaXmET5CEOHcVj443ekzkGkqyHVIBMqwg+HOhizb7C6YdwFJZBU0IR1iMjxcXwBO2B3Rrz/hc576iGYODiIR4yH4W4ZxxjPYmrXjWswX7RWPG8oYihCE/CPlBihM6w0dF83w/VjCzWyBsh7+Is8ls9YWFcZp1uKhHx8XxeOS59Cx8rU/E60ae5whLm6otnWJeHblqoLpW1bwXIRHY8dO0PX9HZIZBMVPJrWEI5ERJmakNF5LM/Ybc+jm8yL8k76J7EbzGGiXRi63b+80w4gMhSJpbIftXrbzOvv+7327W6Lvq0XlNy6DTRnFHI0qB+DB/Wb/kTPm+x3JR7mgBxJ3//Oas2+/1kFHhTfRXIVgz2ZHonLLZgqqgWHP+rBxXU7NA4wNnJtsOPIfDkZHQZBhGOQjcMdb0IVCoANlePUp6LTWk0eMV1sfEnmlkLCeR5EzMMYC6TUjMiJWhZR9IbM4jjlUuOUuzGlNukqdy6eKPtOcSji150o7i0EYoQ4Se8V7ecPxL8RmvRt6Jr+VOI3SxqLkPQTJjQBcM1hLX/4dQ==';

void main() {
  test('a NetMod trojan config is imported without certificate verification', () {
    final text = decryptProtected(
        Uint8List.fromList(utf8.encode(_nm)), 'clipboard.txt', '');
    final links = extractSubscriptionLinks(text);
    expect(links, hasLength(1));
    final c = parseLink(links.single)!;
    expect(c.protocol, 'trojan');
    expect((c.outbound['tls'] as Map)['insecure'], true);
    expect((c.outbound['tls'] as Map)['server_name'], 'firefox.com');
    expect(c.name, startsWith('@MiTiVPN'));
  });
}
