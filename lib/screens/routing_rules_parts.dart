import 'dart:convert';
import 'dart:io' show File, Platform;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../core/platform.dart';
import '../core/routing_rules.dart';
import '../core/rule_book.dart';
import '../core/rule_services.dart';
import '../core/vpn_channel.dart';
import '../l10n/extra.dart';
import '../widgets/app_icon.dart';

/// Whether this device can list its apps for a rule: a phone does, a computer lists the programs that run.
bool get canPickApps => isDesktop || Platform.isAndroid;

/// How the three actions look: an icon and a colour that mean the same wherever they show up (blocked is
/// red, through the VPN is the app's colour, direct is the third colour of the theme).
extension RuleActionUi on RuleAction {
  IconData get icon => switch (this) {
        RuleAction.block => Icons.block,
        RuleAction.proxy => Icons.shield_outlined,
        RuleAction.direct => Icons.call_made,
      };

  /// The keys of the texts: the title, the short name, what it does and an example.
  String get titleKey => switch (this) {
        RuleAction.block => 'ruleBlock',
        RuleAction.proxy => 'ruleProxy',
        RuleAction.direct => 'ruleDirect',
      };

  String get shortKey => switch (this) {
        RuleAction.block => 'rlBlockShort',
        RuleAction.proxy => 'rlProxyShort',
        RuleAction.direct => 'rlDirectShort',
      };

  String get descKey => switch (this) {
        RuleAction.block => 'rlBlockDesc',
        RuleAction.proxy => 'rlProxyDesc',
        RuleAction.direct => 'rlDirectDesc',
      };

  String get exampleKey => switch (this) {
        RuleAction.block => 'rlBlockEx',
        RuleAction.proxy => 'rlProxyEx',
        RuleAction.direct => 'rlDirectEx',
      };

  Color background(ColorScheme s) => switch (this) {
        RuleAction.block => s.errorContainer,
        RuleAction.proxy => s.primaryContainer,
        RuleAction.direct => s.tertiaryContainer,
      };

  Color foreground(ColorScheme s) => switch (this) {
        RuleAction.block => s.onErrorContainer,
        RuleAction.proxy => s.onPrimaryContainer,
        RuleAction.direct => s.onTertiaryContainer,
      };
}

/// The rounded square with an action's icon.
class ActionBadge extends StatelessWidget {
  const ActionBadge(this.action, {super.key, this.size = 40});

  final RuleAction action;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: action.background(scheme), borderRadius: BorderRadius.circular(size / 3)),
      child: Icon(action.icon, size: size * 0.55, color: action.foreground(scheme)),
    );
  }
}

/// Text that is a name, an address or a rule: it reads left to right whatever the language is.
class CodeText extends StatelessWidget {
  const CodeText(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Text(text, textDirection: TextDirection.ltr, style: style);
}

// ---------------------------------------------------------------------------------------------------
// Adding

/// The sheet to add rules: what should happen, then either a line to type (a website, an address, a port)
/// or a list to choose from. It stays open so that several rules can be added one after another.
/// [onAdd] adds the rules to an action's list and returns how many were new.
Future<void> showAddRuleSheet(
  BuildContext context, {
  required RuleAction initial,
  required RuleLists Function() lists,
  required int Function(RuleAction action, List<String> rules) onAdd,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (_) => _AddRuleSheet(initial: initial, lists: lists, onAdd: onAdd),
  );
}

class _AddRuleSheet extends StatefulWidget {
  const _AddRuleSheet({required this.initial, required this.lists, required this.onAdd});

  final RuleAction initial;
  final RuleLists Function() lists;
  final int Function(RuleAction action, List<String> rules) onAdd;

  @override
  State<_AddRuleSheet> createState() => _AddRuleSheetState();
}

class _AddRuleSheetState extends State<_AddRuleSheet> {
  late RuleAction _action = widget.initial;
  final _text = TextEditingController();
  String? _done;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  RouteRule? get _rule => _text.text.trim().isEmpty ? null : parseUserRule(_text.text);

  bool get _exists => _rule != null && widget.lists().of(_action).contains(_rule!.text);

