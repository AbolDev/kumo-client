import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueNotifier, visibleForTesting;

import 'latency_tester.dart' show socksWarmDelay;
import 'system_proxy.dart';
import 'vpn_channel.dart' show AppEntry, Traffic, VpnState, VpnStatus;
import 'win_dpapi.dart';
import 'win_job.dart';
import 'win_tools.dart';

/// The VPN on the desktop: the same sing-box core as on Android, run as a child process
/// (kumo-core, with its TUN device made by wintun.dll on Windows). Xray (kumo-xray) is started
/// next to it for the servers it carries. The tunnel needs administrator rights on Windows (the
/// app asks for them at launch); on Linux and macOS the app works as a local proxy (also set as
/// the system proxy) and starts the tunnel with a password prompt (pkexec / osascript), or with no
/// prompt where the core has been given the network capability by the package.
class DesktopVpn {
  DesktopVpn._();
  static final instance = DesktopVpn._();

  // Cores left over from a run that was killed would hold the tunnel and the ports.
  late final Future<void> _ready = _killStale().then((_) => _proxy.restore());

  /// The port the system proxy was pointed at, while it is set. It is cleared only after the setting
  /// was taken away again.
  int? _sysPort;
  late final SystemProxy _proxy = SystemProxy.forPlatform(dataDir);

  final _states = StreamController<VpnState>.broadcast();
  final _traffic = StreamController<Traffic>.broadcast();
  VpnState _state = const VpnState(VpnStatus.stopped);

  Process? _core;
  Process? _xray;
  HttpClient? _stats;
  int _gen = 0;

  /// Linux / macOS: the tunnel runs as root through a small script; it stops when this file
  /// appears, when the app ends, or when the core ends.
  bool _elevated = false;
  Timer? _beat;

  Stream<VpnState> get states async* {
    yield _state;
    yield* _states.stream;
  }

  Stream<Traffic> get traffic => _traffic.stream;

  // ------------------------------------------------------------------ files

  static String get _sep => Platform.pathSeparator;

  static String get _exeDir => File(Platform.resolvedExecutable).parent.path;

  /// The folder the portable marker sits in: next to the program, or on macOS next to the
  /// `.app` (the program is Kumo.app/Contents/MacOS/Kumo).
  static String get _portableRoot {
    if (!Platform.isMacOS) return _exeDir;
    return File(Platform.resolvedExecutable).parent.parent.parent.parent.path;
  }

  /// The portable build has a file named `portable` next to the program: everything it saves then
  /// stays in a data folder beside it, so the folder can be moved or put on a USB drive.
  static final bool portable = File('$_portableRoot${_sep}portable').existsSync();

  /// Tests keep their files in a folder of their own instead of the user's.
  @visibleForTesting
  static String? dataDirOverride;

  String get dataDir {
    final override = dataDirOverride;
    if (override != null) return override;
    if (portable) {
      // Windows keeps the name it had from the start; the Linux bundle has its own `data` folder.
      return '$_portableRoot$_sep${Platform.isWindows ? 'data' : 'kumo-data'}';
    }
    final env = Platform.environment;
    if (Platform.isWindows) {
      return '${env['APPDATA'] ?? Directory.systemTemp.path}\\Kumo';
    }
    if (Platform.isMacOS) {
      return '${env['HOME'] ?? Directory.systemTemp.path}/Library/Application Support/Kumo';
    }
    final config = env['XDG_CONFIG_HOME'] ?? '${env['HOME'] ?? Directory.systemTemp.path}/.config';
    return '$config/Kumo';
  }

  /// The file name of a program that sits next to the app (kumo-core.exe on Windows).
  static String _program(String name) => Platform.isWindows ? '$name.exe' : name;

  String _exePath(String name) => '$_exeDir$_sep${_program(name)}';

  /// Servers, settings (proxy login) and cached subscriptions are kept encrypted for the Windows
  /// user. Not in the portable build, whose folder is meant to move to other computers.
  static bool _sealed(String name) => Platform.isWindows && !portable && _holdsSecret(name);

  /// The files that hold server credentials or the proxy login.
  static bool _holdsSecret(String name) =>
      name.startsWith('servers') || name.startsWith('settings') || name.startsWith('subcache/');

