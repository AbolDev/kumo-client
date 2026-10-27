import 'package:flutter/services.dart';

import 'desktop_vpn.dart';
import 'xray_delay.dart';
import 'platform.dart';

enum VpnStatus { stopped, starting, started, stopping, error }

class VpnState {
  const VpnState(this.status, [this.error, this.standby = false]);
  final VpnStatus status;
  final String? error;

  /// Android: only the local proxy is running (the tunnel is off).
  final bool standby;
}

/// Live speed and totals since the connection started, in bytes.
class Traffic {
  const Traffic(this.up, this.down, this.upTotal, this.downTotal);
  static const zero = Traffic(0, 0, 0, 0);
  final int up, down, upTotal, downTotal;
}

/// Bridge to the native sing-box VPN: the Android service (see BoxVpnService.kt), or the
/// child process managed by [DesktopVpn] on Windows.
class VpnChannel {
  static const _control = MethodChannel('kumo/control');
  static const _events = EventChannel('kumo/status');

  static const _traffic = EventChannel('kumo/traffic');

  static final bool _win = isDesktop;

  static Stream<Traffic> get traffic => _win
      ? DesktopVpn.instance.traffic
      : _traffic.receiveBroadcastStream().map((e) {
        final l = (e as List).map((v) => (v as num).toInt()).toList();
        return Traffic(l[0], l[1], l[2], l[3]);
      });

  static Stream<VpnState> get states => _win
      ? DesktopVpn.instance.states
      : _events.receiveBroadcastStream().map((e) {
        final m = Map<String, dynamic>.from(e as Map);
        return VpnState(
          VpnStatus.values.firstWhere((s) => s.name == m['status'],
              orElse: () => VpnStatus.stopped),
          m['error'] as String?,
          m['standby'] == true,
        );
      });

  /// Shows the system VPN consent dialog if needed. Returns false when refused.
  static Future<bool> prepare() async => _win
      ? true
      : (await _control.invokeMethod<bool>('prepare')) ?? false;

  /// [serverNames] are the display names of the servers in [configJson], in order
  /// (the notification uses them to show the server that is in use).
  ///
  /// [xrayConfig] (with the SOCKS [xrayPort] sing-box connects to) starts the Xray process
  /// that XHTTP servers need.
  static Future<void> start(
    String configJson, {
    List<String> serverNames = const [],
    String? xrayConfig,
    int? xrayPort,
    bool showSpeed = true,
    bool showVolume = false,
    bool showName = true,
    int? apiPort,
    String? apiSecret,
    int? systemProxyPort,
    bool killSwitch = false,
    bool keepStandby = false,
    String? standbyConfig,
    String? standbyXrayConfig,
    int? proxyPort,
  }) =>
      _win
      ? DesktopVpn.instance.start(configJson,
          xrayConfig: xrayConfig,
          xrayPort: xrayPort,
          apiPort: apiPort ?? 9090,
          apiSecret: apiSecret,
          systemProxyPort: systemProxyPort,
          killSwitch: killSwitch,
          keepStandby: keepStandby)
      : _control.invokeMethod('start', {
        'config': configJson,
        'names': serverNames,
        'xrayConfig': xrayConfig,
        'showSpeed': showSpeed,
        'showVolume': showVolume,
        'showName': showName,
        'killSwitch': killSwitch,
        'standbyConfig': standbyConfig,
        'standbyXrayConfig': standbyXrayConfig,
        'xrayPort': xrayPort,
        'proxyPort': proxyPort,
      });

  /// Real delay in ms: fetches [url] through a temporary core built from [configJson]
  /// (which must hold an outbound tagged `proxy`). -1 when it fails.
  static Future<int> delay(String configJson, String url,
          {int timeoutMs = 8000}) async =>
      _win
          ? DesktopVpn.instance.delay(configJson, url, timeoutMs)
          : (await _control.invokeMethod<int>(
          'delay', {'config': configJson, 'url': url, 'timeout': timeoutMs})) ??
      -1;

  /// Real delay of a server only Xray can carry, -1 on failure (see [runXrayDelay]).
  static Future<int> xrayDelay(String Function(int port) config, String url,
      {int timeoutMs = 8000}) async {
    final dir = await dataDir();
    if (_win) {
      return runXrayDelay(
          exe: DesktopVpn.instance.xrayExecutable,
          dataDir: dir,
          config: config,
          url: url,
          timeoutMs: timeoutMs,
          spawn: DesktopVpn.instance.spawnQuiet);
    }
    final exe = await _control.invokeMethod<String>('xrayPath');
    if (exe == null) return -1;
    return runXrayDelay(
        exe: exe, dataDir: dir, config: config, url: url, timeoutMs: timeoutMs, resolveNames: true);
  }

  /// Desktop: keeps the local proxy running while the VPN is off (see [DesktopVpn.startStandby]).
  static Future<bool> startStandby(String configJson,
          {String? xrayConfig, int? xrayPort, required int apiPort, String? apiSecret, int? proxyPort}) =>
      _win
          ? DesktopVpn.instance.startStandby(configJson,
              xrayConfig: xrayConfig, xrayPort: xrayPort, apiPort: apiPort, apiSecret: apiSecret)
          : _control
              .invokeMethod<bool>('startStandby', {
                'config': configJson,
                'xrayConfig': xrayConfig,
                'xrayPort': xrayPort,
                'proxyPort': proxyPort,
              })
              .then((v) => v ?? false);

