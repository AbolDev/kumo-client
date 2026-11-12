import 'dart:async';
import 'dart:io' show Directory, FileSystemEvent, Platform, exit;
import 'dart:isolate' show Isolate, RawReceivePort;
import 'dart:ui' show PlatformDispatcher;

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'core/app_icon.dart';
import 'core/build_flavor.dart';
import 'core/desktop_vpn.dart';
import 'core/platform.dart';
import 'core/external_open.dart';
import 'core/single_instance.dart';
import 'core/tv.dart';
import 'core/usage/crash_hub.dart';
import 'core/vpn_channel.dart';
import 'core/win_menu_theme.dart';
import 'l10n/extra.dart';
import 'l10n/strings.dart';
import 'screens/home_page.dart';
import 'screens/onboarding_page.dart';
import 'screens/update_dialog.dart';
import 'widgets/title_bar.dart';
import 'state/app_state.dart';

/// Links and files that this copy was started with (desktop); asked about once the app is up.
List<String> _startupExternal = const [];

void main(List<String> args) {
  // Errors nobody caught are handed to the crash report (it does nothing while the usage-count
  // switch is off, and never shows anything). The framework's own printing stays as it was.
  final printed = FlutterError.onError;
  FlutterError.onError = (details) {
    printed?.call(details);
    CrashHub.report(details.exception, details.stack, kind: 'FlutterError', message: details.exceptionAsString());
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    CrashHub.report(error, stack);
    return true;
  };
  try {
    Isolate.current.addErrorListener(RawReceivePort((dynamic pair) {
      final list = pair as List<dynamic>;
      CrashHub.report(StateError('${list.first}'), StackTrace.fromString('${list.last}'), kind: 'IsolateError');
    }).sendPort);
  } catch (_) {}
  runZonedGuarded(() => _start(args), (error, stack) => CrashHub.report(error, stack));
}

Future<void> _start(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (isDesktop) {
    // A second copy would stop the first one's cores and fight over the proxy; it shows the first
    // copy's window and ends.
    final handed = await ExternalInbox.fromArgs(args);
    if (!await SingleInstance.acquire(DesktopVpn.instance.dataDir)) {
      // A link or a file opened with Kumo while it already runs goes to the running copy.
      await ExternalInbox.send(DesktopVpn.instance.dataDir, handed);
      exit(0);
    }
    _startupExternal = handed;
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      WindowOptions(
          size: const Size(800, 680),
          minimumSize: const Size(420, 520),
          title: 'Kumo',
          // Windows draws its own title bar; Linux and macOS keep the system one.
          titleBarStyle: Platform.isWindows ? TitleBarStyle.hidden : TitleBarStyle.normal,
          windowButtonVisibility: !Platform.isWindows),
      () async {
        // Started by Windows at sign-in: stay in the tray.
        if (!args.contains('--minimized')) {
          await windowManager.show();
          await windowManager.focus();
        }
      },
    );
    // Closing the window is handled by the app (hide to the tray, or stop the VPN and quit).
    await windowManager.setPreventClose(true);
  }
  // A television is used with a remote: the screens, the focus and the ways to add servers follow it.
  await initTv();
  runApp(const KumoApp());
}

class KumoApp extends StatefulWidget {
  const KumoApp({super.key});

  @override
  State<KumoApp> createState() => _KumoAppState();
}

