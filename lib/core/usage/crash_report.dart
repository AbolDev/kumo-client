import 'dart:async';
import 'dart:convert';

import 'crash_scrub.dart';
import 'usage_endpoints.dart';
import 'usage_ping.dart';
import 'usage_reporter.dart' show PingMethod;

/// Crash reports: what broke and where, with everything personal removed. They share the switch
/// of the anonymous usage count (off there means nothing is queued or sent here either) and the same
/// signed list of addresses. The format is the server's (POST /api/v1/crash, format v1).

const crashPath = '/api/v1/crash';

/// The most the server takes in one report.
const crashMaxBytes = 24 * 1024;
const crashMaxMessage = 1000;
const crashMaxStack = 8000;
const crashMaxLog = 4000;

const crashVpnStates = {'disconnected', 'connecting', 'connected', 'disconnecting', 'error', 'unknown'};

final _kindRe = RegExp(r'^[A-Za-z0-9_.:$-]{1,80}$');
final _screenRe = RegExp(r'^[A-Za-z0-9/_.:#-]{1,60}$');
final _coreRe = RegExp(r'^[A-Za-z0-9._+-]{1,32}$');

/// The name of what threw, made fit for the server: other characters become "_", at most 80.
String cleanKind(String? raw) {
  var s = (raw ?? '').replaceAll(RegExp(r'[^A-Za-z0-9_.:$-]+'), '_');
  s = s.replaceAll(RegExp(r'_+$'), '');
  if (s.length > 80) s = s.substring(0, 80);
  return _kindRe.hasMatch(s) ? s : 'Error';
}

/// The page the user was on, or null when it does not fit (no query values, no ids).
String? cleanScreen(String? raw) {
  if (raw == null) return null;
  var s = raw.split('?').first.replaceAll(RegExp(r'[^A-Za-z0-9/_.:#-]+'), '_');
  if (s.length > 60) s = s.substring(0, 60);
  return _screenRe.hasMatch(s) ? s : null;
}

String _utf8Cut(String s, int bytes) {
  while (utf8.encode(s).length > bytes && s.isNotEmpty) {
    s = s.substring(0, (s.length * 0.9).floor());
  }
  return s;
}

/// The body of a report, checked and scrubbed. Throws [PingException] when a needed field is
/// missing or invalid (the server would answer 400); an invalid optional field is left out.
/// The texts are cut: the message and the stack keep their beginning (the top of the stack is what
/// matters), the log keeps its end (the lines just before).
Map<String, Object> buildCrashBody({
  required String os,
  required String appVersion,
  required String kind,
  required String message,
  String? id,
  String? osVersion,
  DeviceFacts facts = const DeviceFacts(),
  bool fatal = false,
  String? screen,
  String? vpnState,
  String? core,
  String? stack,
  String? log,
  Iterable<String> hosts = const [],
}) {
  if (!pingOsNames.contains(os)) throw PingException('bad_os');
  if (!isPingAppVersion(appVersion)) throw PingException('bad_app_version');
  final hostList = hosts.toList();
  String clean(String? t) => scrubText(t ?? '', hosts: hostList);

  var msg = clean(message).trim();
  if (msg.isEmpty) msg = kind;
  if (msg.length > crashMaxMessage) msg = msg.substring(0, crashMaxMessage);
  var st = clean(stack).trim();
  if (st.length > crashMaxStack) st = st.substring(0, crashMaxStack);
  var lg = clean(log).trim();
  if (lg.length > crashMaxLog) lg = lg.substring(lg.length - crashMaxLog);

  final shown = fitFacts(os, {
    for (final e in facts.toJson().entries)
      if (const {'arch', 'brand', 'model', 'build'}.contains(e.key)) e.key: e.value,
  });
  final osv = cleanOsVersion(osVersion);
  final scr = cleanScreen(screen);
  final c = core != null && _coreRe.hasMatch(core) ? core : null;

  Map<String, Object> make() => {
        'v': 1,
        'os': os,
        'app_version': appVersion,
        'message': msg,
        'kind': cleanKind(kind),
        'fatal': fatal,
        if (id != null && RegExp(r'^[0-9a-f]{32,64}$').hasMatch(id)) 'id': id,
        if (osv != null) 'os_version': osv,
        ...shown,
        if (scr != null) 'screen': scr,
        'vpn_state': crashVpnStates.contains(vpnState) ? vpnState! : 'unknown',
        if (c != null) 'core': c,
        if (st.isNotEmpty) 'stack': st,
        if (lg.isNotEmpty) 'log': lg,
      };

  var body = make();
  // Text of other scripts takes up to 4 bytes a character: shorten the log, then the stack, until it fits.
  while (utf8.encode(jsonEncode(body)).length > crashMaxBytes && (lg.isNotEmpty || st.isNotEmpty)) {
    if (lg.isNotEmpty) {
      lg = lg.substring((lg.length * 0.2).ceil());
    } else {
      st = st.substring(0, (st.length * 0.8).floor());
    }
    body = make();
  }
  if (utf8.encode(jsonEncode(body)).length > crashMaxBytes) {
    msg = _utf8Cut(msg, 600);
    body = make();
  }
  return body;
}

