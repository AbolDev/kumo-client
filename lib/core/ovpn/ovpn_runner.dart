import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../proxy_config.dart' show OvpnServer;
import 'ovpn_management.dart';

/// Why a connection with OpenVPN did not come up.
enum OvpnFailure {
  /// The OpenVPN program is not there.
  noBinary,

  /// No network adapter driver for OpenVPN (TAP-Windows) is installed.
  noDriver,

  /// A user name and password are needed and not given (or a key's passphrase).
  needsLogin,
  needsKeyPassword,

  /// The server did not take the user name and password.
  authFailed,

  /// It did not connect in time.
  timeout,

  /// The program stopped; the detail holds the last of what it said.
  exited,

  /// Not available on this system yet.
  unsupported,
}

class OvpnConnectException implements Exception {
  OvpnConnectException(this.failure, [this.detail = '']);

  final OvpnFailure failure;
  final String detail;

  @override
  String toString() => detail.isEmpty ? failure.name : '${failure.name}: $detail';
}

/// The name of the adapter Kumo makes for OpenVPN. sing-box sends the traffic out through it.
const ovpnAdapterName = 'KumoOpenVPN';

/// The adapters `openvpn --show-adapters` lists: (name, driver).
List<(String, String)> parseAdapters(String output) {
  final out = <(String, String)>[];
  for (final line in output.split(RegExp(r'\r?\n'))) {
    final m = RegExp(r"^'(.+)'\s+\{[0-9A-Fa-f\-]+\}\s+(\S+)\s*$").firstMatch(line.trim());
    if (m != null) out.add((m[1]!, m[2]!));
  }
  return out;
}

/// What is added to the configuration for the run (after what was read from the user's file, which
/// holds none of these): the adapter, no routes from the server, and the management port.
String runConfig(String config, {required int managementPort, required String passwordFile}) {
  final b = StringBuffer(config.trimRight())
    ..write('\n')
    ..writeln('dev-node $ovpnAdapterName')
    ..writeln('windows-driver tap-windows6')
    // The routes are Kumo's: nothing the server pushes changes how the computer is routed. One route
    // with a very high metric lets a program that is bound to the adapter (sing-box) send through it
    // without making it the way out for everything else.
    ..writeln('route-nopull')
    ..writeln('route 0.0.0.0 0.0.0.0 vpn_gateway 5000')
    ..writeln('management 127.0.0.1 $managementPort ${_quote(passwordFile)}')
    ..writeln('management-hold')
    ..writeln('management-query-passwords')
    ..writeln('auth-retry nointeract');
  return b.toString();
}

String _quote(String s) => '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

/// Runs the OpenVPN program for one connection and talks to it over its management port.
class OvpnRunner {
  OvpnRunner({
    required this.binary,
    required this.tapctl,
    required this.workDir,
    this.driverDir,
    Future<ProcessResult> Function(String exe, List<String> args)? run,
  }) : _run = run ?? Process.run;

  /// `openvpn.exe`, and `tapctl.exe` (which makes the adapter), and a folder for the files of a run.
  final String binary;
  final String? tapctl;
  final String workDir;

  /// The folder with the signed driver of the adapter (OemVista.inf, tap0901.sys and .cat), which is put
  /// into Windows when it is not there yet.
  final String? driverDir;
  final Future<ProcessResult> Function(String exe, List<String> args) _run;

  /// Called before the driver is installed (the screen says what is going on).
  void Function()? onInstallingDriver;

  Process? _process;
  OvpnManagement? _port;
  StreamSubscription<OvpnEvent>? _sub;
  final _tail = <String>[];
  final _files = <File>[];
  var _stopping = false;

  /// Called when the program ends after it was connected, and when it starts to reconnect.
  void Function(String reason)? onLost;
  void Function(OvpnState state)? onState;

  bool get running => _process != null;

  void _remember(String line) {
    if (line.trim().isEmpty) return;
    _tail.add(line.trim());
    if (_tail.length > 30) _tail.removeAt(0);
  }

  String get lastLines => _tail.join('\n');

