import 'dart:async';
import 'dart:io';
import 'dart:math' show Random;
import 'dart:typed_data';

/// Asks a STUN server which public address it sees for a UDP packet from this device: the same
/// question a browser asks for WebRTC. Returns null when there is no answer (for example when
/// STUN is blocked, which is what the "block WebRTC" option does).
Future<String?> stunAddress({
  String host = 'stun.l.google.com',
  int port = 19302,
  Duration timeout = const Duration(seconds: 4),
}) async {
  RawDatagramSocket? socket;
  try {
    final target = (await InternetAddress.lookup(host, type: InternetAddressType.IPv4))
        .firstOrNull;
    if (target == null) return null;
    socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final id = Uint8List.fromList(List.generate(12, (_) => Random.secure().nextInt(256)));
    final request = Uint8List(20)
      ..buffer.asByteData().setUint16(0, 0x0001) // binding request
      ..buffer.asByteData().setUint32(4, 0x2112A442); // magic cookie
    request.setRange(8, 20, id);
    socket.send(request, target, port);
    final done = Completer<String?>();
    final sub = socket.listen((event) {
      if (event != RawSocketEvent.read || done.isCompleted) return;
      final packet = socket!.receive();
      if (packet != null) done.complete(parseStunResponse(packet.data, id));
    });
    final result = await done.future.timeout(timeout, onTimeout: () => null);
    await sub.cancel();
    return result;
  } catch (_) {
    return null;
  } finally {
    socket?.close();
  }
}

/// Reads the (XOR-)mapped address out of a STUN binding response for the request [id].
String? parseStunResponse(Uint8List data, Uint8List id) {
  if (data.length < 20) return null;
  final view = data.buffer.asByteData(data.offsetInBytes, data.length);
  if (view.getUint16(0) != 0x0101 || view.getUint32(4) != 0x2112A442) return null;
  for (var i = 0; i < 12; i++) {
    if (data[8 + i] != id[i]) return null;
  }
  final end = 20 + view.getUint16(2);
  var at = 20;
  while (at + 4 <= end && at + 4 <= data.length) {
    final type = view.getUint16(at);
    final length = view.getUint16(at + 2);
    final body = at + 4;
    if (body + length > data.length) return null;
    // 0x0020 XOR-MAPPED-ADDRESS, 0x0001 MAPPED-ADDRESS; both carry an IPv4 address here
    if ((type == 0x0020 || type == 0x0001) && length >= 8 && data[body + 1] == 0x01) {
      final xor = type == 0x0020;
      final cookie = [0x21, 0x12, 0xA4, 0x42];
      return [
        for (var k = 0; k < 4; k++) data[body + 4 + k] ^ (xor ? cookie[k] : 0),
      ].join('.');
    }
    at = body + length + (4 - length % 4) % 4;
  }
  return null;
}
