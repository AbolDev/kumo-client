import 'dart:io' show InternetAddress;

import 'routing_rules.dart';
import 'rule_services.dart';

/// What a routing rule does to what it matches. The order is the order the rules are applied in: what is
/// blocked first, then what goes through the VPN, then what goes direct.
enum RuleAction { block, proxy, direct }

/// The three lists of rule texts the user keeps, one per [RuleAction].
class RuleLists {
  RuleLists({List<String>? block, List<String>? proxy, List<String>? direct})
      : block = [...?block],
        proxy = [...?proxy],
        direct = [...?direct];

  final List<String> block;
  final List<String> proxy;
  final List<String> direct;

  List<String> of(RuleAction a) => switch (a) {
        RuleAction.block => block,
        RuleAction.proxy => proxy,
        RuleAction.direct => direct,
      };

  int get count => block.length + proxy.length + direct.length;

  RuleLists copy() => RuleLists(block: block, proxy: proxy, direct: direct);

  /// The action of the first list that has [rule] (in the order the rules are applied), or null.
  RuleAction? firstWith(String rule) {
    for (final a in RuleAction.values) {
      if (of(a).contains(rule)) return a;
    }
    return null;
  }
}

/// Reads what the user typed when adding a rule: what [parseRouteRule] reads, and also a bare port
/// (`443`, `1000-2000`) without the `port:` in front of it.
RouteRule? parseUserRule(String input) {
  final t = input.trim();
  final m = RegExp(r'^(\d{1,5})(?:\s*-\s*(\d{1,5}))?$').firstMatch(t);
  if (m != null) return parseRouteRule('port:${m[1]}${m[2] == null ? '' : '-${m[2]}'}');
  return parseRouteRule(t);
}

/// Adds [more] to the end of [list], leaving out what is there already; returns the new list.
List<String> withRules(List<String> list, Iterable<String> more) {
  final out = [...list];
  for (final r in more) {
    if (!out.contains(r)) out.add(r);
  }
  return out;
}

// ---------------------------------------------------------------------------------------------------
// Import and export

/// The rules as a text a person can read, edit and paste back in: a section for each action, one rule
/// on each line.
String exportRules(RuleLists lists) {
  final b = StringBuffer('# Kumo routing rules\n');
  for (final a in RuleAction.values) {
    if (lists.of(a).isEmpty) continue;
    b.write('\n[${a.name}]\n');
    for (final r in lists.of(a)) {
      b.write('$r\n');
    }
  }
  return b.toString();
}

/// What was found in a text of rules.
class RuleImport {
  RuleImport(this.rules, this.skipped);

  final RuleLists rules;

  /// Lines that were not a rule (or were under a section that does not exist).
  final int skipped;

  int get count => rules.count;
}

/// Reads a text of rules (see [exportRules]). `[block]`, `[proxy]` (or `[vpn]`) and `[direct]` on a line
/// of their own tell what the lines under them do; lines before any section go to [fallback]. Empty
/// lines and lines that start with `#` are ignored.
RuleImport parseRulesText(String text, {RuleAction fallback = RuleAction.direct}) {
  final lists = RuleLists();
  RuleAction? current = fallback;
  var skipped = 0;
  for (final raw in text.split(RegExp(r'\r\n|\r|\n'))) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#') || line.startsWith('//')) continue;
    final header = RegExp(r'^\[\s*([A-Za-z]+)\s*\]$').firstMatch(line);
    if (header != null) {
      current = switch (header[1]!.toLowerCase()) {
        'block' || 'blocked' => RuleAction.block,
        'proxy' || 'vpn' => RuleAction.proxy,
        'direct' => RuleAction.direct,
        _ => null,
      };
      continue;
    }
    final rule = parseUserRule(line);
    if (current == null || rule == null) {
      skipped++;
      continue;
    }
    final target = lists.of(current);
    if (!target.contains(rule.text)) target.add(rule.text);
  }
  return RuleImport(lists, skipped);
}

// ---------------------------------------------------------------------------------------------------
// Testing what a rule would do

/// One rule that matches what was tested.
class RuleHit {
  const RuleHit(this.action, this.rule);

  final RuleAction action;

  /// The text of the rule, as it is stored.
  final String rule;
}

/// The public form of what the rules compare a destination name with: no scheme, path, port or `www`-style
/// decoration beyond what [parseRouteRule] cleans. Null when [input] is not a name.
String? cleanDomainName(String input) {
  final r = parseRouteRule('full:$input');
  return r?.value;
}

class _Query {
  String? host;
  InternetAddress? ip;
  int? port;

