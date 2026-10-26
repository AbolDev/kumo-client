import 'sources.dart' show SubInfo;

/// The alerts a subscription's data and time call for. The levels match the Android side
/// (UsageAlerts.kt), which does the same for the background update job.
class UsageLevels {
  const UsageLevels(this.data, this.expiry);

  /// 0 fine, 1 low (10% or less left), 2 used up.
  final int data;

  /// 0 fine, 1 within three days, 2 today, 3 expired.
  final int expiry;

  /// Stored to know what was already said, e.g. "12".
  String get code => '$data$expiry';
}

UsageLevels usageLevels(SubInfo info, {DateTime? now}) {
  var data = 0;
  if (info.total > 0) {
    final left = info.total - info.used;
    data = left <= 0 ? 2 : (left * 10 <= info.total ? 1 : 0);
  }
  var expiry = 0;
  if (info.expire > 0) {
    final left = DateTime.fromMillisecondsSinceEpoch(info.expire * 1000)
        .difference(now ?? DateTime.now());
    expiry = left.isNegative || left == Duration.zero
        ? 3
        : (left < const Duration(days: 1) ? 2 : (left <= const Duration(days: 3) ? 1 : 0));
  }
  return UsageLevels(data, expiry);
}

/// Whole days left, at least 1 (for "expires in 3 days").
int daysLeft(SubInfo info, {DateTime? now}) {
  final left = DateTime.fromMillisecondsSinceEpoch(info.expire * 1000)
      .difference(now ?? DateTime.now());
  return (left.inHours / 24).ceil().clamp(1, 1 << 20);
}
