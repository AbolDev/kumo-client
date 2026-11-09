import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'ad_lists.dart';
import 'singbox_config.dart' show XrayAuth;
import 'socks_get.dart';

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

/// How a list is fetched: [url]'s body, or null. Where it goes (the network's own way, the local proxy
/// of a connection, Xray's SOCKS port) is the caller's choice, see [fetchDirect], [fetchViaProxy] and
/// [fetchViaSocks].
typedef ListFetch = Future<Uint8List?> Function(String url);

/// The way the app's traffic goes by itself: out the network, or into the tunnel when the app is
/// inside it.
Future<Uint8List?> fetchDirect(String url) => _get(url);

/// Through the HTTP proxy on 127.0.0.1:[port] (the local proxy of a connection in the proxy mode).
ListFetch fetchViaProxy(int port) => (url) => _get(url, proxyPort: port);

/// Through the SOCKS5 proxy on 127.0.0.1:[port] (what Xray opens: the app is outside the tunnel then).
ListFetch fetchViaSocks(int port, {XrayAuth? auth}) => (url) => socksGet(url, port, auth: auth);

/// Downloads the first address that answers. With [convert] the body is turned into the file to keep
/// (null: the body is not what it should be, so the next address is tried).
Future<bool> _download(List<String> urls, File target,
        {Future<String?> Function(Uint8List)? convert, ListFetch fetch = fetchDirect}) =>
    _inFlight.putIfAbsent(
        target.path,
        () => _downloadOnce(urls, target, convert: convert, fetch: fetch)
            .whenComplete(() => _inFlight.remove(target.path)));

/// [url]'s body, or null.
Future<Uint8List?> _get(String url, {int? proxyPort}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  if (proxyPort != null) client.findProxy = (_) => 'PROXY 127.0.0.1:$proxyPort';
  try {
    final req = await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 10));
    final res = await req.close().timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;
    // Bytes, not a list of ints (eight times the memory for a list of a few megabytes).
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in res.timeout(const Duration(seconds: 20))) {
      bytes.add(chunk);
      if (bytes.length > _maxDownload) throw const HttpException('too large');
    }
    return bytes.length < 16 ? null : bytes.takeBytes();
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