  /// What an app or a service could be called: the text itself, and the ids of the apps with that name.
  final names = <String>{};
}

_Query _readQuery(String input, Map<String, String> appNames) {
  final q = _Query();
  final raw = input.trim();
  if (raw.isEmpty) return q;
  final lower = raw.toLowerCase();
  if (lower.startsWith('app:')) {
    q.names.add(raw.substring(4).trim().toLowerCase());
    return q;
  }
  if (lower.startsWith('service:')) {
    q.names.add(lower.substring(8).trim());
    return q;
  }
  q.names.add(lower);
  if (lower.length >= 2) {
    for (final e in appNames.entries) {
      final label = e.value.toLowerCase();
      if (label == lower || (lower.length >= 3 && label.contains(lower))) q.names.add(e.key.toLowerCase());
    }
  }
  final onlyPort = RegExp(r'^\d{1,5}$').firstMatch(lower);
  if (onlyPort != null) {
    final p = int.parse(lower);
    if (p >= 1 && p <= 65535) q.port = p;
    return q;
  }
  var s = lower.replaceFirst(RegExp(r'^[a-z][a-z0-9+.-]*://'), '').split(RegExp(r'[/?#]')).first;
  if (s.contains('@')) s = s.substring(s.lastIndexOf('@') + 1);
  final pm = RegExp(r'^(.*):(\d{1,5})$').firstMatch(s);
  if (pm != null && !pm[1]!.contains(':')) {
    final p = int.parse(pm[2]!);
    if (p >= 1 && p <= 65535) q.port = p;
    s = pm[1]!;
  }
  q.ip = InternetAddress.tryParse(s.replaceAll(RegExp(r'^\[|\]$'), ''));
  if (q.ip == null) q.host = cleanDomainName(s);
  return q;
}

bool _inCidr(InternetAddress ip, String cidr) {
  final slash = cidr.lastIndexOf('/');
  final net = InternetAddress.tryParse(slash < 0 ? cidr : cidr.substring(0, slash));
  final bits = slash < 0 ? null : int.tryParse(cidr.substring(slash + 1));
  if (net == null || bits == null) return false;
  final a = ip.rawAddress, b = net.rawAddress;
  if (a.length != b.length || bits > a.length * 8) return false;
  for (var i = 0; i < bits; i++) {
    final mask = 0x80 >> (i & 7);
    if ((a[i >> 3] ^ b[i >> 3]) & mask != 0) return false;
  }
  return true;
}

bool _hostIn(String host, String domain) => host == domain || host.endsWith('.$domain');

bool _matches(RouteRule r, _Query q) {
  final host = q.host;
  switch (r.kind) {
    case RuleKind.domain:
      return host != null && _hostIn(host, r.value);
    case RuleKind.full:
      return host != null && host == r.value;
    case RuleKind.keyword:
      return host != null && host.contains(r.value);
    case RuleKind.regex:
      if (host == null) return false;
      try {
        final plain = r.value
            .replaceAll(RegExp(r'\(\?[imsU]+\)'), '')
            .replaceAllMapped(RegExp(r'\(\?[imsU-]+:'), (_) => '(?:');
        return RegExp(plain, caseSensitive: !r.value.contains('(?i')).hasMatch(host);
      } catch (_) {
        return false;
      }
    case RuleKind.ip:
      return q.ip != null && _inCidr(q.ip!, r.value);
    case RuleKind.port:
      final p = q.port;
      if (p == null) return false;
      final parts = r.value.split('-');
      final from = int.parse(parts.first), to = int.parse(parts.last);
      return p >= from && p <= to;
    case RuleKind.app:
      return q.names.contains(r.value.toLowerCase());
    case RuleKind.service:
      final s = ruleServices[r.value];
      if (s == null) return false;
      if (q.names.contains(s.id) || q.names.contains(s.name.toLowerCase())) return true;
      return host != null && s.domains.any((d) => _hostIn(host, d));
  }
}

/// The rules that match [query] (a website, an address, a port, an app, or a link or `host:port`), in the
/// order they are applied: the first is the one that decides, the others are overridden by it. [appNames]
/// (id to name) lets an app be found by the name it is shown with.
List<RuleHit> matchRules(RuleLists lists, String query, {Map<String, String> appNames = const {}}) {
  final q = _readQuery(query, appNames);
  if (q.host == null && q.ip == null && q.port == null && q.names.isEmpty) return const [];
  return [
    for (final a in RuleAction.values)
      for (final text in lists.of(a))
        if (parseRouteRule(text) case final r? when _matches(r, q)) RuleHit(a, text),
  ];
}
