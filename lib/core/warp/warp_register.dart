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
    await for (final chunk in tls.timeout(const Duration(seconds: 15))) {
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

/// One way to reach the sign-up service: the address and how the hello is cut.
typedef SignUpTry = (String ip, (int, int) size, (int, int) delay);

/// The ways the sign-up service is tried, in order: two rounds, each cutting the hello as the profile
/// says and then in bigger pieces. A filter that drops a connection whose hello comes in many tiny
/// pieces lets pieces of 20 to 100 bytes through (the name is still cut), so those follow the profile's.
List<SignUpTry> signUpTries(WarpProfile profile) => [
      for (var round = 0; round < 2; round++)
        for (final cut in [
          (profile.fragmentSize, profile.fragmentDelay),
          ((20, 60), (5, 5)),
          ((50, 100), (10, 10)),
        ])
          for (final ip in profile.apiIps) (ip, cut.$1, cut.$2),
    ];

/// Makes a WARP account for this device, reaching the service through the addresses and the piece
/// sizes of [profile]. Tries its addresses in turn; throws [WarpRegisterException] when none answers.
Future<WarpAccount> registerWarp(WarpProfile profile, {Random? random}) async {
  final (priv, pub) = newWireGuardKeys(random);
  Object? last;
  // The pieces are cut at random sizes, and a filter does not always lose the name in the same way:
  // a second go with other sizes often passes where the first did not.
  for (final (ip, size, delay) in signUpTries(profile)) {
    final relay = await FragmentRelay.start(ip, size: size, delay: delay, random: random);
    try {
      final reg = await _call(relay.port, 'POST', _apiPath, {
        'key': pub,
        'install_id': '',
        'fcm_token': '',
        'tos': DateTime.now().toUtc().toIso8601String(),
        'model': 'PC',
        'serial_number': '',
        'locale': 'en_US',
      });
      final id = reg['id'], token = reg['token'];
      if (id is! String || token is! String || !RegExp(r'^[A-Za-z0-9-]{8,64}$').hasMatch(id)) {
        throw WarpRegisterException('the answer has no account');
      }
      final on = await _call(relay.port, 'PATCH', '$_apiPath/$id', {'warp_enabled': true}, token: token);
      final account = _account(priv, (on['config'] ?? reg['config']));
      if (account == null) throw WarpRegisterException('the answer is incomplete');
      return account;
    } catch (e) {
      last = e;
    } finally {
      await relay.close();
    }
  }
  throw WarpRegisterException('$last');
}

/// Makes a WARP account that uses MASQUE for this device: a device is signed up with a throw-away
/// WireGuard key (the service wants one), then its key is replaced by a P-256 one with the tunnel type
/// `masque`. It is a different account from the WireGuard one: once a device takes a MASQUE key it no
/// longer speaks WireGuard. [call] is for tests.
Future<WarpMasqueAccount> registerWarpMasque(WarpProfile profile,
    {Random? random,
    Future<Map<String, dynamic>> Function(String method, String path, Map<String, dynamic> body, {String? token})?
        call}) async {
  final (_, wgPub) = newWireGuardKeys(random);
  final keys = newP256Keys(random);
  Object? last;
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
    final id = reg['id'], token = reg['token'];
    if (id is! String || token is! String || !RegExp(r'^[A-Za-z0-9-]{8,64}$').hasMatch(id)) {
      throw WarpRegisterException('the answer has no account');
    }
    final enrolled = await send('PATCH', '$_masquePath/$id', {
      'key': keys.publicBase64,
      'key_type': 'secp256r1',
      'tunnel_type': 'masque',
    }, token: token);
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
  for (final (ip, size, delay) in signUpTries(profile)) {
    final relay = await FragmentRelay.start(ip, size: size, delay: delay, random: random);
    try {
      return await run((method, path, body, {String? token}) =>
          _call(relay.port, method, path, body, token: token, clientVersion: _masqueClientVersion));
    } catch (e) {
      last = e;
    } finally {
      await relay.close();
    }
  }
  throw WarpRegisterException('$last');
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
