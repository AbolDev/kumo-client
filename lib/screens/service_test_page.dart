import 'package:flutter/material.dart';

import '../core/service_check.dart';
import '../l10n/extra.dart';
import '../state/app_state.dart';

/// Shows which well-known services open through the current connection (ChatGPT, Netflix,
/// YouTube, Telegram ...). The requests go through the app's local proxy, so they take the same
/// way out as the user's own traffic.
class ServiceTestPage extends StatefulWidget {
  const ServiceTestPage({super.key, required this.state});

  final AppState state;

  @override
  State<ServiceTestPage> createState() => _ServiceTestPageState();
}

class _ServiceTestPageState extends State<ServiceTestPage> {
  final _results = <String, ({ServiceResult result, int ms})>{};
  final _running = <String>{};
  String? _seenAs;
  var _runId = 0;

  List<String> get _names => ['ChatGPT', 'Netflix', ...serviceProbes.skip(1).map((p) => p.name)];

  @override
  void initState() {
    super.initState();
    if (widget.state.connected) _run();
  }

  @override
  void dispose() {
    _runId++; // results that arrive later are dropped
    super.dispose();
  }

  Future<void> _run() async {
    final id = ++_runId;
    final port = widget.state.net.proxyPort;
    setState(() {
      _results.clear();
      _seenAs = null;
      _running
        ..clear()
        ..addAll(_names);
    });

    Future<void> one(String name, Future<({ServiceResult result, int ms})> Function() job) async {
      final r = await job();
      if (!mounted || id != _runId) return;
      setState(() {
        _results[name] = r;
        _running.remove(name);
      });
    }

    final jobs = <Future<void>>[
      one('Netflix', () => runNetflix(port)),
      for (final p in serviceProbes) one(p.name, () => runProbe(p, port)),
      _lookupAddress(id, port),
    ];
    await Future.wait(jobs);
  }

  /// Which address and country the services see.
  Future<void> _lookupAddress(int id, int port) async {
    final r = await fetchThrough('https://www.cloudflare.com/cdn-cgi/trace', proxyPort: port);
    if (!mounted || id != _runId || r.status != 200) return;
    final map = {
      for (final l in r.body.split('\n'))
        if (l.contains('=')) l.split('=').first: l.substring(l.indexOf('=') + 1).trim(),
    };
    setState(() => _seenAs = tr(context, 'svcYourIp', {
          'ip': map['ip'] ?? '?',
          'country': map['loc'] ?? '?',
        }));
  }

  @override
  Widget build(BuildContext context) {
    final connected = widget.state.connected;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'svcTitle')),
        actions: [
          IconButton(
            tooltip: tr(context, 'svcRun'),
            icon: const Icon(Icons.refresh),
            onPressed: connected && _running.isEmpty ? _run : null,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!connected)
            Card(
              child: ListTile(
                leading: const Icon(Icons.info_outline),
                title: Text(tr(context, 'svcNeedVpn')),
              ),
            ),
          if (_seenAs != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(_seenAs!, textDirection: TextDirection.ltr),
            ),
          for (final name in _names) _tile(context, name),
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, String name) {
    final r = _results[name];
    final scheme = Theme.of(context).colorScheme;
    final (icon, color, text) = switch (r?.result) {
      ServiceResult.works => (Icons.check_circle, Colors.green, tr(context, 'svcWorks')),
      ServiceResult.originalsOnly => (Icons.warning_amber, Colors.orange, tr(context, 'svcOriginals')),
      ServiceResult.blocked => (Icons.cancel, scheme.error, tr(context, 'svcBlocked')),
      null => (Icons.help_outline, scheme.outline, ''),
    };
    return ListTile(
      leading: _running.contains(name)
          ? const SizedBox(
              width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
          : Icon(icon, color: color),
      title: Text(name),
      subtitle: text.isEmpty ? null : Text(text),
      trailing: r == null || r.result == ServiceResult.blocked
          ? null
          : Text('${r.ms} ms', textDirection: TextDirection.ltr),
    );
  }
}
