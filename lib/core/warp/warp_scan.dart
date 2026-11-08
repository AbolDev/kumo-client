import 'dart:math';

/// One way of reaching WARP that answered: its place in the list of ways ([index]) and the real delay.
class WarpScanItem {
  const WarpScanItem(this.index, this.ms);
  final int index;
  final int ms;
}

/// The most ways tried in one scan (the profile lists them best first, so the rest are the least
/// likely to be wanted); each test starts a throw-away core.
const warpScanLimit = 36;

/// Tries ways 0 until [count] ([parallel] at a time) with [test], which returns the real delay in ms
/// (negative when it did not answer), and gives back those that answered, the fastest first.
/// [onProgress] gets how many tests are done and how many there are; [cancelled] stops the scan.
Future<List<WarpScanItem>> scanWarp({
  required int count,
  required Future<int> Function(int index) test,
  int parallel = 3,
  void Function(int done, int total)? onProgress,
  bool Function()? cancelled,
}) async {
  final total = min(count, warpScanLimit);
  final found = <WarpScanItem>[];
  var next = 0, done = 0;
  Future<void> worker() async {
    while (true) {
      if (cancelled?.call() == true) return;
      final i = next++;
      if (i >= total) return;
      int ms;
      try {
        ms = await test(i);
      } catch (_) {
        ms = -1;
      }
      if (ms >= 0) found.add(WarpScanItem(i, ms));
      onProgress?.call(++done, total);
    }
  }

  await Future.wait([for (var i = 0; i < min(parallel, max(1, total)); i++) worker()]);
  found.sort((a, b) => a.ms != b.ms ? a.ms.compareTo(b.ms) : a.index.compareTo(b.index));
  return found;
}
