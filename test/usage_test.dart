import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/usage/usage_build.dart';
import 'package:kumo/core/usage/usage_endpoints.dart';
import 'package:kumo/core/usage/usage_ping.dart';
import 'package:kumo/core/usage/usage_reporter.dart';
import 'package:kumo/core/warp/warp_signature.dart';

typedef Call = ({String host, PingMethod method, Map<String, Object> body});

class Rig {
  Rig({this.tunnel = false, this.sysId = 'machine-guid-1', this.version = '1.12.0-beta.11'}) {
    reporter = UsageReporter(
      read: (n) async => files[n],
      write: (n, c) async => files[n] = c,
      send: (e, b, m) async {
        calls.add((host: e.host, method: m, body: b));
        return answer(e, m);
      },
      systemId: () async => sysId,
      os: 'windows',
      osVersion: () async => '"Windows 10 Pro" 10.0 (Build 26100)',
      appVersion: () async => version,
      tunnelUp: () => tunnel,
      endpoints: () => const [UsageEndpoint('a.example.com'), UsageEndpoint('b.example.com')],
      countryHint: () => 'IR',
      facts: () async => facts,
      now: () => clock,
    );
  }

  DeviceFacts facts = const DeviceFacts();

  final files = <String, String>{};
  final calls = <Call>[];
  late final UsageReporter reporter;
  bool tunnel;
  String? sysId;
  String version;
  DateTime clock = DateTime.utc(2026, 11, 7, 10);
  int? Function(UsageEndpoint, PingMethod) answer = (_, __) => 200;
}

