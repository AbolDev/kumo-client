import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:package_info_plus/package_info_plus.dart';

import '../core/latency_tester.dart' show realDelay;
import '../core/net_options.dart' show fingerprints;
import '../core/proxy_config.dart';
import '../core/vpn_channel.dart';
import '../core/warp/warp_link.dart';
import '../core/warp/warp_scan.dart';
import '../core/warp/warp_profile.dart';
import '../core/warp/warp_register.dart';
import '../core/warp/warp_store.dart';
import 'app_state.dart';

/// One way to reach WARP: a method of the profile, an endpoint of it and one of its ports.
class WarpCombo {
  const WarpCombo(this.method, this.endpoint, this.portIndex);
  final WarpMethod method;
  final WarpEndpoint endpoint;
  final int portIndex;

  int get port => endpoint.ports[portIndex];
}

/// Cloudflare WARP as a server in the list of configs added by hand: an account is made once for this
/// device, and the link of the server is rebuilt from it and from the profile (see warp_profile.dart),
/// so that a new profile can change how it connects without a new version of the app.
class WarpController extends ChangeNotifier {
  WarpController(this._state, {int? build}) : _build = build;

  final AppState _state;
  int? _build;

  static const _file = 'warp_account.json';
  static const _every = Duration(hours: 6);

  /// The method a new account starts with.
  static const defaultMethodId = 'masque-h2';

  late final WarpProfileStore store = WarpProfileStore(
    read: VpnChannel.readFile,
    write: VpnChannel.writeFile,
    loadAsset: rootBundle.loadString,
    fetch: _fetch,
  );

  WarpAccount? account;

  /// Warp-in-Warp (experimental): a second account whose tunnel carries the first one's. Off by
  /// default; the second account is made when the switch is first turned on.
  WarpAccount? account2;
  bool inWarp = false;

  /// An endpoint found by the wider scan (an address of Cloudflare's ranges that is not in the
  /// profile) that is used instead of the profile's own list; null when the profile's list is used.
  ({String method, String ip, int port})? custom;

  /// Whether WARP is on: its server is in the list. Off by default; turning it off takes the server
  /// out of the list but keeps the account, so that turning it on again needs no new sign-up.
  bool enabled = false;

  /// Which combination of [combos] the link is built from.
  int choice = 0;

  /// The link the server in the list was made from (to find it again when it is replaced).
  String? link;

  /// The method and the address the link goes with, for the screen.
  String? currentMethod;
  String? currentAddress;
  bool busy = false;

  /// How far the making of a new account has come (0 to 1) while [setUp] signs up; null at other times.
  double? setupProgress;
  bool loaded = false;
  String? error;
  WarpUpdateResult? lastUpdate;
  int _checkedAt = 0;

  WarpProfile? get profile => store.profile;

  String get platform => Platform.isAndroid
      ? 'android'
      : Platform.isWindows
          ? 'windows'
          : Platform.isMacOS
              ? 'macos'
              : 'linux';

  Future<int> _buildNumber() async {
    if (_build != null) return _build!;
    try {
      return _build = int.tryParse((await PackageInfo.fromPlatform()).buildNumber) ?? 0;
    } catch (_) {
      return _build = 0;
    }
  }

  /// The ways this build can reach WARP now, best first.
  Future<List<WarpCombo>> combos() async {
    final p = profile;
    if (p == null) return const [];
    final build = await _buildNumber();
    return [
      for (final m in p.usable(platform: platform, build: build))
        for (final e in p.endpoints)
          for (var i = 0; i < e.ports.length; i++) WarpCombo(m, e, i),
      // The MASQUE ways come last (see [masqueMethods]).
      for (final m in masqueMethods) WarpCombo(m, WarpEndpoint(masque?.endpoint ?? masqueDefaultEndpoint, const [443]), 0),
    ];
  }

  /// The account of the MASQUE ways, made the first time one of them is used (a different account from
  /// [account]: a device that takes a MASQUE key no longer speaks WireGuard).
  WarpMasqueAccount? masque;

  /// The uTLS fingerprint of the MASQUE ways over HTTP/2 (`chrome`, `firefox`, ...); empty keeps Xray's own.
  String masqueFingerprint = '';

  /// Changes the fingerprint of the MASQUE ways and rebuilds the server with it.
  Future<void> setMasqueFingerprint(String fp) async {
    if (account == null || busy || !fingerprints.contains(fp) || fp == masqueFingerprint) return;
    masqueFingerprint = fp;
    error = null;
    try {
      await _apply();
      await _state.reconnectIfConnected();
    } catch (e) {
      error = '$e'.replaceFirst('Bad state: ', '');
    }
    await _save();
    notifyListeners();
  }

