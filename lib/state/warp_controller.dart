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
import '../core/singbox_config.dart' show xrayViaKey;
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
  double? get setupProgress => busy ? _setupProgress : null;
  double? _setupProgress;

  /// The number of the run of [setUp] that may report progress: a sign-up that was left running (the MASQUE one
  /// when the WireGuard one failed) goes on calling its progress after the run ended, and must not bring the bar
  /// back for good.
  int _setupRun = 0;
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
      // The MASQUE ways come last (see [masqueMethods]). They need an account of their own (a P-256 key), which keys
      // the user brought cannot give: with those only the WireGuard ways are used.
      if (!imported)
        for (final m in masqueMethods) WarpCombo(m, WarpEndpoint(masque?.endpoint ?? masqueDefaultEndpoint, const [443]), 0),
    ];
  }

  /// The account of the MASQUE ways, made the first time one of them is used (a different account from
  /// [account]: a device that takes a MASQUE key no longer speaks WireGuard).
  WarpMasqueAccount? masque;

  /// The WARP+ license key the accounts are bound to (empty: a free account). The MASQUE account is made with it too.
  String license = '';

  /// Whether [account] holds keys the user brought (see [importAccount]) and not one made here.
  bool imported = false;

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

  /// Whether the plain WireGuard ways of WARP are reached with AmneziaWG (junk packets before the handshake, for a network that
  /// cuts the handshake of WireGuard).
  bool amnezia = false;

  /// Turns AmneziaWG on or off for the ways of WARP and rebuilds the servers with it.
  Future<void> setAmnezia(bool on) async {
    if (account == null || busy || on == amnezia) return;
    amnezia = on;
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
    return warpLink(wg ?? account!, c.method, endpoint ?? c.endpoint, endpoint == null ? c.portIndex : 0,
        name: name, amnezia: amnezia);
  }

  Future<WarpMasqueAccount> _ensureMasque() async {
    final have = masque;
    if (have != null) return have;
    final p = store.profile;
    if (p == null) throw StateError('no WARP profile is available');
    final made = await registerWarpMasque(p, license: license.isEmpty ? null : license);
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
        amnezia = j['amnezia'] == true;
        license = j['license'] is String && warpLicenseOf(j['license'] as String) != null ? j['license'] as String : '';
        imported = j['imported'] == true;
        inWarp =j['inWarp'] == true && account2 != null;
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
        if (amnezia) 'amnezia': true,
        if (license.isNotEmpty) 'license': license,
        if (imported) 'imported': true,
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

  /// Warp-in-Warp made the way of [outer]: the tunnel of the main account inside a tunnel that faces the
  /// network, made by the second account (a WireGuard way) or the MASQUE one (a MASQUE way). Inside, no filter
  /// sees the packets, so the inner tunnel is plain WireGuard; the outer one is what has to pass the filter.
  /// Plain WireGuard outside is carried by sing-box. Noise and MASQUE only Xray carries: the whole is then an
  /// Xray server whose inner tunnel opens its connection through the outer one (see [xrayViaKey]).
  @visibleForTesting
  ProxyConfig? twoLayer(WarpCombo outer, List<WarpMethod> methods, {String? outerLink}) {
    final main = account, second = account2;
    if (main == null) return null;
    final name = 'WARP in WARP ${outer.method.id}';
    final masqueWay = isMasqueKind(outer.method.kind);
    // The address of the inner tunnel: the one of the way when it is a WireGuard one, else the first of the
    // profile (reached through the outer tunnel, so the filter never sees it).
    final innerEnd = masqueWay ? (profile?.endpoints.firstOrNull ?? outer.endpoint) : outer.endpoint;
    final innerPort = masqueWay ? 0 : outer.portIndex;
    if (outer.method.kind == 'wg-plain') {
      if (second == null) return null;
      final text = warpLink(main, outer.method, innerEnd, innerPort, name: name);
      final inside = parseLink(text);
      final under = parseLink(warpLink(second, outer.method, outer.endpoint, outer.portIndex, name: 'WARP outer'));
      if (inside == null || under == null || under.outbound.isEmpty) return null;
      // The main account's tunnel is dialled through the second account's tunnel.
      return ProxyConfig(
        link: text,
        protocol: inside.protocol,
        name: name,
        host: inside.host,
        port: inside.port,
        outbound: inside.outbound,
        inner: [under.outbound],
      );
    }
    final plain = methods.where((m) => m.kind == 'wg-plain').firstOrNull;
    if (plain == null) throw StateError('no plain WireGuard method in the profile for Warp-in-Warp');
    final outerText = outerLink ??
        (masqueWay || second == null ? null : warpLink(second, outer.method, outer.endpoint, outer.portIndex, name: name));
    if (outerText == null) return null;
    final outside = parseLink(outerText);
    final inside = parseLink(warpLink(main, plain, innerEnd, innerPort, name: name));
    final outerXray = outside?.xrayOutbound, innerXray = inside?.xrayOutbound;
    if (outside == null || outerXray == null || innerXray == null) return null;
    final xray = jsonDecode(jsonEncode(innerXray)) as Map<String, dynamic>;
    // Room in each packet for the headers of the outer tunnel (WARP's tunnel is 1280 bytes).
    final settings = xray['settings'];
    if (settings is Map<String, dynamic>) settings['mtu'] = 1200;
    xray[xrayViaKey] = outerXray;
    return ProxyConfig(
      link: outerText,
      protocol: 'wireguard',
      name: name,
      host: outside.host,
      port: outside.port,
      outbound: const <String, dynamic>{},
      xrayOutbound: xray,
      xrayNote: masqueWay ? 'masque' : 'noise',
    );
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
  /// they are left out while there is none. With Warp-in-Warp each server is two tunnels, the way of its
  /// method outside (see [twoLayer]).
  Future<(List<ProxyConfig>, ProxyConfig?)> _serversFor(List<WarpCombo> all, {bool signUp = true}) async {
    if (account == null || all.isEmpty) return (const <ProxyConfig>[], null);
    final two = inWarp && account2 != null;
    final methods = all.map((c) => c.method).toList();
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
      final ProxyConfig? config;
      if (two) {
        // The MASQUE link of the outer tunnel (its account is the MASQUE one); a WireGuard way makes its own.
        final outerLink = isMasqueKind(m.kind) ? await _linkOf(way.combo, name: 'WARP in WARP') : null;
        config = twoLayer(way.combo, methods, outerLink: outerLink);
      } else {
        // A MASQUE link puts the method after the name itself.
        config = parseLink(await _linkOf(way.combo, name: isMasqueKind(m.kind) ? 'WARP' : 'WARP ${m.id}'));
      }
      if (config == null) continue;
      final text = config.link;
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
      final run = ++_setupRun;
      if (fresh) {
        // The two sign-ups (WireGuard and MASQUE) run at the same time; the bar shows the two together.
        _setupProgress = 0;
        var wg = 0.0, mq = 0.0;
        final wantMasque = !inWarp && masque == null && (await combos()).any((c) => isMasqueKind(c.method.kind));
        void report() {
          if (run != _setupRun || !busy) return;
          final now = 0.9 * (wantMasque ? (wg + mq) / 2 : wg);
          if (now > (_setupProgress ?? 0)) _setupProgress = now;
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
        } else if (wantMasque) {
          // It was tried just now, with the bar showing it: making the list must not run it a second time while
          // the bar stands still (it is asked for again at the next start).
          _masqueTried = true;
        }
        // The accounts are made; what is left is putting the servers in the list.
        if (run == _setupRun) _setupProgress = 0.95;
        notifyListeners();
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
      _setupRun++;
      busy = false;
      _setupProgress = null;
      notifyListeners();
    }
  }

  /// Binds WARP to a WARP+ license key (see [warpLicenseOf]): new accounts are made with it, in place of the ones there
  /// are (the WireGuard one and, for the MASQUE ways, the MASQUE one), and the server is put in the list, chosen. A key the
  /// service refuses leaves everything as it was and sets [error].
  Future<void> setLicense(String text) async {
    final key = warpLicenseOf(text);
    if (key == null || busy) return;
    busy = true;
    error = null;
    _setupProgress = 0;
    final run = ++_setupRun;
    notifyListeners();
    final before = (account, masque, license, imported, enabled, choice, custom, h2Default);
    final hadAccount = account != null;
    try {
      await load();
      final p = store.profile;
      if (p == null) throw StateError('no WARP profile is available');
      imported = false;
      final wantMasque = !inWarp && (await combos()).any((c) => isMasqueKind(c.method.kind));
      var wg = 0.0, mq = 0.0;
      void report() {
        if (run != _setupRun || !busy) return;
        final now = 0.9 * (wantMasque ? (wg + mq) / 2 : wg);
        if (now > (_setupProgress ?? 0)) _setupProgress = now;
        notifyListeners();
      }

      // A key the service refuses stops the WireGuard sign-up; the MASQUE one is only asked for at the same time.
      final masqueSignUp = wantMasque
          ? registerWarpMasque(p, license: key, onProgress: (v) {
              mq = v;
              report();
            }).then<WarpMasqueAccount?>((a) => a, onError: (Object _) => null)
          : Future<WarpMasqueAccount?>.value(null);
      final made = await registerWarp(p, license: key, onProgress: (v) {
        wg = v;
        report();
      });
      final madeMasque = await masqueSignUp;
      account = made;
      masque = madeMasque;
      license = key;
      _masqueTried = true;
      enabled = true;
      custom = null;
      choice = 0;
      if (!inWarp && madeMasque != null) {
        final i = (await combos()).indexWhere((c) => c.method.id == defaultMethodId);
        if (i >= 0) {
          choice = i;
          h2Default = true;
        }
      }
      if (run == _setupRun) _setupProgress = 0.95;
      notifyListeners();
      await _apply(choose: true);
      await _save();
      if (hadAccount) await _state.reconnectIfConnected();
    } catch (e) {
      account = before.$1;
      masque = before.$2;
      license = before.$3;
      imported = before.$4;
      enabled = before.$5;
      choice = before.$6;
      custom = before.$7;
      h2Default = before.$8;
      error = '$e'.replaceFirst('Bad state: ', '');
      if (hadAccount) {
        try {
          await _apply();
        } catch (_) {}
      }
    } finally {
      _setupRun++;
      busy = false;
      _setupProgress = null;
      notifyListeners();
    }
  }

  /// Uses [keys] the user brought (see [parseWarpAccount]) in place of an account made here. Only the WireGuard ways of
  /// the profile are used with them (see [imported]). Nothing changes when the server cannot be made from them.
  Future<void> importAccount(WarpAccount keys) async {
    if (busy) return;
    busy = true;
    error = null;
    notifyListeners();
    final before = (account, account2, masque, license, imported, enabled, choice, custom, inWarp);
    final hadAccount = account != null;
    try {
      await load();
      if (store.profile == null) throw StateError('no WARP profile is available');
      account = keys;
      account2 = null;
      inWarp = false;
      masque = null;
      license = '';
      imported = true;
      enabled = true;
      custom = null;
      choice = 0;
      await _apply(choose: true);
      await _save();
      if (hadAccount) await _state.reconnectIfConnected();
    } catch (e) {
      account = before.$1;
      account2 = before.$2;
      masque = before.$3;
      license = before.$4;
      imported = before.$5;
      enabled = before.$6;
      choice = before.$7;
      custom = before.$8;
      inWarp = before.$9;
      error = '$e'.replaceFirst('Bad state: ', '');
      if (hadAccount) {
        try {
          await _apply();
        } catch (_) {}
      }
    } finally {
      busy = false;
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

  /// Whether the scan that runs (or ran last) is the wider one, of addresses outside the profile.
  bool scanIsWide = false;

  /// While a scan runs: how many ways answered, the fastest of them, the last ways tried (newest first, the
  /// delay -1 for no answer), and when it started (for the time that is left).
  int scanAnswered = 0;
  ({String text, int ms})? scanBest;
  List<({String text, int ms})> scanRecent = const [];
  DateTime? scanStarted;

  void cancelScan() => _scanCancel = true;

  void _startScan(int total, {required bool wide}) {
    scanning = true;
    scanIsWide = wide;
    scanFailed = false;
    scanResults = const [];
    scanDone = 0;
    scanTotal = total;
    scanAnswered = 0;
    scanBest = null;
    scanRecent = const [];
    scanStarted = DateTime.now();
    _scanCancel = false;
    error = null;
    notifyListeners();
  }

  /// One way of a scan was tried: [text] is how it is shown, [ms] its delay (negative: no answer).
  void _noteTry(String text, int ms) {
    final item = (text: text, ms: ms);
    if (ms >= 0) {
      scanAnswered++;
      final best = scanBest;
      if (best == null || ms < best.ms) scanBest = item;
    }
    scanRecent = [item, ...scanRecent.take(3)];
  }

  /// Tries every way of reaching WARP (a method of the profile, an endpoint, a port) with the real
  /// delay test, and switches to the fastest one that answered. Nothing changes when none did.
  Future<void> scan({Future<int> Function(ProxyConfig)? delay}) async {
    if (account == null || busy || scanning) return;
    // The same list the servers are made from. With Warp-in-Warp too every way is tried on its own: it is
    // the outer tunnel, the one the filter sees.
    var all = await combos();
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
    _startScan(all.length < warpScanLimit ? all.length : warpScanLimit, wide: false);
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
        onResult: (i, ms) => _noteTry('${all[i].method.id} ${all[i].endpoint.ip}:${all[i].port}', ms),
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
    final all = await combos();
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
    _startScan(addresses.length, wide: true);
    try {
      final test = delay ?? ((c) => realDelay(c, timeout: const Duration(seconds: 7)));
      final found = await scanWarp(
        count: addresses.length,
        test: (i) {
          final endpoint = WarpEndpoint(addresses[i], [ports[i % ports.length]]);
          final config = parseLink(warpLink(account!, method, endpoint, 0));
          return config == null ? Future.value(-1) : test(config);
        },
        onResult: (i, ms) => _noteTry('${method.id} ${addresses[i]}:${ports[i % ports.length]}', ms),
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
    license = '';
    imported = false;
    masqueFingerprint = '';
    amnezia = false;
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
