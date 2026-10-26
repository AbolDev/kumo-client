import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/net_options.dart';
import 'package:kumo/core/proxy_config.dart';
import 'package:kumo/core/singbox_config.dart';

void main() {
  test('vless + reality', () {
    final c = parseLink(
      'vless://11111111-2222-3333-4444-555555555555@example.com:443'
      '?security=reality&sni=www.microsoft.com&fp=chrome&pbk=PUBKEY&sid=ab12&type=tcp&flow=xtls-rprx-vision#My%20Node',
    )!;
    expect(c.name, 'My Node');
    expect(c.outbound['type'], 'vless');
    expect(c.outbound['flow'], 'xtls-rprx-vision');
    final tls = c.outbound['tls'] as Map;
    expect(tls['server_name'], 'www.microsoft.com');
    expect((tls['reality'] as Map)['public_key'], 'PUBKEY');
  });

  test('a certificate pin skips chain validation', () {
    final c = parseLink('trojan://pw@1.2.3.4:443?security=tls&sni=firefox.com'
        '&type=ws&path=%2Fx&pcs=abcd#pinned')!;
    expect((c.outbound['tls'] as Map)['insecure'], true);
    final plain = parseLink('trojan://pw@1.2.3.4:443?security=tls&sni=a.com#p')!;
    expect((plain.outbound['tls'] as Map)['insecure'], isNull);
  });

  test('websocket Host falls back to the SNI, unknown fingerprints are dropped', () {
    final c = parseLink('vless://id@1.2.3.4:443?security=tls&sni=cdn.example.com'
        '&type=ws&path=%2F&fp=none#a')!;
    expect(((c.outbound['transport'] as Map)['headers'] as Map)['Host'],
        'cdn.example.com');
    expect((c.outbound['tls'] as Map).containsKey('utls'), false);
    final f = parseLink('trojan://pw@h.com:443?fp=Firefox#a')!;
    expect(((f.outbound['tls'] as Map)['utls'] as Map)['fingerprint'], 'firefox');
  });

  test('hysteria2 port hopping', () {
    final a = parseLink('hysteria2://pw@h.com:443,5000-6000?sni=h.com#a')!;
    expect(a.port, 443);
    expect(a.outbound['server_ports'], ['5000:6000']);
    final b = parseLink('hy2://pw@h.com:443?mport=7000-8000#b')!;
    expect(b.outbound['server_ports'], ['7000:8000']);
  });

  test('vmess over websocket', () {
    final json = jsonEncode({
      'ps': 'ws node',
      'add': 'a.example.com',
      'port': '443',
      'id': 'uuid',
      'aid': '0',
      'net': 'ws',
      'path': '/p',
      'host': 'h.example.com',
      'tls': 'tls',
      'sni': 's.example.com',
    });
    final c = parseLink('vmess://${base64.encode(utf8.encode(json))}')!;
    expect(c.port, 443);
    expect((c.outbound['transport'] as Map)['type'], 'ws');
    expect((c.outbound['tls'] as Map)['server_name'], 's.example.com');
  });

  test('shadowsocks SIP002 and legacy forms', () {
    final userInfo =
        base64Url.encode(utf8.encode('aes-256-gcm:secret')).replaceAll('=', '');
    final a = parseLink('ss://$userInfo@1.2.3.4:8388#ss1')!;
    expect(a.outbound['method'], 'aes-256-gcm');
    expect(a.outbound['password'], 'secret');
    final legacy =
        base64.encode(utf8.encode('aes-256-gcm:secret@5.6.7.8:8399'));
    expect(parseLink('ss://$legacy#ss2')!.port, 8399);
  });

  test('unsupported transports are skipped', () {
    expect(
        parseLink('vless://id@example.com:443?type=kcp&security=tls'), isNull);
    expect(parseLink('vless://id@example.com:0?security=tls'), isNull);
  });

  test('xhttp servers are handed to xray through a local socks port', () {
    final c = parseLink(
      'vless://id@example.com:443?type=xhttp&security=tls&path=%2Fx&mode=packet-up&sni=example.com#x',
    )!;
    expect(c.needsXray, isTrue);
    expect(c.label, 'vless + xhttp');
    final xray = jsonDecode(buildXrayConfig(c, 31000)) as Map<String, dynamic>;
    expect((xray['inbounds'] as List).first['port'], 31000);
    final out = (xray['outbounds'] as List).first as Map<String, dynamic>;
    expect(out['streamSettings']['network'], 'xhttp');
    expect(out['streamSettings']['xhttpSettings']['mode'], 'packet-up');
    final box = jsonDecode(buildSingBoxConfig([c], xrayPort: 31000))
        as Map<String, dynamic>;
    final proxy = (box['outbounds'] as List).first as Map<String, dynamic>;
    expect(proxy['type'], 'socks');
    expect(proxy['server_port'], 31000);
  });

  test('addresses are masked in lists', () {
    expect(maskHost('1.2.3.4'), '1.2.***');
    expect(maskHost('sub.example.com'), 'sub***.com');
    expect(maskHost('2001:db8::1'), '200***:1');
  });

  test('extractLinks handles plain text and base64 subscriptions', () {
    const plain = 'vless://a@h:1?security=tls#a\ntrojan://p@h:2#b\n';
    expect(extractLinks(plain), hasLength(2));
    expect(extractLinks(base64.encode(utf8.encode(plain))), hasLength(2));
  });

  test('links are parsed in a background isolate', () async {
    final servers = await parseLinksInBackground([
      'trojan://p@h1.example.com:443#a',
      'trojan://p@h1.example.com:443#duplicate',
      'trojan://p@h2.example.com:443#b',
    ]);
    expect(servers, hasLength(2));
  });

  test('duplicates ignore the name but not the transport', () {
    final servers = parseLinks([
      'vless://id@h.com:443?security=tls&type=ws&path=%2Fa#one',
      'vless://id@h.com:443?security=tls&type=ws&path=%2Fa#two',
      'vless://id@h.com:443?security=tls&type=ws&path=%2Fb#three',
    ]);
    expect(servers.map((s) => s.name), ['one', 'three']);
  });

  test('the log level reaches the core configs and is saved with the options', () {
    final servers = parseLinks(['trojan://p@h1.example.com:443#a']);
    expect(
        (jsonDecode(buildSingBoxConfig(servers))['log'] as Map)['level'], 'error');
    final o = NetOptions()..logLevel = 'debug';
    expect(
        (jsonDecode(buildSingBoxConfig(servers, options: o))['log'] as Map)['level'],
        'debug');
    final restored = NetOptions()..load(o.toJson());
    expect(restored.logLevel, 'debug');
    expect(NetOptions()..load({'logLevel': 'nonsense'}), isA<NetOptions>());
    final x = parseLink('vless://id@example.com:443?type=xhttp&security=tls#x')!;
    expect(
        (jsonDecode(buildXrayConfig(x, 31000, logLevel: 'debug'))['log'] as Map)['loglevel'],
        'debug');
  });

  test('config uses urltest for several servers', () {
    final servers = parseLinks(
        ['trojan://p@h1.example.com:443#a', 'trojan://p@h2.example.com:443#b']);
    final cfg = jsonDecode(buildSingBoxConfig(servers)) as Map<String, dynamic>;
    final outbounds = (cfg['outbounds'] as List).cast<Map>();
    expect(outbounds.first['type'], 'urltest');
    expect(outbounds.where((o) => o['tag'].toString().startsWith('server-')),
        hasLength(2));
  });
}
