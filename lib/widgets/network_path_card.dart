import 'package:flutter/material.dart';

import '../core/network_path.dart';
import '../l10n/extra.dart';

/// The path of a test as a card: where the traffic starts (the user's own network), the exit of the VPN, and the server
/// it was measured against, one under the other with a line between them. [vpn] says whether a VPN carried it.
class NetworkPathCard extends StatelessWidget {
  const NetworkPathCard({super.key, required this.nodes, required this.vpn, this.title});

  final List<PathNode> nodes;
  final bool vpn;

  /// The heading; "Path of this test" when null.
  final String? title;

  static IconData _icon(PathKind kind) => switch (kind) {
        PathKind.you => Icons.smartphone_outlined,
        PathKind.exit => Icons.lock_outline,
        PathKind.server => Icons.dns_outlined,
      };

  static String _label(BuildContext context, PathKind kind) => tr(
      context,
      switch (kind) {
        PathKind.you => 'pathYou',
        PathKind.exit => 'pathExit',
        PathKind.server => 'pathServer',
      });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: scheme.outlineVariant)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(title ?? tr(context, 'pathTitle'), style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant))),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: vpn ? scheme.primaryContainer : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(99),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(vpn ? Icons.verified_user_outlined : Icons.wifi, size: 14, color: vpn ? scheme.onPrimaryContainer : scheme.onSurfaceVariant),
                const SizedBox(width: 5),
                Text(tr(context, vpn ? 'speedTagVpn' : 'speedTagDirect'),
                    style: text.bodySmall?.copyWith(color: vpn ? scheme.onPrimaryContainer : scheme.onSurfaceVariant)),
              ]),
            ),
          ]),
          const SizedBox(height: 12),
          for (var i = 0; i < nodes.length; i++) _node(context, nodes[i], last: i == nodes.length - 1),
        ]),
      ),
    );
  }

  Widget _node(BuildContext context, PathNode n, {required bool last}) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Column(children: [
          CircleAvatar(
            radius: 17,
            backgroundColor: scheme.primaryContainer,
            child: Icon(_icon(n.kind), size: 18, color: scheme.onPrimaryContainer),
          ),
          if (!last) Expanded(child: Container(width: 2, margin: const EdgeInsets.symmetric(vertical: 4), color: scheme.outlineVariant)),
        ]),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(bottom: last ? 0 : 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_label(context, n.kind), style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              if (n.title.isNotEmpty)
                Text(n.title, textDirection: TextDirection.ltr, style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
              for (final line in n.lines)
                Text(line, textDirection: TextDirection.ltr, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ]),
          ),
        ),
      ]),
    );
  }
}
