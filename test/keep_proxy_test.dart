import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/net_options.dart';
import 'package:kumo/core/proxy_config.dart';
import 'package:kumo/core/singbox_config.dart';
import 'package:kumo/core/updater.dart';

void main() {
  test('the always-on proxy is off by default and is saved', () {
    expect(NetOptions().keepProxy, false);
    final o = NetOptions()..keepProxy = true;
    expect((NetOptions()..load(o.toJson())).keepProxy, true);
  });

  test('the standby config has the local proxy but no tunnel', () {
    final servers = parseLinks(['trojan://p@h1.example.com:443#a']);
    final o = NetOptions()
      ..load((NetOptions()..tun = true..killSwitch = true).toJson())
      ..tun = false
      ..killSwitch = false;
    final cfg = jsonDecode(buildSingBoxConfig(servers, options: o, windows: true)) as Map;
    final types = [for (final i in cfg['inbounds'] as List) (i as Map)['type']];
    expect(types, contains('mixed'));
    expect(types, isNot(contains('tun')));
  });

  test('versions compare by number', () {
    expect(isNewer('1.3.10', '1.3.9'), true);
    expect(isNewer('1.3.9', '1.3.9'), false);
  });
}
