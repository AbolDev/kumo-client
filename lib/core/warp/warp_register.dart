import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'p256.dart';
import 'warp_profile.dart';
import 'x25519.dart';

// The sign-up service of Cloudflare WARP. Where the filter looks at the name of the service in the
// first packet of the connection, that packet is cut into small pieces (see [FragmentRelay]) so that
// the name is not in one piece. The name, the path and the version are fixed here: a profile can
// only choose among Cloudflare's addresses, never another service.
const _apiHost = 'api.cloudflareclient.com';
const _apiPath = '/v0a2158/reg';
const _clientVersion = 'a-6.3-2596';

// The version of the service that takes a MASQUE key (a newer one than the WireGuard sign-up above).
const _masquePath = '/v0a4471/reg';
const _masqueClientVersion = 'a-6.35-4471';

class WarpRegisterException implements Exception {
  WarpRegisterException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The service refused the WARP+ license key (it is not one, or it is used up). Not tried again on another way.
class WarpLicenseException extends WarpRegisterException {
  WarpLicenseException(super.message);
}

/// The public key of Cloudflare's WireGuard peer, the same for every WARP account.
const warpPeerPublicKey = 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=';

/// A WARP+ license key (three groups of eight letters and digits) as the service takes it, or null when [text] is not one.
String? warpLicenseOf(String text) {
  final key = text.trim();
  return RegExp(r'^[A-Za-z0-9]{8}-[A-Za-z0-9]{8}-[A-Za-z0-9]{8}$').hasMatch(key) ? key : null;
}

/// A WireGuard key as standard padded base64 of its 32 bytes (the URL-safe alphabet, no padding, and a `+` that came
/// as a space are accepted); null when [text] is not a key.
String? warpKeyOf(String text) {
  String? attempt(String s) {
    var t = s.replaceAll(' ', '+').replaceAll('-', '+').replaceAll('_', '/').replaceAll('=', '');
    if (t.isEmpty || !RegExp(r'^[A-Za-z0-9+/]+$').hasMatch(t)) return null;
    while (t.length % 4 != 0) {
      t += '=';
    }
    try {
      final bytes = base64.decode(t);
      return bytes.length == 32 ? base64.encode(bytes) : null;
    } catch (_) {
      return null;
    }
  }

  // A space at the start may be a plus; when that is not a key, the spaces around the text were only spaces.
  return attempt(text.replaceAll(RegExp(r'[\r\n\t]'), '')) ?? attempt(text.trim());
}

/// An account taken from what the user gave ([problem] is the text key of what is wrong when there is no account).
typedef WarpImport = ({WarpAccount? account, String? problem});

/// An account from keys the user has: a WireGuard profile (what `wgcf` writes: `PrivateKey`, `Address`, `PublicKey`, and
/// `Reserved` when the tool adds it) or JSON (`private_key`, `v4`, `v6`, `peer_public_key`, `reserved` or `client_id`).
/// [reserved] is the three bytes of the account (`1,2,3`) or its `client_id` (base64); it overrides what [text] says.
WarpImport parseWarpAccount(String text, {String reserved = ''}) {
  const bad = (account: null, problem: 'warpImportEmpty');
  final input = text.trim();
  if (input.isEmpty) return bad;
  String? priv, peer, reservedText;
  final addresses = <String>[];
  void take(String key, Object? value) {
    if (value == null) return;
    final k = key.toLowerCase().replaceAll('_', '');
    final v = value is List ? value.join(',') : '$value';
    switch (k) {
      case 'privatekey' || 'priv':
        priv = v;
      case 'publickey' || 'peerpublickey' || 'pub':
        peer = v;
      case 'address' || 'addresses':
        addresses.addAll(v.split(RegExp(r'[,\s]+')));
      case 'v4' || 'v6':
        addresses.add(v);
      case 'reserved' || 'clientid':
        reservedText = v;
    }
  }

  if (input.startsWith('{')) {
    try {
      final j = jsonDecode(input);
      if (j is! Map) return bad;
      j.forEach((k, v) => take('$k', v));
    } catch (_) {
      return bad;
    }
  } else {
    for (final line in input.split(RegExp(r'[\r\n]+'))) {
      final at = line.indexOf('=');
      if (at > 0) take(line.substring(0, at).trim(), line.substring(at + 1).trim());
    }
  }
  final privateKey = priv == null ? null : warpKeyOf(priv!);
  if (privateKey == null) return (account: null, problem: 'warpImportKey');
  final peerKey = peer == null || peer!.trim().isEmpty ? warpPeerPublicKey : warpKeyOf(peer!);
  if (peerKey == null) return (account: null, problem: 'warpImportPeer');
  String? v4, v6;
  for (final a in addresses) {
    final ip = a.split('/').first.trim();
    if (ip.isEmpty) continue;
    if (ip.contains(':')) {
      v6 ??= ip;
    } else {
      v4 ??= ip;
    }
  }
  if (v4 == null || v6 == null || !RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(v4) || !RegExp(r'^[0-9A-Fa-f:]+$').hasMatch(v6)) {
    return (account: null, problem: 'warpImportAddr');
  }
  final bytes = parseWarpReserved(reserved.trim().isNotEmpty ? reserved : (reservedText ?? ''));
  if (bytes == null) return (account: null, problem: 'warpImportReserved');
  return (
    account: WarpAccount(privateKey: privateKey, v4: v4, v6: v6, peerPublicKey: peerKey, reserved: bytes),
    problem: null,
  );
}

/// The three reserved bytes from `1,2,3` (or with spaces) or from the base64 `client_id` of the account; empty is
/// `0,0,0`; null when it is neither.
List<int>? parseWarpReserved(String text) {
  final t = text.trim().replaceAll(RegExp(r'^\[|\]$'), '').trim();
  if (t.isEmpty) return const [0, 0, 0];
  if (RegExp(r'^\d+([,\s]+\d+){2}$').hasMatch(t)) {
    final bytes = t.split(RegExp(r'[,\s]+')).map(int.parse).toList();
    return bytes.every((b) => b <= 255) ? bytes : null;
  }
  if (t.length == 4 && RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(t)) {
    try {
      final bytes = base64.decode(t);
      if (bytes.length == 3) return bytes;
    } catch (_) {}
  }
  return null;
}

/// What a WireGuard client needs to use the WARP account made for this device.
class WarpAccount {
  const WarpAccount({
    required this.privateKey,
    required this.v4,
    required this.v6,
    required this.peerPublicKey,
    required this.reserved,
  });

