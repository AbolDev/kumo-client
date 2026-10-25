import 'dart:ffi';

import 'package:ffi/ffi.dart';

typedef _CreateJobC = Pointer<Void> Function(Pointer<Void>, Pointer<Utf16>);
typedef _CreateJob = Pointer<Void> Function(Pointer<Void>, Pointer<Utf16>);
typedef _SetInfoC = Int32 Function(Pointer<Void>, Int32, Pointer<Void>, Uint32);
typedef _SetInfo = int Function(Pointer<Void>, int, Pointer<Void>, int);
typedef _OpenProcessC = Pointer<Void> Function(Uint32, Int32, Uint32);
typedef _OpenProcess = Pointer<Void> Function(int, int, int);
typedef _AssignC = Int32 Function(Pointer<Void>, Pointer<Void>);
typedef _Assign = int Function(Pointer<Void>, Pointer<Void>);
typedef _CloseC = Int32 Function(Pointer<Void>);
typedef _Close = int Function(Pointer<Void>);

/// A Windows job object that kills every process put into it when this app ends, however it
/// ends (closed, crashed, killed). Without it the VPN core would keep the tunnel up on its own.
class WinJob {
  static Pointer<Void>? _job;
  static bool _failed = false;

  static void add(int pid) {
    if (_failed) return;
    try {
      final kernel = DynamicLibrary.open('kernel32.dll');
      _job ??= _create(kernel);
      final job = _job;
      if (job == null) {
        _failed = true;
        return;
      }
      final open = kernel.lookupFunction<_OpenProcessC, _OpenProcess>('OpenProcess');
      final assign =
          kernel.lookupFunction<_AssignC, _Assign>('AssignProcessToJobObject');
      final close = kernel.lookupFunction<_CloseC, _Close>('CloseHandle');
      // PROCESS_SET_QUOTA | PROCESS_TERMINATE
      final process = open(0x0101, 0, pid);
      if (process.address == 0) return;
      assign(job, process);
      close(process);
    } catch (_) {
      _failed = true;
    }
  }

  static Pointer<Void>? _create(DynamicLibrary kernel) {
    final create = kernel.lookupFunction<_CreateJobC, _CreateJob>('CreateJobObjectW');
    final setInfo =
        kernel.lookupFunction<_SetInfoC, _SetInfo>('SetInformationJobObject');
    final job = create(nullptr, nullptr);
    if (job.address == 0) return null;
    // JOBOBJECT_EXTENDED_LIMIT_INFORMATION (144 bytes on 64-bit): LimitFlags sits at offset 16.
    final info = calloc<Uint8>(144);
    try {
      (info + 16).cast<Uint32>().value = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
      // JobObjectExtendedLimitInformation = 9
      if (setInfo(job, 9, info.cast(), 144) == 0) return null;
    } finally {
      calloc.free(info);
    }
    return job;
  }
}
