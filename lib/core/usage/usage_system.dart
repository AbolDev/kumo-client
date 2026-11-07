import 'dart:io';

import 'package:flutter/services.dart' show MethodChannel;

import 'usage_ping.dart';

const _control = MethodChannel('kumo/control');

/// The name of this system as the server knows it.
String usageOsName() => Platform.isAndroid
    ? 'android'
    : Platform.isWindows
        ? 'windows'
        : Platform.isMacOS
            ? 'macos'
            : 'linux';

/// The id the system keeps for this computer or phone, never sent as it is (see [hashDeviceId]):
/// Android `ANDROID_ID`, Windows `MachineGuid`, macOS `IOPlatformUUID`, Linux `/etc/machine-id`.
/// Null when it cannot be read.
Future<String?> readSystemId() async {
  try {
    if (Platform.isAndroid) return await _control.invokeMethod<String>('androidId');
    if (Platform.isWindows) {
      final r = await Process.run(
          'reg', ['query', r'HKLM\SOFTWARE\Microsoft\Cryptography', '/v', 'MachineGuid', '/reg:64']);
      final m = RegExp(r'MachineGuid\s+REG_SZ\s+([0-9A-Za-z-]+)').firstMatch('${r.stdout}');
      return m?[1];
    }
    if (Platform.isMacOS) {
      final r = await Process.run('/usr/sbin/ioreg', ['-rd1', '-c', 'IOPlatformExpertDevice']);
      final m = RegExp(r'"IOPlatformUUID"\s*=\s*"([0-9A-Fa-f-]+)"').firstMatch('${r.stdout}');
      return m?[1];
    }
    for (final path in const ['/etc/machine-id', '/var/lib/dbus/machine-id']) {
      final f = File(path);
      if (await f.exists()) {
        final id = (await f.readAsString()).trim();
        if (id.isNotEmpty) return id;
      }
    }
  } catch (_) {}
  return null;
}

/// The version of the system ("14 (API 34)", "10.0 (Build 26100)"), cut to what the server takes.
Future<String?> readOsVersion() async {
  try {
    if (Platform.isAndroid) return cleanOsVersion(await _control.invokeMethod<String>('osRelease'));
    return cleanOsVersion(Platform.operatingSystemVersion);
  } catch (_) {
    return null;
  }
}

/// The country the system's language settings name ("fa_IR" -> "IR"), or null.
String? localeCountry() {
  final m = RegExp(r'^[A-Za-z]{2,3}[-_]([A-Za-z]{2})\b').firstMatch(Platform.localeName);
  final c = m?[1]?.toUpperCase();
  return isCountry(c) ? c : null;
}
