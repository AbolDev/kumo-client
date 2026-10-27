import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/collector_sources.dart';

void main() {
  test('two lists are put together without a link twice, the first one first', () {
    expect(mergeLinks(['a', 'b'], ['b', 'c']), ['a', 'b', 'c']);
    expect(mergeLinks([], ['x']), ['x']);
    expect(mergeLinks(['x'], []), ['x']);
  });

  test('the second list has mirrors of its own file', () {
    expect(kExtraSources.length, greaterThan(1));
    expect(kExtraSources.every((u) => u.endsWith('V2RAY_RAW.txt')), isTrue);
  });
}