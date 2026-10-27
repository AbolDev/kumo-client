import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/proxy_config.dart';
import 'package:kumo/core/singbox_config.dart';
import 'package:kumo/core/sub_formats.dart';

const _clash = '''
proxies:
  - name: "a ws"
    type: vless
    server: example.com
    port: 443
    uuid: 11111111-2222-3333-4444-555555555555
    network: ws
    tls: true
    servername: sni.example.com
    ws-opts:
      path: /p
      headers:
        Host: h.example.com
  - name: ss1
    type: ss
    server: 1.2.3.4
    port: 8388
    cipher: aes-128-gcm
    password: pw
  - name: tj
    type: trojan
    server: t.example.com
    port: 443
    password: secret
    sni: t.example.com
''';

void main() {
  test('hysteria2 port hopping survives the conversion from clash and sing-box', () {
    final clash = extractSubscriptionLinks('''
proxies:
  - name: hy
    type: hysteria2
    server: h.example.com
    port: 443
    ports: 5000-6000
    password: pw
''');
    expect(parseLinks(clash).single.outbound['server_ports'], ['5000:6000']);
    final box = extractSubscriptionLinks(
        '{"outbounds":[{"type":"hysteria2","tag":"hy","server":"h.example.com",'
        '"server_port":443,"server_ports":["7000:8000"],"password":"pw"}]}');
    expect(parseLinks(box).single.outbound['server_ports'], ['7000:8000']);
  });

  test('clash yaml becomes links that parse', () {
    final links = extractSubscriptionLinks(_clash);
    expect(links.length, 3);
    expect(parseLinks(links).length, 3);
  });

  test('sing-box json outbounds become links', () {
    const body =
        '{"outbounds":[{"type":"vless","tag":"x","server":"h.example.com","server_port":443,"uuid":"u","tls":{"enabled":true,"server_name":"s"},"transport":{"type":"ws","path":"/w"}},{"type":"direct","tag":"d"}]}';
    final links = extractSubscriptionLinks(body);
    expect(links.length, 1);
    expect(parseLinks(links).single.protocol, 'vless');
  });

  test('sip008 and plain lists', () {
    expect(
        extractSubscriptionLinks(
                '{"servers":[{"server":"1.1.1.1","server_port":1,"method":"aes-128-gcm","password":"p","remarks":"r"}]}')
            .length,
        1);
    expect(extractSubscriptionLinks('vless://u@h:443?type=tcp#n').length, 1);
  });

  test('plain xhttp vless goes through a loopback relay', () {
    final c = parseLink(
        'vless://u@8.8.8.8:80?type=xhttp&security=none&encryption=none&path=%2F#x')!;
    final cfg = buildXrayConfig(c, 40000);
    expect(cfg, contains('dokodemo-door'));
    expect(cfg, contains('"address": "127.0.0.1"'));
  });
}
