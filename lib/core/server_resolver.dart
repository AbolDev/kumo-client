import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'proxy_config.dart';

/// Looking up the names of servers before a connection, so that the network's own resolver is asked
/// as little as possible (it sees which server the user looks for, and on many networks it answers
/// wrongly for the names of servers that are blocked):
/// 1. over encrypted DNS (DNS over HTTPS to 1.1.1.1 and 8.8.8.8 at once), which a network cannot read
///    or change;
/// 2. when that does not answer (it is blocked on some networks), the system's own resolver;
/// 3. when neither answers, the name is left in the configuration for the core to look up.
/// The address that is found takes the place of the name in the server's settings; the name stays
/// where a server needs it (the TLS server name, the Host header).

typedef NameLookup = Future<String?> Function(String host);

/// A lookup with the system's own resolver (IPv4 first), null when it fails.
Future<String?> systemLookup(String host) async {
  try {
    final found = await InternetAddress.lookup(host).timeout(const Duration(seconds: 3));
    if (found.isEmpty) return null;
    return found.firstWhere((a) => a.type == InternetAddressType.IPv4, orElse: () => found.first).address;
  } catch (_) {
    return null;
  }
}

/// DNS over HTTPS (the JSON form of the API) at one of the public resolvers named by address.
Future<String?> dohLookup(String host, {String resolver = 'https://1.1.1.1/dns-query'}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final uri = Uri.parse(resolver).replace(queryParameters: {'name': host, 'type': 'A'});
    final req = await client.getUrl(uri).timeout(const Duration(seconds: 3));
    req.headers.set(HttpHeaders.acceptHeader, 'application/dns-json');
    final res = await req.close().timeout(const Duration(seconds: 3));
    if (res.statusCode != 200) return null;
    final text = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 3));
    return firstARecord(text);
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// The first IPv4 address in the answer of a DNS-over-HTTPS JSON reply, or null.
String? firstARecord(String json) {
  try {
    final j = jsonDecode(json);
    final answers = j is Map ? j['Answer'] : null;
    if (answers is! List) return null;
    for (final a in answers) {
      if (a is Map && a['type'] == 1 && a['data'] is String) {
        final ip = InternetAddress.tryParse(a['data'] as String);
        if (ip != null && ip.type == InternetAddressType.IPv4) return ip.address;
      }
    }
  } catch (_) {}
  return null;
}

/// The first of [lookups] that gives an address; null when all of them gave none (or failed).
Future<String?> firstAnswer(List<Future<String?>> lookups) {
  final done = Completer<String?>();
  var left = lookups.length;
  if (left == 0) return Future.value(null);
  void settle(String? ip) {
    left--;
    if (done.isCompleted) return;
    if (ip != null) {
      done.complete(ip);
    } else if (left == 0) {
      done.complete(null);
    }
  }

  for (final l in lookups) {
    l.then(settle, onError: (Object _) => settle(null));
  }
  return done.future;
}

/// Looks names up the way described above, and remembers what it found for a few minutes. When the
/// encrypted resolvers did not answer, they are not tried again for a while (a blocked one would
/// otherwise add its timeout to every connection).
class NameResolver {
  NameResolver({
    NameLookup? doh,
    NameLookup? system,
    DateTime Function()? now,
    this.cacheFor = const Duration(minutes: 10),
    this.dohPause = const Duration(minutes: 5),
    this.dohWait = const Duration(milliseconds: 2500),
  })  : _doh = doh ?? _defaultDoh,
        _system = system ?? systemLookup,
        _now = now ?? DateTime.now;

  /// Cloudflare and Google asked at once: the first address that comes back (one after the other,
  /// a blocked first one used to cost its whole timeout before the second was even asked).
  static Future<String?> _defaultDoh(String host) => firstAnswer([
        dohLookup(host),
        dohLookup(host, resolver: 'https://8.8.8.8/resolve'),
      ]);

  final NameLookup _doh;
  final NameLookup _system;
  final DateTime Function() _now;
  final Duration cacheFor;
  final Duration dohPause;

  /// How long the encrypted resolvers are waited for before the system's resolver is asked.
  final Duration dohWait;

