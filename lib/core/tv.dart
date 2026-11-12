import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import 'vpn_channel.dart';

/// Whether Kumo runs on a television (Android TV, Google TV, Fire TV): it is used with a remote control, from a
/// sofa, without a touch screen or a camera. Set once when the app starts ([initTv]); `--dart-define=KUMO_TV=true`
/// turns it on anywhere, to try the television's screens on a computer.
bool isTv = const bool.fromEnvironment('KUMO_TV');

/// Asks the phone's system whether it is a television.
Future<void> initTv() async {
  if (isTv || !Platform.isAndroid) return;
  isTv = await VpnChannel.isTelevision();
}

/// [base] made easy to use with a remote: the thing that has the focus is drawn with a clear ring or a strong
/// tint, so the viewer can tell from the sofa where the arrow keys are.
ThemeData tvTheme(ThemeData base) {
  final scheme = base.colorScheme;
  final focus = scheme.primary.withValues(alpha: 0.34);
  BorderSide? ring(Set<WidgetState> states) =>
      states.contains(WidgetState.focused) ? BorderSide(color: scheme.onSurface, width: 3) : null;
  final buttons = ButtonStyle(side: WidgetStateProperty.resolveWith(ring));
  Color? tint(Set<WidgetState> states) => states.contains(WidgetState.focused) ? focus : null;
  return base.copyWith(
    focusColor: focus,
    filledButtonTheme: FilledButtonThemeData(style: buttons),
    outlinedButtonTheme: OutlinedButtonThemeData(style: buttons),
    textButtonTheme: TextButtonThemeData(style: buttons),
    iconButtonTheme: IconButtonThemeData(style: buttons),
    floatingActionButtonTheme: base.floatingActionButtonTheme.copyWith(focusColor: focus),
    switchTheme: base.switchTheme.copyWith(overlayColor: WidgetStateProperty.resolveWith(tint)),
    checkboxTheme: base.checkboxTheme.copyWith(overlayColor: WidgetStateProperty.resolveWith(tint)),
    radioTheme: base.radioTheme.copyWith(overlayColor: WidgetStateProperty.resolveWith(tint)),
    listTileTheme: base.listTileTheme.copyWith(minVerticalPadding: 8),
  );
}
