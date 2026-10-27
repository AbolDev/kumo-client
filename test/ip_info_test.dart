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

  const sample = '[{"ip":"2a13:7c00:8:4::1","country":"us","country_name":"USA","asn":"AS56971 CGI Global Limited","org":"CGI Global Limited","type":"ip"},'
      '{"ip":"162.158.109.28","country":"de","country_name":"Germany","asn":"AS13335 CloudFlare Inc","org":"CloudFlare Inc","type":"dns"},'
      '{"ip":"2.189.44.84","country":"ir","country_name":"Iran","asn":"AS49666 Telecommunication Infrastructure Company","org":"Telecommunication Infrastructure Company","type":"dns"},'
      '{"ip":"DNS may be leaking.","country":"","country_name":"","asn":"","org":"","type":"conclusion"}]';

  test('the DNS leak answer is read, the network number apart from the name', () {
    final r = parseDnsLeak(sample);
    expect(r.address!.country, 'USA');
    expect(r.address!.asn, 'AS56971');
    expect(r.resolvers.length, 2);
    expect(r.resolvers.first.asn, 'AS13335');
    expect(r.resolvers.first.org, 'CloudFlare Inc');
  });

  test('a resolver of another country that is not a public service is a leak', () {
    final j = judgeDnsLeak(parseDnsLeak(sample));
    expect(j.verdict, DnsLeakVerdict.leak);
    final kinds = {for (final e in j.kinds.entries) e.key.ip: e.value};
    expect(kinds['2.189.44.84'], DnsEntryKind.leak);
    expect(kinds['162.158.109.28'], DnsEntryKind.publicDns);
  });

  test('same country or same network is fine, a lone public resolver abroad is only "possible"', () {
    const home = DnsLeakEntry('9.9.9.9', 'Germany', 'Hetzner', 'AS24940');
    DnsLeakResult seen(List<DnsLeakEntry> r) => DnsLeakResult(home, r, '');
    expect(judgeDnsLeak(seen([const DnsLeakEntry('1.1.1.1', 'Germany', 'Whoever', 'AS1')])).verdict, DnsLeakVerdict.ok);
    expect(judgeDnsLeak(seen([const DnsLeakEntry('5.5.5.5', 'Iran', 'X', 'AS24940')])).verdict, DnsLeakVerdict.ok);
    expect(judgeDnsLeak(seen([const DnsLeakEntry('8.8.8.8', 'USA', 'Google LLC', 'AS15169')])).verdict,
        DnsLeakVerdict.possible);
    expect(judgeDnsLeak(seen(const [])).verdict, DnsLeakVerdict.unknown);
    expect(judgeDnsLeak(const DnsLeakResult(null, [DnsLeakEntry('1.1.1.1', 'USA', 'x')], '')).verdict,
        DnsLeakVerdict.unknown);
    expect(publicDnsName(const DnsLeakEntry('1.1.1.1', 'USA', 'Cloudflare, Inc.')), 'Cloudflare');
    expect(publicDnsName(const DnsLeakEntry('2.2.2.2', 'Iran', 'Telecommunication Infrastructure Company')), isNull);
  });
}