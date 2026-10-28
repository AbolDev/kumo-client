/// What a manual routing rule matches.
enum RuleKind {
  /// A domain and its sub-domains: `example.com`.
  domain,

  /// Exactly this domain: `full:www.example.com`.
  full,

  /// Any domain that contains the word: `keyword:ads`.
  keyword,

  /// Any domain the expression matches: `regex:^ad[0-9]+\.`.
  regex,

  /// An IP address or network: `10.0.0.0/8`.
  ip,

  /// A destination port or range: `port:443`, `port:1000-2000`.
  port,
}

/// A manual routing rule: a domain, an IP address / network or a port.
class RouteRule {
  const RouteRule(this.kind, this.value);
  const RouteRule.domain(String value) : this(RuleKind.domain, value);
  const RouteRule.ip(String value) : this(RuleKind.ip, value);

  final RuleKind kind;

  /// A lower-case domain such as `example.com`, a CIDR such as `10.0.0.0/8`, a word, an
  /// expression, or `443` / `1000-2000`.
  final String value;

  bool get ip => kind == RuleKind.ip;

  /// The text a rule is stored and shown as.
  String get text => switch (kind) {
        RuleKind.domain || RuleKind.ip => value,
        RuleKind.full => 'full:$value',
        RuleKind.keyword => 'keyword:$value',
        RuleKind.regex => 'regex:$value',
        RuleKind.port => 'port:$value',
      };
}

final _v4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?:/(\d{1,2}))?$');
final _v6 = RegExp(r'^[0-9a-f:]*:[0-9a-f:]*(?:/(\d{1,3}))?$');
final _domain = RegExp(r'^(?:[a-z0-9_](?:[a-z0-9_-]*[a-z0-9_])?\.)+[a-z0-9-]{2,}$');

/// A destination name without scheme, path, user info, port and leading `*.` / `.`.
String? _cleanDomain(String input) {
  var s = input.trim().toLowerCase();
  s = s.replaceFirst(RegExp(r'^[a-z][a-z0-9+.-]*://'), '');
  s = s.split(RegExp(r'[/?#]')).first;
  if (s.contains('@')) s = s.substring(s.lastIndexOf('@') + 1);
  s = s.replaceFirst(RegExp(r':\d+$'), '');
  s = s.replaceFirst(RegExp(r'^(\*\.|\.)+'), '');
  // Names written in their own script (IDN) become the ASCII form the core compares with.
  if (s.runes.any((r) => r > 127)) s = s.split('.').map(punycodeLabel).join('.');
  return s == 'localhost' || _domain.hasMatch(s) ? s : null;
}

/// One label of an internationalised domain name in Punycode (RFC 3492): `münchen` becomes
/// `xn--mnchen-3ya`. A label of plain ASCII is returned as it is.
String punycodeLabel(String label) {
  if (label.runes.every((r) => r < 128)) return label;
  const base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700;
  final input = label.runes.toList();
  int adapt(int delta, int points, bool first) {
    delta = first ? delta ~/ damp : delta ~/ 2;
    delta += delta ~/ points;
    var k = 0;
    while (delta > ((base - tMin) * tMax) ~/ 2) {
      delta ~/= base - tMin;
      k += base;
    }
    return k + (base - tMin + 1) * delta ~/ (delta + skew);
  }

  String digit(int d) => String.fromCharCode(d < 26 ? 97 + d : 22 + d);
  final out = StringBuffer();
  final basic = input.where((c) => c < 128).toList();
  out.writeAll(basic.map(String.fromCharCode));
  var handled = basic.length;
  final basicCount = handled;
  if (basicCount > 0) out.write('-');
  var n = 128, delta = 0, bias = 72;
  while (handled < input.length) {
    var m = 0x7fffffff;
    for (final c in input) {
      if (c >= n && c < m) m = c;
    }
    delta += (m - n) * (handled + 1);
    n = m;
    for (final c in input) {
      if (c < n) delta++;
      if (c == n) {
        var q = delta;
        for (var k = base;; k += base) {
          final t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias);
          if (q < t) break;
          out.write(digit(t + (q - t) % (base - t)));
          q = (q - t) ~/ (base - t);
        }
        out.write(digit(q));
        bias = adapt(delta, handled + 1, handled == basicCount);
        delta = 0;
        handled++;
      }
    }
    delta++;
    n++;
  }
  return 'xn--$out';
}

