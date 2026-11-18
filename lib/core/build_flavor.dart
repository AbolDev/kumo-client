/// True in the build made for F-Droid (`--dart-define=FDROID=true`). That build never looks for or
/// installs updates on its own: the store does it.
const fdroidBuild = bool.fromEnvironment('FDROID');

/// True in the build made for Google Play (`--dart-define=PLAY=true`). The store updates it, so it does not look for or install updates
/// either, and it has no page of donations: the payments policy of Google Play does not let an app lead users to a way of paying that is
/// not its own billing (the wallets are on GitHub and in the README instead).
const playBuild = bool.fromEnvironment('PLAY');

/// A build a store updates: it never looks for updates or installs them.
const storeBuild = fdroidBuild || playBuild;

/// Whether the app shows its page of donations (the wallets) and asks for them.
const donationsInApp = !playBuild;