class _KumoAppState extends State<KumoApp>
    with WindowListener, TrayListener, WidgetsBindingObserver {
  final _state = AppState();
  final _navigator = GlobalKey<NavigatorState>();

  /// Whether the tray icon was set up (without it a hidden window could not be brought back).
  var _trayOk = false;

  Future<void> _trayReady = Future.value();

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    // The usage numbers are saved every half minute; leaving the app saves them at once.
    if (lifecycle != AppLifecycleState.resumed) {
      _state.flushUsage();
      _state.flushStore();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _state.init().then((_) {
      // The icon picked in Settings. An update of the Windows app puts kumo.exe back on the
      // shortcuts, so they are checked again at each start.
      // (After the tray's first icon, which would otherwise replace it.)
      if (AppIcon.supported) {
        _trayReady.then((_) => AppIcon.apply(_state.appIcon)).catchError((_) {});
      }
      _askBatteryOnce();
      _listenExternal();
      _state.noteOpen();
      _askStarLater();
      // A newer stable release is offered when the app opens (not in the F-Droid build).
      if (!fdroidBuild) {
        Future<void>.delayed(const Duration(seconds: 3), () {
          final context = _navigator.currentContext;
          if (context != null && context.mounted && _state.onboarded) checkAndPrompt(context, silent: true);
        });
      }
      // Connect on startup (the phone does this from its boot receiver).
      if (isDesktop && _state.autoConnect && !_state.connected) {
        _state.toggle();
      }
    });
    if (isDesktop) {
      windowManager.addListener(this);
      trayManager.addListener(this);
      _trayReady = _setupTray();
      _state.addListener(_refreshTrayMenu);
    }
  }

  @override
  void dispose() {
    _externalTimer?.cancel();
    _externalWatch?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (isDesktop) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
      _state.removeListener(_refreshTrayMenu);
    }
    _state.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- Windows tray

  String get _lang =>
      _state.languageCode ??
      WidgetsBinding.instance.platformDispatcher.locale.languageCode;

  Future<void> _setupTray() async {
    try {
      // On Windows the picked app icon replaces this once the settings are read.
      await trayManager.setIcon(Platform.isWindows
          ? 'assets/app_icons/${AppIcon.defaultId}.ico'
          : 'assets/tray_icon.png');
      await trayManager.setToolTip('Kumo');
      // GNOME shows no tray icons unless an extension is installed, and the icon call still
      // succeeds there: the window is then only minimized, never hidden.
      _trayOk = !(Platform.isLinux &&
          (Platform.environment['XDG_CURRENT_DESKTOP'] ?? '').toUpperCase().contains('GNOME'));
    } catch (_) {
      // without a tray icon the window just stays on the taskbar
      _trayOk = false;
    }
    _refreshTrayMenu();
  }

  String? _trayLang;

  void _refreshTrayMenu() {
    // The tray menu is a Windows menu: dark or light with the app's theme.
    if (Platform.isWindows) WinMenuTheme.apply(_state.themeMode);
    if (_trayLang == _lang) return;
    _trayLang = _lang;
    trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'show', label: trFor(_lang, 'show')),
      MenuItem(key: 'toggle', label: trFor(_lang, 'connectToggle')),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: trFor(_lang, 'quit')),
    ])).catchError((_) {});
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _quit() async {
    // The system proxy and the VPN processes must be put away before the app goes; whatever goes
    // wrong in there, the window still closes.
    for (final step in <Future<void> Function()>[
      _state.flushUsage,
      _state.flushStore,
      VpnChannel.stop,
      _state.stopOpenVpn,
      VpnChannel.stopStandby,
      trayManager.destroy,
    ]) {
      try {
        await step();
      } catch (_) {}
    }
    await windowManager.destroy();
  }

  @override
  void onWindowClose() {
    if (_state.net.minimizeToTray) {
      _trayOk ? windowManager.hide() : windowManager.minimize();
    } else {
      _quit();
    }
  }

  @override
  void onTrayIconMouseDown() => _showWindow();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem item) {
    switch (item.key) {
      case 'show':
        _showWindow();
      case 'toggle':
        _state.toggle();
      case 'quit':
        _quit();
    }
  }

  /// Offers once to lift Android's battery restriction, which can stop the VPN in the background.
  // ---- links and files other programs open with Kumo

  final _externalQueue = <String>[];
  var _askingExternal = false;
  Timer? _externalTimer;
  StreamSubscription<FileSystemEvent>? _externalWatch;

  /// Starts listening: the phone tells the app when something was opened with it, a computer is
  /// looked at every two seconds (a second copy of the program leaves it in the data folder).
  void _listenExternal() {
    VpnChannel.onExternal(_pullExternal);
    if (Platform.isMacOS) MacExternal.onExternal(_pullExternal);
    if (isDesktop) {
      // A second copy of the program leaves a file in the data folder: the system says when it comes.
      // A slow look stands in for a system that does not say (it is quick where watching is not possible).
      var watching = false;
      try {
        final dir = Directory(DesktopVpn.instance.dataDir);
        if (dir.existsSync()) {
          _externalWatch = dir
              .watch(events: FileSystemEvent.create | FileSystemEvent.modify | FileSystemEvent.move)
              .listen((e) {
            if (e.path.endsWith(ExternalInbox.fileName)) _pullExternal();
          }, onError: (Object _) {});
          watching = true;
        }
      } catch (_) {}
      _externalTimer = Timer.periodic(Duration(seconds: watching ? 30 : 2), (_) => _pullExternal());
    }
    _pullExternal();
  }

  Future<void> _pullExternal() async {
    try {
      final got = <String>[];
      if (Platform.isAndroid) {
        final text = await VpnChannel.takeExternal();
        if (text != null && text.trim().isNotEmpty) got.add(text);
      } else {
        got.addAll(_startupExternal);
        _startupExternal = const [];
        got.addAll(await ExternalInbox.take(DesktopVpn.instance.dataDir));
        if (Platform.isMacOS) got.addAll(await MacExternal.take());
      }
      if (got.isEmpty) return;
      _externalQueue.addAll(got);
      if (isDesktop) {
        await windowManager.show();
        await windowManager.focus();
      }
      unawaited(_drainExternal());
    } catch (_) {}
  }

  /// Asks about each thing in turn. Nothing is added without a yes: a link in a web page or a chat
  /// can come from anybody.
  Future<void> _drainExternal() async {
    if (_askingExternal) return;
    _askingExternal = true;
    try {
      while (_externalQueue.isNotEmpty) {
        final context = _navigator.currentContext;
        if (context == null || !context.mounted || !_state.settingsLoaded || !_state.onboarded) {
          // The app is still starting: look again in a moment.
          Timer(const Duration(seconds: 1), _drainExternal);
          return;
        }
        final text = _externalQueue.removeAt(0);
        final what = summarizeExternal(text);
        final yes = await showDialog<bool>(
          context: context,
          builder: (dialog) => AlertDialog(
            icon: const Icon(Icons.download_for_offline_outlined),
            title: Text(tr(dialog, 'openTitle')),
            content: Text(what == null
                ? tr(dialog, 'openNone')
                : [
                    what.host != null
                        ? tr(dialog, 'openSubscription', {'host': ltr(what.host!)})
                        : tr(dialog, 'openServers', {'n': what.servers}),
                    tr(dialog, 'openAsk'),
                  ].join('\n\n')),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialog, false),
                  child: Text(what == null ? MaterialLocalizations.of(dialog).okButtonLabel : S.of(dialog).cancel)),
              if (what != null)
                FilledButton(
                    onPressed: () => Navigator.pop(dialog, true), child: Text(tr(dialog, 'openAdd'))),
            ],
          ),
        );
        if (yes == true && context.mounted) await importTextAndAsk(context, _state, text);
      }
    } catch (_) {
    } finally {
      _askingExternal = false;
    }
  }

  /// After a while of use, asks once (twice at most) for a star on GitHub. It waits for the other
  /// start-up questions and shows nothing while another window is open.
  void _askStarLater() {
    if (!_state.starDue) return;
    Future<void>.delayed(const Duration(seconds: 45), () async {
      final context = _navigator.currentContext;
      if (context == null || !context.mounted || !_state.starDue) return;
      if (ModalRoute.of(context)?.isCurrent == false) return;
      final answer = await showDialog<String>(
        context: context,
        builder: (dialog) => AlertDialog(
          icon: const Icon(Icons.star_rounded),
          title: Text(tr(dialog, 'starTitle')),
          content: Text(tr(dialog, 'starMessage')),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialog, 'never'),
                child: Text(tr(dialog, 'starNever'))),
            TextButton(
                onPressed: () => Navigator.pop(dialog, 'later'),
                child: Text(S.of(dialog).later)),
            FilledButton(
                onPressed: () => Navigator.pop(dialog, 'star'),
                child: Text(tr(dialog, 'starOpen'))),
          ],
        ),
      );
      if (answer == null) return;
      _state.answerStar(done: answer != 'later');
      if (answer == 'star') await openLink('https://github.com/AbolDev/kumo-client');
    });
  }

  Future<void> _askBatteryOnce() async {
    if (_state.batteryAsked || !_state.onboarded) return;
    final context = _navigator.currentContext;
    if (context == null || !context.mounted) return;
    if (await VpnChannel.batteryUnrestricted()) {
      _state.markBatteryAsked();
      return;
    }
    if (!context.mounted) return;
    final allow = await showDialog<bool>(
      context: context,
      builder: (dialog) {
        final t = S.of(dialog);
        return AlertDialog(
          icon: const Icon(Icons.battery_saver),
          title: Text(t.batteryTitle),
          content: Text(t.batteryMessage),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialog, false),
                child: Text(t.later)),
            FilledButton(
                onPressed: () => Navigator.pop(dialog, true),
                child: Text(t.batteryAllow)),
          ],
        );
      },
    );
    _state.markBatteryAsked();
    if (allow == true) await VpnChannel.requestBatteryExemption();
  }

  /// The theme: Kumo's teal, or the colours of the system ([system]: from the wallpaper on Android 12 and
  /// later, the accent colour on Windows) when the setting says so, with a black background in the dark
  /// theme when asked, and Vazirmatn for Persian and Arabic.
  ThemeData _theme(Brightness brightness, ColorScheme? system) {
    final code = _state.languageCode ?? PlatformDispatcher.instance.locale.languageCode;
    final font = code == 'fa' || code == 'ar' ? 'Vazirmatn' : null;
    var base = _state.themeColor == 'system' && system != null
        ? ThemeData(useMaterial3: true, colorScheme: system, fontFamily: font)
        : ThemeData(
            useMaterial3: true,
            colorSchemeSeed: const Color(0xFF0E9F8E),
            brightness: brightness,
            fontFamily: font,
          );
    if (brightness == Brightness.dark && _state.blackTheme) {
      base = base.copyWith(
        scaffoldBackgroundColor: Colors.black,
        colorScheme: base.colorScheme.copyWith(
          surface: Colors.black,
          surfaceContainerLowest: Colors.black,
          surfaceContainerLow: const Color(0xFF0B0B0B),
          surfaceContainer: const Color(0xFF121212),
          surfaceContainerHigh: const Color(0xFF191919),
          surfaceContainerHighest: const Color(0xFF212121),
        ),
      );
    }
    // The header's icons (add, more, settings, back) share one colour: a button and a popup
    // menu icon otherwise get two different greys.
    final icons = IconThemeData(color: base.colorScheme.onSurface);
    final themed = base.copyWith(
      appBarTheme: base.appBarTheme.copyWith(iconTheme: icons, actionsIconTheme: icons),
    );
    return isTv ? tvTheme(themed) : themed;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _state,
      builder: (context, _) => DynamicColorBuilder(
        builder: (light, dark) => MaterialApp(
        title: 'Kumo',
        navigatorKey: _navigator,
        navigatorObservers: [_state.routes],
        // A very wide desktop window keeps its content in the middle, on the same background.
        builder: (context, child) => isDesktop
            ? ColoredBox(
                color: Theme.of(context).colorScheme.surface,
                child: Column(children: [
                  if (Platform.isWindows) const AppTitleBar(),
                  Expanded(
                    child: Center(
                        child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 1100),
                            child: child)),
                  ),
                ]))
            : child!,
        debugShowCheckedModeBanner: false,
        // null follows the phone's language; Settings can force a language.
        locale: _state.languageCode == null
            ? null
            : S.localeFor(_state.languageCode!),
        supportedLocales: S.supportedLocales,
        localizationsDelegates: const [
          S.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: _theme(Brightness.light, light),
        darkTheme: _theme(Brightness.dark, dark),
        themeMode: _state.themeMode,
        // (The first route is "/", set by Flutter.)
        home: !_state.settingsLoaded
            ? const Scaffold()
            : _state.onboarded
                ? HomePage(state: _state)
                : OnboardingPage(state: _state),
      ),
      ),
    );
  }
}
