import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'system_proxy.dart';

const _key = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';

/// The Windows system proxy (what browsers and most programs follow). The previous setting is
/// written to a file first, so it can be restored even after the app was killed.
class WinProxy implements SystemProxy {
  WinProxy(this.dataDir);

  final String dataDir;

  File get _backup => File('$dataDir\\system_proxy_backup.json');

  Future<String?> _query(String name) async {
    final r = await Process.run('reg', ['query', _key, '/v', name]);
    if (r.exitCode != 0) return null;
    final m = RegExp('$name\\s+REG_\\w+\\s+(.*)').firstMatch('${r.stdout}');
    return m?.group(1)?.trim();
  }

  Future<void> _set(String name, String type, String? value) async {
    if (value == null) {
      await Process.run('reg', ['delete', _key, '/v', name, '/f']);
    } else {
      await Process.run('reg', ['add', _key, '/v', name, '/t', type, '/d', value, '/f']);
    }
  }

  /// Makes programs notice the change without a restart.
  void _notify() {
    try {
      final wininet = DynamicLibrary.open('wininet.dll');
      final setOption = wininet.lookupFunction<
          Int32 Function(Pointer<Void>, Uint32, Pointer<Void>, Uint32),
          int Function(Pointer<Void>, int, Pointer<Void>, int)>('InternetSetOptionW');
      setOption(nullptr, 39, nullptr, 0); // INTERNET_OPTION_SETTINGS_CHANGED
      setOption(nullptr, 37, nullptr, 0); // INTERNET_OPTION_REFRESH
    } catch (_) {}
  }

  int? _port;

  /// Points the system proxy at 127.0.0.1:[port].
  @override
  Future<void> enable(int port) async {
    _port = port;
    try {
      if (!await _backup.exists()) {
        await _backup.parent.create(recursive: true);
        await _backup.writeAsString(jsonEncode({
          'ours': port,
          'enable': await _query('ProxyEnable'),
          'server': await _query('ProxyServer'),
          'override': await _query('ProxyOverride'),
          'auto': await _query('AutoConfigURL'),
        }));
      }
      await _set('ProxyServer', 'REG_SZ', '127.0.0.1:$port');
      await _set('ProxyOverride', 'REG_SZ', 'localhost;127.*;10.*;172.16.*;192.168.*;<local>');
      await _set('ProxyEnable', 'REG_DWORD', '1');
      // A setup script (PAC) wins over the manual proxy: it is switched off while connected and
      // put back afterwards (restore).
      await _set('AutoConfigURL', 'REG_SZ', null);
      _notify();
    } catch (_) {}
  }

  /// Switches the proxy off when it still points at [port] (checked, and tried again). A proxy of
  /// another program is left alone.
  Future<void> _clearOurs(int port) async {
    bool ours(String? server) =>
        server != null && (server.contains('127.0.0.1:$port') || server.contains('localhost:$port'));
    for (var attempt = 0; attempt < 3; attempt++) {
      if (!ours(await _query('ProxyServer'))) return;
      await _set('ProxyEnable', 'REG_DWORD', '0');
      await _set('ProxyServer', 'REG_SZ', null);
      _notify();
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  }

  /// Puts back what was there before (also used at startup after a crash), then makes sure the proxy
  /// of this app is gone.
  @override
  Future<void> restore({int? port}) async {
    int? ours = port ?? _port;
    try {
      if (!await _backup.exists()) {
        if (ours != null) await _clearOurs(ours);
        return;
      }
      final j = jsonDecode(await _backup.readAsString()) as Map<String, dynamic>;
      ours ??= (j['ours'] as num?)?.toInt();
      final enable = j['enable'] as String?;
      var server = j['server'] as String?;
      var on = enable == null ? 0 : (int.tryParse(enable.replaceFirst('0x', ''), radix: 16) ?? 0);
      // A backup that itself holds this app's proxy (an earlier crash left it set) means "off".
      if (ours != null && server != null && (server.contains('127.0.0.1:$ours') || server.contains('localhost:$ours'))) {
        on = 0;
        server = null;
      }
      // Independent registry writes, each a separate process: run them side by side.
      await Future.wait([
        _set('ProxyEnable', 'REG_DWORD', '$on'),
        _set('ProxyServer', 'REG_SZ', server),
        _set('ProxyOverride', 'REG_SZ', j['override'] as String?),
        if (j['auto'] is String) _set('AutoConfigURL', 'REG_SZ', j['auto'] as String),
      ]);
      if (ours != null) await _clearOurs(ours);
      await _backup.delete();
      _notify();
    } catch (_) {}
    _port = null;
  }
}