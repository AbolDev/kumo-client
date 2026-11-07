import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

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
    );
  }

  late final UsageEndpointStore store;
  late final UsageReporter reporter;

  bool get enabled => reporter.enabled;

  /// Loads the choice and starts the background work. Returns at once.
  Future<void> startup() async {
    await reporter.load();
    notifyListeners();
    await store.load();
    reporter.start();
    // The list of addresses is looked for a little later, so it never competes with the start.
    unawaited(Future<void>.delayed(const Duration(seconds: 60), () => store.update()).catchError((Object _) => false));
  }

  Future<void> setEnabled(bool on) async {
    await reporter.setEnabled(on);
    notifyListeners();
  }
}
