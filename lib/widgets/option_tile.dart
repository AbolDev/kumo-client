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

/// A description longer than this is cut to two lines under the option, with the whole text behind an
/// information button.
const longDescription = 90;

/// A switch with a short line under it: a long description is cut to two lines and the rest is behind
/// the information button, so that a page of options does not turn into a wall of text.
class InfoSwitchTile extends StatelessWidget {
  const InfoSwitchTile({
    super.key,
    required this.title,
    required this.description,
    required this.value,
    required this.onChanged,
    this.tag = false,
    this.caution = false,
  });

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
    return SwitchListTile(
      value: value,
      onChanged: onChanged,
      title: tag || caution ? taggedTitle(title, caution: caution) : Text(title),
      subtitle: Text(description, maxLines: long ? 2 : null, overflow: long ? TextOverflow.ellipsis : null),
      secondary: long
          ? IconButton(
              tooltip: tr(context, 'moreInfo'),
              icon: const Icon(Icons.info_outline),
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
