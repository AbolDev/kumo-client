import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/socks_get.dart';
import 'package:kumo/core/speed_test.dart';

void main() {
  group('the meter of a rate', () {
    test('nothing that came is no speed', () {
      expect(RateMeter().mbps(), -1);
    });

    test('without a warm-up all of it counts', () async {
      final m = RateMeter()..add(1000000);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      m.add(1000000);
      // 16 Mbit in a bit over 0.1 s: far above 10 Mbit/s, and a number.
      expect(m.mbps(), greaterThan(10));
    });

    test('the warm-up is left out: a fast start and a slow rest give the slow rate', () async {
      final m = RateMeter(warmup: const Duration(milliseconds: 150))..add(2000000);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      m.add(10); // the warm-up is over here
      await Future<void>.delayed(const Duration(milliseconds: 300));
      m.add(10);
      expect(m.mbps(), lessThan(0.1));
    });

    test('when too little is left after the warm-up, all of it counts', () {
      final m = RateMeter(warmup: const Duration(hours: 1))..add(1000000);
      expect(m.mbps(), greaterThan(1));
    });
  });

  group('the live number', () {
    test('the speed of the last second, with the time since the start', () async {
      final got = <double>[];
      final live = LiveRate((v, e) => got.add(v), every: const Duration(hours: 1), span: const Duration(seconds: 1));
      live.start();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      live.add(250000); // 2 Mbit in about 0.2 s
      live.tick();
      expect(got.single, greaterThan(2));
      expect(got.single, lessThan(20));
      expect(live.total, 250000);
      live.stop();
    });

    test('nothing that came is zero, not an error', () async {
      final got = <double>[];
      final live = LiveRate((v, e) => got.add(v), every: const Duration(hours: 1))..start();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      live.tick();
      expect(got.single, 0);
      live.stop();
    });
  });

  group('the servers', () {
    test('the first is Cloudflare and every other has a download and a page for the delay', () {
      expect(speedServers.first.id, 'cloudflare');
      expect(speedServers.map((s) => s.id).toSet().length, speedServers.length);
      for (final s in speedServers) {
        expect(Uri.parse(s.download(1000000)).host, s.host);
        expect(Uri.parse(s.pingUrl).host, s.host);
        if (s.uploadUrl != null) expect(Uri.parse(s.uploadUrl!).host, s.host);
      }
      expect(speedServerById('nothing').id, 'cloudflare');
      expect(speedServerById('ovh').canUpload, isFalse);
      expect(speedServerById('cloudflare').canUpload, isTrue);
    });

    test('a server that takes the size in MB takes 4 at least', () {
      expect(speedServerById('librespeed-fra').download(500000), contains('ckSize=4'));
    });

    test('the size is put in the address', () {
      expect(speedServerById('cloudflare').download(5000000), 'https://speed.cloudflare.com/__down?bytes=5000000');
      expect(speedServerById('librespeed-fra').download(100000000), contains('ckSize=100'));
    });
  });

  group('the history', () {
    SpeedResult at(int i) => SpeedResult(
        at: DateTime.fromMillisecondsSinceEpoch(1700000000000 + i), serverId: 'cloudflare', viaVpn: i.isEven, via: i.isEven ? 'srv$i' : null,
        pingMs: i, jitterMs: 1, downMbps: i + 0.5, upMbps: i * 2.0);

    test('it keeps the newest first and at most as many as asked', () {
      var list = <SpeedResult>[];
      for (var i = 0; i < 40; i++) {
        list = addToHistory(list, at(i), keep: 30);
      }
      expect(list.length, 30);
      expect(list.first.pingMs, 39);
      expect(list.last.pingMs, 10);
    });

    test('the choice of the most data is kept in the file, and a wrong one is the default', () {
      expect(decodeCapMb(encodeHistory([], capMb: 250)), 250);
      expect(decodeCapMb(encodeHistory([], capMb: 7)), speedDefaultMb);
      expect(decodeCapMb(encodeHistory([])), speedDefaultMb);
      expect(decodeCapMb('{ nope'), speedDefaultMb);
      expect(decodeCapMb(null), speedDefaultMb);
      expect(speedMbChoices, contains(speedDefaultMb));
    });

    test('it survives a save, and a damaged or empty file gives nothing', () {
      final back = decodeHistory(encodeHistory([at(2), at(3)]));
      expect(back.length, 2);
      expect(back.first.via, 'srv2');
      expect(back.first.viaVpn, isTrue);
      expect(back.last.via, isNull);
      expect(back.first.downMbps, 2.5);
      expect(back.first.at, at(2).at);
      expect(decodeHistory('{ nope'), isEmpty);
      expect(decodeHistory(null), isEmpty);
      expect(decodeHistory('{"tests": [1, {"at": 1, "server": "x"}, "y"]}').length, 1);
    });
  });

  group('against a server of its own', () {
    late HttpServer server;
    var uploaded = 0;

    setUp(() async {
      uploaded = 0;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        try {
          if (req.method == 'POST') {
            await for (final c in req) {
              uploaded += c.length;
            }
            req.response.statusCode = 200;
          } else if (req.uri.path == '/down') {
            req.response.add(Uint8List(2000000));
          }
          await req.response.close();
        } catch (_) {}
      });
    });

    tearDown(() => server.close(force: true));

    String url(String path) => 'http://127.0.0.1:${server.port}$path';

    test('a download and an upload are measured', () async {
      final down = await httpSpeed(url('/down'), upload: false, window: const Duration(seconds: 3));
      expect(down, greaterThan(0));
      final up = await httpSpeed(url('/up'), upload: true, bytes: 1000000);
      expect(up, greaterThan(0));
      expect(uploaded, 1000000);
    });

    test('a download stops when it has what it was allowed', () async {
      var sent = 0;
      final big = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => big.close(force: true));
      big.listen((req) async {
        try {
          final chunk = Uint8List(65536);
          for (var i = 0; i < 1000; i++) {
            req.response.add(chunk);
            sent += chunk.length;
            await req.response.flush();
            // Not faster than a reader that stops can stop: on a loopback everything would be out at once.
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          await req.response.close();
        } catch (_) {}
      });
      final v = await httpSpeed('http://127.0.0.1:${big.port}/', upload: false, maxBytes: 1000000, window: const Duration(seconds: 5));
      expect(v, greaterThan(0));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      // 1000 chunks are 65 MB: far less than that went out once the reader had had enough.
      expect(sent, lessThan(30000000));
    });

    test('an address that does not answer, or is not a web address, is -1', () async {
      expect(await httpSpeed('ftp://x/y', upload: false), -1);
      expect(await httpSpeed('http://127.0.0.1:1/', upload: false, timeout: const Duration(seconds: 5)), -1);
    });

    test('a whole test gives the delay, the download and the upload, and tells its stages', () async {
      final fake = SpeedServer('fake', 'Fake', '127.0.0.1', url('/down'), url('/ping'), uploadUrl: url('/up'));
      final stages = <SpeedStage>[];
      final partials = <SpeedResult>[];
      final r = await runSpeedTest(fake, const SpeedRoute(),
          pings: 3,
          streams: 2,
          window: const Duration(seconds: 2),
          warmup: Duration.zero,
          onStage: stages.add,
          onResult: partials.add);
      expect(stages, [SpeedStage.ping, SpeedStage.download, SpeedStage.upload]);
      expect(r.pingMs, isNotNull);
      expect(r.jitterMs, isNotNull);
      expect(r.downMbps, greaterThan(0));
      expect(r.upMbps, greaterThan(0));
      expect(r.viaVpn, isFalse);
      expect(partials.length, 3);
      expect(uploaded, greaterThan(0));
    });

    test('a whole test keeps to the most data asked for', () async {
      final fake = SpeedServer('fake', 'Fake', '127.0.0.1', url('/down'), url('/ping'), uploadUrl: url('/up'));
      final r = await runSpeedTest(fake, const SpeedRoute(),
          pings: 1, streams: 2, maxMb: 1, window: const Duration(seconds: 2), warmup: Duration.zero);
      expect(r.downMbps, isNotNull);
      expect(r.upMbps, isNotNull);
      // The try of 300 kB and what the two connections may send of 1 MB: not more than that and a little.
      expect(uploaded, lessThanOrEqualTo(1400000));
    });

    test('a server without an upload is not asked for one', () async {
      final fake = SpeedServer('fake', 'Fake', '127.0.0.1', url('/down'), url('/ping'));
      final r = await runSpeedTest(fake, const SpeedRoute(),
          pings: 1, streams: 1, window: const Duration(seconds: 2), warmup: Duration.zero);
      expect(r.downMbps, isNotNull);
      expect(r.upMbps, isNull);
      expect(uploaded, 0);
    });

    test('stopping returns what was measured so far', () async {
      final fake = SpeedServer('fake', 'Fake', '127.0.0.1', url('/down'), url('/ping'), uploadUrl: url('/up'));
      var asked = 0;
      final r = await runSpeedTest(fake, const SpeedRoute(),
          pings: 2, streams: 1, window: const Duration(seconds: 2), cancelled: () => ++asked > 3);
      expect(r.pingMs, isNotNull);
      expect(r.upMbps, isNull);
    });

    test('nothing reachable gives nothing', () async {
      final dead = SpeedServer('dead', 'Dead', '127.0.0.1', 'http://127.0.0.1:1/d', 'http://127.0.0.1:1/p', uploadUrl: 'http://127.0.0.1:1/u');
      final r = await runSpeedTest(dead, const SpeedRoute(),
          pings: 1, streams: 1, window: const Duration(seconds: 1));
      expect(r.pingMs, isNull);
      expect(r.downMbps, isNull);
      expect(r.upMbps, isNull);
    });
  });
}
