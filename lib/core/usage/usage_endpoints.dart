import 'dart:convert';

import '../warp/warp_profile.dart' show isCloudflareV4;
import '../warp/warp_signature.dart';

/// The public keys the list of addresses may be signed with, by `key_id`. A key of its own, not the
/// WARP one. Make the pair with `dart run tools/usage_keygen.dart`, put the printed public key here
/// (as `'t1': '...'`) and sign docs/telemetry/endpoints.json with `tools/usage_sign.dart`. While this
/// is empty no downloaded list is accepted and the built-in one below is used.
const usagePublicKeys = <String, String>{
  't1': 'BID0cOLEGSzYhR/o2W9detyUjuIiQrAuNDn1ofJ6dHF9F6DHj+DG9RN7Afti75mcVRTHAOBSDk8A7mNkqH7UGrk=',
};

/// Where the list is downloaded from, one after the other (the same places as the WARP profile).
const usageEndpointUrls = [
  'https://raw.githubusercontent.com/AbolDev/kumo-client/main/docs/telemetry/endpoints.json',
  'https://cdn.jsdelivr.net/gh/AbolDev/kumo-client@main/docs/telemetry/endpoints.json',
];

const _savedList = 'usage_endpoints.json';
const _savedSignature = 'usage_endpoints.json.sig';

const usageEndpointsSchema = 1;

class UsageFormatException implements Exception {
  UsageFormatException(this.message);
  final String message;

  @override
  String toString() => 'usage endpoints: $message';
}

/// The list is from a newer layout than this build knows.
class UsageSchemaTooNew extends UsageFormatException {
  UsageSchemaTooNew(int schema) : super('layout $schema is newer than this version understands');
}

/// A server that takes pings: always https on port 443. [ips] (Cloudflare addresses) are only used
/// by the fragmented method, to reach the host when its name does not resolve.
class UsageEndpoint {
  const UsageEndpoint(this.host, [this.ips = const []]);
  final String host;
  final List<String> ips;

  @override
  bool operator ==(Object other) => other is UsageEndpoint && other.host == host && _same(other.ips, ips);

  @override
  int get hashCode => Object.hash(host, ips.length);

