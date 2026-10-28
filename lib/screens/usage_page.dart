import 'package:flutter/material.dart';

import '../core/usage_stats.dart';
import '../l10n/extra.dart';
import '../state/app_state.dart';
import 'home_page.dart' show confirmDeletion;

const _downColor = Colors.green;
const _upColor = Colors.blue;

enum _Period { today, week, month, all }

extension on _Period {
  /// How many days the numbers add up; null is everything saved.
  int? get days => switch (this) {
        _Period.today => 1,
        _Period.week => 7,
        _Period.month => 30,
        _Period.all => null,
      };

  String get key => switch (this) {
        _Period.today => 'usePeriodToday',
        _Period.week => 'usePeriod7',
        _Period.month => 'usePeriod30',
        _Period.all => 'usePeriodAll',
      };
}

/// Data used per day and per server, the time connected, and a chart of the last two minutes
/// of speed.
class UsagePage extends StatefulWidget {
  const UsagePage({super.key, required this.state});

  final AppState state;

  @override
  State<UsagePage> createState() => _UsagePageState();
}

class _UsagePageState extends State<UsagePage> {
  _Period _period = _Period.week;

  /// The bar of the daily chart that was tapped (its day), null shows today.
  String? _picked;

  AppState get state => widget.state;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'usage')),
        actions: [
          IconButton(
            tooltip: tr(context, 'resetStats'),
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              if (await confirmDeletion(context, state)) {
                setState(() => _picked = null);
                state.resetUsage();
              }
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        // The totals change with every traffic sample (once a second), not only with the app state.
        listenable: Listenable.merge([state, state.traffic]),
        builder: (context, _) {
          final now = DateTime.now();
          final summary = summarizeUsage(state.dayUsage, _period.days, now);
          final barCount = switch (_period) {
            _Period.today || _Period.week => 7,
            _ => 30,
          };
          final bars = dailyBars(state.dayUsage, barCount, now);
          final servers = state.serverUsage.entries.toList()
            ..sort((a, b) => AppState.serverTotal(b.value)
                .compareTo(AppState.serverTotal(a.value)));
          final empty = state.dayUsage.isEmpty && state.serverUsage.isEmpty;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              _speedCard(context),
              const SizedBox(height: 16),
              Semantics(
                  container: true,
                  label: tr(context, 'a11yPeriod'),
                  child: SegmentedButton<_Period>(
                    showSelectedIcon: false,
                    segments: [
                      for (final p in _Period.values)
                        ButtonSegment(
                            value: p,
                            label: Text(tr(context, p.key),
                                maxLines: 1, overflow: TextOverflow.ellipsis)),
                    ],
                    selected: {_period},
                    onSelectionChanged: (s) => setState(() {
                      _period = s.first;
                      _picked = null;
                    }),
                  )),
              const SizedBox(height: 12),
              if (empty)
                _emptyCard(context)
              else ...[
                _summaryCard(context, summary),
                const SizedBox(height: 12),
                _dailyCard(context, bars),
                const SizedBox(height: 20),
                if (servers.isNotEmpty) _serversCard(context, servers),
              ],
            ],
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------- speed

  Widget _speedCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: ValueListenableBuilder(
          valueListenable: state.traffic,
          builder: (context, t, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Semantics(
                    header: true,
                    child: Text(tr(context, 'speed'), style: style.titleSmall)),
                const SizedBox(width: 12),
                Expanded(
                  child: Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        _arrowText('↓', '${formatBytes(t.down)}/s', _downColor,
                            style.titleMedium),
                        const SizedBox(width: 14),
                        _arrowText('↑', '${formatBytes(t.up)}/s', _upColor,
                            style.titleMedium),
                      ]),
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 10),
              Semantics(
                  label: tr(context, 'a11yChart', {
                    'down': '${formatBytes(t.down)}/s',
                    'up': '${formatBytes(t.up)}/s',
                    'peak':
                        '${formatBytes(state.peakDown > state.peakUp ? state.peakDown : state.peakUp)}/s',
                  }),
                  excludeSemantics: true,
                  child: SizedBox(
                    height: 110,
                    child: CustomPaint(
                      size: Size.infinite,
                      painter: _SpeedChart(
                          List.of(state.downHistory),
                          List.of(state.upHistory),
                          _downColor,
                          _upColor,
                          scheme.outlineVariant,
                          scheme.onSurfaceVariant),
                    ),
                  )),
              const SizedBox(height: 10),
              Wrap(spacing: 18, runSpacing: 4, children: [
                _fact(context, tr(context, 'usePeak'),
                    '↓ ${formatBytes(state.peakDown)}/s  ↑ ${formatBytes(state.peakUp)}/s'),
                _fact(context, tr(context, 'useSession'),
                    '↓ ${formatBytes(t.downTotal)}  ↑ ${formatBytes(t.upTotal)}'),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fact(BuildContext context, String label, String value) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Text.rich(
      TextSpan(children: [
        TextSpan(text: '$label  ', style: TextStyle(color: muted)),
        TextSpan(
            text: value, style: const TextStyle(fontWeight: FontWeight.w600)),
      ]),
      style: const TextStyle(fontSize: 12),
    );
  }

  Widget _arrowText(String arrow, String text, Color color, TextStyle? style) {
    return Text.rich(
      TextSpan(children: [
        TextSpan(
            text: '$arrow ',
            style: TextStyle(color: color, fontWeight: FontWeight.bold)),
        TextSpan(text: text),
      ]),
      style: style,
      textDirection: TextDirection.ltr,
    );
  }

  // ---------------------------------------------------------------- summary

  Widget _emptyCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 24),
        child: Column(children: [
          Icon(Icons.bar_chart_rounded, size: 48, color: scheme.outline),
          const SizedBox(height: 12),
          Text(tr(context, 'useNoData'),
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(tr(context, 'useNoDataDesc'),
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }

  Widget _summaryCard(BuildContext context, UsageSummary s) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final unitH = tr(context, 'useUnitH'),
        unitM = tr(context, 'useUnitM'),
        unitS = tr(context, 'useUnitS');
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr(context, 'useTotal'),
              style:
                  text.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 2),
          Text(formatBytes(s.total),
              textDirection: TextDirection.ltr,
              style:
                  text.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          // The share of download and upload as one bar.
          Directionality(
            textDirection: TextDirection.ltr,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: SizedBox(
                height: 10,
                child: Row(children: [
                  Expanded(
                      flex: (s.downShare * 1000)
                          .round()
                          .clamp(s.total == 0 ? 500 : 1, 999),
                      child: Container(
                          color: s.total == 0
                              ? scheme.outlineVariant
                              : _downColor)),
                  Expanded(
                      flex: ((1 - s.downShare) * 1000)
                          .round()
                          .clamp(s.total == 0 ? 500 : 1, 999),
                      child: Container(
                          color:
                              s.total == 0 ? scheme.outlineVariant : _upColor)),
                ]),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
                child: _arrowText(
                    '↓',
                    '${tr(context, 'useDownloaded')}  ${formatBytes(s.down)}',
                    _downColor,
                    text.bodySmall)),
            Expanded(
                child: _arrowText(
                    '↑',
                    '${tr(context, 'useUploaded')}  ${formatBytes(s.up)}',
                    _upColor,
                    text.bodySmall)),
          ]),
          const Divider(height: 28),
          LayoutBuilder(builder: (context, c) {
            final w = (c.maxWidth - 12) / 2;
            Widget tile(IconData icon, String label, String value) => SizedBox(
                  width: w,
                  child: Row(children: [
                    Icon(icon, size: 20, color: scheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 11,
                                    color: scheme.onSurfaceVariant)),
                            Text(value,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textDirection: TextDirection.ltr,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                          ]),
                    ),
                  ]),
                );
            return Wrap(spacing: 12, runSpacing: 14, children: [
              tile(Icons.timer_outlined, tr(context, 'useTime'),
                  formatDuration(s.seconds, h: unitH, m: unitM, s: unitS)),
              tile(Icons.calendar_today_outlined, tr(context, 'useDaysActive'),
                  '${s.activeDays}'),
              tile(Icons.speed_outlined, tr(context, 'useAvgDay'),
                  s.activeDays == 0 ? '—' : formatBytes(s.averagePerDay)),
              tile(
                  Icons.local_fire_department_outlined,
                  tr(context, 'useBusiest'),
                  s.busiestDay == null
                      ? '—'
                      : '${s.busiestDay!.substring(5)}  ${formatBytes(s.busiestBytes)}'),
            ]);
          }),
        ]),
      ),
    );
  }

  // ---------------------------------------------------------------- daily chart

  Widget _dailyCard(BuildContext context, List<DayBar> bars) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final peak = bars.fold<int>(1, (m, b) => b.total > m ? b.total : m);
    final shown =
        bars.firstWhere((b) => b.key == _picked, orElse: () => bars.last);
    final isToday = shown.key == bars.last.key;
    final sparse = bars.length > 14;
    const chartHeight = 120.0;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Semantics(
                header: true,
                child: Text(tr(context, 'perDay'), style: text.titleSmall)),
            const Spacer(),
            Text(isToday ? tr(context, 'today') : shown.key.substring(5),
                style:
                    text.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            Text(formatBytes(shown.total),
                textDirection: TextDirection.ltr,
                style: text.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                  '↓ ${formatBytes(shown.down)}   ↑ ${formatBytes(shown.up)}',
                  textDirection: TextDirection.ltr,
                  style:
                      text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ),
          ]),
          const SizedBox(height: 12),
          Directionality(
            textDirection: TextDirection.ltr,
            child: Column(children: [
              SizedBox(
                height: chartHeight,
                child:
                    Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  for (final b in bars)
                    Expanded(
                      child: Semantics(
                        button: true,
                        selected: b.key == shown.key,
                        excludeSemantics: true,
                        label: b.total == 0
                            ? tr(context, 'a11yDayNone', {'date': b.key})
                            : tr(context, 'a11yDayBar', {
                                'date': b.key,
                                'total': formatBytes(b.total),
                                'down': formatBytes(b.down),
                                'up': formatBytes(b.up),
                              }),
                        onTap: () => setState(() => _picked = b.key),
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setState(() => _picked = b.key),
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: sparse ? 1 : 4),
                            child: _bar(b, peak, chartHeight,
                                b.key == shown.key, scheme),
                          ),
                        ),
                      ),
                    ),
                ]),
              ),
              const SizedBox(height: 6),
              Row(children: [
                for (var i = 0; i < bars.length; i++)
                  Expanded(
                    child: Text(
                      // With 30 bars only every fifth day, counted back from today, has a number.
                      sparse && (bars.length - 1 - i) % 5 != 0
                          ? ''
                          : '${bars[i].date.day}',
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.visible,
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight:
                              bars[i].key == shown.key ? FontWeight.bold : null,
                          color: bars[i].key == shown.key
                              ? scheme.onSurface
                              : scheme.onSurfaceVariant),
                    ),
                  ),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _bar(
      DayBar b, int peak, double height, bool selected, ColorScheme scheme) {
    if (b.total == 0) {
      return Align(
        alignment: Alignment.bottomCenter,
        child: Container(
          height: 3,
          decoration: BoxDecoration(
              color: selected ? scheme.outline : scheme.outlineVariant,
              borderRadius: BorderRadius.circular(2)),
        ),
      );
    }
    final h = (b.total / peak * (height - 6)).clamp(4.0, height - 6);
    final upH = b.up == 0 ? 0.0 : (h * b.up / b.total).clamp(2.0, h);
    final opacity = selected ? 1.0 : 0.55;
    return Align(
      alignment: Alignment.bottomCenter,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
        child: SizedBox(
          height: h,
          child: Column(children: [
            if (upH > 0)
              Expanded(
                  flex: upH.round().clamp(1, 1 << 20),
                  child: _fill(_upColor, opacity)),
            Expanded(
                flex: (h - upH).round().clamp(1, 1 << 20),
                child: _fill(_downColor, opacity)),
          ]),
        ),
      ),
    );
  }

  Widget _fill(Color c, double opacity) =>
      ColoredBox(color: c.withValues(alpha: opacity));

  // ---------------------------------------------------------------- servers

  Widget _serversCard(
      BuildContext context, List<MapEntry<String, List<int>>> servers) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final sum =
        servers.fold<int>(0, (m, e) => m + AppState.serverTotal(e.value));
    final top = AppState.serverTotal(servers.first.value);
    final unitH = tr(context, 'useUnitH'),
        unitM = tr(context, 'useUnitM'),
        unitS = tr(context, 'useUnitS');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(tr(context, 'perServer'), style: text.titleSmall),
      ),
      Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Column(children: [
            for (var i = 0; i < servers.take(20).length; i++) ...[
              if (i > 0) const Divider(height: 1),
              Builder(builder: (context) {
                final e = servers[i];
                final v = e.value;
                final total = AppState.serverTotal(v);
                final pct = sum == 0 ? 0 : (total * 100 / sum).round();
                final parts = <String>[
                  if (v[0] + v[1] > 0)
                    '↓ ${formatBytes(v[0])}  ↑ ${formatBytes(v[1])}',
                  if (v[2] > 0)
                    formatDuration(v[2], h: unitH, m: unitM, s: unitS),
                  if (v[3] > 0) _lastUsed(context, v[3]),
                ];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Expanded(
                            child: Text(e.key,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                          ),
                          const SizedBox(width: 8),
                          Text(formatBytes(total),
                              textDirection: TextDirection.ltr),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 38,
                            child: Text('$pct%',
                                textAlign: TextAlign.end,
                                textDirection: TextDirection.ltr,
                                style: TextStyle(
                                    fontSize: 12,
                                    color: scheme.onSurfaceVariant)),
                          ),
                        ]),
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                              value: top == 0 ? 0 : total / top, minHeight: 6),
                        ),
                        if (parts.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(parts.join('  ·  '),
                              textDirection: TextDirection.ltr,
                              style: TextStyle(
                                  fontSize: 11,
                                  color: scheme.onSurfaceVariant)),
                        ],
                      ]),
                );
              }),
            ],
          ]),
        ),
      ),
    ]);
  }

  String _lastUsed(BuildContext context, int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final days = DateTime(now.year, now.month, now.day)
        .difference(DateTime(d.year, d.month, d.day))
        .inDays;
    if (days <= 0) return tr(context, 'today');
    if (days == 1) return tr(context, 'useYesterday');
    return dayKey(d).substring(5);
  }
}

