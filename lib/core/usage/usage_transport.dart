import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../warp/warp_register.dart' show FragmentRelay, parseHttpResponse;
import 'usage_endpoints.dart';
import 'usage_reporter.dart';

/// The size (bytes) and pause (ms) of the pieces the TLS hello is cut into, as ranges [min, max].
typedef FragmentSettings = ({(int, int) size, (int, int) delay});

/// Used when no WARP profile is loaded (its numbers are preferred: they come from the signed file).
const defaultFragment = (size: (10, 30), delay: (5, 20));

const pingPath = '/api/v1/ping';

/// POSTs [body] to https://[endpoint]/api/v1/ping and returns the HTTP status, or null when no answer
/// came. Short timeouts; never throws. The address is always the endpoint's own host on port 443:
/// the fragmenting relay is only ever pointed at it (or at the Cloudflare addresses listed with it).
Future<int?> sendUsagePing(UsageEndpoint endpoint, Map<String, Object> body, PingMethod method,
    {FragmentSettings Function()? fragment}) async {
  try {
    final payload = utf8.encode(jsonEncode(body));
    if (method == PingMethod.direct) {
      final socket = await SecureSocket.connect(endpoint.host, 443, timeout: const Duration(seconds: 6));
      return await _post(socket, endpoint.host, payload);
    }
    final f = (fragment ?? () => defaultFragment)();
    // The name first, then the addresses the list gives for it.
    for (final target in [endpoint.host, ...endpoint.ips]) {
      final relay = await FragmentRelay.start(target, size: f.size, delay: f.delay);
      Socket? plain;
      try {
        plain = await Socket.connect(InternetAddress.loopbackIPv4, relay.port);
        final tls = await SecureSocket.secure(plain, host: endpoint.host)
            .timeout(const Duration(seconds: 8));
        final status = await _post(tls, endpoint.host, payload);
        if (status != null) return status;
      } catch (_) {
        // the next target
      } finally {
        plain?.destroy();
        await relay.close();
      }
    }
  } catch (_) {}
  return null;
}

Future<int?> _post(SecureSocket tls, String host, List<int> payload) async {
  try {
    tls.add([
      ...utf8.encode('POST $pingPath HTTP/1.1\r\nHost: $host\r\n'
          'Content-Type: application/json\r\nUser-Agent: Kumo\r\n'
          'Connection: close\r\nContent-Length: ${payload.length}\r\n\r\n'),
      ...payload,
    ]);
    final buffer = BytesBuilder();
    await for (final chunk in tls.timeout(const Duration(seconds: 10))) {
      buffer.add(chunk);
      final r = parseHttpResponse(buffer.toBytes());
      if (r != null) return r.status;
      if (buffer.length > 16 * 1024) break;
    }
    return parseHttpResponse(buffer.toBytes())?.status;
  } catch (_) {
    return null;
  } finally {
    tls.destroy();
  }
}

/// The text at [url] (the list of addresses), with short timeouts. Throws when it cannot be had.
Future<String> fetchText(String url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 8));
    req.headers.set('User-Agent', 'Kumo');
    final res = await req.close().timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
    final bytes = BytesBuilder();
    await for (final c in res.timeout(const Duration(seconds: 10))) {
      bytes.add(c);
      if (bytes.length > 32 * 1024) throw const HttpException('too large');
    }
    return utf8.decode(bytes.toBytes());
  } finally {
    client.close(force: true);
  }
}