  final String privateKey;
  final String v4;
  final String v6;
  final String peerPublicKey;

  /// The three bytes Cloudflare puts in the header of the packets of this account.
  final List<int> reserved;

  Map<String, dynamic> toJson() => {
        'private_key': privateKey,
        'v4': v4,
        'v6': v6,
        'peer_public_key': peerPublicKey,
        'reserved': reserved,
      };

  static WarpAccount? fromJson(Object? j) {
    if (j is! Map) return null;
    final r = j['reserved'];
    final priv = j['private_key'], v4 = j['v4'], v6 = j['v6'], pub = j['peer_public_key'];
    if (priv is! String || v4 is! String || v6 is! String || pub is! String || r is! List) return null;
    if (r.length != 3 || r.any((e) => e is! int || e < 0 || e > 255)) return null;
    return WarpAccount(
        privateKey: priv, v4: v4, v6: v6, peerPublicKey: pub, reserved: r.cast<int>().toList());
  }
}

/// The Cloudflare edge address MASQUE connects to when the account's answer names none we can use.
const masqueDefaultEndpoint = '162.159.198.2';

/// What a MASQUE client needs to use the WARP account made for this device: a P-256 key (not the
/// Curve25519 one of WireGuard), the key of the edge (the server's certificate is checked against it)
/// and the addresses of the tunnel, which the edge does not hand out by itself.
class WarpMasqueAccount {
  const WarpMasqueAccount({
    required this.privateKey,
    required this.edgeKey,
    required this.v4,
    required this.v6,
    this.endpoint = masqueDefaultEndpoint,
  });

