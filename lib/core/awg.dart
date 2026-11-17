// AmneziaWG: a WireGuard server whose packets are obfuscated (junk packets before the handshake, padding of the messages, other
// numbers for the types of the messages, signature packets), so that a filter that knows the packets of WireGuard does not
// know them. The server is an ordinary WireGuard link (`wireguard://`) or `.conf` file with the parameters of AmneziaWG
// added: `Jc`, `Jmin`, `Jmax`, `S1` to `S4`, `H1` to `H4`, `I1` to `I5`, and the ones of AmneziaWG 3.
//
// The phone's core (libbox) has an endpoint of type `amneziawg` for it (see tools/libbox_patch/amneziawg). The cores of the
// computers are the official sing-box releases, which have none: such a server is not carried there.

import 'dart:io' show Platform;

/// The protocol the servers of AmneziaWG show in lists.
const amneziaProtocol = 'amneziawg';

/// Whether this build can carry AmneziaWG servers: the Android build can, the cores of the computers cannot (yet).
/// (A variable, so that a test can say otherwise.)
bool amneziaSupported = Platform.isAndroid;

/// The options of the endpoint that are AmneziaWG's, by the names the endpoint has for them.
const awgOptionNames = {
  'jc', 'jmin', 'jmax', 's1', 's2', 's3', 's4', 'h1', 'h2', 'h3', 'h4', 'i1', 'i2', 'i3', 'i4', 'i5', //
  'random_trailers', 'disable_cookies', 'header_protection_key', 'content_padding_addition', 'rekey_after_time',
  'rekey_timeout', 'reject_after_time', 'keepalive_timeout', 'max_handshake_attempts',
};

/// The names of the settings in a link or a configuration (lower case, no underscore) and the option of the endpoint each is.
const _optionOf = {
  'jc': 'jc', 'jmin': 'jmin', 'jmax': 'jmax', 's1': 's1', 's2': 's2', 's3': 's3', 's4': 's4', //
  'h1': 'h1', 'h2': 'h2', 'h3': 'h3', 'h4': 'h4', 'i1': 'i1', 'i2': 'i2', 'i3': 'i3', 'i4': 'i4', 'i5': 'i5',
  'randomtrailers': 'random_trailers', 'disablecookies': 'disable_cookies',
  'headerprotectionkey': 'header_protection_key', 'contentpaddingaddition': 'content_padding_addition',
  'rekeyaftertime': 'rekey_after_time', 'rekeytimeout': 'rekey_timeout', 'rejectaftertime': 'reject_after_time',
  'keepalivetimeout': 'keepalive_timeout', 'maxhandshakeattempts': 'max_handshake_attempts',
};

/// The name of a setting as [_optionOf] has it.
String awgSettingKey(String key) => key.toLowerCase().replaceAll('_', '');

/// Whether [key] (as a link or a configuration writes it) is a setting of AmneziaWG.
bool isAwgSetting(String key) => _optionOf.containsKey(awgSettingKey(key));

/// A signature packet: the tags that amneziawg-go reads, one after the other (static bytes, random bytes, random digits,
/// random letters, a timestamp). Anything else would stop the core from starting, so it is not accepted.
final _packet = RegExp(r'^(?:<(?:b 0x(?:[0-9a-fA-F]{2})+|r [1-9][0-9]{0,3}|rd [1-9][0-9]{0,3}|rc [1-9][0-9]{0,3}|t)>)+$');

/// A number, or a range `low-high`.
final _range = RegExp(r'^[0-9]{1,10}(?:-[0-9]{1,10})?$');

bool _validRange(String v, {int max = 0xFFFFFFFF}) {
  if (!_range.hasMatch(v)) return false;
  final parts = v.split('-').map(int.parse).toList();
  if (parts.any((p) => p > max)) return false;
  return parts.length == 1 || parts[0] <= parts[1];
}

/// The settings of AmneziaWG in [settings] (a link's query or the keys of a configuration, any case), as the options of the
/// endpoint. Empty when there are none (an ordinary WireGuard server); null when one is not valid (the core would not start).
Map<String, dynamic>? awgOptions(Map<String, String> settings) {
  final given = <String, String>{};
  for (final e in settings.entries) {
    final option = _optionOf[awgSettingKey(e.key)];
    if (option != null && e.value.trim().isNotEmpty) given[option] = e.value.trim();
  }
  final out = <String, dynamic>{};
  for (final e in given.entries) {
    final key = e.key;
    final value = e.value;
    switch (key) {
      case 'jc':
        final n = int.tryParse(value);
        if (n == null || n < 0 || n > 128) return null;
        out[key] = n;
      case 'jmin' || 'jmax':
        final n = int.tryParse(value);
        if (n == null || n < 0 || n > 1500) return null;
        out[key] = n;
      case 's1' || 's2' || 's3' || 's4':
        final n = int.tryParse(value);
        if (n == null || n < 0 || n > 1500) return null;
        out[key] = n;
      case 'h1' || 'h2' || 'h3' || 'h4':
        if (!_validRange(value)) return null;
        out[key] = value;
      case 'i1' || 'i2' || 'i3' || 'i4' || 'i5':
        if (value.length > 2048 || !_packet.hasMatch(value)) return null;
        out[key] = value;
      case 'random_trailers' || 'disable_cookies':
        final v = value.toLowerCase();
        if (v == 'true' || v == '1' || v == 'yes') {
          out[key] = true;
        } else if (v != 'false' && v != '0' && v != 'no') {
          return null;
        }
      case 'header_protection_key':
        if (value.length > 128 || !RegExp(r'^[A-Za-z0-9+/=_-]+$').hasMatch(value)) return null;
        out[key] = value;
      default: // the times and the padding: a number or a range
        if (!_validRange(value)) return null;
        out[key] = value;
    }
  }
  final min = out['jmin'] as int?;
  final max = out['jmax'] as int?;
  if (min != null && max != null && min > max) return null;
  // The headers are the types of the messages: no two ranges may overlap.
  final headers = <(int, int)>[];
  for (final k in const ['h1', 'h2', 'h3', 'h4']) {
    final v = out[k] as String?;
    if (v == null) continue;
    final parts = v.split('-').map(int.parse).toList();
    headers.add((parts.first, parts.last));
  }
  for (var i = 0; i < headers.length; i++) {
    for (var j = i + 1; j < headers.length; j++) {
      if (headers[i].$1 <= headers[j].$2 && headers[j].$1 <= headers[i].$2) return null;
    }
  }
  return out;
}

/// Whether the sing-box endpoint [endpoint] (a WireGuard one) carries settings of AmneziaWG.
bool hasAwgOptions(Map<String, dynamic> endpoint) => endpoint.keys.any(awgOptionNames.contains);

/// [endpoint] as it goes into the configuration of the core: an endpoint of type `amneziawg` when it carries settings of
/// AmneziaWG (the `reserved` bytes of a peer are a thing of WARP's, and are not used there), else as it is.
Map<String, dynamic> amneziaEndpoint(Map<String, dynamic> endpoint) {
  if (!hasAwgOptions(endpoint)) return endpoint;
  final peers = endpoint['peers'];
  return {
    ...endpoint,
    'type': 'amneziawg',
    if (peers is List)
      'peers': [
        for (final p in peers)
          if (p is Map) {for (final e in p.entries) if (e.key != 'reserved') e.key: e.value} else p,
      ],
  };
}