  /// Desktop: the standby core becomes the connection (false when it is not running).
  static Future<bool> adoptStandby({required int systemProxyPort}) => _win
      ? DesktopVpn.instance.adoptStandby(systemProxyPort: systemProxyPort)
      : Future.value(false);

  static Future<void> stopStandby() async {
    if (_win) {
      await DesktopVpn.instance.stopStandby();
    } else {
      await _control.invokeMethod('stopStandby');
    }
  }

  static Future<void> stop() =>
      _win ? DesktopVpn.instance.stop() : _control.invokeMethod('stop');

  /// Turns the background subscription download job on or off.
  static Future<void> scheduleSubUpdates(bool enabled) async =>
      _win ? null : _control.invokeMethod('scheduleSubUpdates', {'enabled': enabled});

  /// Android: whether the Wi-Fi network's name can be read (it needs the location permission,
  /// which is asked for when [request] is true), and the name of the network the phone is on.
  static Future<({bool granted, String? name})> wifiAccess({bool request = false}) async {
    if (_win) return (granted: false, name: null);
    try {
      final m = await _control.invokeMapMethod<String, dynamic>('wifiAccess', {'request': request});
      return (granted: m?['granted'] == true, name: m?['name'] as String?);
    } catch (_) {
      return (granted: false, name: null);
    }
  }

  /// Android: lets the phone warn about a subscription that is nearly out of data or time.
  static Future<void> checkUsage(
      String id, String name, int used, int total, int expire) async {
    if (_win) return;
    try {
      await _control.invokeMethod('usageCheck', {
        'id': id,
        'name': name,
        'used': used,
        'total': total,
        'expire': expire,
      });
    } catch (_) {}
  }

  /// Android: shows or removes the "not connected" notification (it is only shown while the VPN is off).
  static Future<void> setIdleNotification(bool enabled) async {
    if (_win) return;
    try {
      await _control.invokeMethod('idleNotification', {'enabled': enabled});
    } catch (_) {}
  }

  /// Whether Android already lets the app run without battery restrictions.
  static Future<bool> batteryUnrestricted() async => _win
      ? true
      : (await _control.invokeMethod<bool>('batteryUnrestricted')) ?? true;

  /// Shows the system dialog that lifts the battery restriction.
  static Future<void> requestBatteryExemption() async =>
      _win ? null : _control.invokeMethod('requestBatteryExemption');

  /// Reads a small text file from the app's private storage, null if missing.
  static Future<String?> readFile(String name) => _win
      ? DesktopVpn.instance.readFile(name)
      : _control.invokeMethod<String>('readFile', {'name': name});

  static Future<void> writeFile(String name, String content) => _win
      ? DesktopVpn.instance.writeFile(name, content)
      : _control.invokeMethod('writeFile', {'name': name, 'content': content});

  /// Android: opens the system VPN settings, where Always-on VPN and blocking can be set.
  static Future<void> openVpnSettings() async {
    if (!_win) await _control.invokeMethod('vpnSettings');
  }

  /// The app's private folder (rule sets and other downloaded files live there).
  static Future<String> dataDir() async => _win
      ? DesktopVpn.instance.dataDir
      : (await _control.invokeMethod<String>('filesDir'))!;

  /// Apps that can be chosen for per-app routing: installed apps on Android, running
  /// programs on Windows.
  static Future<List<AppEntry>> listApps() async {
    if (_win) return DesktopVpn.instance.runningProcesses();
    final raw = await _control.invokeListMethod<Map>('apps') ?? const [];
    return [
      for (final m in raw) AppEntry('${m['id']}', '${m['label']}'),
    ];
  }

  /// Android: the CPU types of this phone, best first (arm64-v8a, armeabi-v7a, ...).
  static Future<List<String>> abis() async {
    if (_win) return const [];
    try {
      return (await _control.invokeListMethod<String>('abis')) ?? const [];
    } catch (_) {
      return const [];
    }
  }

  /// Android: whether Kumo is allowed to install apps.
  static Future<bool> canInstallApk() async {
    try {
      return await _control.invokeMethod<bool>('canInstall') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Android: opens the system screen where the user allows Kumo to install apps.
  static Future<void> allowInstallApk() async {
    try {
      await _control.invokeMethod<bool>('allowInstall');
    } catch (_) {}
  }

  /// Android: opens the installer for a downloaded APK. Returns ok, permission (the user must
  /// first allow installs from Kumo) or failed.
  static Future<String> installApk(String path) async {
    try {
      return await _control.invokeMethod<String>('installApk', {'path': path}) ?? 'failed';
    } catch (_) {
      return 'failed';
    }
  }

  /// Android: opens a link in the app that handles it. False when no app does.
  static Future<bool> openUrl(String url) async {
    if (_win) return false;
    try {
      return await _control.invokeMethod<bool>('openUrl', {'url': url}) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Android: the launcher icon of an installed app as PNG bytes, or null.
  static Future<Uint8List?> appIcon(String id) async {
    if (_win) return null;
    try {
      return await _control.invokeMethod<Uint8List>('appIcon', {'id': id});
    } catch (_) {
      return null;
    }
  }
}

/// An app in the per-app routing list: [id] is the package or process name.
class AppEntry {
  const AppEntry(this.id, this.label);
  final String id;
  final String label;
}
