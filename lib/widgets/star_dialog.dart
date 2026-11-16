import 'package:flutter/material.dart';

import '../l10n/extra.dart';
import '../l10n/strings.dart';
import 'kumo_mark.dart';

/// The request for a star on GitHub: a header with Kumo's cloud and a gold star on a soft gradient, the
/// question, one big button to star, and the two quieter answers side by side under it. Pops 'star', 'later'
/// or 'never'.
class StarDialog extends StatelessWidget {
  const StarDialog({super.key});

  static const _gold = Color(0xFFFFC94D);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Dialog(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _header(scheme),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
              child: Column(children: [
                Text(
                  tr(context, 'starTitle'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                Text(
                  tr(context, 'starMessage'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 4),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  shape: const StadiumBorder(),
                  textStyle: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                onPressed: () => Navigator.pop(context, 'star'),
                icon: const Icon(Icons.star_rounded, color: _gold),
                label: Text(tr(context, 'starOpen')),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Row(children: [
                Expanded(
                  child: TextButton(
                    style: TextButton.styleFrom(foregroundColor: scheme.onSurfaceVariant),
                    onPressed: () => Navigator.pop(context, 'never'),
                    child: Text(tr(context, 'starNever'), textAlign: TextAlign.center),
                  ),
                ),
                Container(width: 1, height: 20, color: scheme.outlineVariant),
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.pop(context, 'later'),
                    child: Text(S.of(context).later, textAlign: TextAlign.center),
                  ),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  /// Kumo's cloud in a circle with a gold star on its corner, and a few small stars around, on a gradient.
  Widget _header(ColorScheme scheme) {
    Widget sparkle(double size, double opacity) =>
        Icon(Icons.star_rounded, size: size, color: _gold.withValues(alpha: opacity));
    return Container(
      height: 136,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primaryContainer, scheme.tertiaryContainer],
        ),
      ),
      child: Stack(alignment: Alignment.center, children: [
        PositionedDirectional(top: 22, start: 52, child: sparkle(16, 0.9)),
        PositionedDirectional(top: 70, start: 28, child: sparkle(10, 0.6)),
        PositionedDirectional(top: 28, end: 46, child: sparkle(12, 0.7)),
        PositionedDirectional(bottom: 22, end: 70, child: sparkle(18, 0.85)),
        Stack(clipBehavior: Clip.none, children: [
          Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              color: scheme.surface,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(color: scheme.shadow.withValues(alpha: 0.18), blurRadius: 16, offset: const Offset(0, 6)),
              ],
            ),
            alignment: Alignment.center,
            child: const KumoMark(size: 50),
          ),
          Positioned(
            right: -4,
            bottom: -2,
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: _gold,
                shape: BoxShape.circle,
                border: Border.all(color: scheme.surface, width: 3),
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.star_rounded, size: 20, color: Colors.white),
            ),
          ),
        ]),
      ]),
    );
  }
}
