import 'package:flutter/material.dart';

import '../core/diagnostics.dart';
import '../core/latency_tester.dart' show tcpLatency;
import '../core/proxy_config.dart';
import '../core/vpn_channel.dart';
import '../l10n/extra.dart';
import '../state/app_state.dart';

enum _Check { pass, fail, warn, skipped }

class _Item {
  const _Item(this.check, this.detail, [this.advice]);

  final _Check check;
  final String detail;

  /// The text key of the advice for the first problem found.
  final String? advice;
}

/// The checks, in the order they run: the key of the text that names each.
const _steps = ['tsInternet', 'tsDns', 'tsServers', 'tsServer', 'tsClock', 'tsLastError'];

/// "Why can't I connect?": a few quick checks (internet, DNS, the server, the clock) and a plain
/// answer for the most likely cause. They run when the page opens, each shown as it finishes, and the answer
/// is on top.
class TroubleshootPage extends StatefulWidget {
  const TroubleshootPage({super.key, required this.state, this.autoRun = true});

  final AppState state;

  /// Whether the checks start when the page opens (the tests of the page turn it off).
  final bool autoRun;

  @override
  State<TroubleshootPage> createState() => _TroubleshootPageState();
}

class _TroubleshootPageState extends State<TroubleshootPage> {
  /// The result of each check that is over; a check with none yet is waiting or running.
  final _results = <String, _Item>{};

  /// The checks of this run: the usual ones, and the battery one when it has something to say.
  var _order = List<String>.of(_steps);
  String? _current;
  var _running = false;
  var _done = false;
  var _runId = 0;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    if (widget.autoRun) WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  @override
  void dispose() {
    _runId++; // what arrives later is dropped
    super.dispose();
  }

  Future<void> _run() async {
    final id = ++_runId;
    bool live() => mounted && id == _runId;
    String t(String key, [Map<String, Object>? args]) => tr(context, key, args);
    void set(String key, _Item item) {
      if (live()) {
        setState(() {
          _results[key] = item;
          _current = null;
        });
      }
    }

    void start(String key) {
      if (live()) setState(() => _current = key);
    }

    setState(() {
      _results.clear();
      _order = List<String>.of(_steps);
      _current = null;
      _running = true;
      _done = false;
    });

    // 1. Internet. With the VPN on, the test goes through it.
    start('tsInternet');
    final internet = await internetWorks();
    if (!live()) return;
    set(
        'tsInternet',
        _Item(
          internet ? _Check.pass : _Check.fail,
          internet ? (state.connected ? t('tsInternetOnVpn') : t('tsInternetOk')) : t('tsInternetBad'),
          internet ? null : 'advInternet',
        ));

    // 2. DNS.
    if (internet) {
      start('tsDns');
      final dns = await dnsWorks();
      if (!live()) return;
      set('tsDns', _Item(dns ? _Check.pass : _Check.fail, dns ? t('tsDnsOk') : t('tsDnsBad'), dns ? null : 'advDns'));
    } else {
      set('tsDns', _Item(_Check.skipped, t('tsSkipped')));
    }

    // 3 and 4. Servers.
    final all = state.all.toList();
    if (all.isEmpty) {
      set('tsServers', _Item(_Check.fail, t('tsServersNone'), 'advNoServers'));
      set('tsServer', _Item(_Check.skipped, t('tsSkipped')));
    } else {
      final ProxyConfig target =
          state.selected ?? state.autoPick ?? all.firstWhere((c) => !c.needsXray, orElse: () => all.first);
      set('tsServers', _Item(_Check.pass, t('tsServersOk', {'n': all.length, 'name': target.name})));
      if (target.protocol == 'hysteria2' || target.protocol == 'tuic') {
        set('tsServer', _Item(_Check.warn, t('tsServerUdp', {'name': target.name})));
      } else if (state.connected) {
        set('tsServer', _Item(_Check.pass, t('tsServerOk', {'name': target.name, 'ms': state.liveDelay ?? 0})));
      } else {
        start('tsServer');
        final ms = await tcpLatency(target, timeout: const Duration(seconds: 5));
        if (!live()) return;
        set(
            'tsServer',
            _Item(
              ms >= 0 ? _Check.pass : _Check.fail,
              ms >= 0 ? t('tsServerOk', {'name': target.name, 'ms': ms}) : t('tsServerBad', {'name': target.name}),
              ms >= 0 ? null : 'advServer',
            ));
      }
    }

    // 5. Clock.
    if (internet) {
      start('tsClock');
      final skew = await clockSkew();
      if (!live()) return;
      if (skew == null) {
        set('tsClock', _Item(_Check.warn, t('tsClockUnknown')));
      } else if (skew.inMinutes.abs() >= 3) {
        set('tsClock', _Item(_Check.fail, t('tsClockBad', {'min': skew.inMinutes.abs()}), 'advClock'));
      } else {
        set('tsClock', _Item(_Check.pass, t('tsClockOk')));
      }
    } else {
      set('tsClock', _Item(_Check.skipped, t('tsSkipped')));
    }

    // 6. Battery limits (Android): shown only when it has something to say.
    final unrestricted = await VpnChannel.batteryUnrestricted();
    if (!live()) return;
    if (!unrestricted) {
      setState(() => _order = [..._steps.take(5), 'tsBattery', 'tsLastError']);
      set('tsBattery', _Item(_Check.warn, t('tsBatteryBad')));
    }

    // 7. What went wrong last time.
    final last = state.lastDisconnect;
    set(
        'tsLastError',
        _Item(
          _Check.pass,
          last != null && last.key == 'reasonError' ? t(last.key, last.args) : t('tsNoError'),
        ));

    if (live()) {
      setState(() {
        _running = false;
        _done = true;
      });
    }
  }

