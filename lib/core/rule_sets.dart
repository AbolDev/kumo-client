import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ad_lists.dart';

/// Rule sets that list the addresses and sites of a country, as sing-box binary (.srs) files.
/// Each tag has several mirrors because GitHub itself is often unreachable from some countries.
/// Not every country has a site list; a missing one is simply skipped.
Map<String, List<String>> _sourcesFor(List<String> countries, bool ads, List<String> tags) => {
      // lists a subscription's routing rules ask for: geosite-xxx and geoip-xxx
      for (final tag in tags)
        if (RegExp(r'^(geosite|geoip)-[a-z0-9_.!-]+$').hasMatch(tag))
          tag: [
            'https://cdn.jsdelivr.net/gh/SagerNet/sing-${tag.split('-').first}@rule-set/$tag.srs',
            'https://raw.githubusercontent.com/SagerNet/sing-${tag.split('-').first}/rule-set/$tag.srs',
          ],
      for (final c in countries) ...{
        'geoip-$c': [
          'https://cdn.jsdelivr.net/gh/SagerNet/sing-geoip@rule-set/geoip-$c.srs',
          'https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-$c.srs',
        ],
        'geosite-$c': [
          'https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-category-$c.srs',
          'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-$c.srs',
        ],
      },
      if (countries.contains('ir')) 'geosite-ir-extra': [
        'https://cdn.jsdelivr.net/gh/Chocolate4U/Iran-sing-box-rules@rule-set/geosite-ir.srs',
        'https://raw.githubusercontent.com/Chocolate4U/Iran-sing-box-rules/rule-set/geosite-ir.srs',
      ],
    };

const _maxAge = Duration(days: 7);

/// The ad lists change every day, and so are they fetched.
const adsMaxAge = Duration(days: 1);

/// The most a rule-set download may hold; the biggest list is a few megabytes.
const _maxDownload = 64 * 1024 * 1024;

/// Downloads running now, by target file: two asks for the same file (the tunnel and the standby
/// proxy start together) share one download instead of writing to the same file at once.
final _inFlight = <String, Future<bool>>{};

/// sing-box binary rule sets start with the bytes "SRS". A portal's web page or a cut-off download
/// does not, and sing-box would refuse to start with such a file.
bool _isSrs(List<int> head) =>
    head.length >= 4 && head[0] == 0x53 && head[1] == 0x52 && head[2] == 0x53;

Future<bool> _validFile(File file, {required bool text}) async {
  try {
    final f = await file.open();
    try {
      final head = await f.read(4);
      return text ? head.isNotEmpty && head[0] == 0x7B : _isSrs(head); // "{" for a source list
    } finally {
      await f.close();
    }
  } catch (_) {
    return false;
  }
}

/// The number of domains a list built from text has, kept next to it for the status in Settings.
File _countFile(File list) => File('${list.path}.count');

Future<void> _writeCount(File list, int n) async {
  try {
    await _countFile(list).writeAsString('$n', flush: true);
  } catch (_) {}
}

/// Downloads the first address that answers. With [convert] the body is read as text and turned into
/// the file to keep (null: the body is not what it should be, so the next address is tried).
Future<bool> _download(List<String> urls, File target, {String? Function(String)? convert}) =>
    _inFlight.putIfAbsent(
        target.path,
        () => _downloadOnce(urls, target, convert: convert)
            .whenComplete(() => _inFlight.remove(target.path)));

/// [url]'s body, or null.
Future<List<int>?> _get(String url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 10));
    final res = await req.close().timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;
    final bytes = <int>[];
    await for (final chunk in res.timeout(const Duration(seconds: 20))) {
      bytes.addAll(chunk);
      if (bytes.length > _maxDownload) throw const HttpException('too large');
    }
    return bytes.length < 16 ? null : bytes;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

