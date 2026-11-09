import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// Values under HKEY_CURRENT_USER read and written through the Windows API, without starting a
/// reg.exe process for each (which takes from a few milliseconds to a second, with an antivirus
/// that looks at every new process). Values come back the way `reg query` prints them: a string
/// as it is, a DWORD as `0x` and hex. Throws when the API cannot be used, so the caller can fall
/// back to reg.exe.
class WinRegistry {
  WinRegistry._();

  static const _errorNotFound = 2;
  static const _keyQueryValue = 0x0001, _keySetValue = 0x0002, _keyRead = 0x20019;
  static const _regSz = 1, _regExpandSz = 2, _regDword = 4;

  // HKEY_CURRENT_USER is (HKEY)(LONG)0x80000001: sign-extended where pointers are 64 bits.
  static Pointer<Void> get _hkcu =>
      Pointer<Void>.fromAddress(sizeOf<IntPtr>() == 8 ? -0x7fffffff : 0x80000001);

  static final _advapi = DynamicLibrary.open('advapi32.dll');

  static final _create = _advapi.lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Utf16>, Uint32, Pointer<Utf16>, Uint32, Uint32, Pointer<Void>,
          Pointer<Pointer<Void>>, Pointer<Uint32>),
      int Function(Pointer<Void>, Pointer<Utf16>, int, Pointer<Utf16>, int, int, Pointer<Void>,
          Pointer<Pointer<Void>>, Pointer<Uint32>)>('RegCreateKeyExW');
  static final _open = _advapi.lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Utf16>, Uint32, Uint32, Pointer<Pointer<Void>>),
      int Function(Pointer<Void>, Pointer<Utf16>, int, int, Pointer<Pointer<Void>>)>('RegOpenKeyExW');
  static final _query = _advapi.lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Utf16>, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint8>, Pointer<Uint32>),
      int Function(Pointer<Void>, Pointer<Utf16>, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint8>,
          Pointer<Uint32>)>('RegQueryValueExW');
  static final _set = _advapi.lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Utf16>, Uint32, Uint32, Pointer<Uint8>, Uint32),
      int Function(Pointer<Void>, Pointer<Utf16>, int, int, Pointer<Uint8>, int)>('RegSetValueExW');
  static final _delete = _advapi.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Utf16>),
      int Function(Pointer<Void>, Pointer<Utf16>)>('RegDeleteValueW');
  static final _close =
      _advapi.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('RegCloseKey');

  /// Opens [subKey] of HKEY_CURRENT_USER (made when [write] and missing), runs [body] and closes it.
  static T _with<T>(String subKey, bool write, T Function(Pointer<Void> key, Arena arena) body) =>
      using((arena) {
        final out = arena<Pointer<Void>>();
        final path = subKey.toNativeUtf16(allocator: arena);
        final rc = write
            ? _create(_hkcu, path, 0, nullptr, 0, _keySetValue | _keyQueryValue, nullptr, out, nullptr)
            : _open(_hkcu, path, 0, _keyRead, out);
        if (rc != 0) throw WindowsRegistryException('open', rc);
        try {
          return body(out.value, arena);
        } finally {
          _close(out.value);
        }
      });

  /// The value [name] of [subKey], or null when it is not there.
  static String? read(String subKey, String name) {
    try {
      return _with(subKey, false, (key, arena) {
        final n = name.toNativeUtf16(allocator: arena);
        final type = arena<Uint32>();
        final size = arena<Uint32>();
        var rc = _query(key, n, nullptr, type, nullptr, size);
        if (rc == _errorNotFound) return null;
        if (rc != 0) throw WindowsRegistryException('query', rc);
        final data = arena<Uint8>(size.value + 2);
        rc = _query(key, n, nullptr, type, data, size);
        if (rc != 0) throw WindowsRegistryException('query', rc);
        switch (type.value) {
          case _regDword:
            return '0x${data.cast<Uint32>().value.toRadixString(16)}';
          case _regSz:
          case _regExpandSz:
            final units = data.cast<Uint16>().asTypedList(size.value ~/ 2);
            final end = units.indexOf(0);
            return String.fromCharCodes(end < 0 ? units : units.sublist(0, end));
          default:
            throw WindowsRegistryException('type ${type.value}', 0);
        }
      });
    } on WindowsRegistryException catch (e) {
      // A key that is not there holds no values.
      if (e.op == 'open' && e.code == _errorNotFound) return null;
      rethrow;
    }
  }

  /// Writes [value] to [name] of [subKey] as a string, or deletes it when [value] is null.
  static void writeString(String subKey, String name, String? value) {
    _with(subKey, true, (key, arena) {
      final n = name.toNativeUtf16(allocator: arena);
      if (value == null) {
        final rc = _delete(key, n);
        if (rc != 0 && rc != _errorNotFound) throw WindowsRegistryException('delete', rc);
        return;
      }
      final units = value.codeUnits;
      final data = arena<Uint16>(units.length + 1);
      data.asTypedList(units.length + 1)
        ..setAll(0, units)
        ..[units.length] = 0;
      final rc = _set(key, n, 0, _regSz, data.cast<Uint8>(), (units.length + 1) * 2);
      if (rc != 0) throw WindowsRegistryException('set', rc);
    });
  }

  /// Writes [value] to [name] of [subKey] as a DWORD.
  static void writeDword(String subKey, String name, int value) {
    _with(subKey, true, (key, arena) {
      final n = name.toNativeUtf16(allocator: arena);
      final data = arena<Uint32>()..value = value;
      final rc = _set(key, n, 0, _regDword, data.cast<Uint8>(), 4);
      if (rc != 0) throw WindowsRegistryException('set', rc);
    });
  }
}

class WindowsRegistryException implements Exception {
  WindowsRegistryException(this.op, this.code);
  final String op;
  final int code;

  @override
  String toString() => 'registry $op failed ($code)';
}