  /// The text of a file, null when there is none. Throws when the file is there but cannot be read
  /// (damaged, or encrypted for another Windows account): that is not the same as "no file", and
  /// the caller must not write over it as if it were new.
  Future<String?> readFile(String name) async {
    final f = File('$dataDir$_sep$name');
    if (!await f.exists()) return null;
    final text = await f.readAsString();
    // A file written by an older version is plain text; it is encrypted the next time it is saved.
    if (Platform.isWindows && WinDpapi.isSealed(text)) {
      final plain = WinDpapi.open(text);
      if (plain == null) throw FileSystemException('cannot decrypt', f.path);
      return plain;
    }
    return text;
  }

  /// Saves a file whole or not at all: the new text is written next to it and then moved over it,
  /// so a power cut or a kill in the middle cannot leave half a file. The last good copy of a
  /// JSON file stays as `<name>.bak`.
  Future<void> writeFile(String name, String content) async {
    final f = File('$dataDir$_sep$name');
    await f.parent.create(recursive: true);
    await _lockDown(dataDir, directory: true);
    final text = _sealed(name) ? (WinDpapi.seal(content) ?? content) : content;
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(text, flush: true);
    if (_holdsSecret(name)) await _lockDown(tmp.path);
    if (name.endsWith('.json') && await f.exists()) {
      try {
        jsonDecode(await readFile(name) ?? '');
        await f.copy('${f.path}.bak');
      } catch (_) {
        // the file in place is already damaged: the older .bak is the one worth keeping
      }
    }
    await tmp.rename(f.path);
  }

  /// Sets a damaged or unreadable file aside (`<name>.broken`) so a fresh one can be written
  /// without losing it.
  Future<void> moveAside(String name) async {
    final f = File('$dataDir$_sep$name');
    if (!await f.exists()) return;
    final target = File('${f.path}.broken');
    if (await target.exists()) await target.delete();
    await f.rename(target.path);
  }

  Future<void> deleteFile(String name) async {
    final f = File('$dataDir$_sep$name');
    if (await f.exists()) await f.delete();
  }

  /// Linux and macOS: the folder and the files in it belong to this user alone (they hold server
  /// credentials and the key of the local control API).
  static final _lockedDirs = <String>{};

  static Future<void> _lockDown(String path, {bool directory = false}) async {
    if (Platform.isWindows) return;
    if (directory && !_lockedDirs.add(path)) return;
    try {
      await Process.run('chmod', [directory ? '700' : '600', path]);
    } catch (_) {}
  }

  // ------------------------------------------------------------------ helpers

  /// A core configuration (it holds server credentials and the key of the control API), readable by
  /// this user alone on Linux and macOS.
  static Future<void> _writeConfig(String path, String text) async {
    final f = File(path);
    await f.writeAsString(text, flush: true);
    await _lockDown(path);
  }

  void _emit(VpnStatus s, [String? error]) {
    _state = VpnState(s, error);
    _states.add(_state);
  }

  // The cores this app started and that are still running, written to a file so that a run that was
  // killed can clean up after itself at the next start. (They are no longer found by their name: that
  // would also end the cores of another user or session on the same computer.)
  final _pids = <int>{};
  File get _pidFile => File('$dataDir${_sep}cores.pid');

  Future<void> _writePids() async {
    try {
      await Directory(dataDir).create(recursive: true);
      await _pidFile.writeAsString(_pids.join(','));
    } catch (_) {}
  }

  void _track(Process p) {
    _pids.add(p.pid);
    _writePids();
    p.exitCode.then((_) {
      _pids.remove(p.pid);
      _writePids();
    });
  }

  Future<void> _killStale() async {
    try {
      final file = _pidFile;
      if (!await file.exists()) return;
      final old = (await file.readAsString()).split(',').map(int.tryParse).whereType<int>();
      for (final id in old) {
        if (Platform.isWindows) {
          // Only a process that is still one of ours (the number may have been given to another
          // program since).
          final r = await Process.run(winTool('tasklist'), ['/FI', 'PID eq $id', '/FO', 'CSV', '/NH']);
          final text = '${r.stdout}'.toLowerCase();
          if (text.contains('kumo-core.exe') || text.contains('kumo-xray.exe')) {
            await Process.run(winTool('taskkill'), ['/F', '/PID', '$id']);
          }
        } else {
          final r = await Process.run('ps', ['-p', '$id', '-o', 'comm=']);
          final name = '${r.stdout}'.trim();
          if (name == 'kumo-core' || name == 'kumo-xray') Process.killPid(id);
        }
      }
      await file.delete();
    } catch (_) {}
  }

