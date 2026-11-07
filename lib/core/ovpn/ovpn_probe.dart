import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../proxy_config.dart' show OvpnServer;

/// Whether the server wants every packet signed with a key (tls-auth, tls-crypt): a first packet
/// that is not signed gets no answer, so the server cannot be told from a dead one this way.
bool ovpnSigned(String config) =>
    RegExp(r'^(<tls-(auth|crypt|crypt-v2)>|tls-(auth|crypt|crypt-v2)\b)', multiLine: true).hasMatch(config);

/// The first packet of OpenVPN over UDP (a "hard reset" from a client): the server answers it with
/// one of its own when it is there. Null when no answer came.
Future<int> udpProbe(String host, int port, {Duration timeout = const Duration(seconds: 3)}) async {
  final InternetAddress address;
  try {
    address = InternetAddress.tryParse(host) ?? (await InternetAddress.lookup(host).timeout(timeout)).first;
  } catch (_) {
    return -1;
  }
  final socket = await RawDatagramSocket.bind(
      address.type == InternetAddressType.IPv6 ? InternetAddress.anyIPv6 : InternetAddress.anyIPv4, 0);
  try {
    final random = Random.secure();
    // opcode 7 (P_CONTROL_HARD_RESET_CLIENT_V2) with key 0, a session id, no acknowledgements, packet 0.
    final packet = <int>[0x38, for (var i = 0; i < 8; i++) random.nextInt(256), 0, 0, 0, 0, 0];
    final done = Completer<int>();
    final sw = Stopwatch()..start();
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = socket.receive();
      if (d == null || d.data.isEmpty || done.isCompleted) return;
      // opcode 8: the answer of a server (V2); 2: of an old one (V1)
      final op = d.data[0] >> 3;
      if (op == 8 || op == 2) done.complete(max(1, sw.elapsedMilliseconds));
    });
    socket.send(packet, address, port);
    return await done.future.timeout(timeout, onTimeout: () => -1);
  } finally {
    socket.close();
  }
}

Future<int> _tcpConnect(String host, int port, Duration timeout) async {
  try {
    final address = InternetAddress.tryParse(host) ?? (await InternetAddress.lookup(host).timeout(timeout)).first;
    final sw = Stopwatch()..start();
    final s = await Socket.connect(address, port, timeout: timeout);
    s.destroy();
    return max(1, sw.elapsedMilliseconds);
  } catch (_) {
    return -1;
  }
}

/// The time the server of an OpenVPN profile takes to answer, in ms: a TCP connect for a TCP server and
/// the first packet of the protocol for a UDP one. -1 when none of its first three addresses answered,
/// -2 when this cannot be told (the server only listens to signed packets).
Future<int> ovpnPing(OvpnServer s, {Duration timeout = const Duration(seconds: 3)}) async {
  final signed = ovpnSigned(s.profile.config);
  var tested = false;
  var best = -1;
  for (final r in s.profile.remotes.take(3)) {
    final tcp = r.proto.startsWith('tcp');
    if (!tcp && signed) continue;
    tested = true;
    final ms = tcp ? await _tcpConnect(r.host, r.port, timeout) : await udpProbe(r.host, r.port, timeout: timeout);
    if (ms >= 0 && (best < 0 || ms < best)) best = ms;
  }
  return tested ? best : -2;
}

/// Runs the OpenVPN program against the server without an adapter (`--dev null`) and returns the time in
/// ms until the handshake is done and the server has accepted the client, -1 when it did not come in
/// [timeout], and -2 when it cannot be tried (no program, or a login is needed). Nothing is changed on the
/// computer: no adapter, no routes, no scripts.
Future<int> ovpnHandshake(OvpnServer s, {required String binary, Duration timeout = const Duration(seconds: 15)}) async {
  if (!File(binary).existsSync() || s.needsLogin || s.needsKeyPassword || s.profile.needsLogin) return -2;
  final dir = Directory.systemTemp.createTempSync('kumo_ovpn_probe');
  Process? process;
  try {
    // The file holds the certificates: it is removed as soon as the run ends.
    final config = s.profile.config
        .split('\n')
        .where((l) => !RegExp(r'^(dev|dev-type|dev-node)\b').hasMatch(l))
        .join('\n');
    final file = File('${dir.path}${Platform.pathSeparator}probe.ovpn')..writeAsStringSync('$config\n');
    process = await Process.start(
      binary,
      [
        '--config', file.path,
        '--dev', 'null', '--dev-type', 'tun',
        '--verb', '3',
        '--connect-timeout', '${max(5, timeout.inSeconds - 2)}',
        '--resolv-retry', '0',
        '--route-noexec', '--ifconfig-noexec',
        '--script-security', '1',
        '--disable-dco',
      ],
      workingDirectory: File(binary).parent.path,
      runInShell: false,
    );
    final sw = Stopwatch()..start();
    final done = Completer<int>();
    for (final stream in [process.stdout, process.stderr]) {
      stream.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        if (done.isCompleted) return;
        // the server accepted the client and sent its settings (a refused login answers AUTH_FAILED instead)
        if (line.contains('PUSH_REPLY')) {
          done.complete(max(1, sw.elapsedMilliseconds));
        } else if (line.contains('AUTH_FAILED') || line.contains('Exiting due to fatal error')) {
          done.complete(-1);
        }
      }, onError: (_) {});
    }
    unawaited(process.exitCode.then((_) {
      if (!done.isCompleted) done.complete(-1);
    }));
    return await done.future.timeout(timeout, onTimeout: () => -1);
  } catch (_) {
    return -1;
  } finally {
    process?.kill();
    if (process != null) await process.exitCode.timeout(const Duration(seconds: 3), onTimeout: () => -1);
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }
}
