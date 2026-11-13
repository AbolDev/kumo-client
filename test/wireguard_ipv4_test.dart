import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/latency_tester.dart' show delayConfigForTest, testReal;
import 'package:kumo/core/net_options.dart';
import 'package:kumo/core/proxy_config.dart';
import 'package:kumo/core/singbox_config.dart';

// Made-up keys with the characters a real one has (+, / and = at the end), in the form the links of providers carry
// them (percent-encoded).
const _priv = 'aB3+cD4/eF5gH6iJ7kL8mN9oP0qR1sT2uV3wX4yZ5a6=';
const _pub = 'Zz9+Yy8/Xx7WwVvUuTtSsRrQqPpOoNnMmLlKkJjIiHh0=';

String _link({String address = '10.0.0.2%2F32', String extra = ''}) =>
    'wireguard://${Uri.encodeComponent(_priv)}@203.0.113.7:43618?address=$address&dns=1.1.1.1%2C+8.8.8.8&keepalive=25&mtu=1280'
    '&publickey=${Uri.encodeComponent(_pub)}$extra#WG%7C%F0%9F%93%8A4.99GB';

Map<String, dynamic> _config(List<ProxyConfig> servers) => jsonDecode(buildSingBoxConfig(servers)) as Map<String, dynamic>;

bool _hasAaaaRule(Map<String, dynamic> cfg) => ((cfg['dns'] as Map)['rules'] as List? ?? const [])
    .any((r) => r is Map && (r['query_type'] as List?)?.contains('AAAA') == true && r['action'] == 'predefined');

