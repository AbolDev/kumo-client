// AmneziaWG: a WireGuard server whose packets are obfuscated (junk packets before the handshake, padding of the messages, other
// numbers for the types of the messages, signature packets), so that a filter that knows the packets of WireGuard does not
// know them. The server is an ordinary WireGuard link (`wireguard://`) or `.conf` file with the parameters of AmneziaWG
// added: `Jc`, `Jmin`, `Jmax`, `S1` to `S4`, `H1` to `H4`, `I1` to `I5`, and the ones of AmneziaWG 3.
//
// The phone's core (libbox) has an endpoint of type `amneziawg` for it (see tools/libbox_patch/amneziawg). The cores of the
// computers are the official sing-box releases, which have none: there a program of its own, kumo-awg (sing-box built with
// that endpoint), carries the server and the core sends what is to go through it to that program's local SOCKS port, as it
// does for Xray (a server of AmneziaWG is then, like an XHTTP one, a server that only a helper can carry).

import 'dart:convert';
import 'dart:io' show Platform, ZLibDecoder;

import '../l10n/extra.dart' show trFor;

/// The protocol the servers of AmneziaWG show in lists.
const amneziaProtocol = 'amneziawg';

/// Whether the core itself has the endpoint of AmneziaWG: the one of the phone (Android, and iOS in its tunnel extension) does;
/// on a computer kumo-awg is the one that has it.
/// (A variable, so that a test can say otherwise.)
bool amneziaInCore = Platform.isAndroid || Platform.isIOS;

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

/// Why the last settings that were read were not accepted (null when they were, or none were read): said to the user when an
/// import finds nothing it can use. Set by [awgOptions].
AwgProblem? awgProblem;

/// Why settings were not accepted: the key of a text (see l10n/extra_awg.dart) and what goes into it, so that it can be said
/// in the language of the user. `toString` is the English one.
class AwgProblem {
  const AwgProblem(this.key, [this.args = const {}]);

  final String key;
  final Map<String, Object> args;

  String text([String lang = 'en']) => trFor(lang, key, args);

  @override
  String toString() => text();
}

Map<String, dynamic>? _refuse(String key, [Map<String, Object> args = const {}]) {
  awgProblem = AwgProblem(key, args);
  return null;
}

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

/// A yes or a no as configurations write it (`true`, `on`, `yes`, `1`, `enabled`; `false`, `off`, `no`, `0`, `disabled`);
/// null when it is neither.
bool? _flag(String value) {
  switch (value.trim().toLowerCase()) {
    case 'true' || 'on' || 'yes' || '1' || 'enabled' || 'enable':
      return true;
    case 'false' || 'off' || 'no' || '0' || 'disabled' || 'disable':
      return false;
  }
  return null;
}

/// The key of the header protection as the core takes it: 32 bytes in hex. Configurations write it in base64 (as the keys of
/// WireGuard), the core reads hex; either is accepted. Null when it is neither.
String? _headerKey(String value) {
  final v = value.trim();
  if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(v)) return v.toLowerCase();
  try {
    final bytes = base64.decode(base64.normalize(v.replaceAll('-', '+').replaceAll('_', '/')));
    if (bytes.length == 32) return [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();
  } catch (_) {}
  return null;
}

