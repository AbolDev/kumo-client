import 'package:flutter/material.dart';

import '../core/speed_test.dart';
import '../core/vpn_channel.dart';
import '../l10n/extra.dart';
import '../state/app_state.dart';

const _historyFile = 'speed_history.json';

/// The speed of the connection: the download, the upload and the delay, against a server of the user's
/// choice (Cloudflare unless changed). With a VPN up the test goes through it, otherwise it measures the
/// network itself; the last tests are kept to compare.
class SpeedTestPage extends StatefulWidget {
  const SpeedTestPage({super.key, required this.state});

  final AppState state;

  @override
  State<SpeedTestPage> createState() => _SpeedTestPageState();
}

class _SpeedTestPageState extends State<SpeedTestPage> {
  var _server = speedServers.first;
  var _running = false;
  var _cancel = false;
  SpeedStage? _stage;
  SpeedResult? _result;
  var _history = <SpeedResult>[];

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  @override
  void dispose() {
    // A test that is still going stops at the end of its stage; nothing is drawn after that.
    _cancel = true;
    super.dispose();
  }

  Future<void> _loadHistory() async {
    String? text;
    try {
      text = await VpnChannel.readFile(_historyFile);
    } catch (_) {}
    if (!mounted) return;
    setState(() => _history = decodeHistory(text));
  }

  Future<void> _saveHistory() async {
    try {
      await VpnChannel.writeFile(_historyFile, encodeHistory(_history));
    } catch (_) {}
  }

  Future<void> _start() async {
    final route = widget.state.speedRoute();
    if (route == null) return;
    setState(() {
      _running = true;
      _cancel = false;
      _result = null;
      _stage = SpeedStage.ping;
    });
    final server = _server;
    final r = await runSpeedTest(
      server,
      route,
      via: route.viaVpn ? widget.state.selected?.name : null,
      onStage: (s) {
        if (mounted) setState(() => _stage = s);
      },
      onResult: (p) {
        if (mounted) setState(() => _result = p);
      },
      cancelled: () => _cancel || !mounted,
    );
    if (!mounted) return;
    final got = r.pingMs != null || r.downMbps != null || r.upMbps != null;
    setState(() {
      _running = false;
      _stage = null;
      _result = r;
      if (got) _history = addToHistory(_history, r);
    });
    if (got) _saveHistory();
  }

  String _mbps(double? v) {
    if (v == null) return '—';
    return v < 10 ? v.toStringAsFixed(2) : v.toStringAsFixed(1);
  }

  String _when(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  Widget _tile(IconData icon, String label, String value, String unit, {String? note}) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Card(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: scheme.primary),
            const SizedBox(height: 6),
            Text(label, style: Theme.of(context).textTheme.labelMedium, textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text(ltr(value),
                textDirection: TextDirection.ltr,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
            Text(unit, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            if (note != null)
              Text(note, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ]),
        ),
      ),
    );
  }

  String _stageText(SpeedStage s) => switch (s) {
        SpeedStage.ping => tr(context, 'speedStagePing'),
        SpeedStage.download => tr(context, 'speedStageDownload'),
        SpeedStage.upload => tr(context, 'speedStageUpload'),
      };

  Widget _historyRow(SpeedResult h) {
    final scheme = Theme.of(context).colorScheme;
    final name = speedServerById(h.serverId).name;
    final mode = h.viaVpn ? (h.via == null || h.via!.isEmpty ? tr(context, 'speedTagVpn') : h.via!) : tr(context, 'speedTagDirect');
    return ListTile(
      dense: true,
      leading: Icon(h.viaVpn ? Icons.vpn_key_outlined : Icons.public, color: scheme.primary),
      title: Text('$name · $mode', maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        ltr('↓ ${_mbps(h.downMbps)}   ↑ ${_mbps(h.upMbps)} Mbps   ${h.pingMs ?? '—'} ms'),
        textDirection: TextDirection.ltr,
      ),
      trailing: Text(_when(h.at), style: Theme.of(context).textTheme.bodySmall),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final route = widget.state.speedRoute();
    final r = _result;
    final failed = !_running && r != null && r.pingMs == null && r.downMbps == null && r.upMbps == null;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'speedTitle'))),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              DropdownButtonFormField<String>(
                value: _server.id,
                decoration: InputDecoration(
                  labelText: tr(context, 'speedServer'),
                  border: const OutlineInputBorder(),
                ),
                items: [
                  for (final s in speedServers) DropdownMenuItem(value: s.id, child: Text(s.name)),
                ],
                onChanged: _running ? null : (id) => setState(() => _server = speedServerById(id)),
              ),
              const SizedBox(height: 8),
              Text(
                route == null
                    ? tr(context, 'speedNoRoute')
                    : route.viaVpn
                        ? tr(context, 'speedViaVpn', {'name': widget.state.selected?.name ?? ''})
                        : tr(context, 'speedDirect'),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
              if (!_server.canUpload)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(tr(context, 'speedNoUpload'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                ),
              const SizedBox(height: 16),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _tile(Icons.south, tr(context, 'speedDownload'), _mbps(r?.downMbps), 'Mbps'),
                const SizedBox(width: 8),
                _tile(Icons.north, tr(context, 'speedUpload'), _server.canUpload ? _mbps(r?.upMbps) : '—', 'Mbps'),
                const SizedBox(width: 8),
                _tile(Icons.timer_outlined, tr(context, 'speedPing'), r?.pingMs?.toString() ?? '—', 'ms',
                    note: r?.jitterMs == null ? null : tr(context, 'speedJitter', {'ms': r!.jitterMs!})),
              ]),
              const SizedBox(height: 16),
              if (_running) ...[
                LinearProgressIndicator(borderRadius: BorderRadius.circular(4)),
                const SizedBox(height: 8),
                Text(_stage == null ? '' : _stageText(_stage!), textAlign: TextAlign.center),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => setState(() => _cancel = true),
                  icon: const Icon(Icons.stop),
                  label: Text(tr(context, 'speedStop')),
                ),
              ] else
                FilledButton.icon(
                  onPressed: route == null ? null : _start,
                  icon: const Icon(Icons.play_arrow),
                  label: Text(tr(context, r == null ? 'speedStart' : 'speedAgain')),
                ),
              if (failed)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(tr(context, 'speedFailed'), textAlign: TextAlign.center, style: TextStyle(color: scheme.error)),
                ),
              const SizedBox(height: 8),
              Text(tr(context, 'speedDataNote'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: 24),
              Row(children: [
                Expanded(child: Text(tr(context, 'speedHistory'), style: Theme.of(context).textTheme.titleMedium)),
                if (_history.isNotEmpty)
                  TextButton(
                    onPressed: _running
                        ? null
                        : () {
                            setState(() => _history = []);
                            _saveHistory();
                          },
                    child: Text(tr(context, 'speedClear')),
                  ),
              ]),
              if (_history.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(tr(context, 'speedHistoryEmpty'),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                )
              else
                for (final h in _history) _historyRow(h),
            ],
          ),
        ),
      ),
    );
  }
}
