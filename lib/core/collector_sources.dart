import 'sources.dart';

/// More public lists, taken together with the first one ([kMirrorSources]). Each is a list of
/// mirrors of the same file, tried in turn.
///
/// roosterkid/openproxylist: V2RAY_RAW.txt, a few hundred configs that are renewed often.
const kRoosterSources = <String>[
  'https://cdn.jsdelivr.net/gh/roosterkid/openproxylist@main/V2RAY_RAW.txt',
  'https://gcore.jsdelivr.net/gh/roosterkid/openproxylist@main/V2RAY_RAW.txt',
  'https://fastly.jsdelivr.net/gh/roosterkid/openproxylist@main/V2RAY_RAW.txt',
  'https://raw.githubusercontent.com/roosterkid/openproxylist/refs/heads/main/V2RAY_RAW.txt',
];

/// ShatakVPN/ConfigForge-V2Ray: configs/all.txt, checked configs of many protocols, renewed often.
const kShatakSources = <String>[
  'https://cdn.jsdelivr.net/gh/ShatakVPN/ConfigForge-V2Ray@main/configs/all.txt',
  'https://gcore.jsdelivr.net/gh/ShatakVPN/ConfigForge-V2Ray@main/configs/all.txt',
  'https://fastly.jsdelivr.net/gh/ShatakVPN/ConfigForge-V2Ray@main/configs/all.txt',
  'https://raw.githubusercontent.com/ShatakVPN/ConfigForge-V2Ray/refs/heads/main/configs/all.txt',
];

const kExtraLists = <List<String>>[kRoosterSources, kShatakSources];

/// The lists put together, without a link twice. Earlier lists come first.
List<String> mergeLinks(List<String> first, List<String> second) => {...first, ...second}.toList();

/// Downloads the public lists. All are asked at the same time; the answer is what the ones that
/// worked have, so a list that is down never stops the others. It fails only when none worked.
Future<FetchResult> fetchCollectorLists() async {
  final errors = <String>[];
  Future<FetchResult?> one(List<String> sources) async {
    try {
      return await fetchFromSources(sources: sources);
    } on AllSourcesFailed catch (e) {
      errors.addAll(e.errors);
    } catch (e) {
      errors.add('$e');
    }
    return null;
  }

  final results = await Future.wait([
    one([...kOwnSources, ...kMirrorSources]),
    for (final list in kExtraLists) one(list),
  ]);
  final worked = results.whereType<FetchResult>().toList();
  if (worked.isEmpty) throw AllSourcesFailed(errors);
  var links = <String>[];
  for (final r in worked) {
    links = mergeLinks(links, r.links);
  }
  // The first list that worked names the source.
  return FetchResult(links, worked.first.source);
}