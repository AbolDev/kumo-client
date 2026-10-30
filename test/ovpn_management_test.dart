import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/ovpn/ovpn_management.dart';

/// A stand-in for the management port of OpenVPN: it asks for the password the way OpenVPN does (no
/// line break after the question) and answers the commands.
class _FakePort {
  _FakePort(this.password);

  final String password;
  late final ServerSocket server;
  Socket? client;
  final commands = <String>[];

  Future<void> start() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((s) {
      client = s;
      s.write('ENTER PASSWORD:');
      var authenticated = false;
      s.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        if (!authenticated) {
          if (line == password) {
            authenticated = true;
            s.write('SUCCESS: password is correct\r\n');
            s.write(">INFO:OpenVPN Management Interface Version 5 -- type 'help' for more info\r\n");
            s.write('>HOLD:Waiting for hold release:0\r\n');
          } else {
            s.write('FAILURE: bad password\r\n');
          }
          return;
        }
        commands.add(line);
        s.write('SUCCESS: ok\r\n');
      });
    });
  }

  int get port => server.port;

  void send(String text) => client!.write('$text\r\n');

  Future<void> stop() async {
    client?.destroy();
    await server.close();
  }
}

void main() {
  group('the lines of the protocol', () {
    test('states', () {
      final e = parseOvpnLine('>STATE:1700000000,CONNECTED,SUCCESS,10.8.0.6,203.0.113.5,1194,,') as OvpnState;
      expect((e.name, e.detail, e.localIp, e.remoteIp), ('CONNECTED', 'SUCCESS', '10.8.0.6', '203.0.113.5'));
      expect((parseOvpnLine('>STATE:1,AUTH,,,,,,') as OvpnState).name, 'AUTH');
      expect(parseOvpnLine('>STATE:1'), isNull);
    });

    test('the login that is asked for, and that failed', () {
      expect((parseOvpnLine(">PASSWORD:Need 'Auth' username/password") as OvpnNeedsSecret).kind, 'Auth');
      expect((parseOvpnLine(">PASSWORD:Need 'Private Key' password") as OvpnNeedsSecret).kind, 'Private Key');
      expect((parseOvpnLine(">PASSWORD:Verification Failed: 'Auth'") as OvpnAuthFailed).kind, 'Auth');
    });

    test('log, fatal, bytes and hold', () {
      expect((parseOvpnLine('>LOG:1700000000,I,TLS: Initial packet from [AF_INET]1.2.3.4:1194, sid=ab,cd') as OvpnLog).message,
          'TLS: Initial packet from [AF_INET]1.2.3.4:1194, sid=ab,cd');
      expect((parseOvpnLine('>FATAL:Cannot open TUN/TAP dev') as OvpnFatal).message, 'Cannot open TUN/TAP dev');
      final b = parseOvpnLine('>BYTECOUNT:1024,2048') as OvpnBytes;
      expect((b.received, b.sent), (1024, 2048));
      expect(parseOvpnLine('>HOLD:Waiting for hold release:0'), isA<OvpnHold>());
    });

    test('answers and other lines are not events', () {
      expect(parseOvpnLine('SUCCESS: ok'), isNull);
      expect(parseOvpnLine('>INFO:hello'), isNull);
      expect(parseOvpnLine('plain'), isNull);
    });

    test('a word is quoted, and a line break is refused', () {
      expect(ovpnQuote('a"b\\c'), r'"a\"b\\c"');
      expect(() => ovpnQuote('a\nusername "Auth" "x"'), throwsArgumentError);
      expect(() => ovpnQuote('a\r'), throwsArgumentError);
    });
  });

  group('the port', () {
    test('takes the password, passes the events and sends the commands', () async {
      final port = _FakePort('s3cret');
      await port.start();
      final m = await OvpnManagement.connect(port.port, 's3cret');
      final seen = <OvpnEvent>[];
      m.events.listen(seen.add);
      await m.start();
      port.send('>STATE:1,CONNECTING,,,,,,');
      port.send('>BYTECOUNT:5,6');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(seen.whereType<OvpnState>().single.name, 'CONNECTING');
      expect(seen.whereType<OvpnBytes>().single.sent, 6);
      await m.sendLogin('al"ice', r'p\w');
      await m.releaseHold();
      expect(port.commands, [
        'state on',
        'bytecount 1',
        'log on',
        r'username "Auth" "al\"ice"',
        r'password "Auth" "p\\w"',
        'hold release',
      ]);
      await m.close();
      await port.stop();
    });

    test('is refused with a wrong password', () async {
      final port = _FakePort('s3cret');
      await port.start();
      await expectLater(OvpnManagement.connect(port.port, 'wrong', timeout: const Duration(seconds: 3)),
          throwsA(isA<SocketException>()));
      await port.stop();
    });

    test('a port nobody listens on is an error, not a hang', () async {
      final tmp = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final free = tmp.port;
      await tmp.close();
      await expectLater(
          OvpnManagement.connect(free, 'x', timeout: const Duration(seconds: 1)), throwsA(isA<SocketException>()));
    });
  });
}
