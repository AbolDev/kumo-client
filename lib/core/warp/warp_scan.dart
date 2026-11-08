import 'dart:math';

import 'warp_profile.dart' show parseCidrV4;

/// The most addresses the wider scan tries.
const warpWideCount = 24;

/// [count] different addresses drawn from [ranges] ("a.b.c.d/n"), taking turns between the ranges so
/// that each one is looked at; the network and broadcast addresses of a range are left out. Ranges
/// that do not read are skipped.
List<String> pickScanAddresses(List<String> ranges, int count, Random random) {
  final parsed = [for (final r in ranges) parseCidrV4(r)].whereType<({int base, int bits})>().toList();
  if (parsed.isEmpty || count <= 0) return const [];
  final out = <String>{};
  var guard = 0;
  while (out.length < count && guard++ < count * 40) {
    final r = parsed[out.length % parsed.length];
    final size = 1 << (32 - r.bits);
    final mask = (0xFFFFFFFF << (32 - r.bits)) & 0xFFFFFFFF;
    final base = r.base & mask;
    // A range of one or two addresses has no "network" or "broadcast" to leave out.
    final low = size > 2 ? 1 : 0, high = size > 2 ? size - 2 : size - 1;
    final n = base + low + random.nextInt(high - low + 1);
    out.add('${(n >> 24) & 255}.${(n >> 16) & 255}.${(n >> 8) & 255}.${n & 255}');
  }
  return out.toList();
}

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