/// How a report is told apart from one already sent: kind, message and the top frames.
String crashKey(Map<String, Object> body) {
  final stack = '${body['stack'] ?? ''}'.split('\n').where((l) => l.trim().isNotEmpty).take(3).join('|');
  final msg = '${body['message']}';
  return '${body['kind']}|${msg.length > 200 ? msg.substring(0, 200) : msg}|$stack';
}

typedef CrashSend = Future<int?> Function(UsageEndpoint endpoint, Map<String, Object> body, PingMethod method);

class CrashReporter {
  CrashReporter({
    required this.read,
    required this.write,
    required this.send,
    required this.enabled,
    required this.deviceId,
    required this.os,
    required this.osVersion,
    required this.appVersion,
    required this.endpoints,
    this.facts,
    this.screen,
    this.vpnState,
    this.logLines,
    this.hosts,
    this.log,
    DateTime Function()? now,
    this.maxPerRun = 5,
    this.maxPerDay = 10,
    this.maxQueue = 10,
    this.firstDelay = const Duration(seconds: 40),
    this.recheck = const Duration(hours: 3),
  }) : _now = now ?? DateTime.now;

  static const file = 'crash.json';

  final Future<String?> Function(String name) read;
  final Future<void> Function(String name, String content) write;
  final CrashSend send;

  /// The usage count's switch: false means nothing is queued, kept or sent.
  final bool Function() enabled;
  final Future<String> Function() deviceId;
  final String os;
  final Future<String?> Function() osVersion;
  final Future<String> Function() appVersion;
  final List<UsageEndpoint> Function() endpoints;
  final Future<DeviceFacts> Function()? facts;

  /// The page the user is on, the VPN state, the last lines of the app's own log, and the names of
  /// the user's servers (to be removed from every text).
  final String? Function()? screen;
  final String? Function()? vpnState;
  final List<String> Function()? logLines;
  final Iterable<String> Function()? hosts;
  final void Function(String message)? log;
  final DateTime Function() _now;
  final int maxPerRun;
  final int maxPerDay;
  final int maxQueue;
  final Duration firstDelay;
  final Duration recheck;

  bool _loaded = false;
  String? _day;
  int _dayCount = 0;
  int _runCount = 0;
  String? _nativeSeen;
  final _seen = <String>{};
  final _queue = <Map<String, Object>>[];
  bool _flushing = false;
  Timer? _timer;

