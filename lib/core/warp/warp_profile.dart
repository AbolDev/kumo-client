import 'dart:convert';

/// The WARP "profile": a small signed file (docs/warp/profile.json in the repository) that tells the
/// app which connection methods to try and with what numbers, so that a change in how the network
/// is filtered can be answered without a new version of the app.
///
/// The file holds data only. The kinds of method are fixed in the app ([warpKinds]); the file picks
/// among them and gives their numbers, inside the limits checked here. Anything it says about a kind
/// or a feature this build does not know is skipped, so older versions simply ignore newer methods.

/// The newest layout of the file this build understands.
const warpSchema = 1;

/// What this build can do. A method that asks for more than this is skipped.
const warpFeatures = {'reg.fragment.v1', 'wg.noise.v1', 'wg.plain.v1'};

/// The kinds of method this build can run.
const warpKinds = {'wg-noise', 'wg-plain'};

const warpPlatforms = {'android', 'windows', 'linux', 'macos'};

/// The file is not usable (a limit broken, a value that makes no sense).
class WarpFormatException implements Exception {
  WarpFormatException(this.message);
  final String message;

  @override
  String toString() => 'WARP profile: $message';
}

/// The file is from a newer layout than this build knows: keep what was saved before.
class WarpSchemaTooNew extends WarpFormatException {
  WarpSchemaTooNew(int schema) : super('layout $schema is newer than this version understands');
}

/// A packet sent before the first packet of the tunnel so that the start of it does not look like
/// WireGuard. `rand`: random bytes, [packet] is a size range ("10-30"); `str`: the text [packet].
class WarpNoise {
  const WarpNoise(this.type, this.packet, this.delay);

  final String type;
  final String packet;

  /// Milliseconds to wait after it, a range ("5-10").
  final String delay;

  /// The form Xray's freedom outbound takes.
  Map<String, String> toXray() => {'type': type, 'packet': packet, 'delay': delay};

  /// "rand~10-30~5-10": the form kept in a link.
  String get spec => '$type~$packet~$delay';

  @override
  bool operator ==(Object other) =>
      other is WarpNoise && other.type == type && other.packet == packet && other.delay == delay;

  @override
  int get hashCode => Object.hash(type, packet, delay);
}

final _range = RegExp(r'^(\d{1,4})-(\d{1,4})$');
final _text = RegExp(r'^[A-Za-z0-9 ]{1,32}$');

/// A noise from its link form, or null when it is not valid.
WarpNoise? parseWarpNoise(String spec) {
  final p = spec.split('~');
  if (p.length != 3) return null;
  return checkedNoise(p[0], p[1], p[2]);
}

/// A noise within the limits, or null: at most 1200 bytes, 200 ms.
WarpNoise? checkedNoise(String type, String packet, String delay) {
  bool inRange(String text, int max, {int min = 0}) {
    final m = _range.firstMatch(text);
    if (m == null) return false;
    final a = int.parse(m[1]!), b = int.parse(m[2]!);
    return a >= min && a <= b && b <= max;
  }

  if (!inRange(delay, 200)) return null;
  if (type == 'rand') {
    return inRange(packet, 1200, min: 1) ? WarpNoise(type, packet, delay) : null;
  }
  if (type == 'str') return _text.hasMatch(packet) ? WarpNoise(type, packet, delay) : null;
  return null;
}

/// The addresses of Cloudflare (IPv4), the only ones the file may send the app to.
const _cloudflare = [
  '173.245.48.0/20',
  '103.21.244.0/22',
  '103.22.200.0/22',
  '103.31.4.0/22',
  '141.101.64.0/18',
  '108.162.192.0/18',
  '190.93.240.0/20',
  '188.114.96.0/20',
  '197.234.240.0/22',
  '198.41.128.0/17',
  '162.158.0.0/15',
  '104.16.0.0/13',
  '104.24.0.0/14',
  '172.64.0.0/13',
  '131.0.72.0/22',
];

int? _v4(String ip) {
  final m = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$').firstMatch(ip);
  if (m == null) return null;
  var n = 0;
  for (var i = 1; i <= 4; i++) {
    final part = int.parse(m[i]!);
    if (part > 255) return null;
    n = (n << 8) | part;
  }
  return n;
}