  /// Base64 of the DER of the private key (SEC1), as Xray takes it.
  final String privateKey;

  /// Base64 of the DER of the edge's public key (SubjectPublicKeyInfo).
  final String edgeKey;
  final String v4;
  final String v6;

  /// The address of the edge the account is meant for.
  final String endpoint;

  Map<String, dynamic> toJson() =>
      {'private_key': privateKey, 'edge_key': edgeKey, 'v4': v4, 'v6': v6, 'endpoint': endpoint};

  static WarpMasqueAccount? fromJson(Object? j) {
    if (j is! Map) return null;
    final priv = j['private_key'], edge = j['edge_key'], v4 = j['v4'], v6 = j['v6'];
    if (priv is! String || edge is! String || v4 is! String || v6 is! String) return null;
    if (priv.isEmpty || edge.isEmpty) return null;
    final ep = j['endpoint'];
    return WarpMasqueAccount(
        privateKey: priv,
        edgeKey: edge,
        v4: v4,
        v6: v6,
        endpoint: ep is String && ep.isNotEmpty ? ep : masqueDefaultEndpoint);
  }
}

/// A local TCP relay to [target]:[port] that sends the first bytes the client writes (the TLS hello)
/// in small pieces, [size] bytes each with [delay] ms between them (both a [min, max] range). The
/// rest goes through as it is.
class FragmentRelay {
  FragmentRelay._(this._server);

  final ServerSocket _server;

  int get port => _server.port;

  static Future<FragmentRelay> start(String target,
      {int port = 443, required (int, int) size, required (int, int) delay, Random? random}) async {
    final rng = random ?? Random();
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    int between((int, int) r) => r.$1 + (r.$2 > r.$1 ? rng.nextInt(r.$2 - r.$1 + 1) : 0);
    server.listen((client) async {
      Socket up;
      try {
        up = await Socket.connect(target, port, timeout: const Duration(seconds: 8));
      } catch (_) {
        client.destroy();
        return;
      }
      up.setOption(SocketOption.tcpNoDelay, true);
      // A write to a socket the other side has dropped fails its `done` too; nobody waits for it, and an
      // error left there would be an uncaught one.
      unawaited(up.done.catchError((Object _) {}));
      unawaited(client.done.catchError((Object _) {}));
      var first = true;
      // The pieces go out one after the other even when the next chunk arrives in the meantime.
      var chain = Future<void>.value();
      client.listen((data) {
        chain = chain.then((_) async {
          if (!first) {
            up.add(data);
            return;
          }
          first = false;
          var i = 0;
          while (i < data.length) {
            final piece = max<int>(1, between(size));
            final end = min<int>(i + piece, data.length);
            up.add(data.sublist(i, end));
            await up.flush();
            i = end;
            if (i < data.length) await Future<void>.delayed(Duration(milliseconds: between(delay)));
          }
        }).catchError((Object _) {
          up.destroy();
        });
      }, onDone: () => up.destroy(), onError: (_) => up.destroy(), cancelOnError: true);
      up.listen(client.add,
          onDone: () => client.destroy(), onError: (_) => client.destroy(), cancelOnError: true);
    });
    return FragmentRelay._(server);
  }

