import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../core/speed_test.dart';
import '../core/vpn_channel.dart';
import '../l10n/extra.dart';
import '../state/app_state.dart';

const _historyFile = 'speed_history.json';

/// The highest speed on the gauge, in Mbit/s (the scale is logarithmic, so slow lines still move it).
const _gaugeMax = 500.0;

/// The speed of the connection: the delay, the download and the upload, against a server of the user's
/// choice (Cloudflare unless changed). With a VPN up the test goes through it, otherwise it measures the
/// network itself. Three faces: ready (a big start button and the choices), running (a live gauge, the
/// choices hidden) and done (the results); the last tests are kept to compare.
class SpeedTestPage extends StatefulWidget {
  const SpeedTestPage({super.key, required this.state});

  final AppState state;

  @override
  State<SpeedTestPage> createState() => _SpeedTestPageState();
}

class _SpeedTestPageState extends State<SpeedTestPage> with SingleTickerProviderStateMixin {
  var _server = speedServers.first;
  var _running = false;
  var _cancel = false;
  SpeedStage? _stage;
  SpeedResult? _result;
  var _history = <SpeedResult>[];
  var _capMb = speedDefaultMb;

  // The live speed of the stage that runs, its trace and how long it has run.
  double _live = 0;
  final _trace = <double>[];
  Duration _elapsed = Duration.zero;

  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 2200))
    ..repeat();

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  @override
  void dispose() {
    // A test that is still going stops at the end of its stage; nothing is drawn after that.
    _cancel = true;
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    String? text;
    try {
      text = await VpnChannel.readFile(_historyFile);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _history = decodeHistory(text);
      _capMb = decodeCapMb(text);
    });
  }

  Future<void> _saveHistory() async {
    try {
      await VpnChannel.writeFile(_historyFile, encodeHistory(_history, capMb: _capMb));
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
      _live = 0;
      _trace.clear();
      _elapsed = Duration.zero;
    });
    final r = await runSpeedTest(
      _server,
      route,
      maxMb: _capMb,
      via: route.viaVpn ? widget.state.selected?.name : null,
      onStage: (s) {
        if (!mounted) return;
        setState(() {
          _stage = s;
          _live = 0;
          _trace.clear();
          _elapsed = Duration.zero;
        });
      },
      onResult: (p) {
        if (mounted) setState(() => _result = p);
      },
      onLive: (stage, mbps, elapsed) {
        if (!mounted || stage != _stage) return;
        setState(() {
          _live = mbps;
          _elapsed = elapsed;
          _trace.add(mbps);
          if (_trace.length > 120) _trace.removeAt(0);
        });
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

  static String _mbps(double? v) {
    if (v == null) return '—';
    return v < 10 ? v.toStringAsFixed(2) : v.toStringAsFixed(1);
  }

  static String _when(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    final now = DateTime.now();
    final today = t.year == now.year && t.month == now.month && t.day == now.day;
    return today ? '${two(t.hour)}:${two(t.minute)}' : '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  String _routeText(SpeedRoute? route) {
    if (route == null) return tr(context, 'speedNoRoute');
    if (!route.viaVpn) return tr(context, 'speedNoVpnShort');
    return tr(context, 'speedViaShort', {'name': widget.state.selected?.name ?? 'VPN'});
  }

  // ---- the choices

  Future<void> _pickServer() async {
    final picked = await showModalBottomSheet<SpeedServer>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.only(bottom: 12), children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(tr(context, 'speedServer'), style: Theme.of(context).textTheme.titleMedium),
          ),
          for (final s in speedServers)
            ListTile(
              leading: Icon(s.id == _server.id ? Icons.radio_button_checked : Icons.radio_button_off,
                  color: s.id == _server.id ? Theme.of(context).colorScheme.primary : null),
              title: Text(s.name),
              subtitle: Text(s.canUpload ? s.host : '${s.host} · ${tr(context, 'speedNoUploadShort')}',
                  textDirection: TextDirection.ltr),
              onTap: () => Navigator.pop(context, s),
            ),
        ]),
      ),
    );
    if (picked != null && mounted) setState(() => _server = picked);
  }

  Future<void> _pickCap() async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr(context, 'speedMax'), style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final mb in speedMbChoices)
                ChoiceChip(
                  label: Text('$mb MB', textDirection: TextDirection.ltr),
                  selected: _capMb == mb,
                  onSelected: (_) => Navigator.pop(context, mb),
                ),
            ]),
            const SizedBox(height: 12),
            Text(tr(context, 'speedDataNote'), style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      ),
    );
    if (picked != null && mounted) {
      setState(() => _capMb = picked);
      _saveHistory();
    }
  }

  Widget _choices(SpeedRoute? route) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
      ActionChip(
        avatar: const Icon(Icons.public, size: 18),
        label: Text(_server.name),
        onPressed: _pickServer,
      ),
      Chip(
        avatar: Icon(route?.viaVpn == true ? Icons.verified_user_outlined : Icons.wifi, size: 18, color: scheme.primary),
        label: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: Text(_routeText(route), overflow: TextOverflow.ellipsis),
        ),
      ),
      ActionChip(
        avatar: const Icon(Icons.data_usage, size: 18),
        label: Text('$_capMb MB', textDirection: TextDirection.ltr),
        onPressed: _pickCap,
      ),
    ]);
  }

  // ---- ready

  Widget _goButton(bool enabled) {
    final scheme = Theme.of(context).colorScheme;
    final color = enabled ? scheme.primary : scheme.surfaceContainerHighest;
    final on = enabled ? scheme.onPrimary : scheme.onSurfaceVariant;
    return SizedBox(
      width: 200,
      height: 200,
      child: Stack(alignment: Alignment.center, children: [
        // Two rings that grow and fade, as if the button breathed.
        if (enabled)
          AnimatedBuilder(
            animation: _pulse,
            builder: (context, _) => CustomPaint(
              size: const Size(200, 200),
              painter: _PulsePainter(_pulse.value, scheme.primary),
            ),
          ),
        Container(
          width: 156,
          height: 156,
          decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: color.withValues(alpha: 0.5), width: 2)),
        ),
        Material(
          color: color,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: enabled ? _start : null,
            child: SizedBox(
              width: 136,
              height: 136,
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Text(tr(context, 'speedGo'),
                    style: TextStyle(color: on, fontSize: 34, fontWeight: FontWeight.w800, letterSpacing: 3)),
                const SizedBox(height: 2),
                Text(tr(context, 'speedStart'), style: TextStyle(color: on.withValues(alpha: 0.85), fontSize: 12)),
              ]),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _ready(SpeedRoute? route) => Column(children: [
        const SizedBox(height: 12),
        Center(child: _goButton(route != null)),
        const SizedBox(height: 16),
        _choices(route),
        if (!_server.canUpload) ...[
          const SizedBox(height: 8),
          Text(tr(context, 'speedNoUpload'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
      ]);

  // ---- running

  Widget _mini(String label, String value, String unit, {required bool active, bool done = false}) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Expanded(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        decoration: BoxDecoration(
          color: active ? scheme.primaryContainer.withValues(alpha: 0.55) : scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: active ? scheme.primary : scheme.outlineVariant, width: active ? 1.5 : 1),
        ),
        child: Column(children: [
          Text(label, style: text.labelMedium?.copyWith(color: scheme.onSurfaceVariant), maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(value,
                textDirection: TextDirection.ltr,
                style: text.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700, color: done || active ? scheme.onSurface : scheme.onSurfaceVariant)),
          ),
          Text(unit, style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }

  Widget _row({bool runningNow = false}) {
    final r = _result;
    final s = _stage;
    final downLive = runningNow && s == SpeedStage.download;
    final upLive = runningNow && s == SpeedStage.upload;
    return Row(children: [
      _mini(tr(context, 'speedPing'), r?.pingMs?.toString() ?? '—', r?.jitterMs == null ? 'ms' : 'ms · ±${r!.jitterMs}',
          active: runningNow && s == SpeedStage.ping, done: r?.pingMs != null),
      const SizedBox(width: 8),
      _mini(tr(context, 'speedDownload'), downLive ? _mbps(_live) : _mbps(r?.downMbps), 'Mbps',
          active: downLive, done: r?.downMbps != null),
      const SizedBox(width: 8),
      _mini(tr(context, 'speedUpload'), upLive ? _mbps(_live) : (_server.canUpload ? _mbps(r?.upMbps) : '—'), 'Mbps',
          active: upLive, done: r?.upMbps != null),
    ]);
  }

  String _stageText(SpeedStage s) => switch (s) {
        SpeedStage.ping => tr(context, 'speedStagePing'),
        SpeedStage.download => tr(context, 'speedStageDownload'),
        SpeedStage.upload => tr(context, 'speedStageUpload'),
      };

  Widget _runningView() {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final stage = _stage ?? SpeedStage.ping;
    final measuring = stage != SpeedStage.ping;
    final color = stage == SpeedStage.upload ? scheme.tertiary : scheme.primary;
    return Column(children: [
      _row(runningNow: true),
      const SizedBox(height: 16),
      Semantics(
        label: measuring ? '${_mbps(_live)} Mbps' : _stageText(stage),
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: measuring ? _live : 0),
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
          builder: (context, value, _) => CustomPaint(
            size: const Size(300, 170),
            painter: _GaugePainter(
              value: value,
              track: scheme.surfaceContainerHighest,
              fill: color,
              needle: scheme.onSurface,
              label: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
      Text(measuring ? _mbps(_live) : '…',
          textDirection: TextDirection.ltr, style: text.displayMedium?.copyWith(fontWeight: FontWeight.w700, color: scheme.onSurface)),
      Text(
        measuring ? 'Mbps · ${_stageText(stage)} · ${ltr('${_elapsed.inSeconds} s')}' : _stageText(stage),
        style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 12),
      SizedBox(
        height: 52,
        width: double.infinity,
        child: CustomPaint(painter: _TracePainter(List.of(_trace), color)),
      ),
      const SizedBox(height: 16),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.error,
          side: BorderSide(color: scheme.error.withValues(alpha: 0.6)),
          minimumSize: const Size(140, 48),
        ),
        onPressed: _cancel ? null : () => setState(() => _cancel = true),
        icon: const Icon(Icons.stop_rounded),
        label: Text(tr(context, 'speedStop')),
      ),
    ]);
  }

  // ---- done

  Future<void> _share(SpeedResult r) async {
    final text = tr(context, 'speedShareText', {
      'server': speedServerById(r.serverId).name,
      'down': _mbps(r.downMbps),
      'up': _mbps(r.upMbps),
      'ping': r.pingMs ?? '—',
    });
    try {
      await Share.share(text);
    } catch (_) {}
  }

  Widget _doneView(SpeedRoute? route) {
    final scheme = Theme.of(context).colorScheme;
    final r = _result!;
    final failed = r.pingMs == null && r.downMbps == null && r.upMbps == null;
    return Column(children: [
      _row(),
      if (failed) ...[
        const SizedBox(height: 12),
        Text(tr(context, 'speedFailed'), textAlign: TextAlign.center, style: TextStyle(color: scheme.error)),
      ],
      const SizedBox(height: 16),
      _choices(route),
      const SizedBox(height: 16),
      Row(children: [
        if (!failed) ...[
          Expanded(
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: () => _share(r),
              icon: const Icon(Icons.share_outlined),
              label: Text(tr(context, 'speedShare')),
            ),
          ),
          const SizedBox(width: 12),
        ],
        Expanded(
          flex: 2,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52), shape: const StadiumBorder()),
            onPressed: route == null ? null : _start,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(tr(context, 'speedAgain')),
          ),
        ),
      ]),
    ]);
  }

  // ---- the last tests

  Widget _historyRow(SpeedResult h) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final where = h.viaVpn ? (h.via == null || h.via!.isEmpty ? tr(context, 'speedTagVpn') : h.via!) : tr(context, 'speedTagDirect');
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)))),
      child: Row(children: [
        Icon(h.viaVpn ? Icons.verified_user_outlined : Icons.wifi, size: 20, color: scheme.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(where, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodyMedium),
            Text('${speedServerById(h.serverId).name} · ${ltr(_when(h.at))}',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ]),
        ),
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('↓ ${_mbps(h.downMbps)}  ↑ ${_mbps(h.upMbps)}',
              textDirection: TextDirection.ltr, style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          Text('${h.pingMs ?? '—'} ms', textDirection: TextDirection.ltr, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ]),
      ]),
    );
  }

  Widget _historyView() {
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: Text(tr(context, 'speedHistory'), style: Theme.of(context).textTheme.titleMedium)),
        if (_history.isNotEmpty)
          TextButton(
            onPressed: () {
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
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final route = widget.state.speedRoute();
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'speedTitle'))),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: KeyedSubtree(
                  key: ValueKey(_running ? 'run' : (_result == null ? 'ready' : 'done')),
                  child: _running ? _runningView() : (_result == null ? _ready(route) : _doneView(route)),
                ),
              ),
              // The history and the rest wait while a test runs: only the test is on the page.
              if (!_running) ...[
                const SizedBox(height: 28),
                _historyView(),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Where a speed sits on the gauge, 0 to 1: logarithmic, so 1 and 10 Mbit/s are as far apart as 50 and 500.
double gaugeFraction(double mbps) {
  final v = mbps.isNaN || mbps < 0 ? 0.0 : (mbps > _gaugeMax ? _gaugeMax : mbps);
  return math.log(1 + v) / math.log(1 + _gaugeMax);
}

/// A half circle with the speed: a track, the part reached, the marks and a needle.
class _GaugePainter extends CustomPainter {
  _GaugePainter({required this.value, required this.track, required this.fill, required this.needle, required this.label});

  final double value;
  final Color track, fill, needle, label;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 16.0;
    final radius = math.min(size.width / 2, size.height - 12) - stroke / 2;
    final center = Offset(size.width / 2, size.height - 10);
    final rect = Rect.fromCircle(center: center, radius: radius);
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, math.pi, math.pi, false, base..color = track);
    final f = gaugeFraction(value);
    if (f > 0.001) canvas.drawArc(rect, math.pi, math.pi * f, false, base..color = fill);

    // The marks, inside the arc.
    for (final mark in const [0, 1, 5, 10, 50, 100, 250, 500]) {
      final a = math.pi + math.pi * gaugeFraction(mark.toDouble());
      final p = Offset(center.dx + math.cos(a) * (radius - 26), center.dy + math.sin(a) * (radius - 26));
      final tp = TextPainter(
        text: TextSpan(text: '$mark', style: TextStyle(color: label, fontSize: 10)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, p - Offset(tp.width / 2, tp.height / 2));
    }

    // The needle.
    final a = math.pi + math.pi * f;
    final tip = Offset(center.dx + math.cos(a) * (radius - 10), center.dy + math.sin(a) * (radius - 10));
    canvas.drawLine(
        center,
        tip,
        Paint()
          ..color = needle
          ..strokeWidth = 4
          ..strokeCap = StrokeCap.round);
    canvas.drawCircle(center, 8, Paint()..color = needle);
    canvas.drawCircle(center, 3.5, Paint()..color = fill);
  }

  @override
  bool shouldRepaint(_GaugePainter old) =>
      old.value != value || old.fill != fill || old.track != track || old.needle != needle;
}

/// The speed over the stage, as a line with a soft fill under it.
class _TracePainter extends CustomPainter {
  _TracePainter(this.points, this.color);

  final List<double> points;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final top = points.reduce(math.max);
    if (top <= 0) return;
    final step = size.width / (points.length - 1);
    final line = Path();
    for (var i = 0; i < points.length; i++) {
      final p = Offset(i * step, size.height - points[i] / top * (size.height - 4));
      if (i == 0) {
        line.moveTo(p.dx, p.dy);
      } else {
        line.lineTo(p.dx, p.dy);
      }
    }
    final area = Path.from(line)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(area, Paint()..color = color.withValues(alpha: 0.15));
    canvas.drawPath(
        line,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(_TracePainter old) => true;
}

/// Rings that grow out of the start button and fade.
class _PulsePainter extends CustomPainter {
  _PulsePainter(this.t, this.color);

  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    for (final shift in const [0.0, 0.5]) {
      final k = (t + shift) % 1.0;
      final radius = 70 + k * 30;
      canvas.drawCircle(
          center,
          radius,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = color.withValues(alpha: (1 - k) * 0.35));
    }
  }

  @override
  bool shouldRepaint(_PulsePainter old) => old.t != t;
}
