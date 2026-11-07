import 'dart:io';

import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// The app icon the user picks in Settings (drawn by tools/make_app_icons.py).
///
/// On Android each icon is a launcher entry of its own (see AppIcons.kt). On Windows the
/// program file keeps the default icon; the window, the taskbar button, the tray and the
/// Start menu and desktop shortcuts take the chosen one.
class AppIcon {
  static const defaultId = 'teal';

  /// In the app's teal, then the first set in other colours, then the icon Kumo had before.
  static const groups = <List<String>>[
    ['teal', 'teal_light', 'teal_solid', 'teal_blue', 'mint', 'teal_night'],
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
        await windowManager.setIcon('assets/app_icons/$id.ico');
      } catch (_) {}
      try {
        await trayManager.setIcon(ico);
      } catch (_) {}
      if (shortcuts) await _setShortcuts(id);
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
