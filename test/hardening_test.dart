import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/backup.dart';
import 'package:kumo/core/desktop_vpn.dart';
import 'package:kumo/core/proxy_watchdog.dart';
import 'package:kumo/core/rule_sets.dart';
import 'package:kumo/core/single_instance.dart';
import 'package:kumo/core/sources.dart' show isPublicUrl;
import 'package:kumo/core/system_proxy.dart' show pointsAtPort;
import 'package:kumo/core/updater.dart';
import 'package:pointycastle/export.dart';

void main() {
  group('system proxy', () {
    test('a port is matched whole: 1080 is not 10800', () {
      expect(pointsAtPort('127.0.0.1:1080', 1080), isTrue);
      expect(pointsAtPort('localhost:1080', 1080), isTrue);
      expect(pointsAtPort('http=127.0.0.1:1080;https=127.0.0.1:1080', 1080), isTrue);
      expect(pointsAtPort('127.0.0.1:10800', 1080), isFalse);
      expect(pointsAtPort('127.0.0.1:108', 1080), isFalse);
      expect(pointsAtPort('192.168.1.5:1080', 1080), isFalse);
      expect(pointsAtPort('my127.0.0.1:1080', 1080), isFalse);
      expect(pointsAtPort(null, 1080), isFalse);
    });

    test('the helper that outlives the app knows the app, the port and the registry', () {
      final script = windowsWatchdogScript(4242, 2080);
      expect(script, contains('Wait-Process -Id 4242'));
      expect(script, contains(r'127\.0\.0\.1'));
      expect(script, contains(':2080(;|\$)'));
      expect(script, contains('Internet Settings'));
      // PowerShell reads -EncodedCommand as UTF-16LE in base64.
      final bytes = base64.decode(encodePowerShell('Wait'));
      expect(bytes, [0x57, 0, 0x61, 0, 0x69, 0, 0x74, 0]);
      expect(linuxWatchdogScript, contains('gsettings set org.gnome.system.proxy mode none'));
      expect(macWatchdogScript, contains('networksetup'));
    });
  });

  group('addresses a provider may send', () {
    test('only places on the internet', () {
      expect(isPublicUrl('https://sub.example.com/list'), isTrue);
      expect(isPublicUrl('http://8.8.8.8/x'), isTrue);
      expect(isPublicUrl('http://localhost:9090/'), isFalse);
      expect(isPublicUrl('http://127.0.0.1/'), isFalse);
      expect(isPublicUrl('http://10.0.0.1/'), isFalse);
      expect(isPublicUrl('http://192.168.1.1/'), isFalse);
      expect(isPublicUrl('http://172.20.0.1/'), isFalse);
      expect(isPublicUrl('http://172.32.0.1/'), isTrue);
      expect(isPublicUrl('http://169.254.169.254/'), isFalse);
      expect(isPublicUrl('http://[::1]/'), isFalse);
      expect(isPublicUrl('http://[fd00::1]/'), isFalse);
      expect(isPublicUrl('http://printer.local/'), isFalse);
      expect(isPublicUrl('not a url'), isFalse);
    });
  });

  group('rule sets', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('kumo-rules'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('a file that is not a rule set is dropped, a real one is kept', () async {
      final rules = Directory('${dir.path}/rules')..createSync();
      File('${rules.path}/geoip-ir.srs').writeAsBytesSync([0x53, 0x52, 0x53, 1, 0, 0, 0, 0, 0, 0]);
      File('${rules.path}/geosite-ir.srs')
          .writeAsStringSync('<html>sign in to the hotel wifi</html>' * 3);
      final found = await ensureRuleSets(dir.path, ['ir'], wait: false);
      expect(found.keys, contains('geoip-ir'));
      expect(found.keys, isNot(contains('geosite-ir')));
      expect(File('${rules.path}/geosite-ir.srs').existsSync(), isFalse);
    });
  });

  group('updates', () {
    test('a test version is older than the release of the same number', () {
      expect(isNewer('1.9.0', '1.9.0-beta'), isTrue);
      expect(isNewer('1.9.0-beta', '1.9.0'), isFalse);
      expect(isNewer('1.9.0', '1.9.0'), isFalse);
      expect(isNewer('1.10.0', '1.9.9'), isTrue);
      expect(isNewer('1.8.1+3', '1.8.0+9'), isTrue);
    });

    test('the checksum is the SHA-256 of the file', () async {
      final dir = Directory.systemTemp.createTempSync('kumo-sha');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File('${dir.path}/abc')..writeAsStringSync('abc');
      expect(await fileSha256(f.path),
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    });

    group('download', () {
      late Directory dir;
      late HttpServer server;
      final body = Uint8List.fromList(List.generate(5000, (i) => i % 251));
      late String sha;

      setUp(() async {
        dir = Directory.systemTemp.createTempSync('kumo-upd');
        DesktopVpn.dataDirOverride = dir.path;
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((r) {
          r.response.add(body);
          r.response.close();
        });
        final d = SHA256Digest();
        final out = Uint8List(d.digestSize);
        d
          ..update(body, 0, body.length)
          ..doFinal(out, 0);
        sha = [for (final b in out) b.toRadixString(16).padLeft(2, '0')].join();
      });
      tearDown(() async {
        DesktopVpn.dataDirOverride = null;
        await server.close(force: true);
        dir.deleteSync(recursive: true);
      });

      String url() => 'http://127.0.0.1:${server.port}/f';

      test('the file that matches is kept', () async {
        final path = await downloadUpdate(url(), 'f.bin', (_, __) {}, size: body.length, sha256: sha);
        expect(File(path).readAsBytesSync(), body);
      });

      test('a wrong checksum or size removes the file and fails', () async {
        await expectLater(
            downloadUpdate(url(), 'f.bin', (_, __) {}, sha256: '0' * 64), throwsA(isA<HttpException>()));
        await expectLater(
            downloadUpdate(url(), 'f.bin', (_, __) {}, size: body.length + 1), throwsA(isA<HttpException>()));
        expect(File('${dir.path}/updates/f.bin').existsSync(), isFalse);
      });
    });
  });

  group('backup', () {
    test('a new backup says how many rounds its key took, and opens', () async {
      final text = await sealBackup('{"a":1}', 'pw');
      expect((jsonDecode(text) as Map)['iter'], greaterThanOrEqualTo(150000));
      expect(await openBackup(text, 'pw'), '{"a":1}');
      expect(await openBackup(text, 'wrong'), isNull);
    });

    test('a backup from before the count was written still opens', () async {
      final salt = Uint8List.fromList(List.generate(16, (i) => i));
      final nonce = Uint8List.fromList(List.generate(12, (i) => 100 + i));
      final text = await Isolate.run(() {
        final key = (PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
              ..init(Pbkdf2Parameters(salt, 60000, 32)))
            .process(Uint8List.fromList(utf8.encode('old')));
        final cipher = GCMBlockCipher(AESEngine())
          ..init(true, AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));
        final sealed = cipher.process(Uint8List.fromList(utf8.encode('{"legacy":true}')));
        return jsonEncode({
          'kumo-backup': 1,
          'salt': base64.encode(salt),
          'nonce': base64.encode(nonce),
          'data': base64.encode(sealed),
        });
      });
      expect(await openBackup(text, 'old'), '{"legacy":true}');
    });

    test('a crafted iteration count cannot stall the app', () async {
      final text = jsonEncode({
        'kumo-backup': 1,
        'iter': 2000000000,
        'salt': base64.encode(Uint8List(16)),
        'nonce': base64.encode(Uint8List(12)),
        'data': base64.encode(Uint8List(32)),
      });
      final clock = Stopwatch()..start();
      expect(await openBackup(text, 'x'), isNull);
      expect(clock.elapsed, lessThan(const Duration(seconds: 60)));
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  test('only one copy runs', () async {
    final first = await SingleInstance.acquire(Directory.systemTemp.path);
    expect(first, isTrue);
    expect(SingleInstance.held, isTrue);
    if (Platform.isWindows) {
      // The same process asking again finds the lock taken.
      expect(await SingleInstance.acquire(Directory.systemTemp.path), isFalse);
    }
  });
}
