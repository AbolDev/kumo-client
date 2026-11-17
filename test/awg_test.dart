import 'dart:convert';
import 'dart:io' show ZLibEncoder;

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/awg.dart';
import 'package:kumo/core/latency_tester.dart' show delayConfigForTest;
import 'package:kumo/core/proxy_config.dart';
import 'package:kumo/core/singbox_config.dart';
import 'package:kumo/core/sub_formats.dart';

// Made-up keys with the characters a real one has.
const _priv = 'aB3+cD4/eF5gH6iJ7kL8mN9oP0qR1sT2uV3wX4yZ5a6=';
const _pub = 'Zz9+Yy8/Xx7WwVvUuTtSsRrQqPpOoNnMmLlKkJjIiHh0=';

String _link({String scheme = 'wireguard', String extra = ''}) =>
    '$scheme://${Uri.encodeComponent(_priv)}@203.0.113.7:43618?address=10.8.1.2%2F32&mtu=1280&keepalive=25'
    '&publickey=${Uri.encodeComponent(_pub)}$extra#awg';

const _awg = '&jc=5&jmin=30&jmax=80&s1=17&s2=29&h1=1234567891&h2=1234567892&h3=1234567893&h4=1234567894';

Map<String, dynamic> _config(List<ProxyConfig> servers) => jsonDecode(buildSingBoxConfig(servers)) as Map<String, dynamic>;

