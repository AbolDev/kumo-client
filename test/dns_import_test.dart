import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/proxy_config.dart';

const _key = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _soarKey = 'oO8NO8Uy0r9NfV4s3mHcVgq6A1V9P8Y7Zr0mD5c2k3A=';

Map<String, dynamic> _spec(ProxyConfig c) => c.xrayOutbound![dnsTunnelKey] as Map<String, dynamic>;

String _b64url(Object json) => base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');

void main() {
  group('dnst:// of the net2share spec', () {
    test('the readable form: domain, transport, backend', () {
      final c = parseLink('dnst://t.example.com/dnstt/ssh?pubkey=$_key&user=tunnel&password=secret#my-tunnel')!;
      expect(c.protocol, 'dnstt');
      expect(c.name, 'my-tunnel');
      expect((_spec(c)['ssh'] as Map)['user'], 'tunnel');
      expect(_spec(c)['resolvers'], ['udp://1.1.1.1:53', 'udp://8.8.8.8:53'], reason: 'the spec has none: the usual ones are used');
      expect(c.link.startsWith('dnstt://'), isTrue, reason: 'what is shared is the link of Kumo');
    });

    test('VayDNS with its parameters, and the compatibility mode which is DNSTT', () {
      final v = parseLink('dnst://t.example.com/vaydns/socks?pubkey=$_key&record-type=txt&clientid-size=2&keepalive=10s&idle-timeout=60s#v')!;
      expect(v.protocol, 'vaydns');
      expect(_spec(v)['record'], 'txt');
      expect(_spec(v)['client_id'], 2);
      final compat = parseLink('dnst://t.example.com/vaydns/socks?pubkey=$_key&dnstt-compat=true')!;
      expect(compat.protocol, 'dnstt');
    });

    test('resolvers given as an extension, with the transports of Hiddify', () {
      final c = parseLink('dnst://t.example.com/vaydns/ssh?pubkey=$_key&resolver=8.8.8.8:53,dot://1.1.1.1:853,https://dns.google/dns-query&user=u&password=p')!;
      expect(_spec(c)['resolvers'], ['udp://8.8.8.8:53', 'tls://1.1.1.1:853', 'https://dns.google/dns-query']);
    });

    test('Slipstream takes no key; its certificate becomes PEM', () {
      final c = parseLink('dnst://a.example.com/slipstream/socks?cert=MIIBkTCB#s')!;
      expect(c.protocol, 'slipstream');
      expect(_spec(c)['cert'], contains('BEGIN CERTIFICATE'));
    });

    test('the form of base64url JSON, and the JSON of dnstm (v, key)', () {
      final b = parseLink('dnst://${_b64url({
            'tag': 'my-tunnel',
            'transport': {'type': 'slipstream', 'domain': 'a.example.com', 'cert': '-----BEGIN CERTIFICATE-----\nMIIBkTCB\n-----END CERTIFICATE-----'},
            'backend': {'type': 'socks'},
          })}')!;
      expect(b.protocol, 'slipstream');
      expect(b.name, 'my-tunnel');
      expect(_spec(b)['cert'], contains('MIIBkTCB'));
      final m = parseLink('dnst://${_b64url({
            'v': 1,
            'tag': 'm',
            'transport': {'type': 'dnstt', 'domain': 't.example.com', 'pubkey': _key},
            'backend': {'type': 'ssh', 'user': 'root', 'password': 'pw', 'key': '-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----'},
          })}')!;
      expect(_spec(m)['pubkey'], _key);
      expect((_spec(m)['ssh'] as Map)['key'], contains('OPENSSH PRIVATE KEY'));
    });

    test('what Kumo cannot carry is refused: MasterDNS, a Shadowsocks backend, a custom one', () {
      expect(parseLink('dnst://v.example.com/masterdns/socks?mkey=abcdef1234&encryption=5'), isNull);
      expect(parseLink('dnst://t.example.com/slipstream/shadowsocks?method=aes-256-gcm&password=x'), isNull);
      expect(parseLink('dnst://t.example.com/dnstt/custom?pubkey=$_key'), isNull);
    });
  });

  group('the URLs of Hiddify and Ghajar', () {
    test('Hiddify: dnstt:// is VayDNS unless it says it speaks the original wire format', () {
      final v = parseLink('dnstt://t.example.com?pubkey=$_key&resolver=8.8.8.8:53,dot://1.1.1.1:853&dnstt-compat=false&record-type=txt#h')!;
      expect(v.protocol, 'vaydns');
      expect(_spec(v)['resolvers'], ['udp://8.8.8.8:53', 'tls://1.1.1.1:853']);
      expect(parseLink('dnstt://t.example.com?pubkey=$_key&resolver=8.8.8.8&dnstt-compat=true')!.protocol, 'dnstt');
    });

    test('Ghajar: the login in the user part, the transport and the upstream', () {
      final c = parseLink('dnstt://root:pw@t.example.com?pubkey=$_key&transport=dot&resolver=1.1.1.1&upstream=ssh#g')!;
      expect(c.protocol, 'dnstt');
      expect((_spec(c)['ssh'] as Map)['user'], 'root');
      expect(_spec(c)['resolvers'], ['tls://1.1.1.1:853']);
      final n = parseLink('noizdns://t.example.com?pubkey=$_key&resolver=8.8.8.8&stealth=1')!;
      expect(n.protocol, 'noizdns');
      expect(_spec(n)['stealth'], isTrue);
    });

    test('Kumo\'s own link is not taken for another\'s', () {
      const own = 'dnstt://$_key@t.example.com?resolver=udp%3A%2F%2F1.1.1.1%3A53#Name';
      final c = parseLink(own)!;
      expect(c.link, own);
    });
  });

  group('Slipstream', () {
    test('Slipstreamplus: the resolvers in dns=, a login in the user part', () {
      final c = parseLink('SLIPSTREAM://user:pass@s.example.com:53?dns=8.8.8.8,1.1.1.1#My%20Server')!;
      expect(c.protocol, 'slipstream');
      expect(c.name, 'My Server');
      expect(_spec(c)['resolvers'], ['udp://8.8.8.8:53', 'udp://1.1.1.1:53']);
      expect(_spec(c)['socks_user'], 'user');
    });

    test('slipstream-client-android: base64url JSON', () {
      final c = parseLink('slipstream://${_b64url({
            'id': '1',
            'name': 'Mine',
            'domain': 's.example.com',
            'socksAuthEnabled': true,
            'username': 'u',
            'password': 'p',
          })}')!;
      expect(c.name, 'Mine');
      expect(_spec(c)['socks_pass'], 'p');
    });

    test('Kumo\'s own Slipstream link is left as it is', () {
      const own = 'slipstream://t.example.com?resolver=udp%3A%2F%2F1.1.1.1%3A53&authoritative=10.0.0.1%3A53&cc=bbr';
      final c = parseLink(own)!;
      expect(c.link, own);
      expect(_spec(c)['auth_resolvers'], ['10.0.0.1:53']);
    });
  });

  group('Soar', () {
    test('Hiddify: the key in pk, or before the @; the resolvers in resolvers', () {
      final a = parseLink('soar://t.example.com?pk=$_soarKey&resolvers=8.8.8.8,1.1.1.1&country=ir#h')!;
      expect(a.protocol, 'soar');
      expect(_spec(a)['pubkey'], _soarKey);
      expect(_spec(a)['country'], 'IR');
      expect(_spec(a)['resolvers'], ['udp://8.8.8.8:53', 'udp://1.1.1.1:53']);
      final b = parseLink('soar://${Uri.encodeComponent(_soarKey)}@t.example.com?resolvers=9.9.9.9#h')!;
      expect(_spec(b)['pubkey'], _soarKey);
    });

    test('WhiteDNS: the profile in base64url JSON', () {
      final c = parseLink('soar://${_b64url({
            'schema': 'whitedns.profile',
            'version': 1,
            'profile': {
              'name': 'Iran',
              'server': {'domain': 't.example.com', 'public_key': _soarKey},
              'resolvers': ['8.8.8.8', '1.1.1.1:53'],
              'soarSettings': {'discovery': true, 'country': 'IR', 'transport': 'auto'},
            },
          })}')!;
      expect(c.name, 'Iran');
      expect(_spec(c)['pubkey'], _soarKey);
      expect(_spec(c)['country'], 'IR');
      expect(_spec(c)['tcp_mode'], 'auto');
    });

    test('soar-tunnel (profile and locked), and Velta', () {
      final p = parseLink('soar://profile?domains=a.example.com,b.example.com&key=$_soarKey&port=1080')!;
      expect(_spec(p)['domain'], 'a.example.com');
      expect(_spec(p)['discovery'], isTrue);
      final l = parseLink('soar://locked?data=${_b64url({'name': 'L', 'domains': ['z.example.com'], 'key': _soarKey, 'port': 1080})}')!;
      expect(l.name, 'L');
      expect(parseLink('velta://tunnel?v=1&zone=v.example.com&key=${Uri.encodeComponent(_soarKey)}')!.protocol, 'soar');
    });

    test('Kumo\'s own Soar link is left as it is', () {
      final own = parseLink('soar://${Uri.encodeComponent(_soarKey)}@t.example.com?resolver=udp%3A%2F%2F1.1.1.1%3A53')!;
      expect(own.link.startsWith('soar://'), isTrue);
      expect(_spec(own)['resolvers'], ['udp://1.1.1.1:53']);
    });
  });

  group('the others', () {
    test('NetMod\'s dns:// (ps, addr, ns, pubkey, user, pass)', () {
      final c = parseLink('dns://${base64.encode(utf8.encode(jsonEncode({'ps': 'Net', 'addr': '8.8.8.8:53', 'ns': 't.example.com', 'pubkey': _key, 'user': 'root', 'pass': 'pw'})))}')!;
      expect(c.protocol, 'dnstt');
      expect(c.name, 'Net');
      expect((_spec(c)['ssh'] as Map)['user'], 'root');
      expect(parseLink('dns://8.8.8.8'), isNull, reason: 'any other dns:// is no profile');
    });

    test('Rovunet\'s link is SlipNet\'s under another name', () {
      final f = List<String>.filled(60, '', growable: true)
        ..[0] = '33'
        ..[1] = 'dnstt'
        ..[2] = 'R'
        ..[3] = 't.example.com'
        ..[4] = '8.8.8.8:53:0'
        ..[11] = _key
        ..[22] = 'udp';
      final c = parseLink('rovunet://${base64.encode(utf8.encode(f.join('|')))}')!;
      expect(c.protocol, 'dnstt');
      expect(c.name, 'R');
    });

    test('these links are found in a text', () {
      final text = 'a dnst://t.example.com/dnstt/socks?pubkey=$_key\nb soar://t.example.com?pk=$_soarKey&resolvers=8.8.8.8\nc velta://tunnel?v=1&zone=v.example.com&key=x';
      expect(extractLinks(text), hasLength(3));
    });

    test('a link of Xray\'s XDNS (mKCP over DNS) is a VLESS link with a final mask', () {
      final fm = Uri.encodeComponent(jsonEncode({
        'udp': [
          {
            'type': 'xdns',
            'settings': {
              'domains': [
                {'names': ['t.example.com']}
              ],
              'resolvers': [
                {'addrs': ['udp://8.8.8.8:53']}
              ],
            },
          }
        ],
      }));
      final c = parseLink('vless://11111111-1111-1111-1111-111111111111@1.2.3.4:443?type=kcp&security=none&fm=$fm#xdns');
      expect(c, isNotNull);
      expect(c!.needsXray, isTrue);
    });
  });
}