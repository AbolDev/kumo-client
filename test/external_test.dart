import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/external_open.dart';
import 'package:kumo/core/sources.dart';

const _link = 'vless://11111111-1111-1111-1111-111111111111@example.com:443?security=tls#n';

void main() {
  group('headers and User-Agent of a subscription', () {
    test('lines become headers, and back', () {
      final h = parseHeaderLines('X-Api-Key: abc123\n\n  Authorization:Bearer t0k\nAccept-Language: fa');
      expect(h, {'X-Api-Key': 'abc123', 'Authorization': 'Bearer t0k', 'Accept-Language': 'fa'});
      expect(parseHeaderLines(headerLines(h)), h);
      expect(parseHeaderLines(''), isEmpty);
    });

    test('lines that cannot be a header are refused, naming the line', () {
      for (final bad in [
        'no colon here',
        ': value',
        'Bad Name: v',
        'Host: example.com',
        'content-length: 5',
        'Proxy-Authorization: x',
        'X-Empty:',
        'X-Long: ${'a' * 501}',
      ]) {
        expect(() => parseHeaderLines(bad), throwsFormatException, reason: bad);
      }
      expect(() => parseHeaderLines(List.generate(11, (i) => 'X-$i: v').join('\n')), throwsFormatException);
      try {
        parseHeaderLines('X-Ok: 1\nHost: x');
      } on FormatException catch (e) {
        expect(e.source, 'Host');
      }
    });

    test('the User-Agent is one line of at most 200 characters, or nothing', () {
      expect(cleanUserAgent('  clash.meta/1.18 '), 'clash.meta/1.18');
      expect(cleanUserAgent('a\r\nb'), 'a  b');
      expect(cleanUserAgent(''), isNull);
      expect(cleanUserAgent(null), isNull);
      expect(cleanUserAgent('x' * 300), hasLength(200));
    });

    test('saved headers that do not pass are dropped as a whole', () {
      expect(cleanSavedHeaders({'X-A': '1'}), {'X-A': '1'});
      expect(cleanSavedHeaders({'Host': 'x'}), isEmpty);
      expect(cleanSavedHeaders('x'), isEmpty);
      expect(cleanSavedHeaders(null), isEmpty);
    });

    test('a download uses the given User-Agent and headers, and only own-host gets the headers', () async {
      final seenA = <Map<String, String>>[];
      final seenB = <Map<String, String>>[];
      final b = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      b.listen((r) {
        seenB.add({for (final k in ['user-agent', 'x-api-key']) k: r.headers.value(k) ?? ''});
        r.response
          ..write(_link)
          ..close();
      });
      final a = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      a.listen((r) {
        seenA.add({for (final k in ['user-agent', 'x-api-key']) k: r.headers.value(k) ?? ''});
        // The same computer under another name: another host as far as the headers are concerned.
        r.response
          ..statusCode = 302
          ..headers.set('location', 'http://127.0.0.1:${b.port}/next')
          ..close();
      });
      try {
        final f = await fetchSubscription('http://localhost:${a.port}/sub',
            userAgent: 'MyClient/1.0', headers: {'X-Api-Key': 'secret'});
        expect(f.body, _link);
        expect(seenA.single, {'user-agent': 'MyClient/1.0', 'x-api-key': 'secret'});
        expect(seenB, hasLength(1));
        expect(seenB.single['user-agent'], 'MyClient/1.0');
        expect(seenB.single['x-api-key'], '', reason: 'the key must not go to another host');
        // Only the given User-Agent is tried (no other clients are asked).
        expect(seenA, hasLength(1));
      } finally {
        await a.close(force: true);
        await b.close(force: true);
      }
    });
  });

  group('what other programs open with Kumo', () {
    test('a subscription address, a server link, several links, and nothing', () {
      expect(summarizeExternal('https://panel.example.com/sub/abc?x=1'), (host: 'panel.example.com', servers: 0));
      expect(summarizeExternal('clash://install-config?url=https%3A%2F%2Fp.example.net%2Fs'), (host: 'p.example.net', servers: 0));
      expect(summarizeExternal(_link), (host: null, servers: 1));
      expect(summarizeExternal('$_link\n$_link'.replaceFirst('111111', '222222')), (host: null, servers: 2));
      expect(summarizeExternal('   '), isNull);
      expect(summarizeExternal('hello world, nothing to see'), isNull);
      // A page address inside other text is not taken for a subscription.
      expect(summarizeExternal('see https://example.com/page for details'), isNull);
    });

    test('the inbox hands things from a second copy to the running one, once', () async {
      final dir = await Directory.systemTemp.createTemp('kumo_external_');
      try {
        expect(await ExternalInbox.take(dir.path), isEmpty);
        await ExternalInbox.send(dir.path, [_link]);
        await ExternalInbox.send(dir.path, ['clash://install-config?url=https%3A%2F%2Fx.example.org']);
        expect(await ExternalInbox.take(dir.path), hasLength(2));
        expect(await ExternalInbox.take(dir.path), isEmpty);
        await ExternalInbox.send(dir.path, const []);
        expect(File('${dir.path}/${ExternalInbox.fileName}').existsSync(), isFalse);
        await File('${dir.path}/${ExternalInbox.fileName}').writeAsString('not json');
        expect(await ExternalInbox.take(dir.path), isEmpty);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('command line: links and the text of files; options and unknown words are skipped', () async {
      final dir = await Directory.systemTemp.createTemp('kumo_args_');
      try {
        final file = File('${dir.path}/servers.txt')..writeAsStringSync(_link);
        final big = File('${dir.path}/big.txt')..writeAsBytesSync(List.filled(ExternalInbox.maxBytes + 1, 65));
        final items = await ExternalInbox.fromArgs(['--minimized', _link, file.path, big.path, 'nothing', '${dir.path}/missing.txt', '']);
        expect(items, [_link, _link]);
        expect(utf8.encode(items.last), isNotEmpty);
        expect(await ExternalInbox.fromArgs(List.filled(50, _link)), hasLength(ExternalInbox.maxItems));
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
