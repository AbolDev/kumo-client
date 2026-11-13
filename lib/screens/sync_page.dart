import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:qr_flutter/qr_flutter.dart';

import '../core/device_sync.dart';
import '../core/platform.dart';
import '../l10n/extra.dart';
import '../state/app_state.dart';
import 'scan_page.dart';

/// Settings > Sync devices (see device_sync.dart for how the data goes and why it is safe).
///
/// One device shows a code and listens; the other scans it (or types it where there is no camera). Which way the
/// data goes is the choice of the one that shows the code. What comes in is never applied without a question that
/// says what it holds, and by default it is only added to what the device has.
class SyncPage extends StatefulWidget {
  const SyncPage({super.key, required this.state, this.bind, this.allowLoopback = false, this.camera, this.scan});

  final AppState state;

  /// For the tests: the address to listen on, and that a loopback address is a local one.
  final String? bind;
  final bool allowLoopback;

  /// Whether there is a camera to scan with (a computer has none; the tests set it).
  final bool? camera;

  /// What scans a code (the camera page, unless a test gives another).
  final Future<String?> Function()? scan;

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  AppState get state => widget.state;

  var _settings = false;
  SyncServer? _server;
  SyncCode? _code;
  SyncPhase _phase = SyncPhase.waiting;
  DateTime? _until;
  Timer? _tick;
  String? _busy;

  @override
  void dispose() {
    _tick?.cancel();
    unawaited(_server?.stop());
    super.dispose();
  }

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _stopServer() async {
    _tick?.cancel();
    final s = _server;
    _server = null;
    _code = null;
    await s?.stop();
  }

