import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/ip_info.dart';

void main() {
  test('through a VPN the Iranian service is not asked, so its real-address answer cannot replace the VPN address', () async {
    // The services of the world see the VPN (the United States); the Iranian one, reached directly
    // by the bypass rules, sees the user's own address in Iran.
    const vpn = IpInfo(v4: '46.8.102.180', country: 'United States', countryCode: 'US');
    const real = IpInfo(v4: '5.213.193.125', country: 'Iran', countryCode: 'IR');
    // What the page used to show while connected:
    expect(chooseIpInfo(vpn, real).v4, '5.213.193.125');
    // What it shows now: the Iranian answer is never put forward.
    expect(chooseIpInfo(vpn, null).v4, '46.8.102.180');
  });
}