  void _add(List<String> rules) {
    final n = widget.onAdd(_action, rules);
    setState(() {
      _done = n == 0
          ? tr(context, 'rlAlreadyHere', {'list': tr(context, _action.titleKey)})
          : n == 1 && rules.length == 1
              ? tr(context, 'rlAdded', {'rule': rules.first})
              : tr(context, 'rlAddedN', {'n': n});
    });
  }

  void _submit() {
    final rule = _rule;
    if (rule == null) return;
    _add([rule.text]);
    _text.clear();
    setState(() {});
  }

  Set<String> _taken(RuleKind kind) => {
        for (final r in widget.lists().of(_action))
          if (parseRouteRule(r) case final p? when p.kind == kind) p.value,
      };

  Future<void> _pickApps() async {
    final ids = await Navigator.push<List<String>>(
      context,
      MaterialPageRoute(
        settings: const RouteSettings(name: '/RuleAppsPage'),
        builder: (_) => RuleAppPickerPage(taken: _taken(RuleKind.app)),
      ),
    );
    if (ids != null && ids.isNotEmpty && mounted) _add([for (final id in ids) 'app:$id']);
  }

  Future<void> _pickServices() async {
    final ids = await Navigator.push<List<String>>(
      context,
      MaterialPageRoute(
        settings: const RouteSettings(name: '/RuleServicesPage'),
        builder: (_) => RuleServicePickerPage(taken: _taken(RuleKind.service)),
      ),
    );
    if (ids != null && ids.isNotEmpty && mounted) _add([for (final id in ids) 'service:$id']);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final typed = _text.text.trim();
    final rule = _rule;
    final String? error = typed.isNotEmpty && rule == null ? tr(context, 'rlInvalid') : null;
    final helper = rule != null
        ? (_exists
            ? tr(context, 'rlAlreadyHere', {'list': tr(context, _action.titleKey)})
            : '${tr(context, 'ruleType_${rule.kind.name}')}: ${rule.text}')
        : tr(context, 'rlTypeExamples');
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text(tr(context, 'ruleAdd'), style: text.titleLarge),
          const SizedBox(height: 16),
          Text(tr(context, 'rlAddWhat'), style: text.labelLarge?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          SegmentedButton<RuleAction>(
            showSelectedIcon: false,
            segments: [
              for (final a in RuleAction.values)
                ButtonSegment(value: a, label: Text(tr(context, a.shortKey), maxLines: 1, overflow: TextOverflow.ellipsis)),
            ],
            selected: {_action},
            onSelectionChanged: (s) => setState(() {
              _action = s.first;
              _done = null;
            }),
          ),
          const SizedBox(height: 8),
          Text(tr(context, _action.descKey), style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('rl-text'),
            controller: _text,
            autofocus: isDesktop,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            autocorrect: false,
            enableSuggestions: false,
            textDirection: TextDirection.ltr,
            onChanged: (_) => setState(() => _done = null),
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: tr(context, 'rlTypeLabel'),
              hintText: 'example.com',
              helperText: helper,
              helperMaxLines: 2,
              errorText: error,
              errorMaxLines: 3,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            key: const ValueKey('rl-add'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: rule == null || _exists ? null : _submit,
            icon: const Icon(Icons.add),
            label: Text(tr(context, 'ruleAdd')),
          ),
          if (_done != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Row(children: [
                Icon(Icons.check_circle_outline, size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(child: Text(_done!, style: text.bodyMedium?.copyWith(color: scheme.primary))),
              ]),
            ),
          const SizedBox(height: 20),
          Text(tr(context, 'rlOrPick'), style: text.labelLarge?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          if (canPickApps)
            _PickTile(
              icon: Icons.apps,
              title: tr(context, isDesktop ? 'rlPickPrograms' : 'rlPickApps'),
              subtitle: tr(context, isDesktop ? 'rlPickProgramsDesc' : 'rlPickAppsDesc'),
              onTap: _pickApps,
            ),
          _PickTile(
            icon: Icons.public,
            title: tr(context, 'rlPickServices'),
            subtitle: tr(context, 'rlPickServicesDesc'),
            onTap: _pickServices,
          ),
        ]),
      ),
    );
  }
}

class _PickTile extends StatelessWidget {
  const _PickTile({required this.icon, required this.title, required this.subtitle, required this.onTap});