  /// The reports waiting to be sent (for tests).
  List<Map<String, Object>> get queued => List.unmodifiable(_queue);

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final text = await read(file);
      if (text == null) return;
      final j = jsonDecode(text);
      if (j is! Map) return;
      _day = j['day'] is String ? j['day'] as String : null;
      _dayCount = j['count'] is int ? j['count'] as int : 0;
      _nativeSeen = j['native_seen'] is String ? j['native_seen'] as String : null;
      final q = j['queue'];
      if (q is List) {
        for (final e in q) {
          if (e is Map && e['message'] is String && e['app_version'] is String && e['os'] is String) {
            _queue.add(e.cast<String, Object>());
          }
        }
        while (_queue.length > maxQueue) {
          _queue.removeAt(0);
        }
      }
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      await write(
          file,
          jsonEncode({
            'day': _day,
            'count': _dayCount,
            'native_seen': _nativeSeen,
            'queue': _queue,
          }));
    } catch (_) {}
  }

  /// Sends what is waiting a little after the app is up, and again every few hours. Returns at once.
  void start() {
    _timer?.cancel();
    _timer = Timer(firstDelay, () {
      flush();
      _timer = Timer.periodic(recheck, (_) => flush());
    });
  }

  void stop() => _timer?.cancel();

  /// The user turned the switch off: whatever waits is deleted.
  Future<void> discard() async {
    await load();
    _queue.clear();
    await _save();
  }

  void _rollDay() {
    final today = pingDay(_now());
    if (_day != today) {
      _day = today;
      _dayCount = 0;
    }
  }

  /// Adds a report to the queue (and tries to send it at once, in the background). Never throws and
  /// never waits for the network. Does nothing while the switch is off, for an error already
  /// reported in this run, and past the limits of the run and of the day.
  Future<void> record({
    required String kind,
    required String message,
    Object? stack,
    bool fatal = false,
    String? log,
  }) async {
    try {
      await load();
      if (!enabled()) return;
      final body = await _build(kind: kind, message: message, stack: stack, fatal: fatal, logText: log);
      if (body == null) return;
      final key = crashKey(body);
      if (_seen.contains(key)) return;
      _rollDay();
      if (_runCount >= maxPerRun || _dayCount >= maxPerDay) return;
      _seen.add(key);
      _runCount++;
      _dayCount++;
      _queue.add(body);
      while (_queue.length > maxQueue) {
        _queue.removeAt(0);
      }
      await _save();
      unawaited(flush());
    } catch (_) {}
  }

  Future<Map<String, Object>?> _build({
    required String kind,
    required String message,
    Object? stack,
    required bool fatal,
    String? logText,
  }) async {
    try {
      String? id;
      try {
        id = await deviceId().timeout(const Duration(seconds: 15));
      } catch (_) {}
      String? osv;
      try {
        osv = await osVersion().timeout(const Duration(seconds: 15));
      } catch (_) {}
      var f = const DeviceFacts();
      if (facts != null) {
        try {
          f = await facts!().timeout(const Duration(seconds: 15));
        } catch (_) {}
      }
      final lines = logLines?.call() ?? const <String>[];
      return buildCrashBody(
        os: os,
        appVersion: await appVersion().timeout(const Duration(seconds: 15)),
        kind: kind,
        message: message,
        id: id,
        osVersion: osv,
        facts: f,
        fatal: fatal,
        screen: screen?.call(),
        vpnState: vpnState?.call(),
        stack: stack?.toString(),
        log: logText ?? lines.join('\n'),
        hosts: hosts?.call() ?? const [],
      );
    } on PingException catch (e) {
      log?.call('Crash report not made: $e');
      return null;
    } catch (_) {
      return null;
    }
  }

  /// The crash an Android process left in its crash file (the first line is the time and the thread,
  /// the rest the trace). Queued once as a fatal report; the same crash is not queued again.
  Future<void> importNative(String? text) async {
    try {
      await load();
      if (text == null || text.trim().isEmpty) return;
      final lines = text.trim().split('\n');
      final header = lines.first.trim();
      if (header == _nativeSeen) return;
      _nativeSeen = header;
      await _save();
      final trace = lines.skip(1).join('\n');
      final first = lines.length > 1 ? lines[1].trim() : header;
      await record(kind: 'native_crash', message: first, stack: trace, fatal: true);
    } catch (_) {}
  }

  /// Sends the waiting reports, the oldest first. Stops at the first one that cannot be delivered
  /// (offline, 429): nothing is hammered. True when nothing is left to do for now.
  Future<bool> flush() async {
    if (_flushing) return true;
    _flushing = true;
    try {
      await load();
      while (_queue.isNotEmpty) {
        if (!enabled()) {
          await discard();
          return true;
        }
        final body = _queue.first;
        final r = await _deliver(body);
        if (r == _Outcome.retry) return false;
        // Sent, or refused by the server for good: either way it leaves the queue.
        if (_queue.isNotEmpty && identical(_queue.first, body)) _queue.removeAt(0);
        await _save();
      }
      return true;
    } catch (_) {
      return false;
    } finally {
      _flushing = false;
    }
  }

  Future<_Outcome> _deliver(Map<String, Object> body) async {
    for (final method in const [PingMethod.direct, PingMethod.fragment]) {
      for (final endpoint in endpoints()) {
        if (!enabled()) return _Outcome.retry;
        int? status;
        try {
          status = await send(endpoint, body, method).timeout(const Duration(seconds: 25));
        } catch (_) {
          status = null;
        }
        if (status == 200) return _Outcome.sent;
        if (status == 429) {
          log?.call('Crash report: the server asked to slow down (429)');
          return _Outcome.retry;
        }
        if (status != null && status >= 400 && status < 500 && status != 408) {
          log?.call('Crash report refused by the server ($status), dropped');
          return _Outcome.refused;
        }
      }
    }
    return _Outcome.retry;
  }
}

enum _Outcome { sent, refused, retry }
