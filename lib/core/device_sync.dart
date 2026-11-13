import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:pointycastle/export.dart';

/// Moving servers and settings from one of the user's devices to another, over the local network, with no account
/// and no server of anybody's in between.
///
/// The device that shows a code (a QR code, or the same text) listens for one request on its address in the local
/// network, for five minutes at most. The code holds a key made for this one time, and the data is sealed with it
/// (AES-256-GCM): the key never goes through the network, only the screen of the one device and the camera of
/// the other. Whoever is on the network too sees nothing but sealed bytes, and cannot change them without it
/// being noticed. The code is for one use: when the data has gone through, or after a few wrong requests, or
/// when the time is up, the listening ends.
///
/// Which way the data goes is the choice of the device that shows the code ([SyncMode]): it either hands its data
/// to the one that scanned the code, or takes the data of the one that scanned it.

/// What the device that shows the code does.
enum SyncMode {
  /// It gives its data to whoever scans the code (`GET`).
  send,

  /// It takes the data of whoever scans the code (`POST`).
  receive,
}

/// The longest data accepted, so that nothing on the network can make the app hold more.
const syncMaxBytes = 8 * 1024 * 1024;

/// How long a code lives.
const syncLifetime = Duration(minutes: 5);

/// An address of a private network (or the link-local range): what a device at home or in an office has. A code
/// that names anything else is refused, so that a code made by somebody else cannot send the data out of the
/// local network.
bool isPrivateIpv4(String address) {
  final p = address.split('.');
  if (p.length != 4) return false;
  final n = [for (final s in p) int.tryParse(s)];
  if (n.any((v) => v == null || v < 0 || v > 255)) return false;
  final a = n[0]!, b = n[1]!;
  return a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) || (a == 169 && b == 254);
}