  final IconData icon;
  final String title, subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: scheme.secondaryContainer,
        child: Icon(icon, color: scheme.onSecondaryContainer),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

// ---------------------------------------------------------------------------------------------------
// Testing

/// The sheet to find out what happens to a website, an address, a port or an app: which rule decides, and
/// what the others would have said.
Future<void> showTestRuleSheet(
  BuildContext context, {
  required RuleLists Function() lists,
  required Map<String, String> appNames,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (_) => _TestSheet(lists: lists, appNames: appNames),
  );
}

class _TestSheet extends StatefulWidget {
  const _TestSheet({required this.lists, required this.appNames});

  final RuleLists Function() lists;
  final Map<String, String> appNames;

  @override
  State<_TestSheet> createState() => _TestSheetState();
}

class _TestSheetState extends State<_TestSheet> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  String _ruleTitle(String rule) {
    final r = parseRouteRule(rule);
    if (r == null) return rule;
    if (r.kind == RuleKind.app) return widget.appNames[r.value] ?? r.value;
    if (r.kind == RuleKind.service) return ruleServices[r.value]?.name ?? r.value;
    return rule;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final query = _text.text.trim();
    final hits = query.isEmpty ? const <RuleHit>[] : matchRules(widget.lists(), query, appNames: widget.appNames);
    final first = hits.isEmpty ? null : hits.first;
    final bg = first?.action.background(scheme) ?? scheme.surfaceContainerHighest;
    final fg = first?.action.foreground(scheme) ?? scheme.onSurfaceVariant;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text(tr(context, 'rlTestTitle'), style: text.titleLarge),
          const SizedBox(height: 4),
          Text(tr(context, 'rlTestDesc'), style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('rl-test-text'),
            controller: _text,
            autofocus: isDesktop,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.search,
            autocorrect: false,
            enableSuggestions: false,
            textDirection: TextDirection.ltr,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: tr(context, 'rlTestLabel'),
              hintText: 'youtube.com',
              helperText: tr(context, 'rlTestExamples'),
              helperMaxLines: 2,
              prefixIcon: const Icon(Icons.search),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          if (query.isEmpty)
            Text(tr(context, 'rlTestEmpty'), style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant))
          else
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(16)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(first?.action.icon ?? Icons.help_outline, color: fg),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      first == null
                          ? tr(context, 'rlTestNone')
                          : tr(context, switch (first.action) {
                              RuleAction.block => 'rlTestBlock',
                              RuleAction.proxy => 'rlTestProxy',
                              RuleAction.direct => 'rlTestDirect',
                            }),
                      style: text.titleMedium?.copyWith(color: fg, fontWeight: FontWeight.w700),
                    ),
                  ),
                ]),
                const SizedBox(height: 8),
                if (first == null)
                  Text(tr(context, 'rlTestNoneBody'), style: TextStyle(color: fg, height: 1.4))
                else ...[
                  Text(tr(context, 'rlTestBy'), style: TextStyle(color: fg)),
                  const SizedBox(height: 2),
                  CodeText(_ruleTitle(first.rule), style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
                ],
              ]),
            ),
          if (hits.length > 1) ...[
            const SizedBox(height: 16),
            Text(tr(context, 'rlTestAlso'), style: text.labelLarge?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 4),
            for (final h in hits.skip(1))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: ActionBadge(h.action, size: 32),
                title: CodeText(_ruleTitle(h.rule)),
                subtitle: Text(tr(context, h.action.titleKey)),
              ),
          ],
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------------
// Importing

/// A dialog to paste (or open) a text of rules and see what is in it before it is added. The result is
/// what was found, or null when the dialog was cancelled.
Future<RuleLists?> showImportRulesDialog(BuildContext context) {
  return showDialog<RuleLists>(context: context, builder: (_) => const _ImportDialog());
}

