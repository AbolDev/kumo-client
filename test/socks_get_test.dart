import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/socks_get.dart';

/// A SOCKS5 proxy on this computer for the tests: [routes] says where each "host:port" asked for
/// really is, [seen] collects what was asked for, [auth] makes it ask for a login.
Future<ServerSocket> _fakeSocks(Map<String, int> routes, {List<String>? seen, ({String user, String pass})? auth}) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((client) {
    var stage = 0; // 0 greeting, 1 login, 2 request, 3 passing bytes on
    final inb = <int>[];
    final pending = <int>[];
    Socket? upstream;
    client.listen((data) {
      if (stage == 3) {
        if (upstream == null) {
          pending.addAll(data);
        } else {
          upstream!.add(data);
        }
        return;
      }
      inb.addAll(data);
      if (stage == 0 && inb.length >= 3) {
        inb.removeRange(0, 3);
        client.add([5, auth == null ? 0 : 2]);
        stage = auth == null ? 2 : 1;
      }
      if (stage == 1 && inb.length >= 2) {
        final ul = inb[1];
        if (inb.length >= 3 + ul) {
          final pl = inb[2 + ul];
          if (inb.length >= 3 + ul + pl) {
            final user = utf8.decode(inb.sublist(2, 2 + ul));
            final pass = utf8.decode(inb.sublist(3 + ul, 3 + ul + pl));
            inb.removeRange(0, 3 + ul + pl);
            if (user == auth!.user && pass == auth.pass) {
              client.add([1, 0]);
              stage = 2;
            } else {
              client.add([1, 1]);
              client.close();
              return;
            }
          }
        }
      }
      if (stage == 2 && inb.length >= 5) {
        final len = inb[4];
        if (inb.length >= 5 + len + 2) {
          final host = utf8.decode(inb.sublist(5, 5 + len));
          final port = (inb[5 + len] << 8) | inb[6 + len];
          inb.clear();
          stage = 3;
          seen?.add('$host:$port');
          final to = routes['$host:$port'];
          if (to == null) {
            client.add([5, 5, 0, 1, 0, 0, 0, 0, 0, 0]);
            client.close();
            return;
          }
          Socket.connect(InternetAddress.loopbackIPv4, to).then((s) {
            upstream = s;
            client.add([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
            if (pending.isNotEmpty) {
              s.add(pending);
              pending.clear();
            }
            s.listen((d) => client.add(d), onDone: () => client.close(), onError: (Object _) => client.close());
          }, onError: (Object _) {
            client.add([5, 1, 0, 1, 0, 0, 0, 0, 0, 0]);
            client.close();
          });
        }
      }
    }, onError: (Object _) {}, onDone: () => upstream?.close());
  });
  return server;
}

const _certificate = '''-----BEGIN CERTIFICATE-----
MIIDITCCAgmgAwIBAgIUJLbdcolXUNHnOYO/tQLL8bsIfbIwDQYJKoZIhvcNAQEL
BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2MTEwOTIzMTg0MloYDzIxMjYx
MDE2MjMxODQyWjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwggEiMA0GCSqGSIb3DQEB
AQUAA4IBDwAwggEKAoIBAQDYd/g/jbHs4yInH4WGEaCoipIDyuyEC++IOFrIqQbQ
aSoGkR5VY26PGjQkVsSnGUbQHOMiJey3t7p29gEnl11ZbGHwq7HYsVnpKtRUGYvr
77izSNlTQqdIMMPQBpHTffWJ9a0j5PBN7CASaGUiQ/uiq8/d3RxFIBXbWemt5jVW
8NfImLqLCA7eSXKjoGUA8/A9dEA01x+QSIGP2Cdow/3h7o15l6IXZ1XXc+XjYOf7
Y5RlOsEmGMTHD6BqPSqzgU41uLfdvQGEHEuxAJyzwRaCrFwUpKCnFJf/m8B4zSoH
V5hXzpSqKTxKXmBliOuzsx8/g2Df//qNJGir2rhPsTttAgMBAAGjaTBnMB0GA1Ud
DgQWBBR5eIqKdThgFOCIveAVp+xpAPeF2DAfBgNVHSMEGDAWgBR5eIqKdThgFOCI
veAVp+xpAPeF2DAPBgNVHRMBAf8EBTADAQH/MBQGA1UdEQQNMAuCCWxvY2FsaG9z
dDANBgkqhkiG9w0BAQsFAAOCAQEAEw7VD8KDPNhDGojckqg5oIK0c4FYhb1ZL1Ks
IUg0/oa4s1Nr0uFbAnytNPmwU6aXfG/aXVYbW9EqGA0BXb4TAwb+/ouCT1ilcVp+
7KnjTa9bUAwfymoy4NLpffEk3iqxn5vC82YFZJ1uzWLBvjgDUnw/oE+9NLyGN25b
kt6WbpzmRBN35FU09gdAZxPXgiTQjOG8zc0P5vbG2Xkmap1jiRPf0jGrFB5VO0K5
qruxJnLwxG1gj8BKi3cHqGJUxmu8LdvH0hbhhoUPJcsJXipSIRfAX7aVrPLAZFxg
tiUViNQRgx0DbepL/icFmKsF/SeK9gtzvxoWeVBVuo6y01BqKg==
-----END CERTIFICATE-----''';
const _privateKey = '''-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDYd/g/jbHs4yIn
H4WGEaCoipIDyuyEC++IOFrIqQbQaSoGkR5VY26PGjQkVsSnGUbQHOMiJey3t7p2
9gEnl11ZbGHwq7HYsVnpKtRUGYvr77izSNlTQqdIMMPQBpHTffWJ9a0j5PBN7CAS
aGUiQ/uiq8/d3RxFIBXbWemt5jVW8NfImLqLCA7eSXKjoGUA8/A9dEA01x+QSIGP
2Cdow/3h7o15l6IXZ1XXc+XjYOf7Y5RlOsEmGMTHD6BqPSqzgU41uLfdvQGEHEux
AJyzwRaCrFwUpKCnFJf/m8B4zSoHV5hXzpSqKTxKXmBliOuzsx8/g2Df//qNJGir
2rhPsTttAgMBAAECggEACDBxtHsjJ2JoYQaGQfjaFRuOQ+p3YX96GQiDbA1I9ArR
IN0jQqO3rl5AFBKG714QxGrIr6VeUTei1uvzmzsqDZSrbTQcTvsBUHA4XCjN7FJu
BbT/KRvfwZFmtwX976cCP601rE1K8ge5fDjK1VhburRj8XFzUld7vDKomSruYFLm
X0xKhPJVujvbSnS3V8pjYoXkFKIBi+EL9xdhiHuemGIZP4RHCHdh4meDrhWQ5Y5u
I8CMiHrQNQR9qpHUbJgnKDmdvNDDnRvhHMcZKFuJvMDaorjKDfqd8npx/nY44c4B
R24iJHYfKC9DJAl1yA8ODPRslZvDJ9wicAz5M/cSgQKBgQD5qFHIwA5QG9Db54Sg
pF1vOV/5vgVZIBBDE0YtwDCDCHhf3UikpMEp5on+4OYBLuEUkzUTp/tzWaPGqEcc
iIsu/bH+Xp9dJ7rnuIWvkXPwA6k4mAMyZ8nk/lgsANGDhLm0D4p8saEmr2RK3KQh
d6Wnvx+3PkeIDDpsmmBMnFUzcQKBgQDd981UppxnNfOUFjaz24x4Yt81nTiHQlBa
SC9WiCxSThEHGjBwZUCIr052b5f8kp6dm4CFHhZdFAAe9zki6ZOkyjjo4TlFCVkb
fNRZvnyRgW3lpbdPH307dj6BlTdC1VWj12+kVZH3oVXXyun4rfVLTtjv+nuWIXF9
zfE9RvvRvQKBgHr7q64Uzfgwe6aYWgE4dr5/qQPB06if3uLr77pB3qPt3D59J3fT
oUQeyQPBjgwvJ7mW+qKAMaIVGlSWONGZgdbYKoJ/4klldPEJOPHP2Sj25Ll4SLrf
3djsYkrq7Eq5azGEJlheuF/yLpmiL0g9RGFqCRmfmGUwgOdW9PFIYcBBAoGAXhag
TvWg7o8MBQW1gl/aF12xyAQw5gTSErLuffuS7gBxb1VGmx4QUOAenk2HW2S7H4u+
2q56RFIqCvY4nffswbmGjhCKOh1QTDqJuNDp9LOsZd/s5/ktGHty23LozceoWZ8E
j+BF03Xr8WDt9J+ojpeJlY/TuzvJ483cKGFidPECgYEAjxhSw5YNrkBXx1K2xI30
qbaLhxGcgyeewWZ44nw0WpeGxlrc8JTGb6EjcoCGKB2HC7MhzHOFkQE/CByomi9m
6JSfrMk4QBh0XAd6i3C0oa50RmmIqfA4in4ocqYPSFV6Y5LaVmqtTwChwlHmknBe
aNGbW61PH6/+FJgDIrfgf5I=
-----END PRIVATE KEY-----''';

// ignore: avoid_print
void printOnError(Object e) => print('SOCKSGET FAILED: $e');

void main() {
  late HttpServer web;
  late ServerSocket socks;
  final seen = <String>[];

  setUp(() async {
    seen.clear();
    web = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    web.listen((request) async {
      final path = request.uri.path;
      final res = request.response;
      switch (path) {
        case '/hello':
          final body = utf8.encode('hello ${request.uri.query}');
          res.headers.contentLength = body.length;
          res.add(body);
        case '/chunked':
          res.headers.chunkedTransferEncoding = true;
          for (var i = 0; i < 5; i++) {
            res.write('part$i;');
            await res.flush();
          }
        case '/big':
          final body = Uint8List.fromList(List.generate(1500000, (i) => i % 251));
          res.headers.contentLength = body.length;
          res.add(body);
        case '/to-hello':
          res.statusCode = HttpStatus.found;
          res.headers.set('location', '/hello?after-redirect');
        case '/missing':
          res.statusCode = HttpStatus.notFound;
        default:
          res.statusCode = HttpStatus.internalServerError;
      }
      await res.close();
    });
    socks = await _fakeSocks({'lists.test:80': web.port}, seen: seen);
  });

  tearDown(() async {
    await web.close(force: true);
    await socks.close();
  });

  test('a page is fetched through the proxy, and the proxy is asked for the name, not an address', () async {
    final body = await socksGet('http://lists.test/hello?x=1', socks.port, onError: (e) => printOnError(e));
    expect(utf8.decode(body!), 'hello x=1');
    expect(seen, ['lists.test:80']);
  });

  test('a chunked answer is put together', () async {
    expect(utf8.decode((await socksGet('http://lists.test/chunked', socks.port))!), 'part0;part1;part2;part3;part4;');
  });

  test('a big body arrives whole, and one over the limit is refused', () async {
    final body = await socksGet('http://lists.test/big', socks.port);
    expect(body!.length, 1500000);
    expect(body[250], 250);
    expect(body[251], 0);
    expect(await socksGet('http://lists.test/big', socks.port, maxBytes: 1000000), isNull);
  });

  test('a redirect is followed; a missing page, a refused name and a dead proxy give null', () async {
    expect(utf8.decode((await socksGet('http://lists.test/to-hello', socks.port))!), 'hello after-redirect');
    expect(await socksGet('http://lists.test/missing', socks.port), isNull);
    expect(await socksGet('http://other.test/hello', socks.port), isNull);
    expect(await socksGet('ftp://lists.test/hello', socks.port), isNull);
    final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = dead.port;
    await dead.close();
    expect(await socksGet('http://lists.test/hello', port, timeout: const Duration(seconds: 3)), isNull);
  });

  test('a proxy with a login: the right one is accepted, a wrong one is not', () async {
    final locked = await _fakeSocks({'lists.test:80': web.port}, auth: (user: 'kabc', pass: 's3cret'));
    addTearDown(locked.close);
    expect(utf8.decode((await socksGet('http://lists.test/hello', locked.port, auth: (user: 'kabc', pass: 's3cret')))!), 'hello ');
    expect(await socksGet('http://lists.test/hello', locked.port, auth: (user: 'kabc', pass: 'nope')), isNull);
    expect(await socksGet('http://lists.test/hello', locked.port), isNull);
  });

  test('a page that never answers is given up after the time', () async {
    final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    silent.listen((_) {});
    addTearDown(silent.close);
    final sw = Stopwatch()..start();
    expect(await socksGet('http://lists.test/hello', silent.port, timeout: const Duration(milliseconds: 600)), isNull);
    expect(sw.elapsed, lessThan(const Duration(seconds: 4)));
  });

  test('HTTPS goes through the proxy too (the handshake is made over the proxy connection)', () async {
    final context = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(_certificate))
      ..usePrivateKeyBytes(utf8.encode(_privateKey));
    final secure = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);
    addTearDown(() => secure.close(force: true));
    secure.listen((request) async {
      final body = utf8.encode('secure ${request.uri.path}');
      request.response.headers.contentLength = body.length;
      request.response.add(body);
      await request.response.close();
    });
    final proxy = await _fakeSocks({'localhost:443': secure.port}, seen: seen);
    addTearDown(proxy.close);
    final body = await socksGet('https://localhost/a', proxy.port, onBadCertificate: (_) => true);
    expect(utf8.decode(body!), 'secure /a');
    expect(seen, contains('localhost:443'));
    // A certificate nobody trusts is refused when nothing says it is fine.
    expect(await socksGet('https://localhost/a', proxy.port), isNull);
  });
}
