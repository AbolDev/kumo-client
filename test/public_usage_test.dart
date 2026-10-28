import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/proxy_config.dart';
import 'package:kumo/core/vpn_channel.dart';
import 'package:kumo/state/app_state.dart';

const _public = 'vless://11111111-1111-1111-1111-111111111111@v.example.com:443?security=tls#Free one';
const _mine = 'trojan://secret@t.example.com:443?sni=t.example.com#My own';

void main() {
  AppState state() {
    final s = AppState();
    s.collector.configs.addAll(parseLinks([_public]));
    s.manual.configs.addAll(parseLinks([_mine]));
    return s;
  }

  test('only what went through a public server is counted', () async {
    final s = state();
    // The first sample after the start only sets the starting point on a phone; here it counts.
    s.selected = s.collector.configs.first;
    s.onTrafficForTest(const Traffic(0, 0, 100, 1000));
    s.onTrafficForTest(const Traffic(0, 0, 300, 5000));
    expect(s.publicUsage, [5000, 300]);

    s.selected = s.manual.configs.first;
    s.onTrafficForTest(const Traffic(0, 0, 400, 7000));
    expect(s.publicUsage, [5000, 300], reason: 'a server of the user is not a public one');

    s.selected = null;
    s.onTrafficForTest(const Traffic(0, 0, 500, 8000));
    // Automatic mode with no known active server: not counted either.
    expect(s.publicUsage, [5000, 300]);
    await s.flushUsage();
  });

  test('the counter is cleared with the rest of the usage', () {
    final s = state();
    s.publicUsage[0] = 10;
    s.publicUsage[1] = 20;
    s.resetUsage();
    expect(s.publicUsage, [0, 0]);
  });
}
