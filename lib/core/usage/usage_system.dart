import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart' show MethodChannel;

import 'usage_build.dart';
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
    if (Platform.isWindows) return windowsVersionName(Platform.operatingSystemVersion);
    return cleanOsVersion(Platform.operatingSystemVersion);
  } catch (_) {
    return null;
  }
}

/// The IANA name of the Windows time zone ("Iran Standard Time" -> "Asia/Tehran"), asked of the ICU
/// library that ships with Windows 10 and up. Null when it cannot be had.
String? _windowsTimeZone(String windowsId) {
  Pointer<Uint16>? win, out;
  Pointer<Int32>? status;
  try {
    final icu = DynamicLibrary.open('icu.dll');
    final convert = icu.lookupFunction<
        Int32 Function(Pointer<Uint16>, Int32, Pointer<Utf8>, Pointer<Uint16>, Int32, Pointer<Int32>),
        int Function(Pointer<Uint16>, int, Pointer<Utf8>, Pointer<Uint16>, int,
            Pointer<Int32>)>('ucal_getTimeZoneIDForWindowsID');
    win = calloc<Uint16>(windowsId.length + 1);
    for (var i = 0; i < windowsId.length; i++) {
      win[i] = windowsId.codeUnitAt(i);
    }
    out = calloc<Uint16>(64);
    status = calloc<Int32>();
    final n = convert(win, windowsId.length, nullptr, out, 64, status);
    if (status.value > 0 || n <= 0 || n >= 64) return null;
    return String.fromCharCodes([for (var i = 0; i < n; i++) out[i]]);
  } catch (_) {
    return null;
  } finally {
    if (win != null) calloc.free(win);
    if (out != null) calloc.free(out);
    if (status != null) calloc.free(status);
  }
}

Future<String?> _readTimeZone() async {
  try {
    if (Platform.isWindows) {
      final r = await Process.run('reg', [
        'query',
        r'HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation',
        '/v',
        'TimeZoneKeyName',
      ]);
      final m = RegExp(r'TimeZoneKeyName\s+REG_SZ\s+(.+)').firstMatch('${r.stdout}');
      final id = m?[1]?.trim();
      return id == null || id.isEmpty ? null : _windowsTimeZone(id);
    }
    // Linux and macOS: /etc/localtime points into the zoneinfo folder, whose path ends with the name.
    final link = Link('/etc/localtime');
    if (await link.exists()) {
      final m = RegExp(r'zoneinfo/(.+)$').firstMatch(await link.target());
      if (m != null) return m[1];
    }
    final f = File('/etc/timezone');
    if (await f.exists()) return (await f.readAsString()).trim();
  } catch (_) {}
  return null;
}

/// The processor of a desktop computer. On Windows the machine's, not the program's (an x64 program
/// on an ARM PC runs emulated).
String? _desktopArch() {
  if (Platform.isWindows) {
    final env = Platform.environment;
    return archName(env['PROCESSOR_ARCHITEW6432'] ?? env['PROCESSOR_ARCHITECTURE']);
  }
  final abi = Abi.current().toString(); // "linux_arm64", "macos_x64"
  return archName(abi.split('_').last);
}

/// The facts the ping lists besides the version: the app's language when the user chose one
/// ([appLanguage]), the device's language and region, the time zone, the processor, and on Android
/// the phone's maker, model and interface. Each is null when it cannot be read. Never throws.
Future<DeviceFacts> readDeviceFacts({String? appLanguage}) async {
  String? brand, model, ui, arch, tz;
  try {
    if (Platform.isAndroid) {
      final raw = await _control.invokeMapMethod<String, String?>('deviceInfo');
      if (raw != null) {
        brand = raw['brand'];
        model = raw['model'];
        arch = archName(raw['abi']);
        tz = raw['tz'];
        ui = androidUiName(
            brand: brand,
            oneui: raw['oneui'],
            miui: raw['miui'],
            mios: raw['mios'],
            oplus: raw['oplus']);
      }
    } else {
      arch = _desktopArch();
      tz = await _readTimeZone();
    }
  } catch (_) {}
  return DeviceFacts(
    lang: appLanguage,
    deviceLang: Platform.localeName,
    region: localeCountry(),
    tz: tz,
    brand: brand,
    model: model,
    ui: ui,
    arch: arch,
    build: installedBuildName(),
  );
}

/// The country the system's language settings name ("fa_IR" -> "IR"), or null.
String? localeCountry() {
  final m = RegExp(r'^[A-Za-z]{2,3}[-_]([A-Za-z]{2})\b').firstMatch(Platform.localeName);
  final c = m?[1]?.toUpperCase();
  return isCountry(c) ? c : null;
}