  (IconData, Color) _look(_Check c, ColorScheme scheme) => switch (c) {
        _Check.pass => (Icons.check_rounded, Colors.green.shade600),
        _Check.fail => (Icons.close_rounded, scheme.error),
        _Check.warn => (Icons.priority_high_rounded, Colors.orange.shade700),
        _Check.skipped => (Icons.remove_rounded, scheme.outline),
      };

  /// The answer on top: working on it, what is wrong, or that nothing is.
  Widget _hero(BuildContext context, ColorScheme scheme, TextTheme text) {
    final problem = _order.map((k) => _results[k]).where((i) => i?.advice != null).firstOrNull;
    if (!_done) {
      final finished = _results.length;
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: scheme.primaryContainer.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(children: [
          if (_running)
            SizedBox(width: 44, height: 44, child: CircularProgressIndicator(strokeWidth: 4, color: scheme.primary))
          else
            Icon(Icons.health_and_safety_outlined, size: 48, color: scheme.primary),
          const SizedBox(height: 12),
          Text(
            _running ? tr(context, 'tsChecking', {'done': finished, 'total': _order.length}) : tr(context, 'tsIntro'),
            textAlign: TextAlign.center,
            style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          if (_running) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                  minHeight: 6, value: finished / _order.length, backgroundColor: scheme.surfaceContainerHighest),
            ),
          ],
        ]),
      );
    }
    final bad = problem != null;
    final color = bad ? scheme.error : Colors.green.shade600;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Column(children: [
        Icon(bad ? Icons.report_problem_outlined : Icons.verified_user_outlined, size: 48, color: color),
        const SizedBox(height: 10),
        Text(tr(context, bad ? 'tsHeadlineBad' : 'tsHeadlineOk'),
            textAlign: TextAlign.center, style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700, color: color)),
        const SizedBox(height: 8),
        Text(tr(context, problem?.advice ?? 'advAllOk'), textAlign: TextAlign.center),
      ]),
    );
  }

  Widget _row(BuildContext context, ColorScheme scheme, String key) {
    final item = _results[key];
    final running = _current == key && item == null;
    final (icon, color) = item == null ? (Icons.more_horiz, scheme.outline) : _look(item.check, scheme);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: item == null || item.check == _Check.skipped
              ? scheme.outlineVariant
              : color.withValues(alpha: 0.4)),
        ),
        child: Row(children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color.withValues(alpha: 0.15)),
            child: running
                ? Padding(
                    padding: const EdgeInsets.all(9),
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: scheme.primary))
                : Icon(icon, size: 20, color: color),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr(context, key), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
              const SizedBox(height: 2),
              Text(
                item?.detail ?? (running ? tr(context, 'tsRunning') : tr(context, 'tsWaiting')),
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'tsTitle'))),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: KeyedSubtree(key: ValueKey(_done), child: _hero(context, scheme, text)),
              ),
              const SizedBox(height: 16),
              for (final key in _order) _row(context, scheme, key),
              const SizedBox(height: 8),
              FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                onPressed: _running ? null : _run,
                icon: const Icon(Icons.health_and_safety_outlined),
                label: Text(tr(context, _running ? 'tsRunning' : (_done ? 'tsAgain' : 'tsRun'))),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
