import 'dart:io';

import 'win_tools.dart';

/// Starts Kumo when the user signs in. On Windows a scheduled task is used because the app needs
/// administrator rights, which a plain "Run" entry could not get without a prompt; on Linux an
/// autostart entry and on macOS a login item (launch agent) do the same.
class WinAutostart {
  static const _task = 'KumoAutoStart';

  /// Turns it on or off; false when it could not be turned on.
  static Future<bool> set(bool enabled) async {
    if (Platform.isLinux) return _linux(enabled);
    if (Platform.isMacOS) return _mac(enabled);
    // The task runs the program with administrator rights at every sign-in. Where the program sits
    // in a folder any program of the user can write to (the portable version), another program could
    // put its own file in its place and get those rights, so it is not offered there.
    if (enabled && !inProtectedFolder(Platform.resolvedExecutable)) return false;
    final exe = Platform.resolvedExecutable.replaceAll("'", "''");
    final script = enabled
        ? "\$a = New-ScheduledTaskAction -Execute '$exe' -Argument '--minimized'; "
            "\$t = New-ScheduledTaskTrigger -AtLogOn; "
            "\$p = New-ScheduledTaskPrincipal -UserId \$env:USERNAME -RunLevel Highest; "
            "Register-ScheduledTask -TaskName $_task -Action \$a -Trigger \$t -Principal \$p -Force | Out-Null"
        : "Unregister-ScheduledTask -TaskName $_task -Confirm:\$false -ErrorAction SilentlyContinue";
    try {
      final r = await Process.run(winTool('powershell'), ['-NoProfile', '-Command', script]);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _linux(bool enabled) async {
    final home = Platform.environment['HOME'];
    if (home == null) return false;
    final base = Platform.environment['XDG_CONFIG_HOME'] ?? '$home/.config';
    final file = File('$base/autostart/kumo.desktop');
    try {
      if (!enabled) {
        if (await file.exists()) await file.delete();
        return true;
      }
      await file.parent.create(recursive: true);
      await file.writeAsString('[Desktop Entry]\n'
          'Type=Application\n'
          'Name=Kumo\n'
          'Exec="${Platform.resolvedExecutable}" --minimized\n'
          'X-GNOME-Autostart-enabled=true\n');
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _mac(bool enabled) async {
    final home = Platform.environment['HOME'];
    if (home == null) return false;
    final file = File('$home/Library/LaunchAgents/app.kumo.vpn.plist');
    try {
      if (!enabled) {
        if (await file.exists()) await file.delete();
        return true;
      }
      await file.parent.create(recursive: true);
      await file.writeAsString('<?xml version="1.0" encoding="UTF-8"?>\n'
          '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
          '<plist version="1.0"><dict>\n'
          '<key>Label</key><string>app.kumo.vpn</string>\n'
          '<key>ProgramArguments</key><array><string>${Platform.resolvedExecutable}</string><string>--minimized</string></array>\n'
          '<key>RunAtLoad</key><true/>\n'
          '</dict></plist>\n');
      return true;
    } catch (_) {
      return false;
    }
  }
}
