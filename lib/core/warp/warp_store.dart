import 'dart:convert';

import 'warp_keys.dart';
import 'warp_profile.dart';
import 'warp_signature.dart';

/// Where the profile is downloaded from, one after the other: the repository itself, then a mirror
/// that serves the same files (GitHub is not reachable from every network).
const warpProfileUrls = [
  'https://raw.githubusercontent.com/AbolDev/kumo-client/main/docs/warp/profile.json',
  'https://cdn.jsdelivr.net/gh/AbolDev/kumo-client@main/docs/warp/profile.json',
];

/// The profile files kept in the app's data folder, and the copy that is part of the app.
const _savedProfile = 'warp_profile.json';
const _savedSignature = 'warp_profile.json.sig';
const bundledWarpProfile = 'docs/warp/profile.json';

enum WarpUpdateResult {
  /// A newer profile was downloaded, checked and saved.
  updated,

  /// What the app has is the newest the sources offered.
  current,

  /// Nothing usable came from any source (offline, blocked, or the files did not check).
  failed,

  /// The newest file is for a newer version of the app.
  needsNewerApp,
}

/// Holds the profile the app uses: the newest of the copy bundled with the app and the one
/// downloaded last, and only when its signature fits one of the keys in [warpPublicKeys]. A file
/// that does not check, is older than the one in use, or has run out is never taken.
class WarpProfileStore {
  WarpProfileStore({
    required this.read,
    required this.write,
    required this.loadAsset,
    required this.fetch,
    DateTime Function()? now,
    this.keys = warpPublicKeys,
  }) : _now = now ?? DateTime.now;

  /// The public keys a profile may be signed with, by key id.
  final Map<String, String> keys;

  final Future<String?> Function(String name) read;
  final Future<void> Function(String name, String content) write;
  final Future<String> Function(String path) loadAsset;

  /// The text at [url]; throws when it cannot be had.
  final Future<String> Function(String url) fetch;
  final DateTime Function() _now;

  WarpProfile? profile;

  /// Where [profile] came from: "bundled" or "saved".
  String source = '';

  /// What a profile text is, when it is signed by a known key and valid. Throws otherwise.
  WarpProfile check(String text, String signature) {
    final Object? raw;
    try {
      raw = jsonDecode(text);
    } catch (_) {
      throw WarpFormatException('not JSON');
    }
    final keyId = raw is Map ? raw['key_id'] : null;
    final key = keyId is String ? keys[keyId] : null;
    if (key == null) throw WarpFormatException('signed with a key this version does not know');
    if (!verifyWarpSignature(utf8.encode(text), signature, key)) {
      throw WarpFormatException('the signature does not fit');
    }
    return parseWarpProfile(text);
  }

  Future<WarpProfile?> _try(Future<(String, String)> Function() get) async {
    try {
      final (text, sig) = await get();
      return check(text, sig);
    } catch (_) {
      return null;
    }
  }

  /// Chooses the newest of the bundled and the saved profile.
  Future<void> load() async {
    final bundled = await _try(() async =>
        (await loadAsset(bundledWarpProfile), await loadAsset('$bundledWarpProfile.sig')));
    final saved = await _try(() async {
      final text = await read(_savedProfile), sig = await read(_savedSignature);
      if (text == null || sig == null) throw WarpFormatException('nothing saved');
      return (text, sig);
    });
    if (saved != null && (bundled == null || saved.version > bundled.version)) {
      profile = saved;
      source = 'saved';
    } else {
      profile = bundled;
      source = bundled == null ? '' : 'bundled';
    }
  }

  /// Downloads the profile and takes it when it is newer than the one in use.
  Future<WarpUpdateResult> update() async {
    if (profile == null) await load();
    var newerApp = false;
    var reached = false;
    for (final url in warpProfileUrls) {
      try {
        final text = await fetch(url);
        final sig = await fetch('$url.sig');
        final WarpProfile fresh;
        try {
          fresh = check(text, sig.trim());
        } on WarpSchemaTooNew {
          newerApp = true;
          continue;
        }
        // A mirror may hold an older copy, or a file that has run out: not taken.
        if (!fresh.expiresAt.isAfter(_now().toUtc())) continue;
        reached = true;
        final current = profile;
        if (current != null && fresh.version <= current.version) return WarpUpdateResult.current;
        await write(_savedProfile, text);
        await write(_savedSignature, sig.trim());
        profile = fresh;
        source = 'saved';
        return WarpUpdateResult.updated;
      } catch (_) {
        // the next source
      }
    }
    if (newerApp) return WarpUpdateResult.needsNewerApp;
    return reached ? WarpUpdateResult.current : WarpUpdateResult.failed;
  }
}
