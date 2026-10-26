import 'dart:async';
import 'dart:io';

/// Whether any of a few well-known test pages answers (204 / 200) within [timeout].
Future<bool> internetWorks({Duration timeout = const Duration(seconds: 5)}) async {
  const urls = [
    'http://connectivitycheck.gstatic.com/generate_204',
    'http://cp.cloudflare.com/generate_204',
    'http://www.msftconnecttest.com/connecttest.txt',
  ];
  Future<bool> one(String url) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client.getUrl(Uri.parse(url)).timeout(timeout);
      final res = await req.close().timeout(timeout);
      await res.drain<void>().timeout(timeout);
      return res.statusCode == 204 || res.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  final done = Completer<bool>();
  var left = urls.length;
  for (final u in urls) {
    one(u).then((ok) {
      if (ok && !done.isCompleted) done.complete(true);
      if (--left == 0 && !done.isCompleted) done.complete(false);
    });
  }
  return done.future;
}

/// Whether the system can turn a name into an address.
Future<bool> dnsWorks({Duration timeout = const Duration(seconds: 5)}) async {
  for (final host in const ['example.com', 'cloudflare.com']) {
    try {
      final found = await InternetAddress.lookup(host).timeout(timeout);
      if (found.isNotEmpty) return true;
    } catch (_) {}
  }
  return false;
}

/// How far this device's clock is from the time a web server reports, or null if it could not be
/// found out. Secure protocols (TLS, Reality, VMess) stop working when the clock is far off.
Future<Duration?> clockSkew({Duration timeout = const Duration(seconds: 6)}) async {
  for (final url in const ['https://www.cloudflare.com/', 'https://www.google.com/']) {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final before = DateTime.now().toUtc();
      final req = await client.headUrl(Uri.parse(url)).timeout(timeout);
      final res = await req.close().timeout(timeout);
      await res.drain<void>().timeout(timeout);
      final header = res.headers.value(HttpHeaders.dateHeader);
      if (header == null) continue;
      final server = HttpDate.parse(header);
      // The reply took some time on its way; compare with the middle of the request.
      final after = DateTime.now().toUtc();
      final mid = before.add(after.difference(before) ~/ 2);
      return mid.difference(server);
    } catch (_) {
      continue;
    } finally {
      client.close(force: true);
    }
  }
  return null;
}
