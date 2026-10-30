import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/net_options.dart';
import 'package:kumo/core/proxy_config.dart';
import 'package:kumo/core/singbox_config.dart';
import 'package:kumo/core/sub_formats.dart';

String _pem(String type) => '-----BEGIN $type-----\nMIIBfake\n-----END $type-----';

void main() {
  test('an OpenVPN server is sent out through the adapter of OpenVPN, by sing-box', () {
    final ovpn = '''
client
dev tun
remote vpn.example.com 1194 udp
auth-user-pass
<ca>
${_pem('CERTIFICATE')}
</ca>
''';
    final c = parseLink(extractSubscriptionLinks(ovpn).single)!;
    final o = NetOptions()
      ..tun = true
      ..proxyPort = 38900;
    final j = jsonDecode(buildSingBoxConfig([c],
        options: o, apiPort: 38901, apiSecret: 'x', windows: true, ovpnInterface: 'KumoOpenVPN')) as Map<String, dynamic>;
    final outbounds = (j['outbounds'] as List).cast<Map<String, dynamic>>();
    final proxy = outbounds.singleWhere((e) => e['tag'] == 'proxy');
    expect(proxy['type'], 'direct');
    expect(proxy['bind_interface'], 'KumoOpenVPN');
    // The other outbound for what bypasses the VPN is not bound to it.
    final direct = outbounds.singleWhere((e) => e['tag'] == 'direct');
    expect(direct.containsKey('bind_interface'), isFalse);
    // Nothing of the OpenVPN configuration (certificates, login) goes into the sing-box configuration.
    expect(jsonEncode(j), isNot(contains('CERTIFICATE')));
    expect(jsonEncode(j), isNot(contains('vpn.example.com')));
    expect((j['dns'] as Map)['servers'].toString(), contains('proxy'));
    // The names are looked up through the tunnel before the traffic goes out, and by nobody else.
    final rules = ((j['route'] as Map)['rules'] as List).cast<Map<String, dynamic>>();
    expect(rules.last, {'action': 'resolve', 'server': 'dns-remote', 'strategy': 'ipv4_only'});
  });
}
