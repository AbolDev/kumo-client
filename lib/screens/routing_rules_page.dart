import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../core/platform.dart';
import '../core/routing_rules.dart';
import '../core/rule_services.dart';
import '../core/vpn_channel.dart';
import '../l10n/extra.dart';
import '../state/app_state.dart';
import '../widgets/app_icon.dart';
import '../widgets/prompt_dialog.dart';

/// The user's own routing rules: apps, popular services, websites, addresses and ports that always go direct,
/// always through the VPN, or are always blocked, whatever the country and app settings say. A rule is added by
/// choosing what it is about from a list, so nothing has to be typed unless the user wants to.
class RoutingRulesPage extends StatefulWidget {
  const RoutingRulesPage({super.key, required this.state});

  final AppState state;

  @override
  State<RoutingRulesPage> createState() => _RoutingRulesPageState();
}

class _RoutingRulesPageState extends State<RoutingRulesPage> {
  AppState get state => widget.state;

  /// The apps of this device by id, for the names of the app rules (loaded once).
  Map<String, String> _appNames = const {};

  @override
  void initState() {
    super.initState();
    VpnChannel.listApps().then((l) {
      if (mounted) setState(() => _appNames = {for (final a in l) a.id: a.label});
    }).catchError((_) {});
  }

  List<String> _rules(int tab) => switch (tab) {
        0 => state.net.directRules,
        1 => state.net.proxyRules,
        _ => state.net.blockRules,
      };

  void _setRules(int tab, List<String> list) => state.updateNet((o) {
        switch (tab) {
          case 0:
            o.directRules = list;
          case 1:
            o.proxyRules = list;
          default:
            o.blockRules = list;
        }
      });

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Builder(
        builder: (context) {
          final controller = DefaultTabController.of(context);
          return Scaffold(
            appBar: AppBar(
              title: Text(tr(context, 'ruleTitle')),
              bottom: TabBar(tabs: [
                Tab(text: tr(context, 'ruleDirect')),
                Tab(text: tr(context, 'ruleProxy')),
                Tab(text: tr(context, 'ruleBlock')),
              ]),
            ),
            floatingActionButton: FloatingActionButton.extended(
              onPressed: () => _add(context, controller.index),
              icon: const Icon(Icons.add),
              label: Text(tr(context, 'ruleAdd')),
            ),
            body: ListenableBuilder(
              listenable: state,
              builder: (context, _) => TabBarView(children: [
                for (var tab = 0; tab < 3; tab++)
                  _RuleList(
                    rules: _rules(tab),
                    appNames: _appNames,
                    onChange: (list) => _setRules(tab, list),
                    onAdd: () => _add(context, tab),
                  ),
              ]),
            ),
          );
        },
      ),
    );
  }

  /// Asks what kind of rule to add, then lets the user pick it from a list (or type it).
  Future<void> _add(BuildContext context, int tab) async {
    final kind = await showModalBottomSheet<_Kind>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (sheet) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(tr(sheet, 'ruleAddWhat'), style: Theme.of(sheet).textTheme.titleLarge),
              ),
            ),
            for (final k in _Kind.values)
              if (k != _Kind.app || canPickApps)
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Theme.of(sheet).colorScheme.primaryContainer,
                    child: Icon(k.icon, color: Theme.of(sheet).colorScheme.onPrimaryContainer),
                  ),
                  title: Text(tr(sheet, k.title), style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(tr(sheet, '${k.title}Desc')),
                  onTap: () => Navigator.pop(sheet, k),
                ),
          ]),
        ),
      ),
    );
    if (kind == null || !context.mounted) return;
    final current = _rules(tab);
    final added = <String>[];
    switch (kind) {
      case _Kind.app:
        final ids = await Navigator.push<List<String>>(
          context,
          MaterialPageRoute(
            settings: const RouteSettings(name: '/RuleAppsPage'),
            builder: (_) => _AppPickerPage(
              taken: {for (final r in current) if (parseRouteRule(r)?.kind == RuleKind.app) parseRouteRule(r)!.value},
            ),
          ),
        );
        added.addAll([for (final id in ids ?? const <String>[]) 'app:$id']);
      case _Kind.service:
        final ids = await Navigator.push<List<String>>(
          context,
          MaterialPageRoute(
            settings: const RouteSettings(name: '/RuleServicesPage'),
            builder: (_) => _ServicePickerPage(
              taken: {for (final r in current) if (parseRouteRule(r)?.kind == RuleKind.service) parseRouteRule(r)!.value},
            ),
          ),
        );
        added.addAll([for (final id in ids ?? const <String>[]) 'service:$id']);
      case _Kind.site:
      case _Kind.ip:
      case _Kind.port:
      case _Kind.advanced:
        final text = await _askText(context, kind);
        if (text != null) added.add(text);
    }
    if (added.isEmpty) return;
    final merged = [...current, for (final a in added) if (!current.contains(a)) a];
    _setRules(tab, merged);
  }

  /// One line for a website, an address, a port or an advanced rule; the rule it makes, or null.
  Future<String?> _askText(BuildContext context, _Kind kind) async {
    String prefix = '';
    var accepted = const <RuleKind>{};
    switch (kind) {
      case _Kind.site:
        accepted = {RuleKind.domain, RuleKind.full};
      case _Kind.ip:
        accepted = {RuleKind.ip};
      case _Kind.port:
        prefix = 'port:';
        accepted = {RuleKind.port};
      default:
        accepted = {...RuleKind.values}..removeAll([RuleKind.app, RuleKind.service]);
    }
    String? result;
    await showPrompt(
      context,
      icon: kind.icon,
      title: tr(context, kind.title),
      label: tr(context, switch (kind) {
        _Kind.site => 'ruleSiteLabel',
        _Kind.ip => 'ruleIpLabel',
        _Kind.port => 'rulePortLabel',
        _ => 'ruleAdvLabel',
      }),
      hint: tr(context, switch (kind) {
        _Kind.site => 'ruleSiteHint',
        _Kind.ip => 'ruleIpHint',
        _Kind.port => 'rulePortHint',
        _ => 'ruleAdvHint',
      }),
      keyboard: kind == _Kind.port ? TextInputType.number : TextInputType.url,
      confirm: tr(context, 'ruleAdd'),
      check: (v) async {
        final rule = parseRouteRule('$prefix${v.trim()}');
        if (rule == null || !accepted.contains(rule.kind)) return tr(context, 'ruleInvalid');
        result = rule.text;
        return null;
      },
    );
    return result;
  }
}

