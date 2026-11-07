import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/proxy_config.dart';
import 'package:kumo/core/vpngate.dart';

void main() {
  test('a VPN Gate list is read as OpenVPN servers with names', () {
    final text = File('test/data_vpngate_sample.txt').readAsStringSync();
    final links = extractLinks(text);
    expect(links, isNotEmpty);
    final configs = parseLinks(links);
    expect(configs.length, links.length, reason: 'every line is a server Kumo can read');
    for (final c in configs) {
      expect(c.isOpenVpn, isTrue);
      expect(c.name, contains(vpnGateMark));
    }
    expect(configs.map((c) => c.key).toSet().length, configs.length);
  });

  test('the list is fetched from GitHub and its mirrors, not from vpngate.net', () {
    expect(kVpnGateSources, isNotEmpty);
    expect(kVpnGateSources.any((s) => s.contains('vpngate.net')), isFalse);
    expect(kVpnGateSources.every((s) => s.endsWith('/servers.txt')), isTrue);
  });
}
