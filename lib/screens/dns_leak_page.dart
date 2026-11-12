import 'package:flutter/material.dart';

import '../core/ip_info.dart';
import '../l10n/extra.dart';
import '../state/app_state.dart';

/// The DNS leak test: which DNS servers answer the names this device looks up, and whether they are in the
/// same country as the VPN address. The servers are shown as they are found, with the verdict so far.
class DnsLeakPage extends StatefulWidget {
  const DnsLeakPage({super.key, required this.state, this.runTest = runDnsLeakTest});

  final AppState state;

  /// The test itself (a test of the page gives its own).
  final Future<DnsLeakResult> Function(
      {int? proxyPort,
      void Function(DnsLeakResult partial)? onResult,
      void Function(DnsLeakStep step)? onStep}) runTest;

  @override
  State<DnsLeakPage> createState() => _DnsLeakPageState();
}

class _DnsLeakPageState extends State<DnsLeakPage> {
  DnsLeakResult? _result;
  var _running = true;
  var _failed = false;
  var _step = DnsLeakStep.preparing;
  var _runId = 0;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _runId++; // what arrives later is dropped
    super.dispose();
  }

  Future<void> _run() async {
    final id = ++_runId;
    setState(() {
      _running = true;
      _failed = false;
      _result = null;
      _step = DnsLeakStep.preparing;
    });
    DnsLeakResult? result;
    try {
      result = await widget.runTest(
        proxyPort: widget.state.localProxyPort,
        onResult: (r) {
          if (mounted && id == _runId) setState(() => _result = r);
        },
        onStep: (s) {
          if (mounted && id == _runId && s != _step) setState(() => _step = s);
        },
      );
    } catch (_) {}
    if (!mounted || id != _runId) return;
    setState(() {
      _result = result ?? _result;
      _failed = _result == null;
      _running = false;
    });
  }

  (IconData, Color, String, String) _verdictLook(DnsLeakVerdict v, ColorScheme scheme) => switch (v) {
        DnsLeakVerdict.unknown => (Icons.help_outline, scheme.outline, 'dnsLeakUnknown', 'dnsLeakUnknownDesc'),
        DnsLeakVerdict.leak => (Icons.warning_amber_rounded, scheme.error, 'dnsLeakYes', 'dnsLeakYesDesc'),
        DnsLeakVerdict.possible => (Icons.info_outline, Colors.orange.shade700, 'dnsLeakPossible', 'dnsLeakPossibleDesc'),
        DnsLeakVerdict.ok => (Icons.verified_user, Colors.green.shade600, 'dnsLeakNo', 'dnsLeakNoDesc'),
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final r = _result;
    final judged = r == null ? null : judgeDnsLeak(r);
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'menuDnsLeak')),
        actions: [
          IconButton(
            tooltip: tr(context, 'ipRefresh'),
            icon: const Icon(Icons.refresh),
            onPressed: _running ? null : _run,
          ),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: _failed
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.cloud_off, size: 56, color: scheme.error),
                      const SizedBox(height: 12),
                      Text(tr(context, 'ipFailed'), textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                          onPressed: _run, icon: const Icon(Icons.refresh), label: Text(tr(context, 'ipRefresh'))),
                    ]),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  children: [
                    _hero(context, scheme, text, r, judged),
                    const SizedBox(height: 16),
                    if (r?.address != null) ...[
                      Text(tr(context, 'dnsLeakYourAddress'), style: text.titleSmall),
                      const SizedBox(height: 6),
                      _address(r!.address!, scheme),
                      const SizedBox(height: 16),
                    ],
                    Row(children: [
                      Expanded(
                        child: Text(tr(context, 'dnsLeakServers', {'n': r?.resolvers.length ?? 0}),
                            style: text.titleSmall),
                      ),
                      if (_running)
                        const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    ]),
                    const SizedBox(height: 6),
                    if (r != null && r.resolvers.isEmpty && !_running)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(tr(context, 'dnsLeakNone')),
                      ),
                    for (final e in r?.resolvers ?? const <DnsLeakEntry>[])
                      _Appear(
                        key: ValueKey('dns:${e.ip}'),
                        child: _entry(e, judged?.kinds[e] ?? DnsEntryKind.safe, scheme),
                      ),
                    const SizedBox(height: 8),
                    Text(
                      tr(context, 'dnsLeakNote'),
                      textAlign: TextAlign.center,
                      style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                      onPressed: _running ? null : _run,
                      icon: const Icon(Icons.refresh),
                      label: Text(tr(context, 'dnsLeakAgain')),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  /// The verdict, drawn from what is known at the moment: while the test runs it says how many servers were
  /// seen and what the verdict is so far; when it is over it is the verdict.
  Widget _hero(BuildContext context, ColorScheme scheme, TextTheme text, DnsLeakResult? r,
      ({DnsLeakVerdict verdict, Map<DnsLeakEntry, DnsEntryKind> kinds})? judged) {
    final seen = r?.resolvers.length ?? 0;
    final verdict = judged?.verdict ?? DnsLeakVerdict.unknown;
    final (icon, color, title, desc) = _verdictLook(verdict, scheme);
    final waiting = _running && seen == 0;
    final shownColor = waiting ? scheme.primary : color;
    final steps = [
      (DnsLeakStep.preparing, 'dnsStepPrepare'),
      (DnsLeakStep.asking, 'dnsStepAsk'),
      (DnsLeakStep.settling, 'dnsStepSettle'),
    ];
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: shownColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: shownColor.withValues(alpha: 0.5)),
      ),
      child: Column(children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: waiting
              ? SizedBox(
                  key: const ValueKey('wait'),
                  width: 48,
                  height: 48,
                  child: CircularProgressIndicator(strokeWidth: 4, color: shownColor))
              : Icon(icon, key: ValueKey(icon), size: 48, color: shownColor),
        ),
        const SizedBox(height: 10),
        Text(
          _running
              ? (waiting ? tr(context, 'dnsLeakRunning') : tr(context, 'dnsLeakLive', {'n': seen}))
              : tr(context, title),
          textAlign: TextAlign.center,
          style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700, color: shownColor),
        ),
        const SizedBox(height: 6),
        if (_running && !waiting)
          Text(tr(context, 'dnsLeakSoFar', {'verdict': tr(context, title)}),
              textAlign: TextAlign.center, style: TextStyle(color: color, fontWeight: FontWeight.w600))
        else if (!_running)
          Text(tr(context, desc), textAlign: TextAlign.center),
        if (_running) ...[
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
                minHeight: 6, color: shownColor, backgroundColor: shownColor.withValues(alpha: 0.18)),
          ),
          const SizedBox(height: 10),
          // The three parts of the test, the one running highlighted.
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (final (s, key) in steps)
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    tr(context, key),
                    textAlign: TextAlign.center,
                    style: text.labelSmall?.copyWith(
                      fontWeight: s == _step ? FontWeight.w700 : FontWeight.w400,
                      color: s.index <= _step.index ? scheme.onSurface : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
          ]),
        ],
      ]),
    );
  }

  Widget _entry(DnsLeakEntry e, DnsEntryKind kind, ColorScheme scheme) {
    final (icon, color, label) = switch (kind) {
      DnsEntryKind.safe => (Icons.check_circle, Colors.green.shade600, 'dnsKindSafe'),
      DnsEntryKind.publicDns => (Icons.public, Colors.orange.shade700, 'dnsKindPublic'),
      DnsEntryKind.leak => (Icons.warning_amber_rounded, scheme.error, 'dnsKindLeak'),
    };
    final name = publicDnsName(e);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: ListTile(
          leading: CircleAvatar(backgroundColor: color.withValues(alpha: 0.15), child: Icon(icon, color: color)),
          title: SelectableText(e.ip, textDirection: TextDirection.ltr),
          subtitle: Text(
              [e.country, if (name != null) name else e.org, if (e.asn.isNotEmpty) e.asn]
                  .where((s) => s.isNotEmpty)
                  .join(' · '),
              textDirection: TextDirection.ltr),
          trailing: Text(tr(context, label), style: TextStyle(color: color, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }

  Widget _address(DnsLeakEntry e, ColorScheme scheme) => Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: scheme.primaryContainer,
            child: Icon(Icons.public, color: scheme.onPrimaryContainer),
          ),
          title: SelectableText(e.ip, textDirection: TextDirection.ltr),
          subtitle: Text([e.country, e.org].where((s) => s.isNotEmpty).join(' · '), textDirection: TextDirection.ltr),
        ),
      );
}

/// A row that fades and slides in when it first appears (a server just found).
class _Appear extends StatelessWidget {
  const _Appear({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
        builder: (context, t, child) => Opacity(
          opacity: t,
          child: Transform.translate(offset: Offset(0, (1 - t) * 14), child: child),
        ),
        child: child,
      );
}
