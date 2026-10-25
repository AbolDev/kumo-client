import 'package:flutter/material.dart';

import '../l10n/extra.dart';
import '../state/app_state.dart';

String _size(int b) {
  if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
  if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
  if (b >= 1 << 10) return '${b ~/ 1024} KB';
  return '$b B';
}

/// Data used per day and per server, and a chart of the last two minutes of speed.
class UsagePage extends StatelessWidget {
  const UsagePage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'usage')),
        actions: [
          IconButton(
            tooltip: tr(context, 'resetStats'),
            icon: const Icon(Icons.delete_outline),
            onPressed: state.resetUsage,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final days = state.dayUsage.keys.toList()..sort();
          final recent = days.reversed.take(14).toList();
          final today = state.dayUsage[days.isEmpty ? '' : days.last];
          final maxDay = recent.fold<int>(
              1, (m, k) => (state.dayUsage[k]![0] + state.dayUsage[k]![1]) > m
                  ? state.dayUsage[k]![0] + state.dayUsage[k]![1]
                  : m);
          final servers = state.serverUsage.entries.toList()
            ..sort((a, b) => b.value.compareTo(a.value));
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(tr(context, 'speed'),
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              SizedBox(
                height: 110,
                child: ValueListenableBuilder(
                  valueListenable: state.traffic,
                  builder: (context, _, __) => CustomPaint(
                    size: Size.infinite,
                    painter: _SpeedChart(
                        List.of(state.downHistory),
                        List.of(state.upHistory),
                        Colors.green,
                        Colors.blue,
                        scheme.outlineVariant),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              if (today != null)
                ListTile(
                  leading: const Icon(Icons.today),
                  title: Text(tr(context, 'today')),
                  trailing: Text('↓ ${_size(today[0])}  ↑ ${_size(today[1])}',
                      textDirection: TextDirection.ltr),
                ),
              Text(tr(context, 'perDay'),
                  style: Theme.of(context).textTheme.titleSmall),
              for (final k in recent)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    SizedBox(
                        width: 92,
                        child: Text(k, style: const TextStyle(fontSize: 12))),
                    Expanded(
                      child: LinearProgressIndicator(
                        value: (state.dayUsage[k]![0] + state.dayUsage[k]![1]) /
                            maxDay,
                        minHeight: 8,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    SizedBox(
                      width: 84,
                      child: Text(
                          _size(state.dayUsage[k]![0] + state.dayUsage[k]![1]),
                          textAlign: TextAlign.end,
                          style: const TextStyle(fontSize: 12)),
                    ),
                  ]),
                ),
              const SizedBox(height: 20),
              Text(tr(context, 'perServer'),
                  style: Theme.of(context).textTheme.titleSmall),
              for (final e in servers.take(20))
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(e.key, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: Text(_size(e.value)),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _SpeedChart extends CustomPainter {
  _SpeedChart(this.down, this.up, this.downColor, this.upColor, this.grid);

  final List<int> down, up;
  final Color downColor, upColor, grid;

  @override
  void paint(Canvas canvas, Size size) {
    final border = Paint()
      ..color = grid
      ..style = PaintingStyle.stroke;
    canvas.drawRect(Offset.zero & size, border);
    final peak = [...down, ...up, 1024].reduce((a, b) => a > b ? a : b).toDouble();

    void line(List<int> data, Color color) {
      if (data.length < 2) return;
      final path = Path();
      for (var i = 0; i < data.length; i++) {
        final x = size.width * i / 119;
        final y = size.height - size.height * (data[i] / peak) * 0.9 - 2;
        i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = color
            ..strokeWidth = 2
            ..style = PaintingStyle.stroke);
    }

    line(down, downColor);
    line(up, upColor);
  }

  @override
  bool shouldRepaint(_SpeedChart old) => true;
}
