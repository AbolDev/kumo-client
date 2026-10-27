import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;

/// What public services see of this connection.
class IpInfo {
  const IpInfo({this.v4, this.v6, this.country, this.countryCode, this.city, this.region, this.isp});

  final String? v4;
  final String? v6;
  final String? country;
  final String? countryCode;
  final String? city;
  final String? region;
  final String? isp;
}

/// One resolver (or the address) the DNS leak test saw.
class DnsLeakEntry {
  const DnsLeakEntry(this.ip, this.country, this.org);

  final String ip;
  final String country;
  final String org;
}

class DnsLeakResult {
  const DnsLeakResult(this.address, this.resolvers, this.conclusion);

  /// The public address the test server saw, and the resolvers that asked it.
  final DnsLeakEntry? address;
  final List<DnsLeakEntry> resolvers;
  final String conclusion;
}

HttpClient _client(int? proxyPort) {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  if (proxyPort != null) client.findProxy = (_) => 'PROXY 127.0.0.1:$proxyPort';
  return client;
}

Future<String> _get(Uri uri, int? proxyPort, {Duration timeout = const Duration(seconds: 10)}) async {
  final client = _client(proxyPort);
  try {
    final req = await client.getUrl(uri).timeout(timeout);
    req.headers.set('User-Agent', 'Kumo');
    final res = await req.close().timeout(timeout);
    if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
    return await res.transform(utf8.decoder).join().timeout(timeout);
  } finally {
    client.close(force: true);
  }
}

bool _isV6(String s) => s.contains(':') && InternetAddress.tryParse(s) != null;

/// The IPv4 and IPv6 addresses (either can be missing) and the place the IPv4 one is in.
/// [proxyPort] sends the requests through the local proxy when the tunnel is not used.
Future<IpInfo> fetchIpInfo({int? proxyPort}) async {
  Future<String?> v4() async {
    for (final url in const ['https://api.ipify.org', 'https://ipv4.icanhazip.com']) {
      try {
        final s = (await _get(Uri.parse(url), proxyPort, timeout: const Duration(seconds: 8))).trim();
        if (InternetAddress.tryParse(s)?.type == InternetAddressType.IPv4) return s;
      } catch (_) {}
    }
    return null;
  }

  Future<String?> v6() async {
    for (final url in const ['https://api6.ipify.org', 'https://ipv6.icanhazip.com', 'https://v6.ident.me']) {
      try {
        final s = (await _get(Uri.parse(url), proxyPort, timeout: const Duration(seconds: 6))).trim();
        if (_isV6(s)) return s;
      } catch (_) {}
    }
    return null;
  }

  // Services of the world often cannot see the address of a user in Iran. This Iranian service can,
  // so it is asked as well.
  final results = await Future.wait([v4(), v6(), fetchIranInfo(proxyPort)]);
  final ip4 = results[0] as String?, ip6 = results[1] as String?;
  final iran = results[2] as IpInfo?;
  String? country, code, city, region, isp;
  final lookup = ip4 ?? ip6;
  if (lookup != null) {
    try {
      final j = jsonDecode(await _get(Uri.parse('https://ipwho.is/$lookup'), proxyPort));
      if (j is Map && j['success'] != false) {
        country = j['country'] as String?;
        code = j['country_code'] as String?;
        city = j['city'] as String?;
        region = j['region'] as String?;
        final c = j['connection'];
        if (c is Map) isp = (c['isp'] ?? c['org']) as String?;
      }
    } catch (_) {}
  }
  final others = IpInfo(
      v4: ip4, v6: ip6, country: country, countryCode: code, city: city, region: region, isp: isp);
  final chosen = chooseIpInfo(others, iran);
  if (chosen.v4 == null && chosen.v6 == null) throw const SocketException('no address');
  return chosen;
}

/// The Iranian service's answer about this connection, or null when it fails.
Future<IpInfo?> fetchIranInfo(int? proxyPort) async {
  try {
    final j = jsonDecode(await _get(Uri.parse('https://api.ipmyp.ir/json'), proxyPort,
        timeout: const Duration(seconds: 8)));
    return j is Map ? parseIranInfo(j) : null;
  } catch (_) {
    return null;
  }
}

