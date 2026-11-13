import 'package:flutter/material.dart';

import '../core/anti_filter_tuner.dart';
import '../l10n/extra.dart';
import '../state/app_state.dart';

/// "Find the best settings for my network": tries a few of the advanced options (splitting the TLS hello,
/// a browser fingerprint, multiplexing) on some of the user's servers, shows which work best here and applies
/// one only when the user taps the button (it can be undone).
class TunePage extends StatefulWidget {
  const TunePage({super.key, required this.state});

  final AppState state;

  @override
  State<TunePage> createState() => _TunePageState();
}

class _TunePageState extends State<TunePage> {
  var _tuning = false;
  var _tuneDone = 0, _tuneTotal = 0;
  var _tuneCancel = false;
  List<TuneScore>? _scores;
  ({TuneVerdict verdict, TuneScore? best})? _tuneResult;
  bool _noServers = false;

  /// What the options were before the tuner's choice was applied (to put back), or null.
  ({bool fragment, bool record, String fingerprint, bool mux})? _undo;

  AppState get state => widget.state;

  static const _variantNames = {
    'fragment': 'TLS fragment',
    'fragment+record': 'TLS fragment + record split',
    'chrome': 'Chrome fingerprint',
    'firefox': 'Firefox fingerprint',
    'ios': 'iOS fingerprint',
    'random': 'Random fingerprint',
    'fragment+chrome': 'TLS fragment + Chrome fingerprint',
    'mux': 'Mux',
  };

  String _variantName(TuneVariant v) => v.id == 'current' ? tr(context, 'tuneCurrent') : _variantNames[v.id] ?? v.id;

  Future<void> _tune() async {
    final servers = tuneServers(state.all, state.selected);
    if (servers.isEmpty) {
      setState(() {
        _noServers = true;
        _scores = null;
        _tuneResult = null;
      });
      return;
    }
    setState(() {
      _noServers = false;
      _tuning = true;
      _tuneCancel = false;
      _tuneDone = 0;
      _tuneTotal = servers.length * tuneVariants.length;
      _scores = null;
      _tuneResult = null;
    });
    final scores = await runTuner(
      servers: servers,
      base: state.net,
      onProgress: (d, t) {
        if (mounted) setState(() => _tuneDone = d);
      },
      cancelled: () => _tuneCancel || !mounted,
    );
    if (!mounted) return;
    setState(() {
      _tuning = false;
      if (_tuneCancel) return;
      _scores = scores;
      _tuneResult = recommend(scores);
    });
  }

  Future<void> _applyTune(TuneScore best) async {
    final o = state.net;
    _undo = (fragment: o.tlsFragment, record: o.tlsRecordFragment, fingerprint: o.fingerprint, mux: o.mux);
    await state.updateNet((o) => best.variant.apply(o));
    if (mounted) setState(() {});
  }

  Future<void> _undoTune() async {
    final u = _undo;
    if (u == null) return;
    _undo = null;
    await state.updateNet((o) {
      o.tlsFragment = u.fragment;
      o.tlsRecordFragment = u.record;
      o.fingerprint = u.fingerprint;
      o.mux = u.mux;
    });
    if (mounted) setState(() {});
  }

  Widget _card(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final result = _tuneResult;
    final best = result?.best;
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr(context, 'tuneDesc')),
          const SizedBox(height: 12),
          if (state.connected)
            Text(tr(context, 'tuneDisconnect'), style: TextStyle(color: scheme.error))
          else
            Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              FilledButton.tonalIcon(
                onPressed: _tuning ? null : _tune,
                icon: _tuning
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.tune),
                label: Text(_tuning
                    ? tr(context, 'tuneRunning', {'done': _tuneDone, 'total': _tuneTotal})
                    : tr(context, 'tuneRun')),
              ),
              if (_tuning)
                TextButton(
                    onPressed: () => setState(() => _tuneCancel = true),
                    child: Text(MaterialLocalizations.of(context).cancelButtonLabel)),
            ]),
          if (_noServers) ...[
            const SizedBox(height: 8),
            Text(tr(context, 'tuneNoServers')),
          ],
          if (result != null) ...[
            const SizedBox(height: 12),
            for (final s in _scores!)
              Text(
                s.ok == 0
                    ? '${_variantName(s.variant)}: ${tr(context, 'tuneNone', {'total': s.total})}'
                    : '${_variantName(s.variant)}: ${tr(context, 'tuneOk', {'ok': s.ok, 'total': s.total, 'ms': s.medianMs ?? 0})}',
                style: TextStyle(
                    fontWeight: identical(s, best) ? FontWeight.w700 : FontWeight.w400,
                    color: s.ok == 0 ? scheme.onSurfaceVariant : null),
              ),
            const SizedBox(height: 12),
            Text(
              switch (result.verdict) {
                TuneVerdict.nothingWorks => tr(context, 'tuneNothing'),
                TuneVerdict.currentIsBest => tr(context, 'tuneCurrentBest'),
                TuneVerdict.better => tr(context, 'tuneBetter', {'name': _variantName(best!.variant)}),
              },
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            if (result.verdict == TuneVerdict.better && _undo == null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: FilledButton(onPressed: () => _applyTune(best!), child: Text(tr(context, 'tuneApply'))),
              ),
            if (_undo != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(children: [
                  Expanded(child: Text(tr(context, 'tuneApplied'))),
                  TextButton(onPressed: _undoTune, child: Text(tr(context, 'tuneUndo'))),
                ]),
              ),
          ],
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(tr(context, 'tuneTitle'))),
        // Redrawn when the connection changes: the test needs the VPN off.
        body: ListenableBuilder(
          listenable: state,
          builder: (context, _) => ListView(padding: const EdgeInsets.all(16), children: [_card(context)]),
        ),
      );
}
