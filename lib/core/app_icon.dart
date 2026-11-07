import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';

/// The app icon the user picks in Settings (drawn by tools/make_app_icons.py).
///
/// On Android each icon is a launcher entry of its own (see AppIcons.kt). On Windows the
/// program file keeps the default icon; the window, the taskbar button, the tray and the
/// Start menu and desktop shortcuts take the chosen one.
class AppIcon {
  static const defaultId = 'teal_night';

  /// In the app's teal, then the first set in other colours, then the icon Kumo had before.
  static const groups = <List<String>>[
    ['teal_night', 'teal', 'teal_light', 'teal_solid', 'teal_blue', 'mint'],
    ['blue', 'sunset', 'emerald', 'vivid', 'navy', 'gold'],
    ['classic'],
  ];

  static final ids = [for (final g in groups) ...g];

  static bool get supported => Platform.isAndroid || Platform.isWindows;

  /// The picture shown in the picker.
  static String preview(String id) => 'assets/app_icons/$id.png';

  static String normalize(String? id) => ids.contains(id) ? id! : defaultId;

  static const _control = MethodChannel('kumo/control');

  /// Shows [id] where the system takes the app's icon from. [shortcuts] also changes the Windows
  /// shortcuts (only when the user picks an icon or the installer may have put back the default).
  static Future<void> apply(String id, {bool shortcuts = true}) async {
    id = normalize(id);
    if (Platform.isAndroid) {
      await _control.invokeMethod('setAppIcon', {'id': id});
    } else if (Platform.isWindows) {
      final ico = id == 'classic' ? 'assets/tray_icon.ico' : 'assets/app_icons/$id.ico';
      try {
        _setWindowIcon(_assetPath('assets/app_icons/$id.ico'));
      } catch (_) {}
      try {
        await trayManager.setIcon(ico);
      } catch (_) {}
      if (shortcuts) await _setShortcuts(id);
    }
  }

  static String _assetPath(String asset) =>
      '${File(Platform.resolvedExecutable).parent.path}\\data\\flutter_assets\\${asset.replaceAll('/', '\\')}';

  /// Gives the window (and so its taskbar button) the icon in [icoPath], at the sizes the
  /// screen's scale asks for. window_manager's setIcon always loads 16 and 32 pixels, which
  /// Windows then enlarges, blurred, on a screen set above 100%.
  static void _setWindowIcon(String icoPath) {
    final user = DynamicLibrary.open('user32.dll');
    final kernel = DynamicLibrary.open('kernel32.dll');
    final findWindow = user.lookupFunction<
        IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>),
        int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)>('FindWindowExW');
    final windowPid = user.lookupFunction<Uint32 Function(IntPtr, Pointer<Uint32>),
        int Function(int, Pointer<Uint32>)>('GetWindowThreadProcessId');
    final myPid = kernel.lookupFunction<Uint32 Function(), int Function()>('GetCurrentProcessId')();
    final dpiFor =
        user.lookupFunction<Uint32 Function(IntPtr), int Function(int)>('GetDpiForWindow');
    final metric = user.lookupFunction<Int32 Function(Int32, Uint32), int Function(int, int)>(
        'GetSystemMetricsForDpi');
    final loadImage = user.lookupFunction<
        IntPtr Function(IntPtr, Pointer<Utf16>, Uint32, Int32, Int32, Uint32),
        int Function(int, Pointer<Utf16>, int, int, int, int)>('LoadImageW');
    final send = user.lookupFunction<IntPtr Function(IntPtr, Uint32, IntPtr, IntPtr),
        int Function(int, int, int, int)>('SendMessageW');

    final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    final path = icoPath.toNativeUtf16();
    final pid = calloc<Uint32>();
    try {
      // This app's own window (another Flutter app could have one of the same class).
      var hwnd = 0;
      while (true) {
        hwnd = findWindow(0, hwnd, cls, nullptr);
        if (hwnd == 0) return;
        windowPid(hwnd, pid);
        if (pid.value == myPid) break;
      }
      const smCxIcon = 11, smCxSmIcon = 49, imageIcon = 1, lrLoadFromFile = 0x10;
      const wmSetIcon = 0x80, iconSmall = 0, iconBig = 1;
      final dpi = dpiFor(hwnd);
      final big = metric(smCxIcon, dpi), small = metric(smCxSmIcon, dpi);
      final hBig = loadImage(0, path, imageIcon, big, big, lrLoadFromFile);
      final hSmall = loadImage(0, path, imageIcon, small, small, lrLoadFromFile);
      if (hSmall != 0) send(hwnd, wmSetIcon, iconSmall, hSmall);
      if (hBig != 0) send(hwnd, wmSetIcon, iconBig, hBig);
    } finally {
      calloc.free(cls);
      calloc.free(path);
      calloc.free(pid);
    }
  }

  /// Points Kumo's Start menu, desktop and pinned taskbar shortcuts at the chosen icon.
  static Future<void> _setShortcuts(String id) async {
    final exe = Platform.resolvedExecutable;
    final icon = id == defaultId
        ? '$exe,0'
        : '${File(exe).parent.path}\\data\\flutter_assets\\assets\\app_icons\\$id.ico,0';
    // The paths go in through the environment, never into the script text.
    const script = r'''
$ErrorActionPreference = 'SilentlyContinue'
$exe = $env:KUMO_EXE
$shell = New-Object -ComObject WScript.Shell
$dirs = @(
  [Environment]::GetFolderPath('CommonPrograms'), [Environment]::GetFolderPath('Programs'),
  [Environment]::GetFolderPath('CommonDesktopDirectory'), [Environment]::GetFolderPath('Desktop'),
  (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'))
foreach ($d in $dirs) {
  if (-not $d -or -not (Test-Path $d)) { continue }
  Get-ChildItem -LiteralPath $d -Filter *.lnk -Recurse -Depth 1 | ForEach-Object {
    $l = $shell.CreateShortcut($_.FullName)
    if ($l.TargetPath -ieq $exe -and $l.IconLocation -ne $env:KUMO_ICON) {
      $l.IconLocation = $env:KUMO_ICON
      $l.Save()
    }
  }
}
& "$env:SystemRoot\System32\ie4uinit.exe" -show
''';
    try {
      await Process.run(
        'powershell.exe',
        ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script],
        environment: {'KUMO_EXE': exe, 'KUMO_ICON': icon},
        runInShell: false,
      );
    } catch (_) {}
  }
}
