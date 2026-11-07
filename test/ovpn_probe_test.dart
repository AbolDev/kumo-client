import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/ovpn/ovpn_probe.dart';
import 'package:kumo/core/ovpn/ovpn_profile.dart';
import 'package:kumo/core/proxy_config.dart';

String _pem(String type) => '-----BEGIN $type-----\nMIIBfake\n-----END $type-----';

OvpnServer _server(String remote, {String extra = ''}) => OvpnServer(parseOvpn('''
client
dev tun
$remote
$extra
<ca>
${_pem('CERTIFICATE')}
</ca>
<cert>
${_pem('CERTIFICATE')}
</cert>
<key>
${_pem('PRIVATE KEY')}
</key>
'''));

void main() {
  test('a server that wants signed packets is noticed', () {
    expect(ovpnSigned('client\ntls-auth ta.key 1\n'), isTrue);
    expect(ovpnSigned('<tls-crypt>\nx\n</tls-crypt>'), isTrue);
    expect(ovpnSigned('client\nproto udp\n'), isFalse);
  });

  test('a UDP server that answers with the first packet of the protocol is timed', () async {
    final server = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((e) {
      final d = server.receive();
      if (d == null) return;
      // opcode 7 with key 0 is what a client sends first; the server answers with opcode 8.
      expect(d.data[0], 0x38);
      server.send([0x40, ...List.filled(8, 1), 0, 0, 0, 0, 0], d.address, d.port);
    });
    final ms = await udpProbe('127.0.0.1', server.port);
    expect(ms, greaterThanOrEqualTo(1));
    final profile = _server('remote 127.0.0.1 ${server.port} udp');
    expect(await ovpnPing(profile), greaterThanOrEqualTo(1));
    server.close();
  });

  test('a UDP port where nothing answers is -1, and one that is signed cannot be told (-2)', () async {
    final quiet = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    expect(await udpProbe('127.0.0.1', quiet.port, timeout: const Duration(milliseconds: 400)), -1);
    expect(await ovpnPing(_server('remote 127.0.0.1 ${quiet.port} udp'), timeout: const Duration(milliseconds: 400)), -1);
    final signed = _server('remote 127.0.0.1 ${quiet.port} udp', extra: '<tls-crypt>\n${_pem('OpenVPN Static key V1')}\n</tls-crypt>');
    expect(await ovpnPing(signed), -2);
    quiet.close();
  });

  test('a TCP server is timed by a connect, and a closed port is -1', () async {
    final tcp = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    tcp.listen((s) => s.destroy());
    expect(await ovpnPing(_server('remote 127.0.0.1 ${tcp.port} tcp')), greaterThanOrEqualTo(1));
    final port = tcp.port;
    await tcp.close();
    expect(await ovpnPing(_server('remote 127.0.0.1 $port tcp'), timeout: const Duration(seconds: 1)), -1);
  });

  test('without the program, or with a login that is not given, the handshake test is skipped (-2)', () async {
    expect(await ovpnHandshake(_server('remote 127.0.0.1 1194 udp'), binary: r'C:\nope\openvpn.exe'), -2);
    final login = OvpnServer(parseOvpn('''
client
dev tun
remote 127.0.0.1 1194 udp
auth-user-pass
<ca>
${_pem('CERTIFICATE')}
</ca>
'''));
    expect(await ovpnHandshake(login, binary: Platform.resolvedExecutable), -2);
  });
}
