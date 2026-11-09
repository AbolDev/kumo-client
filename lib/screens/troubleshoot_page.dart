import 'package:flutter/material.dart';

import '../core/anti_filter_tuner.dart';
import '../core/diagnostics.dart';
import '../core/latency_tester.dart' show tcpLatency;
import '../core/proxy_config.dart';
import '../core/vpn_channel.dart';
import '../l10n/extra.dart';
import '../state/app_state.dart';

enum _Check { pass, fail, warn }

class _Item {
  const _Item(this.title, this.check, this.detail, [this.advice]);

  final String title;
  final _Check check;
  final String detail;

  /// The text key of the advice for the first problem found.
  final String? advice;
}

/// "Why can't I connect?": a few quick checks (internet, DNS, the server, the clock) and a plain
/// answer for the most likely cause.
class TroubleshootPage extends StatefulWidget {
  const TroubleshootPage({super.key, required this.state});

  final AppState state;

  @override
  State<TroubleshootPage> createState() => _TroubleshootPageState();
}

class _TroubleshootPageState extends State<TroubleshootPage> {
  final _items = <_Item>[];
  var _running = false;
  var _done = false;

  AppState get state => widget.state;

  // ---- the tuner: which advanced options work best on this network
  var _tuning = false;
  var _tuneDone = 0, _tuneTotal = 0;
  var _tuneCancel = false;
  List<TuneScore>? _scores;
  ({TuneVerdict verdict, TuneScore? best})? _tuneResult;
  bool _noServers = false;

  /// What the options were before the tuner's choice was applied (to put back), or null.
  ({bool fragment, bool record, String fingerprint, bool mux})? _undo;

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

  Widget _tuneCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final result = _tuneResult;
    final best = result?.best;
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr(context, 'tuneTitle'),
              style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
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
                child: FilledButton(
                    onPressed: () => _applyTune(best!), child: Text(tr(context, 'tuneApply'))),
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

  void _add(_Item item) {
    if (mounted) setState(() => _items.add(item));
  }

  Future<void> _run() async {
    setState(() {
      _items.clear();
      _running = true;
      _done = false;
    });
    String t(String key, [Map<String, Object>? args]) => tr(context, key, args);

    // 1. Internet. With the VPN on, the test goes through it.
    final internet = await internetWorks();
    if (!mounted) return;
    _add(_Item(
      t('tsInternet'),
      internet ? _Check.pass : _Check.fail,
      internet
          ? (state.connected ? t('tsInternetOnVpn') : t('tsInternetOk'))
          : t('tsInternetBad'),
      internet ? null : 'advInternet',
    ));

    // 2. DNS.
    if (internet) {
      final dns = await dnsWorks();
      if (!mounted) return;
      _add(_Item(t('tsDns'), dns ? _Check.pass : _Check.fail,
          dns ? t('tsDnsOk') : t('tsDnsBad'), dns ? null : 'advDns'));
    }

    // 3 and 4. Servers.
    final all = state.all.toList();
    if (all.isEmpty) {
      _add(_Item(t('tsServers'), _Check.fail, t('tsServersNone'), 'advNoServers'));
    } else {
      final ProxyConfig target = state.selected ??
          state.autoPick ??
          all.firstWhere((c) => !c.needsXray, orElse: () => all.first);
      _add(_Item(t('tsServers'), _Check.pass,
          t('tsServersOk', {'n': all.length, 'name': target.name})));
      if (target.protocol == 'hysteria2' || target.protocol == 'tuic') {
        _add(_Item(t('tsServer'), _Check.warn, t('tsServerUdp', {'name': target.name})));
      } else if (state.connected) {
        _add(_Item(t('tsServer'), _Check.pass, t('tsServerOk', {'name': target.name, 'ms': state.liveDelay ?? 0})));
      } else {
        final ms = await tcpLatency(target, timeout: const Duration(seconds: 5));
        if (!mounted) return;
        _add(_Item(
          t('tsServer'),
          ms >= 0 ? _Check.pass : _Check.fail,
          ms >= 0
              ? t('tsServerOk', {'name': target.name, 'ms': ms})
              : t('tsServerBad', {'name': target.name}),
          ms >= 0 ? null : 'advServer',
        ));
      }
    }

    // 5. Clock.
    if (internet) {
      final skew = await clockSkew();
      if (!mounted) return;
      if (skew == null) {
        _add(_Item(t('tsClock'), _Check.warn, t('tsClockUnknown')));
      } else if (skew.inMinutes.abs() >= 3) {
        _add(_Item(t('tsClock'), _Check.fail,
            t('tsClockBad', {'min': skew.inMinutes.abs()}), 'advClock'));
      } else {
        _add(_Item(t('tsClock'), _Check.pass, t('tsClockOk')));
      }
    }

    // 6. Battery limits (Android).
    final unrestricted = await VpnChannel.batteryUnrestricted();
    if (!mounted) return;
    if (!unrestricted) {
      _add(_Item(t('tsBattery'), _Check.warn, t('tsBatteryBad')));
    }

    // 7. What went wrong last time.
    final last = state.lastDisconnect;
    _add(_Item(
      t('tsLastError'),
      _Check.pass,
      last != null && last.key == 'reasonError' ? t(last.key, last.args) : t('tsNoError'),
    ));

    if (mounted) {
      setState(() {
        _running = false;
        _done = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final problem = _items.where((i) => i.advice != null).firstOrNull;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'tsTitle'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _tuneCard(context),
          Text(tr(context, 'tsIntro')),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _running ? null : _run,
            icon: _running
                ? const SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.health_and_safety_outlined),
            label: Text(tr(context, _running ? 'tsRunning' : 'tsRun')),
          ),
          const SizedBox(height: 8),
          for (final item in _items)
            ListTile(
              leading: Icon(
                switch (item.check) {
                  _Check.pass => Icons.check_circle,
                  _Check.fail => Icons.cancel,
                  _Check.warn => Icons.warning_amber,
                },
                color: switch (item.check) {
                  _Check.pass => Colors.green,
                  _Check.fail => scheme.error,
                  _Check.warn => Colors.orange,
                },
              ),
              title: Text(item.title),
              subtitle: Text(item.detail),
            ),
          if (_done)
            Card(
              color: problem == null ? scheme.secondaryContainer : scheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  tr(context, problem?.advice ?? 'advAllOk'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
