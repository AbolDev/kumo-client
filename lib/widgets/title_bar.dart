import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// Windows: the app draws its own title bar (drag area plus minimize, maximize and close),
/// so the window matches the rest of the app.
class AppTitleBar extends StatefulWidget {
  const AppTitleBar({super.key, this.leading, this.actions});

  /// At the left end (the name of the app on the home screen).
  final Widget? leading;

  /// Between the drag area and the window buttons (the buttons of the home screen).
  final Widget? actions;

  @override
  State<AppTitleBar> createState() => _AppTitleBarState();
}

class _AppTitleBarState extends State<AppTitleBar> with WindowListener {
  var _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((v) {
      if (mounted) setState(() => _maximized = v);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // The window buttons stay on the right in right-to-left languages too.
    return Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
      height: 36,
      child: Row(
        children: [
          if (widget.leading != null) widget.leading!,
          Expanded(
            child: DragToMoveArea(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTap: () async => await windowManager.isMaximized()
                    ? windowManager.unmaximize()
                    : windowManager.maximize(),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          if (widget.actions != null) widget.actions!,
          _CaptionButton(
              icon: Icons.remove,
              tooltip: 'Minimize',
              onTap: windowManager.minimize),
          _CaptionButton(
              icon: _maximized ? Icons.filter_none : Icons.crop_square,
              iconSize: _maximized ? 14 : 16,
              tooltip: _maximized ? 'Restore' : 'Maximize',
              onTap: () async => _maximized
                  ? windowManager.unmaximize()
                  : windowManager.maximize()),
          _CaptionButton(
              icon: Icons.close,
              tooltip: 'Close',
              hover: scheme.error,
              onTap: windowManager.close),
        ],
      ),
    ));
  }
}

class _CaptionButton extends StatefulWidget {
  const _CaptionButton(
      {required this.icon,
      required this.tooltip,
      required this.onTap,
      this.iconSize = 16,
      this.hover});

  final IconData icon;
  final double iconSize;
  final String tooltip;
  final Future<void> Function() onTap;
  final Color? hover;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  var _over = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = widget.hover;
    // No Tooltip here: this bar sits above the Navigator, so there is no Overlay to show one in.
    return MouseRegion(
        onEnter: (_) => setState(() => _over = true),
        onExit: (_) => setState(() => _over = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            width: 46,
            height: 36,
            alignment: Alignment.center,
            color: _over
                ? (tint ?? scheme.onSurface.withValues(alpha: 0.1))
                : Colors.transparent,
            child: Icon(widget.icon,
                size: widget.iconSize,
                color: _over && tint != null ? scheme.onError : scheme.onSurface),
          ),
        ),
    );
  }
}

/// The name of the app at the left of the title bar.
class TitleBrand extends StatelessWidget {
  const TitleBrand({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 12),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.cloud, size: 18, color: scheme.primary),
        const SizedBox(width: 8),
        const Text('Kumo', style: TextStyle(fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

/// An icon button in the title bar. Like the window buttons it has no tooltip (there is no Overlay
/// above the Navigator to show one in); it hands the place it sits at to [onTap], so that a menu
/// can open under it.
class TitleAction extends StatefulWidget {
  const TitleAction({super.key, required this.icon, required this.label, required this.onTap});

  final IconData icon;

  /// What a screen reader says.
  final String label;
  final void Function(Rect bounds) onTap;

  @override
  State<TitleAction> createState() => _TitleActionState();
}

class _TitleActionState extends State<TitleAction> {
  var _over = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: widget.label,
      excludeSemantics: true,
      onTap: () => _tap(context),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _over = true),
        onExit: (_) => setState(() => _over = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _tap(context),
          child: Container(
            width: 42,
            height: 36,
            alignment: Alignment.center,
            color: _over ? scheme.onSurface.withValues(alpha: 0.1) : Colors.transparent,
            child: Icon(widget.icon, size: 20, color: scheme.onSurface),
          ),
        ),
      ),
    );
  }

  void _tap(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    widget.onTap(box.localToGlobal(Offset.zero) & box.size);
  }
}
