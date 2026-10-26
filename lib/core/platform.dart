import 'dart:io';

/// Windows, Linux or macOS: the platforms where the VPN runs as child processes of the app
/// (see DesktopVpn) and the window has a tray icon.
final bool isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
