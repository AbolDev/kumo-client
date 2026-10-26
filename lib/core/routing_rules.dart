/// A manual routing rule: a domain (with its sub-domains) or an IP address / network.
class RouteRule {
  const RouteRule.domain(this.value) : ip = false;
  const RouteRule.ip(this.value) : ip = true;

  final bool ip;

  /// A lower-case domain such as `example.com`, or a CIDR such as `10.0.0.0/8`.
  final String value;
}

final _v4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?:/(\d{1,2}))?$');
final _v6 = RegExp(r'^[0-9a-f:]*:[0-9a-f:]*(?:/(\d{1,3}))?$');
final _domain = RegExp(r'^(?:[a-z0-9_](?:[a-z0-9_-]*[a-z0-9_])?\.)+[a-z0-9-]{2,}$');

/// Reads what the user typed: an IPv4 or IPv6 address (with an optional /prefix), a domain, or a
/// link (`https://www.example.com/page`, `*.example.com`). Null when it is none of them.
RouteRule? parseRouteRule(String input) {
  var s = input.trim().toLowerCase();
  if (s.isEmpty) return null;

  final v4 = _v4.firstMatch(s);
  if (v4 != null) {
    for (var i = 1; i <= 4; i++) {
      if (int.parse(v4[i]!) > 255) return null;
    }
    final prefix = v4[5] == null ? 32 : int.parse(v4[5]!);
    if (prefix > 32) return null;
    return RouteRule.ip('${v4[1]}.${v4[2]}.${v4[3]}.${v4[4]}/$prefix');
  }
  if (s.contains(':') && _v6.hasMatch(s) && !s.contains('://')) {
    final slash = s.indexOf('/');
    final address = slash < 0 ? s : s.substring(0, slash);
    final prefix = slash < 0 ? 128 : int.tryParse(s.substring(slash + 1));
    if (prefix == null || prefix > 128 || Uri.tryParse('http://[$address]') == null) {
      return null;
    }
    return RouteRule.ip('$address/$prefix');
  }

  s = s.replaceFirst(RegExp(r'^[a-z][a-z0-9+.-]*://'), '');
  s = s.split(RegExp(r'[/?#]')).first;
  if (s.contains('@')) s = s.substring(s.lastIndexOf('@') + 1);
  s = s.replaceFirst(RegExp(r':\d+$'), '');
  s = s.replaceFirst(RegExp(r'^(\*\.|\.)+'), '');
  if (s == 'localhost' || _domain.hasMatch(s)) return RouteRule.domain(s);
  return null;
}

/// The text a rule is stored and shown as.
String? normalizeRouteRule(String input) => parseRouteRule(input)?.value;