void main() {
  final supported = amneziaSupported;
  setUp(() => amneziaSupported = true);
  tearDown(() => amneziaSupported = supported);

  test('a WireGuard link with the settings of AmneziaWG is an AmneziaWG server, carried by the core of the phone only', () {
    final c = parseLink(_link(extra: '$_awg&i1=${Uri.encodeComponent('<b 0xc0ffee><t><r 16>')}&reserved=1,2,3'))!;
    expect(c.protocol, 'amneziawg');
    expect(c.isAmnezia, isTrue);
    expect(c.label, 'amneziawg');
    expect(c.canXray, isFalse, reason: 'Xray cannot carry AmneziaWG');
    expect(c.canSingBox, isTrue);
    final o = c.outbound;
    expect(o['type'], 'wireguard', reason: 'it is a WireGuard endpoint until the configuration is made');
    expect(o['jc'], 5);
    expect(o['jmin'], 30);
    expect(o['jmax'], 80);
    expect(o['s1'], 17);
    expect(o['h1'], '1234567891');
    expect(o['i1'], '<b 0xc0ffee><t><r 16>');
    expect(((o['peers'] as List).single as Map).containsKey('reserved'), isFalse, reason: 'WARP\'s bytes are not used');

    // Where the core has no such endpoint the server is not carried.
    amneziaSupported = false;
    expect(c.canSingBox, isFalse);
  });

  test('the configuration of the core has an endpoint of the type amneziawg, and a plain WireGuard server is left as it was', () {
    final awg = parseLink(_link(extra: _awg))!;
    final cfg = _config([awg]);
    final endpoint = (cfg['endpoints'] as List).single as Map;
    expect(endpoint['type'], 'amneziawg');
    expect(endpoint['tag'], 'proxy');
    expect(endpoint['jc'], 5);
    expect(endpoint['h4'], '1234567894');
    expect(cfg['route']['final'], 'proxy');

    final plain = parseLink(_link())!;
    expect(plain.protocol, 'wireguard');
    expect(plain.isAmnezia, isFalse);
    expect(plain.canXray, isTrue);
    expect(((_config([plain])['endpoints'] as List).single as Map)['type'], 'wireguard');

    // The test core of the delay test has it too.
    final test = jsonDecode(delayConfigForTest([awg.outbound])) as Map<String, dynamic>;
    expect(((test['endpoints'] as List).single as Map)['type'], 'amneziawg');
  });

  test('the other names of the link, and the ranges of AmneziaWG 2', () {
    for (final scheme in ['awg', 'amneziawg']) {
      final c = parseLink(_link(scheme: scheme, extra: _awg));
      expect(c, isNotNull, reason: scheme);
      expect(c!.protocol, 'amneziawg');
    }
    final ranges = parseLink(_link(
        extra: '&Jc=4&JMin=40&JMax=70&S1=15&S2=23&S3=17&S4=11&H1=1000000-1000999&H2=2000000-2000999'
            '&H3=3000000-3000999&H4=4000000-4000999&random_trailers=true&DisableCookies=1'))!;
    expect(ranges.outbound['h1'], '1000000-1000999');
    expect(ranges.outbound['s4'], 11);
    expect(ranges.outbound['random_trailers'], true);
    expect(ranges.outbound['disable_cookies'], true);
    // The DNS servers a link names are still read.
    expect(wireguardLinkDns('awg://k@1.2.3.4:51820?dns=1.1.1.1'), ['1.1.1.1']);
  });

  test('a setting that is not valid refuses the link (the core would not start)', () {
    expect(parseLink(_link(extra: '&jc=5&jmin=90&jmax=80')), isNull, reason: 'Jmin above Jmax');
    expect(parseLink(_link(extra: '&jc=500')), isNull, reason: 'too many junk packets');
    expect(parseLink(_link(extra: '&s1=70000')), isNull);
    expect(parseLink(_link(extra: '&h1=abc')), isNull);
    expect(parseLink(_link(extra: '&h1=10-5')), isNull, reason: 'a range turned round');
    expect(parseLink(_link(extra: '&h1=100-200&h2=150-300')), isNull, reason: 'headers that overlap');
    expect(parseLink(_link(extra: '&i1=${Uri.encodeComponent('<x 1>')}')), isNull, reason: 'a tag that is not known');
    expect(parseLink(_link(extra: '&i1=${Uri.encodeComponent('<b 0xabc>')}')), isNull, reason: 'odd number of hex digits');
    expect(parseLink(_link(extra: '&i1=${Uri.encodeComponent('hello')}')), isNull);
    expect(parseLink(_link(extra: '$_awg&noise=${Uri.encodeComponent('rand:20-30')}')), isNull, reason: 'WARP noise is Xray\'s');
    expect(parseLink(_link(extra: '&random_trailers=maybe')), isNull);
  });

  test('the configuration file of AmneziaWG becomes a link with its settings', () {
    const conf = '[Interface]\n'
        'PrivateKey = $_priv\n'
        'Address = 10.8.1.2/32\n'
        'DNS = 1.1.1.1\n'
        'Jc = 4\nJmin = 40\nJmax = 70\n'
        'S1 = 15\nS2 = 23\n'
        'H1 = 1234567891\nH2 = 1234567892\nH3 = 1234567893\nH4 = 1234567894\n'
        'I1 = <b 0xc0ffee><t><r 16>\n'
        '[Peer]\n'
        'PublicKey = $_pub\n'
        'Endpoint = vpn.example.com:51820\n'
        'AllowedIPs = 0.0.0.0/0, ::/0\n'
        'PersistentKeepalive = 25\n';
    final links = extractSubscriptionLinks(conf);
    expect(links, hasLength(1));
    final c = parseLink(links.single)!;
    expect(c.protocol, 'amneziawg');
    expect(c.outbound['jc'], 4);
    expect(c.outbound['jmin'], 40);
    expect(c.outbound['h3'], '1234567893');
    expect(c.outbound['i1'], '<b 0xc0ffee><t><r 16>');
    expect(((c.outbound['peers'] as List).single as Map)['address'], 'vpn.example.com');
    expect(wireguardLinkDns(links.single), ['1.1.1.1']);

    // An ordinary file of WireGuard stays an ordinary server.
    const plain = '[Interface]\nPrivateKey = $_priv\nAddress = 10.0.0.2/32\n'
        '[Peer]\nPublicKey = $_pub\nEndpoint = h.example.com:51820\nAllowedIPs = 0.0.0.0/0\n';
    expect(parseLink(extractSubscriptionLinks(plain).single)!.protocol, 'wireguard');
  });

  test('a configuration of AmneziaWG 3 as Amnezia writes it (flags as on, a header key in base64, a comment with the name)', () {
    const conf = '[Interface]\n'
        'PrivateKey = $_priv\n'
        'Address = 10.8.1.2/32\n'
        'DNS = 8.8.8.8, 8.8.4.4\n'
        'MTU = 1399\n'
        'Jc = 6\nJmin = 57\nJmax = 275\n'
        'S1 = 113\nS2 = 37\nS3 = 46\nS4 = 21\n'
        'H1 = 156002114\nH2 = 828509851\nH3 = 1195889750\nH4 = 1755676305\n'
        'I1 = <r 124>\n'
        'HeaderProtectionKey = AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=\n'
        'ContentPaddingAddition = 18-35\n'
        'RekeyAfterTime = 116-134\nRekeyTimeout = 5-6\nRejectAfterTime = 185-259\n'
        'KeepaliveTimeout = 11-17\nMaxHandshakeAttempts = 24-33\n'
        'RandomTrailers = on\nDisableCookies = on\n'
        '\n'
        '# my-awg-server\n'
        '[Peer]\n'
        'PublicKey = $_pub\n'
        'AllowedIPs = 0.0.0.0/0, ::/0\n'
        'Endpoint = 203.0.113.9:16041\n'
        'PersistentKeepalive = 25\n';
    final links = extractSubscriptionLinks(conf);
    expect(links, hasLength(1));
    final c = parseLink(links.single);
    expect(c, isNotNull, reason: awgProblem);
    expect(c!.name, 'my-awg-server', reason: 'the comment above [Peer] names the server');
    expect(c.protocol, 'amneziawg');
    expect(c.host, '203.0.113.9');
    expect(c.port, 16041);
    final o = c.outbound;
    expect(o['jc'], 6);
    expect(o['s4'], 21);
    expect(o['h2'], '828509851');
    expect(o['i1'], '<r 124>');
    expect(o['random_trailers'], true);
    expect(o['disable_cookies'], true);
    expect(o['content_padding_addition'], '18-35');
    expect(o['rekey_after_time'], '116-134');
    expect(o['max_handshake_attempts'], '24-33');
    // The core reads the key of the header protection in hex (32 bytes), the file has base64.
    expect(o['header_protection_key'], '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f');
    expect(((o['peers'] as List).single as Map)['persistent_keepalive_interval'], 25);

    // Pasted from the clipboard it is the same text.
    expect(parseLink(extractSubscriptionLinks(conf).single)!.protocol, 'amneziawg');
  });

  test('why a setting was refused is kept', () {
    expect(awgOptions({'Jc': '5', 'Jmin': '90', 'Jmax': '80'}), isNull);
    expect(awgProblem, contains('Jmin'));
    expect(awgOptions({'RandomTrailers': 'perhaps'}), isNull);
    expect(awgProblem, contains('RandomTrailers'));
    expect(awgOptions({'HeaderProtectionKey': 'AAAA', 'S1': '20', 'S2': '20', 'S3': '20', 'S4': '20'}), isNull);
    expect(awgProblem, contains('HeaderProtectionKey'));
    const key = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=';
    expect(awgOptions({'HeaderProtectionKey': key, 'S1': '11', 'S2': '20', 'S3': '20', 'S4': '20'}), isNull);
    expect(awgProblem, contains('S1'));
    expect(awgOptions({'Jc': '5'}), {'jc': 5});
    expect(awgProblem, isNull, reason: 'cleared by a read that was accepted');
    // On and off, as the file writes them.
    expect(awgOptions({'RandomTrailers': 'on', 'DisableCookies': 'off'}), {'random_trailers': true});
  });
  test('the links of Amnezia\'s own app (vpn://) hold the configurations of a server', () {
    const awgConf = '[Interface]\n'
        'PrivateKey = $_priv\nAddress = 10.8.1.2/32\nDNS = \$PRIMARY_DNS, \$SECONDARY_DNS\nMTU = 1280\n'
        'Jc = 4\nJmin = 40\nJmax = 70\nS1 = 15\nS2 = 23\nH1 = 1234567891\nH2 = 1234567892\nH3 = 1234567893\nH4 = 1234567894\n'
        '[Peer]\nPublicKey = $_pub\nAllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = 203.0.113.7:51820\nPersistentKeepalive = 25\n';
    const wgConf = '[Interface]\nPrivateKey = $_priv\nAddress = 10.9.0.2/32\n'
        '[Peer]\nPublicKey = $_pub\nAllowedIPs = 0.0.0.0/0\nEndpoint = 203.0.113.8:51821\n';
    final payload = {
      'description': 'Home server',
      'dns1': '1.1.1.1',
      'dns2': '1.0.0.1',
      'hostName': '203.0.113.7',
      'defaultContainer': 'amnezia-awg',
      'containers': [
        {
          'container': 'amnezia-awg',
          'awg': {'last_config': jsonEncode({'config': awgConf, 'Jc': '4', 'port': '51820'}), 'port': '51820'},
        },
        {
          'container': 'amnezia-wireguard',
          'wireguard': {'last_config': jsonEncode({'config': wgConf})},
        },
        {'container': 'amnezia-dns'},
      ],
    };
    // qCompress: the size in four bytes (big endian), then the zlib stream.
    final json = utf8.encode(jsonEncode(payload));
    final zipped = ZLibEncoder().convert(json);
    final size = [(json.length >> 24) & 0xFF, (json.length >> 16) & 0xFF, (json.length >> 8) & 0xFF, json.length & 0xFF];
    final link = 'vpn://${base64Url.encode([...size, ...zipped]).replaceAll('=', '')}';

    final links = extractSubscriptionLinks(link);
    expect(links, hasLength(2));
    final awg = parseLink(links[0])!;
    expect(awg.protocol, 'amneziawg');
    expect(awg.name, 'Home server', reason: 'the description of the server names it');
    expect(awg.outbound['jc'], 4);
    expect(awg.outbound['h4'], '1234567894');
    expect(wireguardLinkDns(links[0]), ['1.1.1.1', '1.0.0.1'], reason: 'the placeholders of the template are filled in');
    expect(parseLink(links[1])!.protocol, 'wireguard');
    // With text around it (pasted from a message), and a link that is not one of Amnezia's is let alone.
    expect(extractSubscriptionLinks('here: $link thanks'), hasLength(2));
    expect(extractSubscriptionLinks('vpn://not-a-link'), isEmpty);
  });

  test('the settings of AmneziaWG in Clash and sing-box subscriptions', () {
    final clash = '''
proxies:
  - name: awg-clash
    type: wireguard
    server: 203.0.113.7
    port: 51820
    ip: 10.8.1.2
    private-key: $_priv
    public-key: $_pub
    udp: true
    amnezia-wg-option:
      jc: 5
      jmin: 30
      jmax: 80
      s1: 17
      s2: 29
      h1: 1234567891
      h2: 1234567892
      h3: 1234567893
      h4: 1234567894
      i1: "<b 0xc0ffee><t><r 16>"
''';
    final fromClash = extractSubscriptionLinks(clash);
    expect(fromClash, hasLength(1));
    final c = parseLink(fromClash.single)!;
    expect(c.protocol, 'amneziawg');
    expect(c.name, 'awg-clash');
    expect(c.outbound['jc'], 5);
    expect(c.outbound['i1'], '<b 0xc0ffee><t><r 16>');

    for (final type in ['amneziawg', 'wireguard']) {
      final singbox = jsonEncode({
        'endpoints': [
          {
            'type': type,
            'tag': 'awg-box',
            'address': ['10.8.1.2/32'],
            'private_key': _priv,
            'jc': 4,
            'jmin': 40,
            'jmax': 70,
            's1': 15,
            's2': 23,
            'h1': '1234567891',
            'h2': '1234567892',
            'h3': '1234567893',
            'h4': '1234567894',
            'random_trailers': true,
            'peers': [
              {'address': '203.0.113.7', 'port': 51820, 'public_key': _pub, 'allowed_ips': ['0.0.0.0/0']},
            ],
          },
        ],
      });
      final box = extractSubscriptionLinks(singbox);
      expect(box, hasLength(1), reason: type);
      final s = parseLink(box.single)!;
      expect(s.protocol, 'amneziawg', reason: type);
      expect(s.outbound['jmax'], 70);
      expect(s.outbound['random_trailers'], true);
    }
    // A WireGuard endpoint without them stays WireGuard.
    final plain = jsonEncode({
      'endpoints': [
        {
          'type': 'wireguard',
          'tag': 'wg',
          'address': ['10.0.0.2/32'],
          'private_key': _priv,
          'peers': [
            {'address': '203.0.113.7', 'port': 51820, 'public_key': _pub, 'allowed_ips': ['0.0.0.0/0']},
          ],
        },
      ],
    });
    expect(parseLink(extractSubscriptionLinks(plain).single)!.protocol, 'wireguard');
  });
  test('awgOptions reads the settings by any case and with or without underscores', () {
    expect(awgOptions({'JC': '4', 'Jmin': '1', 'JMAX': '2'}), {'jc': 4, 'jmin': 1, 'jmax': 2});
    expect(awgOptions({'RandomTrailers': 'true', 'ContentPaddingAddition': '0-64'}),
        {'random_trailers': true, 'content_padding_addition': '0-64'});
    expect(awgOptions({'publickey': 'x', 'mtu': '1280'}), isEmpty, reason: 'not settings of AmneziaWG');
    expect(awgOptions({'jc': ' '}), isEmpty, reason: 'empty is not given');
    expect(isAwgSetting('S3'), isTrue);
    expect(isAwgSetting('Endpoint'), isFalse);
  });
}
