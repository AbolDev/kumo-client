import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/ovpn/ovpn_profile.dart';
import 'package:kumo/core/ovpn/ovpn_runner.dart';
import 'package:kumo/core/proxy_config.dart';

String _pem(String type) => '-----BEGIN $type-----\nMIIBfake\n-----END $type-----';

OvpnServer _server({bool wantsLogin = false, String? user, String? pass}) {
  final text = '''
client
dev tun
remote 192.0.2.1 1194 udp
${wantsLogin ? 'auth-user-pass' : ''}
<ca>
${_pem('CERTIFICATE')}
</ca>
<cert>
${_pem('CERTIFICATE')}
</cert>
<key>
${_pem('PRIVATE KEY')}
</key>
''';
  return OvpnServer(parseOvpn(text), username: user, password: pass);
}

void main() {
  test('a login that the file does not mention is asked for by adding auth-user-pass', () {
    final text = withLogin(_server(user: 'vpn', pass: 'vpn'));
    expect(RegExp(r'^auth-user-pass$', multiLine: true).hasMatch(text), isTrue);
  });

  test('nothing is added when the file asks for the login itself, or when there is none', () {
    final asks = withLogin(_server(wantsLogin: true, user: 'a', pass: 'b'));
    expect(RegExp(r'^auth-user-pass$', multiLine: true).allMatches(asks).length, 1);
    final none = withLogin(_server());
    expect(none.contains('auth-user-pass'), isFalse);
  });
}
