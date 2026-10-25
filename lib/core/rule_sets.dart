import 'dart:async';
import 'dart:io';

/// Rule sets that list the addresses and sites of a country, as sing-box binary (.srs) files.
/// Each tag has several mirrors because GitHub itself is often unreachable from some countries.
/// Not every country has a site list; a missing one is simply skipped.
Map<String, List<String>> _sourcesFor(List<String> countries) => {
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

Future<bool> _download(List<String> urls, File target) async {
  for (final url in urls) {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 10));
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) continue;
      final bytes = <int>[];
      await for (final chunk in res.timeout(const Duration(seconds: 20))) {
        bytes.addAll(chunk);
      }
      if (bytes.length < 16) continue;
      await target.parent.create(recursive: true);
      await File('${target.path}.tmp').writeAsBytes(bytes, flush: true);
      await File('${target.path}.tmp').rename(target.path);
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
    {bool wait = true}) async {
  final found = <String, String>{};
  final jobs = <Future<void>>[];
  for (final e in _sourcesFor(countries).entries) {
    final file = File('$dir/rules/${e.key}.srs');
    Future<void> one() async {
      final exists = await file.exists();
      final old = exists &&
          DateTime.now().difference(await file.lastModified()) > _maxAge;
      if (!exists || old) {
        if (wait || exists) await _download(e.value, file);
      }
      if (await file.exists()) found[e.key] = file.path.replaceAll('\\', '/');
    }

    jobs.add(wait ? one() : one().catchError((_) {}));
  }
  await Future.wait(jobs);
  return found;
}
