import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/ip_info.dart';

void main() {
  const world = IpInfo(v4: '1.2.3.4', country: 'Germany', countryCode: 'DE', isp: 'Hetzner');
  final iran = parseIranInfo({
    'status': 'success',
    'query': '5.6.7.8',
    'country': 'Iran',
    'countryCode': 'IR',
    'regionName': 'Tehran',
    'city': 'Tehran',
    'isp': 'MCI',
  })!;

  test('the answer of the Iranian service is read', () {
    expect(iran.v4, '5.6.7.8');
    expect(iran.countryCode, 'IR');
    expect(iran.region, 'Tehran');
    expect(parseIranInfo({'status': 'fail'}), isNull);
    expect(parseIranInfo({'status': 'success', 'query': 'nope'}), isNull);
    expect(parseIranInfo({'status': 'success', 'query': '2001:db8::1', 'countryCode': 'ir'})!.v6, '2001:db8::1');
  });

  test('it is used only when it says Iran and the others say another country', () {
    expect(chooseIpInfo(world, iran).country, 'Iran');
    expect(chooseIpInfo(world, iran).v4, '5.6.7.8');
    // the others agree: theirs stands
    expect(chooseIpInfo(const IpInfo(v4: '5.6.7.8', countryCode: 'IR', country: 'Iran'), iran).isp, isNull);
    // the Iranian service says another country: it is not used
    final abroad = parseIranInfo({'status': 'success', 'query': '9.9.9.9', 'countryCode': 'CZ', 'country': 'Czechia'})!;
    expect(chooseIpInfo(world, abroad).country, 'Germany');
    // no answer from the Iranian service
    expect(chooseIpInfo(world, null).country, 'Germany');
    // the others know the address but not the country: theirs stands
    expect(chooseIpInfo(const IpInfo(v4: '1.2.3.4'), iran).country, isNull);
    // the others gave nothing at all
    expect(chooseIpInfo(const IpInfo(), iran).country, 'Iran');
  });
}