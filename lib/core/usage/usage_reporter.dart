import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'usage_endpoints.dart';
import 'usage_ping.dart';

/// How a request is made: straight to the server, or through a local relay that cuts the first bytes
/// of the TLS hello into small pieces so a filter cannot read the server's name.
enum PingMethod { direct, fragment }

/// Sends [body] to [endpoint] and returns the HTTP status; null (or an exception) when no answer came.
typedef PingSend = Future<int?> Function(UsageEndpoint endpoint, Map<String, Object> body, PingMethod method);

/// Sends the anonymous usage ping: at most once a day (and once more when the app version changed),
/// in the background, never blocking anything and never showing an error. When the user turns it off
/// ONE last message ("opt_out") is sent and then nothing, until it is turned on again.
///
/// Where a ping goes: first straight to the server from outside the VPN tunnel, then through the
/// fragmenting relay, and while the VPN is up through the tunnel ("via_tunnel": true, with the last
/// country seen outside it, since Cloudflare would see the VPN's). The endpoints are tried in the order
/// of the (signed) list.
class UsageReporter {
  UsageReporter({
    required this.read,
    required this.write,
    required this.send,
    required this.systemId,
    required this.os,
    required this.osVersion,
    required this.appVersion,
    required this.tunnelUp,
    required this.endpoints,
    required this.countryHint,
    this.facts = _noFacts,
    this.log,
    DateTime Function()? now,
    Random? random,
    this.firstDelay = const Duration(seconds: 25),
    this.recheck = const Duration(hours: 3),
    this.backoff = const [Duration(minutes: 15), Duration(hours: 1), Duration(hours: 4), Duration(hours: 12)],
  })  : _now = now ?? DateTime.now,
        _random = random ?? Random.secure();

  static const file = 'usage.json';

  final Future<String?> Function(String name) read;
  final Future<void> Function(String name, String content) write;
  final PingSend send;

  /// The id the system keeps for this computer or phone (ANDROID_ID, MachineGuid, IOPlatformUUID,
  /// /etc/machine-id); null when it cannot be read.
  final Future<String?> Function() systemId;
  final String os;
  final Future<String?> Function() osVersion;
  final Future<String> Function() appVersion;

  /// True while the VPN carries this app's own traffic.
  final bool Function() tunnelUp;
  final List<UsageEndpoint> Function() endpoints;

  /// The country the phone or computer says it is in (two letters), or null.
  final String? Function() countryHint;

  /// The optional facts (languages, region, time zone, phone, processor); each is checked when the
  /// ping is built and dropped when it does not fit.
  final Future<DeviceFacts> Function() facts;

  /// Where a short note goes (the app's own log, never sent anywhere). Only reasons and status codes,
  /// never the id or the body.
  final void Function(String message)? log;
  final DateTime Function() _now;
  final Random _random;
  final Duration firstDelay;
  final Duration recheck;
  final List<Duration> backoff;

  bool _loaded = false;
  bool _enabled = true;
  String? _day;
  String? _version;
  bool _optOutSent = false;
  String? _country;
  String? _fallbackId;
  bool _busy = false;

  /// The switch was changed while a delivery was running: look again soon after it ends.
  bool _rerun = false;
  int _failures = 0;
  Timer? _timer;

  /// Sending is on unless the user turned it off.
  bool get enabled => _enabled;