  Future<void> _show(SyncMode mode) async {
    await _stopServer();
    final String? payload = mode == SyncMode.send ? await state.syncPayload(settings: _settings) : null;
    if (!mounted) return;
    final server = SyncServer(
      mode: mode,
      payload: payload,
      bind: widget.bind,
      allowLoopback: widget.allowLoopback,
      onReceived: (text) {
        // The data of the other device is held here until the user has seen what it is.
        if (mounted) WidgetsBinding.instance.addPostFrameCallback((_) => _askApply(text));
      },
    );
    final code = await server.start();
    if (!mounted) {
      await server.stop();
      return;
    }
    if (code == null) {
      _say(tr(context, 'syncNoNetwork'));
      return;
    }
    server.phase.addListener(() {
      if (mounted) setState(() => _phase = server.phase.value);
    });
    setState(() {
      _server = server;
      _code = code;
      _phase = SyncPhase.waiting;
      _until = DateTime.now().add(server.ttl);
    });
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  String get _left {
    final until = _until;
    if (until == null) return '';
    final s = until.difference(DateTime.now()).inSeconds.clamp(0, 99999);
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  /// A code that was scanned or typed.
  Future<void> _handleCode(String raw) async {
    final code = SyncCode.parse(raw, allowLoopback: widget.allowLoopback);
    if (code == null) {
      _say(tr(context, 'syncInvalid'));
      return;
    }
    if (code.mode == SyncMode.send) {
      // The device that shows the code gives its data: this one takes it, after the question.
      if (!await _confirm('syncConfirmReceiveTitle', 'syncConfirmReceiveBody', 'syncContinue', code.host)) return;
      if (!mounted) return;
      setState(() => _busy = tr(context, 'syncFetching'));
      final text = await syncFetch(code);
      if (!mounted) return;
      setState(() => _busy = null);
      if (text == null) {
        _say(tr(context, 'syncFetchFail'));
        return;
      }
      await _askApply(text);
    } else {
      // The device that shows the code wants data: this one gives its own, after the question.
      if (!await _confirm('syncConfirmSendTitle', 'syncConfirmSendBody', 'syncSendButton', code.host)) return;
      if (!mounted) return;
      setState(() => _busy = tr(context, 'syncPushing'));
      final payload = await state.syncPayload(settings: _settings);
      final ok = await syncPush(code, payload);
      if (!mounted) return;
      setState(() => _busy = null);
      _say(tr(context, ok ? 'syncPushed' : 'syncPushFail'));
    }
  }

  Future<bool> _confirm(String title, String body, String yes, String host) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(tr(d, title, {'host': host})),
        content: Text(tr(d, body)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(MaterialLocalizations.of(d).cancelButtonLabel)),
          FilledButton(key: const ValueKey('sync-confirm'), onPressed: () => Navigator.pop(d, true), child: Text(tr(d, yes))),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _scan() async {
    final value = widget.scan != null
        ? await widget.scan!()
        : await Navigator.push<String>(context, MaterialPageRoute(settings: const RouteSettings(name: '/ScanPage'), builder: (_) => const ScanPage()));
    if (value != null && mounted) await _handleCode(value);
  }

  Future<void> _enter() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(tr(d, 'syncEnter')),
        content: TextField(
          key: const ValueKey('sync-code-field'),
          controller: controller,
          autofocus: true,
          minLines: 2,
          maxLines: 4,
          textDirection: TextDirection.ltr,
          decoration: InputDecoration(hintText: tr(d, 'syncEnterHint'), border: const OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: Text(MaterialLocalizations.of(d).cancelButtonLabel)),
          FilledButton(
              key: const ValueKey('sync-code-ok'),
              onPressed: () => Navigator.pop(d, controller.text),
              child: Text(tr(d, 'syncContinue'))),
        ],
      ),
    );
    // Not disposed here: the field is still on the screen while the dialog closes.
    if (text != null && text.trim().isNotEmpty && mounted) await _handleCode(text);
  }

  /// What came from the other device: what it holds is told first, and nothing is changed until the user says so.
  Future<void> _askApply(String text) async {
    if (!mounted) return;
    final preview = previewSyncPayload(text);
    if (preview == null || preview.isEmpty) {
      _say(tr(context, 'syncPreviewEmpty'));
      return;
    }
    var replace = false;
    var withSettings = false;
    final go = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, setDialog) => AlertDialog(
          title: Text(tr(d, 'syncPreviewTitle')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr(d, 'syncPreviewBody', {'servers': preview.servers + preview.cleanIps, 'subs': preview.subscriptions.length}) +
                      (preview.hasSettings ? ' ${tr(d, 'syncPreviewSettings')}' : ''),
                  key: const ValueKey('sync-preview'),
                ),
                if (preview.subscriptions.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(preview.subscriptions.take(5).join(', '), style: Theme.of(d).textTheme.bodySmall, maxLines: 3, overflow: TextOverflow.ellipsis),
                ],
                const SizedBox(height: 12),
                RadioListTile<bool>(
                  key: const ValueKey('sync-add'),
                  contentPadding: EdgeInsets.zero,
                  value: false,
                  groupValue: replace,
                  onChanged: (v) => setDialog(() => replace = v!),
                  title: Text(tr(d, 'syncAdd')),
                  subtitle: Text(tr(d, 'syncAddDesc')),
                ),
                RadioListTile<bool>(
                  key: const ValueKey('sync-replace'),
                  contentPadding: EdgeInsets.zero,
                  value: true,
                  groupValue: replace,
                  onChanged: (v) => setDialog(() => replace = v!),
                  title: Text(tr(d, 'syncReplace')),
                  subtitle: Text(tr(d, 'syncReplaceDesc')),
                ),
                if (preview.hasSettings)
                  CheckboxListTile(
                    key: const ValueKey('sync-take-settings'),
                    contentPadding: EdgeInsets.zero,
                    value: withSettings,
                    onChanged: (v) => setDialog(() => withSettings = v ?? false),
                    title: Text(tr(d, 'syncTakeSettings')),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: Text(MaterialLocalizations.of(d).cancelButtonLabel)),
            FilledButton(key: const ValueKey('sync-apply'), onPressed: () => Navigator.pop(d, true), child: Text(tr(d, 'syncApply'))),
          ],
        ),
      ),
    );
    if (go != true || !mounted) return;
    final done = await state.applySync(text, replace: replace, settings: withSettings);
    if (!mounted) return;
    if (done == null) {
      _say(tr(context, 'syncApplyFail'));
    } else if (replace) {
      _say(tr(context, 'syncAppliedReplace'));
    } else {
      _say(tr(context, 'syncApplied', {'servers': done.servers, 'subs': done.subscriptions}));
    }
  }

  Widget _codeCard() {
    final code = _code!;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final sends = code.mode == SyncMode.send;
    return Card(
      key: const ValueKey('sync-code-card'),
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_phase == SyncPhase.waiting) ...[
              Center(
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                  child: QrImageView(key: const ValueKey('sync-qr'), data: code.text, size: 220, backgroundColor: Colors.white),
                ),
              ),
              const SizedBox(height: 12),
              Text(tr(context, 'syncWaiting'), textAlign: TextAlign.center, style: text.titleMedium),
              const SizedBox(height: 4),
              Text(tr(context, sends ? 'syncWaitingSend' : 'syncWaitingReceive'),
                  textAlign: TextAlign.center, style: text.bodySmall?.copyWith(color: scheme.outline)),
              const SizedBox(height: 4),
              Text(tr(context, 'syncTimeLeft', {'t': _left}), key: const ValueKey('sync-left'), textAlign: TextAlign.center, style: text.bodySmall),
            ] else ...[
              Icon(_phase == SyncPhase.done ? Icons.check_circle_outline : Icons.timer_off_outlined,
                  size: 48, color: _phase == SyncPhase.done ? Colors.green : scheme.error),
              const SizedBox(height: 8),
              Text(
                _phase == SyncPhase.done ? tr(context, sends ? 'syncDoneSent' : 'syncDoneReceived') : tr(context, 'syncFailed'),
                key: ValueKey('sync-${_phase.name}'),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              if (_phase == SyncPhase.waiting)
                TextButton.icon(
                  key: const ValueKey('sync-copy'),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: code.text));
                    _say(tr(context, 'syncCopied'));
                  },
                  icon: const Icon(Icons.copy),
                  label: Text(tr(context, 'syncCopy')),
                ),
              TextButton(
                key: const ValueKey('sync-cancel'),
                onPressed: () async {
                  await _stopServer();
                  if (mounted) setState(() {});
                },
                child: Text(_phase == SyncPhase.waiting
                    ? MaterialLocalizations.of(context).cancelButtonLabel
                    : MaterialLocalizations.of(context).closeButtonLabel),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final camera = widget.camera ?? !isDesktop;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'syncTitle'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text(tr(context, 'syncDesc'), style: text.bodyMedium),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.lock_outline, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(tr(context, 'syncSecurity'), key: const ValueKey('sync-security'), style: text.bodySmall)),
            ]),
          ),
          const SizedBox(height: 12),
          if (_code != null) _codeCard(),
          if (_busy != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(children: [
                const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5)),
                const SizedBox(width: 12),
                Expanded(child: Text(_busy!)),
              ]),
            ),
          SwitchListTile(
            key: const ValueKey('sync-settings'),
            contentPadding: EdgeInsets.zero,
            value: _settings,
            onChanged: (v) => setState(() => _settings = v),
            title: Text(tr(context, 'syncSettings')),
            subtitle: Text(tr(context, 'syncSettingsDesc')),
          ),
          const Divider(),
          ListTile(
            key: const ValueKey('sync-send'),
            leading: const Icon(Icons.upload_outlined),
            title: Text(tr(context, 'syncSendTitle')),
            subtitle: Text(tr(context, 'syncSendDesc')),
            onTap: () => _show(SyncMode.send),
          ),
          ListTile(
            key: const ValueKey('sync-receive'),
            leading: const Icon(Icons.download_outlined),
            title: Text(tr(context, 'syncReceiveTitle')),
            subtitle: Text(tr(context, 'syncReceiveDesc')),
            onTap: () => _show(SyncMode.receive),
          ),
          if (camera)
            ListTile(
              key: const ValueKey('sync-scan'),
              leading: const Icon(Icons.qr_code_scanner),
              title: Text(tr(context, 'syncScan')),
              subtitle: Text(tr(context, 'syncScanDesc')),
              onTap: _scan,
            ),
          ListTile(
            key: const ValueKey('sync-enter'),
            leading: const Icon(Icons.keyboard_outlined),
            title: Text(tr(context, 'syncEnter')),
            onTap: _enter,
          ),
        ],
      ),
    );
  }
}
