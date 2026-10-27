/// Sums of the saved daily usage ("2026-10-25" -> [down, up, seconds connected]) over a period.
class UsageSummary {
  const UsageSummary({
    required this.down,
    required this.up,
    required this.seconds,
    required this.activeDays,
    required this.busiestDay,
    required this.busiestBytes,
  });

  final int down, up, seconds, activeDays;

  /// The day with the most data ("2026-10-25"), null when there is none.
  final String? busiestDay;
  final int busiestBytes;

  int get total => down + up;

  /// Bytes per day that had any traffic.
  int get averagePerDay => activeDays == 0 ? 0 : total ~/ activeDays;

  /// The share of the data that was downloaded, 0..1.
  double get downShare => total == 0 ? 0.5 : down / total;
}

/// One bar of the daily chart.
class DayBar {
  const DayBar(this.key, this.date, this.down, this.up);
  final String key;
  final DateTime date;
  final int down, up;
  int get total => down + up;
}

String dayKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// The days from the first one in [days] (counting back from [now]) up to today; [days] null
/// means every saved day.
UsageSummary summarizeUsage(Map<String, List<int>> usage, int? days, DateTime now) {
  final from = days == null
      ? ''
      : dayKey(DateTime(now.year, now.month, now.day).subtract(Duration(days: days - 1)));
  var down = 0, up = 0, secs = 0, active = 0, best = 0;
  String? bestDay;
  usage.forEach((k, v) {
    if (k.compareTo(from) < 0) return;
    final t = v[0] + v[1];
    down += v[0];
    up += v[1];
    secs += v.length > 2 ? v[2] : 0;
    if (t > 0) active++;
    if (t > best) {
      best = t;
      bestDay = k;
    }
  });
  return UsageSummary(
      down: down,
      up: up,
      seconds: secs,
      activeDays: active,
      busiestDay: bestDay,
      busiestBytes: best);
}

/// The last [count] calendar days ending today, days without traffic included as empty bars.
List<DayBar> dailyBars(Map<String, List<int>> usage, int count, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  return [
    for (var i = count - 1; i >= 0; i--)
      () {
        // Calendar arithmetic (not 24-hour steps) so a clock change cannot repeat or skip a day.
        final d = DateTime(today.year, today.month, today.day - i);
        final v = usage[dayKey(d)];
        return DayBar(dayKey(d), d, v?[0] ?? 0, v?[1] ?? 0);
      }(),
  ];
}

/// "1.2 GB", "340 MB", "12 KB".
String formatBytes(int b) {
  if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
  if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
  if (b >= 1 << 10) return '${b ~/ 1024} KB';
  return '$b B';
}

/// "3 h 05 m", "12 m", "40 s".
String formatDuration(int seconds, {String h = 'h', String m = 'm', String s = 's'}) {
  if (seconds >= 3600) {
    return '${seconds ~/ 3600} $h ${((seconds % 3600) ~/ 60).toString().padLeft(2, '0')} $m';
  }
  if (seconds >= 60) return '${seconds ~/ 60} $m';
  return '$seconds $s';
}
