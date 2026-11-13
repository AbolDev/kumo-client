import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;

import '../core/net_options.dart';
import '../core/platform.dart';
import '../core/routing_rules.dart';
import '../core/rule_book.dart';
import '../core/rule_services.dart';
import '../core/vpn_channel.dart';
import '../l10n/extra.dart';
import '../state/app_state.dart';
import '../widgets/app_icon.dart';
import 'routing_rules_parts.dart';
import 'share_sheet.dart';

/// The user's own routing rules: apps, popular services, websites, addresses and ports that are always
/// blocked, always sent through the VPN, or always sent direct, whatever the country and app settings say.
///
/// The page is the three lists in the order they are applied (block, then VPN, then direct), each with its
/// colour and its count. A rule is added by choosing it from a list or typing one line; removing one can be
/// undone; "Test" tells what would happen to a website, an address, a port or an app; the rules can be
/// copied, saved to a file and imported again.
class RoutingRulesPage extends StatefulWidget {
  const RoutingRulesPage({super.key, required this.state, this.update});

  final AppState state;

  /// How a change of the options is made and saved: [AppState.updateNet] unless a test gives its own.
  final Future<void> Function(void Function(NetOptions o) change)? update;

  @override
  State<RoutingRulesPage> createState() => _RoutingRulesPageState();
}

class _Entry {
  const _Entry(this.action, this.text, this.rule);

  final RuleAction action;
  final String text;
  final RouteRule rule;
}

enum _Menu { load, copy, save, clear }

class _RoutingRulesPageState extends State<RoutingRulesPage> {
  AppState get state => widget.state;

  /// The apps of this device by id, for the names of the app rules (loaded once).
  Map<String, String> _appNames = const {};
  final _search = TextEditingController();
  RuleAction _lastAction = RuleAction.direct;