class _ImportDialog extends StatefulWidget {
  const _ImportDialog();

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    if (clip?.text != null && mounted) setState(() => _text.text = clip!.text!);
  }

  Future<void> _file() async {
    final picked = await FilePicker.platform.pickFiles(withData: true);
    final bytes = picked?.files.single.bytes;
    if (bytes == null || !mounted) return;
    setState(() => _text.text = utf8.decode(bytes, allowMalformed: true));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final found = parseRulesText(_text.text);
    final empty = _text.text.trim().isEmpty;
    return AlertDialog(
      icon: Icon(Icons.file_download_outlined, size: 32, color: scheme.primary),
      title: Text(tr(context, 'rlImportTitle'), textAlign: TextAlign.center),
      content: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 280, maxWidth: 480),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(tr(context, 'rlImportHint'), style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
            const SizedBox(height: 12),
            TextField(
              controller: _text,
              minLines: 5,
              maxLines: 10,
              keyboardType: TextInputType.multiline,
              autocorrect: false,
              enableSuggestions: false,
              textDirection: TextDirection.ltr,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '[block]\nads.example.com\n\n[proxy]\nservice:telegram\n\n[direct]\napp:com.bank.app',
              ),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              TextButton.icon(onPressed: _paste, icon: const Icon(Icons.content_paste), label: Text(tr(context, 'rlImportPaste'))),
              TextButton.icon(onPressed: _file, icon: const Icon(Icons.folder_open), label: Text(tr(context, 'rlImportFile'))),
            ]),
            const SizedBox(height: 4),
            Text(
              empty
                  ? tr(context, 'rlImportNone')
                  : found.count == 0
                      ? tr(context, 'rlImportNothingValid')
                      : tr(context, 'rlImportFound', {
                          'n': found.count,
                          'b': found.rules.block.length,
                          'p': found.rules.proxy.length,
                          'd': found.rules.direct.length,
                        }),
              style: TextStyle(color: found.count > 0 ? scheme.primary : scheme.onSurfaceVariant),
            ),
            if (found.skipped > 0)
              Text(tr(context, 'rlImportSkipped', {'n': found.skipped}), style: TextStyle(color: scheme.error)),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(MaterialLocalizations.of(context).cancelButtonLabel)),
        FilledButton(
          onPressed: found.count == 0 ? null : () => Navigator.pop(context, found.rules),
          child: Text(tr(context, 'rlImportBtn')),
        ),
      ],
    );
  }
}

/// Saves a text of rules to a file the user chooses; true when it was saved.
Future<bool> saveRulesFile(String text) async {
  final bytes = utf8.encode(text);
  final path = await FilePicker.platform
      .saveFile(fileName: 'kumo-rules.txt', bytes: Uint8List.fromList(bytes), type: FileType.any);
  if (path == null) return false;
  if (!Platform.isAndroid) await File(path).writeAsBytes(bytes);
  return true;
}

/// Puts [text] on the clipboard.
Future<void> copyText(String text) => Clipboard.setData(ClipboardData(text: text));

// ---------------------------------------------------------------------------------------------------
// Lists to choose from

/// A page to choose several things from a list and add them: a search box, a check mark on each, and a button
/// with how many are chosen. [taken] are the ones that are rules already.
abstract class _PickerState<T extends StatefulWidget> extends State<T> {
  final search = TextEditingController();
  final chosen = <String>{};

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Widget scaffold({required String title, required Widget list, Widget? extra}) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                labelText: tr(context, 'ruleSearch'),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          if (extra != null) extra,
          Expanded(child: list),
        ]),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: chosen.isEmpty ? null : () => Navigator.pop(context, chosen.toList()),
              child: Text(chosen.isEmpty ? tr(context, 'rulePickSome') : tr(context, 'ruleAddN', {'n': chosen.length})),
            ),
          ),
        ),
      );
}

class RuleAppPickerPage extends StatefulWidget {
  const RuleAppPickerPage({super.key, required this.taken});

  final Set<String> taken;

  @override
  State<RuleAppPickerPage> createState() => _RuleAppPickerPageState();
}

class _RuleAppPickerPageState extends _PickerState<RuleAppPickerPage> {
  List<AppEntry>? _apps;
  final _custom = TextEditingController();

