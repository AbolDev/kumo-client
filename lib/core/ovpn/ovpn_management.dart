import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// What the OpenVPN program tells over its management port (a text protocol on a local TCP port that
/// only Kumo knows the password of).
sealed class OvpnEvent {
  const OvpnEvent();
}

/// `>STATE:` — [name] is CONNECTING, WAIT, AUTH, GET_CONFIG, ASSIGN_IP, ADD_ROUTES, CONNECTED,
/// RECONNECTING, EXITING, RESOLVE or TCP_CONNECT; [detail] the reason (SUCCESS, auth-failure ...).
class OvpnState extends OvpnEvent {
  const OvpnState(this.name, this.detail, this.localIp, this.remoteIp);
  final String name;
  final String detail;
  final String localIp;
  final String remoteIp;
}

/// `>PASSWORD:Need 'Auth' username/password` or `Need 'Private Key' password`.
class OvpnNeedsSecret extends OvpnEvent {
  const OvpnNeedsSecret(this.kind);

  /// `Auth` (user name and password) or `Private Key`.
  final String kind;
}

/// `>PASSWORD:Verification Failed: 'Auth'` — the server did not take the login.
class OvpnAuthFailed extends OvpnEvent {
  const OvpnAuthFailed(this.kind);
  final String kind;
}

class OvpnLog extends OvpnEvent {
  const OvpnLog(this.message);
  final String message;
}

/// `>FATAL:` — OpenVPN is stopping because of [message].
class OvpnFatal extends OvpnEvent {
  const OvpnFatal(this.message);
  final String message;
}

/// `>BYTECOUNT:in,out`.
class OvpnBytes extends OvpnEvent {
  const OvpnBytes(this.received, this.sent);
  final int received;
  final int sent;
}

/// `>HOLD:` — OpenVPN waits for [OvpnManagement.releaseHold].
class OvpnHold extends OvpnEvent {
  const OvpnHold();
}

/// One line of the management protocol, as an event (null for the lines that are only answers).
OvpnEvent? parseOvpnLine(String line) {
  if (!line.startsWith('>')) return null;
  final colon = line.indexOf(':');
  if (colon < 0) return null;
  final kind = line.substring(1, colon);
  final rest = line.substring(colon + 1);
  switch (kind) {
    case 'STATE':
      final p = rest.split(',');
      if (p.length < 3) return null;
      return OvpnState(p[1], p[2], p.length > 3 ? p[3] : '', p.length > 4 ? p[4] : '');
    case 'PASSWORD':
      final need = RegExp(r"^Need '([^']+)'").firstMatch(rest);
      if (need != null) return OvpnNeedsSecret(need[1]!);
      final failed = RegExp(r"^Verification Failed: '([^']+)'").firstMatch(rest);
      if (failed != null) return OvpnAuthFailed(failed[1]!);
      return null;
    case 'LOG':
      // time,flags,message
      final p = rest.split(',');
      return OvpnLog(p.length > 2 ? p.sublist(2).join(',') : rest);
    case 'FATAL':
      return OvpnFatal(rest);
    case 'BYTECOUNT':
      final p = rest.split(',');
      if (p.length < 2) return null;
      final a = int.tryParse(p[0]), b = int.tryParse(p[1]);
      return a == null || b == null ? null : OvpnBytes(a, b);
    case 'HOLD':
      return const OvpnHold();
  }
  return null;
}

/// A word written for a management command: in double quotes, with `\` and `"` escaped. A line break
/// would end the command and start another one, so it is refused.
String ovpnQuote(String s) {
  if (s.contains('\n') || s.contains('\r') || s.contains('\u0000')) {
    throw ArgumentError('a line break cannot be part of a login');
  }
  return '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
}

/// The client of the management port.
class OvpnManagement {
  OvpnManagement._(this._socket) {
    _socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .listen(_onData, onDone: _done, onError: (_) => _done(), cancelOnError: true);
  }

  var _buffer = '';

