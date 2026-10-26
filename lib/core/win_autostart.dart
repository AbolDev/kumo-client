import 'dart:io';

/// Starts Kumo when the user signs in. On Windows a scheduled task is used because the app needs
/// administrator rights, which a plain "Run" entry could not get without a prompt; on Linux an
/// autostart entry and on macOS a login item (launch agent) do the same.
class WinAutostart {
  static const _task = 'KumoAutoStart';

  static Future<void> set(bool enabled) async {
    if (Platform.isLinux) return _linux(enabled);
    if (Platform.isMacOS) return _mac(enabled);
    final exe = Platform.resolvedExecutable.replaceAll("'", "''");
    final script = enabled
        ? "\$a = New-ScheduledTaskAction -Execute '$exe' -Argument '--minimized'; "
            "\$t = New-ScheduledTaskTrigger -AtLogOn; "
            "\$p = New-ScheduledTaskPrincipal -UserId \$env:USERNAME -RunLevel Highest; "
            "Register-ScheduledTask -TaskName $_task -Action \$a -Trigger \$t -Principal \$p -Force | Out-Null"
        : "Unregister-ScheduledTask -TaskName $_task -Confirm:\$false -ErrorAction SilentlyContinue";
    try {
      await Process.run('powershell', ['-NoProfile', '-Command', script]);
    } catch (_) {}
  }

  static Future<void> _linux(bool enabled) async {
    final home = Platform.environment['HOME'];
    if (home == null) return;
    final base = Platform.environment['XDG_CONFIG_HOME'] ?? '$home/.config';
    final file = File('$base/autostart/kumo.desktop');
    try {
      if (!enabled) {
        if (await file.exists()) await file.delete();
        return;
      }
      await file.parent.create(recursive: true);
      await file.writeAsString('[Desktop Entry]\n'
          'Type=Application\n'
          'Name=Kumo\n'
          'Exec="${Platform.resolvedExecutable}" --minimized\n'
          'X-GNOME-Autostart-enabled=true\n');
    } catch (_) {}
  }

  static Future<void> _mac(bool enabled) async {
    final home = Platform.environment['HOME'];
    if (home == null) return;
    final file = File('$home/Library/LaunchAgents/app.kumo.vpn.plist');
    try {
      if (!enabled) {
        if (await file.exists()) await file.delete();
        return;
      }
      await file.parent.create(recursive: true);
      await file.writeAsString('<?xml version="1.0" encoding="UTF-8"?>\n'
          '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
          '<plist version="1.0"><dict>\n'
          '<key>Label</key><string>app.kumo.vpn</string>\n'
          '<key>ProgramArguments</key><array><string>${Platform.resolvedExecutable}</string><string>--minimized</string></array>\n'
          '<key>RunAtLoad</key><true/>\n'
          '</dict></plist>\n');
    } catch (_) {}
  }
}
