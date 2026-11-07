import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart' show ThemeMode;

/// Makes the Windows menus of this app (the tray icon's menu) dark or light with the app's
/// theme. Win32 menus are always light unless the app asks otherwise, through two functions of
/// uxtheme.dll that have only an ordinal (Windows 10 1903 and later; Notepad++ and others use
/// them too): SetPreferredAppMode (135) and FlushMenuThemes (136).
class WinMenuTheme {
  static ThemeMode? _applied;

  static void apply(ThemeMode mode) {
    if (_applied == mode) return;
    _applied = mode;
    try {
      final kernel = DynamicLibrary.open('kernel32.dll');
      final load =
          kernel.lookupFunction<IntPtr Function(Pointer<Utf16>), int Function(Pointer<Utf16>)>(
              'LoadLibraryW');
      final proc = kernel.lookupFunction<IntPtr Function(IntPtr, IntPtr), int Function(int, int)>(
          'GetProcAddress');
      final name = 'uxtheme.dll'.toNativeUtf16();
      final module = load(name);
      calloc.free(name);
      if (module == 0) return;
      final setMode = proc(module, 135);
      final flush = proc(module, 136);
      if (setMode == 0) return;
      // 1 follows Windows' own app mode, 2 always dark, 3 always light.
      final value =
          switch (mode) { ThemeMode.dark => 2, ThemeMode.light => 3, ThemeMode.system => 1 };
      Pointer<NativeFunction<Int32 Function(Int32)>>.fromAddress(setMode)
          .asFunction<int Function(int)>()(value);
      if (flush != 0) {
        Pointer<NativeFunction<Void Function()>>.fromAddress(flush).asFunction<void Function()>()();
      }
    } catch (_) {
      // an older Windows: the menu stays light
    }
  }
}
