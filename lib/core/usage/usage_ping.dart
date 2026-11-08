import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' show SHA256Digest;

/// The anonymous usage ping (format v1). What it may hold is decided by the server
/// (worker/src/validate.js); the checks here are the same, so a ping that would be refused is never
/// sent.

const pingSchema = 1;
const pingOsNames = {'android', 'windows', 'macos', 'linux', 'ios'};

/// The most the server takes in one request.
const pingMaxBytes = 2048;

/// Mixed into the system id before it is hashed, so the hash is only good for Kumo: the same
/// computer gives another value anywhere else, and the raw id is never sent.
const idSalt = 'kumo-usage-ping/v1/';

final _idRe = RegExp(r'^[0-9a-f]{32,64}$');
final _appVersionRe = RegExp(r'^\d{1,4}\.\d{1,4}\.\d{1,4}(?:[-+][0-9A-Za-z.+-]{1,32})?$');
final _osVersionRe = RegExp(r'^[\w .,+()-]{1,64}$');
final _countryRe = RegExp(r'^[A-Z]{2}$');

final _langRe = RegExp(r'^[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})?$');
final _deviceLangRe = RegExp(r'^[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{2,8}){0,2}$');
final _tzRe = RegExp(r'^[A-Za-z][A-Za-z0-9_+-]*(?:/[A-Za-z0-9_+-]+){0,2}$');
final _brandRe = RegExp(r'^[A-Za-z0-9][A-Za-z0-9 ._+-]{0,29}$');
final _modelRe = RegExp(r'^[A-Za-z0-9][A-Za-z0-9 ._+()/,-]{0,39}$');

/// What a maker, model or interface name may hold, for [cleanFact].
final _nameChars = RegExp(r'[^A-Za-z0-9 ._+-]');
final _modelChars = RegExp(r'[^A-Za-z0-9 ._+()/,-]');

/// Texts that firmware leaves in place of a real name; they say nothing about the device.
const _placeholders = {
  'to be filled by o.e.m.',
  'to be filled by oem',
  'system product name',
  'system manufacturer',
  'system version',
  'system family',
  'default string',
  'default',
  'unknown',
  'not specified',
  'not applicable',
  'n/a',
  'none',
  'o.e.m.',
  'oem',
  'type1productconfigid',
  'undefined',
  'invalid',
};

