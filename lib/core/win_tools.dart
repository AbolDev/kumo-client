import 'dart:io';

/// The Windows system programs the app runs (reg, taskkill ...), by their full path in the system
/// folder. Run by name, Windows looks next to the app first, and the app runs with administrator
/// rights: a program of the same name placed in a folder the user can write to would then be run
/// with those rights.
String winTool(String name) {
  if (!Platform.isWindows) return name;
  final root = Platform.environment['SystemRoot'] ?? Platform.environment['windir'] ?? r'C:\Windows';
  if (name == 'powershell') return '$root\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
  return '$root\\System32\\$name.exe';
}

/// Whether [path] is inside a folder that ordinary users cannot write to (Program Files, Windows):
/// only there can a program be trusted to be the one that was installed.
bool inProtectedFolder(String path) {
  final env = Platform.environment;
  final p = path.toLowerCase().replaceAll('/', '\\');
  for (final key in ['ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432', 'SystemRoot']) {
    final dir = env[key];
    if (dir != null && dir.isNotEmpty && p.startsWith('${dir.toLowerCase()}\\')) return true;
  }
  return false;
}
