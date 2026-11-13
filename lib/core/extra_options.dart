import 'dart:convert';

/// The extra options of the connection (*Settings > Advanced*) that have a field of their own, so that the
/// common ones need no JSON. What the fields do not know stays in the JSON as it is.
enum ExtraKind { toggle, text, number, choice }

class ExtraOption {
  const ExtraOption(this.path, this.kind, this.labelKey, {this.hint, this.choices = const []});

  /// Where the value is in the object: `['sockopt', 'tcpNoDelay']` is `{"sockopt": {"tcpNoDelay": true}}`.
  final List<String> path;
  final ExtraKind kind;

  /// The key of the label in the texts of the app.
  final String labelKey;
  final String? hint;
  final List<String> choices;

  String get id => path.join('.');
}

/// Dial options of every sing-box server.
const singboxExtraOptions = <ExtraOption>[
  ExtraOption(['tcp_keep_alive'], ExtraKind.text, 'xoTcpKeepAlive', hint: '5m'),
  ExtraOption(['tcp_keep_alive_interval'], ExtraKind.text, 'xoTcpKeepAliveInterval', hint: '75s'),
  ExtraOption(['disable_tcp_keep_alive'], ExtraKind.toggle, 'xoDisableKeepAlive'),
  ExtraOption(['udp_fragment'], ExtraKind.toggle, 'xoUdpFragment'),
];

/// Socket options of the Xray server.
const xrayExtraOptions = <ExtraOption>[
  ExtraOption(['sockopt', 'tcpNoDelay'], ExtraKind.toggle, 'xoTcpNoDelay'),
  ExtraOption(['sockopt', 'tcpKeepAliveIdle'], ExtraKind.number, 'xoKeepAliveIdle', hint: '45'),
  ExtraOption(['sockopt', 'tcpKeepAliveInterval'], ExtraKind.number, 'xoKeepAliveInterval', hint: '45'),
  ExtraOption(['sockopt', 'tcpcongestion'], ExtraKind.choice, 'xoCongestion', choices: ['bbr', 'cubic', 'reno']),
];

/// The value of [o] in [json]: a bool, a number or a text, or null when it is not set.
Object? readOption(Map<String, dynamic> json, ExtraOption o) {
  Object? at = json;
  for (final key in o.path) {
    if (at is! Map) return null;
    at = at[key];
  }
  return at;
}

/// A copy of [json] with [o] set to [value]. Nothing (null), an empty text and false take the key away, and
/// a branch that is left empty goes with it; every other key is kept.
Map<String, dynamic> withOption(Map<String, dynamic> json, ExtraOption o, Object? value) {
  final unset = value == null || value == false || (value is String && value.trim().isEmpty);
  Map<String, dynamic> set(Map<String, dynamic> at, int depth) {
    final out = {...at};
    final key = o.path[depth];
    if (depth == o.path.length - 1) {
      if (unset) {
        out.remove(key);
      } else {
        out[key] = value is String ? value.trim() : value;
      }
      return out;
    }
    final inner = out[key];
    final next = set(inner is Map<String, dynamic> ? inner : <String, dynamic>{}, depth + 1);
    if (next.isEmpty) {
      out.remove(key);
    } else {
      out[key] = next;
    }
    return out;
  }

  return set(json, 0);
}

/// The text kept in the settings for [json]: empty when there is nothing in it.
String encodeExtra(Map<String, dynamic> json) => json.isEmpty ? '' : jsonEncode(json);

/// The final mask that splits the TLS hello (the one the app itself uses for "Split the TLS hello").
String fragmentFinalMask() => jsonEncode({
      'tcp': [
        {
          'type': 'fragment',
          'settings': {
            'packets': 'tlshello',
            'lengths': ['3-5', '6-8', '10-20'],
            'delays': ['10-20'],
            'maxSplit': '3-6',
          },
        },
      ],
    });
