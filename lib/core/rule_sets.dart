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

/// The ad lists change every day.
const _adsMaxAge = Duration(days: 2);

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

/// Downloads the first address that answers. With [convert] the body is read as text and turned into
/// the file to keep (null: the body is not what it should be, so the next address is tried).
Future<bool> _download(List<String> urls, File target, {String? Function(String)? convert}) =>
    _inFlight.putIfAbsent(
        target.path,
        () => _downloadOnce(urls, target, convert: convert)
            .whenComplete(() => _inFlight.remove(target.path)));

Future<bool> _downloadOnce(List<String> urls, File target, {String? Function(String)? convert}) async {
  for (final url in urls) {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 10));
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) continue;
      final bytes = <int>[];
      await for (final chunk in res.timeout(const Duration(seconds: 20))) {
        bytes.addAll(chunk);
        if (bytes.length > _maxDownload) throw const HttpException('too large');
      }
      if (bytes.length < 16) continue;
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
    } finally {
      client.close(force: true);
    }
  }
  return false;
}

/// Makes sure the rule-set files exist in [dir]/rules and returns tag -> path for the ones that
/// do. Missing files are downloaded; files older than a week are refreshed, but an old file is
/// still used when the refresh fails. With [wait] false nothing is downloaded.
Future<Map<String, String>> ensureRuleSets(String dir, List<String> countries,
    {bool wait = true,
    bool ads = false,
    String adsLevel = defaultAdLevel,
    List<String> tags = const [],
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
      final old = exists && DateTime.now().difference(await file.lastModified()) > maxAge;
      if (!exists || old) {
        if (wait || exists) {
          await _download(urls, file, convert: text ? domainListToRuleSet : null);
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
      await fetch(s.tag, s.urls, text: s.text, maxAge: _adsMaxAge);
    }
  }
  // A big list on a slow link must not hold the connection back: what is not there in time is
  // left out now, and the download goes on in the background for the next connection.
  await Future.wait(jobs).timeout(limit, onTimeout: () => const []);
  return Map.of(found);
}