  /// True once the saved choice has been read (before that the switch is not known).
  bool get ready => _ready;
  bool _ready = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      await _read();
    } finally {
      _ready = true;
    }
  }

  Future<void> _read() async {
    try {
      final text = await read(file);
      if (text == null) return;
      final j = jsonDecode(text);
      if (j is! Map) return;
      if (j['enabled'] is bool) _enabled = j['enabled'] as bool;
      _day = j['day'] is String ? j['day'] as String : null;
      _version = j['version'] is String ? j['version'] as String : null;
      _optOutSent = j['opt_out_sent'] == true;
      _country = isCountry(j['country'] as String?) ? j['country'] as String : null;
      _fallbackId = j['fallback_id'] is String ? j['fallback_id'] as String : null;
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      await write(
          file,
          jsonEncode({
            'enabled': _enabled,
            'day': _day,
            'version': _version,
            'opt_out_sent': _optOutSent,
            'country': _country,
            'fallback_id': _fallbackId,
          }));
    } catch (_) {}
  }

  /// Starts the background work: the first check a little after the app is up, then every few hours.
  void start() {
    _timer?.cancel();
    _timer = Timer(firstDelay, _run);
  }

  void stop() => _timer?.cancel();

  void _schedule(Duration d) {
    _timer?.cancel();
    _timer = Timer(d, _run);
  }

  Future<void> _run() async {
    var done = true;
    try {
      done = await tick();
    } catch (_) {}
    if (_rerun) {
      _rerun = false;
      _schedule(const Duration(seconds: 2));
    } else if (done) {
      _failures = 0;
      _schedule(recheck);
    } else {
      final d = backoff[min(_failures, backoff.length - 1)];
      _failures++;
      _schedule(d);
    }
  }

  /// The user's choice. Turning it off sends the one last "opt_out"; turning it on sends a ping again.
  Future<void> setEnabled(bool on) async {
    await load();
    if (_enabled == on) return;
    _enabled = on;
    _optOutSent = false;
    if (on) {
      _day = null;
      _version = null;
    }
    await _save();
    _failures = 0;
    if (_busy) {
      _rerun = true; // the running delivery ends first, then this is looked at
    } else {
      _schedule(const Duration(seconds: 2));
    }
  }

  /// [f] with a limit, so a call that never comes back (a program that hangs while the system id is
  /// read) cannot hold the reporter for good.
  Future<T> _within<T>(Future<T> f) => f.timeout(const Duration(seconds: 15));

  /// The id sent: the salted hash of the system id. When the system id cannot be read, a random one
  /// kept in the app's own storage stands in (it does not survive a reinstall, the system id does).
  Future<String> deviceId({bool limit = true}) async {
    String? sys;
    try {
      sys = await (limit ? _within(systemId()) : systemId());
    } catch (_) {}
    if (sys != null && sys.trim().length >= 8) return hashDeviceId(sys);
    if (_fallbackId == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(_fallbackId!)) {
      _fallbackId = [for (var i = 0; i < 32; i++) _random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
      await _save();
    }
    return _fallbackId!;
  }

  /// Does what is due now. True when nothing is left to do (done, off, or not worth another try
  /// today), false when the delivery failed and should be tried again later. Never throws.
  Future<bool> tick() async {
    if (_busy) return true;
    _busy = true;
    try {
      await load();
      if (!_enabled) {
        if (_optOutSent) return true;
        final r = await _deliver('opt_out');
        if (r != _Result.retry && !_enabled) {
          _optOutSent = true;
          await _save();
        }
        return r != _Result.retry;
      }
      final version = await _within(appVersion());
      final today = pingDay(_now());
      if (_day == today && _version == version) return true;
      final r = await _deliver('ping');
      // Turned off while it was being sent: nothing is kept, the "opt_out" is next.
      if (!_enabled) return true;
      if (r != _Result.retry) {
        // Also when the server refused the ping itself: asking again the same way would not change
        // the answer, so it waits for tomorrow (or the next version).
        _day = today;
        _version = version;
        await _save();
      }
      return r != _Result.retry;
    } catch (_) {
      return false;
    } finally {
      _busy = false;
    }
  }

  Future<_Result> _deliver(String event) async {
    final id = await deviceId();
    final version = await _within(appVersion());
    String? osv;
    try {
      osv = await _within(osVersion());
    } catch (_) {}
    var extra = const DeviceFacts();
    if (event == 'ping') {
      try {
        extra = await _within(facts());
      } catch (_) {}
    }
    final methods = [PingMethod.direct, PingMethod.fragment];
    for (final method in methods) {
      for (final endpoint in endpoints()) {
        // Turned off meanwhile: no further request of a ping.
        if (event == 'ping' && !_enabled) return _Result.retry;
        // Read for each request: the VPN can come up or go down while the routes are tried.
        final tunnel = tunnelUp();
        final Map<String, Object> body;
        try {
          body = buildPing(
            event: event,
            id: id,
            os: os,
            appVersion: version,
            osVersion: osv,
            viaTunnel: tunnel,
            country: tunnel ? (_country ?? countryHint()) : null,
            facts: extra,
          );
        } on PingException catch (e) {
          log?.call('Usage count not sent: $e');
          return _Result.refused; // a ping the server would refuse is never sent
        }
        int? status;
        try {
          status = await send(endpoint, body, method).timeout(const Duration(seconds: 25));
        } catch (_) {
          status = null;
        }
        if (status == 200) {
          // Outside the tunnel the server sees the real country; remember what this device says it
          // is, to use for pings that have to leave from inside the tunnel.
          final hint = countryHint();
          if (!tunnel && isCountry(hint) && hint != _country) {
            _country = hint;
            await _save();
          }
          return _Result.sent;
        }
        // Too many requests from this address: no other route is tried now (that would only make it
        // worse); the next try follows the normal retry pause.
        if (status == 429) {
          log?.call('Usage count: the server asked to slow down (429)');
          return _Result.retry;
        }
        // The server read it and said no: another route will not change that.
        if (status != null && status >= 400 && status < 500 && status != 408) {
          log?.call('Usage count refused by the server ($status), not sent again today');
          return _Result.refused;
        }
      }
    }
    return _Result.retry;
  }
}

enum _Result { sent, refused, retry }

Future<DeviceFacts> _noFacts() async => const DeviceFacts();
