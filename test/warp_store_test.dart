import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/warp/warp_signature.dart';
import 'package:kumo/core/warp/warp_store.dart';

String _profile({int version = 1, int schema = 1, String expires = '2027-01-01T00:00:00Z', String keyId = 'k1'}) =>
    jsonEncode({
      'schema': schema,
      'version': version,
      'issued_at': '2026-10-01T00:00:00Z',
      'expires_at': expires,
      'key_id': keyId,
      'register': {
        'fragment': {'size': [5, 40], 'delay_ms': [10, 10]},
        'api_ips': ['104.16.192.82'],
      },
      'endpoints': [
        {'ip': '162.159.192.1', 'ports': [2408]},
      ],
      'methods': [
        {'id': 'plain', 'kind': 'wg-plain', 'rank': 1},
      ],
    });

void main() {
  final (priv, pub) = newWarpKeyPair();
  final (otherPriv, _) = newWarpKeyPair();
  final now = DateTime.utc(2026, 11, 1);

  late Map<String, String> disk;
  late Map<String, String> web;
  late Map<String, String> assets;

  WarpProfileStore store() => WarpProfileStore(
        read: (n) async => disk[n],
        write: (n, c) async => disk[n] = c,
        loadAsset: (p) async => assets[p] ?? (throw StateError('no asset')),
        fetch: (u) async => web[u] ?? (throw StateError('unreachable')),
        now: () => now,
        keys: {'k1': pub},
      );

  void publish(String url, String text, {String? key}) {
    web[url] = text;
    web['$url.sig'] = signWarp(utf8.encode(text), key ?? priv);
  }

  setUp(() {
    disk = {};
    web = {};
    final text = _profile(version: 5);
    assets = {bundledWarpProfile: text, '$bundledWarpProfile.sig': signWarp(utf8.encode(text), priv)};
  });

  test('the bundled profile is used when nothing was saved', () async {
    final s = store();
    await s.load();
    expect((s.profile!.version, s.source), (5, 'bundled'));
  });

  test('a newer download is saved and then preferred at the next start', () async {
    final s = store();
    publish(warpProfileUrls[0], _profile(version: 6));
    expect(await s.update(), WarpUpdateResult.updated);
    expect(s.profile!.version, 6);
    final again = store();
    await again.load();
    expect((again.profile!.version, again.source), (6, 'saved'));
  });

  test('the same or an older version is not taken', () async {
    final s = store();
    publish(warpProfileUrls[0], _profile(version: 5));
    expect(await s.update(), WarpUpdateResult.current);
    publish(warpProfileUrls[0], _profile(version: 2));
    expect(await s.update(), WarpUpdateResult.current);
    expect(disk, isEmpty);
  });

  test('a file signed with another key, or changed after signing, is not taken', () async {
    final s = store();
    publish(warpProfileUrls[0], _profile(version: 9), key: otherPriv);
    expect(await s.update(), WarpUpdateResult.failed);
    final text = _profile(version: 9);
    web[warpProfileUrls[0]] = text.replaceFirst('"version":9', '"version":10');
    web['${warpProfileUrls[0]}.sig'] = signWarp(utf8.encode(text), priv);
    expect(await s.update(), WarpUpdateResult.failed);
    expect(s.profile!.version, 5);
    expect(disk, isEmpty);
  });

  test('a key id the app does not know is refused', () async {
    final s = store();
    publish(warpProfileUrls[0], _profile(version: 9, keyId: 'k9'));
    expect(await s.update(), WarpUpdateResult.failed);
  });

  test('a file that has run out is not taken', () async {
    final s = store();
    publish(warpProfileUrls[0], _profile(version: 9, expires: '2026-10-15T00:00:00Z'));
    expect(await s.update(), WarpUpdateResult.failed);
  });

  test('a layout from a newer app is reported, and what is saved stays', () async {
    final s = store();
    publish(warpProfileUrls[0], _profile(version: 9, schema: 2));
    expect(await s.update(), WarpUpdateResult.needsNewerApp);
    expect(s.profile!.version, 5);
  });

  test('the mirror is tried when the first source cannot be reached', () async {
    final s = store();
    publish(warpProfileUrls[1], _profile(version: 7));
    expect(await s.update(), WarpUpdateResult.updated);
    expect(s.profile!.version, 7);
  });

  test('nothing reachable is a failure, and the profile in use stays', () async {
    final s = store();
    expect(await s.update(), WarpUpdateResult.failed);
    expect(s.profile!.version, 5);
  });

  test('a damaged saved file falls back to the bundled one', () async {
    disk['warp_profile.json'] = '{"broken"';
    disk['warp_profile.json.sig'] = 'AAAA';
    final s = store();
    await s.load();
    expect((s.profile!.version, s.source), (5, 'bundled'));
  });
}