  /// Makes sure the adapter exists (Windows). Throws [OvpnConnectException] with `noDriver` when the
  /// driver is not there.
  Future<void> ensureAdapter() async {
    if (!Platform.isWindows) return;
    final shown = await _run(binary, ['--show-adapters']);
    final adapters = parseAdapters('${shown.stdout}');
    final named = adapters.where((a) => a.$1 == ovpnAdapterName).toList();
    if (named.any((a) => a.$2 == 'tap-windows6')) return;
    final ctl = tapctl;
    if (ctl == null || !File(ctl).existsSync()) {
      throw OvpnConnectException(OvpnFailure.noBinary, 'tapctl');
    }
    // The type of the adapter is named: tapctl chooses by itself otherwise (it makes an "ovpn-dco" one
    // when that driver is in Windows, which cannot carry the ciphers and the compression that most
    // configurations use).
    Future<ProcessResult> create() => _run(ctl, ['create', '--name', ovpnAdapterName, '--hwid', r'root\tap0901']);
    try {
      if (named.isNotEmpty) {
        // An adapter of ours that an earlier run made with another driver is taken away first.
        await _run(ctl, ['delete', ovpnAdapterName]);
      }
      var r = await create();
      if (r.exitCode != 0) {
        // The driver is not in Windows yet: the one that comes with Kumo (signed by Microsoft's hardware
        // program, made by the OpenVPN project) is put in, and the adapter is made again.
        final first = '${r.stdout}${r.stderr}'.trim();
        await _installDriver(first);
        r = await create();
        if (r.exitCode != 0) {
          throw OvpnConnectException(OvpnFailure.noDriver, '${r.stdout}${r.stderr}'.trim());
        }
      }
    } on ProcessException catch (e) {
      // tapctl asks for the rights of an administrator.
      throw OvpnConnectException(OvpnFailure.noDriver, e.message);
    }
  }

  /// pnputil puts the driver package in the store of Windows (and installs it on the adapters that need
  /// it). Throws noDriver when there is no package or Windows does not take it.
  Future<void> _installDriver(String why) async {
    final dir = driverDir;
    final inf = dir == null ? null : File('$dir${Platform.pathSeparator}OemVista.inf');
    if (inf == null || !inf.existsSync()) {
      throw OvpnConnectException(OvpnFailure.noDriver, why);
    }
    onInstallingDriver?.call();
    final ProcessResult r;
    try {
      r = await _run('pnputil', ['/add-driver', inf.path, '/install']);
    } on ProcessException catch (e) {
      throw OvpnConnectException(OvpnFailure.noDriver, e.message);
    }
    // 0: done; 3010: done, a restart is advised (the adapter works without it); 259: the package was in
    // Windows already and nothing needed it (the adapter can be made all the same).
    if (r.exitCode != 0 && r.exitCode != 3010 && r.exitCode != 259) {
      throw OvpnConnectException(OvpnFailure.noDriver, '${r.stdout}${r.stderr}'.trim());
    }
  }

