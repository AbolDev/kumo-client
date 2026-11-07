import 'dart:io';

import '../desktop_vpn.dart';
import 'usage_ping.dart' show isBuildName;

/// What the build says it is, written by CI (`--dart-define=KUMO_BUILD=...`): the full name of the
/// release file on Android ("kumo-android-arm64-v8a.apk"), and for the desktop the part that is the
/// same for every package made from one compile ("kumo-windows-x64", "kumo-linux-arm64",
/// "kumo-macos"). Empty for a build made by hand: then nothing is sent.
const buildFamily = String.fromEnvironment('KUMO_BUILD');

/// The name of the release file this app was installed from, as it is named on GitHub, or null when
/// that cannot be told for sure. Not the processor of the device: an arm64 phone can run the
/// universal file.
///
/// [portable]: the folder-with-a-`portable`-file packages; [appImage]: run from an AppImage;
/// [linuxPackage]: "deb" or "rpm", from the `package` file the Linux packages hold; [macVariant]:
/// "universal", "arm64" or "x64", from the program's own file.
String? buildAssetName(
  String family, {
  bool portable = false,
  bool appImage = false,
  String? linuxPackage,
  String? macVariant,
}) {
  String? name;
  if (family.startsWith('kumo-android-')) {
    name = family.endsWith('.apk') ? family : null;
  } else if (RegExp(r'^kumo-windows-(x64|arm64)$').hasMatch(family)) {
    name = '$family-${portable ? 'portable.zip' : 'setup.exe'}';
  } else if (RegExp(r'^kumo-linux-(x64|arm64)$').hasMatch(family)) {
    if (appImage) {
      name = '$family.AppImage';
    } else if (portable) {
      name = '$family-portable.tar.gz';
    } else if (linuxPackage == 'deb' || linuxPackage == 'rpm') {
      name = '$family.$linuxPackage';
    }
  } else if (family == 'kumo-macos') {
    if (macVariant == 'universal' || macVariant == 'arm64' || macVariant == 'x64') {
      name = 'kumo-macos-$macVariant${portable ? '-portable.zip' : '.dmg'}';
    }
  }
  return isBuildName(name) ? name : null;
}

/// [buildAssetName] for the app that is running. Never throws.
String? installedBuildName() {
  try {
    if (buildFamily.isEmpty) return null;
    if (Platform.isAndroid) return buildAssetName(buildFamily);
    final dir = File(Platform.resolvedExecutable).parent.path;
    String? package;
    String? mac;
    if (Platform.isLinux) {
      final f = File('$dir/package');
      if (f.existsSync()) package = f.readAsStringSync().trim();
    }
    if (Platform.isMacOS) {
      // A file with both architectures starts with the "fat" magic number; a one-architecture copy
      // is a plain Mach-O file, and the architecture it runs as is its own.
      final raf = File(Platform.resolvedExecutable).openSync();
      final head = raf.readSync(4);
      raf.closeSync();
      final fat = head.length == 4 && head[0] == 0xCA && head[1] == 0xFE && head[2] == 0xBA && (head[3] == 0xBE || head[3] == 0xBF);
      mac = fat ? 'universal' : (Platform.version.contains('arm64') ? 'arm64' : 'x64');
    }
    return buildAssetName(
      buildFamily,
      portable: DesktopVpn.portable,
      appImage: (Platform.environment['APPIMAGE'] ?? '').isNotEmpty,
      linuxPackage: package,
      macVariant: mac,
    );
  } catch (_) {
    return null;
  }
}
