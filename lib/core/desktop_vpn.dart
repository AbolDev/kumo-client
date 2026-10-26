import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'platform.dart';
import 'system_proxy.dart';
import 'vpn_channel.dart' show AppEntry, Traffic, VpnState, VpnStatus;
import 'win_job.dart';

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

  /// The portable build has a file named `portable` next to the program: everything it saves then
  /// stays in the `data` folder beside it, so the folder can be moved or put on a USB drive.
  static final bool portable = File('$_exeDir${_sep}portable').existsSync();

  String get dataDir {
    if (portable) return '$_exeDir${_sep}data';
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

  Future<String?> readFile(String name) async {
    final f = File('$dataDir$_sep$name');
    return await f.exists() ? f.readAsString() : null;
  }

  Future<void> writeFile(String name, String content) async {
    final f = File('$dataDir$_sep$name');
    await f.parent.create(recursive: true);
    await f.writeAsString(content, flush: true);
  }

  // ------------------------------------------------------------------ helpers

  void _emit(VpnStatus s, [String? error]) {
    _state = VpnState(s, error);
    _states.add(_state);
  }

  Future<void> _killStale() async {
    try {
      if (Platform.isWindows) {
        await Process.run('taskkill', ['/F', '/IM', 'kumo-core.exe', '/IM', 'kumo-xray.exe']);
      } else {
        await Process.run('pkill', ['-x', 'kumo-core']);
        await Process.run('pkill', ['-x', 'kumo-xray']);
      }
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

  Map<String, dynamic> _withApi(String configJson, int port) {
    final cfg = jsonDecode(configJson) as Map<String, dynamic>;
    cfg['experimental'] = {
      'clash_api': {'external_controller': '127.0.0.1:$port'},
    };
    return cfg;
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
        return '${caps.stdout}'.contains('cap_net_admin');
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

  /// Starts the core as root through a script that stops it again on request. The user is asked
  /// for the password once (pkexec on Linux, the macOS administrator prompt).
  Future<Process?> _spawnElevated(String cfgFile, StringBuffer output) async {
    final script = File('$dataDir${_sep}run_core.sh');
    await script.writeAsString('''#!/bin/sh
# Runs the VPN core as root for the tunnel. It ends when the app asks (the stop file), when the
# app is gone, or when the core stops by itself.
CORE="\$1"; CFG="\$2"; STOP="\$3"; APP="\$4"; LOG="\$5"
cd "\$(dirname "\$CFG")"
"\$CORE" run -c "\$CFG" >"\$LOG" 2>&1 &
P=\$!
while kill -0 "\$P" 2>/dev/null && [ ! -e "\$STOP" ] && kill -0 "\$APP" 2>/dev/null; do sleep 1; done
kill "\$P" 2>/dev/null
wait "\$P" 2>/dev/null
''', flush: true);
    await _deleteQuietly(_stopFile);
    await _deleteQuietly(_coreLog);
    final args = [script.path, _exePath('kumo-core'), cfgFile, _stopFile, '$pid', _coreLog];
    if (Platform.isMacOS) {
      String q(String s) => "'${s.replaceAll("'", "'\\''")}'";
      final command = 'sh ${args.map(q).join(' ')} >/dev/null 2>&1 &';
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
    final p = await Process.start('pkexec', ['sh', ...args], workingDirectory: dataDir);
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
      bool killSwitch = false}) async {
    _killSwitch = killSwitch;
    _secret = apiSecret;
    final gen = ++_gen;
    bool stale() => gen != _gen;
    _emit(VpnStatus.starting);
    final output = StringBuffer();
    try {
      await _ready;
      await Directory(dataDir).create(recursive: true);
      if (stale()) return;
      if (xrayConfig != null && xrayPort != null) {
        final file = '$dataDir${_sep}xray_config.json';
        await File(file).writeAsString(xrayConfig);
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
      final file = '$dataDir${_sep}active_config.json';
      await File(file).writeAsString(jsonEncode(cfg));

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
      if (systemProxyPort != null) await _proxy.enable(systemProxyPort);
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

  Future<void> stop() async {
    _gen++;
    if (_state.status == VpnStatus.stopped) return;
    _emit(VpnStatus.stopping);
    await _killAll();
    _emit(VpnStatus.stopped);
  }

  /// With [keepBlocked] the system proxy is left pointing at a dead port, so programs that follow
  /// it cannot reach the internet until the user disconnects or reconnects.
  Future<void> _killAll({bool keepBlocked = false}) async {
    // The proxy settings are put back while the cores are being stopped, not before: the two
    // are independent and each used to wait for the other.
    final proxy = keepBlocked ? _proxy.enable(1) : _proxy.restore();
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
    final client = HttpClient();
    _stats = client;
    var upTotal = 0, downTotal = 0;
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
        _traffic.add(Traffic(up, down, upTotal, downTotal));
      }
    } catch (_) {
      // the connection was closed
    } finally {
      client.close(force: true);
    }
  }

  /// Programs running now (their names), for choosing which ones use the tunnel.
  Future<List<AppEntry>> runningProcesses() async {
    final names = <String>{};
    if (Platform.isWindows) {
      final r = await Process.run('tasklist', ['/fo', 'csv', '/nh']);
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

  /// Time to fetch [url] through the single outbound `proxy` of [configJson], -1 on failure.
  /// A throw-away core answers it through its local API.
  Future<int> delay(String configJson, String url, int timeoutMs) async {
    await _ready;
    final output = StringBuffer();
    Process? core;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    File? file;
    try {
      final port = await _freePort();
      await Directory('$dataDir${_sep}delay').create(recursive: true);
      file = File('$dataDir${_sep}delay$_sep$port.json');
      await file.writeAsString(jsonEncode(_withApi(configJson, port)));
      core = await _spawn('kumo-core', ['run', '-c', file.path], output);
      var exited = false;
      core.exitCode.then((_) => exited = true);
      if (!await _waitHttp(port, () => exited, const Duration(seconds: 8))) return -1;
      final req = await client.getUrl(Uri.parse(
          'http://127.0.0.1:$port/proxies/proxy/delay'
          '?url=${Uri.encodeQueryComponent(url)}&timeout=$timeoutMs'));
      final res = await req.close().timeout(Duration(milliseconds: timeoutMs + 3000));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) return -1;
      return (jsonDecode(body)['delay'] as num).toInt();
    } catch (_) {
      return -1;
    } finally {
      client.close(force: true);
      core?.kill();
      try {
        await file?.delete();
      } catch (_) {}
    }
  }
}
