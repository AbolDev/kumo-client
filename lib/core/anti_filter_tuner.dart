import 'dart:async';
import 'dart:math';

import 'latency_tester.dart' show realDelay;
import 'net_options.dart';
import 'proxy_config.dart';

/// "Find the best settings for my network": tries a few of the advanced options (fragmenting the TLS
/// hello, a uTLS fingerprint, multiplexing) on a few of the user's servers with the real delay test,
/// and says which ones work best here. Everything runs on this device; nothing is sent anywhere.
/// Name lookups are not part of it: the test cores look the server up with the system resolver.

/// One combination of the options to try.
class TuneVariant {
  const TuneVariant(this.id, this.apply);

  /// Short name, also the key of its text ("tune_" + id is not used; the id is shown as is).
  final String id;

  /// Sets this variant's options on [o] (a copy of the user's options).
  final void Function(NetOptions o) apply;
}

/// The combinations, the user's own settings first (to compare with).
final List<TuneVariant> tuneVariants = [
  TuneVariant('current', (o) {}),
  TuneVariant('fragment', (o) => o.tlsFragment = true),
  TuneVariant('fragment+record', (o) {
    o.tlsFragment = true;
    o.tlsRecordFragment = true;
  }),
  TuneVariant('chrome', (o) => o.fingerprint = 'chrome'),
  TuneVariant('firefox', (o) => o.fingerprint = 'firefox'),
  TuneVariant('ios', (o) => o.fingerprint = 'ios'),
  TuneVariant('random', (o) => o.fingerprint = 'random'),
  TuneVariant('fragment+chrome', (o) {
    o.tlsFragment = true;
    o.fingerprint = 'chrome';
  }),
  TuneVariant('mux', (o) => o.mux = true),
];

/// How one variant did over all the servers tried.
class TuneScore {
  TuneScore(this.variant, this.ok, this.total, this.medianMs);

  final TuneVariant variant;
  final int ok;
  final int total;

  /// The middle one of the successful delays, ms; null when none succeeded.
  final int? medianMs;
}

/// A copy of [o]: the options are saved as JSON, so this is the same copy a restart would make.
NetOptions copyOptions(NetOptions o) => NetOptions()..load(o.toJson());

/// The servers worth trying: ones sing-box carries over TLS on TCP (where fragmenting and a
/// fingerprint apply), the selected one first, then the fastest by the connect time already
/// measured; at most [max].
List<ProxyConfig> tuneServers(Iterable<ProxyConfig> all, ProxyConfig? selected, {int max = 3}) {
  bool fits(ProxyConfig c) {
    if (c.isOpenVpn || !c.canSingBox || c.preferXray || c.inner.isNotEmpty) return false;
    final type = c.outbound['type'];
    final tls = c.outbound['tls'];
    return (type == 'vless' || type == 'vmess' || type == 'trojan') && tls is Map && tls['enabled'] == true;
  }

  final fast = all.where((c) => fits(c) && c.isAlive).toList()
    ..sort((a, b) => (a.latencyMs ?? 1 << 30).compareTo(b.latencyMs ?? 1 << 30));
  final out = <ProxyConfig>[
    if (selected != null && fits(selected)) selected,
    ...fast.where((c) => !identical(c, selected)),
  ];
  return out.take(max).toList();
}

typedef TuneDelay = Future<int> Function(ProxyConfig server, NetOptions options);

Future<int> _realDelay(ProxyConfig c, NetOptions o) => realDelay(c, options: o, timeout: const Duration(seconds: 7));

/// Tries every variant on every server ([parallel] at a time; each test starts a throw-away core).
/// [onProgress] gets how many tests are done and how many there are; [cancelled] stops the run.
Future<List<TuneScore>> runTuner({
  required List<ProxyConfig> servers,
  required NetOptions base,
  TuneDelay delay = _realDelay,
  List<TuneVariant>? variants,
  int parallel = 3,
  void Function(int done, int total)? onProgress,
  bool Function()? cancelled,
}) async {
  final list = variants ?? tuneVariants;
  final jobs = <(int, ProxyConfig)>[
    for (var v = 0; v < list.length; v++)
      for (final s in servers) (v, s),
  ];
  final results = List.generate(list.length, (_) => <int>[]);
  var next = 0, done = 0;
  Future<void> worker() async {
    while (true) {
      if (cancelled?.call() == true) return;
      final i = next++;
      if (i >= jobs.length) return;
      final (v, server) = jobs[i];
      final o = copyOptions(base);
      list[v].apply(o);
      int ms;
      try {
        ms = await delay(server, o);
      } catch (_) {
        ms = -1;
      }
      // -2: the test was skipped (the tunnel is being started or stopped): it is no answer.
      if (ms != -2) results[v].add(ms);
      onProgress?.call(++done, jobs.length);
    }
  }

  await Future.wait([for (var i = 0; i < min(parallel, max(1, jobs.length)); i++) worker()]);
  return [
    for (var v = 0; v < list.length; v++)
      () {
        final good = results[v].where((ms) => ms >= 0).toList()..sort();
        return TuneScore(list[v], good.length, results[v].length, good.isEmpty ? null : good[good.length ~/ 2]);
      }(),
  ];
}

/// What to tell the user.
enum TuneVerdict {
  /// Nothing worked, with or without the options: the servers or the network are the problem.
  nothingWorks,

  /// The user's own settings did as well as anything: nothing to change.
  currentIsBest,

  /// Another combination works clearly better (more servers answer, or the same ones answer faster).
  better,
}

({TuneVerdict verdict, TuneScore? best}) recommend(List<TuneScore> scores) {
  if (scores.isEmpty || scores.every((s) => s.ok == 0)) return (verdict: TuneVerdict.nothingWorks, best: null);
  final current = scores.first;
  // More servers answering wins; among equals the lower middle delay.
  final ranked = [...scores]..sort((a, b) {
      final byOk = b.ok.compareTo(a.ok);
      if (byOk != 0) return byOk;
      return (a.medianMs ?? 1 << 30).compareTo(b.medianMs ?? 1 << 30);
    });
  final best = ranked.first;
  if (identical(best, current)) return (verdict: TuneVerdict.currentIsBest, best: current);
  final moreServers = best.ok > current.ok;
  // The same servers, answering at least a fifth faster and by more than 50 ms.
  final faster = current.medianMs != null &&
      best.medianMs != null &&
      best.medianMs! < current.medianMs! * 0.8 &&
      current.medianMs! - best.medianMs! > 50;
  if (moreServers || faster) return (verdict: TuneVerdict.better, best: best);
  return (verdict: TuneVerdict.currentIsBest, best: current);
}
