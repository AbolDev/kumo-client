import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/collector_sources.dart';

void main() {
  test('lists are put together without a link twice, the first one first', () {
    expect(mergeLinks(['a', 'b'], ['b', 'c']), ['a', 'b', 'c']);
    expect(mergeLinks([], ['x']), ['x']);
    expect(mergeLinks(['x'], []), ['x']);
  });

  test('each extra list has mirrors of its own file', () {
    expect(kExtraLists.length, 3);
    for (final list in kExtraLists) {
      expect(list.length, greaterThan(1));
      expect(list.map((u) => u.split('/').last).toSet().length, 1);
    }
    expect(kRoosterSources.last, endsWith('roosterkid/openproxylist/refs/heads/main/V2RAY_RAW.txt'));
    expect(kShatakSources.last, endsWith('ShatakVPN/ConfigForge-V2Ray/refs/heads/main/configs/all.txt'));
    expect(kForc3RunSources.last, endsWith('F0rc3Run/F0rc3Run/refs/heads/main/Best-Results/proxies.txt'));
  });
}