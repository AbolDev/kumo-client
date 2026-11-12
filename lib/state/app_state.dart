import 'dart:async';
import 'dart:convert';
import 'dart:io' show HandshakeException, HttpClient, InternetAddress, Platform, ServerSocket;
import 'dart:isolate' show Isolate;
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback, rootBundle;

import '../core/ad_lists.dart' show adBaseAsset;
import '../core/app_icon.dart';
import '../core/backup.dart';
import '../core/core_api.dart';
import '../core/latency_tester.dart';
import '../core/collector_sources.dart';
import '../core/desktop_vpn.dart';
import '../core/net_options.dart';
import '../core/platform.dart';
import '../core/proxy_config.dart';
import '../core/provider_routing.dart';
import '../core/rule_sets.dart';
import '../core/stun.dart';
import '../core/singbox_config.dart';
import '../core/speed_test.dart' show SpeedRoute;
import '../core/sources.dart';
import '../core/sub_formats.dart';
import '../core/sub_surge.dart' show subscriptionDeepLink;
import '../core/updater.dart' show includePrerelease;
import '../core/vpngate.dart';
import '../core/ovpn/ovpn_profile.dart' show ovpnLink;
import '../core/ovpn/ovpn_runner.dart';
import 'warp_controller.dart';
import 'usage_controller.dart';
import '../core/usage/usage_transport.dart' show defaultFragment;
import '../core/server_resolver.dart';
import '../core/usage/crash_hub.dart';
import '../core/usage_alert.dart';
import '../core/vpn_channel.dart';
import '../l10n/extra.dart' show trFor;
import '../l10n/strings.dart';

/// How many configs of the downloaded public list are kept.

/// How many of the fastest servers go into the automatic (urltest) group.
const _autoGroupSize = 6;

const _storeFile = 'servers.json';
const _settingsFile = 'settings.json';

/// A status line that is turned into text with the current language when it is shown.
typedef Message = String Function(S s);

enum GroupKind { collector, subscription, manual, warp, cleanIp }

/// Configs that come from the same place: the free collector, one subscription link,
/// or links added by hand.
class ServerGroup {
  ServerGroup(this.id, this.kind, {this.name = '', this.url});

  final String id;
  final GroupKind kind;
  String name;
  String? url;

  /// The name was taken from the link, so the subscription's own title may replace it.
  bool autoName = false;

  /// What the user set for downloading this subscription: the User-Agent to ask with (null: the app
  /// tries its usual clients one by one) and extra request headers (see core/sources.dart).
  String? userAgent;
  Map<String, String> headers = const {};

  /// Expiry and data volume the provider reported, if any.
  SubInfo? info;
  int updatedAt = 0; // ms since epoch

  /// Hours between two downloads: what the provider says, what the user set instead (it stays
  /// through updates until the user takes the provider's value again), or neither (the app's
  /// default is used).
  int? providerInterval;
  int? customInterval;
  int? get intervalHours => customInterval ?? providerInterval;

  /// The routing rules the provider sends, whether the provider wants them applied, and whether
  /// the user wants them (on by default).
  ProviderRouting? routing;
  bool routingByProvider = true;
  bool routingOn = true;

  /// Links and a notice the provider adds.
  String? supportUrl;
  String? webPage;
  String? announce;
  final List<ProxyConfig> configs = [];
}

/// Progress of a test run over one group.
class GroupTest {
  GroupTest(this.total);
  final int total;
  int done = 0;
  int alive = 0;
  bool running = true;
  int get percent => total == 0 ? 100 : (done * 100 ~/ total);
}

class LogEntry {
  LogEntry(this.time, this.text);
  final DateTime time;
  final String text;
}

const _logFile = 'app.log';
const _maxLogs = 300;

class AppState extends ChangeNotifier {
  // What the Android widgets were last told (the server and the delay), so they are told only of a change.
  String? _widgetSent;

  @override
  void notifyListeners() {
    super.notifyListeners();
    if (!Platform.isAndroid) return;
    final name = (selected ?? autoPick)?.name;
    final ping = connected && (liveDelay ?? -1) > 0 ? liveDelay : null;
    final key = '$name|$ping';
    if (key == _widgetSent) return;
    _widgetSent = key;
    VpnChannel.widgetInfo(name: name, ping: ping);
  }

  final collector = ServerGroup('collector', GroupKind.collector);

  /// Cloudflare WARP (see warp_controller.dart).
  late final warp = WarpController(this);

  /// The anonymous usage numbers (see core/usage): once a day, on by default, off in Settings.
  late final usage = UsageController(
    // Desktop in proxy mode: the app's own traffic does not go through the VPN.
    tunnelUp: () => connected && (!isDesktop || net.tun),
    appLanguage: () => languageCode, // null while the app follows the device
    log: (text) => log(text),
    screen: () => routes.current,
    vpnState: _vpnStateName,
    logLines: _recentLogLines,
    hosts: _secretHosts,
    fragment: () {
      final p = warp.profile;
      return p == null ? defaultFragment : (size: p.fragmentSize, delay: p.fragmentDelay);
    },
  );

  /// The page the user is on (given to the navigator; used in crash reports).
  final routes = RouteTracker();

  /// The VPN state under the names a crash report uses.
  String _vpnStateName() => switch (vpn.status) {
        VpnStatus.stopped => 'disconnected',
        VpnStatus.starting => 'connecting',
        VpnStatus.started => 'connected',
        VpnStatus.stopping => 'disconnecting',
        VpnStatus.error => 'error',
      };

  /// The last lines of the app's own log, with their time, for a crash report.
  List<String> _recentLogLines() {
    final from = logs.length > 40 ? logs.length - 40 : 0;
    return [
      for (final e in logs.sublist(from)) '${e.time.toIso8601String().substring(11, 19)} ${e.text.replaceAll('\n', ' ')}',
    ];
  }

  /// The names and addresses of the user's servers and subscriptions, removed from crash reports.
  Iterable<String> _secretHosts() sync* {
    for (final c in all) {
      yield c.host;
    }
    for (final g in groups) {
      final h = Uri.tryParse(g.url ?? '')?.host;
      if (h != null && h.isNotEmpty) yield h;
    }
  }

  /// The WARP server, in a group of its own while WARP is on. It is not saved with the servers: the
  /// controller makes it from the account it keeps.
  final warpGroup = ServerGroup('warp', GroupKind.warp);
  final manual = ServerGroup('manual', GroupKind.manual);

  /// The copies of configs that *Find a clean IP* made: kept apart from the configs added by hand, shown
  /// only while there are some, and replaced by the next scan.
  final cleanGroup = ServerGroup('clean', GroupKind.cleanIp);
  final List<ServerGroup> subscriptions = [];

  /// null = automatic (fastest servers).
  ProxyConfig? selected;

  VpnState vpn = const VpnState(VpnStatus.stopped);

  /// Status lines go to the log (Settings > Logs), not to the home screen.
  set message(Message? m) {
    if (m != null) log(m(SEn()));
  }

  final logs = <LogEntry>[];
  Timer? _logTimer;

  /// Changes with every new line of the log, so the log page redraws without the whole app doing it.
  final logRevision = ValueNotifier<int>(0);

  void log(String text) {
    logs.add(LogEntry(DateTime.now(), text));
    if (logs.length > _maxLogs) logs.removeRange(0, logs.length - _maxLogs);
    _logTimer ??= Timer(const Duration(seconds: 2), () {
      _logTimer = null;
      final data = logs
          .map((e) =>
              '${e.time.millisecondsSinceEpoch}|${e.text.replaceAll('\n', ' ')}')
          .join('\n');
      VpnChannel.writeFile(_logFile, data).catchError((_) {});
    });
    logRevision.value++;
  }

  void clearLogs() {
    logs.clear();
    VpnChannel.writeFile(_logFile, '').catchError((_) {});
    notifyListeners();
  }

  Future<void> _loadLogs() async {
    try {
      final raw = await VpnChannel.readFile(_logFile);
      for (final line in (raw ?? '').split('\n')) {
        final i = line.indexOf('|');
        final ms = i > 0 ? int.tryParse(line.substring(0, i)) : null;
        if (ms != null) {
          logs.add(LogEntry(
              DateTime.fromMillisecondsSinceEpoch(ms), line.substring(i + 1)));
        }
      }
    } catch (_) {
      // no log yet
    }
  }

  /// Why the connection last ended (a text key of the extra strings and its arguments), shown on
  /// the home screen while disconnected.
  ({String key, Map<String, Object> args})? lastDisconnect;

  /// Set when this app asked for the stop, so a stop that was not asked for can be told apart.
  var _expectStop = false;
  ({String key, Map<String, Object> args})? _forcedReason;

  void _noteDisconnect(VpnState s) {
    // The OpenVPN program lives as long as the connection does.
    stopOpenVpn();
    final forced = _forcedReason;
    _forcedReason = null;
    if (forced != null) {
      lastDisconnect = forced;
    } else if (s.status == VpnStatus.error) {
      final e = s.error ?? '';
      lastDisconnect = (key: 'reasonError', args: {'e': e.startsWith('ovpn:') ? _ovpnFailed(e) : e});
    } else if (_expectStop) {
      lastDisconnect = (key: 'reasonYou', args: const <String, Object>{});
    } else if (s.error == 'revoked') {
      lastDisconnect = (key: 'reasonRevoked', args: const <String, Object>{});
    } else {
      lastDisconnect = (key: 'reasonOutside', args: const <String, Object>{});
    }
    _expectStop = false;
    final asked = _stopAsked;
    _stopAsked = null;
    final took = asked == null ? '' : ' (${DateTime.now().difference(asked).inMilliseconds} ms)';
    log('Disconnect reason: ${trFor('en', lastDisconnect!.key, lastDisconnect!.args)}$took');
  }

  /// Delay through the live tunnel, measured after connecting (null = not measured yet).
  int? liveDelay;
  int? _xrayPort;
  XrayAuth? _xrayAuth;

  Future<void> _measureLive() async {
    final selectedNow = selected;
    for (var attempt = 0; attempt < 2 && connected; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (!connected) return;
      final ms = await tunnelDelay(
          socksPort: _xrayPort,
          socksAuth: _xrayAuth,
          proxyPort: net.tun ? null : net.proxyPort,
          samples: 2);
      if (!connected) return;
      if (ms >= 0 || attempt == 1) {
        liveDelay = ms;
        if (selectedNow != null && identical(selectedNow, selected)) {
          selectedNow.latencyMs = ms;
        }
        log(ms >= 0 ? 'Real delay $ms ms' : 'Real delay test failed');
        notifyListeners();
        return;
      }
    }
  }

  /// Test progress per group id, and the groups being downloaded or tested right now.
  final tests = <String, GroupTest>{};
  final working = <String>{};
  ThemeMode themeMode = ThemeMode.system;

  /// The app icon picked in Settings (see [AppIcon]).
  String appIcon = AppIcon.defaultId;

  /// null = follow the phone, otherwise 'fa' or 'en'.
  String? languageCode;

  // Sub settings
  bool autoUpdateSubs = true;
  bool updateOnStartup = true;
  bool updatePrerelease = false;

  /// Subscription downloads accept a certificate that does not check out. Off by default: with it
  /// on, anyone on the path can hand out servers of their own.
  bool allowInsecure = false;

  /// Servers of the public list may ask not to have their TLS certificate checked (the "allow
  /// insecure" option in their link). Off by default: the certificate is always checked.
  bool collectorAllowInsecure = false;

  /// The address the public list was last downloaded from.
  String? collectorSource;

  // The stored files could not be read. They are set aside (not written over) before anything new
  // is saved.
  bool _storeLocked = false;
  bool _settingsLocked = false;

  /// When each subscription was last tried (not only when it last worked), so a list that comes
  /// back empty is not asked for again every few minutes.
  final _lastAttempt = <String, int>{};

  // App settings
  bool autoConnect = false;
  bool restartOnChange = true;
  bool confirmDelete = true;
  bool batteryAsked = false;

  /// The request to star the project on GitHub: when the app was first used (ms), how many times it
  /// was opened, how many times the request was shown, when it may be shown next (ms), and whether
  /// it is over for good (starred, or "don't ask again").
  int starSince = 0;
  int starOpens = 0;
  int starAsked = 0;
  int starNext = 0;
  bool starDone = false;

  /// True when the request to star the project should be shown now: after a week of use and ten
  /// openings, at most twice (the second time a month after the first), never again once answered.
  bool get starDue {
    if (!onboarded || starDone || starAsked >= 2 || starSince == 0) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    return starOpens >= 10 && now - starSince >= 7 * 86400000 && now >= starNext;
  }

  /// Counts one opening of the app (and notes the first day of use).
  void noteOpen() {
    if (starSince == 0) starSince = DateTime.now().millisecondsSinceEpoch;
    starOpens++;
    _saveSettings();
  }

  /// The answer to the request: [done] when the user starred or asked not to be asked again.
  void answerStar({required bool done}) {
    starAsked++;
    starDone = done;
    starNext = DateTime.now().millisecondsSinceEpoch + 30 * 86400000;
    _saveSettings();
  }

  /// False until the first-run guide has been finished; people who already had settings skip it.
  bool onboarded = false;

  /// True once the saved settings have been read (before that the first-run guide must not show).
  bool settingsLoaded = false;

  /// True once the saved servers have been read. Until then an empty list means "not read yet", not "no servers".
  bool serversLoaded = false;

  /// No server at all, and none being fetched: the home page offers the ways to add one. False while the
  /// saved servers are still being read, so a user who has some does not see that page for a moment.
  bool get noServers => serversLoaded && all.isEmpty && working.isEmpty && refreshing.isEmpty;

  /// The country the user lives in, chosen in the first-run guide (two letters, or empty).
  String homeCountry = '';

  /// The public servers group can be hidden; it is on by default.
  bool showCollector = true;

  /// Ids of the groups in the order the user dragged them into; unknown ones come last.
  List<String> groupOrder = [];

  // UI settings
  bool showSpeed = true;

  /// Notification: transferred data (off by default) and the name of the server (on).
  bool showVolume = false;
  bool showName = true;

