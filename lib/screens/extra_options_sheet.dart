import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;

import '../core/extra_options.dart';
import '../core/singbox_config.dart' show parseExtraJson;
import '../l10n/extra.dart';
import '../l10n/strings.dart' show S;
import 'network_settings.dart' show editJson;

/// The extra options of the connection as a sheet with a field for each common option, and the JSON for the
/// rest ("Edit as JSON"). Returns the text to keep (empty = none), or null when it is cancelled.
Future<String?> editExtraOptions(
  BuildContext context, {
  required String title,
  required String description,
  required String jsonDescription,
  required String initial,
  required List<ExtraOption> options,
}) async {
  var start = initial;
  // Text that is not a JSON object cannot be shown in fields: it is opened as JSON first, to be mended.
  if (initial.trim().isNotEmpty && parseExtraJson(initial) == null) {
    final fixed = await editJson(context, title, jsonDescription, initial);
    if (fixed == null) return null;
    start = fixed;
  }
  if (!context.mounted) return null;
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (sheet) => _ExtraSheet(
        title: title, description: description, jsonDescription: jsonDescription, initial: start, options: options),
  );
}

class _ExtraSheet extends StatefulWidget {
  const _ExtraSheet(
      {required this.title,
      required this.description,
      required this.jsonDescription,
      required this.initial,
      required this.options});

  final String title;
  final String description;
  final String jsonDescription;
  final String initial;
  final List<ExtraOption> options;

  @override
  State<_ExtraSheet> createState() => _ExtraSheetState();
}

class _ExtraSheetState extends State<_ExtraSheet> {
  late Map<String, dynamic> _json = parseExtraJson(widget.initial) ?? <String, dynamic>{};

  /// Changes when the JSON is edited as text, so that the fields start again from it.
  int _rev = 0;

  void _set(ExtraOption o, Object? value) => setState(() => _json = withOption(_json, o, value));

  Future<void> _editJson() async {
    final text = await editJson(context, widget.title, widget.jsonDescription, encodeExtra(_json));
    if (text == null) return;
    setState(() {
      _json = parseExtraJson(text) ?? <String, dynamic>{};
      _rev++;
    });
  }

  Widget _field(ExtraOption o) {
    final label = tr(context, o.labelKey);
    final value = readOption(_json, o);
    switch (o.kind) {
      case ExtraKind.toggle:
        return SwitchListTile(
          key: ValueKey('xo:${o.id}:$_rev'),
          contentPadding: EdgeInsets.zero,
          value: value == true,
          onChanged: (v) => _set(o, v),
          title: Text(label),
        );
      case ExtraKind.choice:
        final shown = value is String ? value : '';
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: DropdownButtonFormField<String>(
            key: ValueKey('xo:${o.id}:$_rev'),
            value: shown,
            decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
            items: [
              const DropdownMenuItem(value: '', child: Text('-')),
              for (final c in {...o.choices, if (shown.isNotEmpty) shown}) DropdownMenuItem(value: c, child: Text(c)),
            ],
            onChanged: (v) => _set(o, v),
          ),
        );
      case ExtraKind.number:
      case ExtraKind.text:
        final number = o.kind == ExtraKind.number;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: TextFormField(
            key: ValueKey('xo:${o.id}:$_rev'),
            initialValue: value == null ? '' : '$value',
            keyboardType: number ? TextInputType.number : TextInputType.text,
            inputFormatters: number ? [FilteringTextInputFormatter.digitsOnly] : null,
            autocorrect: false,
            textDirection: TextDirection.ltr,
            decoration: InputDecoration(labelText: label, hintText: o.hint, border: const OutlineInputBorder()),
            onChanged: (v) => _set(o, number ? int.tryParse(v.trim()) : v),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(widget.title, style: text.titleLarge),
          const SizedBox(height: 4),
          Text(widget.description, style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          for (final o in widget.options) _field(o),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: _editJson,
              icon: const Icon(Icons.data_object),
              label: Text(tr(context, 'extraEditJson')),
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                onPressed: () => Navigator.pop(context),
                child: Text(S.of(context).cancel),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                onPressed: () => Navigator.pop(context, encodeExtra(_json)),
                child: Text(S.of(context).save),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}
