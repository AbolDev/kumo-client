import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

const _key = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';

/// The Windows system proxy (what browsers and most programs follow). The previous setting is
/// written to a file first, so it can be restored even after the app was killed.
class WinProxy {
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

  /// Points the system proxy at 127.0.0.1:[port].
  Future<void> enable(int port) async {
    try {
      if (!await _backup.exists()) {
        await _backup.parent.create(recursive: true);
        await _backup.writeAsString(jsonEncode({
          'enable': await _query('ProxyEnable'),
          'server': await _query('ProxyServer'),
          'override': await _query('ProxyOverride'),
          'auto': await _query('AutoConfigURL'),
        }));
      }
      await _set('ProxyServer', 'REG_SZ', '127.0.0.1:$port');
      await _set('ProxyOverride', 'REG_SZ', 'localhost;127.*;10.*;172.16.*;192.168.*;<local>');
      await _set('ProxyEnable', 'REG_DWORD', '1');
      _notify();
    } catch (_) {}
  }

  /// Puts back what was there before (also used at startup after a crash).
  Future<void> restore() async {
    try {
      if (!await _backup.exists()) return;
      final j = jsonDecode(await _backup.readAsString()) as Map<String, dynamic>;
      final enable = j['enable'] as String?;
      await _set('ProxyEnable', 'REG_DWORD',
          enable == null ? '0' : '${int.tryParse(enable.replaceFirst('0x', ''), radix: 16) ?? 0}');
      await _set('ProxyServer', 'REG_SZ', j['server'] as String?);
      await _set('ProxyOverride', 'REG_SZ', j['override'] as String?);
      await _backup.delete();
      _notify();
    } catch (_) {}
  }
}
