import 'package:flutter/material.dart';

import '../core/service_check.dart';
import '../l10n/extra.dart';
import '../state/app_state.dart';

/// Shows which well-known services open from here (ChatGPT, Netflix, YouTube, Telegram ...). With the VPN on
/// the requests go through the app's local proxy, so they take the same way out as the user's own traffic;
/// with the VPN off they go straight out, which shows what the network itself lets through.
class ServiceTestPage extends StatefulWidget {
  const ServiceTestPage({super.key, required this.state, this.autoRun = true});

  final AppState state;

  /// Whether the test starts when the page opens (the tests of the page turn it off).
  final bool autoRun;

  @override
  State<ServiceTestPage> createState() => _ServiceTestPageState();
}

class _ServiceTestPageState extends State<ServiceTestPage> {
  final _results = <String, ({ServiceResult result, int ms})>{};
  final _running = <String>{};
  String? _ip, _country;
  var _runId = 0;

  /// Whether the last run went through the VPN (null before the first one).
  bool? _viaVpn;

  List<String> get _names => ['ChatGPT', 'Netflix', ...serviceProbes.skip(1).map((p) => p.name)];

  AppState get _state => widget.state;

  /// The local proxy to ask through, or null to go straight out.
  int? get _port => _state.connected ? _state.net.proxyPort : null;

  @override
  void initState() {
    super.initState();
    _state.addListener(_onState);
    if (widget.autoRun) _run();
  }

  @override
  void dispose() {
    _state.removeListener(_onState);
    _runId++; // results that arrive later are dropped
    super.dispose();
  }

  /// The connection went up or down while the page is open: what is shown is for the other way, so it is
  /// tested again.
  void _onState() {
    final now = _state.connected;
    if (_viaVpn != null && now != _viaVpn && !_state.transitioning && _running.isEmpty) _run();
  }

  Future<void> _run() async {
    final id = ++_runId;
    final port = _port;
    setState(() {
      _viaVpn = _state.connected;
      _results.clear();
      _ip = _country = null;
      _running
        ..clear()
        ..addAll(_names);
    });
    await Future.wait([
      for (final name in _names) _probe(id, port, name),
      _lookupAddress(id, port),
    ]);
  }

  Future<void> _probe(int id, int? port, String name) async {
    final r = name == 'Netflix'
        ? await runNetflix(port)
        : await runProbe(serviceProbes.firstWhere((p) => p.name == name), port);
    if (!mounted || id != _runId) return;
    setState(() {
      _results[name] = r;
      _running.remove(name);
    });
  }

  /// One service again (a tap on it), the others as they are.
  Future<void> _retest(String name) async {
    if (_running.contains(name)) return;
    final id = _runId;
    setState(() {
      _results.remove(name);
      _running.add(name);
    });
    await _probe(id, _viaVpn == true ? _state.net.proxyPort : null, name);
  }

  /// Which address and country the services see.
  Future<void> _lookupAddress(int id, int? port) async {
    final r = await fetchThrough('https://www.cloudflare.com/cdn-cgi/trace', proxyPort: port);
    if (!mounted || id != _runId || r.status != 200) return;
    final map = {
      for (final l in r.body.split('\n'))
        if (l.contains('=')) l.split('=').first: l.substring(l.indexOf('=') + 1).trim(),
    };
    setState(() {
      _ip = map['ip'];
      _country = map['loc'];
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final busy = _running.isNotEmpty;
    final open = _results.values.where((r) => r.result != ServiceResult.blocked).length;
    final vpn = _viaVpn ?? _state.connected;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'svcTitle')),
        actions: [
          IconButton(
            tooltip: tr(context, 'svcRun'),
            icon: const Icon(Icons.refresh),
            onPressed: busy ? null : _run,
          ),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              // The summary: the way it is tested, how many open, and the address the services see.
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: vpn ? scheme.primaryContainer : scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(vpn ? Icons.vpn_lock : Icons.public_off_outlined,
                              size: 16, color: vpn ? scheme.onPrimaryContainer : scheme.onSurfaceVariant),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(tr(context, vpn ? 'svcModeVpn' : 'svcModeDirect'),
                                style: text.labelMedium?.copyWith(
                                    color: vpn ? scheme.onPrimaryContainer : scheme.onSurfaceVariant)),
                          ),
                        ]),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 14),
                  Text(
                    busy
                        ? tr(context, 'svcChecking', {'done': _names.length - _running.length, 'total': _names.length})
                        : tr(context, 'svcSummary', {'ok': open, 'total': _names.length}),
                    style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      minHeight: 8,
                      value: (_names.length - _running.length) / _names.length,
                      backgroundColor: scheme.surfaceContainerHighest,
                    ),
                  ),
                  if (_ip != null) ...[
                    const SizedBox(height: 12),
                    Row(children: [
                      Icon(Icons.my_location, size: 16, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(tr(context, 'svcYourIp', {'ip': _ip ?? '?', 'country': _country ?? '?'}),
                            textDirection: TextDirection.ltr,
                            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                      ),
                    ]),
                  ],
                ]),
              ),
              const SizedBox(height: 12),
              for (final name in _names) _tile(context, name),
              const SizedBox(height: 4),
              Center(
                child: Text(tr(context, 'svcTapRetest'),
                    style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                onPressed: busy ? null : _run,
                icon: const Icon(Icons.refresh),
                label: Text(tr(context, 'svcRun')),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, String name) {
    final r = _results[name];
    final scheme = Theme.of(context).colorScheme;
    final brand = Color(serviceColors[name] ?? 0xFF607D8B);
    final (color, text) = switch (r?.result) {
      ServiceResult.works => (Colors.green.shade600, tr(context, 'svcWorks')),
      ServiceResult.originalsOnly => (Colors.orange.shade700, tr(context, 'svcOriginals')),
      ServiceResult.blocked => (scheme.error, tr(context, 'svcBlocked')),
      null => (scheme.outline, ''),
    };
    final running = _running.contains(name);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: running ? null : () => _retest(name),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(children: [
              CircleAvatar(
                backgroundColor: brand,
                child: Text(name.characters.first,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                  if (text.isNotEmpty)
                    Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w500)),
                ]),
              ),
              if (running)
                const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
              else if (r != null) ...[
                if (r.result != ServiceResult.blocked)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 10),
                    child: Text('${r.ms} ms',
                        textDirection: TextDirection.ltr,
                        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
                  ),
                Icon(
                  switch (r.result) {
                    ServiceResult.works => Icons.check_circle,
                    ServiceResult.originalsOnly => Icons.warning_amber_rounded,
                    ServiceResult.blocked => Icons.cancel,
                  },
                  color: color,
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}