  @override
  void initState() {
    super.initState();
    VpnChannel.listApps().then((l) {
      if (mounted) setState(() => _appNames = {for (final a in l) a.id: a.label});
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------------------------- the rules

  RuleLists get _lists => RuleLists(block: state.net.blockRules, proxy: state.net.proxyRules, direct: state.net.directRules);

  void _write(RuleLists l) {
    void change(NetOptions o) {
      o.blockRules = l.block;
      o.proxyRules = l.proxy;
      o.directRules = l.direct;
    }

    final update = widget.update;
    unawaited(update != null ? update(change) : state.updateNet(change));
    if (mounted) setState(() {});
  }

  /// Applies [next] and says so, with a way back.
  void _change(RuleLists next, String message) {
    final before = _lists;
    _write(next);
    toast(context, message, actionLabel: tr(context, 'rlUndo'), onAction: () => _write(before));
  }

  /// Adds [rules] to the list of [action]; how many were not there already.
  int _addRules(RuleAction action, List<String> rules) {
    final l = _lists;
    final merged = withRules(l.of(action), rules);
    final added = merged.length - l.of(action).length;
    if (added == 0) return 0;
    l.of(action)
      ..clear()
      ..addAll(merged);
    _lastAction = action;
    _write(l);
    return added;
  }

  void _remove(_Entry e) {
    final l = _lists..of(e.action).remove(e.text);
    _change(l, tr(context, 'rlRemoved', {'rule': _title(e.rule)}));
  }

  void _move(_Entry e, RuleAction to) {
    final l = _lists..of(e.action).remove(e.text);
    final moved = withRules(l.of(to), [e.text]);
    l.of(to)
      ..clear()
      ..addAll(moved);
    _change(l, tr(context, 'rlMoved', {'list': tr(context, to.titleKey)}));
  }

  void _clearAll() {
    final n = _lists.count;
    if (n == 0) return;
    _change(RuleLists(), tr(context, 'rlClearedAll', {'n': n}));
  }

  // ----------------------------------------------------------------------------------- what to show

  String _title(RouteRule r) => switch (r.kind) {
        RuleKind.app => _appNames[r.value] ?? r.value,
        RuleKind.service => ruleServices[r.value]?.name ?? r.value,
        _ => r.text,
      };

  bool _matchesSearch(_Entry e, String q) {
    final r = e.rule;
    final hay = [
      e.text,
      _title(r),
      if (r.kind == RuleKind.service) ...?ruleServices[r.value]?.domains,
      tr(context, 'ruleType_${r.kind.name}'),
    ].join('\n').toLowerCase();
    return hay.contains(q);
  }

  // ------------------------------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'ruleTitle')),
        actions: [
          IconButton(
            tooltip: tr(context, 'rlTestTitle'),
            icon: const Icon(Icons.fact_check_outlined),
            onPressed: () => showTestRuleSheet(context, lists: () => _lists, appNames: _appNames),
          ),
          PopupMenuButton<_Menu>(
            onSelected: _onMenu,
            itemBuilder: (_) => [
              _menuItem(_Menu.load, Icons.file_download_outlined, 'rlImportTitle'),
              _menuItem(_Menu.copy, Icons.copy_outlined, 'rlCopy'),
              _menuItem(_Menu.save, Icons.save_alt, 'rlSave'),
              const PopupMenuDivider(),
              _menuItem(_Menu.clear, Icons.delete_sweep_outlined, 'rlClearAll'),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openAdd(_lastAction),
        icon: const Icon(Icons.add),
        label: Text(tr(context, 'ruleAdd')),
      ),
      body: ListenableBuilder(listenable: state, builder: (context, _) => _body(context)),
    );
  }

  PopupMenuItem<_Menu> _menuItem(_Menu value, IconData icon, String key) => PopupMenuItem(
        value: value,
        child: Row(children: [Icon(icon, size: 20), const SizedBox(width: 12), Flexible(child: Text(tr(context, key)))]),
      );

  void _openAdd(RuleAction action) => showAddRuleSheet(context, initial: action, lists: () => _lists, onAdd: _addRules);

  Future<void> _onMenu(_Menu m) async {
    switch (m) {
      case _Menu.load:
        final found = await showImportRulesDialog(context);
        if (found == null || !mounted) return;
        final l = _lists;
        var added = 0;
        for (final a in RuleAction.values) {
          final merged = withRules(l.of(a), found.of(a));
          added += merged.length - l.of(a).length;
          l.of(a)
            ..clear()
            ..addAll(merged);
        }
        if (added == 0) {
          toast(context, tr(context, 'rlImportNothingNew'));
        } else {
          _change(l, tr(context, 'rlImportDone', {'n': added}));
        }
      case _Menu.copy:
        if (_lists.count == 0) {
          toast(context, tr(context, 'rlNothingToExport'));
          return;
        }
        await copyText(exportRules(_lists));
        if (mounted) toast(context, tr(context, 'rlCopied'), kind: ToastKind.ok);
      case _Menu.save:
        if (_lists.count == 0) {
          toast(context, tr(context, 'rlNothingToExport'));
          return;
        }
        final saved = await saveRulesFile(exportRules(_lists));
        if (mounted && saved) toast(context, tr(context, 'rlSaved'), kind: ToastKind.ok);
      case _Menu.clear:
        _clearAll();
    }
  }

  Widget _body(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lists = _lists;
    final total = lists.count;
    final q = _search.text.trim().toLowerCase();
    final all = <_Entry>[
      for (final a in RuleAction.values)
        for (final t in lists.of(a))
          if (parseRouteRule(t) case final r?) _Entry(a, t, r),
    ];
    final shown = [for (final e in all) if (q.isEmpty || _matchesSearch(e, q)) e];
    final hasApps = all.any((e) => e.rule.kind == RuleKind.app);

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 112),
          children: [
            _InfoCard(icon: Icons.info_outline, title: tr(context, 'rlOrderTitle'), body: tr(context, 'rlOrderBody')),
            if (hasApps && !state.net.tun)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _InfoCard(
                  icon: Icons.warning_amber_rounded,
                  body: tr(context, 'ruleAppNote'),
                  color: scheme.tertiaryContainer,
                  onColor: scheme.onTertiaryContainer,
                ),
              ),
            if (total == 0) const _EmptyIntro(),
            if (total >= 6)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: tr(context, 'rlSearchHint'),
                    border: const OutlineInputBorder(),
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: tr(context, 'rlSearchClear'),
                            icon: const Icon(Icons.close),
                            onPressed: () => setState(_search.clear),
                          ),
                  ),
                ),
              ),
            if (q.isNotEmpty && shown.isEmpty)
              _NoMatch(query: _search.text.trim(), onAdd: _addFromSearch)
            else
              for (final a in RuleAction.values)
                if (q.isEmpty || shown.any((e) => e.action == a))
                  _section(context, a, [for (final e in shown) if (e.action == a) e], lists),
          ],
        ),
      ),
    );
  }

  void _addFromSearch(RuleAction a, RouteRule rule) {
    final n = _addRules(a, [rule.text]);
    _search.clear();
    toast(context, n == 0 ? tr(context, 'rlAlreadyHere', {'list': tr(context, a.titleKey)}) : tr(context, 'rlAdded', {'rule': rule.text}),
        kind: n == 0 ? ToastKind.info : ToastKind.ok);
  }

  Widget _section(BuildContext context, RuleAction a, List<_Entry> rows, RuleLists lists) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(4, 24, 0, 10),
        child: Row(children: [
          ActionBadge(a),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${a.index + 1}. ${tr(context, a.titleKey)}', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              Text(tr(context, a.descKey), style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ]),
          ),
          if (rows.isNotEmpty)
            Container(
              margin: const EdgeInsetsDirectional.only(start: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
              decoration: BoxDecoration(color: a.background(scheme), borderRadius: BorderRadius.circular(12)),
              child: Text('${rows.length}', style: TextStyle(color: a.foreground(scheme), fontWeight: FontWeight.w700)),
            ),
          IconButton(
            tooltip: tr(context, 'rlAddTo', {'list': tr(context, a.titleKey)}),
            icon: const Icon(Icons.add_circle_outline),
            onPressed: () => _openAdd(a),
          ),
        ]),
      ),
      if (rows.isEmpty)
        _EmptySection(action: a, onAdd: () => _openAdd(a))
      else
        Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: scheme.outlineVariant),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) Divider(height: 1, color: scheme.outlineVariant),
              _tile(context, rows[i], lists),
            ],
          ]),
        ),
    ]);
  }

  Widget _leading(_Entry e) {
    final scheme = Theme.of(context).colorScheme;
    switch (e.rule.kind) {
      case RuleKind.app:
        return isDesktop ? const SizedBox(width: 36, height: 36, child: Icon(Icons.apps)) : AppIcon(id: e.rule.value, size: 36);
      case RuleKind.service:
        return ServiceAvatar(ruleServices[e.rule.value]);
      default:
        return CircleAvatar(
          backgroundColor: scheme.surfaceContainerHighest,
          child: Icon(
            switch (e.rule.kind) {
              RuleKind.ip => Icons.numbers,
              RuleKind.port => Icons.settings_ethernet,
              RuleKind.keyword || RuleKind.regex => Icons.manage_search,
              _ => Icons.language,
            },
            color: scheme.onSurfaceVariant,
          ),
        );
    }
  }

  String _subtitle(_Entry e) => switch (e.rule.kind) {
        RuleKind.app when _appNames[e.rule.value] != null => e.rule.value,
        RuleKind.service => tr(context, 'ruleServiceSites', {'n': ruleServices[e.rule.value]?.domains.length ?? 0}),
        _ => tr(context, 'ruleType_${e.rule.kind.name}'),
      };

  Widget _tile(BuildContext context, _Entry e, RuleLists lists) {
    final scheme = Theme.of(context).colorScheme;
    final wins = lists.firstWith(e.text);
    final plain = e.rule.kind != RuleKind.service && !(e.rule.kind == RuleKind.app && _appNames[e.rule.value] != null);
    return Dismissible(
      key: ValueKey('${e.action.name}|${e.text}'),
      background: _swipeBackground(scheme, AlignmentDirectional.centerStart),
      secondaryBackground: _swipeBackground(scheme, AlignmentDirectional.centerEnd),
      onDismissed: (_) => _remove(e),
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.delete): () => _remove(e),
          const SingleActivator(LogicalKeyboardKey.backspace): () => _remove(e),
        },
        child: ListTile(
          tileColor: scheme.surfaceContainerLow,
          leading: _leading(e),
          title: Text(_title(e.rule), textDirection: plain ? TextDirection.ltr : null),
          subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_subtitle(e), textDirection: e.rule.kind == RuleKind.app && _appNames[e.rule.value] != null ? TextDirection.ltr : null),
            if (wins != null && wins != e.action)
              Text(tr(context, 'rlOverridden', {'list': tr(context, wins.titleKey)}),
                  style: TextStyle(color: scheme.tertiary, fontWeight: FontWeight.w600)),
          ]),
          trailing: IconButton(
            tooltip: tr(context, 'rlRemove'),
            icon: const Icon(Icons.close),
            onPressed: () => _remove(e),
          ),
          onTap: () => _openRow(e),
        ),
      ),
    );
  }

  Widget _swipeBackground(ColorScheme scheme, AlignmentGeometry alignment) => Container(
        color: scheme.errorContainer,
        alignment: alignment,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Icon(Icons.delete_outline, color: scheme.onErrorContainer),
      );

  /// What can be done with one rule: move it to another list, or remove it.
  Future<void> _openRow(_Entry e) {
    final scheme = Theme.of(context).colorScheme;
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (sheet) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: ActionBadge(e.action),
            title: CodeText(_title(e.rule), style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text('${tr(context, e.action.titleKey)} · ${_subtitle(e)}'),
          ),
          const Divider(height: 1),
          for (final a in RuleAction.values)
            if (a != e.action)
              ListTile(
                leading: Icon(a.icon),
                title: Text(tr(context, 'rlMoveTo', {'list': tr(context, a.titleKey)})),
                onTap: () {
                  Navigator.pop(sheet);
                  _move(e, a);
                },
              ),
          ListTile(
            leading: Icon(Icons.delete_outline, color: scheme.error),
            title: Text(tr(context, 'rlRemove'), style: TextStyle(color: scheme.error)),
            onTap: () {
              Navigator.pop(sheet);
              _remove(e);
            },
          ),
        ]),
      ),
    );
  }
}

