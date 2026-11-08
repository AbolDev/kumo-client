import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/usage/crash_hub.dart';
import '../core/usage/crash_report.dart';
import '../core/usage/usage_endpoints.dart';
import '../core/usage/usage_reporter.dart';
import '../core/usage/usage_system.dart';
import '../core/usage/usage_transport.dart';
import '../core/vpn_channel.dart';

/// Wires the anonymous usage ping (see core/usage) into the app: the signed list of addresses, the
/// reporter and the settings switch. Everything runs in the background and fails silently.
class UsageController extends ChangeNotifier {
  UsageController({
    required bool Function() tunnelUp,
    required FragmentSettings Function() fragment,
    required String? Function() appLanguage,
    void Function(String message)? log,
    String? Function()? screen,
    String? Function()? vpnState,
    List<String> Function()? logLines,
    Iterable<String> Function()? hosts,
  }) {
    store = UsageEndpointStore(
      read: VpnChannel.readFile,
      write: VpnChannel.writeFile,
      fetch: fetchText,
    );
    reporter = UsageReporter(
      read: VpnChannel.readFile,
      write: VpnChannel.writeFile,
      send: (endpoint, body, method) => sendUsagePing(endpoint, body, method, fragment: fragment),
      systemId: readSystemId,
      os: usageOsName(),
      osVersion: readOsVersion,
      appVersion: () async => (await PackageInfo.fromPlatform()).version,
      tunnelUp: tunnelUp,
      endpoints: () => store.current.endpoints,
      countryHint: localeCountry,
      facts: () => readDeviceFacts(appLanguage: appLanguage()),
      log: log,
    );
    // Crash reports: the same switch, the same addresses and the same way of sending.
    crash = CrashReporter(
      read: VpnChannel.readFile,
      write: VpnChannel.writeFile,
      send: (endpoint, body, method) =>
          sendUsagePing(endpoint, body, method, fragment: fragment, path: crashPath),
      // Not known yet (the saved choice is still being read): nothing is reported.
      enabled: () => reporter.ready && reporter.enabled,
      deviceId: reporter.deviceId,
      os: usageOsName(),
      osVersion: readOsVersion,
      appVersion: () async => (await PackageInfo.fromPlatform()).version,
      endpoints: () => store.current.endpoints,
      facts: () => readDeviceFacts(appLanguage: appLanguage()),
      screen: screen,
      vpnState: vpnState,
      logLines: logLines,
      hosts: hosts,
      log: log,
    );
    CrashHub.sink = crash;
  }

  late final UsageEndpointStore store;
  late final UsageReporter reporter;
  late final CrashReporter crash;

  bool get enabled => reporter.enabled;

  /// The code that is sent in place of the device id (shown in Settings).
  Future<String> code() => reporter.deviceId(limit: false);

  /// Loads the choice and starts the background work. Returns at once.
  Future<void> startup() async {
    await reporter.load();
    notifyListeners();
    await store.load();
    reporter.start();
    // A crash of the last run that the phone's crash handler wrote down is queued first.
    if (Platform.isAndroid && reporter.enabled) {
      try {
        await crash.importNative(await VpnChannel.readFile('crash.log'));
      } catch (_) {}
    }
    crash.start();
    // The list of addresses is looked for a little later, so it never competes with the start.
    unawaited(Future<void>.delayed(const Duration(seconds: 60), () => store.update()).catchError((Object _) => false));
  }

  Future<void> setEnabled(bool on) async {
    await reporter.setEnabled(on);
    if (!on) await crash.discard(); // reports that wait are deleted with the switch
    notifyListeners();
  }
}
