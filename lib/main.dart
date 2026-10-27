import 'dart:io' show Platform, exit;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'core/build_flavor.dart';
import 'core/desktop_vpn.dart';
import 'core/platform.dart';
import 'core/single_instance.dart';
import 'core/vpn_channel.dart';
import 'l10n/extra.dart';
import 'l10n/strings.dart';
import 'screens/home_page.dart';
import 'screens/onboarding_page.dart';
import 'screens/update_dialog.dart';
import 'widgets/title_bar.dart';
import 'state/app_state.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (isDesktop) {
    // A second copy would stop the first one's cores and fight over the proxy; it shows the first
    // copy's window and ends.
    if (!await SingleInstance.acquire(DesktopVpn.instance.dataDir)) exit(0);
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      WindowOptions(
          size: const Size(800, 620),
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    // The usage numbers are saved every half minute; leaving the app saves them at once.
    if (lifecycle != AppLifecycleState.resumed) _state.flushUsage();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _state.init().then((_) {
      _askBatteryOnce();
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
      _setupTray();
      _state.addListener(_refreshTrayMenu);
    }
  }

  @override
  void dispose() {
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
      await trayManager.setIcon(
          Platform.isWindows ? 'assets/tray_icon.ico' : 'assets/tray_icon.png');
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
      VpnChannel.stop,
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

  ThemeData _theme(Brightness brightness) {
    final base = ThemeData(
      useMaterial3: true,
      colorSchemeSeed: const Color(0xFF0E9F8E),
      brightness: brightness,
    );
    // The header's icons (add, more, settings, back) share one colour: a button and a popup
    // menu icon otherwise get two different greys.
    final icons = IconThemeData(color: base.colorScheme.onSurface);
    return base.copyWith(
      appBarTheme: base.appBarTheme.copyWith(iconTheme: icons, actionsIconTheme: icons),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _state,
      builder: (context, _) => MaterialApp(
        title: 'Kumo',
        navigatorKey: _navigator,
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
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        themeMode: _state.themeMode,
        home: !_state.settingsLoaded
            ? const Scaffold()
            : _state.onboarded
                ? HomePage(state: _state)
                : OnboardingPage(state: _state),
      ),
    );
  }
}