void main() {
  test('a TCP ping of a list measures its UDP servers through the core when it may, and leaves them as they were when it may not', () async {
    final wg = parseLink(_link())!..latencyMs = 55;
    final seen = <String>[];
    await testReal([wg], real: false, udpDelay: false, onResult: (c) => seen.add(c.protocol));
    expect(wg.latencyMs, 55, reason: 'not measured while a connection is up');
    expect(seen, ['wireguard'], reason: 'but counted as done');
  });

  test('any test configuration that has endpoints and no outbound names its default (Warp-in-Warp too)', () {
    final one = parseLink(_link())!;
    final two = parseLink(_link(extra: '&x=2'))!;
    for (final layers in [
      [one.outbound],
      [one.outbound, two.outbound],
    ]) {
      final cfg = jsonDecode(delayConfigForTest(layers)) as Map<String, dynamic>;
      final endpoints = (cfg['endpoints'] as List?) ?? const [];
      expect(endpoints.length, layers.length);
      if (!cfg.containsKey('outbounds')) {
        expect((cfg['route'] as Map)['final'], 'proxy', reason: 'a direct outbound would be made, and it breaks on Android');
      }
    }
  });

  test('the test core of a WireGuard server names the endpoint as its default, so no direct outbound is made', () {
    final c = parseLink(_link())!;
    final cfg = jsonDecode(delayConfigForTest([c.outbound])) as Map<String, dynamic>;
    expect(cfg.containsKey('outbounds'), isFalse);
    expect(((cfg['endpoints'] as List).first as Map)['tag'], 'proxy');
    expect((cfg['route'] as Map)['final'], 'proxy');
    final other = jsonDecode(delayConfigForTest([
      {'type': 'socks', 'server': '203.0.113.7', 'server_port': 1080},
    ])) as Map<String, dynamic>;
    expect((other['route'] as Map).containsKey('final'), isFalse);
  });

  test('the DNS servers a WireGuard link names are read, and the first one is the DNS of the connection', () {
    final c = parseLink(_link())!;
    expect(wireguardLinkDns(c.link), ['1.1.1.1', '8.8.8.8']);
    expect(wireguardLinkDns('vless://x@example.com:443'), isEmpty);
    final cfg = _config([c]);
    final remote = ((cfg['dns'] as Map)['servers'] as List).firstWhere((s) => (s as Map)['tag'] == 'dns-remote') as Map;
    expect(remote['type'], 'udp');
    expect(remote['server'], '1.1.1.1');
    expect(remote['detour'], 'proxy');
    // A DNS server the user typed stays.
    final own = jsonDecode(buildSingBoxConfig([c], options: NetOptions()
      ..dns = 'custom'
      ..customDns = 'https://9.9.9.9/dns-query')) as Map<String, dynamic>;
    final kept = ((own['dns'] as Map)['servers'] as List).firstWhere((s) => (s as Map)['tag'] == 'dns-remote') as Map;
    expect(kept['server'], '9.9.9.9');
    // The test core asks the same server.
    final probe = jsonDecode(delayConfigForTest([c.outbound], dns: '8.8.4.4')) as Map<String, dynamic>;
    expect((((probe['dns'] as Map)['servers'] as List).single as Map)['server'], '8.8.4.4');
  });

  test('the DNS of a configuration file is carried into its link', () {
    final links = wireguardConfToLinks('[Interface]\nPrivateKey = $_priv\nAddress = 10.0.0.2/32\nDNS = 1.1.1.1, 8.8.8.8\n'
        '[Peer]\nPublicKey = $_pub\nEndpoint = 203.0.113.7:43618\nAllowedIPs = 0.0.0.0/0\n');
    expect(wireguardLinkDns(links.single), ['1.1.1.1', '8.8.8.8']);
  });
  test('for the domestic page the test core is handed the address of its name and asks no DNS server', () {
    final c = parseLink(_link())!;
    final cfg = jsonDecode(delayConfigForTest([c.outbound], hosts: {'arvancloud.ir': '198.51.100.4'})) as Map<String, dynamic>;
    final server = ((cfg['dns'] as Map)['servers'] as List).single as Map;
    expect(server['type'], 'hosts');
    expect(server['tag'], 'dns');
    expect(server['predefined'], {
      'arvancloud.ir': ['198.51.100.4'],
    });
    expect(server.containsKey('detour'), isFalse);
  });

  test('the mark of a server that reaches domestic sites only is kept when the server is copied', () {
    final c = parseLink(_link())!
      ..latencyMs = 80
      ..domesticOnly = true;
    final copy = c.withLink('${c.link} ');
    expect(copy.domesticOnly, isTrue);
    expect(copy.latencyMs, 80);
  });

  test('the test core of a WireGuard server looks names up through the tunnel, IPv4 only when it has no IPv6', () {
    final c = parseLink(_link())!;
    final cfg = jsonDecode(delayConfigForTest([c.outbound])) as Map<String, dynamic>;
    final dns = cfg['dns'] as Map;
    expect(((dns['servers'] as List).single as Map)['detour'], 'proxy');
    expect(dns['strategy'], 'ipv4_only');
    final both = parseLink(_link(address: '10.0.0.2%2F32,fd00%3A%3A2%2F128'))!;
    expect(((jsonDecode(delayConfigForTest([both.outbound])) as Map)['dns'] as Map).containsKey('strategy'), isFalse);
    // Any other server is given the name itself: its lookup stays as it was.
    final other = jsonDecode(delayConfigForTest([
      {'type': 'socks', 'server': '203.0.113.7', 'server_port': 1080},
    ])) as Map<String, dynamic>;
    expect((((other['dns'] as Map)['servers'] as List).single as Map).containsKey('detour'), isFalse);
  });

  test('the link of a provider is read: the key and the address are decoded, and the name keeps its text', () {
    final c = parseLink(_link())!;
    expect(c.outbound['type'], 'wireguard');
    expect(c.outbound['private_key'], _priv);
    expect(c.outbound['address'], ['10.0.0.2/32']);
    expect(c.outbound['mtu'], 1280);
    final peer = (c.outbound['peers'] as List).single as Map;
    expect(peer['public_key'], _pub);
    expect(peer['address'], '203.0.113.7');
    expect(peer['port'], 43618);
    expect(peer['persistent_keepalive_interval'], 25);
    expect(c.name, startsWith('WG|'));
  });

  test('a WireGuard server with no IPv6 address is not given IPv6: its allowed networks are IPv4, and no name has an IPv6 answer', () {
    final c = parseLink(_link())!;
    final cfg = _config([c]);
    final peer = (((cfg['endpoints'] as List).single as Map)['peers'] as List).single as Map;
    expect(peer['allowed_ips'], ['0.0.0.0/0']);
    expect(_hasAaaaRule(cfg), isTrue);
    // What the parsed server holds is not changed (it is shown, tested and saved as it was).
    expect(((c.outbound['peers'] as List).single as Map)['allowed_ips'], ['0.0.0.0/0', '::/0']);
  });

  test('a server that has an IPv6 address keeps its IPv6 and its names keep their IPv6 answers', () {
    final c = parseLink(_link(address: '10.0.0.2%2F32%2Cfd00%3A%3A2%2F128'))!;
    final cfg = _config([c]);
    final peer = (((cfg['endpoints'] as List).single as Map)['peers'] as List).single as Map;
    expect(peer['allowed_ips'], ['0.0.0.0/0', '::/0']);
    expect(_hasAaaaRule(cfg), isFalse);
  });

  test('a server that asked for IPv6 networks only is left as it is', () {
    final c = parseLink(_link(extra: '&allowedips=%3A%3A%2F0'))!;
    final cfg = _config([c]);
    final peer = (((cfg['endpoints'] as List).single as Map)['peers'] as List).single as Map;
    expect(peer['allowed_ips'], ['::/0']);
  });

  test('a group of servers is not changed: another of them may carry IPv6', () {
    final a = parseLink(_link())!;
    final b = parseLink('trojan://secret@t.example.com:443?sni=t.example.com#T')!;
    final cfg = _config([a, b]);
    final peer = (((cfg['endpoints'] as List).single as Map)['peers'] as List).single as Map;
    expect(peer['allowed_ips'], ['0.0.0.0/0', '::/0']);
    expect(_hasAaaaRule(cfg), isFalse);
  });

  test('the other servers are not touched', () {
    final c = parseLink('trojan://secret@t.example.com:443?sni=t.example.com#T')!;
    expect(_hasAaaaRule(_config([c])), isFalse);
  });
}