  /// Android: a "not connected" notification with a Connect button stays after a disconnect.
  bool idleNotification = true;

  /// A short vibration when a connection is made or ended (the phone only).
  bool haptics = true;

  /// What the question before a real delay test starts as ("Remove the configs that do not respond"): what the user
  /// ticked "Remember my choice" with. It is still asked every time.
  bool removeDeadChoice = false;

  /// What the home page is to do as soon as it is there ('paste' or 'free'): the last page of the guide
  /// sets it.
  String? pendingHomeAction;

  String? takePendingHomeAction() {
    final a = pendingHomeAction;
    pendingHomeAction = null;
    return a;
  }

  /// When the servers of VPN Gate were fetched (milliseconds since 1970; 0: never).
  int vpnGateUpdated = 0;

  /// How many servers of VPN Gate are in the list.
  int get vpnGateCount => manual.configs.where((c) => c.isOpenVpn && c.name.contains(vpnGateMark)).length;

  /// The colours of the app: 'teal' (Kumo's own) or 'system' (from the wallpaper on Android 12 and
  /// later, from the accent colour on Windows); and a black background in the dark theme.
  String themeColor = 'teal';
  bool blackTheme = false;

  /// Warn when a subscription is nearly out of data or about to expire (a notification on
  /// Android, a banner on Windows).
  bool usageAlerts = true;

  /// Measure the delay through the connection right after connecting and show it on the card.
  bool measurePing = true;

  /// Hours between two downloads of a subscription that sets no interval of its own.
  int subInterval = 6;

  /// Windows: what was already warned about, per subscription (see usage_alert.dart).
  final _alertSeen = <String, String>{};

  /// Windows: the warning shown at the top of the home screen until it is dismissed.
  String? alertText;

  void dismissAlert() {
    alertText = null;
    notifyListeners();
  }

  /// Shows a banner at the top of the home screen (the text is a key of the extra strings) and
  /// writes it to the log.
  void _notice(String key, [Map<String, Object> args = const {}]) {
    final lang = languageCode ?? WidgetsBinding.instance.platformDispatcher.locale.languageCode;
    alertText = trFor(lang, key, args);
    log('Notice: ${trFor('en', key, args)}');
    notifyListeners();
  }

  /// Warns about [g] if its data or time is running out and the user was not told yet.
  void checkUsage(ServerGroup g) {
    final info = g.info;
    if (!usageAlerts || info == null) return;
    if (Platform.isAndroid) {
      VpnChannel.checkUsage(g.id, g.name, info.used, info.total, info.expire);
      return;
    }
    final now = usageLevels(info);
    final seen = _alertSeen[g.id] ?? '00';
    _alertSeen[g.id] = now.code;
    final lang = languageCode ?? WidgetsBinding.instance.platformDispatcher.locale.languageCode;
    String? text;
    if (now.data > int.parse(seen[0])) {
      text = now.data == 2
          ? trFor(lang, 'alertDataOut', {'name': g.name})
          : trFor(lang, 'alertDataLow', {
              'name': g.name,
              'left': _formatBytes((info.total - info.used).clamp(0, 1 << 62).toInt()),
            });
    } else if (now.expiry > int.parse(seen[1])) {
      text = switch (now.expiry) {
        3 => trFor(lang, 'alertExpired', {'name': g.name}),
        2 => trFor(lang, 'alertExpToday', {'name': g.name}),
        _ => trFor(lang, 'alertExpSoon', {'name': g.name, 'days': daysLeft(info)}),
      };
    }
    if (seen != now.code) _saveSettings();
    if (text != null) {
      alertText = text;
      log('Alert: $text');
    }
  }

  static String _formatBytes(int b) {
    if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
    if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
    return '${b ~/ 1024} KB';
  }

  // Core settings
  String delayUrl = defaultDelayUrl;

  /// Network options (tunnel, proxy port, per-app routing, DNS, ...). Change them with [updateNet].
  final net = NetOptions();

  /// Local control API of the running core (live connections); set while connecting.
  int? apiPort;
  String? apiSecret;

  /// Speed and totals while connected; updated every second on its own so the list
  /// does not rebuild.
  final traffic = ValueNotifier<Traffic>(Traffic.zero);

  /// The list scrolls to [locateTarget] and highlights it when [locateTick] changes.
  final locateTick = ValueNotifier<int>(0);
  ProxyConfig? locateTarget;

  void locate(ProxyConfig config) {
    locateTarget = config;
    locateTick.value++;
  }

  /// Configs being tested one by one from their menu.
  final testing = <ProxyConfig>{};

  StreamSubscription<VpnState>? _sub;
  StreamSubscription<Traffic>? _trafficSub;

  // Jobs (downloads, tests) can overlap, so "busy" counts them. A newer job on the same
  // key cancels the older one.
  var _jobs = 0;
  final _generations = <String, int>{};

  bool get busy => _jobs > 0;

  /// Groups whose list is being downloaded; [cancelRefresh] stops one of them.
  final refreshing = <String>{};
  Timer? _dueTimer;
  final _cancels = <String, Completer<void>>{};

  int _begin(String key) => _generations[key] = (_generations[key] ?? 0) + 1;
  bool _stale(String key, int gen) => _generations[key] != gen;

  List<ServerGroup> get groups {
    final base = [
      if (showCollector) collector,
      if (warp.enabled && warpGroup.configs.isNotEmpty) warpGroup,
      ...subscriptions,
      if (cleanGroup.configs.isNotEmpty) cleanGroup,
      manual,
    ];
    int rank(ServerGroup g) {
      final i = groupOrder.indexOf(g.id);
      return i < 0 ? 1 << 20 : i;
    }

    final order = {for (var i = 0; i < base.length; i++) base[i]: i};
    return List.of(base)
      ..sort((a, b) {
        final r = rank(a).compareTo(rank(b));
        return r != 0 ? r : order[a]!.compareTo(order[b]!);
      });
  }

  /// Moves [g] next to [target] after the user dragged it there.
  void moveGroup(ServerGroup g, ServerGroup target, {required bool after}) {
    if (identical(g, target)) return;
    final ids = groups.map((e) => e.id).toList()..remove(g.id);
    final i = ids.indexOf(target.id);
    ids.insert(after ? i + 1 : i, g.id);
    groupOrder = ids;
    _saveSettings();
  }

  /// Every config of every group.
  Iterable<ProxyConfig> get all => groups.expand((g) => g.configs);

  /// Real delay needs a throw-away core outside the tunnel, so it is off while the VPN is up.
  bool get _real => !connected && !transitioning;

  int get aliveCount => all.where((c) => c.isAlive).length;

  bool get connected => vpn.status == VpnStatus.started;
  bool get transitioning =>
      vpn.status == VpnStatus.starting || vpn.status == VpnStatus.stopping;

  Future<void> init() async {
    _sub = VpnChannel.states.listen((s) {
      final changed = s.status != vpn.status;
      final before = vpn.status;
      vpn = s;
      if (changed &&
          (s.status == VpnStatus.stopped || s.status == VpnStatus.error) &&
          (before == VpnStatus.started ||
              before == VpnStatus.starting ||
              before == VpnStatus.stopping)) {
        _noteDisconnect(s);
        // The core stopped on its own or did not start: a report of it (the server and the link
        // are removed from the text; "revoked" is the user taking the VPN away, not a fault).
        if (s.status == VpnStatus.error && s.error != 'revoked') {
          final reason = (s.error ?? '').trim().isEmpty ? 'no reason given' : s.error!;
          CrashHub.report(StateError(reason), null,
              kind: before == VpnStatus.starting ? 'core_start_failed' : 'core_exit', message: reason);
        }
      }
      _preparing = false;
      if (s.status != VpnStatus.started) {
        traffic.value = Traffic.zero;
        _lastDown = _lastUp = 0;
        _lastTick = null;
        _baselined = false;
        downHistory.clear();
        upHistory.clear();
        if (_usageTimer != null) {
          _usageTimer!.cancel();
          _writeUsage();
        }
        liveDelay = null;
      }
      if (changed) _syncStandby(const Duration(milliseconds: 800), false);
      if (changed) {
        if (s.status == VpnStatus.started) buzz();
        if (s.status == VpnStatus.stopped) buzz();
        if (s.status == VpnStatus.error) buzz(strong: true);
      }
      if (s.status == VpnStatus.started && changed) {
        if (measurePing) _measureLive();
        _misses = 0;
        _healthDown = 0;
        _watch?.cancel();
        _watch = Timer.periodic(const Duration(seconds: 20), (_) {
          _refreshActive();
          _healthTick();
        });
        Future<void>.delayed(const Duration(seconds: 3), _refreshActive);
        _refreshListsSoon();
      } else if (s.status != VpnStatus.started) {
        _watch?.cancel();
        _watch = null;
        _listsTimer?.cancel();
        if (changed && (s.status == VpnStatus.stopped || s.status == VpnStatus.error)) _warmLookup(const Duration(seconds: 3));
      }
      if (s.status == VpnStatus.error) {
        final reason = s.error ?? '';
        message = (t) => t.connectFailed(reason);
      } else if (changed) {
        switch (s.status) {
          case VpnStatus.started:
            log('Connected');
          case VpnStatus.stopped:
            log('Disconnected');
          default:
        }
      }
      notifyListeners();
    });

    await _loadSettings();
    settingsLoaded = true;
    notifyListeners();
    // The usage count starts as soon as the settings are known (its switch and the way of sending are
    // among them): it no longer waits for the servers to be read and the subscriptions to be updated.
    usage.addListener(notifyListeners);
    unawaited(usage.startup().catchError((Object _) {}));
    _warmLookup(const Duration(seconds: 5));
    if (Platform.isWindows) {
      OvpnRunner.cleanLeftovers(await VpnChannel.dataDir()).catchError((Object _) {});
    }
    await _loadLogs();
    await _loadUsage();
    // Only now: samples that came in earlier would be overwritten by the saved numbers.
    _listenTraffic();
    await _loadServers();
    serversLoaded = true;
    notifyListeners();
    delayTestUrl = delayUrl;
    if (idleNotification) VpnChannel.setIdleNotification(true);
    VpnChannel.scheduleSubUpdates(autoUpdateSubs).catchError((_) {});
    if (isDesktop) {
      DesktopVpn.instance.standby.addListener(notifyListeners);
      // The connection is up but the desktop's proxy setting could not be made: say so, since
      // programs that follow that setting would not go through the proxy.
      DesktopVpn.instance.proxyIssue.addListener(() {
        if (DesktopVpn.instance.proxyIssue.value) _notice('proxyNotSet');
        notifyListeners();
      });
    }
    _syncStandby(const Duration(seconds: 1));
    _dueTimer?.cancel();
    _dueTimer = Timer.periodic(const Duration(minutes: 10), (_) {
      if (autoUpdateSubs) _updateDueSubscriptions();
    });
    notifyListeners();
    // Nothing is tested on its own: the user pings when they want to.
    await _applyCachedSubscriptions();
    for (final g in subscriptions) {
      checkUsage(g);
    }
    if (showCollector && collector.configs.isEmpty) await refreshCollector();
    if (updateOnStartup) await _updateSubscriptionsOnStartup();
    warp.addListener(notifyListeners);
    unawaited(warp.startup().catchError((Object _) {}));
  }

  /// Uses what the background job downloaded while the app was closed.
  Future<void> _applyCachedSubscriptions() async {
    for (final g in List.of(subscriptions)) {
      try {
        // The background job could not trust this provider's certificate.
        if (await VpnChannel.readFile('subcache/${g.id}.error') != null) {
          await VpnChannel.deleteFile('subcache/${g.id}.error');
          if (!allowInsecure) _notice('subCertError', {'name': g.name});
        }
        final raw = await VpnChannel.readFile('subcache/${g.id}.json');
        if (raw == null) continue;
        final j = jsonDecode(raw) as Map<String, dynamic>;
        final time = (j['time'] as num?)?.toInt() ?? 0;
        if (time <= g.updatedAt) continue;
        final fetched = Fetched.fromHeaders(
            j['body'] as String? ?? '',
            j['profileTitle'] as String?,
            j['disposition'] as String?,
            j['userinfo'] as String?,
            meta: ProviderMeta.fromHeaders((name) => switch (name) {
                  'profile-update-interval' => j['interval'] as String?,
                  'routing' => j['routing'] as String?,
                  'routing-enable' => j['routingEnable'] as String?,
                  'support-url' => j['supportUrl'] as String?,
                  'profile-web-page-url' => j['webPage'] as String?,
                  'announce' => j['announce'] as String?,
                  _ => null,
                }));
        await _applyFetched(g, fetched, time);
      } catch (_) {
        // a broken cache file is ignored
      }
    }
    _save();
    notifyListeners();
  }

  /// The subscription the servers all come from, if there is exactly one.
  ServerGroup? subscriptionOf(List<ProxyConfig> servers) {
    ServerGroup? found;
    for (final c in servers) {
      final g = subscriptions.where((g) => g.configs.contains(c)).firstOrNull;
      if (g == null || (found != null && found != g)) return null;
      found = g;
    }
    return found;
  }

  /// The provider's routing rules to apply when connecting with [servers]: only when the
  /// subscription has them, the provider allows them and the user has not turned them off.
  ProviderRouting? routingFor(List<ProxyConfig> servers) {
    final g = subscriptionOf(servers);
    if (g == null || !g.routingOn || !g.routingByProvider) return null;
    final r = g.routing;
    return r == null || r.isEmpty ? null : r;
  }

  /// Sets the hours between two downloads of [g] (null: take the provider's value again, or the
  /// app's when the provider sets none). The value stays through updates.
  void setSubscriptionInterval(ServerGroup g, int? hours) {
    g.customInterval = hours?.clamp(1, 24 * 30);
    _writeServers();
    notifyListeners();
  }

  void setSubscriptionRouting(ServerGroup g, bool on) {
    g.routingOn = on;
    _writeServers();
    notifyListeners();
    reconnectIfConnected();
  }

