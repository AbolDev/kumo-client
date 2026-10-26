import 'package:flutter/material.dart';

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

  void _add(_Item item) {
    if (mounted) setState(() => _items.add(item));
  }

  Future<void> _run() async {
    setState(() {
      _items.clear();
      _running = true;
      _done = false;
    });
    final t = (String key, [Map<String, Object>? args]) => tr(context, key, args);

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