/// Whether [pattern] only uses what RE2 (the engine of sing-box) understands: no look-ahead or
/// look-behind, no back-references, no atomic groups, possessive quantifiers or `\k<name>`.
bool isRe2Compatible(String pattern) {
  // Escapes are skipped so that `\(` or `\\` do not look like the start of a group.
  final p = pattern.replaceAll(RegExp(r'\\\\'), '');
  if (RegExp(r'\(\?(?:=|!|<=|<!|>)').hasMatch(p.replaceAll(RegExp(r'\\.'), ''))) return false;
  if (RegExp(r'\\[1-9]').hasMatch(p)) return false; // back-reference
  if (RegExp(r'\\k<').hasMatch(p)) return false;
  if (RegExp(r'(?:[*+?]|\})\+').hasMatch(p.replaceAll(RegExp(r'\\.'), ''))) return false; // possessive
  return true;
}

/// Reads what the user typed: an IPv4 or IPv6 address (with an optional /prefix), a domain, a
/// link (`https://www.example.com/page`, `*.example.com`), or a prefixed rule: `full:`,
/// `keyword:`, `regex:`, `port:`. Null when it is none of them.
RouteRule? parseRouteRule(String input) {
  final raw = input.trim();
  if (raw.isEmpty) return null;
  final lower = raw.toLowerCase();

  for (final prefix in const ['full:', 'domain-full:']) {
    if (lower.startsWith(prefix)) {
      final d = _cleanDomain(raw.substring(prefix.length));
      return d == null ? null : RouteRule(RuleKind.full, d);
    }
  }
  if (lower.startsWith('domain:')) {
    final d = _cleanDomain(raw.substring('domain:'.length));
    return d == null ? null : RouteRule.domain(d);
  }
  if (lower.startsWith('keyword:')) {
    final k = lower.substring('keyword:'.length).trim();
    return RegExp(r'^[a-z0-9._-]+$').hasMatch(k) ? RouteRule(RuleKind.keyword, k) : null;
  }
  if (lower.startsWith('regex:')) {
    final r = raw.substring('regex:'.length).trim();
    if (r.isEmpty) return null;
    // RE2 allows flags written in the pattern, `(?i)` or `(?i:...)`, which Dart does not know; they are
    // taken out before Dart checks that the rest is well formed (brackets that match and so on).
    final plain = r
        .replaceAll(RegExp(r'\(\?[imsU]+\)'), '')
        .replaceAllMapped(RegExp(r'\(\?[imsU-]+:'), (_) => '(?:');
    try {
      RegExp(plain);
    } catch (_) {
      return null;
    }
    // sing-box reads it with Go's RE2, which has no look-around and no back-references: a pattern
    // that Dart accepts but RE2 refuses would stop the core from starting at all.
    if (!isRe2Compatible(r)) return null;
    return RouteRule(RuleKind.regex, r);
  }
  if (lower.startsWith('port:')) {
    final m = RegExp(r'^(\d{1,5})(?:-(\d{1,5}))?$').firstMatch(lower.substring('port:'.length).trim());
    if (m == null) return null;
    final from = int.parse(m[1]!);
    final to = m[2] == null ? from : int.parse(m[2]!);
    if (from < 1 || to > 65535 || from > to) return null;
    return RouteRule(RuleKind.port, from == to ? '$from' : '$from-$to');
  }

  final v4 = _v4.firstMatch(lower);
  if (v4 != null) {
    for (var i = 1; i <= 4; i++) {
      if (int.parse(v4[i]!) > 255) return null;
    }
    final prefix = v4[5] == null ? 32 : int.parse(v4[5]!);
    if (prefix > 32) return null;
    return RouteRule.ip('${v4[1]}.${v4[2]}.${v4[3]}.${v4[4]}/$prefix');
  }
  if (lower.contains(':') && _v6.hasMatch(lower) && !lower.contains('://')) {
    final slash = lower.indexOf('/');
    final address = slash < 0 ? lower : lower.substring(0, slash);
    final prefix = slash < 0 ? 128 : int.tryParse(lower.substring(slash + 1));
    if (prefix == null || prefix > 128 || Uri.tryParse('http://[$address]') == null) {
      return null;
    }
    return RouteRule.ip('$address/$prefix');
  }

  final d = _cleanDomain(raw);
  return d == null ? null : RouteRule.domain(d);
}

/// The text a rule is stored and shown as.
String? normalizeRouteRule(String input) => parseRouteRule(input)?.text;
