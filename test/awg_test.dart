import 'dart:convert';
import 'dart:io' show ZLibEncoder;

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/amnezia_qr.dart';
import 'package:kumo/core/awg.dart';
import 'package:kumo/core/desktop_vpn.dart' show DesktopVpn;
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
  // The phone's core has the endpoint itself; the tests that are about a computer say otherwise.
  final inCore = amneziaInCore;
  setUp(() => amneziaInCore = true);
  tearDown(() => amneziaInCore = inCore);

  test('a WireGuard link with the settings of AmneziaWG is an AmneziaWG server, carried by the core of the phone', () {
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
  });

  test('on a computer kumo-awg carries it: the core sends to its SOCKS port, as it does for Xray', () {
    amneziaInCore = false;
    final c = parseLink(_link(extra: '$_awg&i1=${Uri.encodeComponent('<b 0xc0ffee><t><r 16>')}'))!;
    expect(c.protocol, 'amneziawg');
    expect(c.isAmnezia, isTrue);
    expect(c.canSingBox, isFalse, reason: 'the official core has no such endpoint');
    expect(c.needsXray, isTrue, reason: 'a helper carries it, like an XHTTP server');
    expect(c.canXray, isTrue);
    expect(c.label, 'amneziawg');
    expect(c.useXray('sing-box'), isTrue);
    expect(c.xrayOutbound!['jc'], 5);

    // The configuration of the helper: a SOCKS inbound with a login, and the endpoint.
    final helper = jsonDecode(buildXrayConfig(c, 34567, auth: (user: 'u', pass: 'p'))) as Map<String, dynamic>;
    final inbound = (helper['inbounds'] as List).single as Map;
    expect(inbound['type'], 'socks');
    expect(inbound['listen_port'], 34567);
    expect((inbound['users'] as List).single, {'username': 'u', 'password': 'p'});
    final endpoint = (helper['endpoints'] as List).single as Map;
    expect(endpoint['type'], 'amneziawg');
    expect(endpoint['tag'], 'proxy');
    expect(endpoint['jc'], 5);
    expect(endpoint['i1'], '<b 0xc0ffee><t><r 16>');
    expect(helper['route']['final'], 'proxy');
    final dnsServers = (helper['dns'] as Map)['servers'] as List;
    expect(dnsServers.firstWhere((s) => s['tag'] == 'dns')['detour'], 'proxy', reason: 'the names of the sites go through the tunnel');
    expect(helper['route']['default_domain_resolver'], 'dns-local', reason: 'the name of the server does not');
    expect(dnsServers.firstWhere((s) => s['tag'] == 'dns-local')['type'], 'local');

    // The official core goes to that port.
    final core = jsonDecode(buildSingBoxConfig([c], xrayPort: 34567, xrayAuth: (user: 'u', pass: 'p'), viaXray: true))
        as Map<String, dynamic>;
    final proxy = (core['outbounds'] as List).firstWhere((o) => o['tag'] == 'proxy') as Map;
    expect(proxy['type'], 'socks');
    expect(proxy['server_port'], 34567);
    expect(core['endpoints'], isNull, reason: 'the official core has no endpoint of that type');

    // The desktop starts kumo-awg for a configuration of sing-box and Xray for the others.
    expect(DesktopVpn.helperFor(buildXrayConfig(c, 34567)), 'kumo-awg');
    final xray = parseLink('vless://11111111-1111-1111-1111-111111111111@h.example.com:443?type=xhttp&security=tls&sni=h.example.com#x')!;
    expect(DesktopVpn.helperFor(buildXrayConfig(xray, 34568)), 'kumo-xray');
  });

  test('on a computer the AmneziaWG servers join the automatic group, a SOCKS port of kumo-awg each', () {
    amneziaInCore = false;
    final a = parseLink(_link(extra: _awg))!;
    final b = parseLink(_link(extra: _awg.replaceFirst('jc=5', 'jc=7')).replaceFirst('203.0.113.7', '203.0.113.8'))!;
    final vless = parseLink('vless://11111111-1111-1111-1111-111111111111@h.example.com:443?security=tls&sni=h.example.com#v')!;
    expect(a.viaAwgHelper && b.viaAwgHelper, isTrue);
    expect(vless.viaAwgHelper, isFalse);
    final group = [a, vless, b];

    // The helper: one inbound and one endpoint for each, the ports one after the other.
    final helper = jsonDecode(buildAwgGroupConfig([a, b], 40000, auth: (user: 'u', pass: 'p'))) as Map<String, dynamic>;
    final inbounds = helper['inbounds'] as List;
    expect([for (final i in inbounds) i['listen_port']], [40000, 40001]);
    expect([for (final i in inbounds) i['tag']], ['socks-in-0', 'socks-in-1']);
    final endpoints = helper['endpoints'] as List;
    expect([for (final e in endpoints) e['tag']], ['awg-0', 'awg-1']);
    expect([for (final e in endpoints) e['jc']], [5, 7]);
    final rules = (helper['route'] as Map)['rules'] as List;
    expect(rules, [
      {'inbound': ['socks-in-0'], 'action': 'route', 'outbound': 'awg-0'},
      {'inbound': ['socks-in-1'], 'action': 'route', 'outbound': 'awg-1'},
    ]);
    final dns = helper['dns'] as Map;
    expect([for (final r in dns['rules'] as List) r['server']], ['dns-0', 'dns-1']);
    expect(DesktopVpn.helperFor(jsonEncode(helper)), 'kumo-awg');

    // The core: a SOCKS outbound to each in the group, next to the server it carries itself.
    final core = jsonDecode(buildSingBoxConfig(group, xrayAuth: (user: 'u', pass: 'p'), awgPort: 40000)) as Map<String, dynamic>;
    final outs = {for (final o in core['outbounds'] as List) o['tag']: o};
    expect(outs['server-0']['type'], 'socks');
    expect(outs['server-0']['server_port'], 40000);
    expect(outs['server-1']['type'], 'vless');
    expect(outs['server-2']['type'], 'socks');
    expect(outs['server-2']['server_port'], 40001);
    expect(outs['server-2']['username'], 'u');
    expect(outs['proxy']['outbounds'], ['server-0', 'server-1', 'server-2']);
    expect(core['endpoints'], isNull);
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
    expect(c, isNotNull, reason: '$awgProblem');
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
    expect('$awgProblem', contains('Jmin'));
    expect(awgOptions({'RandomTrailers': 'perhaps'}), isNull);
    expect('$awgProblem', contains('RandomTrailers'));
    expect(awgOptions({'HeaderProtectionKey': 'AAAA', 'S1': '20', 'S2': '20', 'S3': '20', 'S4': '20'}), isNull);
    expect('$awgProblem', contains('HeaderProtectionKey'));
    const key = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=';
    expect(awgOptions({'HeaderProtectionKey': key, 'S1': '11', 'S2': '20', 'S3': '20', 'S4': '20'}), isNull);
    expect('$awgProblem', contains('S1'));
    // The reason is said in the language asked for.
    expect(awgProblem!.text('fa'), contains('S1'));
    expect(awgProblem!.text('fa'), isNot(awgProblem!.text('en')));
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

  test('the series of QR codes of Amnezia\'s app is put together into the link', () {
    const conf = '[Interface]\nPrivateKey = $_priv\nAddress = 10.8.1.2/32\nJc = 4\nJmin = 40\nJmax = 70\n'
        '[Peer]\nPublicKey = $_pub\nAllowedIPs = 0.0.0.0/0\nEndpoint = 203.0.113.7:51820\n';
    final json = utf8.encode(jsonEncode({
      'description': 'By QR',
      'containers': [
        {'container': 'amnezia-awg', 'awg': {'last_config': jsonEncode({'config': conf})}},
      ],
    }));
    final zipped = ZLibEncoder().convert(json);
    final data = [(json.length >> 24) & 0xFF, (json.length >> 16) & 0xFF, (json.length >> 8) & 0xFF, json.length & 0xFF, ...zipped];
    // As the app writes the parts: the mark 1984, the count, the number, the length, the bytes; in base64url.
    const size = 40;
    final count = (data.length / size).ceil();
    expect(count, greaterThan(3), reason: 'the test needs a series');
    final parts = [
      for (var i = 0; i < count; i++)
        () {
          final chunk = data.sublist(i * size, (i + 1) * size > data.length ? data.length : (i + 1) * size);
          return base64Url.encode([0x07, 0xC0, count, i, 0, 0, 0, chunk.length, ...chunk]);
        }(),
    ];

    final reader = AmneziaQrParts();
    // Out of order, one of them twice: only the last one that is missing completes it.
    for (final i in [2, 0, 0]) {
      final r = reader.feed(parts[i])!;
      expect(r.link, isNull);
    }
    expect(reader.feed(parts[1]), isNotNull);
    String? link;
    for (var i = 3; i < count; i++) {
      link = reader.feed(parts[i])!.link;
    }
    expect(link, isNotNull);
    expect(link, startsWith('vpn://'));
    final links = extractSubscriptionLinks(link!);
    expect(links, hasLength(1));
    expect(parseLink(links.single)!.name, 'By QR');
    expect(parseLink(links.single)!.outbound['jc'], 4);

    // Anything else is not a part.
    expect(reader.feed('vless://x@example.com:443'), isNull);
    expect(reader.feed('SGVsbG8gd29ybGQgaGVsbG8='), isNull);
    expect(reader.feed('https://example.com/sub'), isNull);
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
