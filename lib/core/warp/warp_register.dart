import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'warp_profile.dart';
import 'x25519.dart';

// The sign-up service of Cloudflare WARP. Where the filter looks at the name of the service in the
// first packet of the connection, that packet is cut into small pieces (see [FragmentRelay]) so that
// the name is not in one piece. The name, the path and the version are fixed here: a profile can
// only choose among Cloudflare's addresses, never another service.
const _apiHost = 'api.cloudflareclient.com';
const _apiPath = '/v0a2158/reg';
const _clientVersion = 'a-6.3-2596';

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
    {String? token}) async {
  final plain = await Socket.connect(InternetAddress.loopbackIPv4, relayPort);
  SecureSocket? tls;
  try {
    tls = await SecureSocket.secure(plain, host: _apiHost).timeout(const Duration(seconds: 8));
    final payload = utf8.encode(jsonEncode(body));
    tls.add([
      ...utf8.encode('$method $path HTTP/1.1\r\nHost: $_apiHost\r\n'
          'Content-Type: application/json\r\nCF-Client-Version: $_clientVersion\r\n'
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

/// Makes a WARP account for this device, reaching the service through the addresses and the piece
/// sizes of [profile]. Tries its addresses in turn; throws [WarpRegisterException] when none answers.
Future<WarpAccount> registerWarp(WarpProfile profile, {Random? random}) async {
  final (priv, pub) = newWireGuardKeys(random);
  Object? last;
  // The pieces are cut at random sizes, and a filter does not always lose the name in the same way:
  // a second go with other sizes often passes where the first did not.
  for (final ip in [for (var round = 0; round < 3; round++) ...profile.apiIps]) {
    final relay = await FragmentRelay.start(ip,
        size: profile.fragmentSize, delay: profile.fragmentDelay, random: random);
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