  Future<void> close() async {
    await _server.close();
  }
}

/// The status and body of an HTTP/1.1 response once all of it is in [data]; null while it is not.
({int status, Uint8List body})? parseHttpResponse(Uint8List data) {
  final end = _indexOf(data, const [13, 10, 13, 10]);
  if (end < 0) return null;
  final head = latin1.decode(data.sublist(0, end)).split('\r\n');
  final status = int.tryParse(head.first.split(' ').elementAtOrNull(1) ?? '') ?? 0;
  final headers = {
    for (final l in head.skip(1))
      if (l.contains(':')) l.substring(0, l.indexOf(':')).trim().toLowerCase(): l.substring(l.indexOf(':') + 1).trim(),
  };
  final body = data.sublist(end + 4);
  if (headers['transfer-encoding']?.toLowerCase().contains('chunked') ?? false) {
    final out = BytesBuilder();
    var i = 0;
    while (true) {
      final eol = _indexOf(body, const [13, 10], i);
      if (eol < 0) return null;
      final size = int.tryParse(latin1.decode(body.sublist(i, eol)).split(';').first.trim(), radix: 16);
      if (size == null) return null;
      i = eol + 2;
      if (size == 0) return (status: status, body: out.toBytes());
      if (body.length < i + size + 2) return null;
      out.add(body.sublist(i, i + size));
      i += size + 2;
    }
  }
  final length = int.tryParse(headers['content-length'] ?? '');
  if (length != null) {
    return body.length >= length ? (status: status, body: body.sublist(0, length)) : null;
  }
  return null;
}

int _indexOf(Uint8List data, List<int> pattern, [int from = 0]) {
  for (var i = from; i + pattern.length <= data.length; i++) {
    var ok = true;
    for (var j = 0; j < pattern.length; j++) {
      if (data[i + j] != pattern[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}

Future<Map<String, dynamic>> _call(int relayPort, String method, String path, Map<String, dynamic> body,
    {String? token, String clientVersion = _clientVersion}) async {
  final plain = await Socket.connect(InternetAddress.loopbackIPv4, relayPort);
  SecureSocket? tls;
  try {
    tls = await SecureSocket.secure(plain, host: _apiHost).timeout(const Duration(seconds: 8));
    final payload = utf8.encode(jsonEncode(body));
    tls.add([
      ...utf8.encode('$method $path HTTP/1.1\r\nHost: $_apiHost\r\n'
          'Content-Type: application/json\r\nCF-Client-Version: $clientVersion\r\n'
          '${token == null ? '' : 'Authorization: Bearer $token\r\n'}'
          'Connection: close\r\nContent-Length: ${payload.length}\r\n\r\n'),
      ...payload,
    ]);
    final buffer = BytesBuilder();
    ({int status, Uint8List body})? response;
    await for (final chunk in tls.timeout(const Duration(seconds: 10))) {
      buffer.add(chunk);
      response = parseHttpResponse(buffer.toBytes());
      if (response != null) break;
    }
    response ??= parseHttpResponse(buffer.toBytes());
    if (response == null) throw WarpRegisterException('no answer from the sign-up service');
    Object? json;
    try {
      json = jsonDecode(utf8.decode(response.body));
    } catch (_) {
      throw WarpRegisterException('the sign-up service answered ${response.status}');
    }
    if (response.status != 200 || json is! Map<String, dynamic>) {
      final errors = json is Map ? json['errors'] : null;
      final first = errors is List && errors.isNotEmpty && errors.first is Map
          ? (errors.first as Map)['message']
          : null;
      throw WarpRegisterException('the sign-up service answered ${response.status}'
          '${first == null ? '' : ': $first'}');
    }
    return json;
  } finally {
    tls?.destroy();
    plain.destroy();
  }
}

/// [_call], tried again on a new connection (with new random pieces) when the connection itself failed: the
/// filter lets a cut hello through with a chance, not always, and an account takes two or three calls. An answer
/// of the service, an error too, is not tried again.
Future<Map<String, dynamic>> _callRetry(int relayPort, String method, String path, Map<String, dynamic> body,
    {String? token, String clientVersion = _clientVersion, int tries = 4}) async {
  Object? last;
  for (var i = 0; i < tries; i++) {
    try {
      return await _call(relayPort, method, path, body, token: token, clientVersion: clientVersion);
    } on WarpRegisterException catch (e) {
      if (!e.message.startsWith('no answer')) rethrow;
      last = e;
    } on Exception catch (e) {
      // A timeout, a reset, a handshake that did not finish.
      last = e;
    }
  }
  throw last is WarpRegisterException ? last : WarpRegisterException('$last');
}

/// One way to reach the sign-up service: the address and how the hello is cut.
typedef SignUpTry = (String ip, (int, int) size, (int, int) delay);

/// How the hello is cut (the size of a piece, the pause after it, each a [min, max] range in bytes and ms).
typedef SignUpCut = ((int, int) size, (int, int) delay);

/// The cuts that pass a filter which blocks the name of the service in one piece, best first. Measured on an
/// Iranian network (Nov 2026), where the connection to the service stalls unless the hello is cut: pieces of
/// 40 to 80 bytes passed 36 times of 36 (a fixed 60 or 70 bytes 12 of 12), 20 to 60 about one in three, 50 to
/// 100 one in four, 5 to 40 (the profile's) never, and pieces of 80 bytes or more (the whole name in one piece)
/// or of 30 bytes or fewer (too many pieces) never. The pause between pieces hardly matters.
const knownCuts = <SignUpCut>[
  ((40, 80), (5, 10)),
  ((35, 70), (10, 15)),
  ((60, 70), (10, 10)),
  ((20, 60), (30, 30)),
];

/// The ways the sign-up service is tried: the cuts that are known to pass, the cut of the profile (it may have
/// been made for another network) and a wider one, each through every address; two rounds, the second a second
/// go with other random sizes.
List<SignUpTry> signUpTries(WarpProfile profile) {
  final cuts = <SignUpCut>[
    ...knownCuts,
    (profile.fragmentSize, profile.fragmentDelay),
    ((50, 100), (30, 30)),
  ];
  final seen = <SignUpCut>{};
  final unique = [
    for (final c in cuts)
      if (seen.add(c)) c,
  ];
  return [
    for (var round = 0; round < 2; round++)
      for (final cut in unique)
        for (final ip in profile.apiIps) (ip, cut.$1, cut.$2),
  ];
}

/// The tries of [signUpTries] in waves: the ways of one wave are raced, the next wave is a second go (the
/// pieces are cut at random sizes, and a filter does not always lose the name in the same way).
List<List<SignUpTry>> signUpWaves(WarpProfile profile) {
  final all = signUpTries(profile);
  final half = all.length ~/ 2;
  return half == 0 ? [all] : [all.sublist(0, half), all.sublist(half)];
}

/// How long the TLS handshake of one way of reaching the sign-up service may take.
const _handshakeTimeout = Duration(seconds: 8);

/// Finds a way through to the sign-up service among [wave]: the TLS handshake of every way is started at the
/// same time, and the first that completes wins (a filter that blocks the service cuts the handshake, so a
/// completed one means the way works). Returns the relay of that way, still open, or null when none got
/// through. [onTried] is told how many ways have failed so far.
Future<FragmentRelay?> _race(List<SignUpTry> wave, Random? random, void Function(int failed)? onTried) {
  final won = Completer<FragmentRelay?>();
  var failed = 0;
  for (final (ip, size, delay) in wave) {
    () async {
      FragmentRelay? relay;
      SecureSocket? tls;
      try {
        relay = await FragmentRelay.start(ip, size: size, delay: delay, random: random);
        final plain = await Socket.connect(InternetAddress.loopbackIPv4, relay.port);
        tls = await SecureSocket.secure(plain, host: _apiHost).timeout(_handshakeTimeout, onTimeout: () {
          plain.destroy();
          throw TimeoutException('handshake');
        });
        tls.destroy();
        if (won.isCompleted) {
          await relay.close();
        } else {
          won.complete(relay);
        }
      } catch (_) {
        tls?.destroy();
        await relay?.close();
        failed++;
        onTried?.call(failed);
        if (failed == wave.length && !won.isCompleted) won.complete(null);
      }
    }();
  }
  return won.future;
}

/// Runs [body] through the first way of [profile] that reaches the sign-up service: wave after wave, the ways
/// of a wave raced (see [_race]). [onProgress] goes from 0 to 0.7 while a way is looked for.
Future<T> _throughService<T>(WarpProfile profile, Random? random, void Function(double)? onProgress,
    Future<T> Function(int relayPort) body) async {
  Object? last;
  final waves = signUpWaves(profile);
  for (var w = 0; w < waves.length; w++) {
    final wave = waves[w];
    onProgress?.call(0.7 * w / waves.length);
    final relay = await _race(
        wave, random, (failed) => onProgress?.call(0.7 * (w + failed / wave.length) / waves.length));
    if (relay == null) {
      last = WarpRegisterException('the sign-up service could not be reached');
      continue;
    }
    onProgress?.call(0.7);
    try {
      return await body(relay.port);
    } on WarpLicenseException {
      // The service answered: another way to it would be refused the same.
      rethrow;
    } catch (e) {
      last = e;
    } finally {
      await relay.close();
    }
  }
  throw WarpRegisterException('$last');
}

typedef _Send = Future<Map<String, dynamic>> Function(String method, String path, Map<String, dynamic> body,
    {String? token});

/// Binds the account [id] to the WARP+ [license] (what `wgcf update` does). An answer of the service that refuses it
/// (a 4xx) is a [WarpLicenseException].
Future<void> _bindLicense(_Send send, String basePath, String id, String token, String license) async {
  try {
    await send('PUT', '$basePath/$id/account', {'license': license}, token: token);
  } on WarpRegisterException catch (e) {
    if (e.message.startsWith('the sign-up service answered 4')) throw WarpLicenseException(e.message);
    rethrow;
  }
}

/// Makes a WARP account for this device, reaching the service through the addresses and the piece
/// sizes of [profile]; throws [WarpRegisterException] when none answers. [onProgress] runs from 0 to 1. With a WARP+
/// [license] (see [warpLicenseOf]) the account is bound to it; a key the service refuses is a [WarpLicenseException].
Future<WarpAccount> registerWarp(WarpProfile profile,
    {Random? random, void Function(double)? onProgress, String? license}) async {
  final (priv, pub) = newWireGuardKeys(random);
  final account = await _throughService(profile, random, onProgress, (port) async {
    final reg = await _callRetry(port, 'POST', _apiPath, {
      'key': pub,
      'install_id': '',
      'fcm_token': '',
      'tos': DateTime.now().toUtc().toIso8601String(),
      'model': 'PC',
      'serial_number': '',
      'locale': 'en_US',
    });
    onProgress?.call(0.85);
    final id = reg['id'], token = reg['token'];
    if (id is! String || token is! String || !RegExp(r'^[A-Za-z0-9-]{8,64}$').hasMatch(id)) {
      throw WarpRegisterException('the answer has no account');
    }
    if (license != null) await _bindLicense((m, p, b, {String? token}) => _callRetry(port, m, p, b, token: token), _apiPath, id, token, license);
    final on = await _callRetry(port, 'PATCH', '$_apiPath/$id', {'warp_enabled': true}, token: token);
    final account = _account(priv, (on['config'] ?? reg['config']));
    if (account == null) throw WarpRegisterException('the answer is incomplete');
    return account;
  });
  onProgress?.call(1);
  return account;
}

/// Makes a WARP account that uses MASQUE for this device: a device is signed up with a throw-away
/// WireGuard key (the service wants one), then its key is replaced by a P-256 one with the tunnel type
/// `masque`. It is a different account from the WireGuard one: once a device takes a MASQUE key it no
/// longer speaks WireGuard. [call] is for tests.
Future<WarpMasqueAccount> registerWarpMasque(WarpProfile profile,
    {Random? random,
    void Function(double)? onProgress,
    String? license,
    Future<Map<String, dynamic>> Function(String method, String path, Map<String, dynamic> body, {String? token})?
        call}) async {
  final (_, wgPub) = newWireGuardKeys(random);
  final keys = newP256Keys(random);
  Future<WarpMasqueAccount> run(
      Future<Map<String, dynamic>> Function(String method, String path, Map<String, dynamic> body, {String? token})
          send) async {
    final reg = await send('POST', _masquePath, {
      'key': wgPub,
      'install_id': '',
      'fcm_token': '',
      'tos': DateTime.now().toUtc().toIso8601String(),
      'model': 'PC',
      'serial_number': '',
      'os_version': '',
      'key_type': 'curve25519',
      'tunnel_type': 'wireguard',
      'locale': 'en_US',
    });
    onProgress?.call(0.8);
    final id = reg['id'], token = reg['token'];
    if (id is! String || token is! String || !RegExp(r'^[A-Za-z0-9-]{8,64}$').hasMatch(id)) {
      throw WarpRegisterException('the answer has no account');
    }
    final enrolled = await send('PATCH', '$_masquePath/$id', {
      'key': keys.publicBase64,
      'key_type': 'secp256r1',
      'tunnel_type': 'masque',
    }, token: token);
    onProgress?.call(0.9);
    if (license != null) await _bindLicense(send, _masquePath, id, token, license);
    // The account is switched on as the WireGuard one is; an answer that refuses it does not stop the
    // sign-up (the service may not ask for it any more).
    try {
      await send('PATCH', '$_masquePath/$id', {'warp_enabled': true}, token: token);
    } catch (_) {}
    final account = masqueAccountFrom(keys.privateBase64, enrolled['config'] ?? reg['config']);
    if (account == null) throw WarpRegisterException('the answer is incomplete');
    return account;
  }

  if (call != null) return run(call);
  final account = await _throughService(
      profile,
      random,
      onProgress,
      (port) => run((method, path, body, {String? token}) =>
          _callRetry(port, method, path, body, token: token, clientVersion: _masqueClientVersion)));
  onProgress?.call(1);
  return account;
}

/// The account from the `config` of the service's answer, or null when something is missing. The edge key
/// comes as a PEM text or in base64.
WarpMasqueAccount? masqueAccountFrom(String privateKey, Object? config) {
  if (config is! Map) return null;
  final peers = config['peers'];
  final addresses = config['interface'] is Map ? (config['interface'] as Map)['addresses'] : null;
  if (peers is! List || peers.isEmpty || peers.first is! Map || addresses is! Map) return null;
  final peer = peers.first as Map;
  final edge = peer['public_key'] is String ? edgeKeyBase64(peer['public_key'] as String) : null;
  final v4 = addresses['v4'], v6 = addresses['v6'];
  if (edge == null || v4 is! String || v6 is! String || v4.isEmpty || v6.isEmpty) return null;
  var endpoint = masqueDefaultEndpoint;
  final ep = peer['endpoint'];
  if (ep is Map && ep['v4'] is String) {
    final host = (ep['v4'] as String).split(':').first;
    if (isCloudflareV4(host)) endpoint = host;
  }
  return WarpMasqueAccount(privateKey: privateKey, edgeKey: edge, v4: v4, v6: v6, endpoint: endpoint);
}

WarpAccount? _account(String privateKey, Object? config) {
  if (config is! Map) return null;
  final peers = config['peers'];
  final addresses = config['interface'] is Map ? (config['interface'] as Map)['addresses'] : null;
  if (peers is! List || peers.isEmpty || peers.first is! Map || addresses is! Map) return null;
  final pub = (peers.first as Map)['public_key'];
  final v4 = addresses['v4'], v6 = addresses['v6'], client = config['client_id'];
  if (pub is! String || v4 is! String || v6 is! String) return null;
  var reserved = const <int>[0, 0, 0];
  if (client is String) {
    try {
      final bytes = base64.decode(client);
      if (bytes.length == 3) reserved = bytes;
    } catch (_) {}
  }
  return WarpAccount(privateKey: privateKey, v4: v4, v6: v6, peerPublicKey: pub, reserved: reserved);
}
