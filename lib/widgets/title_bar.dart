import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../l10n/extra.dart';

/// Windows: the app draws its own title bar (drag area plus minimize, maximize and close),
/// so the window matches the rest of the app.
class AppTitleBar extends StatefulWidget {
  const AppTitleBar({super.key});

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
              _CaptionButton(
                  icon: Icons.remove,
                  tooltip: tr(context, 'winMinimize'),
                  onTap: windowManager.minimize),
              _CaptionButton(
                  icon: _maximized ? Icons.filter_none : Icons.crop_square,
                  iconSize: _maximized ? 14 : 16,
                  tooltip:
                      tr(context, _maximized ? 'winRestore' : 'winMaximize'),
                  onTap: () async => _maximized
                      ? windowManager.unmaximize()
                      : windowManager.maximize()),
              _CaptionButton(
                  icon: Icons.close,
                  tooltip: tr(context, 'winClose'),
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
    // No Tooltip here: this bar sits above the Navigator, so there is no Overlay to show one in; a
    // screen reader gets the name from the semantics label instead.
    return Semantics(
        button: true,
        label: widget.tooltip,
        excludeSemantics: true,
        onTap: widget.onTap,
        child: MouseRegion(
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
                  color: _over && tint != null
                      ? scheme.onError
                      : scheme.onSurface),
            ),
          ),
        ));
  }
}