String _b64u(Uint8List bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List? _fromB64u(String text) {
  try {
    return Uint8List.fromList(base64Url.decode(base64Url.normalize(text)));
  } catch (_) {
    return null;
  }
}

Uint8List _randomBytes(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

/// Compares in a time that does not depend on where the texts differ.
bool _same(String a, String b) {
  var diff = a.length ^ b.length;
  final n = min(a.length, b.length);
  for (var i = 0; i < n; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

/// What a code says: which way the data goes, where to ask, and the key.
class SyncCode {
  SyncCode({required this.mode, required this.host, required this.port, required this.id, required this.key});

  final SyncMode mode;
  final String host;
  final int port;

  /// The name of the one page that answers (16 random bytes), so that nobody can guess the address.
  final String id;

  /// The key of this time (32 random bytes).
  final Uint8List key;

  /// What is shown as the QR code, and can be typed or pasted where there is no camera.
  String get text => 'kumo-sync:1:${mode == SyncMode.send ? 's' : 'r'}:$host:$port:$id:${_b64u(key)}';

  /// The text sealed data is tied to: the way it goes and this one code.
  String get aad => 'kumo-sync-1|${mode == SyncMode.send ? 's' : 'r'}|$id';

  /// The code of [text], or null when it is not one, or names an address outside the local network (a loopback
  /// address is taken only where [allowLoopback] says so: for the tests).
  static SyncCode? parse(String text, {bool allowLoopback = false}) {
    final p = text.trim().split(':');
    if (p.length != 7 || p[0] != 'kumo-sync' || p[1] != '1') return null;
    final mode = switch (p[2]) {
      's' => SyncMode.send,
      'r' => SyncMode.receive,
      _ => null,
    };
    if (mode == null) return null;
    final host = p[3];
    if (!isPrivateIpv4(host) && !(allowLoopback && host == '127.0.0.1')) return null;
    final port = int.tryParse(p[4]);
    if (port == null || port < 1 || port > 65535) return null;
    final id = _fromB64u(p[5]);
    final key = _fromB64u(p[6]);
    if (id == null || id.length != 16 || key == null || key.length != 32) return null;
    return SyncCode(mode: mode, host: host, port: port, id: p[5], key: key);
  }
}

Uint8List _gcm(bool encrypt, Uint8List key, Uint8List nonce, Uint8List data, Uint8List aad) {
  final cipher = GCMBlockCipher(AESEngine())..init(encrypt, AEADParameters(KeyParameter(key), 128, nonce, aad));
  return cipher.process(data);
}

/// [text] sealed with [key], tied to [aad]: `{"v":1,"n":nonce,"c":sealed}` as the text sent over the network.
String sealSync(Uint8List key, String aad, String text) {
  final nonce = _randomBytes(12);
  final sealed = _gcm(true, key, nonce, Uint8List.fromList(utf8.encode(text)), Uint8List.fromList(utf8.encode(aad)));
  return jsonEncode({'v': 1, 'n': _b64u(nonce), 'c': base64.encode(sealed)});
}

/// What [sealSync] sealed, or null when it is not that, was changed on its way, or is meant for another code.
String? openSync(Uint8List key, String aad, String body) {
  try {
    final j = jsonDecode(body);
    if (j is! Map || j['v'] != 1) return null;
    final nonce = _fromB64u('${j['n']}');
    if (nonce == null || nonce.length != 12) return null;
    final sealed = base64.decode('${j['c']}');
    return utf8.decode(_gcm(false, key, nonce, Uint8List.fromList(sealed), Uint8List.fromList(utf8.encode(aad))));
  } catch (_) {
    return null;
  }
}

/// This device's address in the local network (home, office, a hotspot): the first of a private network on the
/// interfaces that are not a VPN, a virtual machine or a container. Null when there is none.
Future<String?> lanAddress() async {
  try {
    final skip = RegExp(r'^(lo|tun|tap|wg|utun|ppp|br-)|vpn|docker|veth|vethernet|vmnet|vbox|virbr', caseSensitive: false);
    final found = <(String, String)>[];
    for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      if (skip.hasMatch(i.name)) continue;
      for (final a in i.addresses) {
        if (isPrivateIpv4(a.address)) found.add((i.name, a.address));
      }
    }
    if (found.isEmpty) return null;
    // Wi-Fi and wired before the rest.
    final first = found.where((f) => RegExp(r'wlan|wlo|wi-?fi|^en|eth|^ap\d', caseSensitive: false).hasMatch(f.$1));
    return (first.isNotEmpty ? first.first : found.first).$2;
  } catch (_) {
    return null;
  }
}

enum SyncPhase { waiting, done, failed }

/// Listens for the one request of a code (see the top of this file).
class SyncServer {
  SyncServer({
    required this.mode,
    this.payload,
    this.onReceived,
    this.bind,
    this.ttl = syncLifetime,
    this.maxFailures = 5,
    this.allowLoopback = false,
  }) : assert(mode == SyncMode.receive || payload != null, 'a server that sends needs what to send');

  final SyncMode mode;

  /// What is given to whoever scans the code ([SyncMode.send]).
  final String? payload;

  /// Called with the text of what was taken ([SyncMode.receive]); only for data that opened with the key.
  final void Function(String text)? onReceived;

  /// The address to listen on (the address in the local network when null).
  final String? bind;
  final Duration ttl;

  /// The wrong requests after which the listening ends.
  final int maxFailures;
  final bool allowLoopback;

  final phase = ValueNotifier<SyncPhase>(SyncPhase.waiting);
  HttpServer? _server;
  Timer? _timer;
  SyncCode? _code;
  var _failures = 0;
  var _handled = false;

  SyncCode? get code => _code;

  /// Starts listening; the code to show, or null when this device is in no local network.
  Future<SyncCode?> start() async {
    final host = bind ?? await lanAddress();
    if (host == null) return null;
    final server = await HttpServer.bind(host, 0);
    _server = server;
    _code = SyncCode(mode: mode, host: host, port: server.port, id: _b64u(_randomBytes(16)), key: _randomBytes(32));
    _timer = Timer(ttl, () => _end(SyncPhase.failed));
    server.listen(_handle, onError: (Object _) {});
    return _code;
  }

  /// Ends the listening. After the data went through the connection that carried it is let finish ([force] false).
  Future<void> stop({bool force = true}) async {
    _timer?.cancel();
    final server = _server;
    _server = null;
    await server?.close(force: force);
  }

  void _end(SyncPhase result) {
    if (phase.value == SyncPhase.waiting) phase.value = result;
    unawaited(stop(force: result != SyncPhase.done));
  }

  Future<void> _refuse(HttpRequest req, int status) async {
    _failures++;
    try {
      req.response
        ..statusCode = status
        ..write('no');
      await req.response.close();
    } catch (_) {}
    if (_failures >= maxFailures) _end(SyncPhase.failed);
  }

  Future<void> _handle(HttpRequest req) async {
    final code = _code!;
    try {
      // Only from the local network.
      final remote = req.connectionInfo?.remoteAddress;
      final local = remote != null && (isPrivateIpv4(remote.address) || (allowLoopback && remote.isLoopback));
      if (!local) return _refuse(req, 403);
      final segments = req.uri.pathSegments;
      if (segments.length != 1 || !_same(segments.first, code.id)) return _refuse(req, 404);
      // One use: what comes after the data went through is not answered.
      if (_handled) return _refuse(req, 410);
      if (mode == SyncMode.send) {
        if (req.method != 'GET') return _refuse(req, 405);
        _handled = true;
        final body = sealSync(code.key, code.aad, payload!);
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(body);
        await req.response.close();
        _end(SyncPhase.done);
        return;
      }
      if (req.method != 'POST') return _refuse(req, 405);
      final bytes = <int>[];
      var tooBig = false;
      await for (final chunk in req) {
        bytes.addAll(chunk);
        if (bytes.length > syncMaxBytes) {
          tooBig = true;
          break;
        }
      }
      if (tooBig) return _refuse(req, 413);
      final text = openSync(code.key, code.aad, utf8.decode(bytes, allowMalformed: true));
      if (text == null) return _refuse(req, 400);
      _handled = true;
      req.response.statusCode = 200;
      req.response.write('ok');
      await req.response.close();
      onReceived?.call(text);
      _end(SyncPhase.done);
    } catch (_) {
      try {
        req.response.statusCode = 500;
        await req.response.close();
      } catch (_) {}
    }
  }
}

HttpClient _client(Duration timeout) {
  // Never through a proxy of the environment: the other device is in the same room.
  final c = HttpClient()..connectionTimeout = timeout;
  c.findProxy = (_) => 'DIRECT';
  return c;
}

/// Asks the device that shows [code] (made to send) for its data; the text, or null when it did not come, did not
/// open with the key, or the code is not one of a sender.
Future<String?> syncFetch(SyncCode code, {Duration timeout = const Duration(seconds: 15)}) async {
  if (code.mode != SyncMode.send) return null;
  final client = _client(timeout);
  try {
    final req = await client.getUrl(Uri(scheme: 'http', host: code.host, port: code.port, path: '/${code.id}')).timeout(timeout);
    final res = await req.close().timeout(timeout);
    if (res.statusCode != 200) return null;
    final bytes = <int>[];
    await for (final chunk in res.timeout(timeout)) {
      bytes.addAll(chunk);
      if (bytes.length > syncMaxBytes) return null;
    }
    return openSync(code.key, code.aad, utf8.decode(bytes, allowMalformed: true));
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// Gives [text] to the device that shows [code] (made to receive); true when it took it.
Future<bool> syncPush(SyncCode code, String text, {Duration timeout = const Duration(seconds: 15)}) async {
  if (code.mode != SyncMode.receive) return false;
  final client = _client(timeout);
  try {
    final req = await client.postUrl(Uri(scheme: 'http', host: code.host, port: code.port, path: '/${code.id}')).timeout(timeout);
    req.headers.contentType = ContentType.json;
    req.write(sealSync(code.key, code.aad, text));
    final res = await req.close().timeout(timeout);
    await res.drain<void>().timeout(timeout);
    return res.statusCode == 200;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}

// ------------------------------------------------------------------ what goes over

/// The settings that go with the servers, when the user wants them to: how the app looks and how it behaves.
/// Not the network options of the device (the ports, the tunnel), not the choice of icon or the disguise, and
/// above all not the erase by a dialled code: what is sent never changes what keeps the device private.
const syncSettingsKeys = [
  'theme',
  'language',
  'themeColor',
  'blackTheme',
  'showSpeed',
  'showVolume',
  'showName',
  'idleNotification',
  'haptics',
  'usageAlerts',
  'measurePing',
  'autoUpdateSubs',
  'updateOnStartup',
  'confirmDelete',
  'restartOnChange',
  'removeDeadChoice',
  'showCollector',
  'subInterval',
  'delayUrl',
];

/// The parts of a settings file that go over.
Map<String, dynamic> pickSyncSettings(Map<String, dynamic> settings) => {
      for (final k in syncSettingsKeys)
        if (settings.containsKey(k)) k: settings[k],
    };

/// The servers file of the user (the lists they made: manual servers, clean IPs and subscriptions) without what
/// is the app's own (the public list, pings, the choice).
Map<String, dynamic> pickSyncServers(Map<String, dynamic> servers) => {
      'manual': servers['manual'] ?? const [],
      'clean': servers['clean'] ?? const [],
      'subs': servers['subs'] ?? const [],
    };

/// The text that goes over: `{"v":1,"servers":{...},"settings":{...}}`.
String buildSyncPayload(Map<String, dynamic> servers, Map<String, dynamic>? settings) => jsonEncode({
      'v': 1,
      'servers': pickSyncServers(servers),
      if (settings != null) 'settings': pickSyncSettings(settings),
    });

/// What a payload holds, to show before anything is changed.
class SyncPreview {
  const SyncPreview({required this.servers, required this.cleanIps, required this.subscriptions, required this.hasSettings});

  final int servers;
  final int cleanIps;
  final List<String> subscriptions;
  final bool hasSettings;

  bool get isEmpty => servers == 0 && cleanIps == 0 && subscriptions.isEmpty && !hasSettings;
}

/// The payload of [text], or null when it is not one this app made.
Map<String, dynamic>? readSyncPayload(String text) {
  try {
    final j = jsonDecode(text);
    if (j is! Map || j['v'] != 1 || j['servers'] is! Map) return null;
    final settings = j['settings'];
    if (settings != null && settings is! Map) return null;
    return Map<String, dynamic>.from(j);
  } catch (_) {
    return null;
  }
}

SyncPreview? previewSyncPayload(String text) {
  final j = readSyncPayload(text);
  if (j == null) return null;
  final s = Map<String, dynamic>.from(j['servers'] as Map);
  int count(Object? v) => v is List ? v.length : 0;
  final subs = s['subs'];
  return SyncPreview(
    servers: count(s['manual']),
    cleanIps: count(s['clean']),
    subscriptions: [
      if (subs is List)
        for (final e in subs)
          if (e is Map) '${e['name'] ?? e['url'] ?? ''}',
    ],
    hasSettings: j['settings'] is Map && (j['settings'] as Map).isNotEmpty,
  );
}

/// [current] (the servers file) with what [incoming] holds added to it: servers and clean IPs that are not there
/// yet, and subscriptions whose address is not there yet. Nothing of the user's own is removed or changed.
({Map<String, dynamic> merged, int servers, int subscriptions}) mergeSyncServers(
    Map<String, dynamic> current, Map<String, dynamic> incoming) {
  final merged = Map<String, dynamic>.from(current);
  var added = 0;
  List<String> strings(Object? v) => v is List ? v.whereType<String>().toList() : <String>[];
  for (final key in ['manual', 'clean']) {
    final have = strings(current[key]);
    final extra = [
      for (final l in strings(incoming[key]))
        if (!have.contains(l)) l,
    ];
    merged[key] = [...have, ...extra];
    added += extra.length;
  }
  final subs = <dynamic>[...(current['subs'] is List ? current['subs'] as List : const [])];
  final urls = {for (final s in subs) if (s is Map && s['url'] is String) s['url'] as String};
  final ids = {for (final s in subs) if (s is Map) '${s['id']}'};
  var addedSubs = 0;
  for (final s in (incoming['subs'] is List ? incoming['subs'] as List : const [])) {
    if (s is! Map) continue;
    final url = s['url'];
    if (url is String && urls.contains(url)) continue;
    final copy = Map<String, dynamic>.from(s);
    // Another subscription of this device already has the name of the id: this one gets a new one.
    var id = '${copy['id']}';
    var n = 1;
    while (ids.contains(id)) {
      id = '${copy['id']}-${n++}';
    }
    copy['id'] = id;
    ids.add(id);
    if (url is String) urls.add(url);
    subs.add(copy);
    addedSubs++;
    added += strings(copy['links']).length;
  }
  merged['subs'] = subs;
  return (merged: merged, servers: added, subscriptions: addedSubs);
}

/// [current] with the user's lists replaced by those of [incoming]. The public list, the pings and the notes of
/// the safety check stay (they are the device's own); the choice of server stays when it is still there.
Map<String, dynamic> replaceSyncServers(Map<String, dynamic> current, Map<String, dynamic> incoming) {
  final out = Map<String, dynamic>.from(current);
  final picked = pickSyncServers(incoming);
  out['manual'] = picked['manual'];
  out['clean'] = picked['clean'];
  out['subs'] = picked['subs'];
  return out;
}
