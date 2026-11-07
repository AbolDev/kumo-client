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
  };
  if (utf8.encode(jsonEncode(body)).length > pingMaxBytes) throw PingException('too_big');
  return body;
}

/// "2026-11-07": the day as the server counts it (UTC).
String pingDay(DateTime t) => t.toUtc().toIso8601String().substring(0, 10);
