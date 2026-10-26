import 'package:flutter/material.dart';

import '../core/routing_rules.dart';
import '../l10n/extra.dart';
import '../state/app_state.dart';

/// The user's own routing rules: domains and addresses that always go direct, or always through
/// the VPN, whatever the country and app settings say.
class RoutingRulesPage extends StatefulWidget {
  const RoutingRulesPage({super.key, required this.state});

  final AppState state;

  @override
  State<RoutingRulesPage> createState() => _RoutingRulesPageState();
}

class _RoutingRulesPageState extends State<RoutingRulesPage> {
  AppState get state => widget.state;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr(context, 'ruleTitle')),
          bottom: TabBar(tabs: [
            Tab(text: tr(context, 'ruleDirect')),
            Tab(text: tr(context, 'ruleProxy')),
          ]),
        ),
        body: ListenableBuilder(
          listenable: state,
          builder: (context, _) => Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(tr(context, 'ruleDesc'),
                  style: Theme.of(context).textTheme.bodySmall),
            ),
            Expanded(
              child: TabBarView(children: [
                _RuleList(
                  rules: state.net.directRules,
                  onChange: (list) =>
                      state.updateNet((o) => o.directRules = list),
                ),
                _RuleList(
                  rules: state.net.proxyRules,
                  onChange: (list) =>
                      state.updateNet((o) => o.proxyRules = list),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _RuleList extends StatefulWidget {
  const _RuleList({required this.rules, required this.onChange});

  final List<String> rules;
  final void Function(List<String> rules) onChange;

  @override
  State<_RuleList> createState() => _RuleListState();
}

class _RuleListState extends State<_RuleList> {
  final _input = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _add() {
    final value = normalizeRouteRule(_input.text);
    if (value == null) {
      setState(() => _error = tr(context, 'ruleInvalid'));
      return;
    }
    setState(() => _error = null);
    _input.clear();
    if (!widget.rules.contains(value)) widget.onChange([...widget.rules, value]);
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: _input,
          textDirection: TextDirection.ltr,
          keyboardType: TextInputType.url,
          autocorrect: false,
          onSubmitted: (_) => _add(),
          decoration: InputDecoration(
            hintText: tr(context, 'ruleHint'),
            errorText: _error,
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(icon: const Icon(Icons.add), onPressed: _add),
          ),
        ),
        const SizedBox(height: 8),
        Text(tr(context, 'ruleNote'), style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        if (widget.rules.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(child: Text(tr(context, 'ruleNone'))),
          ),
        for (final rule in widget.rules)
          ListTile(
            dense: true,
            leading: Icon(
                parseRouteRule(rule)?.ip == true ? Icons.numbers : Icons.language),
            title: Text(rule, textDirection: TextDirection.ltr),
            trailing: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () =>
                  widget.onChange([...widget.rules.where((r) => r != rule)]),
            ),
          ),
      ],
    );
  }
}
