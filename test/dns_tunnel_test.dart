import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/proxy_config.dart';
import 'package:kumo/core/singbox_config.dart';

const _key = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

Map<String, dynamic> _spec(ProxyConfig c) => c.xrayOutbound![dnsTunnelKey] as Map<String, dynamic>;

void main() {
  group('the links of the DNS tunnels', () {
    test('DNSTT: the key is the user, the domain the host, each resolver a parameter', () {
      final c = parseLink('dnstt://$_key@t.example.com?resolver=udp%3A%2F%2F1.1.1.1%3A53&resolver=https%3A%2F%2Fdns.google%2Fdns-query#My%20tunnel')!;
      expect(c.protocol, 'dnstt');
      expect(c.name, 'My tunnel');
      expect(c.isDnsTunnel, isTrue);
      expect(c.canSingBox, isFalse);
      expect(c.canXray, isTrue);
      expect(c.label, 'dnstt');
      expect(_spec(c)['domain'], 't.example.com');
      expect(_spec(c)['pubkey'], _key);
      expect(_spec(c)['resolvers'], ['udp://1.1.1.1:53', 'https://dns.google/dns-query']);
    });

    test('the configuration of the helper has the tunnel, the port and the login', () {
      final c = parseLink('dnstt://$_key@t.example.com?resolver=1.1.1.1')!;
      final json = jsonDecode(buildXrayConfig(c, 31000, auth: (user: 'u', pass: 'p'))) as Map<String, dynamic>;
      expect(json['mode'], 'dnstt');
      expect(json['listen'], '127.0.0.1:31000');
      expect(json['user'], 'u');
      expect(json['pass'], 'p');
      expect(json['resolvers'], ['1.1.1.1']);
      final bare = jsonDecode(buildXrayConfig(c, 31001)) as Map<String, dynamic>;
      expect(bare.containsKey('user'), isFalse);
    });

    test('VayDNS and NoizDNS take their own parameters', () {
      final v = parseLink('vaydns://$_key@t.example.com?resolver=tls%3A%2F%2F1.1.1.1%3A853&record=null&qname=80&rps=20')!;
      expect(_spec(v)['record'], 'null');
      expect(_spec(v)['max_qname'], 80);
      expect(_spec(v)['rps'], 20.0);
      final n = parseLink('noizdns://$_key@t.example.com?resolver=1.1.1.1&resolver=8.8.8.8&stealth=1')!;
      expect(_spec(n)['stealth'], isTrue);
      expect(_spec(n)['resolvers'], ['1.1.1.1', '8.8.8.8']);
    });

    test('Soar may find its resolvers itself', () {
      final s = parseLink('soar://$_key@t.example.com?discovery=IR&tcp=auto')!;
      expect(_spec(s)['discovery'], isTrue);
      expect(_spec(s)['country'], 'IR');
      expect(_spec(s)['tcp_mode'], 'auto');
      expect(parseLink('dnstt://$_key@t.example.com'), isNull, reason: 'the others need a resolver');
    });

    test('a tunnel that ends at SSH, or at a SOCKS5 server with a login', () {
      final ssh = parseLink('dnstt://$_key@t.example.com?resolver=1.1.1.1&ssh=1&ssh_user=root&ssh_pass=secret')!;
      expect((_spec(ssh)['ssh'] as Map)['user'], 'root');
      expect((_spec(ssh)['ssh'] as Map)['pass'], 'secret');
      expect(parseLink('dnstt://$_key@t.example.com?resolver=1.1.1.1&ssh=1'), isNull, reason: 'an SSH login is needed');
      final socks = parseLink('dnstt://$_key@t.example.com?resolver=1.1.1.1&socks_user=a&socks_pass=b')!;
      expect(_spec(socks)['socks_user'], 'a');
    });

    test('SSH over a transport of its own is carried by the helper; an ordinary SSH link stays on sing-box', () {
      final plain = parseLink('ssh://root:pw@example.com:22#plain')!;
      expect(plain.canSingBox, isTrue);
      expect(plain.isDnsTunnel, isFalse);
      final ws = parseLink('ssh://root:pw@example.com:443?transport=ws&ws_path=%2Fssh&ws_tls=1&ws_host=cdn.example.com#ws')!;
      expect(ws.isDnsTunnel, isTrue);
      expect(ws.protocol, 'ssh');
      final spec = (_spec(ws)['ssh'] as Map);
      expect(spec['transport'], 'ws');
      expect(spec['ws_path'], '/ssh');
      expect(spec['ws_tls'], isTrue);
      expect(spec['host'], 'example.com');
      final tls = parseLink('ssh://root:pw@example.com:443?transport=tls&sni=front.example.com')!;
      expect((_spec(tls)['ssh'] as Map)['sni'], 'front.example.com');
      final http = parseLink('ssh://root:pw@example.com:22?transport=http&proxy=10.0.0.1%3A8080')!;
      expect((_spec(http)['ssh'] as Map)['proxy_port'], 8080);
      expect(parseLink('ssh://root:pw@example.com:22?transport=quic'), isNull);
    });

    test('the links are found in a text with others', () {
      final text = 'one dnstt://$_key@t.example.com?resolver=1.1.1.1#a\nand soar://$_key@s.example.com?discovery=1#b';
      expect(extractLinks(text), hasLength(2));
    });
  });

  group('the link of SlipNet is read, and becomes a link of Kumo', () {
    String slipnet(List<String> fields) => 'slipnet://${base64.encode(utf8.encode(fields.join('|')))}';

    List<String> fields({required String type, String domain = 't.example.com', String resolvers = '8.8.8.8:53:0'}) {
      final f = List<String>.filled(60, '');
      f[0] = '24';
      f[1] = type;
      f[2] = 'From SlipNet';
      f[3] = domain;
      f[4] = resolvers;
      f[11] = _key;
      f[22] = 'udp';
      return f;
    }

    test('DNSTT with SSH', () {
      final f = fields(type: 'dnstt_ssh');
      f[14] = '1';
      f[15] = 'root';
      f[16] = 'pw';
      final c = parseLink(slipnet(f))!;
      expect(c.protocol, 'dnstt');
      expect(c.name, 'From SlipNet');
      expect(c.link.startsWith('dnstt://'), isTrue, reason: 'what is shared is the link of Kumo');
      expect(_spec(c)['resolvers'], ['udp://8.8.8.8:53']);
      expect((_spec(c)['ssh'] as Map)['user'], 'root');
    });

    test('NoizDNS (sayedns) with stealth, and Soar with discovery', () {
      final f = fields(type: 'sayedns');
      f[38] = '1';
      expect(_spec(parseLink(slipnet(f))!)['stealth'], isTrue);
      final g = fields(type: 'soar', resolvers: '')..addAll(List.filled(22, ''));
      g[79] = '1';
      g[80] = 'ir';
      final c = parseLink(slipnet(g))!;
      expect(c.protocol, 'soar');
      expect(_spec(c)['discovery'], isTrue);
      expect(_spec(c)['country'], 'IR');
    });

    test('a kind Kumo has no tunnel for is refused', () {
      expect(parseLink(slipnet(fields(type: 'snowflake'))), isNull);
      expect(parseLink('slipnet://not-base64!'), isNull);
    });
  });
}
