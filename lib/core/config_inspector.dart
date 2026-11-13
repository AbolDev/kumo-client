import 'dart:async';
import 'dart:convert';

import 'latency_tester.dart' show serverProbeConfig;
import 'probe_fetch.dart';
import 'proxy_config.dart';
import 'vpn_channel.dart';

/// The safety check of a server: a few well-known addresses are fetched through it, and what comes back is
/// compared with what they must look like (and with what the network itself gets when the server did not
/// look right). It finds a server that changes what passes through it: one that puts its own certificate
/// in front of a secure site (so that it can read it), changes a plain page (to add to it), or does not
/// hide your address at all.
///
/// It cannot find a server that only watches: the one who runs it sees which names you ask for and when, and
/// no test shows that. A result of "nothing found" is only that: nothing in these tests.

enum ProbeKind { tls, plain, trace }

class InspectTarget {
  const InspectTarget(this.url, this.kind);

  final String url;
  final ProbeKind kind;

  String get host => Uri.parse(url).host;

  /// Whether [r] is what this address gives when nothing is changed on the way.
  bool good(ProbeResult r) {
    if (!r.ok) return false;
    if (kind != ProbeKind.plain) return r.verified != false;
    final body = r.body.toLowerCase();
    if (host == 'example.com') {
      return r.status == 200 && body.contains('example domain') && !body.contains('<script') && !body.contains('<iframe');
    }
    // The page of the browsers' captive-portal check: exactly one word.
    return r.status == 200 && body.trim() == 'success';
  }
}

/// Two secure sites of different companies (a certificate that is put in front of them cannot be valid), one
/// of which also tells which address the server shows to the world, and two plain pages that are always the
/// same, where a server that adds to pages shows itself.
const inspectTargets = [
  InspectTarget('https://www.cloudflare.com/cdn-cgi/trace', ProbeKind.trace),
  InspectTarget('https://www.gstatic.com/generate_204', ProbeKind.tls),
  InspectTarget('https://en.wikipedia.org/robots.txt', ProbeKind.tls),
  InspectTarget('http://example.com/', ProbeKind.plain),
  InspectTarget('http://detectportal.firefox.com/success.txt', ProbeKind.plain),
];

enum InspectVerdict { clean, suspicious, danger, unknown }

enum FindingKind {
  /// A secure site came with a certificate that is not valid, and the network sees the real one.
  badCertificate,

  /// The same, without the network's answer to say it is the server.
  badCertificateUnconfirmed,

  /// A plain page was changed, and the network gets it as it is.
  pageChanged,
  pageChangedUnconfirmed,

  /// The address that the world sees is the address of this device.
  sameAddress,

  /// The server does not give this address, which the network does.
  blocked,

  /// Nothing came through the server.
  noAnswer,

  /// The server is of a kind that cannot be tried here (OpenVPN, carried by Xray alone).
  unsupported,

  /// The test could not run now (the connection is being started or stopped).
  busy,
}

class Finding {
  const Finding(this.kind, [this.host = '']);

  final FindingKind kind;
  final String host;

  InspectVerdict get severity => switch (kind) {
        FindingKind.badCertificate || FindingKind.pageChanged => InspectVerdict.danger,
        FindingKind.badCertificateUnconfirmed ||
        FindingKind.pageChangedUnconfirmed ||
        FindingKind.sameAddress =>
          InspectVerdict.suspicious,
        _ => InspectVerdict.clean,
      };
}

class InspectReport {
  InspectReport(this.verdict, this.findings, {this.exitIp, this.exitCountry, this.passed = 0, DateTime? at})
      : at = at ?? DateTime.now();

  final InspectVerdict verdict;
  final List<Finding> findings;

  /// The address and country that the world sees when it is the server that is used.
  final String? exitIp;
  final String? exitCountry;

  /// How many of the addresses came as they must.
  final int passed;
  final DateTime at;
}

/// What the check left of a server, kept to show a mark in the list and to leave a dangerous one out.
class SafetyNote {
  const SafetyNote(this.verdict, this.at);

  final InspectVerdict verdict;
  final int at;

  Map<String, dynamic> toJson() => {'v': verdict.index, 'at': at};

  static SafetyNote? fromJson(Object? j) {
    if (j is! Map) return null;
    final v = (j['v'] as num?)?.toInt() ?? -1;
    if (v < 0 || v >= InspectVerdict.values.length) return null;
    return SafetyNote(InspectVerdict.values[v], (j['at'] as num?)?.toInt() ?? 0);
  }
}

/// `ip` and `loc` of the answer of Cloudflare's trace page.
({String? ip, String? country}) parseTrace(String body) {
  String? ip, loc;
  for (final line in body.split('\n')) {
    final i = line.indexOf('=');
    if (i < 0) continue;
    final k = line.substring(0, i).trim(), v = line.substring(i + 1).trim();
    if (k == 'ip' && v.isNotEmpty) ip = v;
    if (k == 'loc' && v.isNotEmpty) loc = v;
  }
  return (ip: ip, country: loc);
}

