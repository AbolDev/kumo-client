// The QR codes of Amnezia's own app. A server is too big for one code, so the app shows a series (an animation): each code
// holds one part, as text in base64url of a Qt data stream, written in this order (big-endian):
//
//   the number 1984 in two bytes (the mark), the count of parts in one byte, the number of this part (from 0) in one byte,
//   the length of the data in four bytes, the data.
//
// The data of all parts, one after the other, is what a `vpn://` link holds after the base64url: the compressed JSON (or the
// JSON itself). Putting the parts together gives that link, and the reader of such links takes it from there (see
// amneziaVpnConfigs in awg.dart).

import 'dart:convert';

class AmneziaQrParts {
  final _parts = <int, List<int>>{};
  int _total = 0;
  DateTime? _at;

  static final _base64Url = RegExp(r'^[A-Za-z0-9_\-+/]+=*$');

  /// What the parts that were read make: null when [text] is not a part of one of Amnezia's series; else how many parts are
  /// in hand of how many, and the `vpn://` link when the last one has just come (the parts are then forgotten). Reading a
  /// part again changes nothing; parts that come more than ten minutes after the last one, or of a series of another size,
  /// start a new series.
  ({int have, int total, String? link})? feed(String text, {DateTime? now}) {
    final part = _decode(text);
    if (part == null) return null;
    final at = now ?? DateTime.now();
    if (_total != part.count || (_at != null && at.difference(_at!) > const Duration(minutes: 10))) {
      _parts.clear();
    }
    _total = part.count;
    _at = at;
    _parts[part.index] = part.data;
    if (_parts.length < _total) return (have: _parts.length, total: _total, link: null);
    final all = <int>[for (var i = 0; i < _total; i++) ..._parts[i]!];
    _parts.clear();
    return (have: _total, total: _total, link: 'vpn://${base64Url.encode(all).replaceAll('=', '')}');
  }

  void clear() {
    _parts.clear();
    _total = 0;
    _at = null;
  }

  static ({int count, int index, List<int> data})? _decode(String text) {
    final s = text.trim();
    if (s.length < 12 || s.length > 4000 || !_base64Url.hasMatch(s)) return null;
    final List<int> b;
    try {
      b = base64.decode(base64.normalize(s.replaceAll('-', '+').replaceAll('_', '/')));
    } catch (_) {
      return null;
    }
    if (b.length < 8 || b[0] != 0x07 || b[1] != 0xC0) return null;
    final count = b[2];
    final index = b[3];
    final length = (b[4] << 24) | (b[5] << 16) | (b[6] << 8) | b[7];
    if (count < 1 || index >= count || length != b.length - 8) return null;
    return (count: count, index: index, data: b.sublist(8));
  }
}

/// The parts read so far, whatever the way they were read (the camera, a picture, the screen).
final amneziaQrParts = AmneziaQrParts();
