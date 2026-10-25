import 'dart:async';

import 'package:flutter/material.dart';

import '../core/core_api.dart';
import '../l10n/extra.dart';
import '../state/app_state.dart';

String _size(int b) {
  if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
  if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
  if (b >= 1 << 10) return '${b ~/ 1024} KB';
  return '$b B';
}

/// Active connections of the running VPN, refreshed every two seconds.
class ConnectionsPage extends StatefulWidget {
  const ConnectionsPage({super.key, required this.state});

  final AppState state;

  @override
  State<ConnectionsPage> createState() => _ConnectionsPageState();
}

class _ConnectionsPageState extends State<ConnectionsPage> {
  List<LiveConnection> _items = const [];
  Timer? _timer;
  var _busy = false;

  CoreApi? get _api => widget.state.api;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final api = _api;
    if (api == null || _busy || !widget.state.connected) {
      if (mounted && _items.isNotEmpty && !widget.state.connected) {
        setState(() => _items = const []);
      }
      return;
    }
    _busy = true;
    final data = await api.get('/connections');
    _busy = false;
    if (!mounted || data is! Map) return;
    final list = (data['connections'] as List? ?? const [])
        .map(LiveConnection.from)
        .whereType<LiveConnection>()
        .toList()
      ..sort((a, b) => b.start.compareTo(a.start));
    setState(() => _items = list);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${tr(context, 'liveConnections')} (${_items.length})'),
        actions: [
          IconButton(
            tooltip: tr(context, 'closeAll'),
            icon: const Icon(Icons.close),
            onPressed: _items.isEmpty
                ? null
                : () async {
                    await _api?.delete('/connections');
                    _refresh();
                  },
          ),
        ],
      ),
      body: _items.isEmpty
          ? Center(child: Text(tr(context, 'noConnections')))
          : ListView.separated(
              itemCount: _items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final c = _items[i];
                return ListTile(
                  dense: true,
                  title: Text('${c.host}:${c.port}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textDirection: TextDirection.ltr),
                  subtitle: Text(
                    [
                      c.network.toUpperCase(),
                      if (c.process.isNotEmpty) c.process,
                      c.chain,
                      if (c.rule.isNotEmpty) c.rule,
                      '↓ ${_size(c.down)}  ↑ ${_size(c.up)}',
                    ].join(' · '),
                    maxLines: 2,
                    textDirection: TextDirection.ltr,
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () async {
                      await _api?.delete('/connections/${c.id}');
                      _refresh();
                    },
                  ),
                );
              },
            ),
    );
  }
}
