import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/usage_stats.dart';

void main() {
  final now = DateTime(2026, 10, 27, 15);
  final usage = <String, List<int>>{
    '2026-10-27': [100, 50, 600],
    '2026-10-26': [1000, 200, 3600],
    '2026-10-20': [5000, 0, 60],
    '2026-08-01': [9000, 1000, 7200],
    '2026-10-25': [0, 0, 0],
  };

  test('summary adds up only the days of the period', () {
    final today = summarizeUsage(usage, 1, now);
    expect(today.total, 150);
    expect(today.seconds, 600);
    expect(today.activeDays, 1);

    final week = summarizeUsage(usage, 7, now);
    expect(week.down, 1100);
    expect(week.up, 250);
    expect(week.seconds, 4200);
    expect(week.activeDays, 2); // the empty day does not count, 10-20 is eight days back
    expect(week.busiestDay, '2026-10-26');
    expect(week.averagePerDay, 1350 ~/ 2);

    final all = summarizeUsage(usage, null, now);
    expect(all.total, 1350 + 5000 + 10000);
    expect(all.busiestDay, '2026-08-01');
  });

  test('an empty history gives zeros and an even share', () {
    final s = summarizeUsage({}, 7, now);
    expect(s.total, 0);
    expect(s.averagePerDay, 0);
    expect(s.busiestDay, isNull);
    expect(s.downShare, 0.5);
  });

  test('older saved days with two numbers still count', () {
    final s = summarizeUsage({'2026-10-27': [10, 5]}, 1, now);
    expect(s.total, 15);
    expect(s.seconds, 0);
  });

  test('daily bars cover every calendar day, empty ones included', () {
    final bars = dailyBars(usage, 7, now);
    expect(bars.length, 7);
    expect(bars.last.key, '2026-10-27');
    expect(bars.first.key, '2026-10-21');
    expect(bars.last.total, 150);
    expect(bars[4].key, '2026-10-25');
    expect(bars[4].total, 0);
  });

  test('bars across a month and a year boundary', () {
    final bars = dailyBars({'2025-12-31': [1, 1]}, 3, DateTime(2026, 1, 1));
    expect([for (final b in bars) b.key], ['2025-12-30', '2025-12-31', '2026-01-01']);
    expect(bars[1].total, 2);
  });

  test('sizes and durations are written short', () {
    expect(formatBytes(512), '512 B');
    expect(formatBytes(2048), '2 KB');
    expect(formatBytes(5 * (1 << 20)), '5.0 MB');
    expect(formatBytes(3 * (1 << 30)), '3.00 GB');
    expect(formatDuration(40), '40 s');
    expect(formatDuration(720), '12 m');
    expect(formatDuration(3 * 3600 + 5 * 60), '3 h 05 m');
    expect(formatDuration(90, m: 'دقیقه'), '1 دقیقه');
  });
}
