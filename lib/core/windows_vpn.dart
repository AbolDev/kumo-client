import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'vpn_channel.dart' show AppEntry, Traffic, VpnState, VpnStatus;
import 'win_job.dart';
import 'win_proxy.dart';

/// The VPN on Windows: the same sing-box core as on Android, run as a child process
/// (kumo-core.exe, with its TUN device made by wintun.dll). Xray (kumo-xray.exe) is started next
/// to it for XHTTP configs. Needs administrator rights, which the app asks for at launch.
class WindowsVpn {
  WindowsVpn._();
  static final instance = WindowsVpn._();

  // Cores left over from a run that was killed would hold the tunnel and the ports.
  late final Future<void> _ready = _killStale().then((_) => _proxy.restore());
  late final WinProxy _proxy = WinProxy(dataDir);

  final _states = StreamController<VpnState>.broadcast();
  final _traffic = StreamController<Traffic>.broadcast();
  VpnState _state = const VpnState(VpnStatus.stopped);

  Process? _core;
  Process? _xray;
  HttpClient? _stats;
  int _gen = 0;

  Stream<VpnState> get states async* {
    yield _state;
    yield* _states.stream;
  }

  Stream<Traffic> get traffic => _traffic.stream;

  // ------------------------------------------------------------------ files

  String get dataDir {
    final base = Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
    return '$base\\Kumo';
  }

  String _exePath(String name) =>
      '${File(Platform.resolvedExecutable).parent.path}\\$name';

  Future<String?> readFile(String name) async {
    final f = File('$dataDir\\$name');
    return await f.exists() ? f.readAsString() : null;
  }

  Future<void> writeFile(String name, String content) async {
    final f = File('$dataDir\\$name');
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
      await Process.run(
          'taskkill', ['/F', '/IM', 'kumo-core.exe', '/IM', 'kumo-xray.exe']);
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
    WinJob.add(p.pid);
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

  // ------------------------------------------------------------------ connect

  /// [apiPort] / [apiSecret] are the control API the config already opens; with [systemProxyPort]
  /// the Windows system proxy is pointed there while connected.
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
        final file = '$dataDir\\xray_config.json';
        await File(file).writeAsString(xrayConfig);
        final xray = _xray = await _spawn('kumo-xray.exe', ['run', '-c', file], output);
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
          'process_name': ['kumo-xray.exe'],
          'outbound': 'direct',
        });
      }
      final file = '$dataDir\\active_config.json';
      await File(file).writeAsString(jsonEncode(cfg));
      final core = _core = await _spawn('kumo-core.exe', ['run', '-c', file], output);
      var exited = false;
      core.exitCode.then((code) {
        exited = true;
        if (!stale() && identical(_core, core)) {
          final text = output.toString().trim();
          _failed(gen, text.isEmpty ? 'sing-box stopped (exit code $code)' : text);
        }
      });
      final up = await _waitHttp(api, () => exited || stale(), const Duration(seconds: 25), apiSecret);
      if (stale()) return;
      if (!up) {
        throw StateError(output.toString().trim().isEmpty
            ? 'sing-box did not start'
            : output.toString().trim());
      }
      if (systemProxyPort != null) await _proxy.enable(systemProxyPort);
      if (stale()) return;
      _emit(VpnStatus.started);
      _watchTraffic(api, gen);
    } catch (e) {
      if (stale()) return;
      await _killAll();
      _emit(VpnStatus.error, '$e'.replaceFirst('Bad state: ', ''));
    }
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
    final procs = [_core, _xray].whereType<Process>().toList();
    _core = null;
    _xray = null;
    _stats?.close(force: true);
    _stats = null;
    for (final p in procs) {
      p.kill();
    }
    await Future.wait([
      proxy,
      for (final p in procs)
        p.exitCode.timeout(const Duration(seconds: 4), onTimeout: () => -1),
    ]);
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

  /// Programs running now (their .exe names), for choosing which ones use the tunnel.
  Future<List<AppEntry>> runningProcesses() async {
    final r = await Process.run('tasklist', ['/fo', 'csv', '/nh']);
    final names = <String>{};
    for (final line in ''.split('\n')) {
      final m = RegExp(r'^"([^"]+\.exe)"', caseSensitive: false).firstMatch(line.trim());
      if (m != null) names.add(m.group(1)!);
    }
    const own = {'kumo.exe', 'kumo-core.exe', 'kumo-xray.exe'};
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
      await Directory('$dataDir\\delay').create(recursive: true);
      file = File('$dataDir\\delay\\$port.json');
      await file.writeAsString(jsonEncode(_withApi(configJson, port)));
      core = await _spawn('kumo-core.exe', ['run', '-c', file.path], output);
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
