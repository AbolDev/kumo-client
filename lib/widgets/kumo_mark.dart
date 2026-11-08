import 'package:flutter/material.dart';

/// The app icon's crystal cloud in the theme's teal (the picture the home page header shows), for
/// the places that used to show the plain Material cloud icon.
class KumoMark extends StatelessWidget {
  const KumoMark({super.key, this.size = 24});

  final double size;

  @override
  Widget build(BuildContext context) => Image.asset(
        'assets/app_icons/mark.png',
        height: size,
        filterQuality: FilterQuality.high,
        excludeFromSemantics: true,
      );
}