void main() {
  group('the ping body', () {
    final id = hashDeviceId('abc');

    test('the id is a salted SHA-256: 64 lower-case hex characters, not the raw id', () {
      expect(id, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(id, isNot(contains('abc')));
      expect(hashDeviceId(' ABC '), id);
      expect(hashDeviceId('abd'), isNot(id));
    });

    test('a valid body fits the limits of the server', () {
      final b = buildPing(
          event: 'ping', id: id, os: 'android', appVersion: '1.12.0', osVersion: '14 (API 34)');
      expect(b, {
        'v': 1,
        'event': 'ping',
        'id': id,
        'os': 'android',
        'os_version': '14 (API 34)',
        'app_version': '1.12.0',
        'via_tunnel': false,
      });
      expect(utf8.encode(jsonEncode(b)).length, lessThanOrEqualTo(pingMaxBytes));
    });

    test('what the server would refuse is never built', () {
      expect(() => buildPing(event: 'x', id: id, os: 'windows', appVersion: '1.0.0'), throwsA(isA<PingException>()));
      expect(() => buildPing(event: 'ping', id: 'ABC', os: 'windows', appVersion: '1.0.0'), throwsA(isA<PingException>()));
      expect(() => buildPing(event: 'ping', id: id, os: 'beos', appVersion: '1.0.0'), throwsA(isA<PingException>()));
      expect(() => buildPing(event: 'ping', id: id, os: 'linux', appVersion: '1.0'), throwsA(isA<PingException>()));
      expect(isPingAppVersion('1.12.0-beta.7'), isTrue);
      expect(isPingAppVersion('1.12.0-beta.11+43'), isTrue);
      expect(isPingAppVersion('v1.12.0'), isFalse);
    });

    test('the system version is cut to the characters and the length the server takes', () {
      expect(cleanOsVersion('"Windows 10 Pro" 10.0 (Build 26100)'), 'Windows 10 Pro 10.0 (Build 26100)');
      expect(cleanOsVersion('x' * 100)!.length, 64);
      expect(cleanOsVersion('<>'), isNull);
      expect(cleanOsVersion(null), isNull);
      final b = buildPing(event: 'ping', id: id, os: 'linux', appVersion: '1.0.0', osVersion: '<script>');
      expect(b['os_version'], 'script');
    });

    test('Windows 11 is told apart from 10 by its build, and the name is not said twice', () {
      expect(windowsVersionName('"Windows 10 Pro" 10.0 (Build 26300)'), '11 Pro (Build 26300)');
      expect(windowsVersionName('"Windows 10 Home" 10.0 (Build 22631)'), '11 Home (Build 22631)');
      expect(windowsVersionName('"Windows 10 Pro" 10.0 (Build 19045)'), '10 Pro (Build 19045)');
      expect(windowsVersionName('"Windows Server 2022"'), 'Windows Server 2022');
      expect(windowsVersionName(null), isNull);
    });

    test('the country goes only with a ping from inside the tunnel, and only a real one', () {
      Map<String, Object> make(bool tunnel, String? c) =>
          buildPing(event: 'ping', id: id, os: 'linux', appVersion: '1.0.0', viaTunnel: tunnel, country: c);
      expect(make(false, 'IR').containsKey('country'), isFalse);
      expect(make(true, 'IR')['country'], 'IR');
      expect(make(true, 'XX').containsKey('country'), isFalse);
      expect(make(true, 'T1').containsKey('country'), isFalse);
      expect(make(true, 'ir').containsKey('country'), isFalse);
      expect(make(true, null).containsKey('country'), isFalse);
      expect(make(true, 'IR')['via_tunnel'], isTrue);
    });
  });

  group('the facts about the device', () {
    final id = hashDeviceId('abc');
    const full = DeviceFacts(
      lang: 'zh-Hans',
      deviceLang: 'fa_IR',
      region: 'IR',
      tz: 'America/Argentina/Buenos_Aires',
      brand: 'samsung',
      model: 'Redmi Note 12 Pro+',
      ui: 'One UI 6.1.1',
      arch: 'arm64',
    );

    test('known and valid facts go into the ping under the names the server uses', () {
      final b = buildPing(event: 'ping', id: id, os: 'android', appVersion: '1.0.0', facts: full);
      expect(b['lang'], 'zh-Hans');
      expect(b['device_lang'], 'fa_IR');
      expect(b['region'], 'IR');
      expect(b['tz'], 'America/Argentina/Buenos_Aires');
      expect(b['brand'], 'samsung');
      expect(b['model'], 'Redmi Note 12 Pro+');
      expect(b['ui'], 'One UI 6.1.1');
      expect(b['arch'], 'arm64');
      expect(utf8.encode(jsonEncode(b)).length, lessThanOrEqualTo(pingMaxBytes));
    });

    test('a fact that is missing is left out, not sent empty', () {
      final b = buildPing(event: 'ping', id: id, os: 'windows', appVersion: '1.0.0', facts: const DeviceFacts(arch: 'x64'));
      expect(b['arch'], 'x64');
      for (final k in ['lang', 'device_lang', 'region', 'tz', 'brand', 'model', 'ui']) {
        expect(b.containsKey(k), isFalse, reason: k);
      }
    });

    test('a value the server would refuse is dropped, and the rest still goes', () {
      final bad = DeviceFacts(
        lang: 'Farsi',
        deviceLang: 'x',
        region: 'XX',
        tz: '+03:30',
        brand: '',
        model: '<>',
        ui: '...',
        arch: 'mips',
      );
      final b = buildPing(event: 'ping', id: id, os: 'android', appVersion: '1.0.0', facts: bad);
      for (final k in ['lang', 'device_lang', 'region', 'tz', 'brand', 'model', 'ui', 'arch']) {
        expect(b.containsKey(k), isFalse, reason: k);
      }
      expect(b['os'], 'android');
      const mixed = DeviceFacts(lang: 'en', tz: 'IRST', region: 'T1', model: 'SM-S911B');
      final m = buildPing(event: 'ping', id: id, os: 'android', appVersion: '1.0.0', facts: mixed);
      expect(m['lang'], 'en');
      expect(m['model'], 'SM-S911B');
      expect(m['tz'], 'IRST'); // a name of letters passes the pattern; real ones come from the system
      expect(m.containsKey('region'), isFalse);
    });

    test('the limits are the ones of the server', () {
      Map<String, Object> make(DeviceFacts f) =>
          buildPing(event: 'ping', id: id, os: 'android', appVersion: '1.0.0', facts: f);
      expect(make(DeviceFacts(brand: 'a' * 30)).containsKey('brand'), isTrue);
      expect(make(DeviceFacts(brand: 'a' * 31))['brand'], 'a' * 30); // too long: cut, not dropped
      expect(make(DeviceFacts(model: 'a' * 40)).containsKey('model'), isTrue);
      expect(make(DeviceFacts(model: 'a' * 41))['model'], 'a' * 40);
      expect(make(DeviceFacts(ui: 'a' * 41))['ui'], 'a' * 40);
      expect(make(const DeviceFacts(tz: 'Etc/GMT+3')).containsKey('tz'), isTrue);
      expect(make(const DeviceFacts(tz: 'A/B/C/D')).containsKey('tz'), isFalse);
      expect(make(const DeviceFacts(deviceLang: 'en-US')).containsKey('device_lang'), isTrue);
      expect(make(const DeviceFacts(lang: 'zh-Hant')).containsKey('lang'), isTrue);
      expect(make(const DeviceFacts(lang: 'fa-IR-x')).containsKey('lang'), isFalse);
      for (final a in pingArches) {
        expect(make(DeviceFacts(arch: a))['arch'], a);
      }
    });

    test('the release file name goes in as "build", and a name the server would refuse is dropped', () {
      Map<String, Object> make(String? b) => buildPing(
          event: 'ping', id: id, os: 'android', appVersion: '1.0.0', facts: DeviceFacts(arch: 'arm64', build: b));
      expect(make('kumo-android-universal.apk')['build'], 'kumo-android-universal.apk');
      expect(make('kumo-android-universal.apk')['arch'], 'arm64'); // the file is not the processor
      expect(make('kumo-linux-arm64-portable.tar.gz').containsKey('build'), isFalse); // not this system's file
      expect(
          buildPing(
              event: 'ping',
              id: id,
              os: 'linux',
              appVersion: '1.0.0',
              facts: const DeviceFacts(build: 'kumo-linux-arm64-portable.tar.gz'))['build'],
          'kumo-linux-arm64-portable.tar.gz');
      for (final bad in [null, '', 'universal.apk', 'kumo-android', 'kumo-Android-x.apk', 'kumo-android-a b.apk', 'kumo-android-${'a' * 52}']) {
        expect(make(bad).containsKey('build'), isFalse, reason: '$bad');
      }
      expect(make('kumo-android-${'a' * 51}')['build'], hasLength(64));
    });

    test('the name of the file is worked out from the build and how it is installed', () {
      expect(buildAssetName('kumo-android-arm64-v8a.apk'), 'kumo-android-arm64-v8a.apk');
      expect(buildAssetName('kumo-android-universal.apk'), 'kumo-android-universal.apk');
      expect(buildAssetName('kumo-android-x86_64'), isNull);
      expect(buildAssetName(''), isNull);

      expect(buildAssetName('kumo-windows-x64'), 'kumo-windows-x64-setup.exe');
      expect(buildAssetName('kumo-windows-x64', portable: true), 'kumo-windows-x64-portable.zip');
      expect(buildAssetName('kumo-windows-arm64'), 'kumo-windows-arm64-setup.exe');
      expect(buildAssetName('kumo-windows-arm64', portable: true), 'kumo-windows-arm64-portable.zip');

      expect(buildAssetName('kumo-linux-x64', appImage: true), 'kumo-linux-x64.AppImage');
      expect(buildAssetName('kumo-linux-x64', portable: true), 'kumo-linux-x64-portable.tar.gz');
      expect(buildAssetName('kumo-linux-arm64', linuxPackage: 'deb'), 'kumo-linux-arm64.deb');
      expect(buildAssetName('kumo-linux-arm64', linuxPackage: 'rpm'), 'kumo-linux-arm64.rpm');
      expect(buildAssetName('kumo-linux-x64'), isNull); // installed, but which package is not known
      expect(buildAssetName('kumo-linux-x64', linuxPackage: 'snap'), isNull);

      expect(buildAssetName('kumo-macos', macVariant: 'universal'), 'kumo-macos-universal.dmg');
      expect(buildAssetName('kumo-macos', macVariant: 'arm64', portable: true), 'kumo-macos-arm64-portable.zip');
      expect(buildAssetName('kumo-macos', macVariant: 'x64'), 'kumo-macos-x64.dmg');
      expect(buildAssetName('kumo-macos'), isNull);
      expect(buildAssetName('kumo-freebsd-x64'), isNull);
    });

    test('a build made by hand sends no build name', () {
      expect(buildFamily, isEmpty);
      expect(installedBuildName(), isNull);
    });

    test('the last message after turning it off carries none of them', () {
      final b = buildPing(event: 'opt_out', id: id, os: 'android', appVersion: '1.0.0', facts: full);
      expect(b.keys.toSet(), {'v', 'event', 'id', 'os', 'app_version', 'via_tunnel'});
    });

    test('the processor is named as the server knows it', () {
      expect(archName('arm64-v8a'), 'arm64');
      expect(archName('armeabi-v7a'), 'armv7');
      expect(archName('x86_64'), 'x64');
      expect(archName('AMD64'), 'x64');
      expect(archName('aarch64'), 'arm64');
      expect(archName('x86'), 'x86');
      expect(archName('riscv64'), 'riscv64');
      expect(archName('mips64'), 'other');
      expect(archName(null), isNull);
      expect(archName(' '), isNull);
    });

    test('the maker interface is read only when it can be told for sure', () {
      expect(androidUiName(brand: 'samsung', oneui: '60101'), 'One UI 6.1.1');
      expect(androidUiName(brand: 'samsung', oneui: '60100'), 'One UI 6.1');
      expect(androidUiName(brand: 'samsung', oneui: ''), isNull);
      expect(androidUiName(brand: 'samsung'), isNull);
      expect(androidUiName(brand: 'Xiaomi', miui: 'V140'), 'MIUI 14');
      expect(androidUiName(brand: 'Xiaomi', miui: 'V125'), 'MIUI 12.5');
      expect(androidUiName(brand: 'Xiaomi', miui: 'V140', mios: 'OS1.0.3.0'), 'HyperOS 1.0');
      expect(androidUiName(brand: 'Xiaomi', miui: 'weird'), isNull);
      expect(androidUiName(brand: 'OPPO', oplus: 'V14.0.0'), 'ColorOS 14.0');
      expect(androidUiName(brand: 'Google'), isNull);
      expect(androidUiName(brand: null), isNull);
    });
  });

  group('the maker and model of the device', () {
    test('Windows: from the BIOS key; a placeholder maker falls back to the family', () {
      const real = r'''
HKEY_LOCAL_MACHINE\HARDWARE\DESCRIPTION\System\BIOS
    BIOSVendor    REG_SZ    American Megatrends Inc.
    SystemFamily    REG_SZ    Zenbook
    SystemManufacturer    REG_SZ    ASUSTeK COMPUTER INC.
    SystemProductName    REG_SZ    ZenBook UX425EA_UX425EA
    SystemSKU    REG_SZ    UX425EA
''';
      final n = parseWindowsBios(real);
      expect(n.brand, 'ASUSTeK COMPUTER INC.');
      expect(n.model, 'ZenBook UX425EA_UX425EA');
      final custom = parseWindowsBios(r'''
    SystemFamily    REG_SZ    My Family
    SystemManufacturer    REG_SZ    System manufacturer
    SystemProductName    REG_SZ    System Product Name
''');
      expect(custom.brand, 'My Family');
      expect(custom.model, isNull);
      expect(parseWindowsBios('').brand, isNull);
    });

    test('macOS: Apple and the model identifier, with its comma', () {
      final n = parseMacModel('MacBookPro18,3\n');
      expect(n.brand, 'Apple');
      expect(n.model, 'MacBookPro18,3');
      expect(parseMacModel('').brand, isNull);
    });

    test('Linux: vendor, product (family when missing) and the desktop', () {
      var n = linuxDeviceNames(vendor: 'LENOVO\n', product: '82KB\n', family: 'Legion 5', desktop: 'ubuntu:GNOME');
      expect((n.brand, n.model, n.ui), ('LENOVO', '82KB', 'GNOME'));
      n = linuxDeviceNames(vendor: 'Dell Inc.', product: '', family: 'XPS', desktop: 'KDE');
      expect((n.brand, n.model, n.ui), ('Dell Inc.', 'XPS', 'KDE'));
      n = linuxDeviceNames(vendor: 'To be filled by O.E.M.', product: 'Default string', family: 'Unknown', desktop: null);
      expect((n.brand, n.model, n.ui), (null, null, null));
    });

    test('placeholders go, long names are cut, characters the server refuses become spaces', () {
      for (final p in ['To be filled by O.E.M.', 'System Product Name', 'Default string', 'Unknown', '  none ', '']) {
        expect(cleanFact(p, max: 30), isNull, reason: p);
      }
      expect(cleanFact('Micro-Star International Co., Ltd.', max: 30), 'Micro-Star International Co. L');
      expect(cleanFact('Acme Co., Ltd.', max: 30), 'Acme Co. Ltd.');
      expect(cleanFact('A' * 50, max: 30), 'A' * 30);
      expect(cleanFact('Model ${'x' * 60}', max: 40, model: true), hasLength(40));
      expect(cleanFact('  Dell   Inc.  ', max: 30), 'Dell Inc.');
      expect(cleanFact('.hidden', max: 30), isNull); // must start with a letter or digit
      expect(cleanFact('MacBookPro18,3 (2021)', max: 40, model: true), 'MacBookPro18,3 (2021)');
      expect(cleanFact('Gigabyte™ Aorus', max: 30), 'Gigabyte Aorus');
    });

    test('they go into the body, and a bad one never makes the ping invalid', () {
      final body = buildPing(
          event: 'ping',
          id: 'a' * 64,
          os: 'macos',
          appVersion: '1.12.1',
          facts: const DeviceFacts(brand: 'Apple', model: 'MacBookPro18,3', ui: '...'));
      expect(body['brand'], 'Apple');
      expect(body['model'], 'MacBookPro18,3');
      expect(body.containsKey('ui'), isFalse);
    });
  });

  group('sending', () {
    test('the facts go with a ping, and a refusing fact never reaches the server', () async {
      final r = Rig()..facts = const DeviceFacts(lang: 'fa', tz: 'Asia/Tehran', brand: '');
      await r.reporter.tick();
      expect(r.calls.single.body['lang'], 'fa');
      expect(r.calls.single.body['tz'], 'Asia/Tehran');
      expect(r.calls.single.body.containsKey('brand'), isFalse);
    });

    test('the facts do not go with the opt_out', () async {
      final r = Rig()..facts = const DeviceFacts(lang: 'fa');
      await r.reporter.setEnabled(false);
      await r.reporter.tick();
      expect(r.calls.single.body['event'], 'opt_out');
      expect(r.calls.single.body.containsKey('lang'), isFalse);
    });

    test('a first ping goes out, once, and the same day it is not repeated', () async {
      final r = Rig();
      expect(await r.reporter.tick(), isTrue);
      expect(r.calls, hasLength(1));
      expect(r.calls.first.body['event'], 'ping');
      expect(r.calls.first.body['id'], hashDeviceId('machine-guid-1'));
      expect(await r.reporter.tick(), isTrue);
      expect(r.calls, hasLength(1));
    });

    test('the next day it goes again, and the same day again after a new version', () async {
      final r = Rig();
      await r.reporter.tick();
      r.clock = DateTime.utc(2026, 11, 8, 1);
      await r.reporter.tick();
      expect(r.calls, hasLength(2));
      r.version = '1.12.0';
      await r.reporter.tick();
      expect(r.calls, hasLength(3));
      expect(r.calls.last.body['app_version'], '1.12.0');
      await r.reporter.tick();
      expect(r.calls, hasLength(3));
    });

    test('the once-a-day record survives a restart', () async {
      final r = Rig();
      await r.reporter.tick();
      final again = Rig()..files.addAll(r.files);
      await again.reporter.tick();
      expect(again.calls, isEmpty);
    });

    test('with no system id a random one is kept and stays the same', () async {
      final r = Rig(sysId: null);
      await r.reporter.tick();
      final id = r.calls.first.body['id'] as String;
      expect(id, matches(RegExp(r'^[0-9a-f]{64}$')));
      final again = Rig(sysId: null)..files.addAll(r.files);
      again.clock = DateTime.utc(2026, 11, 9);
      await again.reporter.tick();
      expect(again.calls.first.body['id'], id);
    });

    test('turning it off sends one opt_out and then nothing, even after a restart', () async {
      final r = Rig();
      await r.reporter.tick();
      await r.reporter.setEnabled(false);
      r.calls.clear();
      expect(await r.reporter.tick(), isTrue);
      expect(r.calls, hasLength(1));
      expect(r.calls.first.body['event'], 'opt_out');
      expect(r.calls.first.body['id'], hashDeviceId('machine-guid-1'));
      r.clock = DateTime.utc(2026, 12, 1);
      await r.reporter.tick();
      await r.reporter.tick();
      expect(r.calls, hasLength(1));
      final again = Rig()..files.addAll(r.files);
      await again.reporter.tick();
      expect(again.calls, isEmpty);
      expect(again.reporter.enabled, isFalse);
    });

    test('an opt_out that did not get through is tried again, not forgotten', () async {
      final r = Rig()..answer = (_, __) => null;
      await r.reporter.setEnabled(false);
      expect(await r.reporter.tick(), isFalse);
      r.answer = (_, __) => 200;
      r.calls.clear();
      expect(await r.reporter.tick(), isTrue);
      expect(r.calls.single.body['event'], 'opt_out');
    });

    test('off while offline: the opt_out waits across restarts, goes once when online, then silence', () async {
      final r = Rig()..answer = (_, __) => null;
      await r.reporter.tick(); // a ping that did not get through
      await r.reporter.setEnabled(false);
      expect(await r.reporter.tick(), isFalse); // offline: the opt_out is still pending
      final restarted = Rig()
        ..files.addAll(r.files)
        ..answer = (_, __) => null;
      expect(await restarted.reporter.tick(), isFalse); // still offline after a restart
      expect(restarted.reporter.enabled, isFalse);
      restarted.answer = (_, __) => 200; // online again
      restarted.calls.clear();
      expect(await restarted.reporter.tick(), isTrue);
      expect(restarted.calls, hasLength(1));
      expect(restarted.calls.single.body['event'], 'opt_out');
      for (var i = 0; i < 3; i++) {
        await restarted.reporter.tick();
      }
      final again = Rig()..files.addAll(restarted.files);
      await again.reporter.tick();
      expect(restarted.calls, hasLength(1));
      expect(again.calls, isEmpty);
    });

    test('turned back on before the pending opt_out was sent: it is dropped, a normal ping follows', () async {
      final r = Rig()..answer = (_, __) => null;
      await r.reporter.setEnabled(false);
      await r.reporter.tick();
      await r.reporter.setEnabled(true);
      r.answer = (_, __) => 200;
      r.calls.clear();
      await r.reporter.tick();
      expect(r.calls.single.body['event'], 'ping');
      await r.reporter.setEnabled(false);
      expect(await r.reporter.tick(), isTrue);
      expect(r.calls.last.body['event'], 'opt_out');
      expect(r.calls, hasLength(2));
    });

    test('turned on again, a ping is sent again the same day', () async {
      final r = Rig();
      await r.reporter.tick();
      await r.reporter.setEnabled(false);
      await r.reporter.tick();
      await r.reporter.setEnabled(true);
      r.calls.clear();
      await r.reporter.tick();
      expect(r.calls.single.body['event'], 'ping');
    });

    test('maker, model and interface go from every system, and a build name only for its own system', () async {
      final r = Rig()
        ..facts = const DeviceFacts(
            brand: 'Dell Inc.', model: 'XPS 15 9530', ui: 'GNOME', build: 'kumo-android-universal.apk', arch: 'x64');
      await r.reporter.tick();
      final body = r.calls.single.body;
      expect(body['brand'], 'Dell Inc.');
      expect(body['model'], 'XPS 15 9530');
      expect(body['ui'], 'GNOME');
      expect(body.containsKey('build'), isFalse); // an Android file name on a Windows body
      expect(body['arch'], 'x64');
      final ok = Rig()..facts = const DeviceFacts(build: 'kumo-windows-x64-setup.exe');
      await ok.reporter.tick();
      expect(ok.calls.single.body['build'], 'kumo-windows-x64-setup.exe');
      expect(fitFacts('android', {'brand': 'Google', 'build': 'kumo-android-arm64-v8a.apk'}),
          {'brand': 'Google', 'build': 'kumo-android-arm64-v8a.apk'});
    });

    test('429: one request only, no other route, and the next try is the normal one', () async {
      final r = Rig()..answer = (_, __) => 429;
      expect(await r.reporter.tick(), isFalse);
      expect(r.calls, hasLength(1));
      r.answer = (_, __) => 200;
      await r.reporter.tick();
      expect(r.calls, hasLength(2)); // not recorded as sent: asked again later
    });

    test('400: the ping is not sent again today, and nothing is shown or thrown', () async {
      final logs = <String>[];
      final r = Rig()..answer = (_, __) => 400;
      final reporter = UsageReporter(
        read: (n) async => r.files[n],
        write: (n, c) async => r.files[n] = c,
        send: (e, b, m) async {
          r.calls.add((host: e.host, method: m, body: b));
          return 400;
        },
        systemId: () async => 'x-machine-id',
        os: 'windows',
        osVersion: () async => null,
        appVersion: () async => '1.12.1',
        tunnelUp: () => false,
        endpoints: () => const [UsageEndpoint('a.example.com'), UsageEndpoint('b.example.com')],
        countryHint: () => null,
        log: logs.add,
        now: () => r.clock,
      );
      expect(await reporter.tick(), isTrue);
      expect(r.calls, hasLength(1));
      expect(await reporter.tick(), isTrue);
      expect(r.calls, hasLength(1));
      expect(logs.single, contains('400'));
      expect(logs.join(), isNot(contains(hashDeviceId('x-machine-id'))));
    });

    test('a request that throws or never answers is a failure to retry later, not a crash', () async {
      final r = Rig();
      final reporter = UsageReporter(
        read: (n) async => r.files[n],
        write: (n, c) async => r.files[n] = c,
        send: (e, b, m) async => throw const FormatException('boom'),
        systemId: () async => 'x-machine-id',
        os: 'linux',
        osVersion: () async => throw StateError('no version'),
        appVersion: () async => '1.12.1',
        tunnelUp: () => false,
        endpoints: () => const [UsageEndpoint('a.example.com')],
        countryHint: () => null,
        facts: () async => throw StateError('no facts'),
        now: () => r.clock,
      );
      expect(await reporter.tick(), isFalse);
      expect(r.files[UsageReporter.file], isNull); // nothing recorded as sent
    });

    test('turned off while a ping is being sent: no more requests of it, the opt_out follows', () async {
      final r = Rig();
      var first = true;
      r.answer = (_, __) {
        if (first) {
          first = false;
          r.reporter.setEnabled(false);
        }
        return null;
      };
      await r.reporter.tick();
      expect(r.calls.where((c) => c.body['event'] == 'ping'), hasLength(1));
      r.answer = (_, __) => 200;
      await r.reporter.tick();
      expect(r.calls.last.body['event'], 'opt_out');
    });

    test('the day is the UTC day: the same UTC day is one ping, whatever the local clock says', () async {
      final r = Rig();
      r.clock = DateTime.utc(2026, 11, 7, 23, 59);
      await r.reporter.tick();
      r.clock = DateTime.utc(2026, 11, 7, 23, 59, 59);
      await r.reporter.tick();
      expect(r.calls, hasLength(1));
      r.clock = DateTime.utc(2026, 11, 8, 0, 0, 1);
      await r.reporter.tick();
      expect(r.calls, hasLength(2));
      expect(pingDay(DateTime.parse('2026-11-08T01:30:00+03:30')), '2026-11-07');
    });

    test('app versions with a test suffix fit the server, and a bad one is never sent', () {
      for (final v in ['1.12.1', '1.12.0-beta.12', '1.12.0-beta.12+44', '10.0.0-rc.1']) {
        expect(isPingAppVersion(v), isTrue, reason: v);
      }
      for (final v in ['1.12', 'v1.12.1', '1.12.1 beta', '']) {
        expect(isPingAppVersion(v), isFalse, reason: v);
      }
    });

    test('off from the start sends nothing but the one opt_out', () async {
      final r = Rig();
      r.files[UsageReporter.file] = jsonEncode({'enabled': false, 'opt_out_sent': true});
      await r.reporter.tick();
      expect(r.calls, isEmpty);
    });
  });

  group('the way a ping travels', () {
    test('outside the tunnel: direct on the first endpoint, then the second, then fragmented', () async {
      final r = Rig()..answer = (_, __) => null;
      expect(await r.reporter.tick(), isFalse);
      expect([for (final c in r.calls) '${c.host}/${c.method.name}'], [
        'a.example.com/direct',
        'b.example.com/direct',
        'a.example.com/fragment',
        'b.example.com/fragment',
      ]);
      expect(r.calls.every((c) => c.body['via_tunnel'] == false && !c.body.containsKey('country')), isTrue);
    });

    test('a later route is used when the earlier ones fail, and a success stops the tries', () async {
      final r = Rig()..answer = (e, m) => m == PingMethod.fragment && e.host == 'a.example.com' ? 200 : null;
      expect(await r.reporter.tick(), isTrue);
      expect(r.calls, hasLength(3));
      expect(await r.reporter.tick(), isTrue);
      expect(r.calls, hasLength(3));
    });

    test('a failure is not recorded, so the ping is tried again', () async {
      final r = Rig()..answer = (_, __) => 503;
      expect(await r.reporter.tick(), isFalse);
      r.answer = (_, __) => 200;
      r.calls.clear();
      expect(await r.reporter.tick(), isTrue);
      expect(r.calls, hasLength(1));
    });

    test('a refusal by the server (400) is final for the day: no other route, no retry', () async {
      final r = Rig()..answer = (_, __) => 400;
      expect(await r.reporter.tick(), isTrue);
      expect(r.calls, hasLength(1));
      await r.reporter.tick();
      expect(r.calls, hasLength(1));
    });

    test('through the tunnel the ping says so and carries the last country seen outside it', () async {
      final r = Rig();
      await r.reporter.tick(); // outside: remembers the country
      r.tunnel = true;
      r.clock = DateTime.utc(2026, 11, 8);
      await r.reporter.tick();
      final last = r.calls.last.body;
      expect(last['via_tunnel'], isTrue);
      expect(last['country'], 'IR');
    });

    test('an exception in the transport never escapes', () async {
      final r = Rig()..answer = (_, __) => throw StateError('boom');
      expect(await r.reporter.tick(), isFalse);
    });
  });

  group('the signed list of addresses', () {
    final (priv, pub) = newWarpKeyPair();
    final other = newWarpKeyPair();
    String list({int version = 2, String expires = '2099-01-01T00:00:00Z', String keyId = 't1', String host = 'x.example.com'}) =>
        jsonEncode({
          'schema': 1,
          'version': version,
          'issued_at': '2026-11-01T00:00:00Z',
          'expires_at': expires,
          'key_id': keyId,
          'endpoints': [
            {'host': host},
          ],
        });

    UsageEndpointStore store(Map<String, String> files, Map<String, String> net, {Map<String, String>? keys}) =>
        UsageEndpointStore(
          read: (n) async => files[n],
          write: (n, c) async => files[n] = c,
          fetch: (u) async => net[u] ?? (throw Exception('offline')),
          keys: keys ?? {'t1': pub},
          now: () => DateTime.utc(2026, 11, 7),
        );

    test('the built-in list holds the two addresses, workers.dev first', () {
      expect([for (final e in builtInUsageEndpoints.endpoints) e.host],
          ['kumo-api.kumoapp.workers.dev', 'api.kumo-client.ir']);
    });

    test('a list signed by the known key is taken, and kept for the next start', () async {
      final text = list(), url = usageEndpointUrls.first;
      final files = <String, String>{};
      final s = store(files, {url: text, '$url.sig': signWarp(utf8.encode(text), priv)});
      expect(await s.update(), isTrue);
      expect(s.current.endpoints.single.host, 'x.example.com');
      final next = store(files, {});
      await next.load();
      expect(next.current.version, 2);
    });

    test('a list with a wrong signature, an unknown key, an old version or past its date is refused', () async {
      final url = usageEndpointUrls.first;
      Future<bool> tryList(String text, String sig, {Map<String, String>? keys}) =>
          store({}, {url: text, '$url.sig': sig}, keys: keys).update();
      final good = list();
      expect(await tryList(good, signWarp(utf8.encode(good), other.$1)), isFalse);
      expect(await tryList(good, signWarp(utf8.encode(good), priv), keys: {}), isFalse);
      expect(await tryList(good.replaceAll('x.example', 'evil.example'), signWarp(utf8.encode(good), priv)), isFalse);
      final old = list(version: 0 + 1);
      final s = store({}, {url: old, '$url.sig': signWarp(utf8.encode(old), priv)});
      s.current = UsageEndpoints(
          version: 5,
          issuedAt: DateTime.utc(2026),
          expiresAt: DateTime.utc(2099),
          keyId: 't1',
          endpoints: const [UsageEndpoint('keep.example.com')]);
      expect(await s.update(), isFalse);
      expect(s.current.endpoints.single.host, 'keep.example.com');
      final expired = list(expires: '2026-11-02T00:00:00Z');
      expect(await tryList(expired, signWarp(utf8.encode(expired), priv)), isFalse);
    });

    test('the file is checked: only https hosts, nothing else', () {
      expect(() => parseUsageEndpoints(list(host: 'http://x.example.com')), throwsA(isA<UsageFormatException>()));
      expect(() => parseUsageEndpoints(list(host: 'x.example.com/path')), throwsA(isA<UsageFormatException>()));
      expect(() => parseUsageEndpoints(list(host: 'localhost')), throwsA(isA<UsageFormatException>()));
      expect(parseUsageEndpoints(list()).endpoints.single.host, 'x.example.com');
    });

    test('the second source is used when the first is not reachable', () async {
      final text = list(), sig = signWarp(utf8.encode(text), priv), url = usageEndpointUrls.last;
      final s = store({}, {url: text, '$url.sig': sig});
      expect(await s.update(), isTrue);
    });
  });
}
