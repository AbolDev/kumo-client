import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/state/app_state.dart';

String vless(String ip) => 'vless://11111111-1111-1111-1111-111111111111@$ip:443?security=tls&type=ws&sni=cdn.example.com&host=cdn.example.com#n%20$ip';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the clean-IP group is shown only while it has configs, and a scan replaces the earlier one', () {
    final s = AppState();
    expect(s.groups.contains(s.cleanGroup), isFalse);
    expect(s.addCleanIps([vless('104.16.0.1'), vless('104.16.0.2')]), 2);
    expect(s.groups.contains(s.cleanGroup), isTrue);
    expect(s.cleanGroup.configs, hasLength(2));
    // They are among all the servers (the automatic mode can use them), and apart from the manual ones.
    expect(s.all.where((c) => c.host.startsWith('104.16.')).length, 2);
    expect(s.manual.configs, isEmpty);
    // The next scan replaces them.
    expect(s.addCleanIps([vless('104.16.0.9')]), 1);
    expect(s.cleanGroup.configs.map((c) => c.host), ['104.16.0.9']);
    // The chosen one stays.
    s.selected = s.cleanGroup.configs.single;
    s.addCleanIps([vless('104.16.0.7')]);
    expect(s.cleanGroup.configs.map((c) => c.host), containsAll(['104.16.0.9', '104.16.0.7']));
    // Nothing readable: nothing changes.
    expect(s.addCleanIps(['not a link']), 0);
    expect(s.cleanGroup.configs, hasLength(2));
    s.clearCleanIps();
    expect(s.cleanGroup.configs, isEmpty);
    expect(s.selected, isNull);
    expect(s.groups.contains(s.cleanGroup), isFalse);
  });
}
