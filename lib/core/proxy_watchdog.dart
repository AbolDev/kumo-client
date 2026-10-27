import 'dart:convert';
import 'dart:io';

/// A tiny helper process that outlives this app: when the app ends in any way (closed, crashed,
/// killed) it takes this app's proxy away from the system settings, so the internet does not stay
/// pointed at a dead port until the app is opened again. The full previous setting is still put
/// back by the app at its next start (see the backup file of the system proxy classes).
class ProxyWatchdog {
  Process? _helper;

  /// Starts watching this process; [port] is the proxy port that must not be left behind.
  Future<void> start(int port) async {
    stop();
    try {
      if (Platform.isWindows) {
        _helper = await Process.start(
          'powershell.exe',
          [
            '-NoProfile',
            '-NonInteractive',
            '-WindowStyle',
            'Hidden',
            '-EncodedCommand',
            encodePowerShell(windowsWatchdogScript(pid, port)),
          ],
          mode: ProcessStartMode.detached,
        );
      } else {
        final script = Platform.isMacOS ? macWatchdogScript : linuxWatchdogScript;
        _helper = await Process.start('sh', ['-c', script, 'sh', '$pid', '$port'],
            mode: ProcessStartMode.detached);
      }
    } catch (_) {
      // no helper: the app still restores the setting itself when it ends normally
    }
  }

  /// Ends the helper (the proxy was taken away by the app itself).
  void stop() {
    final helper = _helper;
    _helper = null;
    if (helper != null) {
      try {
        Process.killPid(helper.pid);
      } catch (_) {}
    }
  }
}

/// PowerShell reads `-EncodedCommand` as base64 of UTF-16LE text.
String encodePowerShell(String script) {
  final bytes = <int>[];
  for (final unit in script.codeUnits) {
    bytes
      ..add(unit & 0xFF)
      ..add(unit >> 8);
  }
  return base64.encode(bytes);
}

/// Waits for [appPid] to end, then switches the registry proxy off when it still points at
/// 127.0.0.1:[port] (a proxy of another program is left alone).
String windowsWatchdogScript(int appPid, int port,
    {String key = r'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'}) {
  return '''
Wait-Process -Id $appPid -ErrorAction SilentlyContinue
\$k = '$key'
\$s = (Get-ItemProperty -Path \$k -ErrorAction SilentlyContinue).ProxyServer
if (\$s -match '(^|[=;\\s])(127\\.0\\.0\\.1|localhost):$port(;|\$)') {
  Set-ItemProperty -Path \$k -Name ProxyEnable -Value 0 -Type DWord
  Remove-ItemProperty -Path \$k -Name ProxyServer -ErrorAction SilentlyContinue
}
''';
}

/// `sh -c` script, arguments: the app's pid and the proxy port.
const linuxWatchdogScript = r'''
while kill -0 "$1" 2>/dev/null; do sleep 2; done
case "$(echo "$XDG_CURRENT_DESKTOP" | tr a-z A-Z)" in
  *KDE*)
    w=$(command -v kwriteconfig6 || command -v kwriteconfig5)
    r=$(command -v kreadconfig6 || command -v kreadconfig5)
    [ -n "$w" ] && [ -n "$r" ] || exit 0
    h=$("$r" --file kioslaverc --group 'Proxy Settings' --key httpProxy)
    case "$h" in
      *127.0.0.1*"$2"*) "$w" --file kioslaverc --group 'Proxy Settings' --key ProxyType 0 ;;
    esac
    ;;
  *)
    command -v gsettings >/dev/null 2>&1 || exit 0
    host=$(gsettings get org.gnome.system.proxy.http host)
    port=$(gsettings get org.gnome.system.proxy.http port)
    case "$host" in
      *127.0.0.1*) [ "$port" = "$2" ] && gsettings set org.gnome.system.proxy mode none ;;
    esac
    ;;
esac
''';

const macWatchdogScript = r'''
while kill -0 "$1" 2>/dev/null; do sleep 2; done
networksetup -listallnetworkservices | tail -n +2 | grep -v '^\*' | while IFS= read -r s; do
  for pair in "getwebproxy:setwebproxystate" "getsecurewebproxy:setsecurewebproxystate" "getsocksfirewallproxy:setsocksfirewallproxystate"; do
    get=${pair%%:*}
    set=${pair##*:}
    out=$(networksetup -"$get" "$s")
    case "$out" in
      *"Enabled: Yes"*"Server: 127.0.0.1"*"Port: $2"*) networksetup -"$set" "$s" off ;;
    esac
  done
done
''';