Future<bool> _downloadOnce(List<String> urls, File target,
    {Future<String?> Function(Uint8List)? convert, ListFetch fetch = fetchDirect}) async {
  for (final url in urls) {
    try {
      final bytes = await fetch(url);
      if (bytes == null) continue;
      await target.parent.create(recursive: true);
      final tmp = File('${target.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
      if (convert != null) {
        final text = await convert(bytes);
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

/// A block list (its bytes) as a rule-set and the number of its domains; null when it holds fewer than
/// [min]. Runs on another isolate: reading hundreds of thousands of names takes seconds, and the screen
/// must not stop meanwhile.
({String text, int count})? _listToRuleSet(Uint8List bytes, int min) {
  final p = parseBlocklist(utf8.decode(bytes, allowMalformed: true));
  final domains = p.block..removeAll(p.allow);
  dropNeverBlocked(domains);
  pruneCovered(domains);
  if (domains.length < min) return null;
  return (text: ruleSetOf(domains), count: domains.length);
}

// The jobs given to another isolate. Each is made in a function of its own, so that the closure sent
// over holds only its arguments (a closure carries the variables around it, and some cannot be sent).
Future<({String text, int count})?> _listToRuleSetOff(Uint8List bytes, int min) =>
    Isolate.run(() => _listToRuleSet(bytes, min));
Future<bool> _rawListOkOff(Uint8List bytes, int min) => Isolate.run(() => _rawListOk(bytes, min));
Future<int> _mergeIntoOff(List<String> paths, String out) => Isolate.run(() => _mergeInto(paths, out));

/// How a downloaded text list becomes the rule-set kept, with the count kept for the status.
Future<String?> Function(Uint8List) _textToRuleSet(File target, {int min = 1000}) => (bytes) async {
      final r = await _listToRuleSetOff(bytes, min);
      if (r == null) return null;
      await _writeCount(target, r.count);
      return r.text;
    };

/// Whether a downloaded list of the max level names at least [min] domains (on another isolate).
bool _rawListOk(Uint8List bytes, int min) => parseBlocklist(utf8.decode(bytes, allowMalformed: true)).block.length >= min;

/// The text lists at [paths] merged into the rule-set [out] (written whole, then moved into place);
/// the number of its domains, or 0 when there were too few to write. Runs on another isolate.
///
/// The files are read line by line into one set, what the lists allow and what apps need is taken out,
/// and so is every name that has a parent in the set; the rule-set is written in pieces. So the most
/// that is held at once is the set of names (about a million at the max level), not that and the
/// texts of all the lists and the finished rule-set on top of it.
Future<int> _mergeInto(List<String> paths, String out) async {
  final block = <String>{}, allow = <String>{};
  for (final p in paths) {
    await addBlocklistFile(p, block, allow);
  }
  block.removeAll(allow);
  allow.clear();
  dropNeverBlocked(block);
  pruneCovered(block);
  if (block.length < 1000) return 0;
  final file = File(out);
  await file.parent.create(recursive: true);
  final tmp = File('$out.${DateTime.now().microsecondsSinceEpoch}.tmp');
  final sink = tmp.openWrite();
  try {
    sink.write('{"version":3,"rules":[{"domain_suffix":["');
    final piece = StringBuffer();
    var n = 0;
    for (final d in block) {
      if (n > 0) piece.write('","');
      piece.write(d);
      if (++n % 5000 == 0) {
        sink.write(piece.toString());
        piece.clear();
      }
    }
    sink.write(piece.toString());
    sink.write('"]}]}');
    await sink.flush();
  } finally {
    await sink.close();
  }
  await tmp.rename(out);
  return block.length;
}

/// The lists of the max level: each kept as text in rules/raw (fetched once a day, an old copy kept
/// when a fetch fails), and all of them merged into one rule-set, built again when one of them is
/// newer than it. True when the merged rule-set is there.
Future<bool> _ensureMaxList(String dir,
    {required bool wait, bool refresh = true, bool force = false, ListFetch fetch = fetchDirect}) async {
  final merged = File('$dir/rules/$adMaxTag.json');
  var newest = DateTime.fromMillisecondsSinceEpoch(0);
  final raws = <File>[];
  for (final s in maxTextSources) {
    final raw = File('$dir/rules/raw/${s.name}.txt');
    final exists = await raw.exists();
    final old = exists && (force || DateTime.now().difference(await raw.lastModified()) > adsMaxAge);
    if ((!exists && wait) || (old && refresh)) {
      await _inFlight.putIfAbsent(raw.path, () async {
        for (final url in s.urls) {
          final bytes = await fetch(url);
          if (bytes == null) continue;
          if (!await _rawListOkOff(bytes, s.min)) continue;
          await raw.parent.create(recursive: true);
          final tmp = File('${raw.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
          await tmp.writeAsBytes(bytes, flush: true);
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
    // A million names: merged on another isolate, and once at a time.
    await _inFlight.putIfAbsent(merged.path, () async {
      final n = await _mergeIntoOff([for (final r in raws) r.path], merged.path);
      if (n > 0) await _writeCount(merged, n);
      return n > 0;
    }).whenComplete(() => _inFlight.remove(merged.path));
  }
  return merged.exists();
}

/// The list built into the app ([loadBase]: a binary rule-set) copied to [dir]/rules, once, and
/// again when a new version of the app brings another one. True when it is there.
Future<bool> _ensureBaseList(String dir, Future<Uint8List?> Function() loadBase) async {
  final file = File('$dir/rules/$adBaseTag.srs');
  try {
    final bytes = await loadBase();
    if (bytes == null || !_isSrs(bytes)) return file.exists();
    if (await file.exists() && await file.length() == bytes.length) return true;
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
    await _writeCount(file, adBaseCount);
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
/// do. Missing files are downloaded; with [refresh], files older than a week (ad lists: a day) are
/// fetched again, but an old file is still used when that fails. With [wait] false nothing missing
/// is downloaded (except the lists a subscription's rules ask for, with [waitForTags]).
///
/// So that a connection never waits for a download, it calls this with neither [wait] nor
/// [refresh]: a list the app carries ([loadBundled]: the country lists) is copied in when there is
/// none yet, and the ad lists missing are stood in for by the list built into the app ([loadBase]).
/// The downloads are made once the connection is up, through it.
///
/// A list kept as JSON is given as its binary copy when [compileRuleSets] made one that is current.
Future<Map<String, String>> ensureRuleSets(String dir, List<String> countries,
    {bool wait = true,
    bool refresh = true,
    bool waitForTags = false,
    bool ads = false,
    String adsLevel = defaultAdLevel,
    List<String> tags = const [],
    Future<Uint8List?> Function()? loadBase,
    Future<Uint8List?> Function(String tag)? loadBundled,
    ListFetch fetch = fetchDirect,
    bool force = false,
    Duration limit = const Duration(seconds: 45)}) async {
  final found = <String, String>{};
  final jobs = <Future<void>>[];

  Future<void> fetch(String tag, List<String> urls,
      {bool text = false, Duration maxAge = _maxAge, bool waitHere = false}) async {
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
      if (!exists && !text && loadBundled != null) exists = await _seed(file, tag, loadBundled);
      final old = exists &&
          ((force && maxAge == adsMaxAge) ||
              DateTime.now().difference(await file.lastModified()) > maxAge ||
              // A list made by a version before 1.12.2-beta.4 (no count kept) is made again.
              (text && !await _countFile(file).exists()));
      if (!exists ? (wait || waitHere) : (old && refresh)) {
        await _download(urls, file, convert: text ? _textToRuleSet(file) : null, fetch: fetch);
      }
      if (await file.exists()) found[tag] = file.path.replaceAll('\\', '/');
    }

    jobs.add(one().catchError((_) {}));
  }

  final asked = tags.toSet();
  for (final e in _sourcesFor(countries, ads, tags).entries) {
    await fetch(e.key, e.value, waitHere: waitForTags && asked.contains(e.key));
  }
  if (ads) {
    for (final s in adSources(adsLevel)) {
      await fetch(s.tag, s.urls, text: s.text, maxAge: adsMaxAge);
    }
    if (adsLevel == 'max') {
      jobs.add(_ensureMaxList(dir, wait: wait, refresh: refresh, force: force, fetch: fetch).then((ok) {
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
      found[adBaseTag] = '$dir/rules/$adBaseTag.srs'.replaceAll('\\', '/');
    }
  }
  return {for (final e in found.entries) e.key: await _preferCompiled(e.value)};
}

/// Copies the list the app carries for [tag] to [file], dated long ago so that it is fetched again
/// (as an old file) the next time the lists are refreshed. True when there is one.
Future<bool> _seed(File file, String tag, Future<Uint8List?> Function(String tag) loadBundled) async {
  try {
    final bytes = await loadBundled(tag);
    if (bytes == null || !_isSrs(bytes)) return false;
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
    await file.setLastModified(DateTime(2020));
    return true;
  } catch (_) {
    return false;
  }
}

/// The binary copy of a JSON rule-set: `ads-x.json` -> `ads-x.bin.srs`.
File _compiledOf(File json) => File('${json.path.substring(0, json.path.length - 5)}.bin.srs');

/// [path], or its binary copy when that is there and not older than it.
Future<String> _preferCompiled(String path) async {
  if (!path.endsWith('.json')) return path;
  try {
    final json = File(path), bin = _compiledOf(json);
    if (await bin.exists() &&
        !(await bin.lastModified()).isBefore(await json.lastModified()) &&
        await _validFile(bin, text: false)) {
      return bin.path.replaceAll('\\', '/');
    }
  } catch (_) {}
  return path;
}

/// Makes a binary copy of every JSON rule-set in [dir]/rules that has none or an older one, one at a
/// time, with [compile] (the core's own compiler). sing-box reads the binary format several times
/// faster and with less memory: what a list of a million names costs at each start is paid once
/// here. Returns how many were made.
Future<int> compileRuleSets(String dir, Future<bool> Function(String source, String output) compile) async {
  var made = 0;
  final folder = Directory('$dir/rules');
  if (!await folder.exists()) return 0;
  final jsons = [
    await for (final f in folder.list())
      if (f is File && f.path.endsWith('.json')) f,
  ];
  for (final json in jsons) {
    final bin = _compiledOf(json);
    try {
      if (await bin.exists() && !(await bin.lastModified()).isBefore(await json.lastModified())) continue;
      final ok = await _inFlight
          .putIfAbsent(bin.path, () => compile(json.path, bin.path))
          .whenComplete(() => _inFlight.remove(bin.path));
      if (ok && await _validFile(bin, text: false)) {
        made++;
      } else if (await bin.exists()) {
        await bin.delete();
      }
    } catch (_) {}
  }
  return made;
}

/// Deletes the list files in [dir]/rules that the settings no longer use: the lists of countries
/// and of a subscription's rules that are not chosen any more, the ad lists of another level, what
/// older versions of the app left, and temporary files of downloads that never ended. With ad
/// blocking off the ad lists are kept (it is often turned off and on again). Only files this app
/// names are touched. Returns how many were deleted.
Future<int> cleanRuleSets(String dir, List<String> countries,
    {bool ads = false, String adsLevel = defaultAdLevel, List<String> tags = const []}) async {
  final folder = Directory('$dir/rules');
  if (!await folder.exists()) return 0;
  final keep = <String>{
    for (final tag in _sourcesFor(countries, ads, tags).keys) '$tag.srs',
    '$adBaseTag.srs',
    '$adBaseTag.srs.count',
  };
  void keepJson(String tag) => keep.addAll(['$tag.json', '$tag.json.count', '$tag.bin.srs']);
  if (ads) {
    for (final s in adSources(adsLevel)) {
      s.text ? keepJson(s.tag) : keep.add('${s.tag}.srs');
    }
    if (adsLevel == 'max') keepJson(adMaxTag);
  }
  final ours = RegExp(r'^(ads-|geoip-|geosite-)');
  final stale = DateTime.now().subtract(const Duration(hours: 1));
  var deleted = 0;
  Future<void> drop(FileSystemEntity f) async {
    try {
      await f.delete(recursive: true);
      deleted++;
    } catch (_) {}
  }

  await for (final f in folder.list()) {
    final name = f.uri.pathSegments.lastWhere((p) => p.isNotEmpty);
    if (f is Directory) {
      // The downloaded texts of the max level.
      if (name != 'raw') continue;
      if (ads && adsLevel != 'max') {
        await drop(f);
      } else if (ads) {
        final wanted = {for (final s in maxTextSources) '${s.name}.txt'};
        await for (final r in f.list()) {
          final n = r.uri.pathSegments.last;
          if (r is! File || wanted.contains(n)) continue;
          if (n.endsWith('.tmp') && (await r.lastModified()).isAfter(stale)) continue;
          await drop(r);
        }
      }
      continue;
    }
    if (f is! File || !ours.hasMatch(name) || keep.contains(name)) continue;
    // A download in progress writes a .tmp file: only old ones are leftovers.
    if (name.endsWith('.tmp') && (await f.lastModified()).isAfter(stale)) continue;
    if (!ads && name.startsWith(adTagPrefix)) continue;
    await drop(f);
  }
  return deleted;
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
  final base = File('$dir/rules/$adBaseTag.srs');
  final baseOnly = !await main.exists() && await base.exists();
  if (baseOnly) {
    try {
      domains += int.tryParse((await _countFile(base).readAsString()).trim()) ?? 0;
    } catch (_) {}
  }
  return AdsStatus(lists: lists, expected: expected.length, domains: domains, updated: updated, baseOnly: baseOnly);
}