/// The last two minutes of speed: the newest sample sits at the right edge.
class _SpeedChart extends CustomPainter {
  _SpeedChart(
      this.down, this.up, this.downColor, this.upColor, this.grid, this.label);

  final List<int> down, up;
  final Color downColor, upColor, grid, label;

  @override
  void paint(Canvas canvas, Size size) {
    final peak =
        [...down, ...up, 10 * 1024].reduce((a, b) => a > b ? a : b).toDouble();
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var i = 0; i <= 2; i++) {
      final y = size.height * i / 2;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    Offset point(int i, int count, int value) => Offset(
        size.width - size.width * (count - 1 - i) / 119,
        size.height - size.height * (value / peak) * 0.92 - 1);

    void line(List<int> data, Color color, {bool fill = false}) {
      if (data.length < 2) return;
      final path = Path();
      for (var i = 0; i < data.length; i++) {
        final p = point(i, data.length, data[i]);
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      if (fill) {
        final area = Path.from(path)
          ..lineTo(size.width, size.height)
          ..lineTo(point(0, data.length, data[0]).dx, size.height)
          ..close();
        canvas.drawPath(
            area,
            Paint()
              ..shader = LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  color.withValues(alpha: 0.28),
                  color.withValues(alpha: 0.02)
                ],
              ).createShader(Offset.zero & size));
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = color
            ..strokeWidth = 2
            ..strokeJoin = StrokeJoin.round
            ..style = PaintingStyle.stroke);
    }

    line(down, downColor, fill: true);
    line(up, upColor);

    // The scale: what the top line stands for.
    final scale = TextPainter(
      text: TextSpan(
          text: '${formatBytes(peak.round())}/s',
          style: TextStyle(fontSize: 10, color: label)),
      textDirection: TextDirection.ltr,
    )..layout();
    scale.paint(canvas, const Offset(4, 3));
  }

  @override
  bool shouldRepaint(_SpeedChart old) => true;
}