  Future<int> _freePort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final p = s.port;
    await s.close();
    return p;
  }

  /// Starts OpenVPN and waits until it is connected. Returns the name of the adapter to send through.
  Future<String> start(OvpnServer server, {Duration timeout = const Duration(seconds: 60)}) async {
    if (!Platform.isWindows) {
      throw OvpnConnectException(OvpnFailure.unsupported, Platform.operatingSystem);
    }
    if (!File(binary).existsSync()) throw OvpnConnectException(OvpnFailure.noBinary, binary);
    if (server.needsLogin) throw OvpnConnectException(OvpnFailure.needsLogin);
    if (server.needsKeyPassword) throw OvpnConnectException(OvpnFailure.needsKeyPassword);
    await stop();
    _stopping = false;
    _tail.clear();
    await ensureAdapter();

    final dir = Directory('$workDir${Platform.pathSeparator}ovpn')..createSync(recursive: true);
    final random = Random.secure();
    final secret = List.generate(24, (_) => random.nextInt(36).toRadixString(36)).join();
    final pw = File('${dir.path}${Platform.pathSeparator}mgmt.pw')..writeAsStringSync(secret);
    final cfg = File('${dir.path}${Platform.pathSeparator}run.ovpn');
    final port = await _freePort();
    cfg.writeAsStringSync(runConfig(server.profile.config, managementPort: port, passwordFile: pw.path));
    _files
      ..clear()
      ..addAll([pw, cfg]);

    final process = await Process.start(binary, ['--config', cfg.path],
        workingDirectory: File(binary).parent.path, runInShell: false);
    _process = process;
    // Written so that a program left running by a crash of Kumo can be found and ended at the next start.
    final pid = File('${dir.path}${Platform.pathSeparator}openvpn.pid')..writeAsStringSync('${process.pid}');
    _files.add(pid);
    final exited = Completer<int>();
    process.exitCode.then((code) {
      if (!exited.isCompleted) exited.complete(code);
      if (identical(_process, process)) {
        _process = null;
        if (!_stopping) onLost?.call(lastLines);
      }
    });
    for (final stream in [process.stdout, process.stderr]) {
      stream.transform(utf8.decoder).transform(const LineSplitter()).listen(_remember, onError: (_) {});
    }

    final done = Completer<String>();
    void fail(OvpnConnectException e) {
      if (!done.isCompleted) done.completeError(e);
    }

    // The program may stop before the port even opens (a driver or a file that is missing).
    unawaited(exited.future.then((code) {
      fail(OvpnConnectException(OvpnFailure.exited, lastLines.isEmpty ? 'exit code $code' : lastLines));
    }));

    try {
      final OvpnManagement m = await Future.any([

        OvpnManagement.connect(port, secret, timeout: const Duration(seconds: 15)),
        exited.future.then<OvpnManagement>((code) =>
            throw OvpnConnectException(OvpnFailure.exited, lastLines.isEmpty ? 'exit code $code' : lastLines)),
      ]);
      _port = m;
      _sub = m.events.listen((e) async {
        switch (e) {
          case OvpnLog(:final message):
            _remember(message);
          case OvpnFatal(:final message):
            _remember(message);
            fail(OvpnConnectException(OvpnFailure.exited, message));
          case OvpnAuthFailed():
            fail(OvpnConnectException(OvpnFailure.authFailed));
          case OvpnNeedsSecret(:final kind):
            if (kind == 'Auth') {
              await m.sendLogin(server.username ?? '', server.password ?? '');
            } else {
              await m.sendKeyPassword(server.keyPassword ?? '');
            }
          case OvpnHold():
            await m.releaseHold();
          case final OvpnState s:
            onState?.call(s);
            if (s.name == 'CONNECTED') {
              if (!done.isCompleted) done.complete(ovpnAdapterName);
            } else if (s.name == 'EXITING') {
              fail(OvpnConnectException(OvpnFailure.exited, s.detail));
            }
          case OvpnBytes():
            break;
        }
      });
      await m.start();
      // The hold line may have come before the listener was there: releasing it again does no harm.
      await m.releaseHold();
      return await done.future.timeout(timeout, onTimeout: () {
        throw OvpnConnectException(OvpnFailure.timeout, lastLines);
      });
    } catch (e) {
      await stop();
      if (e is OvpnConnectException) rethrow;
      throw OvpnConnectException(OvpnFailure.exited, '$e${lastLines.isEmpty ? '' : '\n$lastLines'}');
    }
  }

  /// At the start of the app: ends an OpenVPN that an earlier run of Kumo left behind (it was killed or
  /// crashed) and removes the files it left (they hold the certificates and the login).
  static Future<void> cleanLeftovers(String workDir) async {
    final dir = Directory('$workDir${Platform.pathSeparator}ovpn');
    if (!dir.existsSync()) return;
    final pidFile = File('${dir.path}${Platform.pathSeparator}openvpn.pid');
    if (pidFile.existsSync() && Platform.isWindows) {
      final pid = int.tryParse(pidFile.readAsStringSync().trim());
      if (pid != null) {
        // Only a process that is still an openvpn.exe is ended (the number may have been given again).
        final r = await Process.run('tasklist', ['/FI', 'PID eq $pid', '/FO', 'CSV', '/NH']);
        if ('${r.stdout}'.toLowerCase().contains('openvpn.exe')) {
          await Process.run('taskkill', ['/PID', '$pid', '/F']);
        }
      }
    }
    for (final f in dir.listSync().whereType<File>()) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
  }

  /// Ends the program and removes the files of the run (they hold the certificates and the login).
  Future<void> stop() async {
    _stopping = true;
    await _sub?.cancel();
    _sub = null;
    final port = _port;
    _port = null;
    port?.terminate();
    final process = _process;
    if (process != null) {
      try {
        await process.exitCode.timeout(const Duration(seconds: 4));
      } catch (_) {
        process.kill();
        try {
          await process.exitCode.timeout(const Duration(seconds: 2));
        } catch (_) {}
      }
      _process = null;
    }
    await port?.close();
    for (final f in _files) {
      try {
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
    _files.clear();
  }
}