  final _cache = <String, ({String ip, DateTime at})>{};
  DateTime? _dohBlockedUntil;

  /// The address for [host], or null when nothing answered.
  Future<String?> lookup(String host) async {
    final key = host.toLowerCase();
    final cached = _cache[key];
    if (cached != null && _now().difference(cached.at) < cacheFor) return cached.ip;
    String? ip;
    final paused = _dohBlockedUntil != null && _now().isBefore(_dohBlockedUntil!);
    if (!paused) {
      ip = await _doh(host).timeout(dohWait, onTimeout: () => null).catchError((Object _) => null);
      if (ip == null) _dohBlockedUntil = _now().add(dohPause);
    }
    ip ??= await _system(host);
    if (ip != null) _cache[key] = (ip: ip, at: _now());
    return ip;
  }
}

/// [outbound] with its server name replaced by the address [lookup] finds. Where the server needs
/// the name (TLS server name, a Host header, the host of an HTTP upgrade) it is put there first. An
/// outbound whose server is already an address, or whose name is not found, comes back unchanged.
Future<Map<String, dynamic>> resolveOutbound(Map<String, dynamic> outbound, NameLookup lookup) async {
  final out = Map<String, dynamic>.of(outbound);
  // A WireGuard endpoint keeps its server in the peer.
  if (out['type'] == 'wireguard') {
    final peers = out['peers'];
    if (peers is List && peers.isNotEmpty && peers.first is Map) {
      final peer = Map<String, dynamic>.from(peers.first as Map);
      final host = peer['address'];
      if (host is String && InternetAddress.tryParse(host) == null) {
        final ip = await lookup(host);
        if (ip != null) {
          peer['address'] = ip;
          out['peers'] = [peer, ...peers.skip(1)];
        }
      }
    }
    return out;
  }
  final server = out['server'];
  if (server is! String || server.isEmpty || InternetAddress.tryParse(server) != null) return out;
  final ip = await lookup(server);
  if (ip == null) return out;
  out['server'] = ip;
  final tls = out['tls'];
  if (tls is Map && (tls['server_name'] ?? '') == '') {
    out['tls'] = {...tls, 'server_name': server};
  }
  final t = out['transport'];
  if (t is Map) {
    final type = t['type'];
    if (type == 'ws' && !((t['headers'] as Map?)?.containsKey('Host') ?? false)) {
      out['transport'] = {
        ...t,
        'headers': {...?(t['headers'] as Map?), 'Host': server},
      };
    } else if ((type == 'httpupgrade' || type == 'http') && t['host'] == null) {
      out['transport'] = {
        ...t,
        'host': type == 'http' ? [server] : server,
      };
    }
  }
  return out;
}

/// The most servers whose names are looked up in advance: a group of many (the automatic mode) is
/// left to the core.
const resolveAheadLimit = 25;

/// [servers] with their names looked up in advance ([resolver]); the ones that cannot be (OpenVPN,
/// a name nobody answers) are returned as they are. Gives up after [budget] and returns [servers].
Future<List<ProxyConfig>> resolveServers(
  List<ProxyConfig> servers,
  NameResolver resolver, {
  Duration budget = const Duration(seconds: 7),
}) async {
  if (servers.isEmpty || servers.length > resolveAheadLimit) return servers;
  Future<ProxyConfig> one(ProxyConfig c) async {
    if (c.isOpenVpn || !c.canSingBox) return c;
    final outbound = await resolveOutbound(c.outbound, resolver.lookup);
    final inner = [for (final l in c.inner) await resolveOutbound(l, resolver.lookup)];
    return ProxyConfig(
      link: c.link,
      protocol: c.protocol,
      name: c.name,
      host: c.host,
      port: c.port,
      outbound: outbound,
      xrayOutbound: c.xrayOutbound,
      inner: inner,
      xrayNote: c.xrayNote,
      ovpn: c.ovpn,
      preferXray: c.preferXray,
    )..latencyMs = c.latencyMs;
  }

  try {
    return await Future.wait(servers.map(one)).timeout(budget);
  } catch (_) {
    return servers;
  }
}
