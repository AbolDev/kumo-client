import 'dart:convert';
import 'dart:io';

import 'win_proxy.dart';

/// The proxy setting of the desktop that browsers and most programs follow. [enable] points it at
/// 127.0.0.1:[port] and writes the previous setting to a file first; [restore] puts that back (it
/// is also used at startup, after a crash).
abstract class SystemProxy {
  Future<void> enable(int port);
  Future<void> restore();

  static SystemProxy forPlatform(String dataDir) {
    if (Platform.isWindows) return WinProxy(dataDir);
    if (Platform.isMacOS) return MacProxy(dataDir);
    return LinuxProxy(dataDir);
  }
}

const _bypass = [
  'localhost',
  '127.0.0.0/8',
  '::1',
  '10.0.0.0/8',
  '172.16.0.0/12',
  '192.168.0.0/16',
];

Future<String> _run(String exe, List<String> args) async {
  try {
    final r = await Process.run(exe, args);
    return r.exitCode == 0 ? '${r.stdout}'.trim() : '';
  } catch (_) {
    return '';
  }
}

Future<bool> _exists(String exe) async {
  try {
    final r = await Process.run('which', [exe]);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

// ----------------------------------------------------------------------------------- Linux

/// GNOME (and the many desktops that follow its settings) through gsettings, KDE Plasma through
/// its kioslaverc file.
class LinuxProxy implements SystemProxy {
  LinuxProxy(this.dataDir);

  final String dataDir;

  File get _backup => File('$dataDir/system_proxy_backup.json');

  static const _gnome = [
    ['org.gnome.system.proxy', 'mode'],
    ['org.gnome.system.proxy', 'ignore-hosts'],
    ['org.gnome.system.proxy', 'autoconfig-url'],
    ['org.gnome.system.proxy.http', 'host'],
    ['org.gnome.system.proxy.http', 'port'],
    ['org.gnome.system.proxy.https', 'host'],
    ['org.gnome.system.proxy.https', 'port'],
    ['org.gnome.system.proxy.socks', 'host'],
    ['org.gnome.system.proxy.socks', 'port'],
  ];

  bool get _kde => (Platform.environment['XDG_CURRENT_DESKTOP'] ?? '').toUpperCase().contains('KDE');

  Future<String?> _kdeWriter() async {
    for (final name in const ['kwriteconfig6', 'kwriteconfig5']) {
      if (await _exists(name)) return name;
    }
    return null;
  }

  Future<String> _kdeRead(String key) async {
    for (final name in const ['kreadconfig6', 'kreadconfig5']) {
      if (await _exists(name)) {
        return _run(name, ['--file', 'kioslaverc', '--group', 'Proxy Settings', '--key', key]);
      }
    }
    return '';
  }

  Future<void> _kdeNotify() => _run('dbus-send', [
        '--type=signal',
        '/KIO/Scheduler',
        'org.kde.KIO.Scheduler.reparseSlaveConfiguration',
        'string:',
      ]);

  @override
  Future<void> enable(int port) async {
    try {
      if (!await _backup.exists()) {
        await _backup.parent.create(recursive: true);
        if (_kde) {
          await _backup.writeAsString(jsonEncode({
            'kde': {
              for (final k in const ['ProxyType', 'httpProxy', 'httpsProxy', 'socksProxy', 'NoProxyFor'])
                k: await _kdeRead(k),
            },
          }));
        } else {
          await _backup.writeAsString(jsonEncode({
            'gnome': {
              for (final e in _gnome) '${e[0]} ${e[1]}': await _run('gsettings', ['get', e[0], e[1]]),
            },
          }));
        }
      }
      if (_kde) {
        final write = await _kdeWriter();
        if (write == null) return;
        Future<void> set(String key, String value) => _run(write,
            ['--file', 'kioslaverc', '--group', 'Proxy Settings', '--key', key, value]);
        await set('ProxyType', '1');
        await set('httpProxy', 'http://127.0.0.1 $port');
        await set('httpsProxy', 'http://127.0.0.1 $port');
        await set('socksProxy', 'socks://127.0.0.1 $port');
        await set('NoProxyFor', _bypass.join(','));
        await _kdeNotify();
      } else {
        Future<void> set(String schema, String key, String value) =>
            _run('gsettings', ['set', schema, key, value]);
        await set('org.gnome.system.proxy', 'autoconfig-url', '');
        await set('org.gnome.system.proxy.http', 'host', '127.0.0.1');
        await set('org.gnome.system.proxy.http', 'port', '$port');
        await set('org.gnome.system.proxy.https', 'host', '127.0.0.1');
        await set('org.gnome.system.proxy.https', 'port', '$port');
        await set('org.gnome.system.proxy.socks', 'host', '127.0.0.1');
        await set('org.gnome.system.proxy.socks', 'port', '$port');
        await set('org.gnome.system.proxy', 'ignore-hosts', "[${_bypass.map((e) => "'$e'").join(', ')}]");
        await set('org.gnome.system.proxy', 'mode', 'manual');
      }
    } catch (_) {}
  }

  @override
  Future<void> restore() async {
    try {
      if (!await _backup.exists()) return;
      final j = jsonDecode(await _backup.readAsString()) as Map<String, dynamic>;
      final gnome = j['gnome'];
      if (gnome is Map) {
        // mode last, so the old mode only returns once its details are back
        final entries = gnome.entries.toList()
          ..sort((a, b) => (a.key == 'org.gnome.system.proxy mode' ? 1 : 0)
              .compareTo(b.key == 'org.gnome.system.proxy mode' ? 1 : 0));
        for (final e in entries) {
          final parts = '${e.key}'.split(' ');
          if ('${e.value}'.isEmpty) continue;
          await _run('gsettings', ['set', parts[0], parts[1], '${e.value}']);
        }
      }
      final kde = j['kde'];
      if (kde is Map) {
        final write = await _kdeWriter();
        if (write != null) {
          for (final e in kde.entries) {
            await _run(write, [
              '--file', 'kioslaverc', '--group', 'Proxy Settings', '--key', '${e.key}', '${e.value}',
            ]);
          }
          await _kdeNotify();
        }
      }
      await _backup.delete();
    } catch (_) {}
  }
}

// ----------------------------------------------------------------------------------- macOS

/// Every network service (Wi-Fi, Ethernet ...) through `networksetup`.
class MacProxy implements SystemProxy {
  MacProxy(this.dataDir);

  final String dataDir;

  File get _backup => File('$dataDir/system_proxy_backup.json');

  Future<List<String>> _services() async {
    final out = await _run('networksetup', ['-listallnetworkservices']);
    return [
      for (final line in out.split('\n').skip(1))
        // a leading * marks a disabled service
        if (line.trim().isNotEmpty && !line.startsWith('*')) line.trim(),
    ];
  }

  /// "Enabled: Yes / Server: x / Port: 8080" -> (on, server, port).
  Future<({bool on, String server, String port})> _state(String query, String service) async {
    final out = await _run('networksetup', [query, service]);
    String field(String name) =>
        RegExp('^$name:\\s*(.*)\$', multiLine: true).firstMatch(out)?.group(1)?.trim() ?? '';
    return (on: field('Enabled') == 'Yes', server: field('Server'), port: field('Port'));
  }

  @override
  Future<void> enable(int port) async {
    try {
      final services = await _services();
      if (!await _backup.exists()) {
        await _backup.parent.create(recursive: true);
        final saved = <String, dynamic>{};
        for (final s in services) {
          final web = await _state('-getwebproxy', s);
          final secure = await _state('-getsecurewebproxy', s);
          final socks = await _state('-getsocksfirewallproxy', s);
          saved[s] = {
            'web': [web.on, web.server, web.port],
            'secure': [secure.on, secure.server, secure.port],
            'socks': [socks.on, socks.server, socks.port],
          };
        }
        await _backup.writeAsString(jsonEncode(saved));
      }
      for (final s in services) {
        await _run('networksetup', ['-setwebproxy', s, '127.0.0.1', '$port']);
        await _run('networksetup', ['-setsecurewebproxy', s, '127.0.0.1', '$port']);
        await _run('networksetup', ['-setsocksfirewallproxy', s, '127.0.0.1', '$port']);
        await _run('networksetup', ['-setproxybypassdomains', s, ..._bypass]);
      }
    } catch (_) {}
  }

  @override
  Future<void> restore() async {
    try {
      if (!await _backup.exists()) return;
      final j = jsonDecode(await _backup.readAsString()) as Map<String, dynamic>;
      for (final e in j.entries) {
        final s = e.key;
        final v = e.value as Map<String, dynamic>;
        Future<void> back(String set, String state, List<dynamic> old) async {
          final server = '${old[1]}', port = '${old[2]}';
          if (server.isNotEmpty && port.isNotEmpty && port != '0') {
            await _run('networksetup', [set, s, server, port]);
          }
          await _run('networksetup', [state, s, old[0] == true ? 'on' : 'off']);
        }

        await back('-setwebproxy', '-setwebproxystate', v['web'] as List);
        await back('-setsecurewebproxy', '-setsecurewebproxystate', v['secure'] as List);
        await back('-setsocksfirewallproxy', '-setsocksfirewallproxystate', v['socks'] as List);
      }
      await _backup.delete();
    } catch (_) {}
  }
}
