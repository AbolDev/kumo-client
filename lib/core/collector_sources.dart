import 'sources.dart';

/// A second public list, taken together with the first one ([kMirrorSources]): V2RAY_RAW.txt of
/// roosterkid/openproxylist, a few hundred configs that are renewed often. Each address is a mirror
/// of the same file, tried in turn.
const kExtraSources = <String>[
  'https://cdn.jsdelivr.net/gh/roosterkid/openproxylist@main/V2RAY_RAW.txt',
  'https://gcore.jsdelivr.net/gh/roosterkid/openproxylist@main/V2RAY_RAW.txt',
  'https://fastly.jsdelivr.net/gh/roosterkid/openproxylist@main/V2RAY_RAW.txt',
  'https://raw.githubusercontent.com/roosterkid/openproxylist/refs/heads/main/V2RAY_RAW.txt',
];

/// The two lists put together, without a link twice. The second one comes after the first.
List<String> mergeLinks(List<String> first, List<String> second) => {...first, ...second}.toList();

/// Downloads the public lists. Both are asked at the same time; the answer is what the ones that
/// worked have, so a list that is down never stops the other. It fails only when none worked.
Future<FetchResult> fetchCollectorLists() async {
  Future<FetchResult?> one(List<String> sources, List<String> errors) async {
    try {
      return await fetchFromSources(sources: sources);
    } on AllSourcesFailed catch (e) {
      errors.addAll(e.errors);
    } catch (e) {
      errors.add('$e');
    }
    return null;
  }

  final errors = <String>[];
  final results = await Future.wait([
    one([...kOwnSources, ...kMirrorSources], errors),
    one(kExtraSources, errors),
  ]);
  final main = results[0], extra = results[1];
  if (main == null && extra == null) throw AllSourcesFailed(errors);
  if (main == null) return extra!;
  if (extra == null) return main;
  return FetchResult(mergeLinks(main.links, extra.links), main.source);
}