/// The settings of AmneziaWG in [settings] (a link's query or the keys of a configuration, any case), as the options of the
/// endpoint. Empty when there are none (an ordinary WireGuard server); null when one is not valid (the core would not start;
/// [awgProblem] says which).
Map<String, dynamic>? awgOptions(Map<String, String> settings) {
  awgProblem = null;
  final given = <String, String>{};
  for (final e in settings.entries) {
    final option = _optionOf[awgSettingKey(e.key)];
    if (option != null && e.value.trim().isNotEmpty) given[option] = e.value.trim();
  }
  final out = <String, dynamic>{};
  for (final e in given.entries) {
    final key = e.key;
    final value = e.value;
    final name = key.toUpperCase();
    switch (key) {
      case 'jc':
        final n = int.tryParse(value);
        if (n == null || n < 0 || n > 128) return _refuse('awgRange', {'name': 'Jc', 'max': 128, 'value': value});
        out[key] = n;
      case 'jmin' || 'jmax':
        final n = int.tryParse(value);
        if (n == null || n < 0 || n > 1500) return _refuse('awgRange', {'name': name, 'max': 1500, 'value': value});
        out[key] = n;
      case 's1' || 's2' || 's3' || 's4':
        final n = int.tryParse(value);
        if (n == null || n < 0 || n > 1500) return _refuse('awgRange', {'name': name, 'max': 1500, 'value': value});
        out[key] = n;
      case 'h1' || 'h2' || 'h3' || 'h4':
        if (!_validRange(value)) return _refuse('awgRangeText', {'name': name, 'value': value});
        out[key] = value;
      case 'i1' || 'i2' || 'i3' || 'i4' || 'i5':
        // (A packet that looks like a QUIC one is some 1200 bytes, 2400 hex digits.)
        if (value.length > 16384) return _refuse('awgTooLong', {'name': name});
        if (!_packet.hasMatch(value)) return _refuse('awgTag', {'name': name});
        out[key] = value;
      case 'random_trailers' || 'disable_cookies':
        final flag = _flag(value);
        if (flag == null) {
          return _refuse('awgFlag',
              {'name': key == 'random_trailers' ? 'RandomTrailers' : 'DisableCookies', 'value': value});
        }
        if (flag) out[key] = true;
      case 'header_protection_key':
        final hex = _headerKey(value);
        if (hex == null) return _refuse('awgKey');
        out[key] = hex;
      default: // the times and the padding: a number or a range
        if (!_validRange(value)) return _refuse('awgRangeText', {'name': key, 'value': value});
        out[key] = value;
    }
  }
  final min = out['jmin'] as int?;
  final max = out['jmax'] as int?;
  if (min != null && max != null && min > max) return _refuse('awgMinMax', {'min': min, 'max': max});
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
      if (headers[i].$1 <= headers[j].$2 && headers[j].$1 <= headers[i].$2) return _refuse('awgOverlap');
    }
  }
  // With the header protection the paddings S1 to S4 are the nonces of its cipher: none may be short.
  if (out.containsKey('header_protection_key')) {
    for (final k in const ['s1', 's2', 's3', 's4']) {
      final s = out[k] as int? ?? 0;
      if (s < 12) return _refuse('awgShort', {'name': k.toUpperCase(), 'value': s});
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

/// The settings of AmneziaWG found among the keys of [map] (a sing-box endpoint, or the `amnezia-wg-option` of a Clash proxy),
/// as the text a link carries them in (a flag is `true`). Only the ones that are given.
Map<String, String> awgSettingsOf(Map map) {
  final out = <String, String>{};
  for (final e in map.entries) {
    final key = '${e.key}';
    final value = e.value;
    if (!isAwgSetting(key) || value == null || value is Map || value is List) continue;
    final text = value is bool ? (value ? 'true' : 'false') : '$value'.trim();
    if (text.isNotEmpty) out[awgSettingKey(key)] = text;
  }
  return out;
}

/// The configurations inside the `vpn://` links of Amnezia's own app (the text it shares a server by): the link is base64 of a
/// compressed JSON (Qt's qCompress: the size in four bytes, then zlib) that lists the containers of a server, each with its
/// last configuration as text (WireGuard and AmneziaWG as a `.conf`, OpenVPN as a `.ovpn`, Xray as its JSON). Each is
/// returned as text for the readers of those formats, with the name of the server (its description) as a comment above
/// the `[Peer]` of a `.conf`, where the reader looks for a name. Empty when [text] has no such link or it is not readable.
List<String> amneziaVpnConfigs(String text) {
  final out = <String>[];
  for (final m in RegExp(r'vpn://([A-Za-z0-9_\-+/=]+)').allMatches(text)) {
    try {
      final bytes = base64.decode(base64.normalize(m[1]!.replaceAll('-', '+').replaceAll('_', '/')));
      List<int>? json;
      // qCompress: four bytes of the size, then the zlib stream.
      if (bytes.length > 5) {
        try {
          json = ZLibDecoder().convert(bytes.sublist(4));
        } catch (_) {}
      }
      json ??= bytes;
      final root = jsonDecode(utf8.decode(json));
      if (root is! Map) continue;
      final name = '${root['description'] ?? ''}'.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
      final dns1 = '${root['dns1'] ?? ''}';
      final dns2 = '${root['dns2'] ?? ''}';
      final containers = root['containers'];
      if (containers is! List) continue;
      for (final c in containers) {
        if (c is! Map) continue;
        for (final part in c.values) {
          if (part is! Map || part['last_config'] is! String) continue;
          final inner = jsonDecode(part['last_config'] as String);
          var config = inner is Map ? inner['config'] : null;
          if (config is! String || config.trim().isEmpty) continue;
          // The placeholders of the template, if any were left.
          if (dns1.isNotEmpty) config = config.replaceAll(r'$PRIMARY_DNS', dns1);
          if (dns2.isNotEmpty) config = config.replaceAll(r'$SECONDARY_DNS', dns2);
          if (name.isNotEmpty && config.contains('[Peer]')) config = config.replaceFirst('[Peer]', '# $name\n[Peer]');
          out.add(config);
        }
      }
    } catch (_) {
      // not a link of Amnezia
    }
  }
  return out;
}