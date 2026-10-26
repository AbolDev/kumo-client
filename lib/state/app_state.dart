import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpClient, InternetAddress, Platform, ServerSocket;
import 'dart:math';

import 'package:flutter/material.dart';

import '../core/backup.dart';
import '../core/core_api.dart';
import '../core/latency_tester.dart';
import '../core/net_options.dart';
import '../core/proxy_config.dart';
import '../core/rule_sets.dart';
import '../core/singbox_config.dart';
import '../core/sources.dart';
import '../core/sub_formats.dart';
import '../core/updater.dart' show includePrerelease;
import '../core/vpn_channel.dart';
import '../l10n/strings.dart';

/// How many configs of the downloaded public list are kept.

/// Subscriptions are refreshed on startup when older than this.
const _startupInterval = Duration(hours: 1);

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

  /// Delay through the live tunnel, measured after connecting (null = not measured yet).
  int? liveDelay;
  int? _xrayPort;

  Future<void> _measureLive() async {
    final selectedNow = selected;
    for (var attempt = 0; attempt < 2 && connected; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (!connected) return;
      final ms = await tunnelDelay(
          socksPort: _xrayPort, proxyPort: net.tun ? null : net.proxyPort);
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
      vpn = s;
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
      if (s.status == VpnStatus.started && changed) {
        _measureLive();
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
    await _loadLogs();
    await _loadUsage();
    await _loadServers();
    delayTestUrl = delayUrl;
    if (idleNotification) VpnChannel.setIdleNotification(true);
    VpnChannel.scheduleSubUpdates(autoUpdateSubs).catchError((_) {});
    notifyListeners();
    // Nothing is tested on its own: the user pings when they want to.
    await _applyCachedSubscriptions();
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
            j['userinfo'] as String?);
        await _applyFetched(g, fetched, time);
      } catch (_) {
        // a broken cache file is ignored
      }
    }
    _save();
    notifyListeners();
  }

  Future<void> _updateSubscriptionsOnStartup() async {
    final limit =
        DateTime.now().subtract(_startupInterval).millisecondsSinceEpoch;
    for (final g in List.of(subscriptions)) {
      if (g.updatedAt < limit) await refreshSubscription(g);
    }
  }

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
  Future<int> _applyFetched(ServerGroup g, Fetched fetched, int time) async {
    final title = fetched.title;
    if (title != null &&
        (g.autoName ||
            g.name.isEmpty ||
            g.name == Uri.tryParse(g.url ?? '')?.host)) {
      g.name = title;
      g.autoName = true;
    }
    g.info = fetched.info;
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
  }

  Future<void> _reconnect() async {
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
      includePrerelease = updatePrerelease;
      allowInsecure = flag('allowInsecure', true);
      autoConnect = flag('autoConnect', false);
      restartOnChange = flag('restartOnChange', true);
      confirmDelete = flag('confirmDelete', true);
      batteryAsked = flag('batteryAsked', false);
      showCollector = flag('showCollector', true);
      final order = j['groupOrder'];
      if (order is List) groupOrder = order.whereType<String>().toList();
      showSpeed = flag('showSpeed', true);
      showVolume = flag('showVolume', false);
      showName = flag('showName', true);
      idleNotification = flag('idleNotification', true);
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
          'showCollector': showCollector,
          'groupOrder': groupOrder,
          'showSpeed': showSpeed,
          'showVolume': showVolume,
          'showName': showName,
          'idleNotification': idleNotification,
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
    if (net.bypass.isNotEmpty) ensureRuleSets(await VpnChannel.dataDir(), net.bypass).catchError((_) => <String, String>{});
    if (reconnect && connected) await _reconnect();
  }

  void setDelayUrl(String url) {
    delayUrl = url;
    delayTestUrl = url;
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
          ..updatedAt = (m['updatedAt'] as num?)?.toInt() ?? 0;
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
      c.latencyMs = real ? await realDelay(c) : await tcpLatency(c);
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
      if (c.needsXray || !c.isAlive) continue;
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

  Future<void> refreshSubscription(ServerGroup g) async {
    if (g.url == null) return;
    final key = 'sub-${g.id}';
    final gen = _begin(key);
    working.add(g.id);
    refreshing.add(g.id);
    final cancel = _cancels[key] = Completer<void>();
    await _job((t) => t.fetchingList, () async {
      try {
        final fetched = await Future.any(<Future<Fetched?>>[
          fetchSubscription(g.url!, allowInsecure: allowInsecure),
          cancel.future.then((_) => null),
        ]);
        if (fetched == null || _stale(key, gen)) return;
        final n = await _applyFetched(
            g, fetched, DateTime.now().millisecondsSinceEpoch);
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
    final input = text.trim();
    if (input.isEmpty) return null;
    final first = input.split(RegExp(r'\s')).first;
    if (first.startsWith('http://') || first.startsWith('https://')) {
      var g = subscriptions.where((s) => s.url == first).firstOrNull;
      final isNew = g == null;
      if (g == null) {
        g = ServerGroup('sub-${DateTime.now().microsecondsSinceEpoch}',
            GroupKind.subscription,
            name: Uri.tryParse(first)?.host ?? first, url: first)
          ..autoName = true;
        subscriptions.add(g);
      }
      await refreshSubscription(g);
      final nameless = g.name == Uri.tryParse(first)?.host;
      return isNew && nameless && g.configs.isNotEmpty ? g : null;
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
    // Automatic mode only groups sing-box servers; XHTTP ones need their own Xray process,
    // so they are used when picked by hand (or when nothing else is available).
    final plain = all.where((c) => !c.needsXray).toList();
    final alive = plain.where((c) => c.isAlive).toList()
      ..sort((a, b) => _rank(a).compareTo(_rank(b)));
    final auto =
        (alive.isNotEmpty ? alive : plain).take(_autoGroupSize).toList();
    final chosen =
        selected != null ? [selected!] : (auto.isNotEmpty ? auto : [all.first]);
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
      final sets = net.bypass.isNotEmpty
          ? await ensureRuleSets(await VpnChannel.dataDir(), net.bypass)
          : <String, String>{};
      if (cancelled()) return;
      apiPort = await _freePort();
      apiSecret = _randomSecret();
      final chain = net.chain.isEmpty ? null : parseLink(net.chain);
      String config(int? xray) => buildSingBoxConfig(chosen,
          xrayPort: xray,
          options: net,
          ruleSets: sets,
          apiPort: apiPort,
          apiSecret: apiSecret,
          windows: Platform.isWindows,
          chain: chain);
      final proxyPort =
          Platform.isWindows && !net.tun ? net.proxyPort : null;
      if (chosen.first.needsXray) {
        final port = 30000 + Random().nextInt(30000);
        _xrayPort = port;
        await VpnChannel.start(
          config(port),
          serverNames: names,
          xrayConfig: buildXrayConfig(chosen.first, port, logLevel: net.logLevel),
          xrayPort: port,
          showSpeed: showSpeed,
          showVolume: showVolume,
          showName: showName,
          apiPort: apiPort,
          apiSecret: apiSecret,
          systemProxyPort: proxyPort,
          killSwitch: net.killSwitch,
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
            killSwitch: net.killSwitch);
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
    _save();
    notifyListeners();
    try {
      await _reconnect();
    } finally {
      _failingOver = false;
    }
  }

  /// Applies changed network options to a running connection.
  Future<void> reconnectIfConnected() async {
    if (connected) await _reconnect();
  }

  /// Asks a public service which address and country it sees (through the tunnel or the local
  /// proxy when connected). Returns null when the request fails.
  Future<({String ip, String country})?> checkLeak() async {
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
      return (ip: map['ip'] ?? '?', country: map['loc'] ?? '?');
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