  static bool _same(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class UsageEndpoints {
  const UsageEndpoints({
    required this.version,
    required this.issuedAt,
    required this.expiresAt,
    required this.keyId,
    required this.endpoints,
  });

  final int version;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final String keyId;

  /// Tried in this order.
  final List<UsageEndpoint> endpoints;
}

/// What the app has before anything is downloaded. Version 0: any signed list is newer.
final builtInUsageEndpoints = UsageEndpoints(
  version: 0,
  issuedAt: DateTime.utc(2026, 11, 1),
  expiresAt: DateTime.utc(2100),
  keyId: 'built-in',
  endpoints: const [
    UsageEndpoint('kumo-api.kumoapp.workers.dev'),
    UsageEndpoint('api.kumo-client.ir'),
  ],
);

final _hostRe = RegExp(r'^(?=.{4,100}$)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$');

Never _fail(String what) => throw UsageFormatException(what);

/// Reads and checks the file. Throws [UsageFormatException] (or [UsageSchemaTooNew]).
UsageEndpoints parseUsageEndpoints(String text) {
  if (text.length > 16 * 1024) _fail('the file is too large');
  final Object? raw;
  try {
    raw = jsonDecode(text);
  } catch (_) {
    _fail('not JSON');
  }
  if (raw is! Map<String, dynamic>) _fail('not an object');
  final Map<String, dynamic> j = raw;
  final schema = j['schema'];
  if (schema is! int || schema < 1) _fail('no layout number');
  if (schema > usageEndpointsSchema) throw UsageSchemaTooNew(schema);
  final version = j['version'];
  if (version is! int || version < 1 || version > (1 << 30)) _fail('version is not valid');
  DateTime date(String key) {
    final v = j[key];
    final d = v is String ? DateTime.tryParse(v) : null;
    if (d == null) _fail('$key is not a date');
    return d.toUtc();
  }

  final issued = date('issued_at'), expires = date('expires_at');
  if (!expires.isAfter(issued)) _fail('expires_at is not after issued_at');
  final keyId = j['key_id'];
  if (keyId is! String || !RegExp(r'^[a-z0-9]{1,16}$').hasMatch(keyId)) _fail('key_id is not valid');
  final list = j['endpoints'];
  if (list is! List || list.isEmpty || list.length > 8) _fail('endpoints is not valid');
  final endpoints = <UsageEndpoint>[];
  for (final e in list) {
    if (e is! Map<String, dynamic>) _fail('endpoints is not valid');
    final host = e['host'];
    if (host is! String || !_hostRe.hasMatch(host)) _fail('an endpoint has no valid host');
    final ips = e['ips'];
    final out = <String>[];
    if (ips != null) {
      if (ips is! List || ips.length > 8) _fail('ips is not valid');
      for (final ip in ips) {
        if (ip is! String || !isCloudflareV4(ip)) _fail('an address is outside Cloudflare');
        out.add(ip);
      }
    }
    endpoints.add(UsageEndpoint(host, out));
  }
  return UsageEndpoints(
      version: version, issuedAt: issued, expiresAt: expires, keyId: keyId, endpoints: endpoints);
}

/// Holds the list the app uses: the newest of the built-in one and the one downloaded last, and a
/// downloaded one only when its signature fits one of [keys]. A file that does not check, is not
/// newer than the one in use, or has run out is never taken.
class UsageEndpointStore {
  UsageEndpointStore({
    required this.read,
    required this.write,
    required this.fetch,
    DateTime Function()? now,
    this.keys = usagePublicKeys,
  }) : _now = now ?? DateTime.now;

  final Map<String, String> keys;
  final Future<String?> Function(String name) read;
  final Future<void> Function(String name, String content) write;

  /// The text at [url]; throws when it cannot be had.
  final Future<String> Function(String url) fetch;
  final DateTime Function() _now;

  UsageEndpoints current = builtInUsageEndpoints;

  /// What a list text is, when a known key signed it and it is valid. Throws otherwise.
  UsageEndpoints check(String text, String signature) {
    final Object? raw;
    try {
      raw = jsonDecode(text);
    } catch (_) {
      throw UsageFormatException('not JSON');
    }
    final keyId = raw is Map ? raw['key_id'] : null;
    final key = keyId is String ? keys[keyId] : null;
    if (key == null) throw UsageFormatException('signed with a key this version does not know');
    if (!verifyWarpSignature(utf8.encode(text), signature, key)) {
      throw UsageFormatException('the signature does not fit');
    }
    return parseUsageEndpoints(text);
  }

  /// Takes the saved list when it checks and is newer than the built-in one. Never throws.
  Future<void> load() async {
    try {
      final text = await read(_savedList), sig = await read(_savedSignature);
      if (text == null || sig == null) return;
      final saved = check(text, sig.trim());
      if (saved.version > current.version && saved.expiresAt.isAfter(_now().toUtc())) current = saved;
    } catch (_) {}
  }

  /// Downloads the list and takes it when it is newer. True when a newer one was taken.
  Future<bool> update() async {
    for (final url in usageEndpointUrls) {
      try {
        final text = await fetch(url);
        final sig = (await fetch('$url.sig')).trim();
        final UsageEndpoints fresh;
        try {
          fresh = check(text, sig);
        } on UsageSchemaTooNew {
          continue;
        }
        if (!fresh.expiresAt.isAfter(_now().toUtc())) continue;
        if (fresh.version <= current.version) return false;
        await write(_savedList, text);
        await write(_savedSignature, sig);
        current = fresh;
        return true;
      } catch (_) {
        // the next source
      }
    }
    return false;
  }
}
