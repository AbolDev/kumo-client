import 'package:flutter/material.dart';

/// A button that does nothing when it is tapped and confirms only when it is held down for [duration] while a
/// bar fills: for what cannot be undone (see Settings > Disguise and erase), so that no tap by chance does it.
/// Letting go early empties the bar and nothing happens.
class HoldToConfirm extends StatefulWidget {
  const HoldToConfirm({
    super.key,
    required this.label,
    required this.onConfirmed,
    this.duration = const Duration(seconds: 3),
    this.color,
  });

  final String label;
  final VoidCallback onConfirmed;
  final Duration duration;
  final Color? color;

  @override
  State<HoldToConfirm> createState() => _HoldToConfirmState();
}

class _HoldToConfirmState extends State<HoldToConfirm> with SingleTickerProviderStateMixin {
  late final AnimationController _bar = AnimationController(vsync: this, duration: widget.duration)
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) _confirm();
    });
  var _done = false;

  void _confirm() {
    if (_done) return;
    _done = true;
    widget.onConfirmed();
  }

  @override
  void dispose() {
    _bar.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.error;
    return Semantics(
      button: true,
      label: widget.label,
      // The long press of a screen reader is as deliberate as holding.
      onLongPress: _confirm,
      child: Listener(
        onPointerDown: (_) {
          if (!_done) _bar.forward();
        },
        onPointerUp: (_) {
          if (!_done) _bar.animateBack(0, duration: const Duration(milliseconds: 250));
        },
        onPointerCancel: (_) {
          if (!_done) _bar.animateBack(0, duration: const Duration(milliseconds: 250));
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(26),
          child: SizedBox(
            height: 52,
            child: Stack(fit: StackFit.expand, children: [
              ColoredBox(color: color.withValues(alpha: 0.14)),
              AnimatedBuilder(
                animation: _bar,
                builder: (_, __) => FractionallySizedBox(
                  alignment: AlignmentDirectional.centerStart,
                  widthFactor: _bar.value,
                  child: ColoredBox(key: const ValueKey('hold-fill'), color: color.withValues(alpha: 0.85)),
                ),
              ),
              Center(
                child: ExcludeSemantics(
                  // The text turns white as the bar fills behind it.
                  child: AnimatedBuilder(
                    animation: _bar,
                    builder: (_, __) => Text(widget.label,
                        style: TextStyle(
                            fontWeight: FontWeight.w700, color: Color.lerp(color, Colors.white, (_bar.value * 2).clamp(0, 1)))),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
