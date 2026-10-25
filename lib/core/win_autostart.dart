import 'dart:io';

/// Starts Kumo when the user signs in to Windows. A scheduled task is used because the app needs
/// administrator rights, which a plain "Run" entry could not get without a prompt.
class WinAutostart {
  static const _task = 'KumoAutoStart';

  static Future<void> set(bool enabled) async {
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
}
