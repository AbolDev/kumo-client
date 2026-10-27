import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _CreateMutexC = Pointer<Void> Function(Pointer<Void>, Int32, Pointer<Utf16>);
typedef _CreateMutex = Pointer<Void> Function(Pointer<Void>, int, Pointer<Utf16>);
typedef _OpenMutexC = Pointer<Void> Function(Uint32, Int32, Pointer<Utf16>);
typedef _OpenMutex = Pointer<Void> Function(int, int, Pointer<Utf16>);
typedef _CloseHandleC = Int32 Function(Pointer<Void>);
typedef _CloseHandle = int Function(Pointer<Void>);
typedef _FindWindowExC = Pointer<Void> Function(
    Pointer<Void>, Pointer<Void>, Pointer<Utf16>, Pointer<Utf16>);
typedef _FindWindowEx = Pointer<Void> Function(
    Pointer<Void>, Pointer<Void>, Pointer<Utf16>, Pointer<Utf16>);
typedef _ThreadProcessC = Uint32 Function(Pointer<Void>, Pointer<Uint32>);
typedef _ThreadProcess = int Function(Pointer<Void>, Pointer<Uint32>);
typedef _ShowWindowC = Int32 Function(Pointer<Void>, Int32);
typedef _ShowWindow = int Function(Pointer<Void>, int);
typedef _ForegroundC = Int32 Function(Pointer<Void>);
typedef _Foreground = int Function(Pointer<Void>);

/// Only one copy of the app may run per user: a second one would stop the first one's cores (they
/// have the same names) and fight over the proxy port and the system proxy setting.
class SingleInstance {
  // Kept for the life of the process: the lock goes away when the process does.
  static Pointer<Void>? _mutex;
  static RandomAccessFile? _lock;

  /// Whether this copy holds the single-instance lock.
  static bool get held => _mutex != null || _lock != null;

  /// True when this is the only copy. False when another one runs; it is brought to the front
  /// where the system allows, and this one should end.
  static Future<bool> acquire(String dataDir) async {
    try {
      return Platform.isWindows ? _windows() : await _posix(dataDir);
    } catch (_) {
      // If the check itself fails the app still starts, as it always did.
      return true;
    }
  }

  static bool _windows() {
    final kernel = DynamicLibrary.open('kernel32.dll');
    final name = r'Local\KumoVpnClient'.toNativeUtf16();
    try {
      // GetLastError is not reliable after an FFI call, so the name is looked for first.
      const synchronize = 0x00100000;
      final existing =
          kernel.lookupFunction<_OpenMutexC, _OpenMutex>('OpenMutexW')(synchronize, 0, name);
      if (existing.address != 0) {
        kernel.lookupFunction<_CloseHandleC, _CloseHandle>('CloseHandle')(existing);
        _showRunning();
        return false;
      }
      final handle =
          kernel.lookupFunction<_CreateMutexC, _CreateMutex>('CreateMutexW')(nullptr, 0, name);
      if (handle.address != 0) _mutex = handle;
      return true;
    } finally {
      calloc.free(name);
    }
  }

  /// The window of the copy that already runs, shown even if it was hidden in the tray.
  static void _showRunning() {
    final user = DynamicLibrary.open('user32.dll');
    final findEx = user.lookupFunction<_FindWindowExC, _FindWindowEx>('FindWindowExW');
    final threadProcess =
        user.lookupFunction<_ThreadProcessC, _ThreadProcess>('GetWindowThreadProcessId');
    final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    final processId = calloc<Uint32>();
    try {
      // This copy has a window of its own already (the runner makes it before the app starts):
      // the one to show is the window of another process.
      var window = findEx(nullptr, nullptr, cls, nullptr);
      for (var i = 0; i < 20 && window.address != 0; i++) {
        threadProcess(window, processId);
        if (processId.value != pid) {
          user.lookupFunction<_ShowWindowC, _ShowWindow>('ShowWindow')(window, 9); // SW_RESTORE
          user.lookupFunction<_ForegroundC, _Foreground>('SetForegroundWindow')(window);
          return;
        }
        window = findEx(nullptr, window, cls, nullptr);
      }
    } finally {
      calloc.free(cls);
      calloc.free(processId);
    }
  }

  static Future<bool> _posix(String dataDir) async {
    await Directory(dataDir).create(recursive: true);
    final file = await File('$dataDir/kumo.lock').open(mode: FileMode.write);
    try {
      // The non-blocking exclusive lock fails at once when another copy holds it.
      await file.lock(FileLock.exclusive);
    } on FileSystemException {
      await file.close();
      return false;
    }
    _lock = file;
    return true;
  }
}
