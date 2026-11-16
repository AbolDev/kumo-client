import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/updater.dart';

/// A list of releases as GitHub gives it, newest first.
final _releases = jsonEncode([
  {
    'tag_name': 'v1.12.3-beta.1',
    'prerelease': true,
    'html_url': 'https://github.com/AbolDev/kumo-client/releases/tag/v1.12.3-beta.1',
    'body': 'beta notes',
    'assets': [],
  },
  {
    'tag_name': 'v1.12.2',
    'prerelease': false,
    'html_url': 'https://github.com/AbolDev/kumo-client/releases/tag/v1.12.2',
    'body': 'stable notes',
    'assets': [
      {
        'name': 'kumo-android-universal.apk',
        'browser_download_url': 'https://example.com/a.apk',
        'size': 1234,
        'digest': 'sha256:ABCD',
      },
    ],
  },
  {'tag_name': 'v1.12.1', 'prerelease': false, 'body': 'older notes', 'assets': []},
  {'tag_name': 'v1.13.0', 'draft': true, 'body': 'not out yet', 'assets': []},
]);

void main() {
  test('the newest stable release is offered, with what was missed', () {
    final info = releaseInfo(_releases, '1.12.0', prerelease: false);
    expect(info.version, '1.12.2');
    expect(info.tag, 'v1.12.2');
    expect(info.newer, isTrue);
    expect(info.assets['kumo-android-universal.apk'], 'https://example.com/a.apk');
    expect(info.sizes['kumo-android-universal.apk'], 1234);
    expect(info.digests['kumo-android-universal.apk'], 'abcd');
    expect(info.history.map((h) => h.version), ['1.12.2', '1.12.1']);
  });

  test('an installed version that is current or newer is not offered anything', () {
    expect(releaseInfo(_releases, '1.12.2', prerelease: false).newer, isFalse);
    expect(releaseInfo(_releases, '1.12.3-beta.1', prerelease: false).newer, isFalse);
  });

  test('test versions only when asked for, and never a draft', () {
    final info = releaseInfo(_releases, '1.12.2', prerelease: true);
    expect(info.version, '1.12.3-beta.1');
    expect(info.newer, isTrue);
  });

  test('a list with no release is an error', () {
    expect(() => releaseInfo('[]', '1.0.0', prerelease: false), throwsFormatException);
  });
}