  /// The text that comes in is cut into lines by hand: OpenVPN asks for the password with
  /// ENTER PASSWORD: and no line break after it.
  void _onData(String chunk) {
    _buffer += chunk;
    if (!_authenticated && _buffer.contains('ENTER PASSWORD:')) {
      _buffer = _buffer.replaceFirst('ENTER PASSWORD:', '');
      _login?.complete();
    }
    while (true) {
      final i = _buffer.indexOf('\n');
      if (i < 0) break;
      final line = _buffer.substring(0, i);
      _buffer = _buffer.substring(i + 1);
      _onLine(line);
    }
  }

  final Socket _socket;
  final _events = StreamController<OvpnEvent>.broadcast();
  final _answers = <Completer<String>>[];
  var _authenticated = false;
  Completer<void>? _login;

  Stream<OvpnEvent> get events => _events.stream;
  bool get closed => _closed;
  var _closed = false;

  /// Connects to the port and gives the password; completes when OpenVPN took it.
  static Future<OvpnManagement> connect(int port, String password,
      {Duration timeout = const Duration(seconds: 10)}) async {
    final end = DateTime.now().add(timeout);
    Object? last;
    while (DateTime.now().isBefore(end)) {
      try {
        final socket = await Socket.connect(InternetAddress.loopbackIPv4, port,
            timeout: const Duration(seconds: 2));
        final m = OvpnManagement._(socket);
        m._login = Completer<void>();
        await m._login!.future.timeout(const Duration(seconds: 5));
        if (!await m._authenticate(password)) {
          await m.close();
          throw const SocketException('the management port did not take the password');
        }
        return m;
      } catch (e) {
        last = e;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    throw SocketException('the management port did not answer: $last');
  }

  void _onLine(String raw) {
    final line = raw.trimRight();
    if (!_authenticated) {
      if (line.startsWith('SUCCESS: password is correct')) {
        _authenticated = true;
        _passwordAnswer?.complete(true);
        return;
      }
      if (line.startsWith('FAILURE')) {
        _passwordAnswer?.complete(false);
        return;
      }
    }
    final event = parseOvpnLine(line);
    if (event != null) {
      _events.add(event);
      return;
    }
    // An answer to a command: SUCCESS: / ERROR: / the lines of a list, then END.
    if (line.startsWith('SUCCESS:') || line.startsWith('ERROR:') || line == 'END') {
      if (_answers.isNotEmpty) _answers.removeAt(0).complete(line);
    }
  }

  Completer<bool>? _passwordAnswer;

  /// Sends the password of the port. False when OpenVPN did not accept it.
  Future<bool> _authenticate(String password) async {
    _passwordAnswer = Completer<bool>();
    _socket.write('$password\n');
    return _passwordAnswer!.future.timeout(const Duration(seconds: 5), onTimeout: () => false);
  }

  Future<String> _send(String command) {
    final c = Completer<String>();
    _answers.add(c);
    _socket.write('$command\n');
    return c.future.timeout(const Duration(seconds: 5), onTimeout: () => 'ERROR: no answer');
  }

  Future<void> start() async {
    await _send('state on');
    await _send('bytecount 1');
    await _send('log on');
  }

  Future<void> releaseHold() => _send('hold release');

  /// Gives the user name and password the server asked for.
  Future<void> sendLogin(String user, String password) async {
    await _send('username ${ovpnQuote('Auth')} ${ovpnQuote(user)}');
    await _send('password ${ovpnQuote('Auth')} ${ovpnQuote(password)}');
  }

  Future<void> sendKeyPassword(String password) =>
      _send('password ${ovpnQuote('Private Key')} ${ovpnQuote(password)}');

  /// Asks OpenVPN to end (it closes the tunnel and its adapter state itself).
  void terminate() {
    if (_closed) return;
    try {
      _socket.write('signal SIGTERM\n');
    } catch (_) {}
  }

  void _done() {
    if (_closed) return;
    _closed = true;
    for (final a in _answers) {
      if (!a.isCompleted) a.complete('ERROR: closed');
    }
    _answers.clear();
    if (!_events.isClosed) _events.close();
  }

  Future<void> close() async {
    _done();
    try {
      await _socket.close();
    } catch (_) {}
    _socket.destroy();
  }
}
