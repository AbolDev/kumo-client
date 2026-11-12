import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;

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

/// What the remote's keys do wherever the focus is: the arrows (the D-pad) move the focus in their direction and OK
/// presses what has it. The platform's own shortcuts on Android do not move the focus with the arrows, which a
/// remote has nothing else to do with. A text field keeps the arrows for its cursor (its own shortcuts come first).
class TvKeys extends StatelessWidget {
  const TvKeys({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(TraversalDirection.up),
          SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(TraversalDirection.down),
          SingleActivator(LogicalKeyboardKey.arrowLeft): DirectionalFocusIntent(TraversalDirection.left),
          SingleActivator(LogicalKeyboardKey.arrowRight): DirectionalFocusIntent(TraversalDirection.right),
          SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
        },
        child: child,
      );
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
