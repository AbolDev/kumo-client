import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/latency_tester.dart';

void main() {
  setUp(NetPace.reset);
  tearDown(NetPace.reset);

  group('time limits on a slow network', () {
    test('an ordinary network keeps the usual limits', () {
      expect(NetPace.factor, 1);
      for (final ms in [40, 60, 80, 120, 150, 200, 90]) {
        NetPace.note(ms);
      }
      expect(NetPace.factor, 1);
      expect(NetPace.scale(const Duration(seconds: 3)), const Duration(seconds: 3));
    });

    test('a few slow answers are not yet a slow network, and failures are not counted', () {
      for (final ms in [900, 1000, -1, -1, 1100]) {
        NetPace.note(ms);
      }
      expect(NetPace.factor, 1);
    });

    test('a slow network gets longer limits, three times at most', () {
      for (final ms in [700, 800, 800, 900, 850, 820]) {
        NetPace.note(ms);
      }
      expect(NetPace.factor, closeTo(2.05, 0.01));
      expect(NetPace.scale(const Duration(seconds: 3)).inMilliseconds, closeTo(6150, 20));
      for (var i = 0; i < 60; i++) {
        NetPace.note(2500);
      }
      expect(NetPace.factor, 3);
      expect(NetPace.scale(const Duration(seconds: 5)), const Duration(seconds: 15));
    });

    test('only the last answers count: a better network brings the usual limits back', () {
      for (var i = 0; i < 60; i++) {
        NetPace.note(2000);
      }
      expect(NetPace.factor, 3);
      for (var i = 0; i < 60; i++) {
        NetPace.note(80);
      }
      expect(NetPace.factor, 1);
    });

    test('the check of a running connection waits longer for a slow connection', () {
      expect(healthTimeout(null), const Duration(seconds: 5));
      expect(healthTimeout(-1), const Duration(seconds: 5));
      expect(healthTimeout(300), const Duration(seconds: 5));
      expect(healthTimeout(2500), const Duration(seconds: 10));
      expect(healthTimeout(9000), const Duration(seconds: 20));
      for (var i = 0; i < 10; i++) {
        NetPace.note(1200);
      }
      expect(healthTimeout(300), const Duration(seconds: 15));
    });
  });
}
