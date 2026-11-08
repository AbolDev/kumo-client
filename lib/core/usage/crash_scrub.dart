import 'dart:io' show InternetAddress, InternetAddressType;

/// Removes what must never leave the device from a text that goes into a crash report: links,
/// addresses, e-mail addresses, ids, long tokens, passwords, user names in folder paths and the
/// names of the user's servers. Code locations (`package:kumo/x.dart:12:3`), error types and
/// method names are kept: they are what a report is for.

/// What is kept as it is: places in the code and the build id a stack trace of a release build
/// carries (it is what tells which symbols to use).
final _keep = RegExp(
  r"package:[A-Za-z0-9_.]+/[A-Za-z0-9_./$-]+\.dart(?::\d+(?::\d+)?)?"
  r"|dart:[A-Za-z0-9_.]+(?:/[A-Za-z0-9_.]+)?(?::\d+(?::\d+)?)?"
  r"|build_id: '[0-9a-fA-F]+'"
  r"|(?:abs|virt) [0-9a-fA-F]{6,16}"
  r"|_kDart[A-Za-z]+(?:\+0x[0-9a-fA-F]+)?"
  r"|app\.kumo\.[A-Za-z0-9_.$]+\([A-Za-z0-9_.$]+(?::\d+)?\)",
);

final _homeDirs = [
  RegExp(r'([A-Za-z]:[\\/]+Users[\\/]+)[^\\/\s"' "'" r':*?<>|]+', caseSensitive: false),
  RegExp(r'(/Users/)[^/\s"' "'" r':]+'),
  RegExp(r'(/home/)[^/\s"' "'" r':]+'),
];
final _url = RegExp(r'\b(?!file:)([A-Za-z][A-Za-z0-9+.-]{1,19})://[^\s"' "'" r'<>)\]]+');
final _email = RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+');
final _uuid = RegExp(r'\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b');
final _v6run = RegExp(r'(?<![A-Za-z0-9_])[0-9A-Fa-f:.]{2,}(?![A-Za-z0-9_])');
final _v4 = RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}\b(?::\d{1,5})?');
final _secret = RegExp(
  r'''(password|passwd|pwd|passphrase|secret|token|api[_-]?key|private[_-]?key|authorization|auth|psk|key)(["']?\s*[=:]\s*)("[^"]*"|'[^']*'|\S+)''',
  caseSensitive: false,
);
final _token = RegExp(r'[A-Za-z0-9+/=_-]{32,}');

/// [hosts]: the names and addresses of the servers and subscriptions the user has; they are
/// removed whatever form they appear in (with a port, in a longer text).
String scrubText(String text, {Iterable<String> hosts = const []}) {
  if (text.isEmpty) return text;
  var s = text;

  // Places in the code are put aside, so no rule below can damage them.
  final kept = <String>[];
  s = s.replaceAllMapped(_keep, (m) {
    kept.add(m[0]!);
    return '\u0001${kept.length - 1}\u0002';
  });

  for (final re in _homeDirs) {
    s = s.replaceAllMapped(re, (m) => '${m[1]}<user>');
  }
  s = s.replaceAllMapped(_url, (m) => '${m[1]}://<redacted>');

  final names = <String>{
    for (final h in hosts)
      if (h.trim().length >= 4) h.trim(),
  }.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final h in names) {
    s = s.replaceAll(RegExp('${RegExp.escape(h)}(?::\\d{1,5})?', caseSensitive: false), '<host>');
  }

  s = s.replaceAll(_email, '<email>');
  s = s.replaceAll(_uuid, '<uuid>');
  s = s.replaceAllMapped(_v6run, (m) {
    final t = m[0]!;
    if (!t.contains('::') && ':'.allMatches(t).length < 4) return t;
    final a = InternetAddress.tryParse(t);
    return a != null && a.type == InternetAddressType.IPv6 ? '<ip>' : t;
  });
  s = s.replaceAllMapped(_v4, (m) {
    final ok = RegExp(r'\d+').allMatches(m[0]!.split(':').first).every((p) => int.parse(p[0]!) <= 255);
    return ok ? '<ip>' : m[0]!;
  });
  s = s.replaceAllMapped(_secret, (m) => '${m[1]}${m[2]}<redacted>');
  s = s.replaceAllMapped(_token, (m) {
    final t = m[0]!;
    // Ordinary words and names joined by "_" or "-" (no digit) are not secrets.
    return RegExp(r'\d').hasMatch(t) && RegExp(r'[A-Za-z]').hasMatch(t) ? '<token>' : t;
  });

  return s.replaceAllMapped(RegExp('\u0001(\\d+)\u0002'), (m) => kept[int.parse(m[1]!)]);
}
