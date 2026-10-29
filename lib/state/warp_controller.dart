import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:package_info_plus/package_info_plus.dart';

import '../core/proxy_config.dart';
import '../core/vpn_channel.dart';
import '../core/warp/warp_link.dart';
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

  late final WarpProfileStore store = WarpProfileStore(
    read: VpnChannel.readFile,
    write: VpnChannel.writeFile,
    loadAsset: rootBundle.loadString,
    fetch: _fetch,
  );

  WarpAccount? account;

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
    ];
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
        'enabled': enabled,
        'choice': choice,
        'link': link,
        'checked': _checkedAt,
      }));

  /// At the start of the app: when an account exists, looks for a newer profile now and then.
  Future<void> startup() async {
    await restoreServer();
    if (account == null || !enabled) return;
    if (DateTime.now().millisecondsSinceEpoch - _checkedAt < _every.inMilliseconds) {
      return;
    }
    await updateProfile(silent: true);
  }

  Future<ProxyConfig?> _configFor(List<WarpCombo> all) async {
    if (account == null || all.isEmpty) return null;
    final c = all[choice % all.length];
    final text = warpLink(account!, c.method, c.endpoint, c.portIndex);
    final config = parseLink(text);
    if (config == null) return null;
    link = text;
    currentMethod = c.method.id;
    currentAddress = '${c.endpoint.ip}:${c.port}';
    return config;
  }

  /// Puts the server for the current choice in the list, in place of the one made before.
  Future<void> _apply({bool choose = false}) async {
    final all = await combos();
    if (all.isEmpty) throw StateError('no method of the profile fits this version');
    final config = await _configFor(all);
    if (config == null) throw StateError('the profile gave a link that cannot be used');
    _state.setWarpServer(config, choose: choose);
    await _save();
  }

  /// Makes the account (once) and puts the server in the list, chosen.
  Future<void> setUp() async {
    if (busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await load();
      if (store.profile == null) throw StateError('no WARP profile is available');
      if (account == null) {
        try {
          account = await registerWarp(store.profile!);
        } catch (_) {
          // A newer profile may carry other piece sizes or addresses for a network that changed.
          final r = await store.update();
          if (r != WarpUpdateResult.updated) rethrow;
          account = await registerWarp(store.profile!);
        }
      }
      enabled = true;
      await _apply(choose: true);
    } catch (e) {
      error = '$e'.replaceFirst('Bad state: ', '');
      if (account == null) enabled = false;
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

  /// Switches to the next way of reaching WARP (another method, endpoint or port).
  Future<void> nextMethod() async {
    if (account == null || busy) return;
    final all = await combos();
    if (all.isEmpty) return;
    choice = (choice + 1) % all.length;
    error = null;
    try {
      await _apply();
      await _state.reconnectIfConnected();
    } catch (e) {
      error = '$e'.replaceFirst('Bad state: ', '');
    }
    notifyListeners();
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
    enabled = false;
    _state.setWarpServer(null);
    link = null;
    currentMethod = currentAddress = null;
    choice = 0;
    error = null;
    try {
      await VpnChannel.deleteFile(_file);
    } catch (_) {}
    notifyListeners();
  }

  /// The WARP server, when it is in the list.
  ProxyConfig? get config => _state.warpGroup.configs.firstOrNull;

  /// At the start of the app, before the choice of server is read: puts the server of the saved
  /// account in its group (when WARP is on), so that it can be the chosen one.
  Future<void> restoreServer() async {
    await load();
    final l = link;
    if (!enabled || account == null || l == null) return;
    final config = parseLink(l);
    if (config != null) _state.restoreWarpServer(config);
  }
}
