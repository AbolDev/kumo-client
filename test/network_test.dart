import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/backup.dart';
import 'package:kumo/core/net_options.dart';
import 'package:kumo/core/proxy_config.dart';
import 'package:kumo/core/singbox_config.dart';

ProxyConfig server() => parseLink(
    'trojan://secret@example.com:443?security=tls&sni=example.com#test')!;

Map<String, dynamic> build(NetOptions o,
        {Map<String, String> sets = const {}, bool windows = false}) =>
    jsonDecode(buildSingBoxConfig([server()],
        options: o,
        ruleSets: sets,
        apiPort: 9999,
        apiSecret: 's',
        windows: windows)) as Map<String, dynamic>;

void main() {
  test('the device is tunneled by default on Android only', () {
    expect(NetOptions().tun, Platform.isAndroid);
    final c = build(NetOptions()..tun = true);
    final types = [for (final i in c['inbounds']) i['type']];
    expect(types, containsAll(['mixed', 'tun']));
    final off = build(NetOptions()..tun = false);
    expect([for (final i in off['inbounds']) i['type']], ['mixed']);
    expect(c['inbounds'][0]['listen_port'], 2080);
    expect(c['experimental']['clash_api']['external_controller'],
        '127.0.0.1:9999');
  });

  test('the tunnel, the port and the MTU follow the options', () {
    final o = NetOptions()
      ..tun = true
      ..proxyPort = 3000
      ..mtu = 1500;
    final c = build(o);
    final tun = (c['inbounds'] as List).firstWhere((i) => i['type'] == 'tun');
    expect(tun['mtu'], 1500);
    expect(c['inbounds'][0]['listen_port'], 3000);
  });

  test('per-app lists go to the tunnel on Android and to rules on Windows', () {
    final o = NetOptions()
      ..tun = true
      ..appMode = AppMode.except
      ..apps = ['com.bank.app'];
    final android = build(o);
    final tun =
        (android['inbounds'] as List).firstWhere((i) => i['type'] == 'tun');
    expect(tun['exclude_package'], ['com.bank.app']);

    final win = build(o..apps = ['bank.exe'], windows: true);
    final rules = win['route']['rules'] as List;
    expect(rules.any((r) => r['process_name'] != null), isTrue);
    expect(win['route']['find_process'], isTrue);
  });

  test('sites of the chosen countries go direct only when asked', () {
    final off = build(NetOptions(), sets: {'geoip-ir': '/tmp/a.srs'});
    expect(jsonEncode(off['route']['rules']).contains('geoip-ir'), isFalse);

    final on = build(NetOptions()..bypass = ['ir'],
        sets: {'geoip-ir': '/tmp/a.srs'});
    expect(jsonEncode(on['route']['rules']).contains('geoip-ir'), isTrue);
    expect(on['route']['rule_set'][0]['path'], '/tmp/a.srs');
  });

  test('advanced options reach the outbound', () {
    final o = NetOptions()
      ..mux = true
      ..tlsFragment = true
      ..fingerprint = 'firefox';
    final out = build(o)['outbounds'][0] as Map<String, dynamic>;
    expect(out['multiplex']['enabled'], isTrue);
    expect(out['tls']['fragment'], isTrue);
    expect(out['tls']['utls']['fingerprint'], 'firefox');
  });

  test('a custom DNS address picks DoH, DoT or plain UDP', () {
    Map<String, dynamic> dns(String address) => (build(NetOptions()
          ..dns = 'custom'
          ..customDns = address)['dns']['servers'] as List)
        .first as Map<String, dynamic>;
    expect(dns('https://dns.example/dns-query')['type'], 'https');
    expect(dns('tls://9.9.9.9')['type'], 'tls');
    expect(dns('8.8.4.4')['type'], 'udp');
  });

  test('IPv4 addresses keep only their first two parts', () {
    expect(maskHost('185.1.2.187'), '185.1.***');
  });

  test('a backup opens with its password only', () async {
    final sealed = await sealBackup('{"a":1}', 'pw');
    expect(backupIsEncrypted(sealed), isTrue);
    expect(await openBackup(sealed, 'pw'), '{"a":1}');
    expect(await openBackup(sealed, 'nope'), isNull);
    final plain = await sealBackup('{"a":1}', '');
    expect(backupIsEncrypted(plain), isFalse);
    expect(await openBackup(plain, ''), '{"a":1}');
  });
}