/// A maker, model or interface name made fit for the server: characters it does not take become
/// spaces, runs of spaces become one, the text is cut to [max] characters (a long name is shortened,
/// not dropped), and null is returned for a placeholder, an empty text, or one that still does not
/// fit (it must start with a letter or digit).
String? cleanFact(String? raw, {required int max, bool model = false}) {
  if (raw == null) return null;
  var s = raw.replaceAll(model ? _modelChars : _nameChars, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (_placeholders.contains(s.toLowerCase())) return null;
  if (s.length > max) s = s.substring(0, max).trim();
  if (s.isEmpty) return null;
  return (model ? _modelRe : max <= 30 ? _brandRe : _uiRe).hasMatch(s) ? s : null;
}

/// Windows: the maker and model from the text of `reg query HKLM\HARDWARE\DESCRIPTION\System\BIOS`.
/// The maker is SystemManufacturer, or SystemFamily when that is a placeholder.
({String? brand, String? model}) parseWindowsBios(String regOutput) {
  String? value(String name) =>
      RegExp('^\\s*$name\\s+REG_SZ\\s+(.*)\$', multiLine: true).firstMatch(regOutput)?[1]?.trim();
  return (
    brand: cleanFact(value('SystemManufacturer'), max: 30) ?? cleanFact(value('SystemFamily'), max: 30),
    model: cleanFact(value('SystemProductName'), max: 40, model: true),
  );
}

/// macOS: the model identifier from `sysctl -n hw.model` ("MacBookPro18,3"). The maker is Apple.
({String? brand, String? model}) parseMacModel(String sysctlOutput) {
  final model = cleanFact(sysctlOutput, max: 40, model: true);
  return (brand: model == null ? null : 'Apple', model: model);
}

/// Linux: the maker and model from the files of /sys/class/dmi/id, and the desktop from
/// XDG_CURRENT_DESKTOP ("ubuntu:GNOME" gives "GNOME"). Whatever is missing or a placeholder is null.
({String? brand, String? model, String? ui}) linuxDeviceNames({
  String? vendor,
  String? product,
  String? family,
  String? desktop,
}) {
  final parts = (desktop ?? '').split(':').map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
  return (
    brand: cleanFact(vendor, max: 30),
    model: cleanFact(product, max: 40, model: true) ?? cleanFact(family, max: 40, model: true),
    ui: parts.isEmpty ? null : cleanFact(parts.last, max: 40),
  );
}
final _uiRe = RegExp(r'^[A-Za-z0-9][A-Za-z0-9 ._+-]{0,39}$');
const pingArches = {'arm64', 'armv7', 'x64', 'x86', 'riscv64', 'other'};
final _buildRe = RegExp(r'^kumo-[a-z0-9]+-[A-Za-z0-9._-]+$');

/// True when [name] is a release file name the server takes: "kumo-", the system, a dash and the
/// rest, at most 64 characters.
bool isBuildName(String? name) => name != null && name.length <= 64 && _buildRe.hasMatch(name);

/// The optional facts about the device and the app's language. Each is left out of the ping when it
/// is not known or does not fit what the server takes: never an empty text, never a guess.
class DeviceFacts {
  const DeviceFacts({
    this.lang,
    this.deviceLang,
    this.region,
    this.tz,
    this.brand,
    this.model,
    this.ui,
    this.arch,
    this.build,
  });

  /// The name of the release file this app was installed from ("kumo-android-universal.apk"). Not the
  /// same as [arch]: an arm64 phone can run the universal file.
  final String? build;

  /// The language chosen inside the app ("fa", "zh-Hans"); null while it follows the device.
  final String? lang;

  /// The language of the device ("fa-IR", "en_US").
  final String? deviceLang;

  /// The device's country setting, not where it is ("IR").
  final String? region;

  /// The IANA name of the time zone ("Asia/Tehran"), never an offset or an abbreviation.
  final String? tz;

  /// Android only: the maker, the model and the maker's interface ("One UI 6.1.1").
  final String? brand;
  final String? model;
  final String? ui;

  /// The processor: arm64, armv7, x64, x86, riscv64 or other.
  final String? arch;

  /// The fields that are known and valid, under the names the server uses.
  Map<String, String> toJson() {
    String? ok(String? v, RegExp re, int max) =>
        v != null && v.length <= max && re.hasMatch(v) ? v : null;
    final out = <String, String?>{
      'lang': ok(lang, _langRe, 12),
      'device_lang': ok(deviceLang, _deviceLangRe, 20),
      'region': isCountry(region) ? region : null,
      'tz': ok(tz, _tzRe, 40),
      'brand': cleanFact(brand, max: 30),
      'model': cleanFact(model, max: 40, model: true),
      'ui': cleanFact(ui, max: 40),
      'arch': arch != null && pingArches.contains(arch) ? arch : null,
      'build': isBuildName(build) ? build : null,
    };
    return {
      for (final e in out.entries)
        if (e.value != null) e.key: e.value!,
    };
  }
}

/// The maker's interface from the properties of an Android phone, or null when it cannot be read
/// reliably: "One UI 6.1.1" (60101), "MIUI 14" (V140), "HyperOS 1.0" (OS1.0.x), "ColorOS 14.0".
String? androidUiName({
  required String? brand,
  String? oneui,
  String? miui,
  String? mios,
  String? oplus,
}) {
  final b = (brand ?? '').toLowerCase();
  if (b == 'samsung') {
    final n = int.tryParse(oneui ?? '');
    if (n == null || n < 10000) return null;
    final major = n ~/ 10000, minor = (n ~/ 100) % 100, patch = n % 100;
    return 'One UI $major.$minor${patch == 0 ? '' : '.$patch'}';
  }
  if (b == 'xiaomi' || b == 'redmi' || b == 'poco') {
    final os = RegExp(r'^OS(\d+(?:\.\d+)?)').firstMatch(mios ?? '');
    if (os != null) return 'HyperOS ${os[1]}';
    final v = RegExp(r'^V(\d{2,3})$').firstMatch(miui ?? '');
    if (v != null) {
      final n = int.parse(v[1]!);
      return 'MIUI ${n % 10 == 0 ? '${n ~/ 10}' : '${n ~/ 10}.${n % 10}'}';
    }
    return null;
  }
  if (b == 'oppo') {
    final v = RegExp(r'^V?(\d+\.\d+)').firstMatch(oplus ?? '');
    return v == null ? null : 'ColorOS ${v[1]}';
  }
  return null;
}

/// The processor name the server knows, from an Android ABI ("arm64-v8a") or a machine name
/// ("x86_64", "aarch64", "AMD64"). "other" when it is not one of them; null when nothing is given.
String? archName(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  switch (raw.trim().toLowerCase()) {
    case 'arm64-v8a':
    case 'arm64':
    case 'aarch64':
      return 'arm64';
    case 'armeabi-v7a':
    case 'armv7':
    case 'armv7l':
    case 'arm':
      return 'armv7';
    case 'x86_64':
    case 'x64':
    case 'amd64':
      return 'x64';
    case 'x86':
    case 'i386':
    case 'i686':
      return 'x86';
    case 'riscv64':
      return 'riscv64';
  }
  return 'other';
}

/// Lower-case hex SHA-256 of the salt and [systemId]: 64 characters.
String hashDeviceId(String systemId) {
  final data = Uint8List.fromList(utf8.encode('$idSalt${systemId.trim().toLowerCase()}'));
  final d = SHA256Digest();
  d.update(data, 0, data.length);
  final out = Uint8List(d.digestSize);
  d.doFinal(out, 0);
  return [for (final b in out) b.toRadixString(16).padLeft(2, '0')].join();
}

/// A real two-letter country code (the server also refuses Cloudflare's "XX" and "T1").
bool isCountry(String? c) => c != null && _countryRe.hasMatch(c) && c != 'XX' && c != 'T1';

/// The system version made fit for the server: only the characters it takes, at most 64. Null when
/// nothing is left.
String? cleanOsVersion(String? raw) {
  if (raw == null) return null;
  var s = raw.replaceAll(RegExp(r'[^\w .,+()-]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (s.length > 64) s = s.substring(0, 64).trim();
  return _osVersionRe.hasMatch(s) ? s : null;
}

/// What Dart reports on Windows ('"Windows 10 Pro" 10.0 (Build 26300)') made right: Windows 11 still
/// calls itself 10.0, and is told apart by the build number (22000 and up). The system name is left
/// out because the server shows it next to this. Returns [raw] cleaned when it is not that shape.
String? windowsVersionName(String? raw) {
  if (raw == null) return null;
  final m = RegExp(r'"?Windows\s+(\d+)\s*([^"]*)"?.*\(Build\s+(\d+)\)').firstMatch(raw);
  if (m == null) return cleanOsVersion(raw);
  final build = int.parse(m[3]!);
  final major = build >= 22000 ? '11' : m[1]!;
  final edition = m[2]!.trim();
  return cleanOsVersion('$major${edition.isEmpty ? '' : ' $edition'} (Build $build)');
}

/// The version of the app as the server wants it ("1.12.0-beta.11+43" is fine as it is).
bool isPingAppVersion(String v) => _appVersionRe.hasMatch(v);

class PingException implements FormatException {
  PingException(this.message);
  @override
  final String message;
  @override
  dynamic get source => null;
  @override
  int? get offset => null;

  @override
  String toString() => 'ping: $message';
}

/// The facts that go together with [os]: a build name only when it starts with "kumo-" + the system
/// + "-". (The maker, model and interface go from every system.)
Map<String, String> fitFacts(String os, Map<String, String> facts) => {
      for (final e in facts.entries)
        if (e.key != 'build' || e.value.startsWith('kumo-$os-')) e.key: e.value,
    };

/// The body of a ping, checked. Throws [PingException] when the server would refuse it.
/// [country] is only for a ping that left from inside the tunnel (the server then cannot use what
/// Cloudflare sees); for a direct one it is left out and the server reads it itself.
Map<String, Object> buildPing({
  required String event,
  required String id,
  required String os,
  required String appVersion,
  String? osVersion,
  bool viaTunnel = false,
  String? country,
  DeviceFacts facts = const DeviceFacts(),
}) {
  if (event != 'ping' && event != 'opt_out') throw PingException('bad_event');
  if (!_idRe.hasMatch(id)) throw PingException('bad_id');
  if (!pingOsNames.contains(os)) throw PingException('bad_os');
  if (!isPingAppVersion(appVersion)) throw PingException('bad_app_version');
  final osv = cleanOsVersion(osVersion);
  final body = <String, Object>{
    'v': pingSchema,
    'event': event,
    'id': id,
    'os': os,
    if (osv != null) 'os_version': osv,
    'app_version': appVersion,
    'via_tunnel': viaTunnel,
    if (viaTunnel && isCountry(country)) 'country': country!,
    // Only with a ping, not with the last message after the user turned it off.
    if (event == 'ping') ...fitFacts(os, facts.toJson()),
  };
  if (utf8.encode(jsonEncode(body)).length > pingMaxBytes) throw PingException('too_big');
  return body;
}

/// "2026-11-07": the day as the server counts it (UTC).
String pingDay(DateTime t) => t.toUtc().toIso8601String().substring(0, 10);