  Future<int> _freePort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    return port;
  }

  Future<Process> _spawn(String exe, List<String> args, StringBuffer output) async {
    final p = await Process.start(_exePath(exe), args, workingDirectory: dataDir);
    if (Platform.isWindows) WinJob.add(p.pid);
    _track(p);
    void collect(List<int> data) {
      if (output.length < 4000) output.write(utf8.decode(data, allowMalformed: true));
    }

    p.stdout.listen(collect, onError: (_) {});
    p.stderr.listen(collect, onError: (_) {});
    return p;
  }

  Future<bool> _waitHttp(int port, bool Function() abort, Duration limit,
      [String? secret]) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    final end = DateTime.now().add(limit);
    try {
      while (DateTime.now().isBefore(end) && !abort()) {
        try {
          final req = await client.getUrl(
              Uri.parse('http://127.0.0.1:$port/version'));
          if (secret != null) req.headers.set('Authorization', 'Bearer $secret');
          final res = await req.close();
          await res.drain<void>();
          return true;
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 80));
        }
      }
    } finally {
      client.close(force: true);
    }
    return false;
  }

  // ------------------------------------------------------------------ elevated tunnel (Linux, macOS)

  String get _stopFile => '$dataDir${_sep}core.stop';
  String get _coreLog => '$dataDir${_sep}core.log';

  /// Whether the core may open a TUN device without a password: it runs as root, or (Linux, from
  /// the .deb package) it was given the network capability.
  Future<bool> _canTunWithoutPrompt() async {
    try {
      final id = await Process.run('id', ['-u']);
      if ('${id.stdout}'.trim() == '0') return true;
      if (Platform.isLinux) {
        final caps = await Process.run('getcap', [_exePath('kumo-core')]);
        if (!'${caps.stdout}'.contains('cap_net_admin')) return false;
        // The packages give the core to the group "kumo" only: someone outside it cannot run it
        // and is asked for a password instead.
        final run = await Process.run('test', ['-x', _exePath('kumo-core')]);
        return run.exitCode == 0;
      }
    } catch (_) {}
    return false;
  }

  Future<bool> _configHasTun(String file) async {
    try {
      final cfg = jsonDecode(await File(file).readAsString()) as Map<String, dynamic>;
      return (cfg['inbounds'] as List).any((i) => (i as Map)['type'] == 'tun');
    } catch (_) {
      return false;
    }
  }

  /// Runs the VPN core as root for the tunnel (`sh -c`, arguments: the core, its configuration
  /// text, the stop file, the app's pid, the log file, the data folder). It ends when the app asks
  /// (the stop file), when the app is gone, or when the core stops by itself.
  static const _rootScript = r'''
T=$(mktemp -d) || exit 1
chmod 700 "$T"
printf '%s' "$2" > "$T/config.json"
cd "$6" 2>/dev/null || cd "$T"
rm -f "$5"
set -C
"$1" run -c "$T/config.json" >"$5" 2>&1 &
P=$!
while kill -0 "$P" 2>/dev/null && [ ! -e "$3" ] && kill -0 "$4" 2>/dev/null; do sleep 1; done
kill "$P" 2>/dev/null
wait "$P" 2>/dev/null
rm -rf "$T"
''';

  /// Starts the core as root through that script, which stops it again on request. The user is
  /// asked for the password once (pkexec on Linux, the macOS administrator prompt).
  Future<Process?> _spawnElevated(String cfgFile, StringBuffer output) async {
    await _deleteQuietly(_stopFile);
    await _deleteQuietly(_coreLog);
    // What root runs is given in the command itself (the script and the configuration), not read
    // from files in this user's folder: another program of this user could change such a file while
    // the password prompt is open. The root side keeps its own copy in a folder only root can enter.
    final args = [
      _rootScript,
      'kumo',
      _exePath('kumo-core'),
      await File(cfgFile).readAsString(),
      _stopFile,
      '$pid',
      _coreLog,
      dataDir,
    ];
    if (Platform.isMacOS) {
      String q(String s) => "'${s.replaceAll("'", "'\\''")}'";
      final command = 'sh -c ${args.map(q).join(' ')} >/dev/null 2>&1 &';
      final apple = 'do shell script "${command.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}" '
          'with administrator privileges';
      final r = await Process.run('osascript', ['-e', apple]);
      if (r.exitCode != 0) {
        output.write('${r.stderr}');
        return null;
      }
      _elevated = true;
      return null; // no handle: the beat below watches the core
    }
    final p = await Process.start('pkexec', ['sh', '-c', ...args], workingDirectory: dataDir);
    p.stdout.listen((_) {}, onError: (_) {});
    p.stderr.listen((d) {
      if (output.length < 4000) output.write(utf8.decode(d, allowMalformed: true));
    }, onError: (_) {});
    _elevated = true;
    return p;
  }

  Future<void> _deleteQuietly(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  // ------------------------------------------------------------------ connect

  /// [apiPort] / [apiSecret] are the control API the config already opens; with [systemProxyPort]
  /// the system proxy is pointed there while connected.
  Future<void> start(String configJson,
      {String? xrayConfig,
      int? xrayPort,
      required int apiPort,
      String? apiSecret,
      int? systemProxyPort,
      bool killSwitch = false,
      bool keepStandby = false}) async {
    _killSwitch = killSwitch;
    _secret = apiSecret;
    final gen = ++_gen;
    bool stale() => gen != _gen;
    _emit(VpnStatus.starting);
    final output = StringBuffer();
    try {
      await _ready;
      // The standby proxy holds the same port, so it gives way to a core that serves the proxy too.
      // A tunnel core serves no proxy: the standby stays, and its programs are not cut.
      final withStandby = keepStandby && _sbCore != null;
      if (!withStandby) await stopStandby();
      await Directory(dataDir).create(recursive: true);
      if (stale()) return;
      if (xrayConfig != null && xrayPort != null) {
        final file = '$dataDir${_sep}xray_config.json';
        await _writeConfig(file, xrayConfig);
        final xray = _xray = await _spawn('kumo-xray', ['run', '-c', file], output);
        var exited = false;
        xray.exitCode.then((_) => exited = true);
        if (stale()) return;
        var listening = false;
        final end = DateTime.now().add(const Duration(seconds: 8));
        while (!listening && !exited && !stale() && DateTime.now().isBefore(end)) {
          try {
            (await Socket.connect('127.0.0.1', xrayPort,
                    timeout: const Duration(milliseconds: 300)))
                .destroy();
            listening = true;
          } catch (_) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
        if (stale()) return;
        if (!listening) {
          throw StateError('xray failed to start: ${output.toString().trim()}');
        }
      }

      final api = apiPort;
      final cfg = jsonDecode(configJson) as Map<String, dynamic>;
      if (xrayConfig != null) {
        // Xray talks to its server directly: its own traffic must not loop into the tunnel.
        final route = cfg['route'] as Map<String, dynamic>;
        (route['rules'] as List).insert(0, {
          'process_name': [_program('kumo-xray')],
          'outbound': 'direct',
        });
        route['find_process'] = true;
      }
      if (withStandby) {
        // The proxy ports belong to the standby core, and its own traffic must not loop into the tunnel.
        (cfg['inbounds'] as List).removeWhere((i) => i is Map && (i['tag'] == 'mixed-in' || i['tag'] == 'lan-in'));
        final route = cfg['route'] as Map<String, dynamic>;
        (route['rules'] as List).insert(0, {
          'process_name': [_program('kumo-core'), _program('kumo-xray')],
          'outbound': 'direct',
        });
        route['find_process'] = true;
      }
      final file = '$dataDir${_sep}active_config.json';
      await _writeConfig(file, jsonEncode(cfg));

      _elevated = false;
      Process? core;
      if (!Platform.isWindows && await _configHasTun(file) && !await _canTunWithoutPrompt()) {
        core = _core = await _spawnElevated(file, output);
        if (core == null && !_elevated) {
          throw StateError('the password was not given: ${output.toString().trim()}');
        }
      } else {
        core = _core = await _spawn('kumo-core', ['run', '-c', file], output);
      }
      var exited = false;
      if (core != null) {
        core.exitCode.then((code) {
          exited = true;
          if (!stale() && identical(_core, core)) {
            var text = output.toString().trim();
            if (_elevated && File(_coreLog).existsSync()) {
              text = File(_coreLog).readAsStringSync().trim();
            }
            _failed(gen, text.isEmpty ? 'sing-box stopped (exit code $code)' : text);
          }
        });
      }
      // The password prompt can take a while.
      final limit = _elevated ? const Duration(seconds: 90) : const Duration(seconds: 25);
      final up = await _waitHttp(api, () => exited || stale(), limit, apiSecret);
      if (stale()) return;
      if (!up) {
        var text = output.toString().trim();
        if (_elevated && File(_coreLog).existsSync()) {
          text = File(_coreLog).readAsStringSync().trim();
        }
        throw StateError(text.isEmpty ? 'sing-box did not start' : text);
      }
      if (systemProxyPort != null) {
        _sysPort = systemProxyPort;
        proxyIssue.value = !await _proxy.enable(systemProxyPort);
      }
      if (stale()) return;
      _emit(VpnStatus.started);
      _watchTraffic(api, gen);
      if (_elevated && core == null) _beatCore(api, gen);
    } catch (e) {
      if (stale()) return;
      await _killAll();
      _emit(VpnStatus.error, '$e'.replaceFirst('Bad state: ', ''));
    }
  }

  /// macOS: the elevated core has no process handle, so its API is asked every few seconds.
  void _beatCore(int port, int gen) {
    _beat?.cancel();
    var misses = 0;
    _beat = Timer.periodic(const Duration(seconds: 5), (t) async {
      if (gen != _gen) {
        t.cancel();
        return;
      }
      final ok = await _waitHttp(port, () => false, const Duration(seconds: 2), _secret);
      misses = ok ? 0 : misses + 1;
      if (misses >= 3 && gen == _gen) {
        t.cancel();
        _failed(gen, 'sing-box stopped');
      }
    });
  }

  bool _killSwitch = false;
  String? _secret;

  void _failed(int gen, String message) {
    if (gen != _gen) return;
    _gen++;
    _killAll(keepBlocked: _killSwitch).then((_) => _emit(VpnStatus.error, message));
  }

  // ------------------------------------------------------------------ standby proxy

  /// A core that only serves the local proxy (no tunnel, no system proxy), kept running while the
  /// VPN is off so that programs which use the proxy address keep working.
  Process? _sbCore;
  Process? _sbXray;
  int _sbGen = 0;
  int _sbApi = 0;
  String? _sbSecret;

  /// True while the connection is the standby core itself (see [adoptStandby]).
  bool _adopted = false;

  /// True while the standby proxy is up.
  final standby = ValueNotifier<bool>(false);

  /// True when the connection is up but the desktop's proxy setting could not be made, so programs
  /// that follow it do not go through the proxy (the user is told).
  final proxyIssue = ValueNotifier<bool>(false);

  Future<bool> _portOpen(int port) async {
    try {
      (await Socket.connect('127.0.0.1', port, timeout: const Duration(milliseconds: 300)))
          .destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Starts the standby proxy. Returns false when it could not (the port is taken ...).
  Future<bool> startStandby(String configJson,
      {String? xrayConfig, int? xrayPort, required int apiPort, String? apiSecret}) async {
    await stopStandby();
    final gen = ++_sbGen;
    bool stale() => gen != _sbGen;
    final output = StringBuffer();
    try {
      await _ready;
      if (stale()) return false;
      await Directory(dataDir).create(recursive: true);
      if (xrayConfig != null && xrayPort != null) {
        final file = '$dataDir${_sep}standby_xray.json';
        await _writeConfig(file, xrayConfig);
        final xray = _sbXray = await _spawn('kumo-xray', ['run', '-c', file], output);
        var exited = false;
        xray.exitCode.then((_) => exited = true);
        final end = DateTime.now().add(const Duration(seconds: 8));
        var listening = false;
        while (!listening && !exited && !stale() && DateTime.now().isBefore(end)) {
          listening = await _portOpen(xrayPort);
          if (!listening) await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        if (stale()) return false;
        if (!listening) throw StateError('xray failed to start: ${output.toString().trim()}');
      }
      final file = '$dataDir${_sep}standby_config.json';
      await _writeConfig(file, configJson);
      final core = _sbCore = await _spawn('kumo-core', ['run', '-c', file], output);
      var exited = false;
      core.exitCode.then((_) {
        exited = true;
        if (identical(_sbCore, core)) {
          _sbCore = null;
          _sbXray?.kill();
          _sbXray = null;
          standby.value = false;
          // The connection was this core: it ended with it.
          if (_adopted) {
            _adopted = false;
            _gen++;
            _stats?.close(force: true);
            _stats = null;
            _releaseProxy().then((_) => _emit(VpnStatus.error, 'sing-box stopped'));
          }
        }
      });
      final up = await _waitHttp(apiPort, () => exited || stale(), const Duration(seconds: 15), apiSecret);
      if (stale()) return false;
      if (!up) {
        final text = output.toString().trim();
        throw StateError(text.isEmpty ? 'sing-box did not start' : text);
      }
      _sbApi = apiPort;
      _sbSecret = apiSecret;
      standby.value = true;
      return true;
    } catch (e) {
      if (!stale()) await stopStandby();
      return false;
    }
  }

  /// Makes the core that is already running the connection: nothing is restarted, so the programs
  /// using the proxy are not cut. Only for the proxy mode (the tunnel is a core of its own). The
  /// system proxy is pointed at [systemProxyPort]; false when there is no standby core.
  Future<bool> adoptStandby({required int systemProxyPort}) async {
    if (_sbCore == null || !standby.value) return false;
    final gen = ++_gen;
    _emit(VpnStatus.starting);
    try {
      _sysPort = systemProxyPort;
      proxyIssue.value = !await _proxy.enable(systemProxyPort);
    } catch (_) {
      proxyIssue.value = true;
    }
    if (gen != _gen || _sbCore == null) return false;
    _adopted = true;
    _secret = _sbSecret;
    _emit(VpnStatus.started);
    _watchTraffic(_sbApi, gen);
    return true;
  }

  Future<void> stopStandby() async {
    // Giving the standby core up ends a connection that is that core.
    if (_adopted) await stop();
    _sbGen++;
    final procs = [_sbCore, _sbXray].whereType<Process>().toList();
    _sbCore = null;
    _sbXray = null;
    standby.value = false;
    for (final p in procs) {
      p.kill();
    }
    await Future.wait([
      for (final p in procs) p.exitCode.timeout(const Duration(seconds: 4), onTimeout: () => -1),
    ]);
  }

  /// Takes this app's system proxy away. It is tried again when the check afterwards shows the
  /// setting is still there, so that disconnecting always leaves the system without our proxy.
  Future<void> _releaseProxy() async {
    proxyIssue.value = false;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await _proxy.restore(port: _sysPort);
        break;
      } catch (_) {}
    }
    _sysPort = null;
  }

  Future<void> _blockProxy() async {
    _sysPort = 1;
    proxyIssue.value = false;
    await _proxy.enable(1);
  }

  Future<void> stop() async {
    _gen++;
    if (_state.status == VpnStatus.stopped) {
      // Nothing runs, but a setting left behind (a failed earlier removal) is still taken away.
      if (_sysPort != null) await _releaseProxy();
      return;
    }
    _emit(VpnStatus.stopping);
    if (_adopted) {
      // Only the system proxy goes; the core stays, with the programs that use it.
      _adopted = false;
      _stats?.close(force: true);
      _stats = null;
      await _releaseProxy();
    } else {
      await _killAll();
    }
    _emit(VpnStatus.stopped);
  }

  /// With [keepBlocked] the system proxy is left pointing at a dead port, so programs that follow
  /// it cannot reach the internet until the user disconnects or reconnects.
  Future<void> _killAll({bool keepBlocked = false}) async {
    // The proxy settings are put back while the cores are being stopped, not before: the two
    // are independent and each used to wait for the other.
    final proxy = keepBlocked ? _blockProxy() : _releaseProxy();
    _beat?.cancel();
    _beat = null;
    final wasElevated = _elevated;
    // The pkexec wrapper ends by itself when the script sees the stop file: killing it would
    // leave the root core running.
    final wrapper = wasElevated ? _core : null;
    final procs = [_core, _xray].whereType<Process>().toList();
    _core = null;
    _xray = null;
    _stats?.close(force: true);
    _stats = null;
    if (wasElevated) {
      try {
        await File(_stopFile).writeAsString('stop');
      } catch (_) {}
    }
    for (final p in procs) {
      if (!identical(p, wrapper)) p.kill();
    }
    await Future.wait([
      proxy,
      for (final p in procs)
        p.exitCode.timeout(Duration(seconds: identical(p, wrapper) ? 8 : 4), onTimeout: () {
          if (identical(p, wrapper)) p.kill();
          return -1;
        }),
    ]);
    if (wasElevated) {
      _elevated = false;
      await _deleteQuietly(_stopFile);
    }
  }

  /// Speed and totals from the core's local API, one line a second.
  Future<void> _watchTraffic(int port, int gen) async {
    var upTotal = 0, downTotal = 0;
    var failures = 0;
    // The stream is asked for again when it drops while the connection is still up (a hiccup of the
    // core's API), so the speed and the usage do not stop silently.
    while (gen == _gen && failures < 5) {
      final client = HttpClient();
      _stats = client;
      var got = false;
      try {
        final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port/traffic'));
        if (_secret != null) req.headers.set('Authorization', 'Bearer $_secret');
        final res = await req.close();
        await for (final line
            in res.transform(utf8.decoder).transform(const LineSplitter())) {
          if (gen != _gen) break;
          if (line.trim().isEmpty) continue;
          final j = jsonDecode(line) as Map<String, dynamic>;
          final up = (j['up'] as num).toInt(), down = (j['down'] as num).toInt();
          upTotal += up;
          downTotal += down;
          got = true;
          _traffic.add(Traffic(up, down, upTotal, downTotal));
        }
      } catch (_) {
        // the connection was closed
      } finally {
        client.close(force: true);
      }
      if (gen != _gen) return;
      failures = got ? 0 : failures + 1;
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }

  /// Programs running now (their names), for choosing which ones use the tunnel.
  Future<List<AppEntry>> runningProcesses() async {
    final names = <String>{};
    if (Platform.isWindows) {
      final r = await Process.run(winTool('tasklist'), ['/fo', 'csv', '/nh']);
      for (final line in '${r.stdout}'.split('\n')) {
        final m = RegExp(r'^"([^"]+\.exe)"', caseSensitive: false).firstMatch(line.trim());
        if (m != null) names.add(m.group(1)!);
      }
    } else {
      final r = await Process.run('ps', ['-A', '-o', 'comm=']);
      for (final line in '${r.stdout}'.split('\n')) {
        final name = line.trim().split('/').last;
        if (name.isNotEmpty && !name.startsWith('[')) names.add(name);
      }
    }
    final own = {'kumo', 'kumo.exe', 'kumo-core', 'kumo-core.exe', 'kumo-xray', 'kumo-xray.exe'};
    return [
      for (final n in (names.where((n) => !own.contains(n.toLowerCase())).toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()))))
        AppEntry(n, n),
    ];
  }

  // ------------------------------------------------------------------ real delay

  /// The Xray program next to the app.
  String get xrayExecutable => _exePath('kumo-xray');

  Future<Process> spawnQuiet(String exe, List<String> args) async {
    final p = await Process.start(exe, args, workingDirectory: dataDir);
    if (Platform.isWindows) WinJob.add(p.pid);
    _track(p);
    return p;
  }

  /// The real delay of the single outbound `proxy` of [configJson] to [url] in ms, -1 on failure:
  /// a throw-away core with a SOCKS inbound, and two requests over one connection through it (see
  /// [socksWarmDelay]).
  Future<int> delay(String configJson, String url, int timeoutMs) async {
    await _ready;
    final output = StringBuffer();
    Process? core;
    File? file;
    try {
      final port = await _freePort();
      final cfg = jsonDecode(configJson) as Map<String, dynamic>;
      cfg['inbounds'] = [
        {'type': 'socks', 'tag': 'in', 'listen': '127.0.0.1', 'listen_port': port},
      ];
      cfg['route'] = {...?(cfg['route'] as Map<String, dynamic>?), 'final': 'proxy'};
      await Directory('$dataDir${_sep}delay').create(recursive: true);
      file = File('$dataDir${_sep}delay$_sep$port.json');
      await file.writeAsString(jsonEncode(cfg));
      core = await _spawn('kumo-core', ['run', '-c', file.path], output);
      var exited = false;
      core.exitCode.then((_) => exited = true);
      // wait for the inbound to listen
      final end = DateTime.now().add(const Duration(seconds: 8));
      var ready = false;
      while (!exited && DateTime.now().isBefore(end)) {
        try {
          final s = await Socket.connect('127.0.0.1', port, timeout: const Duration(milliseconds: 500));
          s.destroy();
          ready = true;
          break;
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 60));
        }
      }
      if (!ready) return -1;
      return await socksWarmDelay(port, Uri.parse(url), Duration(milliseconds: timeoutMs));
    } catch (_) {
      return -1;
    } finally {
      core?.kill();
      try {
        await file?.delete();
      } catch (_) {}
    }
  }
}