/// Reads the answer of api.ipmyp.ir (`status`, `query`, `country`, `countryCode`, `regionName`,
/// `city`, `isp`). Null when it says it failed or holds no address.
IpInfo? parseIranInfo(Map j) {
  if (j['status'] != 'success') return null;
  String? text(String key) {
    final v = j[key];
    return v is String && v.trim().isNotEmpty ? v.trim() : null;
  }

  final query = text('query');
  final parsed = query == null ? null : InternetAddress.tryParse(query);
  if (parsed == null) return null;
  return IpInfo(
    v4: parsed.type == InternetAddressType.IPv4 ? query : null,
    v6: parsed.type == InternetAddressType.IPv6 ? query : null,
    country: text('country'),
    countryCode: text('countryCode')?.toUpperCase(),
    city: text('city'),
    region: text('regionName'),
    isp: text('isp') ?? text('org'),
  );
}

/// The Iranian service's answer is used only when it says Iran and the other services say another
/// country (they do not see the address of a user in Iran, so their answer is wrong) or gave nothing
/// at all. In every other case the others' answer stands.
IpInfo chooseIpInfo(IpInfo others, IpInfo? iran) {
  if (iran == null || iran.countryCode != 'IR') return others;
  final noAnswer = others.v4 == null && others.v6 == null;
  final code = others.countryCode?.toUpperCase();
  final otherCountry = code != null && code != 'IR';
  if (!noAnswer && !otherCountry) return others;
  return IpInfo(
    // the address the Iranian service saw; the other kind of address (v4 / v6) is kept
    v4: iran.v4 ?? others.v4,
    v6: iran.v6 ?? others.v6,
    country: iran.country,
    countryCode: iran.countryCode,
    city: iran.city,
    region: iran.region,
    isp: iran.isp,
  );
}
/// The DNS leak test: asks the system resolver for names of a test domain that only the test
/// server answers, then asks that server which resolvers came to it. The lookups use the
/// device's own resolver on purpose, as an app would.
Future<DnsLeakResult> runDnsLeakTest({int? proxyPort}) async {
  final id = (await _get(Uri.parse('https://bash.ws/id'), proxyPort)).trim();
  if (id.isEmpty || id.length > 64) throw const FormatException('bad id');
  final random = Random();
  // With the local proxy (VPN without the tunnel) the names are given to the proxy, which looks
  // them up through the VPN: that is the lookup an app using the connection causes. With the
  // tunnel, or with no VPN, the device's own resolver is asked, as an app would.
  Future<void> lookup(String name) async {
    if (proxyPort == null) {
      try {
        await InternetAddress.lookup(name).timeout(const Duration(seconds: 6));
      } catch (_) {}
      return;
    }
    final client = _client(proxyPort);
    try {
      final req = await client.getUrl(Uri.parse('http://$name/')).timeout(const Duration(seconds: 6));
      await (await req.close().timeout(const Duration(seconds: 6))).drain<void>();
    } catch (_) {
      // only the lookup matters, not the answer
    } finally {
      client.close(force: true);
    }
  }

  await Future.wait([
    for (var i = 1; i <= 10; i++) lookup('${i + random.nextInt(1000) * 10}.$id.bash.ws'),
  ]);
  await Future<void>.delayed(const Duration(seconds: 1));
  final body = await _get(Uri.parse('https://bash.ws/dnsleak/test/$id?json'), proxyPort);
  final list = jsonDecode(body);
  if (list is! List) throw const FormatException('bad answer');
  DnsLeakEntry? address;
  final resolvers = <DnsLeakEntry>[];
  var conclusion = '';
  for (final e in list) {
    if (e is! Map) continue;
    final entry = DnsLeakEntry('${e['ip'] ?? ''}', '${e['country_name'] ?? ''}',
        '${e['org'] ?? e['asn'] ?? ''}');
    switch (e['type']) {
      case 'ip':
        address = entry;
      case 'dns':
        resolvers.add(entry);
      case 'conclusion':
        conclusion = entry.ip;
    }
  }
  return DnsLeakResult(address, resolvers, conclusion);
}