  /// How long a subscription may go without a download: its own interval, else the app's.
  Duration intervalOf(ServerGroup g) => Duration(hours: g.intervalHours ?? subInterval);

  bool isDue(ServerGroup g, [DateTime? now]) =>
      (now ?? DateTime.now()).millisecondsSinceEpoch - g.updatedAt >= intervalOf(g).inMilliseconds;

  /// Downloads the subscriptions whose time has come (each has its own interval).
  Future<void> _updateDueSubscriptions() async {
    for (final g in List.of(subscriptions)) {
      // A list that failed or came back empty is not asked for again for an hour.
      final tried = _lastAttempt[g.id] ?? 0;
      final waited = DateTime.now().millisecondsSinceEpoch - tried;
      if (isDue(g) && !refreshing.contains(g.id) && waited > const Duration(hours: 1).inMilliseconds) {
        await refreshSubscription(g);
      }
    }
  }

  Future<void> _updateSubscriptionsOnStartup() => _updateDueSubscriptions();

  /// After a list was replaced by new objects the chosen server follows to its new copy; if the
  /// list no longer has it, the choice goes back to automatic.
  void _keepSelected() {
    final chosen = selected;
    if (chosen == null || all.contains(chosen)) return;
    selected = all.where((c) => c.key == chosen.key).firstOrNull ??
        // A provider that rotated the credentials or path keeps the server's name and address.
        all
            .where((c) =>
                c.protocol == chosen.protocol &&
                c.host == chosen.host &&
                c.port == chosen.port &&
                c.name == chosen.name)
            .firstOrNull;
  }

  /// Puts a downloaded subscription into [g]. Returns how many configs it has.
  Future<int> _applyFetched(ServerGroup g, Fetched fetched, int time,
      {bool naming = false}) async {
    // The provider's name is only taken when the subscription is added; later updates never
    // rename it.
    final title = fetched.title;
    if (naming && title != null && g.name == Uri.tryParse(g.url ?? '')?.host) {
      g.name = title;
    }
    final links = await extractSubscriptionLinksInBackground(fetched.body);
    final parsed = await parseLinksInBackground(links, shuffle: false);
    // An answer without servers (an error page, an empty list) changes nothing.
    if (parsed.isEmpty) return 0;
    g.info = fetched.info;
    final meta = fetched.meta;
    g.providerInterval = meta.intervalHours;
    g.routing = ProviderRouting.parse(meta.routing);
    g.routingByProvider = meta.routingEnabled;
    g.supportUrl = meta.supportUrl;
    g.webPage = meta.webPage;
    g.announce = meta.announce;
    checkUsage(g);
    // Configs that were already there keep their ping.
    final known = {for (final c in g.configs) c.key: c.latencyMs};
    for (final c in parsed) {
      c.latencyMs = known[c.key];
    }
    g.configs
      ..clear()
      ..addAll(parsed);
    if (known.values.any((v) => v != null)) _sort(g);
    g.updatedAt = time;
    _keepSelected();
    return parsed.length;
  }

  @override
  void dispose() {
    _sub?.cancel();
    _watch?.cancel();
    _trafficSub?.cancel();
    traffic.dispose();
    logRevision.dispose();
    super.dispose();
  }

  bool get _idle =>
      vpn.status == VpnStatus.stopped || vpn.status == VpnStatus.error;

  /// A server can be picked while disconnected, or while connected if the app may
  /// restart the connection for it.
  bool get canSelect => _idle || (connected && restartOnChange);

  Future<void> select(ProxyConfig? config) async {
    if (!canSelect) return;
    selected = identical(selected, config) ? null : config;
    _save();
    notifyListeners();
    if (connected) await _reconnect();
    _syncStandby();
    _warmLookup();
  }

  Timer? _warmTimer;

  /// While disconnected, the names of the servers a connection would use are looked up ahead (over
  /// encrypted DNS, as at a connection) and again before the answer is forgotten, so that a
  /// connection finds them ready instead of waiting for the lookup.
  void _warmLookup([Duration after = const Duration(seconds: 1), bool again = false]) {
    _warmTimer?.cancel();
    if (!net.encryptedLookup || net.strictDns) return;
    if (!again) _warmRounds = 0;
    _warmTimer = Timer(after, () async {
      if (!_idle || _preparing || all.isEmpty) return;
      try {
        // A group of many servers (the automatic mode) is left to the core: too many names to ask.
        final chosen = _chosenServers();
        if (chosen.length <= 5) await _resolveAhead(chosen);
      } catch (e) {
        _logQuiet('Looking the server names up ahead', e);
      }
      // Again before the answers are forgotten, a few times while nothing is asked of the app (a pick,
      // a connection or a disconnect starts it over): an app left open in the tray does not ask for ever.
      if (++_warmRounds < 3) _warmLookup(const Duration(minutes: 9), true);
    });
  }

  var _warmRounds = 0;

