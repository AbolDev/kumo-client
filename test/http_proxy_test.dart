import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/proxy_config.dart';
import 'package:kumo/core/sub_formats.dart';

void main() {
  group('an HTTP proxy and a subscription are never taken for each other', () {
    test('proxies: a port, no path, and a login or an IP address', () {
      for (final link in [
        'http://user:pass@example.com:8080',
        'http://1.2.3.4:3128',
        'http://1.2.3.4:80/',
        'https://u:p@proxy.example.com:443#Office',
        'http://[2001:db8::1]:8080',
        'https://u:p@proxy.example.com:8443?sni=front.example.com&insecure=1',
      ]) {
        expect(isHttpProxyLink(link), isTrue, reason: link);
      }
    });

    test('subscriptions and pages: a path, a query of their own, or a name with no login', () {
      for (final link in [
        'https://sub.example.com/sub/abc',
        'https://example.com:2096/sub/token',
        'https://example.com',
        'http://example.com:8080',
        'https://1.2.3.4:2096/link?token=x',
        'https://1.2.3.4:2096?token=x',
        'https://u:p@1.2.3.4:2096/sub',
        'https://t.me/channel',
        'https://raw.githubusercontent.com/a/b/main/list.txt',
      ]) {
        expect(isHttpProxyLink(link), isFalse, reason: link);
      }
    });

    test('in a text only a whole word that is a proxy is taken, never a page or part of another link', () {
      const text = 'Sub: https://sub.example.com/sub/abc\n'
          'http://u:p@1.2.3.4:8080#Office\n'
          'vless://11111111-1111-1111-1111-111111111111@v.example.com:443?security=tls&type=ws&host=http://1.2.3.4:80#V';
      final links = extractLinks(text);
      expect(links, contains('http://u:p@1.2.3.4:8080#Office'));
      expect(links.where((l) => l.startsWith('vless://')).single, endsWith('#V'));
      expect(links.any((l) => l.contains('sub.example.com')), isFalse);
      expect(links.length, 2);
    });

    test('a list of nothing but proxies is read as a list, not as base64', () {
      expect(extractLinks('http://1.2.3.4:3128\nhttp://5.6.7.8:8080'), ['http://1.2.3.4:3128', 'http://5.6.7.8:8080']);
    });
  });

  group('an HTTP proxy server', () {
    test('plain, with a login, on both cores', () {
      final c = parseLink('http://user:p%40ss@1.2.3.4:8080#Office')!;
      expect(c.protocol, 'http');
      expect(c.name, 'Office');
      expect(c.outbound, {'type': 'http', 'server': '1.2.3.4', 'server_port': 8080, 'username': 'user', 'password': 'p@ss'});
      expect(c.xrayOutbound!['protocol'], 'http');
      expect(c.xrayOutbound!['settings']['servers'][0]['users'][0], {'user': 'user', 'pass': 'p@ss'});
    });

    test('over TLS: the server name, and a proxy that skips the certificate check is on sing-box only', () {
      final c = parseLink('https://u:p@proxy.example.com:443?sni=front.example.com')!;
      expect(c.protocol, 'https');
      expect(c.port, 443);
      expect(c.outbound['tls'], containsPair('server_name', 'front.example.com'));
      expect(c.xrayOutbound!['streamSettings']['security'], 'tls');
      final insecure = parseLink('https://u:p@proxy.example.com:8443?insecure=1')!;
      expect(insecure.outbound['tls']['insecure'], isTrue);
      expect(insecure.canXray, isFalse);
    });
  });

  group('Clash lists', () {
    List<ProxyConfig> read(String yaml) => parseLinks(extractSubscriptionLinks(yaml));

    test('HTTP, SSH and WireGuard servers are read', () {
      final found = read('''
proxies:
  - {name: Web, type: http, server: proxy.example.com, port: 8080, username: u, password: p}
  - {name: Shell, type: ssh, server: 5.6.7.8, port: 22, username: root, password: secret}
  - name: Tunnel
    type: wireguard
    server: 9.9.9.9
    port: 51820
    ip: 10.0.0.2
    private-key: yOe8Js2xW3Qq6x1VY0m8m7mCzJ8h0o4xkq1o2m8x2E8=
    public-key: bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
    reserved: [1, 2, 3]
''');
      expect(found.map((c) => c.protocol), ['http', 'ssh', 'wireguard']);
      expect(found[0].outbound['username'], 'u');
      expect(found[1].outbound['user'], 'root');
      expect(found[2].outbound['address'], ['10.0.0.2/32']);
      expect((found[2].outbound['peers'] as List).first['reserved'], [1, 2, 3]);
    });

    test('a Shadowsocks server keeps its plugin, and one with a plugin the cores lack is left out', () {
      final found = read('''
proxies:
  - name: Obfs
    type: ss
    server: 1.2.3.4
    port: 8388
    cipher: aes-128-gcm
    password: pw
    plugin: obfs
    plugin-opts: {mode: tls, host: bing.com}
  - name: STLS
    type: ss
    server: 1.2.3.5
    port: 443
    cipher: 2022-blake3-aes-128-gcm
    password: AAAAAAAAAAAAAAAAAAAAAA==
    plugin: shadow-tls
    plugin-opts: {host: cloud.tencent.com, password: stls, version: 3}
  - {name: Kcp, type: ss, server: 1.2.3.6, port: 8388, cipher: aes-128-gcm, password: pw, plugin: kcptun}
''');
      expect(found.map((c) => c.name), ['Obfs', 'STLS']);
      expect(found[0].outbound['plugin'], 'obfs-local');
      expect(found[0].outbound['plugin_opts'], 'obfs=tls;obfs-host=bing.com');
      expect(found[1].inner.single['type'], 'shadowtls');
      expect(found[1].inner.single['password'], 'stls');
    });
  });

  group('sing-box lists', () {
    List<String> links(Map<String, Object?> config) => extractSubscriptionLinks(jsonEncode(config));

    test('HTTP and NaiveProxy servers, and WireGuard endpoints, are read', () {
      final found = links({
        'outbounds': [
          {'type': 'http', 'tag': 'Web', 'server': '1.2.3.4', 'server_port': 3128, 'username': 'u', 'password': 'p'},
          {
            'type': 'naive',
            'tag': 'Naive',
            'server': 'n.example.com',
            'server_port': 443,
            'username': 'u',
            'password': 'p',
            'tls': {'enabled': true, 'server_name': 'n.example.com'},
          },
          {'type': 'direct', 'tag': 'direct'},
        ],
        'endpoints': [
          {
            'type': 'wireguard',
            'tag': 'Tunnel',
            'address': ['10.0.0.2/32'],
            'private_key': 'yOe8Js2xW3Qq6x1VY0m8m7mCzJ8h0o4xkq1o2m8x2E8=',
            'peers': [
              {'address': '9.9.9.9', 'port': 51820, 'public_key': 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo='},
            ],
          },
        ],
      });
      expect(found.length, 3);
      expect(parseLink(found[0])!.outbound['type'], 'http');
      expect(found[1], startsWith('naive+https://u:p@n.example.com:443'));
      expect(parseLink(found[2])!.outbound['peers'][0]['address'], '9.9.9.9');
    });

    test('a Shadowsocks server behind ShadowTLS becomes one server with the shadow-tls plugin', () {
      final found = links({
        'outbounds': [
          {
            'type': 'shadowsocks',
            'tag': 'SS',
            'method': '2022-blake3-aes-128-gcm',
            'password': 'AAAAAAAAAAAAAAAAAAAAAA==',
            'detour': 'stls',
          },
          {
            'type': 'shadowtls',
            'tag': 'stls',
            'server': '1.2.3.4',
            'server_port': 443,
            'version': 3,
            'password': 'stls',
            'tls': {'enabled': true, 'server_name': 'cloud.tencent.com'},
          },
        ],
      });
      final c = parseLink(found.single)!;
      expect(c.host, '1.2.3.4');
      expect(c.inner.single['type'], 'shadowtls');
      expect(c.inner.single['tls']['server_name'], 'cloud.tencent.com');
    });
  });
}