/// What a rule can be about, as the choices of the first sheet.
enum _Kind {
  app(Icons.apps, 'ruleKindApp'),
  service(Icons.public, 'ruleKindService'),
  site(Icons.language, 'ruleKindSite'),
  ip(Icons.numbers, 'ruleKindIp'),
  port(Icons.settings_ethernet, 'ruleKindPort'),
  advanced(Icons.manage_search, 'ruleKindAdv');

  const _Kind(this.icon, this.title);

  final IconData icon;

  /// The key of the title; the key of the line under it is the same with "Desc".
  final String title;
}

/// Whether this device can list its apps for a rule: a phone does, a computer lists the programs that run.
bool get canPickApps => isDesktop || Platform.isAndroid;

class _RuleList extends StatelessWidget {
  const _RuleList({required this.rules, required this.appNames, required this.onChange, required this.onAdd});

  final List<String> rules;
  final Map<String, String> appNames;
  final void Function(List<String> rules) onChange;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final parsed = [
      for (final r in rules)
        if (parseRouteRule(r) != null) (text: r, rule: parseRouteRule(r)!),
    ];
    final apps = parsed.where((p) => p.rule.kind == RuleKind.app).toList();
    final services = parsed.where((p) => p.rule.kind == RuleKind.service).toList();
    final others = parsed.where((p) => p.rule.kind != RuleKind.app && p.rule.kind != RuleKind.service).toList();

    void remove(String rule) => onChange([...rules.where((r) => r != rule)]);

