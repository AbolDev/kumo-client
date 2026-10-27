import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpClient, InternetAddress, Platform, ServerSocket;
import 'dart:math';

import 'package:flutter/material.dart';

import '../core/backup.dart';
import '../core/core_api.dart';
import '../core/latency_tester.dart';
import '../core/desktop_vpn.dart';
import '../core/net_options.dart';
import '../core/platform.dart';
import '../core/proxy_config.dart';
import '../core/provider_routing.dart';
import '../core/rule_sets.dart';
import '../core/stun.dart';
import '../core/singbox_config.dart';
import '../core/sources.dart';
import '../core/sub_formats.dart';
import '../core/sub_surge.dart' show subscriptionDeepLink;
import '../core/updater.dart' show includePrerelease;
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

enum GroupKind { collector, subscription, manual }

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
  final collector = ServerGroup('collector', GroupKind.collector);
  final manual = ServerGroup('manual', GroupKind.manual);
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
    notifyListeners();
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
    final forced = _forcedReason;
    _forcedReason = null;
    if (forced != null) {
      lastDisconnect = forced;
    } else if (s.status == VpnStatus.error) {
      lastDisconnect = (key: 'reasonError', args: {'e': s.error ?? ''});
    } else if (_expectStop) {
      lastDisconnect = (key: 'reasonYou', args: const <String, Object>{});
    } else if (s.error == 'revoked') {
      lastDisconnect = (key: 'reasonRevoked', args: const <String, Object>{});
    } else {
      lastDisconnect = (key: 'reasonOutside', args: const <String, Object>{});
    }
    _expectStop = false;
    log('Disconnect reason: ${trFor('en', lastDisconnect!.key, lastDisconnect!.args)}');
  }

  /// Delay through the live tunnel, measured after connecting (null = not measured yet).
  int? liveDelay;
  int? _xrayPort;

  Future<void> _measureLive() async {
    final selectedNow = selected;
    for (var attempt = 0; attempt < 2 && connected; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (!connected) return;
      final ms = await tunnelDelay(
          socksPort: _xrayPort, proxyPort: net.tun ? null : net.proxyPort, samples: 2);
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

  /// null = follow the phone, otherwise 'fa' or 'en'.
  String? languageCode;

  // Sub settings
  bool autoUpdateSubs = true;
  bool updateOnStartup = true;
  bool updatePrerelease = false;
  bool allowInsecure = true;

  // App settings
  bool autoConnect = false;
  bool restartOnChange = true;
  bool confirmDelete = true;
  bool batteryAsked = false;

  /// False until the first-run guide has been finished; people who already had settings skip it.
  bool onboarded = false;

  /// True once the saved settings have been read (before that the first-run guide must not show).
  bool settingsLoaded = false;

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
    final base = [if (showCollector) collector, ...subscriptions, manual];
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
    _listenTraffic();
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
      }
      _preparing = false;
      if (s.status != VpnStatus.started) {
        traffic.value = Traffic.zero;
        _lastDown = _lastUp = 0;
        downHistory.clear();
        upHistory.clear();
        if (_usageTimer != null) {
          _usageTimer!.cancel();
          _writeUsage();
        }
        liveDelay = null;
      }
      if (changed) _syncStandby(const Duration(milliseconds: 800), false);
      if (s.status == VpnStatus.started && changed) {
        if (measurePing) _measureLive();
        _misses = 0;
        _healthDown = 0;
        _watch?.cancel();
        _watch = Timer.periodic(const Duration(seconds: 20), (_) => _healthTick());
      } else if (s.status != VpnStatus.started) {
        _watch?.cancel();
        _watch = null;
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
    await _loadLogs();
    await _loadUsage();
    await _loadServers();
    delayTestUrl = delayUrl;
    if (idleNotification) VpnChannel.setIdleNotification(true);
    VpnChannel.scheduleSubUpdates(autoUpdateSubs).catchError((_) {});
    if (isDesktop) DesktopVpn.instance.standby.addListener(notifyListeners);
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
  }

  /// Uses what the background job downloaded while the app was closed.
  Future<void> _applyCachedSubscriptions() async {
    for (final g in List.of(subscriptions)) {
      try {
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
      if (isDue(g) && !refreshing.contains(g.id)) await refreshSubscription(g);
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
    g.info = fetched.info;
    final meta = fetched.meta;
    g.providerInterval = meta.intervalHours;
    g.routing = ProviderRouting.parse(meta.routing);
    g.routingByProvider = meta.routingEnabled;
    g.supportUrl = meta.supportUrl;
    g.webPage = meta.webPage;
    g.announce = meta.announce;
    checkUsage(g);
    final links = await extractSubscriptionLinksInBackground(fetched.body);
    final parsed = await parseLinksInBackground(links, shuffle: false);
    if (parsed.isEmpty) return 0;
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
  }

  Future<void> _reconnect() async {
    _expectStop = true;
    await VpnChannel.stop();
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (vpn.status != VpnStatus.stopped &&
        vpn.status != VpnStatus.error &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await toggle();
  }

  // ---------------------------------------------------------------- settings

  Future<void> _loadSettings() async {
    try {
      final raw = await VpnChannel.readFile(_settingsFile);
      if (raw == null) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      themeMode = ThemeMode.values.firstWhere((m) => m.name == j['theme'],
          orElse: () => ThemeMode.system);
      final lang = j['language'] as String?;
      languageCode = S.languageNames.containsKey(lang) ? lang : null;
      bool flag(String k, bool d) => j[k] is bool ? j[k] as bool : d;
      autoUpdateSubs = flag('autoUpdateSubs', true);
      updateOnStartup = flag('updateOnStartup', true);
      updatePrerelease = flag('updatePrerelease', false);
      // Test versions are asked about at each manual check, not kept as a setting.
      includePrerelease = false;
      allowInsecure = flag('allowInsecure', true);
      autoConnect = flag('autoConnect', false);
      restartOnChange = flag('restartOnChange', true);
      confirmDelete = flag('confirmDelete', true);
      batteryAsked = flag('batteryAsked', false);
      onboarded = flag('onboarded', true);
      homeCountry = j['homeCountry'] is String ? j['homeCountry'] as String : '';
      showCollector = flag('showCollector', true);
      final order = j['groupOrder'];
      if (order is List) groupOrder = order.whereType<String>().toList();
      showSpeed = flag('showSpeed', true);
      showVolume = flag('showVolume', false);
      showName = flag('showName', true);
      idleNotification = flag('idleNotification', true);
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

  void _saveSettings() {
    VpnChannel.writeFile(
        _settingsFile,
        jsonEncode({
          'theme': themeMode.name,
          'language': languageCode,
          'autoUpdateSubs': autoUpdateSubs,
          'updateOnStartup': updateOnStartup,
          'updatePrerelease': updatePrerelease,
          'allowInsecure': allowInsecure,
          'autoConnect': autoConnect,
          'restartOnChange': restartOnChange,
          'confirmDelete': confirmDelete,
          'batteryAsked': batteryAsked,
          'onboarded': onboarded,
          'homeCountry': homeCountry,
          'showCollector': showCollector,
          'groupOrder': groupOrder,
          'showSpeed': showSpeed,
          'showVolume': showVolume,
          'showName': showName,
          'idleNotification': idleNotification,
          'usageAlerts': usageAlerts,
          'measurePing': measurePing,
          'subInterval': subInterval,
          'alertSeen': _alertSeen,
          'delayUrl': delayUrl,
          'net': net.toJson(),
        })).catchError((_) {});
    notifyListeners();
  }

  /// Changes one of the switches in Settings.
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
    if (net.bypass.isNotEmpty || net.blockAds) {
      ensureRuleSets(await VpnChannel.dataDir(), net.bypass, ads: net.blockAds)
          .catchError((_) => <String, String>{});
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
    try {
      final raw = await VpnChannel.readFile(_storeFile);
      if (raw == null) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      // Older versions kept one flat list: that was the collector's.
      collector.configs.addAll(parseLinks(
          ((j['collector'] ?? j['links'] ?? const []) as List).cast<String>()));
      manual.configs.addAll(
          parseLinks(((j['manual'] ?? const []) as List).cast<String>()));
      for (final s in (j['subs'] ?? const []) as List) {
        final m = s as Map<String, dynamic>;
        final g = ServerGroup(m['id'] as String, GroupKind.subscription,
            name: m['name'] as String? ?? '', url: m['url'] as String?)
          ..autoName = m['auto'] == true
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
        g.configs.addAll(parseLinks((m['links'] as List).cast<String>()));
        subscriptions.add(g);
      }
      final pings = (j['pings'] as Map?) ?? const {};
      for (final c in all) {
        final ms = pings[c.link];
        if (ms is num) c.latencyMs = ms.toInt();
      }
      for (final g in [collector, manual, ...subscriptions]) {
        if (g.configs.any((c) => c.latencyMs != null)) _sort(g);
      }
      final link = j['selected'] as String?;
      final inGroup = j['selectedGroup'] as String?;
      // The same link can be in two groups: the one that was picked is the one that comes back.
      selected = [
        for (final g in [collector, manual, ...subscriptions])
          if (g.id == inGroup) ...g.configs,
      ].where((c) => c.link == link).firstOrNull ??
          all.where((c) => c.link == link).firstOrNull;
    } catch (_) {
      // missing or corrupt store: start fresh
    }
  }

  CoreApi? get api => apiPort == null || apiSecret == null
      ? null
      : CoreApi(apiPort!, apiSecret!);

  // ---------------------------------------------------------------- usage

  /// Data used per day ("2026-10-25" -> [down, up] bytes) and per server name.
  final dayUsage = <String, List<int>>{};
  final serverUsage = <String, int>{};

  /// The last two minutes of speed, one sample a second (bytes per second).
  final downHistory = <int>[];
  final upHistory = <int>[];
  var _lastDown = 0, _lastUp = 0;
  Timer? _usageTimer;
  static const _usageFile = 'usage.json';

  static String _dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  void _onTraffic(Traffic t) {
    traffic.value = t;
    var dd = t.downTotal - _lastDown, du = t.upTotal - _lastUp;
    if (dd < 0 || du < 0) {
      dd = t.downTotal;
      du = t.upTotal;
    }
    _lastDown = t.downTotal;
    _lastUp = t.upTotal;
    downHistory.add(t.down);
    upHistory.add(t.up);
    if (downHistory.length > 120) {
      downHistory.removeAt(0);
      upHistory.removeAt(0);
    }
    if (dd + du > 0) {
      final day = dayUsage.putIfAbsent(_dayKey(DateTime.now()), () => [0, 0]);
      day[0] += dd;
      day[1] += du;
      final name = selected?.name ?? 'Automatic';
      serverUsage[name] = (serverUsage[name] ?? 0) + dd + du;
      _usageTimer ??= Timer(const Duration(seconds: 30), _writeUsage);
    }
  }

  void _writeUsage() {
    _usageTimer = null;
    VpnChannel.writeFile(
        _usageFile, jsonEncode({'days': dayUsage, 'servers': serverUsage}))
        .catchError((_) {});
  }

  Future<void> _loadUsage() async {
    try {
      final raw = await VpnChannel.readFile(_usageFile);
      if (raw == null) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      (j['days'] as Map?)?.forEach((k, v) {
        final l = (v as List).map((e) => (e as num).toInt()).toList();
        if (l.length == 2) dayUsage['$k'] = l;
      });
      (j['servers'] as Map?)
          ?.forEach((k, v) => serverUsage['$k'] = (v as num).toInt());
    } catch (_) {
      // no statistics yet
    }
  }

  void resetUsage() {
    dayUsage.clear();
    serverUsage.clear();
    _writeUsage();
    notifyListeners();
  }

  void _listenTraffic() =>
      _trafficSub ??= VpnChannel.traffic.listen(_onTraffic);

  void _save() => _writeServers();

  void _writeServers() {
    List<String> links(ServerGroup g, [int? limit]) =>
        g.configs.take(limit ?? g.configs.length).map((c) => c.link).toList();
    // Ping results, so they survive closing the app.
    Map<String, int> pings(ServerGroup g) => {
          for (final c in g.configs)
            if (c.latencyMs != null) c.link: c.latencyMs!,
        };
    final data = jsonEncode({
      'collector': links(collector),
      'manual': links(manual),
      'pings': {
        ...pings(collector),
        ...pings(manual),
        for (final g in subscriptions) ...pings(g),
      },
      'subs': [
        for (final g in subscriptions)
          {
            'id': g.id,
            'name': g.name,
            'url': g.url,
            'auto': g.autoName,
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
      'selectedGroup': [collector, manual, ...subscriptions]
          .where((g) => g.configs.any((c) => identical(c, selected)))
          .firstOrNull
          ?.id,
    });
    VpnChannel.writeFile(_storeFile, data).catchError((_) {});
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
    final list = List.of(g.configs);
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

  String _title(ServerGroup g) => g.kind == GroupKind.collector
      ? 'Public servers'
      : (g.kind == GroupKind.manual ? 'Manual configs' : g.name);

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
          fetchFromSources(),
          cancel.future.then((_) => null),
        ]);
        if (result == null || _stale(key, gen)) return;
        final parsed = await parseLinksInBackground(result.links);
        if (_stale(key, gen)) return;
        final fresh = parsed.toList();
        collector.configs
          ..clear()
          ..addAll(fresh);
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
  // ---------------------------------------------------------------- subscriptions

  Future<void> refreshSubscription(ServerGroup g, {bool naming = false}) async {
    if (g.url == null) return;
    final key = 'sub-${g.id}';
    final gen = _begin(key);
    working.add(g.id);
    refreshing.add(g.id);
    final cancel = _cancels[key] = Completer<void>();
    await _job((t) => t.fetchingList, () async {
      try {
        final fetched = await Future.any(<Future<Fetched?>>[
          fetchSubscription(g.url!, allowInsecure: allowInsecure, lookupName: naming),
          cancel.future.then((_) => null),
        ]);
        if (fetched == null || _stale(key, gen)) return;
        final n = await _applyFetched(
            g, fetched, DateTime.now().millisecondsSinceEpoch, naming: naming);
        message =
            n == 0 ? (t) => t.noValidConfig : (t) => t.subscriptionUpdated(n);
      } catch (e) {
        message = (t) => t.fetchFailed(e);
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

  Future<void> editSubscription(ServerGroup g, String name, String url) async {
    final changed = g.url != url;
    if (name != g.name) g.autoName = false;
    g.name = name;
    g.url = url;
    _save();
    notifyListeners();
    if (changed) await refreshSubscription(g);
  }

  void removeSubscription(ServerGroup g) {
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
    g.configs[i] = updated;
    if (selected == old) selected = updated;
    _save();
    notifyListeners();
    return true;
  }

  void removeConfig(ServerGroup g, ProxyConfig c) {
    g.configs.remove(c);
    if (selected == c) selected = null;
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

  // ---------------------------------------------------------------- vpn

  /// True from the tap until the start request reached the service.
  bool _preparing = false;
  var _startId = 0;

  void _show(VpnStatus s) {
    vpn = VpnState(s);
    notifyListeners();
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

  Future<void> _applyStandby() async {
    if (!net.keepProxy || !_idle || _preparing || all.isEmpty) {
      // On the phone the service gives the proxy up by itself when a tunnel starts.
      if (!net.keepProxy || (isDesktop && (connected || vpn.status == VpnStatus.starting))) {
        await VpnChannel.stopStandby();
      }
      return;
    }
    try {
      final chosen = _chosenServers();
      final routing = routingFor(chosen);
      final tags = routing?.ruleSetTags ?? const <String>[];
      final sets = net.bypass.isNotEmpty || net.blockAds || tags.isNotEmpty
          ? await ensureRuleSets(await VpnChannel.dataDir(), net.bypass,
              ads: net.blockAds, tags: tags, wait: false)
          : <String, String>{};
      final viaXray = chosen.length == 1 &&
          chosen.first.canXray &&
          (chosen.first.needsXray || net.core == 'xray');
      final xrayPort = viaXray ? 30000 + Random().nextInt(30000) : null;
      final parts = _standbyParts(chosen, routing, sets, xrayPort);
      // Something changed while this was being prepared.
      if (!net.keepProxy || !_idle || _preparing) return;
      final ok = await VpnChannel.startStandby(parts.config,
          xrayConfig: parts.xrayConfig,
          xrayPort: xrayPort,
          apiPort: parts.api,
          proxyPort: net.proxyPort);
      if (!ok) log('The proxy could not be kept running');
    } catch (e) {
      log('The proxy could not be kept running: $e');
    }
  }

  /// The configuration of the proxy that stays up without the tunnel: the same options without
  /// the tunnel, the kill switch and the system proxy, with the login when one is set.
  ({String config, String? xrayConfig, int api}) _standbyParts(List<ProxyConfig> chosen,
      ProviderRouting? routing, Map<String, String> sets, int? xrayPort) {
    final o = NetOptions()
      ..load(net.toJson())
      ..tun = false
      ..killSwitch = false;
    final chain = o.chain.isEmpty ? null : parseLink(o.chain);
    final viaXray = xrayPort != null;
    // The port of the control API is only used on the desktop; any free one will do.
    final api = 20000 + Random().nextInt(20000);
    final config = buildSingBoxConfig(chosen,
        xrayPort: xrayPort,
        options: o,
        ruleSets: sets,
        apiPort: api,
        apiSecret: null,
        windows: isDesktop,
        chain: chain,
        viaXray: viaXray,
        routing: routing,
        localLogin: true);
    return (
      config: config,
      xrayConfig: viaXray ? buildXrayConfig(chosen.first, xrayPort, options: o) : null,
      api: api,
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
      if (_preparing) {
        _preparing = false;
        _show(VpnStatus.stopped);
        return;
      }
      _show(VpnStatus.stopping);
      _expectStop = true;
      await VpnChannel.stop();
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
    final chosen = _chosenServers();
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
    try {
      final routing = routingFor(chosen);
      final tags = routing?.ruleSetTags ?? const <String>[];
      final sets = net.bypass.isNotEmpty || net.blockAds || tags.isNotEmpty
          ? await ensureRuleSets(await VpnChannel.dataDir(), net.bypass,
              ads: net.blockAds, tags: tags)
          : <String, String>{};
      if (cancelled()) return;
      apiPort = await _freePort();
      apiSecret = _randomSecret();
      final chain = net.chain.isEmpty ? null : parseLink(net.chain);
      // One chosen server runs on Xray when only Xray can carry it, or when Xray is the default
      // core and can. A group of servers (automatic mode) is always sing-box.
      final viaXray = chosen.length == 1 &&
          chosen.first.canXray &&
          (chosen.first.needsXray || net.core == 'xray');
      String config(int? xray) => buildSingBoxConfig(chosen,
          xrayPort: xray,
          options: net,
          ruleSets: sets,
          apiPort: apiPort,
          apiSecret: apiSecret,
          windows: isDesktop,
          chain: chain,
          viaXray: viaXray,
          routing: routing);
      final proxyPort =
          isDesktop && !net.tun ? net.proxyPort : null;
      final xrayPortNew = viaXray ? 30000 + Random().nextInt(30000) : null;
      // The phone keeps the proxy alone after the tunnel stops; the desktop does it from here.
      final standby = !isDesktop && net.keepProxy
          ? _standbyParts(chosen, routing, sets, viaXray ? xrayPortNew : null)
          : null;
      if (viaXray) {
        final port = xrayPortNew!;
        _xrayPort = port;
        await VpnChannel.start(
          config(port),
          serverNames: names,
          xrayConfig: buildXrayConfig(chosen.first, port, options: net),
          xrayPort: port,
          showSpeed: showSpeed,
          showVolume: showVolume,
          showName: showName,
          apiPort: apiPort,
          apiSecret: apiSecret,
          systemProxyPort: proxyPort,
          killSwitch: net.killSwitch,
          standbyConfig: standby?.config,
          standbyXrayConfig: standby?.xrayConfig,
          proxyPort: net.proxyPort,
        );
      } else {
        await VpnChannel.start(config(null),
            serverNames: names,
            showSpeed: showSpeed,
            showVolume: showVolume,
            showName: showName,
            apiPort: apiPort,
            apiSecret: apiSecret,
            systemProxyPort: proxyPort,
            killSwitch: net.killSwitch,
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

  String _randomSecret() {
    final r = Random.secure();
    return List.generate(24, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  // ---------------------------------------------------------------- failover

  Timer? _watch;
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
      await VpnChannel.writeFile(_storeFile, j['servers'] as String);
      await VpnChannel.writeFile(_settingsFile, j['settings'] as String);
      if (j['usage'] is String) {
        await VpnChannel.writeFile(_usageFile, j['usage'] as String);
      }
      collector.configs.clear();
      manual.configs.clear();
      subscriptions.clear();
      selected = null;
      await _loadSettings();
      await _loadServers();
      await _loadUsage();
      delayTestUrl = delayUrl;
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }
}