  @override
  void initState() {
    super.initState();
    VpnChannel.listApps().then((l) {
      if (mounted) setState(() => _apps = l);
    }).catchError((_) {
      if (mounted) setState(() => _apps = const []);
    });
  }

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  void _addCustom(String v) {
    final name = v.trim();
    if (name.isEmpty || parseRouteRule('app:$name') == null) return;
    setState(() {
      (_apps ??= []).add(AppEntry(name, name));
      chosen.add(name);
    });
    _custom.clear();
  }

  @override
  Widget build(BuildContext context) {
    final q = search.text.trim().toLowerCase();
    final shown = [
      for (final a in _apps ?? const <AppEntry>[])
        if (q.isEmpty || a.label.toLowerCase().contains(q) || a.id.toLowerCase().contains(q)) a,
    ];
    return scaffold(
      title: tr(context, 'ruleAppsTitle'),
      extra: isDesktop
          ? Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: TextField(
                controller: _custom,
                onSubmitted: _addCustom,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.add),
                  labelText: tr(context, 'addProcess'),
                  border: const OutlineInputBorder(),
                ),
              ),
            )
          : null,
      list: _apps == null
          ? const Center(child: CircularProgressIndicator())
          : shown.isEmpty
              ? Center(child: Text(tr(context, 'ruleNoApps')))
              : ListView(children: [
                  for (final a in shown)
                    CheckboxListTile(
                      secondary: isDesktop ? const Icon(Icons.apps) : AppIcon(id: a.id),
                      value: widget.taken.contains(a.id) || chosen.contains(a.id),
                      onChanged: widget.taken.contains(a.id)
                          ? null
                          : (v) => setState(() => v == true ? chosen.add(a.id) : chosen.remove(a.id)),
                      title: Text(a.label),
                      subtitle: widget.taken.contains(a.id)
                          ? Text(tr(context, 'ruleAlready'))
                          : (a.label == a.id ? null : Text(a.id, textDirection: TextDirection.ltr)),
                    ),
                ]),
    );
  }
}

class RuleServicePickerPage extends StatefulWidget {
  const RuleServicePickerPage({super.key, required this.taken});

  final Set<String> taken;

  @override
  State<RuleServicePickerPage> createState() => _RuleServicePickerPageState();
}

class _RuleServicePickerPageState extends _PickerState<RuleServicePickerPage> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final q = search.text.trim().toLowerCase();
    final shown = [
      for (final s in ruleServiceList)
        if (q.isEmpty || s.name.toLowerCase().contains(q) || s.domains.any((d) => d.contains(q))) s,
    ];
    final groups = <String>[];
    for (final s in shown) {
      if (!groups.contains(s.group)) groups.add(s.group);
    }
    return scaffold(
      title: tr(context, 'ruleServicesTitle'),
      list: shown.isEmpty
          ? Center(child: Text(tr(context, 'ruleNoServices')))
          : ListView(children: [
              for (final g in groups) ...[
                Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(16, 14, 16, 4),
                  child: Text(tr(context, g),
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(color: scheme.onSurfaceVariant)),
                ),
                for (final s in shown.where((s) => s.group == g))
                  CheckboxListTile(
                    secondary: ServiceAvatar(s),
                    value: widget.taken.contains(s.id) || chosen.contains(s.id),
                    onChanged: widget.taken.contains(s.id)
                        ? null
                        : (v) => setState(() => v == true ? chosen.add(s.id) : chosen.remove(s.id)),
                    title: Text(s.name),
                    subtitle: Text(widget.taken.contains(s.id)
                        ? tr(context, 'ruleAlready')
                        : tr(context, 'ruleServiceSites', {'n': s.domains.length})),
                  ),
              ],
            ]),
    );
  }
}

/// A round mark with the first letter of a service.
class ServiceAvatar extends StatelessWidget {
  const ServiceAvatar(this.service, {super.key, this.radius});

  final RuleService? service;
  final double? radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CircleAvatar(
      radius: radius,
      backgroundColor: scheme.secondaryContainer,
      child: Text((service?.name ?? '?').characters.first,
          style: TextStyle(color: scheme.onSecondaryContainer, fontWeight: FontWeight.w700)),
    );
  }
}
