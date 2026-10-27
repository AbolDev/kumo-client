import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _ProtectC = Int32 Function(Pointer<Uint8>, Pointer<Utf16>, Pointer<Void>,
    Pointer<Void>, Pointer<Void>, Uint32, Pointer<Uint8>);
typedef _Protect = int Function(Pointer<Uint8>, Pointer<Utf16>, Pointer<Void>,
    Pointer<Void>, Pointer<Void>, int, Pointer<Uint8>);
typedef _UnprotectC = Int32 Function(Pointer<Uint8>, Pointer<Pointer<Utf16>>,
    Pointer<Void>, Pointer<Void>, Pointer<Void>, Uint32, Pointer<Uint8>);
typedef _Unprotect = int Function(Pointer<Uint8>, Pointer<Pointer<Utf16>>,
    Pointer<Void>, Pointer<Void>, Pointer<Void>, int, Pointer<Uint8>);
typedef _FreeC = Pointer<Void> Function(Pointer<Void>);
typedef _Free = Pointer<Void> Function(Pointer<Void>);

/// Windows data protection (DPAPI): text is encrypted with a key that belongs to the signed-in
/// Windows user, so the saved files are unreadable from another account or another computer.
/// Nothing is stored or asked for: Windows keeps the key.
class WinDpapi {
  /// What an encrypted file starts with; a file without it is plain text from an older version.
  static const prefix = 'kumo-dpapi1:';

  static bool isSealed(String text) => text.startsWith(prefix);

  /// The encrypted form of [text], or null when Windows could not do it.
  static String? seal(String text) {
    final bytes = _run(Uint8List.fromList(utf8.encode(text)), protect: true);
    return bytes == null ? null : prefix + base64.encode(bytes);
  }

  /// The text inside [sealed] (which starts with [prefix]), or null when it cannot be opened
  /// (another user's file, damaged).
  static String? open(String sealed) {
    try {
      final data = base64.decode(sealed.substring(prefix.length).trim());
      final bytes = _run(Uint8List.fromList(data), protect: false);
      return bytes == null ? null : utf8.decode(bytes);
    } catch (_) {
      return null;
    }
  }

  // A DATA_BLOB is a 4-byte length, padding, then a pointer: 16 bytes on 64-bit Windows.
  static Uint8List? _run(Uint8List input, {required bool protect}) {
    final crypt = DynamicLibrary.open('crypt32.dll');
    final kernel = DynamicLibrary.open('kernel32.dll');
    final free = kernel.lookupFunction<_FreeC, _Free>('LocalFree');
    final inBlob = calloc<Uint8>(16);
    final outBlob = calloc<Uint8>(16);
    final buffer = calloc<Uint8>(input.isEmpty ? 1 : input.length);
    try {
      buffer.asTypedList(input.length).setAll(0, input);
      inBlob.cast<Uint32>().value = input.length;
      (inBlob + 8).cast<IntPtr>().value = buffer.address;
      final int ok;
      if (protect) {
        ok = crypt.lookupFunction<_ProtectC, _Protect>('CryptProtectData')(
            inBlob, nullptr, nullptr, nullptr, nullptr, 0, outBlob);
      } else {
        ok = crypt.lookupFunction<_UnprotectC, _Unprotect>('CryptUnprotectData')(
            inBlob, nullptr, nullptr, nullptr, nullptr, 0, outBlob);
      }
      if (ok == 0) return null;
      final length = outBlob.cast<Uint32>().value;
      final data = Pointer<Uint8>.fromAddress((outBlob + 8).cast<IntPtr>().value);
      final copy = Uint8List.fromList(data.asTypedList(length));
      free(data.cast());
      return copy;
    } catch (_) {
      return null;
    } finally {
      calloc.free(inBlob);
      calloc.free(outBlob);
      calloc.free(buffer);
    }
  }
}
