import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/vpn_channel.dart';

/// The launcher icon of an installed app, fetched once per app.
class AppIcon extends StatelessWidget {
  const AppIcon({super.key, required this.id, this.size = 40});

  final String id;
  final double size;

  static final _cache = <String, Future<Uint8List?>>{};

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: FutureBuilder<Uint8List?>(
        future: _cache.putIfAbsent(id, () => VpnChannel.appIcon(id)),
        builder: (context, snap) =>
            snap.data == null ? const Icon(Icons.android) : Image.memory(snap.data!, gaplessPlayback: true),
      ),
    );
  }
}
