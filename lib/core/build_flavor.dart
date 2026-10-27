/// True in the build made for F-Droid (`--dart-define=FDROID=true`). That build never looks for or
/// installs updates on its own: the store does it.
const fdroidBuild = bool.fromEnvironment('FDROID');