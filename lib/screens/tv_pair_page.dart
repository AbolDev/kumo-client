import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/tv_pair.dart';
import '../l10n/extra.dart';
import '../widgets/kumo_mark.dart';

/// Add servers to a television from a phone: a code and an address to open on the phone, which has a box to
/// paste a link or a subscription into. Each text that comes is handed to [onText] (which adds it and asks
/// the user what the adding needs).
class TvPairPage extends StatefulWidget {
  const TvPairPage({super.key, required this.onText, this.server});

  final Future<void> Function(BuildContext context, String text) onText;

  /// The server to use (a test gives its own); by default a new one.
  final TvPairServer? server;

  @override
  State<TvPairPage> createState() => _TvPairPageState();
}

class _TvPairPageState extends State<TvPairPage> {
  late final TvPairServer _server = widget.server ?? TvPairServer();
  String? _url;
  var _loading = true;
  var _received = 0;

  /// The texts that came while another was being added: one dialog at a time.
  final _queue = <String>[];
  var _busy = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    String? url;
    try {
      url = await _server.start((text) {
        if (!mounted) return;
        setState(() => _received++);
        _queue.add(text);
        _drain();
      });
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _url = url;
      _loading = false;
    });
  }

  Future<void> _drain() async {
    if (_busy) return;
    _busy = true;
    try {
      while (_queue.isNotEmpty && mounted) {
        await widget.onText(context, _queue.removeAt(0));
      }
    } finally {
      _busy = false;
    }
  }

  @override
  void dispose() {
    // The address stops answering the moment the page is left.
    unawaited(_server.stop());
    super.dispose();
  }

  Widget _step(BuildContext context, int n, String key) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        CircleAvatar(
          radius: 16,
          backgroundColor: scheme.primaryContainer,
          child: Text('$n', style: TextStyle(color: scheme.onPrimaryContainer, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: 14),
        Expanded(child: Text(tr(context, key), style: Theme.of(context).textTheme.titleMedium)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final url = _url;
    final qr = Container(
      width: 280,
      height: 280,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(28)),
      child: url == null
          ? Center(child: _loading ? const CircularProgressIndicator() : const Icon(Icons.wifi_off, size: 56))
          : Stack(alignment: Alignment.center, children: [
              QrImageView(
                key: ValueKey('pair-qr:$url'),
                data: url,
                padding: EdgeInsets.zero,
                backgroundColor: Colors.white,
                errorCorrectionLevel: QrErrorCorrectLevel.M,
                eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.circle, color: Color(0xFF04302C)),
                dataModuleStyle:
                    const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.circle, color: Color(0xFF0B5A52)),
              ),
              Container(
                width: 44,
                height: 44,
                decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                alignment: Alignment.center,
                child: const KumoMark(size: 26),
              ),
            ]),
    );
    final steps = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(tr(context, 'tvPairTitle'), style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      _step(context, 1, 'tvPairStep1'),
      _step(context, 2, 'tvPairStep2'),
      _step(context, 3, 'tvPairStep3'),
      const SizedBox(height: 12),
      if (url != null)
        SelectableText(url,
            key: const ValueKey('pair-url'),
            textDirection: TextDirection.ltr,
            style: text.titleMedium?.copyWith(color: scheme.primary, fontWeight: FontWeight.w600))
      else if (!_loading)
        Text(tr(context, 'tvPairNoNet'), style: TextStyle(color: scheme.error)),
      const SizedBox(height: 16),
      Row(mainAxisSize: MainAxisSize.min, children: [
        if (url != null && _received == 0)
          const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.5))
        else if (_received > 0)
          Icon(Icons.check_circle, color: Colors.green.shade600),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            _received == 0 ? tr(context, 'tvPairWaiting') : tr(context, 'tvPairGot', {'n': _received}),
            style: text.titleSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ]),
    ]);
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'tvPairTitle'))),
      body: LayoutBuilder(
        builder: (context, box) => Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: box.maxWidth >= 720
                ? Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.center, children: [
                    qr,
                    const SizedBox(width: 40),
                    Flexible(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520), child: steps)),
                  ])
                : Column(mainAxisSize: MainAxisSize.min, children: [qr, const SizedBox(height: 24), steps]),
          ),
        ),
      ),
    );
  }
}
