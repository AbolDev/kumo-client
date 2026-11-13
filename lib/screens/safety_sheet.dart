import 'package:flutter/material.dart';

import '../core/config_inspector.dart';
import '../core/proxy_config.dart';
import '../l10n/extra.dart';
import '../state/app_state.dart';

/// The mark of a safety result in a list: null where there is nothing to warn of.
IconData? safetyIcon(InspectVerdict? v) => switch (v) {
      InspectVerdict.danger => Icons.gpp_bad,
      InspectVerdict.suspicious => Icons.gpp_maybe,
      _ => null,
    };

Color safetyColor(InspectVerdict? v, ColorScheme scheme) => switch (v) {
      InspectVerdict.danger => scheme.error,
      InspectVerdict.suspicious => const Color(0xFFE08A00),
      InspectVerdict.clean => const Color(0xFF2E9E5B),
      _ => scheme.outline,
    };

/// Checks [config] and shows what was found, in plain words, with what the check cannot find.
Future<void> showSafetySheet(BuildContext context, AppState state, ProxyConfig config) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SafetySheet(state: state, config: config),
    );

class SafetySheet extends StatefulWidget {
  const SafetySheet({super.key, required this.state, required this.config, this.autoRun = true, this.check});

  final AppState state;
  final ProxyConfig config;

  /// What runs the check (the state's own, unless a test gives another).
  final Future<InspectReport?> Function(ProxyConfig config)? check;

  /// Starts the check when the sheet opens (the tests of the sheet itself leave it off).
  final bool autoRun;

  @override
  State<SafetySheet> createState() => _SafetySheetState();
}

class _SafetySheetState extends State<SafetySheet> {
  InspectReport? _report;
  var _running = false;

  /// The check could not start now (a connection is up).
  var _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoRun) WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    if (_running) return;
    setState(() {
      _running = true;
      _busy = false;
      _report = null;
    });
    final report = await (widget.check ?? widget.state.checkSafety)(widget.config);
    if (!mounted) return;
    setState(() {
      _running = false;
      _report = report;
      _busy = report == null;
    });
  }

  String _finding(Finding f) {
    final Map<String, Object> host = {'host': f.host};
    return switch (f.kind) {
      FindingKind.badCertificate => tr(context, 'sfBadCert', host),
      FindingKind.badCertificateUnconfirmed => tr(context, 'sfBadCertMaybe', host),
      FindingKind.pageChanged => tr(context, 'sfPageChanged', host),
      FindingKind.pageChangedUnconfirmed => tr(context, 'sfPageChangedMaybe', host),
      FindingKind.sameAddress => tr(context, 'sfSameAddress'),
      FindingKind.blocked => tr(context, 'sfBlocked', host),
      FindingKind.noAnswer => tr(context, 'safetyUnknownBody'),
      FindingKind.unsupported => tr(context, 'safetyUnsupported'),
      FindingKind.busy => tr(context, 'safetyBusy'),
    };
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final report = _report;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr(context, 'safetyCheck'), style: text.titleLarge),
            const SizedBox(height: 2),
            Text(widget.config.name,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodyMedium?.copyWith(color: scheme.outline)),
            const SizedBox(height: 16),
            if (_running)
              Row(children: [
                const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
                const SizedBox(width: 14),
                Expanded(
                    child: Text(tr(context, 'safetyChecking', {'name': widget.config.name}),
                        key: const ValueKey('safety-running'))),
              ]),
            if (_running) ...[
              const SizedBox(height: 8),
              Text(tr(context, 'safetyCheckingHint'), style: text.bodySmall?.copyWith(color: scheme.outline)),
            ],
            if (_busy) Text(tr(context, 'safetyBusy'), key: const ValueKey('safety-busy')),
            if (report != null) _result(context, report),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
              child: Text(tr(context, 'safetyLimits'), style: text.bodySmall, key: const ValueKey('safety-limits')),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (!_running)
                  TextButton.icon(
                    key: const ValueKey('safety-again'),
                    onPressed: _run,
                    icon: const Icon(Icons.refresh),
                    label: Text(tr(context, 'safetyAgain')),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _result(BuildContext context, InspectReport r) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final color = safetyColor(r.verdict, scheme);
    final (icon, title, body) = switch (r.verdict) {
      InspectVerdict.clean => (
          Icons.verified_user,
          tr(context, 'safetyClean'),
          tr(context, 'safetyCleanBody', {'n': r.passed, 'total': inspectTargets.length})
        ),
      InspectVerdict.suspicious => (Icons.gpp_maybe, tr(context, 'safetySuspicious'), tr(context, 'safetySuspiciousBody')),
      InspectVerdict.danger => (Icons.gpp_bad, tr(context, 'safetyDanger'), tr(context, 'safetyDangerBody')),
      InspectVerdict.unknown => (Icons.help_outline, tr(context, 'safetyUnknown'), ''),
    };
    final shown = r.findings.where((f) => f.kind != FindingKind.noAnswer || r.verdict == InspectVerdict.unknown).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          key: ValueKey('safety-${r.verdict.name}'),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withValues(alpha: 0.5)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: color, size: 32),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: text.titleMedium?.copyWith(color: color, fontWeight: FontWeight.w700)),
                    if (body.isNotEmpty) ...[const SizedBox(height: 4), Text(body)],
                  ],
                ),
              ),
            ],
          ),
        ),
        if (r.exitIp != null) ...[
          const SizedBox(height: 10),
          Text(tr(context, 'safetyExit', {'ip': r.exitIp!, 'country': r.exitCountry ?? '?'}),
              textDirection: TextDirection.ltr, style: text.bodySmall?.copyWith(color: scheme.outline)),
        ],
        for (final f in shown)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  f.severity == InspectVerdict.clean ? Icons.info_outline : Icons.warning_amber_rounded,
                  size: 18,
                  color: safetyColor(f.severity == InspectVerdict.clean ? null : f.severity, scheme),
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(_finding(f), style: text.bodyMedium)),
              ],
            ),
          ),
      ],
    );
  }
}

/// Asks before a server that was found dangerous is picked: true when the user wants it all the same.
Future<bool> confirmDangerous(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(tr(d, 'safetyConnectTitle')),
      content: Text(tr(d, 'safetyConnectBody')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: Text(MaterialLocalizations.of(d).cancelButtonLabel)),
        TextButton(
          key: const ValueKey('safety-anyway'),
          style: TextButton.styleFrom(foregroundColor: Theme.of(d).colorScheme.error),
          onPressed: () => Navigator.pop(d, true),
          child: Text(tr(d, 'safetyConnectAnyway')),
        ),
      ],
    ),
  );
  return ok == true;
}
