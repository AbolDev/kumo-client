import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'latency_tester.dart' show socksWarmDelay;

/// The real delay of a server that only Xray can carry (XHTTP, mKCP, VLESS encryption ...): a
/// throw-away Xray process with a SOCKS inbound, and the same two requests over one connection
/// that the sing-box test uses, so both kinds of server are measured the same way.
///
/// [exe] is the Xray program, [config] builds its configuration for the SOCKS port that was
/// chosen. [resolveNames] looks the server's name up first (Android: Xray's own resolver cannot
/// read the phone's DNS settings). Returns -1 on failure.
Future<int> runXrayDelay({
  required String exe,
  required String dataDir,
  required String Function(int port) config,
  required String url,
  required int timeoutMs,
  bool resolveNames = false,
  Future<Process> Function(String exe, List<String> args)? spawn,
}) async {
  Process? process;
  File? file;
  try {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();

    var json = config(port);
    if (resolveNames) json = await _resolved(json);
    final sep = Platform.pathSeparator;
    await Directory('$dataDir${sep}delay').create(recursive: true);
    file = File('$dataDir${sep}delay${sep}xray-$port.json');
    await file.writeAsString(json);

    process = await (spawn ?? (e, a) => Process.start(e, a, workingDirectory: dataDir))(
        exe, ['run', '-c', file.path]);
    // keep its output read so it never blocks on a full pipe
    process.stdout.listen((_) {}, onError: (_) {});
    process.stderr.listen((_) {}, onError: (_) {});
    var exited = false;
    process.exitCode.then((_) => exited = true);

    final end = DateTime.now().add(const Duration(seconds: 8));
    var ready = false;
    while (!exited && DateTime.now().isBefore(end)) {
      try {
        final s = await Socket.connect('127.0.0.1', port, timeout: const Duration(milliseconds: 500));
        s.destroy();
        ready = true;
        break;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
    }
    if (!ready) return -1;
    return await socksWarmDelay(port, Uri.parse(url), Duration(milliseconds: timeoutMs));
  } catch (_) {
    return -1;
  } finally {
    process?.kill();
    try {
      await file?.delete();
    } catch (_) {}
  }
}

/// The server addresses of an Xray configuration replaced by their IP addresses.
Future<String> _resolved(String json) async {
  Future<String> ip(String host) async {
    if (InternetAddress.tryParse(host) != null) return host;
    try {
      final found = await InternetAddress.lookup(host).timeout(const Duration(seconds: 3));
      return found.isEmpty ? host : found.first.address;
    } catch (_) {
      return host;
    }
  }

  try {
    final cfg = jsonDecode(json) as Map<String, dynamic>;
    final outbounds = cfg['outbounds'];
    if (outbounds is List && outbounds.isNotEmpty && outbounds.first is Map) {
      final settings = (outbounds.first as Map)['settings'];
      if (settings is Map) {
        final list = settings['vnext'] ?? settings['servers'];
        if (list is List && list.isNotEmpty && list.first is Map) {
          final target = list.first as Map;
          if (target['address'] is String) target['address'] = await ip(target['address'] as String);
        } else if (settings['address'] is String && settings.containsKey('port')) {
          settings['address'] = await ip(settings['address'] as String);
        }
        final peers = settings['peers'];
        if (peers is List) {
          for (final peer in peers) {
            if (peer is! Map || peer['endpoint'] is! String) continue;
            final endpoint = peer['endpoint'] as String;
            final colon = endpoint.lastIndexOf(':');
            if (colon > 0 && !endpoint.startsWith('[')) {
              peer['endpoint'] = (await ip(endpoint.substring(0, colon))) + endpoint.substring(colon);
            }
          }
        }
      }
    }
    // a loopback relay (plain VLESS) carries the real server address on its inbound
    final inbounds = cfg['inbounds'];
    if (inbounds is List) {
      for (final inbound in inbounds) {
        if (inbound is Map && inbound['protocol'] == 'dokodemo-door' && inbound['settings'] is Map) {
          final s = inbound['settings'] as Map;
          if (s['address'] is String) s['address'] = await ip(s['address'] as String);
        }
      }
    }
    return jsonEncode(cfg);
  } catch (_) {
    return json;
  }
}