Future<bool> _downloadOnce(List<String> urls, File target, {String? Function(String)? convert}) async {
  for (final url in urls) {
    try {
      final bytes = await _get(url);
      if (bytes == null) continue;
      await target.parent.create(recursive: true);
      final tmp = File('${target.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
      if (convert != null) {
        final text = convert(utf8.decode(bytes, allowMalformed: true));
        if (text == null) continue;
        await tmp.writeAsString(text, flush: true);
      } else {
        if (!_isSrs(bytes)) continue;
        await tmp.writeAsBytes(bytes, flush: true);
      }
      await tmp.rename(target.path);
      return true;
    } catch (_) {
      // try the next mirror
    }
  }
  return false;
}

/// How [domainListToRuleSet] is used for a download, with the count kept for the status.
String? Function(String) _textToRuleSet(File target, {int min = 1000}) => (text) {
      final p = parseBlocklist(text);
      final domains = withoutNeverBlocked(p.block.difference(p.allow));
      if (domains.length < min) return null;
      _writeCount(target, domains.length);
      return ruleSetOf(domains);
    };

/// The lists of the max level: each kept as text in rules/raw (fetched once a day, an old copy kept
/// when a fetch fails), and all of them merged into one rule-set, built again when one of them is
/// newer than it. True when the merged rule-set is there.
Future<bool> _ensureMaxList(String dir, {required bool wait, bool force = false}) async {
  final merged = File('$dir/rules/$adMaxTag.json');
  var newest = DateTime.fromMillisecondsSinceEpoch(0);
  final raws = <File>[];
  for (final s in maxTextSources) {
    final raw = File('$dir/rules/raw/${s.name}.txt');
    final exists = await raw.exists();
    final old = exists && (force || DateTime.now().difference(await raw.lastModified()) > adsMaxAge);
    if ((!exists && wait) || old) {
      await _inFlight.putIfAbsent(raw.path, () async {
        for (final url in s.urls) {
          final bytes = await _get(url);
          if (bytes == null) continue;
          final text = utf8.decode(bytes, allowMalformed: true);
          if (parseBlocklist(text).block.length < s.min) continue;
          await raw.parent.create(recursive: true);
          final tmp = File('${raw.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
          await tmp.writeAsString(text, flush: true);
          await tmp.rename(raw.path);
          return true;
        }
        return false;
      }).whenComplete(() => _inFlight.remove(raw.path));
    }
    if (await raw.exists()) {
      final m = await raw.lastModified();
      if (m.isAfter(newest)) newest = m;
      raws.add(raw);
    }
  }
  if (raws.isEmpty) return merged.exists();
  final current = await merged.exists() && !(await merged.lastModified()).isBefore(newest);
  if (!current) {
    final domains = mergeBlocklists([for (final r in raws) await r.readAsString()]);
    if (domains.length >= 1000) {
      await merged.parent.create(recursive: true);
      final tmp = File('${merged.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
      await tmp.writeAsString(ruleSetOf(domains), flush: true);
      await tmp.rename(merged.path);
      await _writeCount(merged, domains.length);
    }
  }
  return merged.exists();
}

/// The list built into the app as a rule-set in [dir]/rules, made from [loadBase] once (and again
/// when the built-in list changed with a new version of the app). True when it is there.
Future<bool> _ensureBaseList(String dir, Future<String> Function() loadBase) async {
  final file = File('$dir/rules/$adBaseTag.json');
  final stamp = File('${file.path}.source');
  try {
    final text = await loadBase();
    final sign = '${text.length}:${text.hashCode}';
    if (await file.exists() && await stamp.exists() && await stamp.readAsString() == sign) return true;
    final p = parseBlocklist(text);
    final domains = withoutNeverBlocked(p.block.difference(p.allow));
    if (domains.isEmpty) return file.exists();
    await file.parent.create(recursive: true);
    await file.writeAsString(ruleSetOf(domains), flush: true);
    await stamp.writeAsString(sign, flush: true);
    await _writeCount(file, domains.length);
    return true;
  } catch (_) {
    return file.exists();
  }
}

/// The tag of the main domain list of [level] (the one the built-in list stands in for).
String mainAdTag(String level) => level == 'max'
    ? adMaxTag
    : '${adTagPrefix}hagezi-${level == 'strong' ? 'pro' : 'light'}';

/// Makes sure the rule-set files exist in [dir]/rules and returns tag -> path for the ones that
/// do. Missing files are downloaded; files older than a week (ad lists: a day) are refreshed, but an
/// old file is still used when the refresh fails. With [wait] false nothing is downloaded. When the
/// main ad list of the level is not there, the list built into the app ([loadBase]) is used.
Future<Map<String, String>> ensureRuleSets(String dir, List<String> countries,
    {bool wait = true,
    bool ads = false,
    String adsLevel = defaultAdLevel,
    List<String> tags = const [],
    Future<String> Function()? loadBase,
    bool force = false,
    Duration limit = const Duration(seconds: 45)}) async {
  final found = <String, String>{};
  final jobs = <Future<void>>[];

  Future<void> fetch(String tag, List<String> urls, {bool text = false, Duration maxAge = _maxAge}) async {
    final file = File('$dir/rules/$tag.${text ? 'json' : 'srs'}');
    Future<void> one() async {
      var exists = await file.exists();
      // A file from before the checks, or a damaged one, is replaced rather than trusted.
      if (exists && !await _validFile(file, text: text)) {
        try {
          await file.delete();
        } catch (_) {}
        exists = false;
      }
      final old = exists &&
          ((force && maxAge == adsMaxAge) ||
              DateTime.now().difference(await file.lastModified()) > maxAge ||
              // A list made by a version before 1.12.2-beta.4 (no count kept) is made again.
              (text && !await _countFile(file).exists()));
      if (!exists || old) {
        if (wait || exists) {
          await _download(urls, file, convert: text ? _textToRuleSet(file) : null);
        }
      }
      if (await file.exists()) found[tag] = file.path.replaceAll('\\', '/');
    }

    jobs.add(one().catchError((_) {}));
  }

  for (final e in _sourcesFor(countries, ads, tags).entries) {
    await fetch(e.key, e.value);
  }
  if (ads) {
    for (final s in adSources(adsLevel)) {
      await fetch(s.tag, s.urls, text: s.text, maxAge: adsMaxAge);
    }
    if (adsLevel == 'max') {
      jobs.add(_ensureMaxList(dir, wait: wait, force: force).then((ok) {
        if (ok) found[adMaxTag] = '$dir/rules/$adMaxTag.json'.replaceAll('\\', '/');
      }).catchError((_) {}));
    }
  }
  // A big list on a slow link must not hold the connection back: what is not there in time is
  // left out now, and the download goes on in the background for the next connection.
  await Future.wait(jobs).timeout(limit, onTimeout: () => const []);
  // Without the main list (no download yet, or none possible), the one built into the app stands in.
  if (ads && loadBase != null && !found.containsKey(mainAdTag(adsLevel))) {
    if (await _ensureBaseList(dir, loadBase)) {
      found[adBaseTag] = '$dir/rules/$adBaseTag.json'.replaceAll('\\', '/');
    }
  }
  return Map.of(found);
}

/// What Settings shows about the ad lists.
class AdsStatus {
  AdsStatus({required this.lists, required this.expected, required this.domains, required this.updated, required this.baseOnly});

  /// How many of the lists of the level are there, of how many.
  final int lists, expected;

  /// How many domains the domain lists hold (the rule-set files of other lists are not counted).
  final int domains;

  /// When the newest list was fetched; null when none was.
  final DateTime? updated;

  /// True when the main list could not be had and only the built-in one stands in.
  final bool baseOnly;
}

/// The state of the ad lists of [level] in [dir]/rules.
Future<AdsStatus> adsStatus(String dir, String level) async {
  final expected = [
    for (final s in adSources(level)) File('$dir/rules/${s.tag}.${s.text ? 'json' : 'srs'}'),
    if (level == 'max') File('$dir/rules/$adMaxTag.json'),
  ];
  var lists = 0, domains = 0;
  DateTime? updated;
  for (final f in expected) {
    if (!await f.exists()) continue;
    lists++;
    final m = await f.lastModified();
    if (updated == null || m.isAfter(updated)) updated = m;
    try {
      domains += int.tryParse((await _countFile(f).readAsString()).trim()) ?? 0;
    } catch (_) {}
  }
  final main = File('$dir/rules/${mainAdTag(level)}.json');
  final base = File('$dir/rules/$adBaseTag.json');
  final baseOnly = !await main.exists() && await base.exists();
  if (baseOnly) {
    try {
      domains += int.tryParse((await _countFile(base).readAsString()).trim()) ?? 0;
    } catch (_) {}
  }
  return AdsStatus(lists: lists, expected: expected.length, domains: domains, updated: updated, baseOnly: baseOnly);
}
