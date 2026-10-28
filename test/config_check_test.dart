import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/net_options.dart';
import 'package:kumo/core/proxy_config.dart';
import 'package:kumo/core/routing_rules.dart';
import 'package:kumo/core/singbox_config.dart';

/// The sing-box program of this build: named in KUMO_CORE, or the one the build fetched for this
/// system. Without it these tests are skipped (the CI job fetches it).
String? _core() {
  final env = Platform.environment['KUMO_CORE'];
  final candidates = [
    if (env != null && env.isNotEmpty) env,
    'windows/core/kumo-core.exe',
    'linux/core/kumo-core',
    'macos/core/kumo-core',
  ];
  for (final c in candidates) {
    if (!File(c).existsSync()) continue;
    try {
      if (Process.runSync(File(c).absolute.path, ['version']).exitCode == 0) {
        return File(c).absolute.path;
      }
    } catch (_) {
      // not a program this system can run (the other system's build)
    }
  }
  return null;
}

const _links = [
  'vless://11111111-1111-1111-1111-111111111111@v.example.com:443?security=reality&sni=www.example.com&fp=chrome&pbk=Z7wpmFS5jHjbR3WuDHe0_KC6KJqXzSTrX3ZtVGV0Vm0&sid=ab12&type=tcp&flow=xtls-rprx-vision#reality',
  'vless://11111111-1111-1111-1111-111111111111@w.example.com:443?security=tls&sni=w.example.com&type=ws&path=%2Fws%3Fed%3D2048&host=w.example.com#ws',
  'trojan://secret@t.example.com:443?sni=t.example.com&type=grpc&serviceName=svc#trojan',
  'ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ@s.example.com:8388#ss',
  'hysteria2://pass@h.example.com:443?sni=h.example.com&obfs=salamander&obfs-password=x&mport=20000-30000#hy2',
  'tuic://11111111-1111-1111-1111-111111111111:pw@u.example.com:443?sni=u.example.com&congestion_control=bbr&alpn=h3#tuic',
  'wireguard://yAnz5TF%2BlXXJte14tji3zlMNq%2Bhd2rYUIgJBgB3fBmk%3D@g.example.com:51820?publickey=xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg%3D&address=10.0.0.2%2F32&mtu=1280#wg',
];

String _write(Directory dir, String name, String json) {
  final f = File('${dir.path}/$name.json')..writeAsStringSync(json);
  return f.path;
}

void main() {
  final core = _core();
  final skip = core == null ? 'no sing-box program to check with (set KUMO_CORE)' : null;
  late Directory dir;
  setUpAll(() => dir = Directory.systemTemp.createTempSync('kumo-check'));
  tearDownAll(() => dir.deleteSync(recursive: true));

  /// Runs `check` on the config and fails with the core's own message when it is refused.
  void accepted(String name, String json) {
    final r = Process.runSync(core!, ['check', '-c', _write(dir, name, json)]);
    expect(r.exitCode, 0, reason: '$name was refused:\n${r.stdout}\n${r.stderr}');
  }

  final servers = parseLinks(_links);

  test('the sample links all become servers', () {
    expect(servers.length, _links.length);
  }, skip: skip);

  group('one server of every kind', () {
    for (final s in parseLinks(_links)) {
      test(s.name, () {
        accepted('one-${s.name}', buildSingBoxConfig([s]));
      }, skip: skip);
    }
  });

  test('the automatic group over all of them', () {
    accepted('group', buildSingBoxConfig(servers));
  }, skip: skip);

  test('the tunnel, with and without fake addresses and strict DNS', () {
    for (final (fake, strict) in [(false, false), (true, false), (false, true), (true, true)]) {
      final o = NetOptions()
        ..tun = true
        ..fakeIp = fake
        ..strictDns = strict;
      accepted('tun-$fake-$strict', buildSingBoxConfig(servers, options: o));
    }
  }, skip: skip);

  test('every DNS preset and a few addresses of one\'s own', () {
    final addresses = [
      for (final p in dnsPresets) p.address,
      '1.1.1.1',
      '1.1.1.1:5353',
      'dns.google',
      'tls://dns.google:853',
      'https://dns.example/custom-path',
      'not a dns address', // falls back to the first preset instead of stopping the core
    ];
    for (final (i, a) in addresses.indexed) {
      final o = NetOptions()
        ..dns = 'custom'
        ..customDns = a;
      accepted('dns-$i', buildSingBoxConfig(servers.take(1).toList(), options: o));
    }
  }, skip: skip);

  test('manual rules of every kind', () {
    final o = NetOptions()
      ..directRules = ['example.com', 'full:www.example.org', 'keyword:ads', r'regex:^ad[0-9]+\.', '10.0.0.0/8', 'port:443', 'port:1000-2000']
      ..proxyRules = ['proxied.example', 'münchen.de']
      ..blockRules = ['blocked.example', '192.0.2.0/24'];
    accepted('rules', buildSingBoxConfig(servers, options: o));
  }, skip: skip);

  test('a pattern RE2 cannot read is turned away before it reaches the core', () {
    final o = NetOptions()
      ..directRules = [r'regex:(?=x)y', r'regex:(a)\1', r'regex:a++'].map(normalizeRouteRule).whereType<String>().toList();
    expect(o.directRules, isEmpty);
    accepted('re2', buildSingBoxConfig(servers.take(1).toList(), options: o));
  }, skip: skip);

  test('the other switches', () {
    final o = NetOptions()
      ..tun = true
      ..blockAds = true
      ..adsLevel = 'strong'
      ..blockStun = true
      ..mux = true
      ..tcpFastOpen = true
      ..tlsFragment = true
      ..ntp = true
      ..killSwitch = true
      ..shareLan = true
      ..lanPassword = 'secret123'
      ..proxyUser = 'me'
      ..proxyPassword = 'pw'
      ..mtu = 1280;
    accepted('switches', buildSingBoxConfig(servers, options: o, localLogin: true));
  }, skip: skip);

  test('a server behind Xray, with the login of its local port', () {
    final xray = parseLinks([
      'vless://11111111-1111-1111-1111-111111111111@x.example.com:443?security=tls&sni=x.example.com&type=xhttp&path=%2Fx#xhttp',
    ]).single;
    final auth = (user: 'kuser', pass: 'kpass');
    accepted('xray', buildSingBoxConfig([xray], xrayPort: 31234, viaXray: true, xrayAuth: auth));
    final cfg = jsonDecode(buildXrayConfig(xray, 31234, auth: auth)) as Map;
    final settings = ((cfg['inbounds'] as List).first as Map)['settings'] as Map;
    expect(settings['auth'], 'password');
  }, skip: skip);
}
