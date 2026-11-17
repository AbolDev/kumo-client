import 'package:flutter/material.dart';

import '../l10n/extra.dart';

/// A small label next to the name of an option that most people never need ("Advanced"), or one that can
/// cut the connection when it is wrong ("Careful").
class OptionTag extends StatelessWidget {
  const OptionTag({super.key, this.caution = false});

  /// "Careful" in the colour of a warning, instead of "Advanced".
  final bool caution;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = caution ? scheme.errorContainer : scheme.tertiaryContainer;
    final foreground = caution ? scheme.onErrorContainer : scheme.onTertiaryContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(10)),
      child: Text(tr(context, caution ? 'cautionTag' : 'advancedTag'),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: foreground)),
    );
  }
}

/// The title of an option with its [OptionTag] after it.
Widget taggedTitle(String title, {bool caution = false}) => Row(children: [
      Flexible(child: Text(title)),
      const SizedBox(width: 8),
      OptionTag(caution: caution),
    ]);

/// An option with a switch. The switch stands at the end of the title's line only, and the description under
/// them takes the whole width (in a [SwitchListTile] the switch has a column of its own the height of the row,
/// so a description wraps into many more lines). A tap anywhere on the row turns it on or off.
class SwitchOption extends StatelessWidget {
  const SwitchOption({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
    this.secondary,
    this.titleTrailing,
    this.contentPadding,
    this.dense = false,
  });

  final Widget title;
  final Widget? subtitle;
  final bool value;

  /// Null shows the option disabled.
  final ValueChanged<bool>? onChanged;

  /// An icon (or another small widget) before the title. In a list every row has one, so that the texts
  /// start at the same place; it stands in the middle of the row, as in a [ListTile].
  final Widget? secondary;

  /// A small widget between the title and the switch (the information button of a long description).
  final Widget? titleTrailing;
  final EdgeInsetsGeometry? contentPadding;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = onChanged != null;
    Color faded(Color c) => enabled ? c : c.withValues(alpha: 0.38);
    final titleStyle = (dense ? theme.textTheme.bodyMedium : theme.textTheme.bodyLarge)?.copyWith(color: faded(scheme.onSurface));
    final subtitleStyle = theme.textTheme.bodyMedium?.copyWith(color: faded(scheme.onSurfaceVariant));
    return MergeSemantics(
      child: InkWell(
        onTap: enabled ? () => onChanged!(!value) : null,
        child: Padding(
          padding: (contentPadding ?? const EdgeInsets.symmetric(horizontal: 16))
              .add(EdgeInsets.symmetric(vertical: dense ? 4 : 8)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            if (secondary != null)
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 16),
                child: IconTheme.merge(data: IconThemeData(color: faded(scheme.onSurfaceVariant)), child: secondary!),
              ),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: DefaultTextStyle.merge(style: titleStyle, child: title)),
                  if (titleTrailing != null) titleTrailing!,
                  const SizedBox(width: 12),
                  Switch(
                    value: value,
                    onChanged: onChanged,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ]),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: DefaultTextStyle.merge(style: subtitleStyle, child: subtitle!),
                  ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// A description longer than this is cut to two lines under the option, with the whole text behind an
/// information button.
const longDescription = 90;

/// A switch with a short line under it: a long description is cut to two lines and the rest is behind
/// the information button, so that a page of options does not turn into a wall of text.
class InfoSwitchTile extends StatelessWidget {
  const InfoSwitchTile({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.value,
    required this.onChanged,
    this.tag = false,
    this.caution = false,
  });

  /// The icon before the title: every option of a list has one, the information button is not in its place.
  final IconData icon;
  final String title;
  final String description;
  final bool value;
  final ValueChanged<bool> onChanged;

  /// Shows the "Advanced" label (or, with [caution], "Careful").
  final bool tag;
  final bool caution;

  @override
  Widget build(BuildContext context) {
    final long = description.length > longDescription;
    return SwitchOption(
      value: value,
      onChanged: onChanged,
      title: tag || caution ? taggedTitle(title, caution: caution) : Text(title),
      subtitle: Text(description, maxLines: long ? 2 : null, overflow: long ? TextOverflow.ellipsis : null),
      secondary: Icon(icon),
      titleTrailing: long
          ? IconButton(
              tooltip: tr(context, 'moreInfo'),
              icon: const Icon(Icons.info_outline, size: 20),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              onPressed: () => showInfo(context, title, description),
            )
          : null,
    );
  }
}

/// A dialog with the whole description of an option.
Future<void> showInfo(BuildContext context, String title, String text) => showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(text)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog), child: Text(MaterialLocalizations.of(dialog).okButtonLabel)),
        ],
      ),
    );

/// Asks whether to put a section's options back to their defaults.
Future<bool> confirmReset(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        content: Text(tr(dialog, 'resetSectionAsk')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text(MaterialLocalizations.of(dialog).cancelButtonLabel)),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(tr(dialog, 'resetSectionDo'))),
        ],
      ),
    ) ??
    false;
