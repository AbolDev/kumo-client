import 'dart:convert';
import 'dart:io';

import 'vpn_channel.dart';

/// The GitHub repository whose releases are checked for a newer version.
const updateRepo = 'AbolDev/kumo-client';

class UpdateInfo {
  const UpdateInfo(this.version, this.url, this.newer, this.assets,
      {this.notes = '', this.sizes = const {}, this.history = const []});

  /// The notes of every release newer than the installed one, newest first.
  final List<({String version, String notes})> history;

  /// The text of the release (Markdown) and the size in bytes of each attached file.
  final String notes;
  final Map<String, int> sizes;

  /// Latest stable release, without a leading "v".
  final String version;

  /// The release page.
  final String url;
  final bool newer;

  /// File name -> download link of the files attached to the release.
  final Map<String, String> assets;
}

List<int> _parts(String v) => [
      for (final p in v.split('+').first.split('-').first.split('.'))
        int.tryParse(p.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0
    ];

/// True when version [a] is newer than [b] (1.2.10 > 1.2.9).
bool isNewer(String a, String b) {
  final x = _parts(a), y = _parts(b);
  for (var i = 0; i < 3; i++) {
    final p = i < x.length ? x[i] : 0, q = i < y.length ? y[i] : 0;
    if (p != q) return p > q;
  }
  return false;
}

/// Whether test versions are offered too. Only set for a single check the user confirmed.
bool includePrerelease = false;

/// Asks GitHub for the latest stable release, or the newest release of any kind when
/// [includePrerelease] is on. Throws when it cannot be reached or there is none.
Future<UpdateInfo> checkForUpdate(String current) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client
        .getUrl(Uri.parse('https://api.github.com/repos/$updateRepo/releases?per_page=20'))
        .timeout(const Duration(seconds: 12));
    req.headers
      ..set('Accept', 'application/vnd.github+json')
      ..set('User-Agent', 'Kumo');
    final res = await req.close().timeout(const Duration(seconds: 12));
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
    final decoded = jsonDecode(body);
    Map<String, dynamic>? picked;
    final published = <Map<String, dynamic>>[];
    String nameOf(Map<String, dynamic> r) =>
        '${r['tag_name'] ?? ''}'.replaceFirst(RegExp(r'^[vV]'), '');
    if (decoded is List) {
      // The release with the highest version among the published ones; test versions only
      // when asked for.
      for (final r in decoded) {
        if (r is! Map<String, dynamic> || r['draft'] == true) continue;
        if (r['prerelease'] == true && !includePrerelease) continue;
        final tag = nameOf(r);
        if (tag.isEmpty) continue;
        published.add(r);
        if (picked == null || isNewer(tag, nameOf(picked))) picked = r;
      }
    }
    if (picked == null) throw const FormatException('no release');
    // Every release between this one and the newest, newest first, to show what was missed.
    final history = <({String version, String notes})>[
      for (final r in published)
        if (isNewer(nameOf(r), current)) (version: nameOf(r), notes: '${r['body'] ?? ''}'),
    ]..sort((a, b) => isNewer(a.version, b.version) ? -1 : 1);
    final j = picked;
    final tag = '${j['tag_name'] ?? ''}'.replaceFirst(RegExp(r'^[vV]'), '');
    if (tag.isEmpty) throw const FormatException('no version');
    final assets = <String, String>{
      for (final a in (j['assets'] as List? ?? const []))
        if (a is Map && a['name'] is String && a['browser_download_url'] is String)
          a['name'] as String: a['browser_download_url'] as String,
    };
    final sizes = <String, int>{
      for (final a in (j['assets'] as List? ?? const []))
        if (a is Map && a['name'] is String && a['size'] is int)
          a['name'] as String: a['size'] as int,
    };
    return UpdateInfo(
        tag,
        '${j['html_url'] ?? 'https://github.com/$updateRepo/releases'}',
        isNewer(tag, current),
        assets,
        notes: '${j['body'] ?? ''}',
        sizes: sizes,
        history: history);
  } finally {
    client.close(force: true);
  }
}

/// The file of [info] made for this device: its own CPU type first, then the universal one.
/// Null when the release has nothing that fits (the release page is opened instead).
Future<({String name, String url})?> pickAsset(UpdateInfo info) async {
  Iterable<String> wanted;
  if (Platform.isWindows) {
    final env = Platform.environment;
    final arm = '${env['PROCESSOR_ARCHITEW6432']}${env['PROCESSOR_ARCHITECTURE']}'
        .toUpperCase()
        .contains('ARM64');
    wanted = [if (arm) 'kumo-windows-arm64-setup.exe', 'kumo-windows-x64-setup.exe'];
  } else if (Platform.isLinux || Platform.isMacOS) {
    // The Linux and macOS builds are not installed by the app: the release page is opened.
    return null;
  } else {
    final abis = await VpnChannel.abis();
    wanted = [
      for (final abi in abis) 'kumo-android-$abi.apk',
      'kumo-android-universal.apk',
    ];
  }
  for (final name in wanted) {
    final url = info.assets[name];
    if (url != null) return (name: name, url: url);
  }
  return null;
}

/// Lets the user stop a running download.
class DownloadCancel {
  bool cancelled = false;
  HttpClient? _client;

  void cancel() {
    cancelled = true;
    _client?.close(force: true);
  }
}

/// Downloads [url] into the app's folder, reporting the bytes received and the total (-1 when
/// unknown). Returns the path. When [cancel] is used the partial file is removed and a
/// [HttpException] is thrown.
Future<String> downloadUpdate(String url, String name,
    void Function(int received, int total) progress,
    {DownloadCancel? cancel}) async {
  final dir = Directory('${await VpnChannel.dataDir()}${Platform.pathSeparator}updates');
  if (await dir.exists()) await dir.delete(recursive: true);
  await dir.create(recursive: true);
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  cancel?._client = client;
  try {
    if (cancel?.cancelled ?? false) throw const HttpException('cancelled');
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set('User-Agent', 'Kumo');
    final res = await req.close();
    if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
    final total = res.contentLength;
    var got = 0;
    final sink = file.openWrite();
    try {
      await for (final chunk in res) {
        sink.add(chunk);
        got += chunk.length;
        progress(got, total);
      }
    } finally {
      await sink.close();
    }
    if (cancel?.cancelled ?? false) throw const HttpException('cancelled');
    return file.path;
  } catch (_) {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
    rethrow;
  } finally {
    client.close(force: true);
  }
}