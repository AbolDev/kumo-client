import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../core/speed_test.dart';
import '../core/vpn_channel.dart';
import '../l10n/extra.dart';
import '../state/app_state.dart';

const _historyFile = 'speed_history.json';

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

  // The live speed of the stage that runs and how long it has run; the tries of the delay.
  double _live = 0;
  Duration _elapsed = Duration.zero;
  var _pingDone = 0, _pingTotal = 5, _pingLast = -1;

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
      _elapsed = Duration.zero;
      _pingDone = 0;
      _pingLast = -1;
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
        });
      },
      onPingTry: (done, total, ms) {
        if (!mounted) return;
        setState(() {
          _pingDone = done;
          _pingTotal = total;
          if (ms >= 0) _pingLast = ms;
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

  /// The colour of a stage: the delay, the download and the upload each have their own.
  Color _stageColor(SpeedStage st) {
    final scheme = Theme.of(context).colorScheme;
    return switch (st) {
      SpeedStage.ping => scheme.secondary,
      SpeedStage.download => scheme.primary,
      SpeedStage.upload => scheme.tertiary,
    };
  }

  /// How far each stage is, 0 to 1: the ones done are full, the one running fills with its tries or its time.
  List<double> _progress() {
    final stages = [SpeedStage.ping, SpeedStage.download, if (_server.canUpload) SpeedStage.upload];
    final now = stages.indexOf(_stage ?? SpeedStage.ping);
    return [
      for (final (i, st) in stages.indexed)
        if (i < now)
          1.0
        else if (i > now)
          0.0
        else if (st == SpeedStage.ping)
          _pingTotal == 0 ? 0.0 : _pingDone / _pingTotal
        else
          (_elapsed.inMilliseconds / 8000).clamp(0.0, 1.0).toDouble(),
    ];
  }

  Widget _legend(String label, String value, {required bool now, required bool done}) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final color = now ? scheme.onSurface : (done ? scheme.onSurfaceVariant : scheme.outline);
    return Expanded(
      child: Column(children: [
        Text(label, style: text.labelMedium?.copyWith(color: color), maxLines: 1, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 2),
        Text(value,
            textDirection: TextDirection.ltr,
            style: text.titleMedium?.copyWith(color: color, fontWeight: now ? FontWeight.w700 : FontWeight.w500)),
      ]),
    );
  }

  Widget _runningView() {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final stage = _stage ?? SpeedStage.ping;
    final r = _result;
    final stages = [SpeedStage.ping, SpeedStage.download, if (_server.canUpload) SpeedStage.upload];
    final color = _stageColor(stage);
    final (title, value, unit) = switch (stage) {
      SpeedStage.ping => (
          tr(context, 'speedPing'),
          _pingLast < 0 ? '…' : '$_pingLast',
          'ms · ${ltr('$_pingDone / $_pingTotal')}',
        ),
      SpeedStage.download => ('↓ ${tr(context, 'speedDownload')}', _mbps(_live), 'Mbps · ${ltr('${_elapsed.inSeconds} s')}'),
      SpeedStage.upload => ('↑ ${tr(context, 'speedUpload')}', _mbps(_live), 'Mbps · ${ltr('${_elapsed.inSeconds} s')}'),
    };
    final size = math.min(MediaQuery.sizeOf(context).width - 64, 280.0);
    return Column(children: [
      const SizedBox(height: 8),
      SizedBox(
        width: size,
        height: size,
        child: Stack(alignment: Alignment.center, children: [
          TweenAnimationBuilder<List<double>>(
            tween: _ListTween(end: _progress()),
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOut,
            builder: (context, parts, _) => CustomPaint(
              size: Size.square(size),
              painter: _RingPainter(
                parts: parts,
                colors: [for (final st in stages) _stageColor(st)],
                track: scheme.surfaceContainerHighest,
              ),
            ),
          ),
          Container(
            width: size * 0.66,
            height: size * 0.66,
            decoration: BoxDecoration(shape: BoxShape.circle, color: scheme.surfaceContainerLow),
            child: Semantics(
              liveRegion: false,
              label: '$title $value $unit',
              excludeSemantics: true,
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Text(title, style: text.labelLarge?.copyWith(color: color), maxLines: 1, overflow: TextOverflow.ellipsis),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(value,
                      textDirection: TextDirection.ltr,
                      style: text.displayMedium?.copyWith(fontWeight: FontWeight.w700, color: scheme.onSurface, height: 1.1)),
                ),
                Text(unit, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ]),
            ),
          ),
        ]),
      ),
      const SizedBox(height: 16),
      Row(children: [
        _legend(tr(context, 'speedPing'), r?.pingMs == null ? (stage == SpeedStage.ping && _pingLast >= 0 ? '$_pingLast ms' : '—') : '${r!.pingMs} ms',
            now: stage == SpeedStage.ping, done: r?.pingMs != null),
        _legend(tr(context, 'speedDownload'),
            stage == SpeedStage.download ? _mbps(_live) : _mbps(r?.downMbps),
            now: stage == SpeedStage.download, done: r?.downMbps != null),
        if (_server.canUpload)
          _legend(tr(context, 'speedUpload'), stage == SpeedStage.upload ? _mbps(_live) : _mbps(r?.upMbps),
              now: stage == SpeedStage.upload, done: r?.upMbps != null),
      ]),
      const SizedBox(height: 20),
      IconButton.outlined(
        tooltip: tr(context, 'speedStop'),
        style: IconButton.styleFrom(
          foregroundColor: scheme.error,
          side: BorderSide(color: scheme.error.withValues(alpha: 0.6)),
          minimumSize: const Size(52, 52),
        ),
        onPressed: _cancel ? null : () => setState(() => _cancel = true),
        icon: const Icon(Icons.stop_rounded),
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

/// Tweens a list of numbers one by one (the parts of the ring), from wherever they were.
class _ListTween extends Tween<List<double>> {
  _ListTween({required List<double> end}) : super(begin: end, end: end);

  @override
  List<double> lerp(double t) {
    final a = begin ?? end!;
    final b = end!;
    return [for (var i = 0; i < b.length; i++) (i < a.length ? a[i] : 0.0) + (b[i] - (i < a.length ? a[i] : 0.0)) * t];
  }
}

/// A ring in as many parts as there are stages, with a small gap between them: a part that is done is full,
/// the one running fills, the next ones are only their track.
class _RingPainter extends CustomPainter {
  _RingPainter({required this.parts, required this.colors, required this.track});

  final List<double> parts;
  final List<Color> colors;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final n = parts.length;
    if (n == 0) return;
    final stroke = size.width * 0.06;
    final rect = Rect.fromCircle(center: size.center(Offset.zero), radius: size.width / 2 - stroke / 2 - 2);
    // The gap, in radians, plus what the round ends take.
    final gap = 0.09 + stroke / rect.width;
    final sweep = (2 * math.pi - n * gap) / n;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < n; i++) {
      final start = -math.pi / 2 + gap / 2 + i * (sweep + gap);
      canvas.drawArc(rect, start, sweep, false, paint..color = track);
      final f = parts[i].clamp(0.0, 1.0).toDouble();
      if (f > 0.005) canvas.drawArc(rect, start, sweep * f, false, paint..color = colors[i % colors.length]);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) => true;
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