  /// The link of a way of reaching WARP. A MASQUE way makes its account first when there is none.
  Future<String> _linkOf(WarpCombo c, {WarpAccount? wg, WarpEndpoint? endpoint, String name = 'WARP'}) async {
    if (isMasqueKind(c.method.kind)) {
      final account = await _ensureMasque();
      return masqueLink(account, c.method, name: name, fingerprint: masqueFingerprint);
    }
    return warpLink(wg ?? account!, c.method, endpoint ?? c.endpoint, endpoint == null ? c.portIndex : 0, name: name);
  }

  Future<WarpMasqueAccount> _ensureMasque() async {
    final have = masque;
    if (have != null) return have;
    final p = store.profile;
    if (p == null) throw StateError('no WARP profile is available');
    final made = await registerWarpMasque(p);
    masque = made;
    await _save();
    return made;
  }

  /// The profile's note for [language] (or English), if it has one.
  String? note(String language) => profile?.message[language] ?? profile?.message['en'];

  Future<String> _fetch(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    // Through the proxy while connected, so that a network that blocks the address still gets it.
    if (_state.connected && !_state.net.tun) {
      client.findProxy = (_) => 'PROXY 127.0.0.1:${_state.net.proxyPort}';
    }
    try {
      final req = await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 10));
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) throw HttpException('status ${res.statusCode}', uri: Uri.parse(url));
      final bytes = <int>[];
      await for (final chunk in res.timeout(const Duration(seconds: 10))) {
        bytes.addAll(chunk);
        if (bytes.length > 70 * 1024) throw const HttpException('too large');
      }
      return utf8.decode(bytes);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> load() async {
    if (loaded) return;
    try {
      final text = await VpnChannel.readFile(_file);
      final j = text == null ? null : jsonDecode(text);
      if (j is Map) {
        account = WarpAccount.fromJson(j['account']);
        account2 = WarpAccount.fromJson(j['account2']);
        masque = WarpMasqueAccount.fromJson(j['masque']);
        final fp = j['masqueFp'];
        masqueFingerprint = fp is String && fingerprints.contains(fp) ? fp : '';
        inWarp = j['inWarp'] == true && account2 != null;
        h2Default = j['h2Default'] == true;
        final cu = j['custom'];
        if (cu is Map && cu['method'] is String && cu['ip'] is String && cu['port'] is int) {
          final port = cu['port'] as int;
          // Only an address of Cloudflare is ever used.
          if (isCloudflareV4(cu['ip'] as String) && port >= 1 && port <= 65535) {
            custom = (method: cu['method'] as String, ip: cu['ip'] as String, port: port);
          }
        }
        // Saved before the switch existed: an account that was made is in use.
        enabled = j['enabled'] is bool ? j['enabled'] as bool : account != null;
        choice = j['choice'] is int ? j['choice'] as int : 0;
        link = j['link'] is String ? j['link'] as String : null;
        _checkedAt = j['checked'] is int ? j['checked'] as int : 0;
      }
    } catch (_) {
      // no account yet
    }
    await store.load();
    loaded = true;
    notifyListeners();
  }

  Future<void> _save() => VpnChannel.writeFile(
      _file,
      jsonEncode({
        'account': account?.toJson(),
        'account2': account2?.toJson(),
        'masque': masque?.toJson(),
        if (masqueFingerprint.isNotEmpty) 'masqueFp': masqueFingerprint,
        'inWarp': inWarp,
        if (h2Default) 'h2Default': true,
        if (custom != null) 'custom': {'method': custom!.method, 'ip': custom!.ip, 'port': custom!.port},
        'enabled': enabled,
        'choice': choice,
        'link': link,
        'checked': _checkedAt,
      }));

  /// At the start of the app: when an account exists, looks for a newer profile now and then.
  Future<void> startup() async {
    await restoreServer();
    if (account == null || !enabled) return;
    // An account made before MASQUE over HTTP/2 was the default: moved to it once (its own account is asked for
    // in the background, once a run until it works), so that the MASQUE ways show in the group too.
    if (!inWarp && (!h2Default || masque == null)) unawaited(_upgrade());
    if (DateTime.now().millisecondsSinceEpoch - _checkedAt < _every.inMilliseconds) {
      return;
    }
    await updateProfile(silent: true);
  }

  /// Whether the way in use was moved to [defaultMethodId] once (a new account starts there); until then each
  /// run tries it again.
  bool h2Default = false;

  Future<void> _upgrade() async {
    if (_masqueTried || busy || scanning) return;
    _masqueTried = true;
    final all = await combos();
    if (!all.any((c) => isMasqueKind(c.method.kind))) return;
    final h2 = all.indexWhere((c) => c.method.id == defaultMethodId);
    final before = (choice, custom);
    try {
      if (!h2Default && h2 >= 0) {
        custom = null;
        choice = h2;
      }
      // Makes the MASQUE account when there is none (an error leaves the list as it was).
      await _apply();
      h2Default = true;
      await _save();
      if (isChosen) await _state.reconnectIfConnected();
    } catch (_) {
      choice = before.$1;
      custom = before.$2;
    }
    notifyListeners();
  }

  /// The ways Warp-in-Warp can use: plain WireGuard ones (a method with noise goes through Xray,
  /// which does not carry one tunnel inside another).
  List<WarpCombo> _plain(List<WarpCombo> all) =>
      all.where((c) => c.method.kind != 'wg-noise' && !isMasqueKind(c.method.kind)).toList();

  Future<ProxyConfig?> _configFor(List<WarpCombo> all) async {
    if (account == null || all.isEmpty) return null;
    final useTwo = inWarp && account2 != null;
    final list = useTwo ? _plain(all) : all;
    if (list.isEmpty) throw StateError('no plain WireGuard method in the profile for Warp-in-Warp');
    final cu = custom;
    // An address found by the wider scan: the method it was found with (or the best one) and that address.
    final c = cu == null
        ? list[choice % list.length]
        : WarpCombo(
            list.map((x) => x.method).where((m) => m.id == cu.method).firstOrNull ?? list.first.method,
            WarpEndpoint(cu.ip, [cu.port]),
            0);
    final text = await _linkOf(c);
    var config = parseLink(text);
    if (config == null) return null;
    if (useTwo) {
      final inner = parseLink(warpLink(account2!, c.method, c.endpoint, c.portIndex, name: 'WARP inner'));
      if (inner == null || inner.outbound.isEmpty) return null;
      // The first account's tunnel is dialled through the second account's tunnel.
      config = ProxyConfig(
        link: text,
        protocol: config.protocol,
        name: 'WARP in WARP',
        host: config.host,
        port: config.port,
        outbound: config.outbound,
        inner: [inner.outbound],
      );
    }
    link = text;
    currentMethod = useTwo ? '${c.method.id} x2' : c.method.id;
    currentAddress = '${c.endpoint.ip}:${c.port}';
    return config;
  }

  /// Turns Warp-in-Warp on or off. The second account is made the first time it is turned on.
  Future<void> setInWarp(bool on) async {
    if (account == null || busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await load();
      if (on && account2 == null) {
        final p = store.profile;
        if (p == null) throw StateError('no WARP profile is available');
        account2 = await registerWarp(p);
      }
      inWarp = on;
      choice = 0;
      await _apply();
      await _state.reconnectIfConnected();
    } catch (e) {
      inWarp = false;
      error = '$e'.replaceFirst('Bad state: ', '');
      try {
        await _apply();
      } catch (_) {}
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// What each WARP server of the list stands for: its way of connecting and the place of that way in
  /// [combos] (-1 for an address of the wider scan).
  final _ways = Expando<({WarpCombo combo, int index})>();

  /// The WARP server of the way in use.
  ProxyConfig? _active;

  /// A missing MASQUE account is asked for once a run when the list is made (not at each rebuild).
  bool _masqueTried = false;

  /// The servers of the WARP group: one per method of [all], in the order of the profile. The method in use
  /// has the way in use (its address and port, or the one of the wider scan), the others their first, best,
  /// way. The MASQUE methods need their own account: with [signUp] it is made once a run when missing, and
  /// they are left out while there is none. With Warp-in-Warp there is only the one server.
  Future<(List<ProxyConfig>, ProxyConfig?)> _serversFor(List<WarpCombo> all, {bool signUp = true}) async {
    if (account == null || all.isEmpty) return (const <ProxyConfig>[], null);
    if (inWarp && account2 != null) {
      final one = await _configFor(all);
      return (one == null ? const <ProxyConfig>[] : [one], one);
    }
    final cu = custom;
    final ({WarpCombo combo, int index}) now;
    if (cu == null) {
      final i = choice % all.length;
      now = (combo: all[i], index: i);
    } else {
      final method = all.map((x) => x.method).where((m) => m.id == cu.method).firstOrNull ?? all.first.method;
      now = (combo: WarpCombo(method, WarpEndpoint(cu.ip, [cu.port]), 0), index: -1);
    }
    if (isMasqueKind(now.combo.method.kind) && masque == null) {
      if (!signUp) throw StateError('no MASQUE account yet');
      await _ensureMasque(); // the way in use cannot be made without it: the caller reports the error
    } else if (signUp && masque == null && !_masqueTried && all.any((c) => isMasqueKind(c.method.kind))) {
      _masqueTried = true;
      try {
        await _ensureMasque();
      } catch (_) {
        // The MASQUE ways stay out of the list until a later run (or until one of them is picked).
      }
    }
    final servers = <ProxyConfig>[];
    ProxyConfig? active;
    final seen = <String>{};
    for (var i = 0; i < all.length; i++) {
      final m = all[i].method;
      if (!seen.add(m.id)) continue;
      if (isMasqueKind(m.kind) && masque == null) continue;
      final inUse = m.id == now.combo.method.id;
      final way = inUse ? now : (combo: all[i], index: i);
      // A MASQUE link puts the method after the name itself.
      final text = await _linkOf(way.combo, name: isMasqueKind(m.kind) ? 'WARP' : 'WARP ${m.id}');
      final config = parseLink(text);
      if (config == null) continue;
      _ways[config] = way;
      servers.add(config);
      if (inUse) {
        active = config;
        link = text;
      }
    }
    currentMethod = now.combo.method.id;
    currentAddress = '${now.combo.endpoint.ip}:${now.combo.port}';
    return (servers, active);
  }

  /// Puts the servers for the current choice in the list, in place of the ones made before.
  Future<void> _apply({bool choose = false}) async {
    final all = await combos();
    if (all.isEmpty) throw StateError('no method of the profile fits this version');
    final (servers, active) = await _serversFor(all);
    if (servers.isEmpty || active == null) throw StateError('the profile gave a link that cannot be used');
    _active = active;
    _state.setWarpServers(servers, active: active, choose: choose);
    await _save();
  }

  /// The user picked [config], one of the WARP servers of the list: its way is the one in use from now on (the
  /// scans and a rebuild keep it).
  void follow(ProxyConfig config) {
    final way = _ways[config];
    if (way == null) return;
    if (way.index >= 0) {
      custom = null;
      choice = way.index;
    }
    _active = config;
    link = config.link;
    currentMethod = way.combo.method.id;
    currentAddress = '${way.combo.endpoint.ip}:${way.combo.port}';
    unawaited(_save());
    notifyListeners();
  }

  /// Whether one of the WARP servers is the chosen server.
  bool get isChosen => _state.warpGroup.configs.any((c) => identical(c, _state.selected));

  /// Makes the account (once) and puts the server in the list, chosen.
  Future<void> setUp() async {
    if (busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await load();
      if (store.profile == null) throw StateError('no WARP profile is available');
      final fresh = account == null;
      var masqueReady = masque != null;
      if (fresh) {
        // The two sign-ups (WireGuard and MASQUE) run at the same time; the bar shows the two together.
        setupProgress = 0;
        var wg = 0.0, mq = 0.0;
        final wantMasque = !inWarp && masque == null && (await combos()).any((c) => isMasqueKind(c.method.kind));
        void report() {
          final now = 0.9 * (wantMasque ? (wg + mq) / 2 : wg);
          if (now > (setupProgress ?? 0)) setupProgress = now;
          notifyListeners();
        }

        final masqueSignUp = wantMasque
            ? registerWarpMasque(store.profile!, onProgress: (v) {
                mq = v;
                report();
              }).then<WarpMasqueAccount?>((a) => a, onError: (Object _) => null)
            : Future<WarpMasqueAccount?>.value(null);
        try {
          account = await registerWarp(store.profile!, onProgress: (v) {
            wg = v;
            report();
          });
        } catch (_) {
          // A newer profile may carry other piece sizes or addresses for a network that changed.
          final r = await store.update();
          if (r != WarpUpdateResult.updated) rethrow;
          account = await registerWarp(store.profile!, onProgress: (v) {
            wg = v;
            report();
          });
        }
        final made = await masqueSignUp;
        if (made != null) {
          masque = made;
          masqueReady = true;
          _masqueTried = true;
        }
      }
      enabled = true;
      // A new account starts with MASQUE over HTTP/2 (it passes where WireGuard is cut). When its sign-up
      // did not work, the first way of the profile is used, and MASQUE is tried again at the next start.
      if (fresh && !inWarp && masqueReady) {
        final i = (await combos()).indexWhere((c) => c.method.id == defaultMethodId);
        if (i >= 0) choice = i;
      }
      try {
        await _apply(choose: true);
        if (fresh && !inWarp && masqueReady) h2Default = true;
      } catch (_) {
        if (choice == 0) rethrow;
        choice = 0;
        await _apply(choose: true);
      }
      await _save();
    } catch (e) {
      error = '$e'.replaceFirst('Bad state: ', '');
      if (account == null) enabled = false;
    } finally {
      busy = false;
      setupProgress = null;
      notifyListeners();
    }
  }

  /// Turns WARP on: the server goes back in the list (the account is made first when there is none).
  Future<void> enable() async {
    if (account == null) return setUp();
    if (busy) return;
    enabled = true;
    error = null;
    try {
      await load();
      await _apply();
    } catch (e) {
      error = '$e'.replaceFirst('Bad state: ', '');
    }
    await _save();
    notifyListeners();
  }

  /// Turns WARP off: the server leaves the list; the account stays.
  Future<void> disable() async {
    enabled = false;
    _state.setWarpServer(null);
    error = null;
    await _save();
    notifyListeners();
  }

  // ---- the scan: which way of reaching WARP works best on this network

  bool scanning = false;
  int scanDone = 0, scanTotal = 0;
  bool _scanCancel = false;

  /// The ways that answered in the last scan, the fastest first (the text shown and the delay).
  List<({String text, int ms})> scanResults = const [];

  /// True after a scan in which nothing answered.
  bool scanFailed = false;

  void cancelScan() => _scanCancel = true;

  /// Tries every way of reaching WARP (a method of the profile, an endpoint, a port) with the real
  /// delay test, and switches to the fastest one that answered. Nothing changes when none did.
  Future<void> scan({Future<int> Function(ProxyConfig)? delay}) async {
    if (account == null || busy || scanning) return;
    // The same list the server is made from (with Warp-in-Warp only the plain WireGuard ways).
    final every = await combos();
    var all = inWarp && account2 != null ? _plain(every) : every;
    if (all.isEmpty) return;
    // The MASQUE ways need their own account: made now (this is the one place a scan signs up), and when
    // that does not work those ways are left out of the scan.
    if (all.any((c) => isMasqueKind(c.method.kind))) {
      try {
        await _ensureMasque();
      } catch (_) {
        all = all.where((c) => !isMasqueKind(c.method.kind)).toList();
      }
    }
    if (all.isEmpty) return;
    scanning = true;
    scanFailed = false;
    scanResults = const [];
    scanDone = 0;
    scanTotal = all.length < warpScanLimit ? all.length : warpScanLimit;
    _scanCancel = false;
    error = null;
    notifyListeners();
    try {
      final test = delay ?? ((c) => realDelay(c, timeout: const Duration(seconds: 7)));
      final found = await scanWarp(
        count: all.length,
        test: (i) async {
          final String text;
          try {
            text = await _linkOf(all[i]);
          } catch (_) {
            return -1;
          }
          final config = parseLink(text);
          return config == null ? -1 : await test(config);
        },
        onProgress: (d, t) {
          scanDone = d;
          notifyListeners();
        },
        cancelled: () => _scanCancel,
      );
      if (_scanCancel) return;
      scanResults = [
        for (final f in found.take(5))
          (text: '${all[f.index].method.id} ${all[f.index].endpoint.ip}:${all[f.index].port}', ms: f.ms),
      ];
      if (found.isEmpty) {
        scanFailed = true;
      } else {
        custom = null;
        choice = found.first.index;
        await _apply();
        await _state.reconnectIfConnected();
      }
    } catch (e) {
      error = '$e'.replaceFirst('Bad state: ', '');
    } finally {
      scanning = false;
      notifyListeners();
    }
  }

  /// The wider scan: besides the profile's own list, tries addresses drawn from the ranges of
  /// Cloudflare that the profile names (or the built-in ones) with the method now in use, and switches
  /// to the fastest that answers. Nothing changes when none did.
  Future<void> scanWide({Future<int> Function(ProxyConfig)? delay, Random? random}) async {
    final p = profile;
    if (account == null || busy || scanning || p == null) return;
    final every = await combos();
    final all = inWarp && account2 != null ? _plain(every) : every;
    if (all.isEmpty) return;
    // The wider scan looks for WireGuard endpoints: with a MASQUE way in use it takes the best WireGuard one.
    final wgOnly = all.where((c) => !isMasqueKind(c.method.kind)).toList();
    if (wgOnly.isEmpty) return;
    var method = (custom == null
            ? all[choice % all.length].method
            : all.map((c) => c.method).where((m) => m.id == custom!.method).firstOrNull ?? all.first.method);
    if (isMasqueKind(method.kind)) method = wgOnly.first.method;
    final addresses = pickScanAddresses(p.scanRanges, warpWideCount, random ?? Random());
    if (addresses.isEmpty) return;
    final ports = p.scanPorts;
    scanning = true;
    scanFailed = false;
    scanResults = const [];
    scanDone = 0;
    scanTotal = addresses.length;
    _scanCancel = false;
    error = null;
    notifyListeners();
    try {
      final test = delay ?? ((c) => realDelay(c, timeout: const Duration(seconds: 7)));
      final found = await scanWarp(
        count: addresses.length,
        test: (i) {
          final endpoint = WarpEndpoint(addresses[i], [ports[i % ports.length]]);
          final config = parseLink(warpLink(account!, method, endpoint, 0));
          return config == null ? Future.value(-1) : test(config);
        },
        onProgress: (d, t) {
          scanDone = d;
          notifyListeners();
        },
        cancelled: () => _scanCancel,
      );
      if (_scanCancel) return;
      scanResults = [
        for (final f in found.take(5)) (text: '${method.id} ${addresses[f.index]}:${ports[f.index % ports.length]}', ms: f.ms),
      ];
      if (found.isEmpty) {
        scanFailed = true;
      } else {
        final best = found.first;
        custom = (method: method.id, ip: addresses[best.index], port: ports[best.index % ports.length]);
        await _apply();
        await _state.reconnectIfConnected();
      }
    } catch (e) {
      error = '$e'.replaceFirst('Bad state: ', '');
    } finally {
      scanning = false;
      notifyListeners();
    }
  }

  /// Downloads the newest profile; when it changed and an account exists, the server is rebuilt.
  Future<void> updateProfile({bool silent = false}) async {
    if (busy) return;
    busy = true;
    if (!silent) error = null;
    notifyListeners();
    try {
      await load();
      final r = await store.update();
      lastUpdate = r;
      // "Failed" is not counted as a check: it is tried again at the next start.
      if (r != WarpUpdateResult.failed) _checkedAt = DateTime.now().millisecondsSinceEpoch;
      if (r == WarpUpdateResult.updated && account != null) {
        await _apply();
        await _state.reconnectIfConnected();
      } else if (account != null) {
        await _save();
      }
    } catch (e) {
      if (!silent) error = '$e'.replaceFirst('Bad state: ', '');
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Makes the WARP server the chosen one.
  Future<void> choose() async {
    final c = config;
    if (c != null && !identical(_state.selected, c)) await _state.select(c);
    notifyListeners();
  }

  /// Takes the WARP server out of the list and forgets the account.
  Future<void> remove() async {
    account = null;
    account2 = null;
    masque = null;
    masqueFingerprint = '';
    h2Default = false;
    inWarp = false;
    custom = null;
    enabled = false;
    _state.setWarpServer(null);
    _active = null;
    link = null;
    currentMethod = currentAddress = null;
    choice = 0;
    error = null;
    try {
      await VpnChannel.deleteFile(_file);
    } catch (_) {}
    notifyListeners();
  }

  /// The WARP server of the way in use, when it is in the list.
  ProxyConfig? get config {
    final a = _active;
    final list = _state.warpGroup.configs;
    return a != null && list.any((c) => identical(c, a)) ? a : list.firstOrNull;
  }

  /// At the start of the app, before the choice of server is read: puts the servers of the saved
  /// account in their group (when WARP is on), so that one of them can be the chosen one. Nothing is signed up
  /// here; when the list cannot be made, the saved server of the way in use is put back alone.
  Future<void> restoreServer() async {
    await load();
    final l = link;
    if (!enabled || account == null || l == null) return;
    var servers = const <ProxyConfig>[];
    try {
      final (list, active) = await _serversFor(await combos(), signUp: false);
      servers = list;
      _active = active;
    } catch (_) {
      // the saved link below
    }
    if (servers.isEmpty) {
      final one = parseLink(l);
      if (one == null) return;
      servers = [one];
      _active = one;
    }
    _state.restoreWarpServers(servers);
  }
}
