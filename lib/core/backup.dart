import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Backup files are JSON. With a password the payload is encrypted with AES-256-GCM, the key
/// coming from PBKDF2-HMAC-SHA256 of the password.
const _iterations = 60000;

Uint8List _randomBytes(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

Uint8List _deriveKey(String password, Uint8List salt) {
  final pbkdf2 = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(salt, _iterations, 32));
  return pbkdf2.process(Uint8List.fromList(utf8.encode(password)));
}

Uint8List _gcm(bool encrypt, Uint8List key, Uint8List nonce, Uint8List data) {
  final cipher = GCMBlockCipher(AESEngine())
    ..init(encrypt, AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));
  return cipher.process(data);
}

/// Wraps [payload] (any JSON text) into a backup file text.
Future<String> sealBackup(String payload, String password) {
  if (password.isEmpty) {
    return Future.value(jsonEncode({'kumo-backup': 1, 'plain': payload}));
  }
  return Isolate.run(() {
    final salt = _randomBytes(16), nonce = _randomBytes(12);
    final sealed = _gcm(true, _deriveKey(password, salt), nonce,
        Uint8List.fromList(utf8.encode(payload)));
    return jsonEncode({
      'kumo-backup': 1,
      'salt': base64.encode(salt),
      'nonce': base64.encode(nonce),
      'data': base64.encode(sealed),
    });
  });
}

/// True when [text] is a backup file made by [sealBackup].
bool isBackup(String text) {
  try {
    return (jsonDecode(text) as Map)['kumo-backup'] != null;
  } catch (_) {
    return false;
  }
}

/// True when the backup needs a password.
bool backupIsEncrypted(String text) =>
    (jsonDecode(text) as Map).containsKey('data');

/// Returns the payload, or null when the password is wrong or the file is damaged.
Future<String?> openBackup(String text, String password) async {
  try {
    final j = jsonDecode(text) as Map<String, dynamic>;
    if (j['plain'] is String) return j['plain'] as String;
    final salt = base64.decode(j['salt'] as String);
    final nonce = base64.decode(j['nonce'] as String);
    final data = base64.decode(j['data'] as String);
    return await Isolate.run(() => utf8.decode(
        _gcm(false, _deriveKey(password, Uint8List.fromList(salt)),
            Uint8List.fromList(nonce), Uint8List.fromList(data))));
  } catch (_) {
    return null;
  }
}
