import 'package:flutter/material.dart';

import '../core/clean_ip.dart';
import '../core/link_fields.dart';
import '../core/server_resolver.dart' show systemLookup;
import '../l10n/extra.dart';

/// "Find a clean IP" for one server (see core/clean_ip.dart). Pops with the address the user picks.
class CleanIpPage extends StatefulWidget {
  const CleanIpPage({super.key, required this.server});

  final LinkFields server;

  @override
  State<CleanIpPage> createState() => _CleanIpPageState();
}

class _CleanIpPageState extends State<CleanIpPage> {
  // The network: Cloudflare, Fastly or the user's own ranges (null).
  Cdn? _cdn = Cdn.cloudflare;
  final _custom = TextEditingController();
  String? _rangeError;
  var _running = false;
  var _cancel = false;
  var _stage = 1, _done = 0, _total = 0;
  List<CleanIp>? _found;

  @override
  void initState() {
    super.initState();
    _detect();
  }

  @override
  void dispose() {
    _cancel = true;
    _custom.dispose();
    super.dispose();
  }

  /// Chooses the CDN the server's name resolves to.
  Future<void> _detect() async {
    final host = widget.server.host;
    final ip = await systemLookup(host) ?? host;
    final cdn = cdnOf(ip);
    if (mounted && cdn != null) setState(() => _cdn = cdn);
  }

  Future<void> _scan() async {
    final List<String> ranges;
    try {
      ranges = _cdn == null ? parseRanges(_custom.text) : rangesOf(_cdn!);
      if (ranges.isEmpty) throw const FormatException('No range');
    } on FormatException catch (e) {
      setState(() => _rangeError = tr(context, 'cleanIpBadRange', {'line': '${e.source ?? e.message}'}));
      return;
    }
    setState(() {
      _rangeError = null;
      _running = true;
      _cancel = false;
      _found = null;
      _stage = 1;
      _done = 0;
      _total = 0;
    });
    final found = await scanCleanIps(
      server: widget.server,
      ranges: ranges,
      onProgress: (s, d, t) {
        if (mounted) {
          setState(() {
            _stage = s;
            _done = d;
            _total = t;
          });
        }
      },
      cancelled: () => _cancel || !mounted,
    );
    if (!mounted) return;
    setState(() {
      _running = false;
      if (!_cancel) _found = found;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final found = _found;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'cleanIpTitle'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(tr(context, 'cleanIpDesc')),
          const SizedBox(height: 16),
          DropdownButtonFormField<Cdn?>(
            value: _cdn,
            decoration: InputDecoration(labelText: tr(context, 'cleanIpNetwork'), border: const OutlineInputBorder()),
            items: [
              const DropdownMenuItem(value: Cdn.cloudflare, child: Text('Cloudflare')),
              const DropdownMenuItem(value: Cdn.fastly, child: Text('Fastly')),
              DropdownMenuItem(value: null, child: Text(tr(context, 'cleanIpCustom'))),
            ],
            onChanged: _running ? null : (v) => setState(() => _cdn = v),
          ),
          if (_cdn == null) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _custom,
              enabled: !_running,
              maxLines: 4,
              minLines: 2,
              textDirection: TextDirection.ltr,
              decoration: InputDecoration(
                labelText: tr(context, 'cleanIpRanges'),
                helperText: tr(context, 'cleanIpRangesHint'),
                helperMaxLines: 3,
                errorText: _rangeError,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Row(children: [
            FilledButton.icon(
              onPressed: _running ? null : _scan,
              icon: _running
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.travel_explore),
              label: Text(_running
                  ? tr(context, _stage == 1 ? 'cleanIpStage1' : 'cleanIpStage2', {'done': _done, 'total': _total})
                  : tr(context, 'cleanIpScan')),
            ),
            if (_running)
              TextButton(
                  onPressed: () => setState(() => _cancel = true),
                  child: Text(MaterialLocalizations.of(context).cancelButtonLabel)),
          ]),
          if (found != null) ...[
            const SizedBox(height: 16),
            if (found.isEmpty)
              Text(tr(context, 'cleanIpNone'), style: TextStyle(color: scheme.error))
            else
              for (final r in found)
                Card(
                  child: ListTile(
                    title: Text(r.ip, textDirection: TextDirection.ltr),
                    subtitle: Text('${r.delayMs} ms', textDirection: TextDirection.ltr),
                    trailing: FilledButton.tonal(
                        onPressed: () => Navigator.pop(context, r.ip), child: Text(tr(context, 'cleanIpUse'))),
                  ),
                ),
          ],
        ],
      ),
    );
  }
}