/// True when [ip] is an IPv4 address inside Cloudflare's ranges.
bool isCloudflareV4(String ip) {
  final n = _v4(ip);
  if (n == null) return false;
  for (final cidr in _cloudflare) {
    final parts = cidr.split('/');
    final base = _v4(parts[0])!;
    final bits = int.parse(parts[1]);
    final mask = (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF;
    if ((n & mask) == (base & mask)) return true;
  }
  return false;
}

class WarpEndpoint {
  const WarpEndpoint(this.ip, this.ports);
  final String ip;
  final List<int> ports;
}

class WarpMethod {
  const WarpMethod({
    required this.id,
    required this.kind,
    required this.rank,
    required this.platforms,
    required this.requires,
    required this.minBuild,
    required this.maxBuild,
    required this.noise,
  });

  final String id;
  final String kind;
  final int rank;

  /// Empty: every platform.
  final Set<String> platforms;
  final Set<String> requires;
  final int? minBuild;
  final int? maxBuild;
  final List<WarpNoise> noise;
}

class WarpProfile {
  const WarpProfile({
    required this.version,
    required this.issuedAt,
    required this.expiresAt,
    required this.keyId,
    required this.message,
    required this.disabled,
    required this.fragmentSize,
    required this.fragmentDelay,
    required this.apiIps,
    required this.endpoints,
    required this.methods,
  });

  final int version;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final String keyId;

  /// A short note by language ("en", "fa" ...), plain text.
  final Map<String, String> message;
  final Set<String> disabled;

  /// The size (bytes) and pause (ms) of the pieces the TLS hello of the sign-up is cut into: [min, max].
  final (int, int) fragmentSize;
  final (int, int) fragmentDelay;

  /// Cloudflare addresses of the sign-up service, tried in order.
  final List<String> apiIps;
  final List<WarpEndpoint> endpoints;
  final List<WarpMethod> methods;

  /// The methods this build can run on [platform] at [build], best first. Anything disabled, of a
  /// kind or needing a feature this build does not have, or outside its build range is left out.
  List<WarpMethod> usable({required String platform, required int build}) {
    final list = [
      for (final m in methods)
        if (!disabled.contains(m.id) &&
            warpKinds.contains(m.kind) &&
            (m.platforms.isEmpty || m.platforms.contains(platform)) &&
            m.requires.every(warpFeatures.contains) &&
            (m.minBuild == null || build >= m.minBuild!) &&
            (m.maxBuild == null || build <= m.maxBuild!))
          m,
    ];
    // List.sort is not stable; the position in the file breaks ties.
    final order = {for (var i = 0; i < methods.length; i++) methods[i]: i};
    list.sort((a, b) => a.rank != b.rank ? a.rank.compareTo(b.rank) : order[a]!.compareTo(order[b]!));
    return list;
  }
}

Never _fail(String what) => throw WarpFormatException(what);

int _int(Object? v, String name, int min, int max) {
  if (v is! int || v < min || v > max) _fail('$name must be a whole number from $min to $max');
  return v;
}

(int, int) _pair(Object? v, String name, int min, int max) {
  if (v is! List || v.length != 2) _fail('$name must be two numbers');
  final a = _int(v[0], name, min, max), b = _int(v[1], name, min, max);
  if (a > b) _fail('$name must go from the smaller to the larger');
  return (a, b);
}

final _id = RegExp(r'^[a-z0-9][a-z0-9-]{0,31}$');

/// Reads and checks the file. Throws [WarpFormatException] (or [WarpSchemaTooNew]) when it cannot be
/// used as a whole; methods of a kind this build does not know are skipped, not an error.
WarpProfile parseWarpProfile(String text) {
  if (text.length > 64 * 1024) _fail('the file is too large');
  final Object? raw;
  try {
    raw = jsonDecode(text);
  } catch (_) {
    _fail('not JSON');
  }
  if (raw is! Map<String, dynamic>) _fail('not an object');
  final j = raw;

  final schema = j['schema'];
  if (schema is! int || schema < 1) _fail('no layout number');
  if (schema > warpSchema) throw WarpSchemaTooNew(schema);

  final version = _int(j['version'], 'version', 1, 1 << 30);
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

  final message = <String, String>{};
  final m = j['message'];
  if (m != null) {
    if (m is! Map || m.length > 8) _fail('message is not valid');
    m.forEach((k, v) {
      if (k is! String || !RegExp(r'^[a-z]{2,3}$').hasMatch(k) || v is! String) _fail('message is not valid');
      if (v.length > 200 || v.contains(RegExp(r'[<>]')) || v.contains('://')) {
        _fail('message holds markup or a link, or is too long');
      }
      message[k] = v;
    });
  }

  final disabled = <String>{};
  final d = j['disabled_methods'];
  if (d != null) {
    if (d is! List || d.length > 20) _fail('disabled_methods is not valid');
    for (final id in d) {
      if (id is! String || !_id.hasMatch(id)) _fail('disabled_methods is not valid');
      disabled.add(id);
    }
  }

  final reg = j['register'];
  if (reg is! Map<String, dynamic>) _fail('register is missing');
  final frag = reg['fragment'];
  if (frag is! Map<String, dynamic>) _fail('register.fragment is missing');
  final size = _pair(frag['size'], 'fragment.size', 1, 200);
  final delay = _pair(frag['delay_ms'], 'fragment.delay_ms', 0, 100);
  final ips = reg['api_ips'];
  if (ips is! List || ips.isEmpty || ips.length > 16) _fail('register.api_ips is not valid');
  final apiIps = <String>[];
  for (final ip in ips) {
    if (ip is! String || !isCloudflareV4(ip)) _fail('register.api_ips holds an address outside Cloudflare');
    apiIps.add(ip);
  }

  final eps = j['endpoints'];
  if (eps is! List || eps.isEmpty || eps.length > 64) _fail('endpoints is not valid');
  final endpoints = <WarpEndpoint>[];
  for (final e in eps) {
    if (e is! Map<String, dynamic>) _fail('endpoints is not valid');
    final ip = e['ip'];
    if (ip is! String || !isCloudflareV4(ip)) _fail('an endpoint is outside Cloudflare');
    final ports = e['ports'];
    if (ports is! List || ports.isEmpty || ports.length > 8) _fail('an endpoint has no usable ports');
    endpoints.add(WarpEndpoint(ip, [for (final p in ports) _int(p, 'port', 1, 65535)]));
  }

  final ms = j['methods'];
  if (ms is! List || ms.isEmpty || ms.length > 20) _fail('methods is not valid');
  final methods = <WarpMethod>[];
  final seen = <String>{};
  for (final e in ms) {
    if (e is! Map<String, dynamic>) _fail('methods is not valid');
    final id = e['id'];
    if (id is! String || !_id.hasMatch(id) || !seen.add(id)) _fail('a method has no valid, unique id');
    final kind = e['kind'];
    if (kind is! String) _fail('method $id has no kind');
    // A kind this build does not know is for a newer version of the app.
    if (!warpKinds.contains(kind)) continue;
    final rank = _int(e['rank'], 'rank of $id', 1, 100);
    Set<String> strings(Object? v, String name, int max) {
      if (v == null) return {};
      if (v is! List || v.length > max) _fail('$name of $id is not valid');
      return {
        for (final s in v)
          if (s is String && s.length <= 40) s else _fail('$name of $id is not valid'),
      };
    }

    final platforms = strings(e['platforms'], 'platforms', 8).where(warpPlatforms.contains).toSet();
    final requires = strings(e['requires'], 'requires', 10);
    int? build(String key) => e[key] == null ? null : _int(e[key], '$key of $id', 0, 1 << 30);
    final params = e['params'];
    final noise = <WarpNoise>[];
    if (kind == 'wg-noise') {
      final list = params is Map<String, dynamic> ? params['noise'] : null;
      if (list is! List || list.isEmpty || list.length > 5) _fail('method $id needs 1 to 5 noises');
      for (final n in list) {
        if (n is! Map<String, dynamic>) _fail('a noise of $id is not valid');
        final packet = n['packet'];
        final del = n['delay_ms'];
        String range(Object? v) => v is List && v.length == 2 ? '${v[0]}-${v[1]}' : '$v';
        final c = checkedNoise('${n['type']}', n['type'] == 'rand' ? range(packet) : '$packet', range(del));
        if (c == null) _fail('a noise of $id is outside the limits');
        noise.add(c);
      }
    }
    methods.add(WarpMethod(
      id: id,
      kind: kind,
      rank: rank,
      platforms: platforms,
      requires: requires,
      minBuild: build('min_build'),
      maxBuild: build('max_build'),
      noise: noise,
    ));
  }

  return WarpProfile(
    version: version,
    issuedAt: issued,
    expiresAt: expires,
    keyId: keyId,
    message: message,
    disabled: disabled,
    fragmentSize: size,
    fragmentDelay: delay,
    apiIps: apiIps,
    endpoints: endpoints,
    methods: methods,
  );
}
