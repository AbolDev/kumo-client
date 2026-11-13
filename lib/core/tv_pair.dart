import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;
import 'dart:typed_data' show BytesBuilder;

/// A television has no camera, no files to pick and no good way to type a long link. So it lets a phone on the
/// same network do it: it shows an address and a code, the phone opens the address in its browser, pastes the
/// link or the subscription into a box and sends it, and the television adds it (after asking the user).
///
/// The server listens on the local network only while the page that shows the address is open, under a random
/// secret in the path, takes small texts only and stops after [maxTexts] of them.
class TvPairServer {
  TvPairServer({this.maxTexts = 20});

  /// The most texts one session takes.
  final int maxTexts;

  HttpServer? _server;
  String _secret = '';
  var _taken = 0;

  /// The address the phone opens (null until [start] has run, or when there is no local network).
  String? url;

  /// Starts listening; [onText] gets each text the phone sends. Returns the address, or null when the device
  /// has no local network address to give.
  Future<String?> start(void Function(String text) onText) async {
    await stop();
    final host = await localAddress();
    if (host == null) return null;
    final random = Random.secure();
    _secret = List.generate(12, (_) => random.nextInt(36).toRadixString(36)).join();
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _server = server;
    unawaited(_serve(server, onText));
    return url = 'http://$host:${server.port}/$_secret';
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    url = null;
    _taken = 0;
    await s?.close(force: true);
  }

  Future<void> _serve(HttpServer server, void Function(String text) onText) async {
    await for (final req in server) {
      try {
        await _handle(req, onText);
      } catch (_) {
        try {
          req.response
            ..statusCode = HttpStatus.internalServerError
            ..close();
        } catch (_) {}
      }
    }
  }

  /// The body of a request as text, read up to 64 KB (null when it is longer or does not arrive).
  Future<String?> _readBody(HttpRequest req) async {
    final bytes = BytesBuilder();
    try {
      await for (final chunk in req.timeout(const Duration(seconds: 10))) {
        bytes.add(chunk);
        if (bytes.length > 64 * 1024) return null;
      }
    } catch (_) {
      return null;
    }
    return utf8.decode(bytes.takeBytes(), allowMalformed: true);
  }

  Future<void> _handle(HttpRequest req, void Function(String text) onText) async {
    final res = req.response;
    final path = req.uri.path;
    if (path != '/$_secret' && path != '/$_secret/') {
      res
        ..statusCode = HttpStatus.notFound
        ..write('Not found');
      await res.close();
      return;
    }
    if (req.method == 'POST') {
      // Small on purpose: a link, a few links or a subscription address, not a file.
      final body = await _readBody(req);
      final text = body == null ? null : tvPairText(body);
      final ok = text != null && _taken < maxTexts;
      if (ok) {
        _taken++;
        onText(text);
      }
      res
        ..statusCode = ok ? HttpStatus.ok : HttpStatus.badRequest
        ..headers.contentType = ContentType.html
        ..write(tvPairPage(sent: ok, failed: !ok));
      await res.close();
      return;
    }
    res
      ..headers.contentType = ContentType.html
      ..headers.set('Cache-Control', 'no-store')
      ..write(tvPairPage());
    await res.close();
  }
}

/// The text a phone sent (the form's field `text`, or plain text): trimmed, and null when empty or too large.
String? tvPairText(String body) {
  if (body.length > 64 * 1024) return null;
  var text = body;
  if (RegExp(r'^text=').hasMatch(body)) {
    final pairs = Uri.splitQueryString(body);
    text = pairs['text'] ?? '';
  }
  text = text.trim();
  return text.isEmpty ? null : text;
}

/// The page the phone shows: a box to paste into and a button, in English and Persian.
String tvPairPage({bool sent = false, bool failed = false}) => '''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Kumo</title>
<style>
body{font-family:system-ui,sans-serif;margin:0;padding:24px;background:#0b2b28;color:#fff}
main{max-width:520px;margin:0 auto}
h1{font-size:24px;margin:0 0 4px}
p{color:#c9e4e0;line-height:1.6;margin:8px 0 16px}
textarea{width:100%;box-sizing:border-box;min-height:150px;border-radius:14px;border:2px solid #16b8a4;padding:12px;font-size:16px;background:#fff;color:#111}
button{margin-top:14px;width:100%;padding:16px;border:0;border-radius:14px;background:#16b8a4;color:#04302c;font-size:18px;font-weight:700}
.ok{background:#16b8a4;color:#04302c;padding:12px 14px;border-radius:12px;margin-bottom:14px}
.bad{background:#ffb4ab;color:#410002;padding:12px 14px;border-radius:12px;margin-bottom:14px}
</style></head><body><main>
<h1>Kumo</h1>
${sent ? '<div class="ok">Sent. Look at the TV. / ارسال شد. به تلویزیون نگاه کنید.</div>' : ''}
${failed ? '<div class="bad">Nothing was added. / چیزی اضافه نشد.</div>' : ''}
<p>Paste a server link or a subscription address and send it to your TV.<br>لینک سرور یا آدرس اشتراک را اینجا بچسبانید و برای تلویزیون بفرستید.</p>
<form method="post"><textarea name="text" dir="ltr" autocomplete="off" autocapitalize="off" spellcheck="false" placeholder="vless://… https://…"></textarea>
<button type="submit">Send to TV / ارسال به تلویزیون</button></form>
</main></body></html>''';

/// The address of this device on the local network (not a loopback or a link-local one), the one a phone on the
/// same Wi-Fi or cable can reach; null when there is none.
Future<String?> localAddress() async {
  try {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
    for (final i in interfaces) {
      for (final a in i.addresses) {
        if (isLocalNetworkAddress(a.address)) return a.address;
      }
    }
  } catch (_) {}
  return null;
}

/// Whether [ip] is a private IPv4 address (10.x, 172.16-31.x, 192.168.x).
bool isLocalNetworkAddress(String ip) {
  final p = ip.split('.').map(int.tryParse).toList();
  if (p.length != 4 || p.any((n) => n == null)) return false;
  return p[0] == 10 || (p[0] == 172 && p[1]! >= 16 && p[1]! <= 31) || (p[0] == 192 && p[1] == 168);
}