/// The verdict on [via] (the answers through the server, one for each of [inspectTargets], in the same order),
/// with [direct] (what the network itself answered for the addresses that did not look right through the
/// server) and [directIp] (the address the network shows, when it is known: only without a connection).
///
/// "Danger" is only said when the network gets the right answer from the same address: a bad certificate or a
/// changed page that the network gives too is the network's (a hotel's login page, a filter), not the server's.
InspectReport judgeInspection(List<ProbeResult> via, Map<String, ProbeResult> direct, {String? directIp}) {
  if (via.length != inspectTargets.length) return InspectReport(InspectVerdict.unknown, [const Finding(FindingKind.busy)]);
  final findings = <Finding>[];
  var answered = 0, passed = 0;
  String? exitIp, exitCountry;
  for (var i = 0; i < inspectTargets.length; i++) {
    final t = inspectTargets[i], v = via[i], d = direct[t.url];
    if (!v.ok) {
      if (d != null && d.ok) findings.add(Finding(FindingKind.blocked, t.host));
      continue;
    }
    answered++;
    if (t.kind == ProbeKind.trace) {
      final trace = parseTrace(v.body);
      exitIp = trace.ip;
      exitCountry = trace.country;
    }
    if (t.good(v)) {
      passed++;
      continue;
    }
    final plain = t.kind == ProbeKind.plain;
    final networkGood = d != null && t.good(d);
    final networkAlsoBad = d != null && d.ok && !networkGood;
    if (networkAlsoBad) continue;
    if (networkGood) {
      findings.add(Finding(plain ? FindingKind.pageChanged : FindingKind.badCertificate, t.host));
    } else {
      findings.add(Finding(plain ? FindingKind.pageChangedUnconfirmed : FindingKind.badCertificateUnconfirmed, t.host));
    }
  }
  if (exitIp != null && directIp != null && exitIp == directIp) findings.add(const Finding(FindingKind.sameAddress));
  if (answered == 0) findings.add(const Finding(FindingKind.noAnswer));
  final InspectVerdict verdict;
  if (findings.any((f) => f.severity == InspectVerdict.danger)) {
    verdict = InspectVerdict.danger;
  } else if (findings.any((f) => f.severity == InspectVerdict.suspicious)) {
    verdict = InspectVerdict.suspicious;
  } else if (answered == 0) {
    verdict = InspectVerdict.unknown;
  } else {
    verdict = InspectVerdict.clean;
  }
  return InspectReport(verdict, findings, exitIp: exitIp, exitCountry: exitCountry, passed: passed);
}

/// Fetches the addresses through [c]: null when the test could not run now, an empty list when it ran and
/// failed. The throw-away core of the platform does it (see [VpnChannel.inspect]).
typedef InspectVia = Future<List<ProbeResult>?> Function(ProxyConfig c);

Future<List<ProbeResult>?> _viaServer(ProxyConfig c) async {
  final config = await serverProbeConfig(c);
  if (config == null) return const [];
  final requests = jsonEncode([for (final t in inspectTargets) {'url': t.url}]);
  final answer = await VpnChannel.inspect(config, requests);
  if (answer == null) return null;
  return ProbeResult.listFromJson(answer);
}

/// Checks the server [c]. [networkIsOpen]: the device is not in a VPN now, so that what it fetches itself is
/// the network's own and its address is the one to compare with. [via] and [fetch] are for the tests.
Future<InspectReport> inspectServer(
  ProxyConfig c, {
  required bool networkIsOpen,
  InspectVia? via,
  Future<ProbeResult> Function(Uri uri)? fetch,
}) async {
  if (c.isOpenVpn || !c.canSingBox || (c.preferXray && c.canXray)) {
    return InspectReport(InspectVerdict.unknown, [const Finding(FindingKind.unsupported)]);
  }
  final fetchNet = fetch ?? (uri) => probeFetch(uri);
  final answers = await (via ?? _viaServer)(c);
  if (answers == null) return InspectReport(InspectVerdict.unknown, [const Finding(FindingKind.busy)]);
  if (answers.length != inspectTargets.length) {
    return InspectReport(InspectVerdict.unknown, [const Finding(FindingKind.noAnswer)]);
  }
  // What the network itself gets, for the addresses that did not look right through the server.
  final direct = <String, ProbeResult>{};
  await Future.wait([
    for (var i = 0; i < inspectTargets.length; i++)
      if (!inspectTargets[i].good(answers[i]))
        fetchNet(Uri.parse(inspectTargets[i].url)).then((r) => direct[inspectTargets[i].url] = r),
  ]);
  String? directIp;
  if (networkIsOpen) {
    final trace = inspectTargets.first;
    final r = direct[trace.url] ?? await fetchNet(Uri.parse(trace.url));
    if (r.ok) directIp = parseTrace(r.body).ip;
  }
  return judgeInspection(answers, direct, directIp: directIp);
}
