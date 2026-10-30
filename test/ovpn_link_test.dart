import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/proxy_config.dart';
import 'package:kumo/core/sub_formats.dart';

String _pem(String type) => '-----BEGIN $type-----\nMIIBfake\n-----END $type-----';

final _ovpn = '''
client
dev tun
proto tcp
remote vpn.example.com 443
cipher AES-256-GCM
auth-user-pass
script-security 2
up /bin/evil.sh
<ca>
${_pem('CERTIFICATE')}
</ca>
''';

void main() {
  test('an .ovpn text becomes one openvpn link, which reads back as a server', () {
    final links = extractSubscriptionLinks(_ovpn);
    expect(links.length, 1);
    expect(links.single, startsWith('openvpn://'));
    final c = parseLink(links.single)!;
    expect(c.isOpenVpn, isTrue);
    expect(c.protocol, 'openvpn');
    expect(c.host, 'vpn.example.com');
    expect(c.port, 443);
    expect(c.label, 'openvpn');
    expect(c.canSingBox, isFalse);
    expect(c.needsXray, isFalse);
    expect(c.ovpn!.needsLogin, isTrue);
    expect(c.ovpn!.profile.config, isNot(contains('evil')));
  });

  test('the link is read again, so a crafted link cannot bring a line that the reader would drop', () {
    final good = extractSubscriptionLinks(_ovpn).single;
    expect(parseLink(good)!.ovpn!.profile.blocked, isEmpty, reason: 'the link holds the clean text');
    // A link whose text is not a valid configuration is not a server.
    expect(parseLink('openvpn://AAAA#x'), isNull);
    expect(parseLink('openvpn://!!!#x'), isNull);
  });

  test('the same configuration is the same server (the name does not matter)', () {
    final a = parseLink(extractSubscriptionLinks(_ovpn).single)!;
    final b = parseLink('${extractSubscriptionLinks(_ovpn).single.split('#').first}#Another name')!;
    expect(a.key, b.key);
    expect(b.name, 'Another name');
  });

  test('links of other kinds still work next to it', () {
    final text = 'vless://11111111-1111-1111-1111-111111111111@v.example.com:443?security=tls#A\n'
        '${extractSubscriptionLinks(_ovpn).single}';
    final all = parseLinks(extractLinks(text));
    expect(all.map((c) => c.protocol).toSet(), {'vless', 'openvpn'});
  });
}
