import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/net_options.dart';
import 'package:kumo/core/proxy_config.dart';
import 'package:kumo/state/app_state.dart';

const _links = [
  'vless://11111111-1111-1111-1111-111111111111@a.example.com:443?security=tls&type=ws&path=%2F#A',
  'trojan://secret@b.example.com:443?sni=b.example.com#B',
  'ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ@c.example.com:8388#C',
  'vless://11111111-1111-1111-1111-111111111111@d.example.com:443?security=tls&type=ws&path=%2F#D',
];

void main() {
  group('deleting servers can be undone', () {
    test('each comes back where it was, in the order it had, and the chosen one is chosen again', () {
      final s = AppState();
      s.manual.configs.addAll(parseLinks(_links));
      final names = s.manual.configs.map((c) => c.name).toList();
      s.selected = s.manual.configs[1];
      final chosen = s.selected;
      final removed = s.removeConfigs([
        (group: s.manual, config: s.manual.configs[1]),
        (group: s.manual, config: s.manual.configs[0]),
        (group: s.manual, config: s.manual.configs[3]),
      ]);
      expect(removed, hasLength(3));
      expect(s.manual.configs.map((c) => c.name), ['C']);
      expect(s.selected, isNull);
      s.restoreConfigs(removed);
      expect(s.manual.configs.map((c) => c.name), names);
      expect(identical(s.selected, chosen), isTrue);
      // Putting back what is there already adds nothing.
      s.restoreConfigs(removed);
      expect(s.manual.configs, hasLength(4));
    });

    test('a server that is not in the group is skipped, and a deleted subscription comes back at its place', () {
      final s = AppState();
      final other = parseLinks(_links.take(1).toList()).single;
      expect(s.removeConfigs([(group: s.manual, config: other)]), isEmpty);
      final a = ServerGroup('a', GroupKind.subscription, name: 'A');
      final b = ServerGroup('b', GroupKind.subscription, name: 'B');
      final c = ServerGroup('c', GroupKind.subscription, name: 'C');
      s.subscriptions.addAll([a, b, c]);
      final at = s.subscriptions.indexOf(b);
      s.removeSubscription(b);
      expect(s.subscriptions.map((g) => g.id), ['a', 'c']);
      s.restoreSubscription(b, at);
      expect(s.subscriptions.map((g) => g.id), ['a', 'b', 'c']);
      s.restoreSubscription(b, 0);
      expect(s.subscriptions, hasLength(3));
    });
  });

  test('the key of a ping is short, the same for the same link and different for another', () {
    expect(pingKey(_links[0]), hasLength(8));
    expect(pingKey(_links[0]), pingKey(_links[0]));
    expect(pingKey(_links[0]), isNot(pingKey(_links[1])));
    expect(RegExp(r'^[0-9a-f]{8}$').hasMatch(pingKey('')), isTrue);
  });

  group('the options of a section go back to the defaults', () {
    test('only that section', () {
      final o = NetOptions()
        ..blockAds = true
        ..adsLevel = 'max'
        ..adAllow = ['a.example.com']
        ..blockPublicDoh = false
        ..dns = 'google'
        ..fakeIp = true
        ..bypass = ['ir']
        ..listsRoute = 'tunnel'
        ..killSwitch = true
        ..mux = true;
      o.resetSection('ads');
      expect([o.blockAds, o.adsLevel, o.adAllow, o.blockPublicDoh], [false, NetOptions().adsLevel, <String>[], true]);
      expect([o.dns, o.fakeIp, o.bypass, o.listsRoute, o.killSwitch, o.mux], ['google', true, ['ir'], 'tunnel', true, true]);
      o.resetSection('routing');
      expect([o.bypass, o.listsRoute], [<String>[], 'auto']);
      o.resetSection('dns');
      expect([o.dns, o.fakeIp], [NetOptions().dns, false]);
      o.resetSection('network');
      expect(o.killSwitch, isFalse);
      o.resetSection('advanced');
      expect(o.mux, isFalse);
      o.resetSection('nothing'); // an unknown section changes nothing
    });

    test('the download route and the DNS switch are saved and read back; a wrong route is the default', () {
      final o = NetOptions()
        ..listsRoute = 'direct'
        ..blockPublicDoh = false;
      final back = NetOptions()..load(o.toJson());
      expect(back.listsRoute, 'direct');
      expect(back.blockPublicDoh, isFalse);
      expect((NetOptions()..load({'listsRoute': 'sideways'})).listsRoute, 'auto');
      expect(NetOptions().blockPublicDoh, isTrue);
    });
  });
}