  Future<void> _reconnect() async {
    _expectStop = true;
    await VpnChannel.stop();
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (vpn.status != VpnStatus.stopped &&
        vpn.status != VpnStatus.error &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    // Not stopped after all: connecting now would tap a connection that is still going down.
    if (!_idle) {
      log('The connection did not stop in time; it was not restarted');
      return;
    }
    await toggle();
  }

  // ---------------------------------------------------------------- settings

  /// Reads a saved JSON file, or its last good copy when the file itself is damaged. [broken] is
  /// true when the file is there but neither it nor its copy can be read: such a file must not be
  /// written over as if it were new. A file that is not there gives no data and is not broken.
  Future<({Map<String, dynamic>? data, bool broken})> _readJson(String name) async {
    Future<Map<String, dynamic>?> read(String n) async {
      final raw = await VpnChannel.readFile(n);
      if (raw == null) return null;
      final j = jsonDecode(raw);
      if (j is! Map<String, dynamic>) throw const FormatException('not an object');
      return j;
    }

    try {
      return (data: await read(name), broken: false);
    } catch (e) {
      log('$name could not be read: $e');
      try {
        final copy = await read('$name.bak');
        if (copy != null) {
          log('$name was restored from its last good copy');
          return (data: copy, broken: false);
        }
      } catch (_) {}
      return (data: null, broken: true);
    }
  }

  Future<void> _loadSettings() async {
    final read = await _readJson(_settingsFile);
    if (read.broken) {
      _settingsLocked = true;
      _notice('storeUnreadable', {'file': _settingsFile});
      return;
    }
    final j = read.data;
    if (j == null) return;
    try {
      themeMode = ThemeMode.values.firstWhere((m) => m.name == j['theme'],
          orElse: () => ThemeMode.system);
      appIcon = AppIcon.normalize(j['appIcon'] as String?);
      final lang = j['language'] as String?;
      languageCode = S.languageNames.containsKey(lang) ? lang : null;
      bool flag(String k, bool d) => j[k] is bool ? j[k] as bool : d;
      autoUpdateSubs = flag('autoUpdateSubs', true);
      updateOnStartup = flag('updateOnStartup', true);
      updatePrerelease = flag('updatePrerelease', false);
      // Test versions are asked about at each manual check, not kept as a setting.
      includePrerelease = false;
      // A new key: the old "allowInsecure" was on for everybody and is not carried over.
      allowInsecure = flag('subInsecure', false);
      collectorAllowInsecure = flag('collectorInsecure', false);
      collectorSource = j['collectorSource'] is String ? j['collectorSource'] as String : null;
      collector.updatedAt = (j['collectorUpdated'] as num?)?.toInt() ?? 0;
      autoConnect = flag('autoConnect', false);
      restartOnChange = flag('restartOnChange', true);
      confirmDelete = flag('confirmDelete', true);
      batteryAsked = flag('batteryAsked', false);
      starSince = (j['starSince'] as num?)?.toInt() ?? 0;
      starOpens = (j['starOpens'] as num?)?.toInt() ?? 0;
      starAsked = (j['starAsked'] as num?)?.toInt() ?? 0;
      starNext = (j['starNext'] as num?)?.toInt() ?? 0;
      starDone = flag('starDone', false);
      onboarded = flag('onboarded', true);
      homeCountry = j['homeCountry'] is String ? j['homeCountry'] as String : '';
      showCollector = flag('showCollector', true);
      final order = j['groupOrder'];
      if (order is List) groupOrder = order.whereType<String>().toList();
      showSpeed = flag('showSpeed', true);
      showVolume = flag('showVolume', false);
      showName = flag('showName', true);
      idleNotification = flag('idleNotification', true);
      haptics = flag('haptics', true);
      removeDeadChoice = flag('removeDeadChoice', false);
      vpnGateUpdated = (j['vpnGateUpdated'] as num?)?.toInt() ?? 0;
      themeColor = j['themeColor'] == 'system' ? 'system' : 'teal';
      blackTheme = flag('blackTheme', false);
      usageAlerts = flag('usageAlerts', true);
      measurePing = flag('measurePing', true);
      final si = j['subInterval'];
      if (si is int && si >= 1 && si <= 24 * 30) subInterval = si;
      final seen = j['alertSeen'];
      if (seen is Map) {
        for (final e in seen.entries) {
          if (e.value is String && (e.value as String).length == 2) {
            _alertSeen['${e.key}'] = e.value as String;
          }
        }
      }
      final url = j['delayUrl'];
      if (url is String && url.startsWith('http') && url != oldDefaultDelayUrl) {
        delayUrl = url;
      }
      final n = j['net'];
      if (n is Map<String, dynamic>) net.load(n);
    } catch (_) {
      // keep the default
    }
  }

  /// Writes a stored file; a file that could not be read is set aside first (kept as
  /// `<name>.broken`) so that it is not lost.
  Future<void> _store(String name, String data, {required bool locked}) async {
    if (locked) {
      try {
        await VpnChannel.moveAside(name);
      } catch (_) {}
    }
    await VpnChannel.writeFile(name, data);
  }

  void _saveSettings() {
    final locked = _settingsLocked;
    _settingsLocked = false;
    _store(
        _settingsFile,
        jsonEncode({
          'theme': themeMode.name,
          'appIcon': appIcon,
          'language': languageCode,
          'autoUpdateSubs': autoUpdateSubs,
          'updateOnStartup': updateOnStartup,
          'updatePrerelease': updatePrerelease,
          'subInsecure': allowInsecure,
          'collectorInsecure': collectorAllowInsecure,
          'collectorSource': collectorSource,
          'collectorUpdated': collector.updatedAt,
          'autoConnect': autoConnect,
          'restartOnChange': restartOnChange,
          'confirmDelete': confirmDelete,
          'batteryAsked': batteryAsked,
          'starSince': starSince,
          'starOpens': starOpens,
          'starAsked': starAsked,
          'starNext': starNext,
          'starDone': starDone,
          'onboarded': onboarded,
          'homeCountry': homeCountry,
          'showCollector': showCollector,
          'groupOrder': groupOrder,
          'showSpeed': showSpeed,
          'showVolume': showVolume,
          'showName': showName,
          'idleNotification': idleNotification,
          'haptics': haptics,
          'removeDeadChoice': removeDeadChoice,
          'vpnGateUpdated': vpnGateUpdated,
          'themeColor': themeColor,
          'blackTheme': blackTheme,
          'usageAlerts': usageAlerts,
          'measurePing': measurePing,
          'subInterval': subInterval,
          'alertSeen': _alertSeen,
          'delayUrl': delayUrl,
          'net': net.toJson(),
        }),
        locked: locked)
        .catchError((_) {});
    notifyListeners();
  }

  /// Changes one of the switches in Settings.
  /// "Remember my choice" in the question before a real delay test: the next one starts with the same answer.
  void rememberRealDelay(bool removeDead) {
    removeDeadChoice = removeDead;
    _saveSettings();
    notifyListeners();
  }

  void setFlag(String key, bool value) {
    switch (key) {
      case 'autoUpdateSubs':
        autoUpdateSubs = value;
        VpnChannel.scheduleSubUpdates(value).catchError((_) {});
      case 'updateOnStartup':
        updateOnStartup = value;
      case 'updatePrerelease':
        updatePrerelease = value;
        includePrerelease = value;
      case 'allowInsecure':
        allowInsecure = value;
      case 'autoConnect':
        autoConnect = value;
        if (value) _askVpnPermission();
      case 'restartOnChange':
        restartOnChange = value;
      case 'confirmDelete':
        confirmDelete = value;
      case 'showSpeed':
        showSpeed = value;
      case 'showVolume':
        showVolume = value;
      case 'showName':
        showName = value;
      case 'idleNotification':
        idleNotification = value;
        VpnChannel.setIdleNotification(value);
      case 'haptics':
        haptics = value;
        if (value) buzz();
      case 'blackTheme':
        blackTheme = value;
      case 'measurePing':
        measurePing = value;
      case 'usageAlerts':
        usageAlerts = value;
      case 'showCollector':
        showCollector = value;
        if (!value) {
          if (selected != null && !all.contains(selected)) selected = null;
          _save();
        } else if (collector.configs.isEmpty) {
          refreshCollector();
        }
    }
    _saveSettings();
    notifyListeners();
  }

  /// Booting without a stored VPN permission would fail silently, so ask while the user is here.
  Future<void> _askVpnPermission() async {
    if (await VpnChannel.prepare()) return;
    autoConnect = false;
    _saveSettings();
    notifyListeners();
  }

  /// Changes a network option. Options that only apply to a new connection restart a running one.
  Future<void> updateNet(void Function(NetOptions o) change,
      {bool reconnect = true}) async {
    change(net);
    _saveSettings();
    final fetch = _listFetch();
    if ((net.bypass.isNotEmpty || net.blockAds) && fetch != null) {
      // Fetched now, so that the next connection has them (a connection does not wait for lists).
      ensureRuleSets(await VpnChannel.dataDir(), net.bypass,
              ads: net.blockAds,
              adsLevel: net.adsLevel,
              loadBase: _loadAdBase,
              loadBundled: _loadBundledRules,
              fetch: fetch)
          .catchError((Object e) {
        _logQuiet('Fetching the lists', e);
        return <String, String>{};
      });
    }
    if (reconnect && connected) await _reconnect();
    _syncStandby();
  }

  void setDelayUrl(String url) {
    delayUrl = url;
    delayTestUrl = url;
    _saveSettings();
  }

  /// Ends the first-run guide, keeping the chosen language (null = follow the device) and country.
  void finishOnboarding({String? language, String country = ''}) {
    languageCode = language;
    homeCountry = country;
    onboarded = true;
    _saveSettings();
  }

  void markBatteryAsked() {
    batteryAsked = true;
    _saveSettings();
  }

  void setThemeMode(ThemeMode mode) {
    themeMode = mode;
    _saveSettings();
  }

  void setThemeColor(String value) {
    themeColor = value == 'system' ? 'system' : 'teal';
    _saveSettings();
    notifyListeners();
  }

  /// A short vibration, when the setting is on (the phone only). [strong]: for the end of a connection
  /// that was not asked for.
  void buzz({bool strong = false}) {
    if (!haptics || !Platform.isAndroid) return;
    try {
      strong ? HapticFeedback.mediumImpact() : HapticFeedback.lightImpact();
    } catch (_) {}
  }

  Future<void> setAppIcon(String id) async {
    appIcon = AppIcon.normalize(id);
    _saveSettings();
    notifyListeners();
    try {
      await AppIcon.apply(appIcon);
    } catch (_) {}
  }

  void setSubInterval(int hours) {
    subInterval = hours.clamp(1, 24 * 30);
    _saveSettings();
    _writeServers(); // the background job reads the intervals from there
  }

  void setLanguage(String? code) {
    languageCode = code;
    _saveSettings();
  }

  // ---------------------------------------------------------------- storage

  Future<void> _loadServers() async {
    final read = await _readJson(_storeFile);
    if (read.broken) {
      _storeLocked = true;
      _notice('storeUnreadable', {'file': _storeFile});
      return;
    }
    final j = read.data;
    // The WARP server is made before the choice of server is read, so that it can be the chosen one.
    await warp.restoreServer();
    if (j == null) return;
    // One damaged entry must not take the others down with it (the next save would drop them).
    try {
      // Older versions kept one flat list: that was the collector's.
      collector.configs.addAll(await parseLinksOff(
          ((j['collector'] ?? j['links'] ?? const []) as List).cast<String>(),
          secure: !collectorAllowInsecure));
    } catch (e) {
      log('The saved public list was skipped: $e');
    }
    try {
      manual.configs.addAll(await parseLinksOff(((j['manual'] ?? const []) as List).cast<String>()));
    } catch (e) {
      log('The saved manual configs were skipped: $e');
    }
    try {
      cleanGroup.configs.addAll(await parseLinksOff(((j['clean'] ?? const []) as List).cast<String>()));
    } catch (e) {
      log('The saved clean-IP configs were skipped: $e');
    }
    try {
      for (final s in (j['subs'] ?? const []) as List) {
        try {
          final m = s as Map<String, dynamic>;
          final g = ServerGroup(m['id'] as String, GroupKind.subscription,
              name: m['name'] as String? ?? '', url: m['url'] as String?)
            ..autoName = m['auto'] == true
            ..userAgent = cleanUserAgent(m['userAgent'] as String?)
            ..headers = cleanSavedHeaders(m['headers'])
            ..info = SubInfo.fromJson(m['info'])
            ..updatedAt = (m['updatedAt'] as num?)?.toInt() ?? 0
            ..providerInterval = (m['providerInterval'] as num?)?.toInt()
            ..customInterval = (m['customInterval'] as num?)?.toInt()
            ..routing = m['routing'] is Map ? ProviderRouting.fromJson(m['routing'] as Map) : null
            ..routingByProvider = m['routingByProvider'] != false
            ..routingOn = m['routingOn'] != false
            ..supportUrl = m['supportUrl'] as String?
            ..webPage = m['webPage'] as String?
            ..announce = m['announce'] as String?;
          g.configs.addAll(await parseLinksOff((m['links'] as List).cast<String>()));
          subscriptions.add(g);
        } catch (e) {
          log('A saved subscription was skipped: $e');
        }
      }
    } catch (e) {
      log('The saved subscriptions were skipped: $e');
    }
    try {
      final pings = (j['pings'] as Map?) ?? const {};
      for (final c in all) {
        // The key of this version, or the whole link that older versions used.
        final ms = pings[pingKey(c.link)] ?? pings[c.link];
        if (ms is num) c.latencyMs = ms.toInt();
      }
      for (final g in [collector, manual, cleanGroup, ...subscriptions]) {
        if (g.configs.any((c) => c.latencyMs != null)) _sort(g);
      }
      final link = j['selected'] as String?;
      final inGroup = j['selectedGroup'] as String?;
      // The same link can be in two groups: the one that was picked is the one that comes back.
      selected = [
        for (final g in [collector, warpGroup, manual, cleanGroup, ...subscriptions])
          if (g.id == inGroup) ...g.configs,
      ].where((c) => c.link == link).firstOrNull ??
          all.where((c) => c.link == link).firstOrNull;
    } catch (_) {
      // missing or corrupt store: start fresh
    }
  }

  /// Reads the saved settings and servers, as the start of the app does.
  @visibleForTesting
  Future<void> loadStoredForTest() async {
    await _loadSettings();
    await _loadServers();
  }

  @visibleForTesting
  bool get storeLockedForTest => _storeLocked;

  CoreApi? get api => apiPort == null || apiSecret == null
      ? null
      : CoreApi(apiPort!, apiSecret!);

  // ---------------------------------------------------------------- usage

  /// Data used per day ("2026-10-25" -> [down, up, seconds connected]) and per server name
  /// ([down, up, seconds connected, last used in ms since epoch, bytes from before the split]).
  final dayUsage = <String, List<int>>{};
  final serverUsage = <String, List<int>>{};

  /// What went through the free public servers since the start, [down, up]. It is kept apart from the
  /// per-server numbers, which are pruned and renamed with the list.
  final publicUsage = <int>[0, 0];

  /// The same for WARP, [down, up].
  final warpUsage = <int>[0, 0];

  /// Whether the server that carried the traffic is from the public list: the one the user picked, or
  /// (in automatic mode) a server whose name is in that list and in no other.
  bool _isPublic(String name) {
    final pick = selected;
    if (pick != null) return collector.configs.any((c) => identical(c, pick));
    return collector.configs.any((c) => c.name == name) &&
        !manual.configs.any((c) => c.name == name) &&
        !subscriptions.any((g) => g.configs.any((c) => c.name == name));
  }

  /// Whether the server that carried the traffic is the WARP one (see [_isPublic]).
  bool _isWarp(String name) {
    final pick = selected;
    if (pick != null) return warpGroup.configs.any((c) => identical(c, pick));
    return warpGroup.configs.any((c) => c.name == name) &&
        !manual.configs.any((c) => c.name == name) &&
        !collector.configs.any((c) => c.name == name) &&
        !subscriptions.any((g) => g.configs.any((c) => c.name == name));
  }

  /// What a server used in total.
  static int serverTotal(List<int> l) => l[0] + l[1] + (l.length > 4 ? l[4] : 0);

  /// The fastest speed seen since the app started (bytes per second).
  int peakDown = 0, peakUp = 0;
  DateTime? _lastTick;

  /// The last two minutes of speed, one sample a second (bytes per second).
  final downHistory = <int>[];
  final upHistory = <int>[];
  var _lastDown = 0, _lastUp = 0;
  Timer? _usageTimer;
  static const _usageFile = 'usage.json';

  static String _dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// On the phone the VPN service counts the usage by itself while the app's screen is closed (and
  /// the app adds that when it opens), so the first sample after the app starts listening only sets
  /// the starting point: the totals it carries were counted already.
  var _baselined = false;
  var _usageDirty = false;

  /// The most servers whose usage is kept; the ones used longest ago go first.
  static const _maxServers = 300;

  @visibleForTesting
  void onTrafficForTest(Traffic t) => _onTraffic(t);

  void _onTraffic(Traffic t) {
    traffic.value = t;
    var dd = t.downTotal - _lastDown, du = t.upTotal - _lastUp;
    if (dd < 0 || du < 0) {
      dd = t.downTotal;
      du = t.upTotal;
    }
    if (!_baselined && Platform.isAndroid) {
      dd = 0;
      du = 0;
    }
    _baselined = true;
    _lastDown = t.downTotal;
    _lastUp = t.upTotal;
    downHistory.add(t.down);
    upHistory.add(t.up);
    if (t.down > peakDown) peakDown = t.down;
    if (t.up > peakUp) peakUp = t.up;
    if (downHistory.length > 120) {
      downHistory.removeAt(0);
      upHistory.removeAt(0);
    }
    // Time connected: the gap since the last sample (a long gap means the link was off).
    final now = DateTime.now();
    final gap = _lastTick == null ? 1 : now.difference(_lastTick!).inSeconds.clamp(0, 3);
    _lastTick = now;
    final day = dayUsage.putIfAbsent(_dayKey(now), () => [0, 0, 0]);
    day[0] += dd;
    day[1] += du;
    day[2] += gap;
    final name = selected?.name ?? _activeName ?? 'Automatic';
    final s = serverUsage.putIfAbsent(name, () => [0, 0, 0, 0]);
    s[0] += dd;
    s[1] += du;
    s[2] += gap;
    s[3] = now.millisecondsSinceEpoch;
    if (dd > 0 || du > 0) {
      if (_isPublic(name)) {
        publicUsage[0] += dd;
        publicUsage[1] += du;
      } else if (_isWarp(name)) {
        warpUsage[0] += dd;
        warpUsage[1] += du;
      }
    }
    if (serverUsage.length > _maxServers) _pruneServers();
    _usageDirty = true;
    _usageTimer ??= Timer(const Duration(seconds: 30), _writeUsage);
  }

  void _pruneServers() {
    final byLastUse = serverUsage.entries.toList()
      ..sort((a, b) => a.value[3].compareTo(b.value[3]));
    for (final e in byLastUse.take(serverUsage.length - _maxServers)) {
      serverUsage.remove(e.key);
    }
  }

  Future<void> _writeUsage() {
    _usageTimer?.cancel();
    _usageTimer = null;
    _usageDirty = false;
    return VpnChannel.writeFile(
            _usageFile,
            jsonEncode({
              'days': dayUsage,
              'servers': serverUsage,
              'public': publicUsage,
              'warp': warpUsage,
              'peak': [peakDown, peakUp],
            }))
        .catchError((_) {});
  }

  /// Saves the usage now (the app is being left or closed), not at the next half minute.
  Future<void> flushUsage() => _usageDirty ? _writeUsage() : Future.value();

  /// Adds what the phone's VPN service counted while the app's screen was closed.
  Future<void> _mergePendingUsage() async {
    if (!Platform.isAndroid) return;
    try {
      final raw = await VpnChannel.takeUsage();
      if (raw == null) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      List<int> numbers(Object? v, int length) => [
            for (var i = 0; i < length; i++) (v is List && i < v.length) ? (v[i] as num).toInt() : 0,
          ];
      (j['days'] as Map?)?.forEach((k, v) {
        final add = numbers(v, 3);
        final day = dayUsage.putIfAbsent('$k', () => [0, 0, 0]);
        for (var i = 0; i < 3; i++) {
          day[i] += add[i];
        }
      });
      (j['servers'] as Map?)?.forEach((k, v) {
        final add = numbers(v, 4);
        final s = serverUsage.putIfAbsent('$k', () => [0, 0, 0, 0]);
        for (var i = 0; i < 3; i++) {
          s[i] += add[i];
        }
        if (add[3] > s[3]) s[3] = add[3];
        if (_isPublic('$k')) {
          publicUsage[0] += add[0];
          publicUsage[1] += add[1];
        } else if (_isWarp('$k')) {
          warpUsage[0] += add[0];
          warpUsage[1] += add[1];
        }
      });
      _usageDirty = true;
      await _writeUsage();
    } catch (_) {
      // nothing to add
    }
  }

  Future<void> _loadUsage() async {
    final read = await _readJson(_usageFile);
    final j = read.data;
    if (j != null) {
      try {
        final peak = j['peak'];
        if (peak is List && peak.length == 2) {
          peakDown = (peak[0] as num).toInt();
          peakUp = (peak[1] as num).toInt();
        }
        _readUsage(j);
      } catch (_) {
        // no statistics yet
      }
    }
    await _mergePendingUsage();
  }

  void _readUsage(Map<String, dynamic> j) {
    try {
      final pub = j['public'];
      if (pub is List && pub.length == 2) {
        publicUsage[0] = (pub[0] as num).toInt();
        publicUsage[1] = (pub[1] as num).toInt();
      }
      final warpSaved = j['warp'];
      if (warpSaved is List && warpSaved.length == 2) {
        warpUsage[0] = (warpSaved[0] as num).toInt();
        warpUsage[1] = (warpSaved[1] as num).toInt();
      }
      (j['days'] as Map?)?.forEach((k, v) {
        final l = (v as List).map((e) => (e as num).toInt()).toList();
        if (l.length >= 2) dayUsage['$k'] = [l[0], l[1], l.length > 2 ? l[2] : 0];
      });
      (j['servers'] as Map?)?.forEach((k, v) {
        if (v is num) {
          // Saved by an older version: only the total is known.
          serverUsage['$k'] = [0, 0, 0, 0, v.toInt()];
        } else if (v is List) {
          final l = v.map((e) => (e as num).toInt()).toList();
          while (l.length < 4) {
            l.add(0);
          }
          serverUsage['$k'] = l;
        }
      });
      // Keep about a year and a half; older days only make the file longer.
      final old = _dayKey(DateTime.now().subtract(const Duration(days: 550)));
      dayUsage.removeWhere((k, _) => k.compareTo(old) < 0);
    } catch (_) {
      // no statistics yet
    }
  }

  void resetUsage() {
    dayUsage.clear();
    serverUsage.clear();
    publicUsage[0] = publicUsage[1] = 0;
    warpUsage[0] = warpUsage[1] = 0;
    peakDown = peakUp = 0;
    _writeUsage();
    notifyListeners();
  }

  void _listenTraffic() =>
      _trafficSub ??= VpnChannel.traffic.listen(_onTraffic);

  Timer? _saveTimer;

  /// Saves the servers a moment from now: a test that finishes a result every few milliseconds, or a
  /// run of edits, writes the file once, not once each.
  void _save() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), _writeServers);
  }

  /// Writes at once what [_save] was about to write (the app is being left or closed).
  Future<void> flushStore() async {
    if (_saveTimer?.isActive ?? false) {
      _saveTimer!.cancel();
      await _writeServers();
    }
  }

  Future<void> _writeServers() {
    List<String> links(ServerGroup g, [int? limit]) =>
        g.configs.take(limit ?? g.configs.length).map((c) => c.link).toList();
    // Ping results, so they survive closing the app. Under a short key of the link, not the link: the
    // links are in the file already, and each of them twice made it twice as big (and as slow to write).
    Map<String, int> pings(ServerGroup g) => {
          for (final c in g.configs)
            if (c.latencyMs != null) pingKey(c.link): c.latencyMs!,
        };
    final data = jsonEncode({
      'collector': links(collector),
      'manual': links(manual),
      'clean': links(cleanGroup),
      'pings': {
        ...pings(collector),
        ...pings(manual),
        ...pings(cleanGroup),
        for (final g in subscriptions) ...pings(g),
      },
      'subs': [
        for (final g in subscriptions)
          {
            'id': g.id,
            'name': g.name,
            'url': g.url,
            'auto': g.autoName,
            if (g.userAgent != null) 'userAgent': g.userAgent,
            if (g.headers.isNotEmpty) 'headers': g.headers,
            'info': g.info?.toJson(),
            'updatedAt': g.updatedAt,
            'providerInterval': g.providerInterval,
            'customInterval': g.customInterval,
            // the hours the background job waits between two downloads of this one
            'interval': g.intervalHours ?? subInterval,
            'routing': g.routing?.toJson(),
            'routingByProvider': g.routingByProvider,
            'routingOn': g.routingOn,
            'supportUrl': g.supportUrl,
            'webPage': g.webPage,
            'announce': g.announce,
            'links': links(g),
          },
      ],
      'selected': selected?.link,
      'selectedGroup': [collector, warpGroup, manual, cleanGroup, ...subscriptions]
          .where((g) => g.configs.any((c) => identical(c, selected)))
          .firstOrNull
          ?.id,
    });
    final locked = _storeLocked;
    _storeLocked = false;
    return _store(_storeFile, data, locked: locked).catchError((_) {});
  }

  // ---------------------------------------------------------------- helpers

  /// Reachable first, fastest first; untested and dead ones at the end.
  static int _rank(ProxyConfig c) {
    final v = c.latencyMs;
    if (v == null) return 1 << 40;
    return v < 0 ? 1 << 41 : v;
  }

  void _sort(ServerGroup g) =>
      g.configs.sort((a, b) => _rank(a).compareTo(_rank(b)));

  void _merge(ServerGroup g, List<ProxyConfig> items) {
    final keys = g.configs.map((c) => c.key).toSet();
    g.configs.addAll(items.where((c) => keys.add(c.key)));
    _sort(g);
  }

  /// Runs [body] as a job: "busy" stays on until it ends, whatever happens in it.
  Future<void> _job(Message? status, Future<void> Function() body) async {
    _jobs++;
    message = status;
    notifyListeners();
    try {
      await body();
    } finally {
      _jobs--;
      _save();
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------- testing

  /// Tests every config of [g] again, with TCP connects or with real delay.
  /// With [removeDead] the configs that did not answer are deleted afterwards.
  Future<void> ping(ServerGroup g,
      {required bool real, bool removeDead = false}) async {
    if (real && !_real) return;
    final key = 'ping-${g.id}';
    final gen = _begin(key);
    final list = g.configs.toList();
    // The old pings of this list go as the test starts, so the numbers on screen are all new.
    for (final c in list) {
      c.latencyMs = null;
    }
    final done = <ProxyConfig>{};
    _pingRuns[g.id] = (list: list, done: done);
    final test = tests[g.id] = GroupTest(list.length);
    working.add(g.id);
    final clock = Stopwatch()..start();
    var lastTick = 0;
    final gone = <ProxyConfig>{};
    // Dead configs leave and the rest is re-sorted while the test still runs.
    void refresh() {
      if (gone.isNotEmpty) {
        g.configs.removeWhere(gone.contains);
        if (selected != null && gone.contains(selected)) selected = null;
      }
      _sort(g);
      notifyListeners();
    }

    notifyListeners();
    try {
      await _job(null, () async {
        await testReal(
          real: real,
          tcpFirst: g.kind == GroupKind.collector,
          list,
          isCancelled: () => _stale(key, gen),
          onResult: (c) {
            done.add(c);
            test.done++;
            if (c.isAlive) {
              test.alive++;
            } else if (removeDead && c.latencyMs != null) {
              gone.add(c);
            }
            if (clock.elapsedMilliseconds - lastTick > 300) {
              lastTick = clock.elapsedMilliseconds;
              refresh();
            }
          },
        );
        if (_stale(key, gen)) return;
        if (removeDead) {
          log('Removed ${gone.length} configs that did not answer from ${_title(g)}');
        }
        refresh();
        log('Tested ${list.length} servers in ${_title(g)}: ${test.alive} answered');
      });
    } finally {
      test.running = false;
      if (!_stale(key, gen) || identical(tests[g.id], test)) {
        test.done = test.total;
      }
      working.remove(g.id);
      notifyListeners();
    }
  }

  String _title(ServerGroup g) => switch (g.kind) {
        GroupKind.collector => 'Public servers',
        GroupKind.manual => 'Manual configs',
        GroupKind.warp => 'WARP',
        GroupKind.cleanIp => 'Clean IPs',
        GroupKind.subscription => g.name,
      };

  /// Tests one config from its menu.
  Future<void> testOne(ProxyConfig c, {required bool real}) async {
    if (testing.contains(c) || (real && !_real)) return;
    testing.add(c);
    notifyListeners();
    try {
      final ms = real ? await realDelay(c) : await tcpLatency(c);
      if (ms != -2) c.latencyMs = ms;
    } finally {
      testing.remove(c);
      _save();
      notifyListeners();
    }
  }

  bool get canTestReal => _real;

  /// In automatic mode: the answering server with the lowest ping, which is the one
  /// the automatic group starts with.
  ProxyConfig? get autoPick {
    ProxyConfig? best;
    for (final c in all) {
      if (!c.canSingBox || !c.isAlive) continue;
      if (best == null || c.latencyMs! < best.latencyMs!) best = c;
    }
    return best;
  }

  // ---------------------------------------------------------------- collector

  /// Downloads a fresh public list. Nothing is tested: the user pings when they want.
  Future<void> refreshCollector() async {
    const key = 'collector';
    final gen = _begin(key);
    working.add(collector.id);
    refreshing.add(collector.id);
    final cancel = _cancels[key] = Completer<void>();
    await _job((t) => t.fetchingList, () async {
      try {
        final result = await Future.any(<Future<FetchResult?>>[
          fetchCollectorLists(),
          cancel.future.then((_) => null),
        ]);
        if (result == null || _stale(key, gen)) return;
        final parsed =
            await parseLinksInBackground(result.links, secure: !collectorAllowInsecure);
        if (_stale(key, gen)) return;
        final fresh = parsed.toList();
        collector.configs
          ..clear()
          ..addAll(fresh);
        collectorSource = result.source;
        collector.updatedAt = DateTime.now().millisecondsSinceEpoch;
        _saveSettings();
        _keepSelected();
        message = (t) => t.listLoaded(fresh.length);
      } on AllSourcesFailed {
        message = (t) => t.allSourcesFailed;
      } catch (e) {
        message = (t) => t.fetchFailed(e);
      }
    });
    if (!_stale(key, gen)) {
      working.remove(collector.id);
      refreshing.remove(collector.id);
    }
    tests.remove(collector.id);
    notifyListeners();
  }
  /// Whether servers of the public list may skip the check of their TLS certificate. Off by
  /// default; changing it parses the saved list again (the pings stay).
  Future<void> setCollectorInsecure(bool allow) async {
    if (collectorAllowInsecure == allow) return;
    collectorAllowInsecure = allow;
    final pings = {for (final c in collector.configs) c.link: c.latencyMs};
    final chosen = selected?.link;
    final wasSelected = collector.configs.any((c) => identical(c, selected));
    final again = await parseLinksInBackground(
        [for (final c in collector.configs) c.link],
        shuffle: false, secure: !allow);
    for (final c in again) {
      c.latencyMs = pings[c.link];
    }
    collector.configs
      ..clear()
      ..addAll(again);
    if (wasSelected) selected = again.where((c) => c.link == chosen).firstOrNull;
    _saveSettings();
    _save();
    notifyListeners();
    if (connected && wasSelected) await _reconnect();
    _syncStandby();
  }

  /// How many servers of the public list ask for their certificate not to be checked.
  int get collectorInsecureCount =>
      collector.configs.where((c) => asksInsecure(c.link)).length;

  // ---------------------------------------------------------------- subscriptions

  Future<void> refreshSubscription(ServerGroup g, {bool naming = false}) async {
    if (g.url == null) return;
    _lastAttempt[g.id] = DateTime.now().millisecondsSinceEpoch;
    final key = 'sub-${g.id}';
    final gen = _begin(key);
    working.add(g.id);
    refreshing.add(g.id);
    final cancel = _cancels[key] = Completer<void>();
    await _job((t) => t.fetchingList, () async {
      try {
        final fetched = await Future.any(<Future<Fetched?>>[
          fetchSubscription(g.url!,
              allowInsecure: allowInsecure,
              lookupName: naming,
              userAgent: g.userAgent,
              headers: g.headers),
          cancel.future.then((_) => null),
        ]);
        if (fetched == null || _stale(key, gen)) return;
        final n = await _applyFetched(
            g, fetched, DateTime.now().millisecondsSinceEpoch, naming: naming);
        message =
            n == 0 ? (t) => t.noValidConfig : (t) => t.subscriptionUpdated(n);
      } catch (e) {
        message = (t) => t.fetchFailed(e);
        // The certificate did not check out: say where the switch for such servers is.
        if (e is HandshakeException && !allowInsecure) _notice('subCertError', {'name': g.name});
      }
    });
    if (!_stale(key, gen)) {
      working.remove(g.id);
      refreshing.remove(g.id);
    }
    notifyListeners();
  }

  /// Stops the download of a group's list; whatever it brings back is dropped.
  void cancelRefresh(ServerGroup g) {
    final key = g.kind == GroupKind.collector ? 'collector' : 'sub-${g.id}';
    _begin(key);
    _cancels.remove(key)?.complete();
    working.remove(g.id);
    refreshing.remove(g.id);
    message = null;
    notifyListeners();
  }

  Future<void> editSubscription(ServerGroup g, String name, String url,
      {String? userAgent, Map<String, String> headers = const {}}) async {
    final ua = cleanUserAgent(userAgent);
    final changed = g.url != url || g.userAgent != ua || !_sameHeaders(g.headers, headers);
    if (name != g.name) g.autoName = false;
    g.name = name;
    g.url = url;
    g.userAgent = ua;
    g.headers = Map.unmodifiable(headers);
    _save();
    notifyListeners();
    if (changed) await refreshSubscription(g);
  }

  static bool _sameHeaders(Map<String, String> a, Map<String, String> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  void removeSubscription(ServerGroup g) {
    // A download that is still going must not bring the list back, and the copy the background job
    // left for it goes too.
    cancelRefresh(g);
    _lastAttempt.remove(g.id);
    for (final name in ['subcache/${g.id}.json', 'subcache/${g.id}.json.bak']) {
      VpnChannel.deleteFile(name).catchError((_) {});
    }
    subscriptions.remove(g);
    if (selected != null && !all.contains(selected)) selected = null;
    _save();
    notifyListeners();
  }

  // ---------------------------------------------------------------- configs

  /// Replaces [old] by the config in [newLink]. Returns false if the link is not valid.
  Future<bool> editConfig(
      ServerGroup g, ProxyConfig old, String newLink) async {
    final updated = parseLink(newLink.trim());
    if (updated == null) return false;
    final i = g.configs.indexOf(old);
    if (i < 0) return false;
    // A server that is already in the list is not added a second time (two rows with the same
    // link would also share one key in the list).
    final same = g.configs.where((c) => !identical(c, old) && c.key == updated.key).firstOrNull;
    if (same != null) {
      g.configs.removeAt(i);
      if (identical(selected, old)) selected = same;
    } else {
      g.configs[i] = updated;
      if (identical(selected, old)) selected = updated;
    }
    _save();
    notifyListeners();
    return true;
  }

  /// Puts [config] in the WARP group (null empties it). The choice is kept when the server it replaces
  /// was the chosen one, and [choose] makes it the chosen one.
  void setWarpServer(ProxyConfig? config, {bool choose = false}) {
    final old = warpGroup.configs.firstOrNull;
    final wasChosen = old != null && identical(selected, old);
    warpGroup.configs.clear();
    if (config == null) {
      if (wasChosen) selected = null;
    } else {
      warpGroup.configs.add(config);
      if (choose || wasChosen) selected = config;
    }
    _save();
    notifyListeners();
  }

  /// Puts the WARP server in its group at the start of the app. A copy that an earlier version kept
  /// among the configs added by hand is taken out of there (and the choice moves to the new one).
  void restoreWarpServer(ProxyConfig config) {
    var changed = false;
    if (warpGroup.configs.isEmpty) warpGroup.configs.add(config);
    final shown = warpGroup.configs.first;
    for (final old in manual.configs.where((c) => c.link == config.link).toList()) {
      if (identical(selected, old)) selected = shown;
      manual.configs.remove(old);
      changed = true;
    }
    if (changed) _save();
  }

  /// True while the VPN Gate list is being downloaded.
  final vpnGateBusy = ValueNotifier<bool>(false);

  /// Downloads the VPN Gate list (OpenVPN servers) and puts it among the servers added by hand, in
  /// place of an earlier copy of it (the server that is chosen stays). Returns how many were added.
  Future<int> addVpnGate() async {
    vpnGateBusy.value = true;
    try {
      final parsed = parseLinks(await fetchVpnGate()).where((c) => c.isOpenVpn).toList();
      if (parsed.isEmpty) return 0;
      vpnGateUpdated = DateTime.now().millisecondsSinceEpoch;
      _saveSettings();
      manual.configs.removeWhere((c) => c.isOpenVpn && c.name.contains(vpnGateMark) && !identical(c, selected));
      _merge(manual, parsed);
      _save();
      notifyListeners();
      return parsed.length;
    } finally {
      vpnGateBusy.value = false;
    }
  }

  /// Puts the configs of [links] in the clean-IP group, in place of an earlier scan's (the server that is
  /// chosen stays). Returns how many were added.
  int addCleanIps(List<String> links) {
    final parsed = parseLinks(links);
    if (parsed.isEmpty) return 0;
    cleanGroup.configs.removeWhere((c) => !identical(c, selected));
    _merge(cleanGroup, parsed);
    _save();
    notifyListeners();
    return parsed.length;
  }

  /// Removes the configs of the clean-IP group.
  List<RemovedConfig> clearCleanIps() {
    if (tests[cleanGroup.id]?.running ?? false) cancelPing(cleanGroup);
    final removed = removeConfigs([for (final c in cleanGroup.configs.toList()) (group: cleanGroup, config: c)]);
    log('Removed ${removed.length} clean-IP configs');
    return removed;
  }

  /// Removes every config that was added by hand.
  /// What was removed is returned, for [restoreConfigs] (the Undo button).
  List<RemovedConfig> clearManual() {
    if (tests[manual.id]?.running ?? false) cancelPing(manual);
    final removed = removeConfigs([for (final c in manual.configs.toList()) (group: manual, config: c)]);
    log('Removed all ${removed.length} configs added manually');
    return removed;
  }

  void removeConfig(ServerGroup g, ProxyConfig c) {
    g.configs.remove(c);
    if (selected == c) selected = null;
    _save();
    notifyListeners();
  }

  /// Takes [items] out of their groups and says where each was, for [restoreConfigs].
  List<RemovedConfig> removeConfigs(Iterable<({ServerGroup group, ProxyConfig config})> items) {
    final out = <RemovedConfig>[];
    for (final it in items) {
      final at = it.group.configs.indexOf(it.config);
      if (at < 0) continue;
      it.group.configs.removeAt(at);
      final wasSelected = identical(selected, it.config);
      if (wasSelected) selected = null;
      out.add((group: it.group, config: it.config, index: at, wasSelected: wasSelected));
    }
    if (out.isNotEmpty) {
      _save();
      notifyListeners();
    }
    return out;
  }

  /// Puts back what [removeConfigs] took out, each where it was.
  void restoreConfigs(List<RemovedConfig> removed) {
    for (final r in removed.reversed) {
      final list = r.group.configs;
      if (list.contains(r.config)) continue;
      list.insert(r.index.clamp(0, list.length), r.config);
      if (r.wasSelected && selected == null) selected = r.config;
    }
    _save();
    notifyListeners();
  }

  /// Puts back a subscription removed with [removeSubscription], at [index] among them. (What the
  /// background job had kept of it is gone: the next update brings it back.)
  void restoreSubscription(ServerGroup g, int index) {
    if (subscriptions.contains(g)) return;
    subscriptions.insert(index.clamp(0, subscriptions.length), g);
    _save();
    notifyListeners();
  }

  /// Adds pasted or scanned text: a subscription URL, or one or more share links.
  /// Works while other downloads or tests are running.
  /// Returns a subscription that was just added and whose provider gave it no name,
  /// so the screen can ask the user for one.
  Future<ServerGroup?> importText(String text) async {
    var input = text.trim();
    if (input.isEmpty) return null;
    // Links other clients hand out (clash://install-config?url=..., hiddify://import/..., sub://...)
    // hold the real address and sometimes a name.
    final deep = subscriptionDeepLink(input.split(RegExp(r'\s')).first);
    if (deep != null) input = deep.url;
    final typed = input.split(RegExp(r'\s')).first;
    if (typed.startsWith('http://') || typed.startsWith('https://')) {
      // A #name at the end of the address is the name the user wants for the subscription (and
      // is not part of the address that is downloaded).
      final hash = typed.indexOf('#');
      final first = hash < 0 ? typed : typed.substring(0, hash);
      String? fragment;
      if (hash >= 0 && hash + 1 < typed.length) {
        try {
          fragment = Uri.decodeComponent(typed.substring(hash + 1)).trim();
        } catch (_) {
          fragment = typed.substring(hash + 1).trim();
        }
        if (fragment.isEmpty) fragment = null;
      }
      var g = subscriptions.where((s) => s.url == first).firstOrNull;
      final isNew = g == null;
      // Without https the list of servers can be read, or changed, by anyone on the way.
      if (isNew && first.startsWith('http://')) _notice('subHttp', {'name': Uri.tryParse(first)?.host ?? first});
      if (g == null) {
        g = ServerGroup('sub-${DateTime.now().microsecondsSinceEpoch}',
            GroupKind.subscription,
            name: fragment ?? deep?.name ?? Uri.tryParse(first)?.host ?? first, url: first)
          ..autoName = false;
        subscriptions.add(g);
      }
      await refreshSubscription(g, naming: isNew);
      // A new subscription always goes to the screen, which asks for its name (the name the
      // provider or the link gave is filled in; empty when there was none).
      return isNew && g.configs.isNotEmpty ? g : null;
    }
    await _job((t) => t.adding, () async {
      try {
        final parsed =
            parseLinks(await extractSubscriptionLinksInBackground(input));
        if (parsed.isEmpty) {
          message = (t) => t.noValidConfig;
          return;
        }
        _merge(manual, parsed);
        final n = parsed.length;
        message = (t) => t.addedConfigs(n);
      } catch (e) {
        message = (t) => t.importFailed(e);
      }
    });
    return null;
  }

  void renameSubscription(ServerGroup g, String name) {
    final n = name.trim();
    if (n.isEmpty) return;
    g.name = n;
    g.autoName = false;
    _save();
    notifyListeners();
  }

  // ---------------------------------------------------------------- OpenVPN

  OvpnRunner? _ovpn;

  /// Set when the chosen OpenVPN server needs a user name and password: the home screen asks for them.
  final ovpnLoginRequest = ValueNotifier<ProxyConfig?>(null);

  /// Starts OpenVPN for [c] and returns the name of its adapter, which sing-box sends through. Null when
  /// it could not (the user is told why).
  Future<String?> _startOpenVpn(ProxyConfig c, bool Function() cancelled) async {
    if (!Platform.isWindows) {
      _notice('ovpnUnsupported');
      return null;
    }
    final dir = DesktopVpn.instance.openvpnDir;
    final runner = _ovpn ??= OvpnRunner(
      binary: '$dir\\openvpn.exe',
      tapctl: '$dir\\tapctl.exe',
      workDir: await VpnChannel.dataDir(),
      driverDir: '$dir\\driver',
    );
    runner.onInstallingDriver = () => _notice('ovpnInstallingDriver');
    runner.onLost = (why) {
      // The program ended or was killed while connected: the tunnel is no use any more.
      if (connected) {
        _notice('ovpnLost');
        VpnChannel.stop();
      }
    };
    _ovpnStarting = true;
    try {
      return await runner.start(c.ovpn!);
    } on OvpnConnectException catch (e) {
      log('OpenVPN: $e');
      // The user stopped it while it was starting: nothing to tell.
      if (cancelled()) return null;
      switch (e.failure) {
        case OvpnFailure.noBinary:
          _notice('ovpnNoBinary', {'detail': e.detail});
        case OvpnFailure.noDriver:
          _notice('ovpnNoDriver', {'detail': _short(e.detail)});
        case OvpnFailure.needsLogin || OvpnFailure.needsKeyPassword:
          _notice(e.failure == OvpnFailure.needsLogin ? 'ovpnNeedsLogin' : 'ovpnNeedsKey');
          ovpnLoginRequest.value = c;
        case OvpnFailure.authFailed:
          _notice('ovpnAuthFailed');
          ovpnLoginRequest.value = c;
        case OvpnFailure.timeout:
          // The server answered (its first packet came) but the secure handshake never ended: the usual
          // sign of a network that cuts OpenVPN.
          if (e.detail.contains('TLS: Initial packet') && !e.detail.contains('Peer Connection Initiated')) {
            _notice('ovpnHandshake');
          } else {
            _notice('ovpnTimeout', {'detail': _short(e.detail.split('\n').reversed.take(3).toList().reversed.join('\n'))});
          }
        case OvpnFailure.exited:
          _notice('ovpnExited', {'detail': _short(e.detail.split('\n').reversed.take(3).toList().reversed.join('\n'))});
        case OvpnFailure.unsupported:
          _notice('ovpnUnsupported');
      }
      return null;
    } finally {
      _ovpnStarting = false;
    }
  }

  /// Android: starts the OpenVPN service for [c]. It reports its state like the sing-box service does.
  Future<void> _startOpenVpnAndroid(ProxyConfig c) async {
    final s = c.ovpn!;
    if (s.needsLogin || s.needsKeyPassword) {
      _notice(s.needsLogin ? 'ovpnNeedsLogin' : 'ovpnNeedsKey');
      ovpnLoginRequest.value = c;
      _show(VpnStatus.stopped);
      return;
    }
    try {
      await VpnChannel.startOpenVpn(
        config: withLogin(s),
        username: s.username,
        password: s.password,
        keyPassword: s.keyPassword,
        name: c.name,
        showSpeed: showSpeed,
        showVolume: showVolume,
        showName: showName,
        killSwitch: net.killSwitch,
        include: net.appMode == AppMode.only ? net.apps : const [],
        exclude: net.appMode == AppMode.except ? net.apps : const [],
      );
    } catch (e) {
      log('OpenVPN: $e');
      _notice('ovpnExited', {'detail': _short('$e')});
      _show(VpnStatus.stopped);
    }
  }

  /// The service's own words for why OpenVPN ended (`ovpn:kind|detail`): the user is told, and the text
  /// for the line under the status is returned.
  String _ovpnFailed(String error) {
    final parts = error.substring('ovpn:'.length).split('|');
    final blocked = parts.length > 1 && parts.last == 'blocked';
    if (blocked) parts.removeLast();
    final kind = parts.first;
    final detail = _short(parts.skip(1).join('\n'));
    switch (kind) {
      case 'auth':
        _notice('ovpnAuthFailed');
        if (selected?.isOpenVpn ?? false) ovpnLoginRequest.value = selected;
      case 'handshake':
        _notice('ovpnHandshake');
      case 'timeout':
        _notice('ovpnTimeout', {'detail': detail});
      case 'nobinary':
        _notice('ovpnNoBinary', {'detail': 'libopenvpn.so'});
      case 'permission':
        message = (t) => t.vpnPermissionDenied;
      default:
        _notice('ovpnExited', {'detail': detail});
    }
    return detail.isEmpty ? kind : '$kind: $detail';
  }

  /// True while OpenVPN is being started (the tap that stops a connection must stop that too).
  bool _ovpnStarting = false;

  /// The first lines of what a program said, on one line (for a notice).
  static String _short(String text) {
    final lines = text.split(RegExp(r'\r?\n')).map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    final one = lines.take(3).join(' | ');
    return one.length > 200 ? '${one.substring(0, 200)}...' : one;
  }

  /// Ends the OpenVPN program, if one runs (also when the app is closed).
  Future<void> stopOpenVpn() async {
    final r = _ovpn;
    if (r != null) await r.stop();
  }

  /// Gives an OpenVPN server its login: the link of the server is written again with it.
  Future<void> setOvpnLogin(ProxyConfig c, {String? username, String? password, String? keyPassword}) async {
    final server = c.ovpn;
    if (server == null) return;
    final link = ovpnLink(server.profile,
        username: username ?? server.username,
        password: password ?? server.password,
        keyPassword: keyPassword ?? server.keyPassword,
        name: c.name);
    final group = groups.where((g) => g.configs.contains(c)).firstOrNull;
    if (group != null) await editConfig(group, c, link);
  }
  // ---------------------------------------------------------------- vpn

  /// True from the tap until the start request reached the service.
  bool _preparing = false;
  var _startId = 0;

  void _show(VpnStatus s) {
    vpn = VpnState(s);
    notifyListeners();
  }

  /// When the disconnect was asked for (for the time it took, in the log).
  DateTime? _stopAsked;

  /// The connection is shown as ended without the program having said so (see [_settleStop]): the
  /// reason is noted as for any other end, so that it is in the log and the next end of a connection is
  /// not taken for this one's. When the program does say it later, the state is already the same and
  /// nothing is noted twice.
  void _showEnded(VpnState s) {
    _noteDisconnect(s);
    _show(s.status);
    _warmLookup(const Duration(seconds: 3));
  }

  /// After [after], a screen still on "Disconnecting..." takes the state the VPN really has: on the
  /// desktop the stop has done all it waits for by then; on Android the service is asked.
  void _settleStop(Duration after) {
    final asked = _stopAsked;
    Timer(after, () async {
      if (vpn.status != VpnStatus.stopping || _stopAsked != asked) return;
      if (isDesktop) {
        _showEnded(const VpnState(VpnStatus.stopped));
        return;
      }
      final real = await VpnChannel.currentStatus();
      if (vpn.status != VpnStatus.stopping || _stopAsked != asked) return;
      if (real == VpnStatus.stopped || real == VpnStatus.error) _showEnded(VpnState(real!));
    });
  }

  /// The server(s) a connection would use: the picked one, or in automatic mode the fastest few.
  /// Automatic mode only groups sing-box servers; the ones only Xray can carry (XHTTP, mKCP ...)
  /// need their own Xray process, so they are used when picked by hand (or when nothing else is
  /// available).
  List<ProxyConfig> _chosenServers() {
    final plain = all.where((c) => c.canSingBox).toList();
    final alive = plain.where((c) => c.isAlive).toList()
      ..sort((a, b) => _rank(a).compareTo(_rank(b)));
    final auto = (alive.isNotEmpty ? alive : plain).take(_autoGroupSize).toList();
    return selected != null ? [selected!] : (auto.isNotEmpty ? auto : [all.first]);
  }

  // ---------------------------------------------------------------- standby proxy

  Timer? _standbyTimer;

  /// Whether the standby proxy (the local proxy kept up while the VPN is off) is running.
  bool get standbyUp => isDesktop ? DesktopVpn.instance.standby.value : vpn.standby;

  /// Brings the standby proxy in line with the setting and the connection state, a moment after
  /// the last change (a reconnect passes through "stopped" for a short while).
  void _syncStandby([Duration wait = const Duration(milliseconds: 800), bool force = true]) {
    _standbyTimer?.cancel();
    _standbyTimer = Timer(wait, () {
      // The phone's service starts the proxy by itself when the tunnel stops.
      if (!force && !isDesktop && standbyUp) return;
      _applyStandby();
    });
  }

  // What the standby core was started for: its servers, and a key of everything that shapes its
  // configuration. While they still fit, the core is left alone (restarting it would cut the
  // programs that use it), and a connection can even be made of it.
  String? _standbyKey;
  List<ProxyConfig>? _standbyChosen;
  int? _standbyXrayPort;
  int _standbyApi = 0;
  XrayAuth? _standbyXrayAuth;
  String? _standbySecret;

  String _standbyKeyOf(List<ProxyConfig> chosen, ProviderRouting? routing) {
    final o = NetOptions()
      ..load(net.toJson())
      ..tun = false
      ..killSwitch = false;
    return jsonEncode([for (final c in chosen) '${c.outbound}', o.toJson(), routing?.toJson()]);
  }

  /// The servers the standby core runs, when it is up and they are all still in the lists.
  List<ProxyConfig>? get _standbyServers {
    final c = _standbyChosen;
    if (!isDesktop || !standbyUp || c == null || !c.every(all.contains)) return null;
    return c;
  }

  Future<void> _applyStandby() async {
    if (!net.keepProxy) {
      await VpnChannel.stopStandby();
      await VpnChannel.releaseProxy();
      return;
    }
    // On the phone the service gives the proxy up by itself when a tunnel starts; on the desktop
    // the standby core stays up while connected.
    if (!_idle || _preparing || all.isEmpty) return;
    try {
      // In automatic mode the servers the core already runs are kept, so the order of the latest
      // pings does not restart it.
      final chosen = selected == null ? (_standbyServers ?? _chosenServers()) : _chosenServers();
      if (chosen.any((c) => c.isOpenVpn)) {
        await VpnChannel.stopStandby();
        return;
      }
      final routing = routingFor(chosen);
      final key = _standbyKeyOf(chosen, routing);
      if (isDesktop && standbyUp && key == _standbyKey) return;
      final tags = routing?.ruleSetTags ?? const <String>[];
      final sets = net.bypass.isNotEmpty || net.blockAds || tags.isNotEmpty
          ? await ensureRuleSets(await VpnChannel.dataDir(), net.bypass,
              ads: net.blockAds,
              adsLevel: net.adsLevel,
              loadBase: _loadAdBase,
              loadBundled: _loadBundledRules,
              tags: tags,
              wait: false,
              refresh: false)
          : <String, String>{};
      final viaXray = chosen.length == 1 &&
          chosen.first.canXray &&
          (chosen.first.needsXray || chosen.first.preferXray || net.core == 'xray');
      final xrayPort = viaXray ? 30000 + Random().nextInt(30000) : null;
      final parts = _standbyParts(chosen, routing, sets, xrayPort, resolved: await _resolveAhead(chosen));
      // Something changed while this was being prepared.
      if (!net.keepProxy || !_idle || _preparing) return;
      final ok = await VpnChannel.startStandby(parts.config,
          xrayConfig: parts.xrayConfig,
          xrayPort: xrayPort,
          apiPort: parts.api,
          apiSecret: parts.secret,
          proxyPort: net.proxyPort);
      if (ok) {
        _standbyKey = key;
        _standbyChosen = chosen;
        _standbyXrayPort = xrayPort;
        _standbyXrayAuth = parts.xrayAuth;
        _standbyApi = parts.api;
        _standbySecret = parts.secret;
      } else {
        log('The proxy could not be kept running');
      }
    } catch (e) {
      log('The proxy could not be kept running: $e');
    }
  }
  final _nameResolver = NameResolver();

  /// The ad list built into the app (see core/ad_lists.dart).
  static Future<Uint8List?> _loadAdBase() async {
    try {
      final data = await rootBundle.load(adBaseAsset);
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (_) {
      return null;
    }
  }

  /// The country list the app carries for [tag] (assets/rules), null when it carries none.
  static Future<Uint8List?> _loadBundledRules(String tag) async {
    if (!RegExp(r'^[a-z0-9-]+$').hasMatch(tag)) return null;
    try {
      final data = await rootBundle.load('assets/rules/$tag.srs');
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (_) {
      return null;
    }
  }

  /// The rule-set lists of the connection now (the subscription's routing asks for some).
  List<String> _connectedTags = const [];
  Timer? _listsTimer;

  /// How the lists are fetched now (Settings > Network > Download the lists), or null when the setting
  /// is "only through the connection" and none is up.
  ///
  /// Through the connection means: where the app's own traffic goes by itself (inside the tunnel on
  /// the phone, and on a computer with the tunnel mode) a plain download is enough. Where it does not,
  /// the download is handed to the connection: Xray's SOCKS port on the phone (with Xray the app is
  /// kept out of the tunnel), the local proxy on a computer in the proxy mode.
  ListFetch? _listFetch() {
    final route = net.listsRoute;
    if (route == 'direct') return fetchDirect;
    if (!connected) return route == 'tunnel' ? null : fetchDirect;
    if (Platform.isAndroid) {
      final port = _xrayPort;
      return port == null ? fetchDirect : fetchViaSocks(port, auth: _xrayAuth);
    }
    if (net.tun) return fetchDirect;
    // A local proxy with a login is not asked: its answer would be "login needed".
    if (net.proxyUser.isNotEmpty && net.proxyPassword.isNotEmpty) return fetchDirect;
    return fetchViaProxy(net.proxyPort);
  }

  /// How the speed test reaches the internet now: straight when no VPN is up (the speed of the network
  /// itself), and through the connection when one is (see [_listFetch] for the three ways). Null where the
  /// connection cannot be used for it: a local proxy with a login, which a plain request does not pass.
  SpeedRoute? speedRoute() {
    if (!connected) return const SpeedRoute();
    if (Platform.isAndroid) {
      final port = _xrayPort;
      return port == null ? const SpeedRoute(viaVpn: true) : SpeedRoute(viaVpn: true, socksPort: port, auth: _xrayAuth);
    }
    if (net.tun) return const SpeedRoute(viaVpn: true);
    if (net.proxyUser.isNotEmpty && net.proxyPassword.isNotEmpty) return null;
    return SpeedRoute(viaVpn: true, proxyPort: net.proxyPort);
  }

  /// A line in the log for something that failed and went on (the places that used to say nothing).
  void _logQuiet(String where, Object error) => log('$where: $error');

  /// A while after a connection is up, the lists are fetched again where they are old or missing
  /// (through the tunnel, so a filter on the way does not stop it), and the big ones are made binary
  /// for the next connection. The connection itself never waits for any of this.
  void _refreshListsSoon() {
    _listsTimer?.cancel();
    if (net.bypass.isEmpty && !net.blockAds && _connectedTags.isEmpty) return;
    _listsTimer = Timer(const Duration(seconds: 8), () async {
      if (!connected) return;
      final fetch = _listFetch();
      if (fetch == null) return;
      try {
        final dir = await VpnChannel.dataDir();
        await ensureRuleSets(dir, net.bypass,
            ads: net.blockAds,
            adsLevel: net.adsLevel,
            tags: _connectedTags,
            loadBase: _loadAdBase,
            loadBundled: _loadBundledRules,
            fetch: fetch,
            limit: const Duration(minutes: 5));
        await compileRuleSets(dir, VpnChannel.compileRuleSet);
        await cleanRuleSets(dir, net.bypass, ads: net.blockAds, adsLevel: net.adsLevel, tags: _connectedTags);
      } catch (e) {
        _logQuiet('Refreshing the lists', e);
      }
    });
  }

  /// Fetches the ad lists again now (Settings > Update now). True when the main list is there after.
  /// False too when the setting says "only through the connection" and none is up ([listsNeedConnection]).
  Future<bool> refreshAdLists() async {
    final fetch = _listFetch();
    if (fetch == null) return false;
    final dir = await VpnChannel.dataDir();
    final found = await ensureRuleSets(dir, const [],
        ads: true,
        adsLevel: net.adsLevel,
        loadBase: _loadAdBase,
        fetch: fetch,
        force: true,
        limit: const Duration(minutes: 3));
    notifyListeners();
    compileRuleSets(dir, VpnChannel.compileRuleSet).catchError((Object e) {
      _logQuiet('Making the lists binary', e);
      return 0;
    });
    return found.containsKey(mainAdTag(net.adsLevel));
  }

  /// True when the lists cannot be fetched now because the setting wants the connection and none is up.
  bool get listsNeedConnection => net.listsRoute == 'tunnel' && !connected;

  /// [chosen] with the names of the servers already looked up over encrypted DNS (and by the system's
  /// resolver when that does not answer), or [chosen] itself when that is off or not possible.
  Future<List<ProxyConfig>> _resolveAhead(List<ProxyConfig> chosen) async {
    if (!net.encryptedLookup || net.strictDns) return chosen;
    try {
      return await resolveServers(chosen, _nameResolver);
    } catch (_) {
      return chosen;
    }
  }

  /// The configuration of the proxy that stays up without the tunnel: the same options without
  /// the tunnel, the kill switch and the system proxy, with the login when one is set.
  ({String config, String? xrayConfig, int api, String secret, XrayAuth? xrayAuth}) _standbyParts(List<ProxyConfig> chosen,
      ProviderRouting? routing, Map<String, String> sets, int? xrayPort,
      {List<ProxyConfig>? resolved}) {
    final o = NetOptions()
      ..load(net.toJson())
      ..tun = false
      ..killSwitch = false;
    final chain = o.chain.isEmpty ? null : parseLink(o.chain);
    final viaXray = xrayPort != null;
    // The port of the control API is only used on the desktop; any free one will do.
    final api = 20000 + Random().nextInt(20000);
    final secret = _randomSecret();
    final xrayAuth = viaXray ? _newXrayAuth() : null;
    final config = buildSingBoxConfig(resolved ?? chosen,
        xrayPort: xrayPort,
        xrayAuth: xrayAuth,
        options: o,
        ruleSets: sets,
        apiPort: api,
        apiSecret: secret,
        windows: isDesktop,
        chain: chain,
        viaXray: viaXray,
        routing: routing,
        localLogin: true);
    return (
      config: config,
      xrayConfig: viaXray ? buildXrayConfig(chosen.first, xrayPort, options: o, auth: xrayAuth) : null,
      api: api,
      secret: secret,
      xrayAuth: xrayAuth,
    );
  }

  /// Never blocks: a tap while connecting cancels, a tap while connected disconnects.
  Future<void> toggle() async {
    if (vpn.status == VpnStatus.stopping) return;
    if (connected || vpn.status == VpnStatus.starting) {
      _startId++;
      // Downloads that were riding the tunnel are abandoned, not left to fail later.
      for (final k in _generations.keys.toList()) {
        _generations[k] = _generations[k]! + 1;
      }
      // While OpenVPN is starting there is no core to answer a stop: the state is put back at once.
      if (_preparing || _ovpnStarting) {
        _preparing = false;
        _show(VpnStatus.stopped);
        await stopOpenVpn();
        return;
      }
      _show(VpnStatus.stopping);
      _expectStop = true;
      _stopAsked = DateTime.now();
      log('Disconnecting');
      await VpnChannel.stop();
      // A stop with nothing running (a core that never started, a service that was already gone) gives
      // no answer: the screen must not stay on "Disconnecting...". On the desktop the program itself
      // says "stopped" within 2.5 s, so this comes after that.
      if (isDesktop) {
        _settleStop(const Duration(seconds: 4));
        _settleStop(const Duration(seconds: 8));
      } else {
        _settleStop(const Duration(seconds: 2));
        _settleStop(const Duration(seconds: 6));
      }
      return;
    }
    final id = ++_startId;
    _preparing = true;
    _show(VpnStatus.starting);
    bool cancelled() => id != _startId;
    if (all.isEmpty) {
      if (showCollector) await refreshCollector();
      if (cancelled()) return;
      if (all.isEmpty) {
        _preparing = false;
        _show(VpnStatus.stopped);
        return;
      }
    }
    // With the proxy kept running, the connection goes on the servers that core already runs.
    final standbyServers = isDesktop && net.keepProxy ? _standbyServers : null;
    final chosen = standbyServers != null && selected == null ? standbyServers : _chosenServers();
    final granted = await VpnChannel.prepare();
    if (cancelled()) return;
    if (!granted) {
      message = (t) => t.vpnPermissionDenied;
      _preparing = false;
      _show(VpnStatus.stopped);
      return;
    }
    log('Connecting to ${selected?.name ?? 'the fastest servers'}');
    // The names let the notification show which server is in use.
    final names = chosen.map((c) => c.name).toList();
    _preparing = false;
    _xrayPort = null;
    _xrayAuth = null;
    _activeName = null;
    _groupNames = chosen.length > 1 ? [for (final c in chosen) if (c.canSingBox) c.name] : const [];
    try {
      final routing = routingFor(chosen);
      // In the proxy mode the core that already runs the proxy becomes the connection: nothing is
      // restarted, so what goes through it is not cut. (A login cannot be used here: the system
      // proxy has none.)
      if (standbyServers != null &&
          !net.tun &&
          (net.proxyUser.isEmpty || net.proxyPassword.isEmpty) &&
          _standbyKeyOf(chosen, routing) == _standbyKey) {
        final adopted = await VpnChannel.adoptStandby(systemProxyPort: net.proxyPort);
        if (cancelled()) return;
        if (adopted) {
          _xrayPort = _standbyXrayPort;
          _xrayAuth = _standbyXrayAuth;
          apiPort = _standbyApi;
          apiSecret = _standbySecret ?? '';
          return;
        }
      }
      // On the phone the OpenVPN program is the whole connection (its own service, no sing-box).
      if (Platform.isAndroid && chosen.length == 1 && chosen.first.isOpenVpn) {
        await _startOpenVpnAndroid(chosen.first);
        return;
      }
      // An OpenVPN server is carried by the OpenVPN program, which is started first; sing-box then sends
      // everything out through its adapter.
      String? ovpnInterface;
      if (chosen.length == 1 && chosen.first.isOpenVpn) {
        ovpnInterface = await _startOpenVpn(chosen.first, cancelled);
        if (cancelled()) {
          await stopOpenVpn();
          if (vpn.status != VpnStatus.stopped) _show(VpnStatus.stopped);
          return;
        }
        if (ovpnInterface == null) {
          _show(VpnStatus.stopped);
          return;
        }
      }
      final tags = routing?.ruleSetTags ?? const <String>[];
      _connectedTags = tags;
      // No download holds the connection back: the lists there are used (missing ones are stood in for
      // by the ones the app carries) and they are refreshed once it is up. Only lists a subscription's
      // rules ask for and that nobody has yet are waited for, a little.
      final sets = net.bypass.isNotEmpty || net.blockAds || tags.isNotEmpty
          ? await ensureRuleSets(await VpnChannel.dataDir(), net.bypass,
              ads: net.blockAds,
              adsLevel: net.adsLevel,
              loadBase: _loadAdBase,
              loadBundled: _loadBundledRules,
              tags: tags,
              wait: false,
              refresh: false,
              // The lists a subscription's rules ask for are the only ones waited for, and only when the
              // setting allows a download before the connection is up.
              waitForTags: net.listsRoute != 'tunnel',
              fetch: fetchDirect,
              limit: const Duration(seconds: 10))
          : <String, String>{};
      if (cancelled()) return;
      apiPort = await _freePort();
      apiSecret = _randomSecret();
      final chain = net.chain.isEmpty ? null : parseLink(net.chain);
      // One chosen server runs on Xray when only Xray can carry it, or when Xray is the default
      // core and can. A group of servers (automatic mode) is always sing-box.
      final viaXray = chosen.length == 1 &&
          chosen.first.canXray &&
          (chosen.first.needsXray || chosen.first.preferXray || net.core == 'xray');
      // Xray's local port asks for a login of its own, so no other program here can use it.
      final xrayAuth = viaXray ? _newXrayAuth() : null;
      // The names of the chosen servers are looked up first (encrypted DNS, then the system's).
      final resolved = await _resolveAhead(chosen);
      if (cancelled()) return;
      String config(int? xray) => buildSingBoxConfig(resolved,
          xrayPort: xray,
          xrayAuth: xrayAuth,
          options: net,
          ruleSets: sets,
          apiPort: apiPort,
          apiSecret: apiSecret,
          windows: isDesktop,
          chain: chain,
          viaXray: viaXray,
          routing: routing,
          ovpnInterface: ovpnInterface);
      final proxyPort =
          isDesktop && !net.tun ? net.proxyPort : null;
      final xrayPortNew = viaXray ? 30000 + Random().nextInt(30000) : null;
      // The phone keeps the proxy alone after the tunnel stops; the desktop does it from here.
      final standby = !isDesktop && net.keepProxy
          ? _standbyParts(chosen, routing, sets, viaXray ? xrayPortNew : null, resolved: resolved)
          : null;
      if (viaXray) {
        final port = xrayPortNew!;
        _xrayPort = port;
        _xrayAuth = xrayAuth;
        await VpnChannel.start(
          config(port),
          serverNames: names,
          xrayConfig: buildXrayConfig(chosen.first, port, options: net, auth: xrayAuth),
          xrayPort: port,
          showSpeed: showSpeed,
          showVolume: showVolume,
          showName: showName,
          apiPort: apiPort,
          apiSecret: apiSecret,
          systemProxyPort: proxyPort,
          killSwitch: net.killSwitch,
          keepStandby: standbyServers != null && net.tun,
          holdProxy: isDesktop && net.keepProxy && !net.tun,
          standbyConfig: standby?.config,
          standbyXrayConfig: standby?.xrayConfig,
          proxyPort: net.proxyPort,
        );
      } else {
        await VpnChannel.start(config(null),
            directPrograms: ovpnInterface == null ? const [] : const ['openvpn'],
            serverNames: names,
            showSpeed: showSpeed,
            showVolume: showVolume,
            showName: showName,
            apiPort: apiPort,
            apiSecret: apiSecret,
            systemProxyPort: proxyPort,
            killSwitch: net.killSwitch,
            keepStandby: standbyServers != null && net.tun,
            holdProxy: isDesktop && net.keepProxy && !net.tun,
            standbyConfig: standby?.config,
            proxyPort: net.proxyPort);
      }
    } catch (e) {
      log('Could not start the connection: $e');
      _show(VpnStatus.stopped);
    }
  }

  Future<int> _freePort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    return port;
  }

  XrayAuth _newXrayAuth() => (user: 'k${_randomSecret().substring(0, 8)}', pass: _randomSecret());

  String _randomSecret() {
    final r = Random.secure();
    return List.generate(24, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  // ---------------------------------------------------------------- failover

  Timer? _watch;

  /// The names of the servers in the automatic group, in the order the core knows them (server-0 ...),
  /// and the one the group uses now (asked from the core), so that the usage is filed under the
  /// server that carried it.
  List<String> _groupNames = const [];
  String? _activeName;

  Future<void> _refreshActive() async {
    if (!connected || selected != null || _groupNames.length < 2) {
      _activeName = null;
      return;
    }
    final j = await api?.get('/proxies/proxy');
    final now = j is Map ? '${j['now']}' : '';
    final m = RegExp(r'^server-(\d+)$').firstMatch(now);
    final i = m == null ? -1 : int.parse(m[1]!);
    _activeName = i >= 0 && i < _groupNames.length ? _groupNames[i] : null;
  }
  var _misses = 0;
  var _healthDown = 0;
  var _failingOver = false;

  /// In automatic mode only: checks that traffic still flows. After two failures in a row it
  /// moves to the best other server. A server the user picked is never switched.
  Future<void> _healthTick() async {
    if (!connected || !net.failover || _failingOver || _preparing) return;
    if (selected != null) return;
    // Data that came in since the last check already proves the server works; a probe on top of
    // it would only keep the radio busy.
    final received = traffic.value.downTotal;
    final flowing = received - _healthDown > 2048;
    _healthDown = received;
    if (flowing) {
      _misses = 0;
      return;
    }
    final ms = await tunnelDelay(
        socksPort: _xrayPort,
        socksAuth: _xrayAuth,
        proxyPort: net.tun ? null : net.proxyPort,
        timeout: const Duration(seconds: 5));
    if (!connected) return;
    if (ms >= 0) {
      _misses = 0;
      return;
    }
    if (++_misses < 2) return;
    _misses = 0;
    final current = autoPick;
    if (current == null) return;
    current.latencyMs = -1;
    final next = autoPick;
    if (next == null) return;
    _failingOver = true;
    log('Server ${current.name} stopped answering, switching to ${next.name}');
    _forcedReason = (key: 'reasonServer', args: {'name': current.name});
    _save();
    notifyListeners();
    try {
      await _reconnect();
    } finally {
      _failingOver = false;
    }
  }

  /// The local proxy port that tools must use to go through the VPN: set while connected
  /// without the tunnel, null otherwise (the tunnel already carries everything).
  int? get localProxyPort => connected && !net.tun ? net.proxyPort : null;

  /// Tests every server of every list, one list after the other.
  Future<void> pingAll({required bool real}) async {
    if (real && !_real) return;
    _pingAllStopped = false;
    for (final g in List.of(groups)) {
      if (_pingAllStopped) break;
      if (g.configs.isEmpty) continue;
      await ping(g, real: real);
    }
  }

  bool _pingAllStopped = false;

  /// Whether any list is being tested now.
  bool get anyTesting => tests.values.any((t) => t.running);

  // The servers of each running test and the ones whose result is in.
  final _pingRuns = <String, ({List<ProxyConfig> list, Set<ProxyConfig> done})>{};

  /// Stops the test of one list; the results so far stay. With [removeUntested] the servers that
  /// were not tested yet are deleted from the list (they stay by default).
  void cancelPing(ServerGroup g, {bool removeUntested = false}) {
    final run = _pingRuns[g.id];
    _begin('ping-${g.id}');
    tests[g.id]?.running = false;
    if (removeUntested && run != null) {
      final untested = run.list.where((c) => !run.done.contains(c)).toSet();
      g.configs.removeWhere(untested.contains);
      if (selected != null && untested.contains(selected)) selected = null;
      log('Removed ${untested.length} servers that were not tested from ${_title(g)}');
      _save();
    }
    notifyListeners();
  }

  /// Stops every test that is running, and the ones of a test-all that have not started.
  void cancelAllPings({bool removeUntested = false}) {
    _pingAllStopped = true;
    for (final g in groups) {
      if (tests[g.id]?.running ?? false) cancelPing(g, removeUntested: removeUntested);
    }
  }

  /// Forgets all ping results.
  void clearTestResults() {
    for (final c in all) {
      c.latencyMs = null;
    }
    tests.clear();
    _save();
    notifyListeners();
  }

  /// Downloads every subscription again.
  Future<void> updateAllSubscriptions() async {
    for (final g in List.of(subscriptions)) {
      await refreshSubscription(g);
    }
  }

  /// Applies changed network options to a running connection.
  Future<void> reconnectIfConnected() async {
    if (connected) await _reconnect();
  }

  /// Asks a public service which address and country it sees (through the tunnel or the local
  /// proxy when connected). Returns null when the request fails.
  Future<({String ip, String country, String? webrtc})?> checkLeak() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    if (connected && !net.tun) {
      client.findProxy = (_) => 'PROXY 127.0.0.1:${net.proxyPort}';
    }
    try {
      final req = await client
          .getUrl(Uri.parse('https://www.cloudflare.com/cdn-cgi/trace'))
          .timeout(const Duration(seconds: 10));
      final res = await req.close().timeout(const Duration(seconds: 10));
      final body = await res.transform(utf8.decoder).join();
      final map = {
        for (final l in body.split('\n'))
          if (l.contains('=')) l.split('=').first: l.substring(l.indexOf('=') + 1),
      };
      // The address a browser's WebRTC would show: a UDP request does not use the local proxy,
      // so with the tunnel off it shows the network's own address.
      final webrtc = await stunAddress();
      return (ip: map['ip'] ?? '?', country: map['loc'] ?? '?', webrtc: webrtc);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  // ---------------------------------------------------------------- backup

  /// The text of a backup file holding the servers, subscriptions and settings.
  Future<String> exportBackup(String password) async {
    final payload = jsonEncode({
      'servers': await VpnChannel.readFile(_storeFile) ?? '{}',
      'settings': await VpnChannel.readFile(_settingsFile) ?? '{}',
      'usage': await VpnChannel.readFile(_usageFile),
    });
    return sealBackup(payload, password);
  }

  /// Restores a backup. Returns false when the password is wrong or the file is damaged.
  Future<bool> importBackup(String text, String password) async {
    final payload = await openBackup(text, password);
    if (payload == null) return false;
    try {
      final j = jsonDecode(payload) as Map<String, dynamic>;
      final servers = j['servers'] as String;
      final settings = j['settings'] as String;
      final usage = j['usage'];
      // Look before writing anything: each part must be what this app saves, or the files in
      // place stay as they are.
      if (jsonDecode(servers) is! Map || jsonDecode(settings) is! Map) return false;
      if (usage is String && jsonDecode(usage) is! Map) return false;
      await _store(_storeFile, servers, locked: _storeLocked);
      await _store(_settingsFile, settings, locked: _settingsLocked);
      _storeLocked = _settingsLocked = false;
      if (usage is String) {
        await VpnChannel.writeFile(_usageFile, usage);
      }
      collector.configs.clear();
      manual.configs.clear();
      subscriptions.clear();
      selected = null;
      // The restored numbers replace the current ones, they are not added to them.
      dayUsage.clear();
      serverUsage.clear();
      publicUsage[0] = publicUsage[1] = 0;
      warpUsage[0] = warpUsage[1] = 0;
      peakDown = peakUp = 0;
      await _loadSettings();
      await _loadServers();
      await _loadUsage();
      delayTestUrl = delayUrl;
      // What the settings drive outside this object.
      VpnChannel.scheduleSubUpdates(autoUpdateSubs).catchError((_) {});
      VpnChannel.setIdleNotification(idleNotification);
      _syncStandby();
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// What [AppState.removeConfigs] took out of where.
typedef RemovedConfig = ({ServerGroup group, ProxyConfig config, int index, bool wasSelected});

/// A short key for the ping of a link in the saved servers: 32 bits of FNV-1a of the link, in hex. Two
/// links with the same key would only share a ping that is measured again at the next test.
String pingKey(String link) {
  var h = 0x811c9dc5;
  for (final unit in link.codeUnits) {
    h = ((h ^ unit) * 0x01000193) & 0xFFFFFFFF;
  }
  return h.toRadixString(16).padLeft(8, '0');
}

/// [parseLinks], on another isolate when there are many links (a few hundred take long enough to stop the
/// screen for a moment at the start of the app). The same on the spot when they are few, or when the
/// result cannot be handed back.
Future<List<ProxyConfig>> parseLinksOff(List<String> links, {bool secure = false}) async {
  if (links.length < 300) return parseLinks(links, secure: secure);
  try {
    return await Isolate.run(() => parseLinks(links, secure: secure));
  } catch (_) {
    return parseLinks(links, secure: secure);
  }
}