/// A tinted box with a short explanation.
class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.icon, required this.body, this.title, this.color, this.onColor});

  final IconData icon;
  final String body;
  final String? title;
  final Color? color, onColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = onColor ?? scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: color ?? scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(16)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 22, color: fg),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (title != null) Text(title!, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: fg, fontWeight: FontWeight.w700)),
            if (title != null) const SizedBox(height: 2),
            Text(body, style: TextStyle(color: fg, height: 1.4)),
          ]),
        ),
      ]),
    );
  }
}

/// Shown instead of the lists' contents before the first rule: what a rule is for.
class _EmptyIntro extends StatelessWidget {
  const _EmptyIntro();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 28, 8, 4),
      child: Column(children: [
        Icon(Icons.alt_route, size: 56, color: scheme.primary),
        const SizedBox(height: 12),
        Text(tr(context, 'ruleNone'), style: text.titleLarge, textAlign: TextAlign.center),
        const SizedBox(height: 6),
        Text(tr(context, 'rlEmptyBody'),
            textAlign: TextAlign.center, style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant, height: 1.4)),
      ]),
    );
  }
}

/// What an empty list says: an example of what to put in it, and the way to add.
class _EmptySection extends StatelessWidget {
  const _EmptySection({required this.action, required this.onAdd});

  final RuleAction action;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(children: [
        Expanded(child: Text(tr(context, action.exampleKey), style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4))),
        TextButton.icon(onPressed: onAdd, icon: const Icon(Icons.add), label: Text(tr(context, 'ruleAdd'))),
      ]),
    );
  }
}

/// What the search says when nothing matches; when the words are a rule, the three ways to add it.
class _NoMatch extends StatelessWidget {
  const _NoMatch({required this.query, required this.onAdd});

  final String query;
  final void Function(RuleAction action, RouteRule rule) onAdd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rule = parseUserRule(query);
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(children: [
        Icon(Icons.search_off, size: 48, color: scheme.outline),
        const SizedBox(height: 8),
        Text(tr(context, 'rlNoMatch', {'q': query}), textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
        if (rule != null) ...[
          const SizedBox(height: 16),
          Text(tr(context, 'rlAddAs', {'rule': rule.text}), textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
            for (final a in RuleAction.values)
              FilledButton.tonalIcon(
                onPressed: () => onAdd(a, rule),
                icon: Icon(a.icon, size: 18),
                label: Text(tr(context, a.shortKey)),
              ),
          ]),
        ],
      ]),
    );
  }
}
