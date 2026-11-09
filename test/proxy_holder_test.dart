import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/proxy_holder.dart';

/// A server that answers each line with its name, a colon and the line.
Future<ServerSocket> _echo(String name) async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  s.listen((c) {
    c.cast<List<int>>().transform(utf8.decoder).listen((t) => c.write('$name:$t'), onDone: c.destroy, onError: (_) {});
  });
  return s;
}

Future<int> _free() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  await s.close();
  return p;
}

Future<String> _ask(int port, String text) async {
  final c = await Socket.connect(InternetAddress.loopbackIPv4, port);
  c.write(text);
  final answer = await c.cast<List<int>>().transform(utf8.decoder).first.timeout(const Duration(seconds: 10));
  c.destroy();
  return answer;
}

void main() {
  test('a connection is carried to the core that is routed', () async {
    final holder = ProxyHolder();
    final port = await _free();
    final a = await _echo('a');
    expect(await holder.bind(port, '127.0.0.1'), isTrue);
    holder.route(port, a.port);
    expect(await _ask(port, 'hi'), 'a:hi');
    await holder.release();
    await a.close();
  });

  test('the port stays open while there is no core, and the connection waits for the next one', () async {
    final holder = ProxyHolder();
    final port = await _free();
    final a = await _echo('a');
    await holder.bind(port, '127.0.0.1');
    holder.route(port, a.port);
    expect(await _ask(port, '1'), 'a:1');

    // The core goes: the port is still there and a connection waits.
    holder.unroute(port, a.port);
    await a.close();
    final waiting = _ask(port, '2');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final b = await _echo('b');
    holder.route(port, b.port);
    expect(await waiting, 'b:2');
    await holder.release();
    await b.close();
  });

  test('a core that is unrouted late does not take away the next one', () async {
    final holder = ProxyHolder();
    final port = await _free();
    final a = await _echo('a');
    final b = await _echo('b');
    await holder.bind(port, '127.0.0.1');
    holder.route(port, a.port);
    holder.route(port, b.port);
    holder.unroute(port, a.port);
    expect(await _ask(port, 'x'), 'b:x');
    await holder.release();
    await a.close();
    await b.close();
  });

  test('a connection that waits too long is closed', () async {
    final holder = ProxyHolder(patience: const Duration(milliseconds: 300));
    final port = await _free();
    await holder.bind(port, '127.0.0.1');
    final c = await Socket.connect(InternetAddress.loopbackIPv4, port);
    final done = await c.cast<List<int>>().toList().timeout(const Duration(seconds: 5));
    expect(done, isEmpty);
    await holder.release();
  });

  test('a port that another program holds is not held', () async {
    final taken = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    expect(await ProxyHolder().bind(taken.port, '127.0.0.1'), isFalse);
    await taken.close();
  });

  test('after the release the port is free again', () async {
    final holder = ProxyHolder();
    final port = await _free();
    await holder.bind(port, '127.0.0.1');
    await holder.release();
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    await s.close();
  });
}
