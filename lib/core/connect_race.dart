import 'dart:async';
import 'dart:io';

import 'latency_tester.dart' show NetPace, udpProtocols;
import 'proxy_config.dart';

/// The race of the automatic mode, run just before a connection is made.
///
/// The group of the automatic mode is ordered by the pings of the last tests, which can be minutes (or a
/// network change) old. The core dials the first server of the group until its own test has an answer, so a
/// server that has died since then costs the whole time limit of a dial on the first connection, which is
/// the thing the user waits for. Here the servers of the group are tried at once with a plain TCP connect
/// (a round trip each, no core started): the first answers decide the order, and a server that does not
/// answer in time is not the first one the core is given.

/// What a plain TCP connect can try for a server: an address that is not a name (a name the system's
/// resolver may answer wrongly is not looked up again here) and its port. Null where it cannot be tried:
/// servers on UDP, OpenVPN, servers reached through another one, and names that were not resolved.
({String host, int port})? raceTarget(ProxyConfig c) {
  if (c.isOpenVpn || !c.canSingBox || c.inner.isNotEmpty || udpProtocols.contains(c.protocol)) return null;
  final server = c.outbound['server'];
  if (server is! String || InternetAddress.tryParse(server) == null) return null;
  final port = c.outbound['server_port'];
  return (host: server, port: port is int ? port : c.port);
}

/// Time of a TCP connect to [host]:[port] in ms, -1 when it fails or is not done within [timeout].
typedef RaceProbe = Future<int> Function(String host, int port, Duration timeout);

Future<int> tcpProbe(String host, int port, Duration timeout) async {
  final sw = Stopwatch()..start();
  try {
    final s = await Socket.connect(host, port, timeout: timeout);
    s.destroy();
    NetPace.note(sw.elapsedMilliseconds);
    return sw.elapsedMilliseconds;
  } catch (_) {
    return -1;
  }
}

/// The order a group of servers should be given to the core in: indexes into [targets] (null = a server
/// that cannot be tried, see [raceTarget]).
///
/// All the servers are tried at once. It waits for the first answer and then a moment more ([grace]), or
/// until all have answered or failed. The servers that answered come first, in the order they were given
/// (the ranking of the tests is kept: only what is seen to be unreachable is moved), then the ones that
/// cannot be tried, then the ones still silent. A server whose connect failed is left out, but never so
/// many that fewer than [keepAtLeast] remain (a group of one is a different kind of connection). When no
/// server answered at all (the network itself is down, or everything is blocked) the order is not changed.
Future<List<int>> raceOrder(
  List<({String host, int port})?> targets, {
  RaceProbe probe = tcpProbe,
  Duration timeout = const Duration(milliseconds: 2500),
  Duration grace = const Duration(milliseconds: 300),
  int keepAtLeast = 2,
}) async {
  final n = targets.length;
  final identity = List<int>.generate(n, (i) => i);
  if (targets.every((t) => t == null)) return identity;
  // null: no answer yet, -1: failed, otherwise the time of the connect
  final ms = List<int?>.filled(n, null);
  final finished = Completer<void>();
  var open = 0;
  Timer? graceTimer;
  void finish() {
    if (!finished.isCompleted) finished.complete();
  }

  for (var i = 0; i < n; i++) {
    final t = targets[i];
    if (t == null) continue;
    open++;
    probe(t.host, t.port, timeout).then((v) => v, onError: (Object _) => -1).then((v) {
      ms[i] = v;
      open--;
      if (v >= 0) graceTimer ??= Timer(grace, finish);
      if (open == 0) finish();
    });
  }
  // The probes have limits of their own; this is only so that a probe that never ends cannot hold a connection.
  final hard = Timer(timeout + const Duration(milliseconds: 500), finish);
  await finished.future;
  hard.cancel();
  graceTimer?.cancel();

  final answered = [for (var i = 0; i < n; i++) if ((ms[i] ?? -1) >= 0) i];
  if (answered.isEmpty) return identity;
  final unknown = [for (var i = 0; i < n; i++) if (targets[i] == null) i];
  final silent = [for (var i = 0; i < n; i++) if (targets[i] != null && ms[i] == null) i];
  final failed = [for (var i = 0; i < n; i++) if (ms[i] == -1) i];
  final order = [...answered, ...unknown, ...silent];
  for (final i in failed) {
    if (order.length >= keepAtLeast) break;
    order.add(i);
  }
  return order;
}

/// The servers of [group] (and [resolved], the same servers with their names looked up, in the same order)
/// in the order [raceOrder] gives. Never throws: a failure leaves both lists as they were.
Future<({List<ProxyConfig> group, List<ProxyConfig> resolved, int answered, int total})> raceGroup(
  List<ProxyConfig> group,
  List<ProxyConfig> resolved, {
  RaceProbe probe = tcpProbe,
  Duration? timeout,
  Duration grace = const Duration(milliseconds: 300),
}) async {
  ({List<ProxyConfig> group, List<ProxyConfig> resolved, int answered, int total}) same(int answered) =>
      (group: group, resolved: resolved, answered: answered, total: group.length);
  if (group.length < 2 || resolved.length != group.length) return same(0);
  try {
    final targets = [for (final r in resolved) raceTarget(r)];
    final order = await raceOrder(targets,
        probe: probe, timeout: timeout ?? NetPace.scale(const Duration(milliseconds: 2500)), grace: grace);
    return (
      group: [for (final i in order) group[i]],
      resolved: [for (final i in order) resolved[i]],
      answered: order.length,
      total: group.length,
    );
  } catch (_) {
    return same(0);
  }
}