    Widget section(String key, List<({String text, RouteRule rule})> items, Widget Function(({String text, RouteRule rule})) row) {
      if (items.isEmpty) return const SizedBox.shrink();
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(4, 16, 4, 6),
          child: Text(tr(context, key), style: text.titleSmall?.copyWith(color: scheme.onSurfaceVariant)),
        ),
        Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: scheme.outlineVariant),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(children: [
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) Divider(height: 1, color: scheme.outlineVariant),
              row(items[i]),
            ],
          ]),
        ),
      ]);
    }

    Widget tile(
            {required Widget leading, required String title, String? subtitle, required String rule, bool ltr = true}) =>
        ListTile(
          leading: leading,
          title: Text(title, textDirection: ltr ? TextDirection.ltr : null),
          subtitle: subtitle == null ? null : Text(subtitle),
          trailing: IconButton(
            tooltip: MaterialLocalizations.of(context).deleteButtonTooltip,
            icon: const Icon(Icons.close),
            onPressed: () => remove(rule),
          ),
        );

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      children: [
        Text(tr(context, 'ruleDesc'), style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
        if (parsed.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Column(children: [
              Icon(Icons.alt_route, size: 56, color: scheme.outline),
              const SizedBox(height: 12),
              Text(tr(context, 'ruleNone'), style: text.titleMedium),
              const SizedBox(height: 4),
              Text(tr(context, 'ruleNoneHint'), textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
              const SizedBox(height: 16),
              FilledButton.tonalIcon(onPressed: onAdd, icon: const Icon(Icons.add), label: Text(tr(context, 'ruleAdd'))),
            ]),
          ),
        section(
            'ruleSectionApps',
            apps,
            (p) => tile(
                  leading: AppIcon(id: p.rule.value, size: 36),
                  title: appNames[p.rule.value] ?? p.rule.value,
                  subtitle: appNames[p.rule.value] == null ? null : p.rule.value,
                  rule: p.text,
                  ltr: appNames[p.rule.value] == null,
                )),
        section('ruleSectionServices', services, (p) {
          final service = ruleServices[p.rule.value];
          return tile(
            leading: CircleAvatar(
              backgroundColor: scheme.primaryContainer,
              child: Text((service?.name ?? '?').characters.first,
                  style: TextStyle(color: scheme.onPrimaryContainer, fontWeight: FontWeight.w700)),
            ),
            title: service?.name ?? p.rule.value,
            subtitle: tr(context, 'ruleServiceSites', {'n': service?.domains.length ?? 0}),
            rule: p.text,
          );
        }),
        section(
            'ruleSectionOther',
            others,
            (p) => tile(
                  leading: Icon(switch (p.rule.kind) {
                    RuleKind.ip => Icons.numbers,
                    RuleKind.port => Icons.settings_ethernet,
                    RuleKind.keyword || RuleKind.regex => Icons.manage_search,
                    _ => Icons.language,
                  }),
                  title: p.text,
                  subtitle: tr(context, 'ruleType_${p.rule.kind.name}'),
                  rule: p.text,
                )),
        if (apps.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(tr(context, 'ruleAppNote'), style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ],
      ],
    );
  }
}

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

class _AppPickerPage extends StatefulWidget {
  const _AppPickerPage({required this.taken});

  final Set<String> taken;

  @override
  State<_AppPickerPage> createState() => _AppPickerPageState();
}

class _AppPickerPageState extends _PickerState<_AppPickerPage> {
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
                          : (a.label == a.id ? null : Text(a.id)),
                    ),
                ]),
    );
  }
}

class _ServicePickerPage extends StatefulWidget {
  const _ServicePickerPage({required this.taken});

  final Set<String> taken;

  @override
  State<_ServicePickerPage> createState() => _ServicePickerPageState();
}

class _ServicePickerPageState extends _PickerState<_ServicePickerPage> {
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
                    secondary: CircleAvatar(
                      backgroundColor: scheme.primaryContainer,
                      child: Text(s.name.characters.first,
                          style: TextStyle(color: scheme.onPrimaryContainer, fontWeight: FontWeight.w700)),
                    ),
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
