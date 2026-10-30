import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/ovpn/ovpn_profile.dart';

String pem(String type, [String body = 'MIIBfake']) => '-----BEGIN $type-----\n$body\n-----END $type-----';

String sample({String extra = '', bool login = false, bool cert = true, String remote = 'remote vpn.example.com 1194'}) => '''
client
dev tun
proto udp
$remote
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-CBC
auth SHA256
comp-lzo
verb 3
${login ? 'auth-user-pass' : ''}
$extra
<ca>
${pem('CERTIFICATE')}
</ca>
${cert ? '<cert>\n${pem('CERTIFICATE')}\n</cert>\n<key>\n${pem('PRIVATE KEY')}\n</key>' : ''}
<tls-crypt>
${pem('OpenVPN Static key V1', '00112233445566778899aabbccddeeff')}
</tls-crypt>
''';

void main() {
  group('a normal configuration', () {
    final p = parseOvpn(sample());

    test('gives the remote, and a configuration with only what was understood', () {
      expect(p.remotes, [const OvpnRemote('vpn.example.com', 1194, 'udp')]);
      expect(p.needsLogin, isFalse);
      expect(p.config, contains('remote vpn.example.com 1194 udp'));
      expect(p.config, contains('cipher AES-256-CBC'));
      expect(p.config, contains('auth SHA256'));
      expect(p.config, contains('remote-cert-tls server'));
      expect(p.config, contains('<ca>'));
      expect(p.config, contains('<tls-crypt>'));
      expect(p.blocked, isEmpty);
      expect(p.ignored, isEmpty);
    });

    test('is written the same way when it is read again', () {
      final again = parseOvpn(p.config);
      expect(again.config, p.config);
    });
  });

  group('the protocol and the port', () {
    test('a proto line after the remote still applies to it', () {
      final p = parseOvpn(sample(remote: 'remote a.example.com 443').replaceFirst('proto udp', 'proto tcp'));
      expect(p.remotes.single, const OvpnRemote('a.example.com', 443, 'tcp-client'));
    });

    test('a remote can name its own protocol, and the port line sets the default port', () {
      final p = parseOvpn(sample(remote: 'port 1195\nremote a.example.com\nremote b.example.com 443 tcp'));
      expect(p.remotes, [
        const OvpnRemote('a.example.com', 1195, 'udp'),
        const OvpnRemote('b.example.com', 443, 'tcp-client'),
      ]);
    });

    test('connection blocks each have their own', () {
      final base = sample(remote: '').replaceFirst('proto udp', '');
      final text = '$base\n<connection>\nremote a.example.com 443\nproto tcp\n</connection>\n'
          '<connection>\nremote b.example.com 1194\nproto udp\n</connection>\n';
      final p = parseOvpn(text);
      expect(p.remotes, [
        const OvpnRemote('a.example.com', 443, 'tcp-client'),
        const OvpnRemote('b.example.com', 1194, 'udp'),
      ]);
    });

    test('with no port at all it is 1194', () {
      expect(parseOvpn(sample(remote: 'remote a.example.com')).remotes.single.port, 1194);
    });

    test('an IPv6 address and a bad port', () {
      expect(parseOvpn(sample(remote: 'remote 2001:db8::1 443')).remotes.single.host, '2001:db8::1');
      expect(() => parseOvpn(sample(remote: 'remote a.example.com 99999')), throwsA(isA<OvpnException>()));
      expect(() => parseOvpn(sample(remote: 'remote bad host!.example 1194')), throwsA(isA<OvpnException>()));
    });
  });

  group('what a file may not make Kumo do', () {
    test('lines that run programs, open a control port or write files are left out and reported', () {
      final p = parseOvpn(sample(extra: '''
script-security 2
up /bin/sh -c "calc.exe"
down /tmp/x.sh
route-up "cmd /c evil"
tls-verify /tmp/v.sh
plugin /lib/evil.so
management 127.0.0.1 7505
log /etc/passwd
config /etc/other.conf
setenv FOO bar
dev-node /dev/net/tun
'''));
      for (final w in ['script-security', 'up', 'down', 'route-up', 'tls-verify', 'plugin', 'management', 'log', 'config', 'setenv', 'dev-node']) {
        expect(p.blocked, contains(w));
        expect(RegExp('^$w\\b', multiLine: true).hasMatch(p.config), isFalse, reason: w);
      }
      expect(p.config, isNot(contains('/bin/sh')));
      expect(p.config, isNot(contains('calc.exe')));
      expect(p.config, isNot(contains('evil')));
    });

    test('a block that is not known is left out, and an unknown line is reported', () {
      final p = parseOvpn('${sample(extra: 'frobnicate 7')}\n<up>\nrm -rf\n</up>\n');
      expect(p.ignored, contains('frobnicate'));
      expect(p.blocked, contains('<up>'));
      expect(p.config, isNot(contains('rm -rf')));
    });

    test('a value with a quote or a backslash cannot add a line', () {
      final p = parseOvpn(sample(extra: r'verify-x509-name "Server \"X\" Name" name'));
      final line = p.config.split('\n').firstWhere((l) => l.startsWith('verify-x509-name'));
      expect(line, r'verify-x509-name "Server \"X\" Name" name');
      expect(p.config.split('\n').where((l) => l.startsWith('verify-x509-name')).length, 1);
    });

    test('a value that is not plain is not copied', () {
      final p = parseOvpn(sample(extra: 'cipher AES-256-CBC;calc'));
      expect(p.config, isNot(contains('calc')));
      expect(p.ignored, contains('cipher'));
    });

    test('route lines and the like are not used, and not reported (Kumo decides the routes)', () {
      final p = parseOvpn(sample(extra: 'redirect-gateway def1\nroute 10.0.0.0 255.0.0.0\ndhcp-option DNS 8.8.8.8\npull-filter ignore x'));
      expect(p.config, isNot(contains('redirect-gateway')));
      expect(p.config, isNot(contains('dhcp-option')));
      expect(p.ignored, isEmpty);
      expect(p.blocked, isEmpty);
    });
  });

  group('the login', () {
    test('auth-user-pass means a login is needed', () {
      final p = parseOvpn(sample(login: true, cert: false));
      expect(p.needsLogin, isTrue);
      expect(p.config, contains('auth-user-pass'));
      expect(p.username, isNull);
    });

    test('a credentials file that comes with the configuration is read, and not named in the result', () {
      final p = parseOvpn(sample(cert: false).replaceFirst('verb 3', 'auth-user-pass creds.txt'),
          files: {'creds.txt': 'alice\nsecret\n'});
      expect(p.username, 'alice');
      expect(p.password, 'secret');
      expect(p.config, isNot(contains('creds.txt')));
      expect(p.config, isNot(contains('secret')));
    });

    test('a credentials file that is not given is not an error', () {
      final p = parseOvpn(sample(cert: false).replaceFirst('verb 3', 'auth-user-pass creds.txt'));
      expect(p.needsLogin, isTrue);
      expect(p.username, isNull);
    });

    test('an encrypted private key is noticed', () {
      final text = sample().replaceFirst(pem('PRIVATE KEY'), pem('ENCRYPTED PRIVATE KEY'));
      expect(parseOvpn(text).needsKeyPassword, isTrue);
      expect(parseOvpn(sample()).needsKeyPassword, isFalse);
    });
  });

  group('files named by the configuration', () {
    final named = sample()
        .replaceAll(RegExp(r'<ca>[\s\S]*?</ca>\n'), 'ca ca.crt\n')
        .replaceAll(RegExp(r'<cert>[\s\S]*?</cert>\n'), 'cert client.crt\n')
        .replaceAll(RegExp(r'<key>[\s\S]*?</key>\n'), 'key client.key\n')
        .replaceAll(RegExp(r'<tls-crypt>[\s\S]*?</tls-crypt>\n'), 'tls-crypt tc.key\n');

    test('are asked for by name when they are missing', () {
      try {
        parseOvpn(named);
        fail('should throw');
      } on OvpnException catch (e) {
        expect(e.missingFiles.toSet(), {'ca.crt', 'client.crt', 'client.key', 'tc.key'});
      }
    });

    test('are put inside when they are given (the path is only a name)', () {
      final p = parseOvpn(named, files: {
        'ca.crt': pem('CERTIFICATE'),
        'client.crt': pem('CERTIFICATE'),
        'client.key': pem('PRIVATE KEY'),
        'tc.key': pem('OpenVPN Static key V1'),
      });
      expect(p.config, contains('<ca>'));
      expect(p.config, contains('<tls-crypt>'));
      expect(p.config, isNot(contains('ca.crt')));
    });
  });

  group('what cannot be used', () {
    test('a TAP device', () => expect(() => parseOvpn(sample().replaceFirst('dev tun', 'dev tap')), throwsA(isA<OvpnException>())));
    test('a shared static key', () => expect(() => parseOvpn('${sample()}\nsecret static.key'), throwsA(isA<OvpnException>())));
    test('no remote', () => expect(() => parseOvpn(sample(remote: '')), throwsA(isA<OvpnException>())));
    test('not a client', () => expect(() => parseOvpn(sample().replaceFirst('client\n', '')), throwsA(isA<OvpnException>())));
    test('no authority to check the server with', () {
      expect(() => parseOvpn(sample().replaceAll(RegExp(r'<ca>[\s\S]*?</ca>\n'), '')), throwsA(isA<OvpnException>()));
    });
    test('neither a certificate nor a login', () {
      expect(() => parseOvpn(sample(cert: false)), throwsA(isA<OvpnException>()));
    });
    test('a block that is wrong for its name', () {
      expect(() => parseOvpn(sample().replaceFirst(pem('PRIVATE KEY'), pem('CERTIFICATE'))), throwsA(isA<OvpnException>()));
    });
    test('a block that is not closed, and a quote that is not closed', () {
      expect(() => parseOvpn('${sample()}\n<extra-certs>\nx'), throwsA(isA<OvpnException>()));
      expect(() => parseOvpn('${sample()}\ncipher "AES'), throwsA(isA<OvpnException>()));
    });
    test('a file that is far too large', () => expect(() => parseOvpn('x' * 300000), throwsA(isA<OvpnException>())));
  });

  test('comments, tabs, CRLF and a BOM do not matter', () {
    final bom = String.fromCharCode(0xFEFF);
    final text = '$bom${sample().replaceAll('\n', '\r\n').replaceFirst('nobind', '# a comment\r\n;another\r\n\tnobind')}';
    final p = parseOvpn(text);
    expect(p.remotes.single.host, 'vpn.example.com');
  });

  test('which texts look like a configuration', () {
    expect(looksLikeOvpn(sample()), isTrue);
    expect(looksLikeOvpn('[Interface]\nPrivateKey = x\n[Peer]\nEndpoint = a:1\n'), isFalse);
    expect(looksLikeOvpn('vless://abc@host:443#x'), isFalse);
    expect(looksLikeOvpn(''), isFalse);
  });

  test('the link holds the configuration, the login and the name', () {
    final p = parseOvpn(sample(login: true, cert: false));
    final link = ovpnLink(p, username: 'al ice', password: 'p&ss=1', name: 'My VPN');
    expect(link, startsWith('openvpn://'));
    final body = link.substring('openvpn://'.length, link.indexOf('?'));
    expect(utf8.decode(base64Url.decode(base64Url.normalize(body))), p.config);
    final u = Uri.parse(link);
    expect(u.queryParameters['user'], 'al ice');
    expect(u.queryParameters['pass'], 'p&ss=1');
    expect(Uri.decodeComponent(u.fragment), 'My VPN');
  });
}
