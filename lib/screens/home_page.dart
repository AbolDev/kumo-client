import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' show Random, cos, pi, sin;
import 'dart:ui' show ImageFilter;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';

import 'package:window_manager/window_manager.dart';

import '../core/qr_decode.dart';
import '../core/sources.dart' show SubInfo;
import '../core/config_decryptor.dart';
import '../core/proxy_config.dart';
import '../core/sub_formats.dart';
import '../core/vpn_channel.dart';
import '../l10n/extra.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../widgets/flag_name.dart';
import 'free_connections_page.dart';
import 'warp_page.dart';
import 'edit_config_page.dart';
import '../core/platform.dart';
import 'scan_page.dart';
import 'settings_page.dart';
import 'region_picker.dart';
import 'service_test_page.dart';
import 'my_ip_page.dart';
import 'dns_leak_page.dart';
import 'troubleshoot_page.dart';
import 'share_sheet.dart';
import 'collector_info_page.dart';
import 'subscription_info_page.dart';

String _bytes(int b) {
  if (b >= 1 << 40) return '${(b / (1 << 40)).toStringAsFixed(2)} TB';
  if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
  if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
  if (b >= 1 << 10) return '${(b / (1 << 10)).toStringAsFixed(0)} KB';
  return '$b B';
}

/// Live speed with one decimal, e.g. "1.2 MB/s".
String _rate(int b) {
  if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(1)} GB/s';
  if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB/s';
  return '${(b / (1 << 10)).toStringAsFixed(1)} KB/s';
}

Color _latencyColor(int ms) =>
    ms < 300 ? Colors.green : (ms < 800 ? Colors.orange : Colors.red);

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final t = S.of(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => Scaffold(
        // The tint of the connection card reaches up behind the title bar, with no seam.
        extendBodyBehindAppBar: Platform.isAndroid,
        appBar: AppBar(
          scrolledUnderElevation: 0,
          backgroundColor: Colors.transparent,
          title: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.cloud, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
            const Text('Kumo'),
          ]),
          actions: [
            PopupMenuButton<VoidCallback>(
              icon: const Icon(Icons.add),
              tooltip: t.add,
              onSelected: (action) => action(),
              itemBuilder: (menu) => [
                PopupMenuItem(
                  value: () => _addFromClipboard(context),
                  child: _MenuRow(Icons.content_paste, t.addFromClipboard),
                ),
                PopupMenuItem(
                  value: () => _addFromFile(context),
                  child: _MenuRow(Icons.file_open, t.addFromFile),
                ),
                if (Platform.isAndroid)
                  PopupMenuItem(
                    value: () => _scan(context),
                    child: _MenuRow(Icons.qr_code_scanner, t.scanQr),
                  ),
                if (Platform.isWindows) ...[
                  PopupMenuItem(
                    value: () => _qrFrom(context, 'screen'),
                    child: _MenuRow(Icons.screenshot_monitor, tr(context, 'importQrScreen')),
                  ),
                ],
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(builder: (_) => FreeConnectionsPage(state: state)),
                  ),
                  child: _MenuRow(Icons.volunteer_activism_outlined, tr(context, 'freeConnections')),
                ),
              ],
            ),
            PopupMenuButton<VoidCallback>(
              icon: const Icon(Icons.more_vert),
              onSelected: (action) => action(),
              itemBuilder: (menu) => [
                PopupMenuItem(
                  value: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(builder: (_) => MyIpPage(state: state)),
                  ),
                  child: _MenuRow(Icons.my_location, tr(context, 'menuMyIp')),
                ),
                PopupMenuItem(
                  value: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(builder: (_) => DnsLeakPage(state: state)),
                  ),
                  child: _MenuRow(Icons.dns_outlined, tr(context, 'menuDnsLeak')),
                ),
                PopupMenuItem(
                  value: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                        builder: (_) => ServiceTestPage(state: state)),
                  ),
                  child: _MenuRow(Icons.public, tr(context, 'menuServices')),
                ),
                PopupMenuItem(
                  value: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                        builder: (_) => TroubleshootPage(state: state)),
                  ),
                  child: _MenuRow(Icons.help_outline, tr(context, 'menuTroubleshoot')),
                ),
                const PopupMenuDivider(),
                PopupMenuItem(
                  enabled: state.connected,
                  value: state.reconnectIfConnected,
                  child: _MenuRow(Icons.restart_alt, tr(context, 'menuRestart')),
                ),
                if (state.anyTesting)
                  PopupMenuItem(
                    value: () async {
                      final remove = await _askUntested(context);
                      if (remove != null) state.cancelAllPings(removeUntested: remove);
                    },
                    child: _MenuRow(Icons.stop_circle_outlined, tr(context, 'cancelTest')),
                  ),
                PopupMenuItem(
                  value: () => state.pingAll(real: false),
                  child: _MenuRow(Icons.network_check, tr(context, 'menuTcpingAll')),
                ),
                PopupMenuItem(
                  enabled: state.canTestReal,
                  value: () => state.pingAll(real: true),
                  child: _MenuRow(Icons.speed, tr(context, 'menuRealDelayAll')),
                ),
                PopupMenuItem(
                  value: state.clearTestResults,
                  child: _MenuRow(Icons.cleaning_services_outlined, tr(context, 'menuClearResults')),
                ),
                PopupMenuItem(
                  enabled: state.subscriptions.isNotEmpty,
                  value: state.updateAllSubscriptions,
                  child: _MenuRow(Icons.sync, tr(context, 'menuUpdateSubs')),
                ),
              ],
            ),
            IconButton(
              tooltip: t.settings,
              icon: const Icon(Icons.settings),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                    builder: (_) => SettingsPage(state: state)),
              ),
            ),
            if (Platform.isWindows) const SizedBox(width: 12),
          ],
        ),
        body: _withDrop(context, LayoutBuilder(builder: (context, box) {
          // A wide desktop window puts the controls beside the server list.
          if (isDesktop && box.maxWidth >= 760) {
            final scheme = Theme.of(context).colorScheme;
            final count = state.groups.fold<int>(0, (n, g) => n + g.configs.length);
            return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(
                width: 380,
                margin: const EdgeInsets.fromLTRB(12, 4, 6, 12),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: SingleChildScrollView(child: _ConnectCard(state: state)),
              ),
              Expanded(
                // The list sits on a panel of its own, like the connect card: a soft tint that
                // fades across it and two faint glows in the corners.
                child: Container(
                  margin: const EdgeInsets.fromLTRB(6, 4, 12, 12),
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: scheme.outlineVariant),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color.alphaBlend(scheme.primary.withValues(alpha: 0.07), scheme.surfaceContainerLow),
                        scheme.surfaceContainerLow,
                        Color.alphaBlend(scheme.tertiary.withValues(alpha: 0.06), scheme.surfaceContainerLow),
                      ],
                    ),
                  ),
                  child: CustomPaint(
                    painter: _PanelGlowPainter(primary: scheme.primary, tertiary: scheme.tertiary),
                    child: Column(children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 14, 18, 4),
                        child: Row(children: [
                          Icon(Icons.dns_outlined, size: 20, color: scheme.primary),
                          const SizedBox(width: 8),
                          Text('${tr(context, 'servers')} ($count)',
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                        ]),
                      ),
                      Expanded(child: _ServerList(state: state)),
                    ]),
                  ),
                ),
              ),
            ]);
          }
          return Column(children: [
            _ConnectCard(state: state),
            Expanded(child: _ServerList(state: state)),
          ]);
        })),
      ),
    );
  }

  /// Windows: files and pictures dropped on the window are added like the Add menu does.
  Widget _withDrop(BuildContext context, Widget child) {
    if (!isDesktop) return child;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyV, control: true): () => _addFromClipboard(context),
      },
      child: Focus(autofocus: true, child: _dropTarget(context, child)),
    );
  }

  Widget _dropTarget(BuildContext context, Widget child) {
    return DropTarget(
      onDragDone: (d) async {
        for (final f in d.files) {
          final bytes = await f.readAsBytes();
          if (!context.mounted) return;
          await _importDropped(context, f.path, bytes);
        }
      },
      child: child,
    );
  }

  Future<void> _importDropped(
      BuildContext context, String path, Uint8List bytes) async {
    final name = path.split(RegExp(r'[\\\\/]')).last;
    final lower = name.toLowerCase();
    const pictures = ['.png', '.jpg', '.jpeg', '.bmp', '.gif', '.webp'];
    if (pictures.any(lower.endsWith)) {
      final text = await decodeQr(bytes);
      if (!context.mounted) return;
      if (text == null) {
        toast(context, tr(context, 'qrNotFound'));
        return;
      }
      await _import(context, text);
      return;
    }
    await _importFile(context, name, bytes);
  }

  /// Adds [text]; a subscription whose provider gave no name gets one from the user.
  Future<void> _import(BuildContext context, String text) async {
    final group = await state.importText(text);
    if (group == null || !context.mounted) return;
    // The name the provider or the link gave is filled in; with none, the field is empty (the
    // address is not shown as a hint).
    final found = group.name == Uri.tryParse(group.url ?? '')?.host ? '' : group.name;
    final controller = TextEditingController(text: found)
      ..selection = TextSelection(baseOffset: 0, extentOffset: found.length);
    final name = await showDialog<String>(
      context: context,
      builder: (dialog) {
        final t = S.of(dialog);
        return AlertDialog(
          title: Text(t.nameSubscription),
          content: TextField(
            controller: controller,
            autofocus: true,
            onSubmitted: (v) => Navigator.pop(dialog, v),
            decoration: InputDecoration(
                labelText: t.subscriptionName,
                border: const OutlineInputBorder()),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialog), child: Text(t.later)),
            FilledButton(
                onPressed: () => Navigator.pop(dialog, controller.text),
                child: Text(t.save)),
          ],
        );
      },
    );
    controller.dispose();
    if (name != null) state.renameSubscription(group, name);
  }

  /// Windows: reads a QR code from a screenshot of the screen or an image on the clipboard
  /// (an image file goes through Add from file).
  Future<void> _qrFrom(BuildContext context, String source) async {
    Uint8List? bytes;
    if (source == 'screen') {
      // The window steps aside so the QR code on the screen is not covered by it.
      await windowManager.minimize();
      await Future<void>.delayed(const Duration(milliseconds: 900));
      bytes = await captureScreen();
      await windowManager.restore();
      await windowManager.focus();
      if (bytes != null && context.mounted) {
        // The screenshot fills the screen; the user drags over the QR code to pick it.
        await windowManager.setFullScreen(true);
        try {
          if (context.mounted) bytes = await pickRegion(context, bytes);
        } finally {
          // Whatever happened in the picker, the window does not stay full screen.
          await windowManager.setFullScreen(false);
        }
        if (bytes == null) return;
      }
    }
    final text = bytes == null ? null : await decodeQr(bytes);
    if (!context.mounted) return;
    if (text == null) {
      toast(context, tr(context, 'qrNotFound'));
      return;
    }
    await _import(context, text);
  }

  Future<void> _addFromClipboard(BuildContext context) async {
    final t = S.of(context);
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clip?.text?.trim() ?? '';
    final raw = Uint8List.fromList(utf8.encode(text));
    if (text.isNotEmpty && isProtectedFile('clipboard.txt', raw)) {
      if (context.mounted) {
        await _importProtected(context, raw, 'clipboard.txt');
      }
      return;
    }
    final usable = text.startsWith('http://') ||
        text.startsWith('https://') ||
        extractSubscriptionLinks(text).isNotEmpty;
    if (!usable) {
      // No usable text: on Windows the clipboard may hold a picture of a QR code.
      if (Platform.isWindows && text.isEmpty) {
        final image = await clipboardImage();
        final qr = image == null ? null : await decodeQr(image);
        if (!context.mounted) return;
        if (qr != null) {
          await _import(context, qr);
          return;
        }
        if (image != null) {
          toast(context, tr(context, 'qrNotFound'));
          return;
        }
      }
      if (context.mounted) toast(context, t.clipboardEmpty);
      return;
    }
    if (!context.mounted) return;
    await _import(context, text);
  }

  /// Reads a text file (share links, a base64 list or a subscription URL) or an image holding a QR
  /// code, and adds it.
  /// Password-protected exports (.slip, .npvs, .zsx ...) ask for the user's password first.
  Future<void> _addFromFile(BuildContext context) async {
    final picked = await FilePicker.platform.pickFiles(withData: true);
    final file = picked?.files.single;
    final bytes = file?.bytes;
    if (file == null || bytes == null || !context.mounted) return;
    await _importDropped(context, file.name, bytes);
  }

  Future<void> _importFile(
      BuildContext context, String name, Uint8List bytes) async {
    if (!isProtectedFile(name, bytes)) {
      await _import(context, utf8.decode(bytes, allowMalformed: true));
      return;
    }
    if (!context.mounted) return;
    await _importProtected(context, bytes, name);
  }

  /// Opens an encrypted export (from a file or the clipboard), asking for a password only if needed.
  Future<void> _importProtected(
      BuildContext context, Uint8List bytes, String name) async {
    final t = S.of(context);
    // Only ask for a password when the file really is locked with one.
    final kind = inspectProtected(bytes, name);
    if (kind == ProtectKind.unsupported) {
      toast(context, t.unsupportedFile);
      return;
    }
    var password = '';
    if (kind == ProtectKind.password) {
      final entered = await _askPassword(context);
      if (entered == null) return;
      password = entered;
    }
    try {
      final tables = await _loadTables();
      final text = await compute(_decrypt, (bytes, name, password, tables));
      if (!context.mounted) return;
      await _import(context, text);
    } catch (e) {
      // The raw error is for the log; the screen gets a plain sentence.
      state.log('Could not open $name: $e');
      if (context.mounted) toast(context, tr(context, 'decryptFailed'));
    }
  }

  Future<NpvTables> _loadTables() async {
    Future<Uint8List> load(String n) async =>
        (await rootBundle.load('assets/npvs/$n')).buffer.asUint8List();
    return NpvTables(
        await load('tyboxes.bin'),
        await load('mbl.bin'),
        await load('tboxes_last.bin'),
        await load('tboxes_last_v2.bin'),
        await load('xor.bin'),
        gen2Z: await load('gen2_tables.bin.z'),
        crypt5Json: await load('crypt5-keys.json'));
  }

  Future<String?> _askPassword(BuildContext context) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialog) {
        final t = S.of(dialog);
        return AlertDialog(
          title: Text(t.password),
          content: TextField(
            controller: controller,
            obscureText: true,
            autofocus: true,
            onSubmitted: (v) => Navigator.pop(dialog, v),
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialog), child: Text(t.cancel)),
            FilledButton(
                onPressed: () => Navigator.pop(dialog, controller.text),
                child: Text(t.ok)),
          ],
        );
      },
    ).whenComplete(controller.dispose);
  }

  Future<void> _scan(BuildContext context) async {
    final value = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const ScanPage()),
    );
    if (value != null && context.mounted) await _import(context, value);
  }
}

String _decrypt((Uint8List, String, String, NpvTables?) a) =>
    decryptProtected(a.$1, a.$2, a.$3, tables: a.$4);

/// Asks before something is deleted, unless confirmation is turned off in Settings.
Future<bool> confirmDeletion(BuildContext context, AppState state) async {
  if (!state.confirmDelete) return true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialog) {
      final t = S.of(dialog);
      return AlertDialog(
        title: Text(t.deleteQuestion),
        content: Text(t.deleteWarning),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text(t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(t.delete)),
        ],
      );
    },
  );
  return ok == true;
}

/// "12 days left · 3.2 GB of 50 GB used"; unlimited parts say so.
String subscriptionLine(S t, SubInfo info) {
  String time;
  if (info.unlimitedTime) {
    time = t.unlimitedTime;
  } else {
    final left = DateTime.fromMillisecondsSinceEpoch(info.expire * 1000)
        .difference(DateTime.now());
    if (left.inMinutes <= 0) {
      time = t.expired;
    } else if (left.inDays >= 1) {
      time = t.daysLeft(left.inDays);
    } else if (left.inHours >= 1) {
      time = t.hoursLeft(left.inHours);
    } else {
      time = t.minutesLeft(left.inMinutes);
    }
  }
  final String data;
  if (info.unlimitedData) {
    data = info.used > 0
        ? '${t.usedUnlimited(_bytes(info.used))} · ${t.unlimitedData}'
        : t.unlimitedData;
  } else {
    data = t.usedOf(_bytes(info.used), _bytes(info.total));
  }
  return '$time · $data';
}

class _MenuRow extends StatelessWidget {
  const _MenuRow(this.icon, this.label);

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(children: [
        Icon(icon),
        const SizedBox(width: 12),
        Flexible(child: Text(label))
      ]);
}

class _ConnectCard extends StatelessWidget {
  const _ConnectCard({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final t = S.of(context);
    final scheme = Theme.of(context).colorScheme;
    final status = state.vpn.status;
    final (label, color) = switch (status) {
      VpnStatus.started => (t.connected, Colors.green),
      VpnStatus.starting => (t.connecting, Colors.orange),
      VpnStatus.stopping => (t.disconnecting, Colors.orange),
      VpnStatus.error => (t.connectionError, scheme.error),
      VpnStatus.stopped => (t.disconnected, scheme.outline),
    };
    final selected = state.selected;
    // A picked server shows its own ping; automatic mode shows the one it would use.
    final shown = selected ?? state.autoPick;
    final serverLabel = shown?.name ?? t.autoFastest;
    final ping = state.connected && state.liveDelay != null
        ? state.liveDelay
        : shown?.latencyMs;

    // Idle is not grey: the app's own colour tints the card, as the green does when connected.
    final accent = status == VpnStatus.stopped ? scheme.primary : color;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [accent.withValues(alpha: 0.16), accent.withValues(alpha: 0)],
        ),
      ),
      child: Padding(
      padding: EdgeInsets.fromLTRB(16,
          isDesktop ? 100 : MediaQuery.paddingOf(context).top + kToolbarHeight + 8, 16, 12),
      child: Column(
        children: [
          _PowerButton(
              color: accent,
              busy: state.transitioning,
              on: status == VpnStatus.started,
              onTap: status == VpnStatus.stopping ? null : state.toggle),
          SizedBox(height: isDesktop ? 10 : 22),
          // The status sits on a frosted-glass pill: what is behind it (the rings) is blurred.
          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 3, sigmaY: 3),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  color: color.withValues(alpha: 0.06),
                  border: Border.all(color: color.withValues(alpha: 0.28)),
                ),
                // A screen reader says it again whenever the state changes (connecting, connected ...).
                child: Semantics(
                  container: true,
                  liveRegion: true,
                  label: tr(context, 'a11yStatusLine', {'status': label}),
                  excludeSemantics: true,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: Text(label,
                        key: ValueKey(label),
                        style: Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.copyWith(color: color, fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
            ),
          ),
          if (!state.connected && state.standbyUp)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(tr(context, 'keepProxyUp', {'port': state.net.proxyPort}),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
            ),
          // Windows: a warning about a subscription that is running out (the phone uses a
          // notification instead).
          if (state.alertText != null)
            Semantics(
              liveRegion: true,
              child: Card(
                margin: const EdgeInsets.only(bottom: 8),
                color: scheme.tertiaryContainer,
                child: ListTile(
                  dense: true,
                  leading: const ExcludeSemantics(child: Icon(Icons.warning_amber)),
                  title: Text(state.alertText!),
                  trailing: IconButton(
                    tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                    icon: const Icon(Icons.close),
                    onPressed: state.dismissAlert,
                  ),
                ),
              ),
            ),
          const SizedBox(height: 8),
          Semantics(
            button: shown != null,
            hint: shown == null ? null : tr(context, 'a11yLocate'),
            child: GestureDetector(
            onTap: shown == null ? null : () => state.locate(shown),
            child: MouseRegion(
            cursor: shown == null ? MouseCursor.defer : SystemMouseCursors.click,
            child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                  color: state.connected
                      ? color.withValues(alpha: 0.6)
                      : accent.withValues(alpha: 0.35)),
            ),
            child: Column(children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: FlagName(
                        serverLabel,
                        key: ValueKey(serverLabel),
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  ),
                  if (ping != null) ...[
                    const SizedBox(width: 8),
                    _PingChip(ping: ping, t: t),
                  ],
                ],
              ),
              if (shown != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '${selected == null ? '${t.autoFastest} · ' : ''}'
                    '${ltr('${shown.label} · ${shown.maskedAddress}')}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                  ),
                ),
            ]),
          )))),
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: ValueListenableBuilder<Traffic>(
              valueListenable: state.traffic,
              builder: (context, tr, _) {
                final on = state.connected;
                return Row(
                  children: [
                    Expanded(
                        child: _TrafficBox(
                            icon: Icons.arrow_downward,
                            color: Colors.green,
                            label: t.downloadLabel,
                            active: on,
                            speed: on ? _rate(tr.down) : '-',
                            total: on ? _bytes(tr.downTotal) : '-')),
                    const SizedBox(width: 12),
                    Expanded(
                        child: _TrafficBox(
                            icon: Icons.arrow_upward,
                            color: Colors.blue,
                            label: t.uploadLabel,
                            active: on,
                            speed: on ? _rate(tr.up) : '-',
                            total: on ? _bytes(tr.upTotal) : '-')),
                  ],
                );
              },
            ),
          ),
          // On the desktop the tunnel switch sits here; on the phone it is in Settings.
          if (isDesktop)
            SwitchListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              value: state.net.tun,
              onChanged: state.transitioning
                  ? null
                  : (v) => state.updateNet((o) => o.tun = v),
              title: Text(tr(context, 'tunShort')),
              subtitle: Text(state.net.tun
                  ? tr(context, Platform.isWindows ? 'tunOnNote' : 'tunPasswordNote')
                  : tr(context, 'proxyNote', {'port': state.net.proxyPort})),
            ),
        ],
      ),
    ));
  }
}

/// The big round connect button: glows while connected and gives a little on press.
class _PowerButton extends StatefulWidget {
  const _PowerButton(
      {required this.color,
      required this.busy,
      required this.on,
      required this.onTap});

  final Color color;
  final bool busy;
  final bool on;
  final VoidCallback? onTap;

  @override
  State<_PowerButton> createState() => _PowerButtonState();
}

class _PowerButtonState extends State<_PowerButton> with SingleTickerProviderStateMixin {
  bool _down = false;
  bool _focused = false;

  // The time that moves the rings around the button, in seconds. It only runs while connected
  // (and only ticks when the app is in front); it carries on from where it stopped.
  final _time = ValueNotifier<double>(0);
  late final Ticker _ticker;
  double _base = 0;

  @override
  void initState() {
    super.initState();
    // The rings drift slowly, so thirty updates a second look the same as sixty and cost half.
    _ticker = createTicker((elapsed) {
      final t = _base + elapsed.inMicroseconds / 1e6;
      if (t - _time.value >= 1 / 31) _time.value = t;
    });
  }

  /// The system setting "remove animations" (also used by people who get dizzy from motion).
  bool get _still => MediaQuery.disableAnimationsOf(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_PowerButton old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final move = widget.on && !_still;
    if (move && !_ticker.isActive) {
      _ticker.start();
    } else if (!move && _ticker.isActive) {
      _ticker.stop();
      _base = _time.value;
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color;
    // A remote control (Android TV) or the keyboard moves focus here and presses with OK / Enter.
    return Focus(
      onFocusChange: (v) => setState(() => _focused = v),
      onKeyEvent: (_, event) {
        final key = event.logicalKey;
        if (event is KeyDownEvent &&
            (key == LogicalKeyboardKey.select ||
                key == LogicalKeyboardKey.enter ||
                key == LogicalKeyboardKey.numpadEnter ||
                key == LogicalKeyboardKey.space ||
                key == LogicalKeyboardKey.gameButtonA)) {
          widget.onTap?.call();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      // The rings are painted around the button without taking any room.
      child: SizedBox(
        width: 128,
        height: 128,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            Positioned(
              left: -176,
              top: -176,
              width: 480,
              height: 480,
              child: IgnorePointer(
                child: RepaintBoundary(
                  child: CustomPaint(
                      painter: _RingsPainter(
                          color: color, on: widget.on, time: _time, gap: isDesktop ? 14.3 : 27)),
                ),
              ),
            ),
            _button(color),
          ],
        ),
      ),
    );
  }

  Widget _button(Color color) {
    // A screen reader says what the button does, not only that it is a button.
    return Semantics(
      button: true,
      enabled: widget.onTap != null,
      label: tr(context, widget.on ? 'a11yDisconnect' : 'a11yConnect'),
      onTap: widget.onTap,
      excludeSemantics: true,
      child: _buttonBody(color),
    );
  }

  Widget _buttonBody(Color color) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? 0.94 : 1,
        duration: const Duration(milliseconds: 120),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
          width: 128,
          height: 128,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withValues(alpha: widget.on ? 0.22 : 0.12),
            border: Border.all(
                color: _focused ? Theme.of(context).colorScheme.onSurface : color,
                width: _focused ? 8 : 4),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: widget.on ? 0.35 : 0.18),
                blurRadius: widget.on ? 28 : 18,
                spreadRadius: widget.on ? 4 : 1,
              ),
            ]
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: ScaleTransition(scale: anim, child: child)),
            child: widget.busy
                ? Padding(
                    key: const ValueKey('busy'),
                    padding: const EdgeInsets.all(44),
                    child: CircularProgressIndicator(color: color))
                : Icon(Icons.power_settings_new,
                    key: const ValueKey('icon'), size: 60, color: color),
          ),
        ),
      ),
    );
  }
}

/// Two large, very faint glows in opposite corners of the desktop server panel.
class _PanelGlowPainter extends CustomPainter {
  const _PanelGlowPainter({required this.primary, required this.tertiary});

  final Color primary;
  final Color tertiary;

  @override
  void paint(Canvas canvas, Size size) {
    void glow(Offset center, double radius, Color color, double alpha) {
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(colors: [color.withValues(alpha: alpha), color.withValues(alpha: 0)])
              .createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }

    glow(Offset(size.width * 0.92, size.height * 0.04), size.shortestSide * 0.7, primary, 0.10);
    glow(Offset(size.width * 0.05, size.height * 0.98), size.shortestSide * 0.6, tertiary, 0.09);
  }

  @override
  bool shouldRepaint(_PanelGlowPainter old) => old.primary != primary || old.tertiary != tertiary;
}

/// Thin contour lines around the connect button, like ripples on water: the inner one is nearly
/// round and crisp, and each one further out is fainter and more wobbly. While connected the shapes
/// drift very slowly and unevenly (every wave of every line has its own random speed), so they
/// never repeat and never stand still. Disconnected, they rest, fainter.
class _RingsPainter extends CustomPainter {
  _RingsPainter(
      {required this.color, required this.on, required ValueListenable<double> time, required this.gap})
      : _time = time,
        super(repaint: time);

  final Color color;
  final bool on;
  final ValueListenable<double> _time;

  /// Pixels between two lines: the phone has the room for more than the desktop card.
  final double gap;

  static const _rings = 6;
  static const _waves = 4; // wobbles with 2, 3, 4 and 5 bumps around the circle

  // Random, but the same every time: where each wave starts and how slowly it drifts.
  static List<List<double>> _table(int seed, double lo, double hi) {
    final r = Random(seed);
    return [
      for (var i = 0; i < _rings; i++) [for (var j = 0; j < _waves; j++) lo + r.nextDouble() * (hi - lo)],
    ];
  }

  static final _phase = _table(11, 0, 2 * pi);
  static final _speed = _table(23, -0.55, 0.55); // radians per second, both directions

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final t = _time.value;
    final k = on ? 1.0 : 0.55;

    // a soft halo behind the lines
    canvas.drawCircle(
      c,
      180,
      Paint()
        ..shader = RadialGradient(colors: [
          color.withValues(alpha: 0.09 * k),
          color.withValues(alpha: 0),
        ]).createShader(Rect.fromCircle(center: c, radius: 180)),
    );

    final line = Paint()..style = PaintingStyle.stroke;
    for (var i = 0; i < _rings; i++) {
      final f = i / (_rings - 1); // 0 = the line next to the button, 1 = the outermost
      final base = 74.0 + gap * i;
      // the further out, the more it wobbles; the wobble itself swells and eases slowly
      // how far the line strays from a circle, in pixels: a little for the first, more further out
      final stray = (1.5 + 2.4 * i) * (0.75 + 0.25 * sin(t * 0.45 + i * 2.1));
      final breath = 1 + 0.014 * sin(t * 0.8 + i * 1.3);
      final path = Path();
      const steps = 96;
      for (var s = 0; s <= steps; s++) {
        final a = 2 * pi * s / steps;
        var n = 0.0;
        for (var j = 0; j < _waves; j++) {
          n += sin((j + 2) * a + _phase[i][j] + _speed[i][j] * t) / (j + 1.5);
        }
        final r = base * breath + stray * n;
        final x = c.dx + r * cos(a);
        final y = c.dy + r * sin(a);
        s == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      path.close();
      line
        ..strokeWidth = i == 0 ? 1.5 : 0.9
        ..color = color.withValues(alpha: (i == 0 ? 0.44 : 0.34 * (1 - 0.8 * f) + 0.05) * k);
      canvas.drawPath(path, line);
    }
  }

  @override
  bool shouldRepaint(_RingsPainter old) => old.color != color || old.on != on;
}
class _PingChip extends StatelessWidget {
  const _PingChip({required this.ping, required this.t});

  final int ping;
  final S t;

  @override
  Widget build(BuildContext context) {
    final color = ping < 0 ? Colors.red : _latencyColor(ping);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(ping < 0 ? t.timeout : '$ping ms',
          style: TextStyle(
              color: color, fontWeight: FontWeight.w600, fontSize: 12)),
    );
  }
}

class _TrafficBox extends StatelessWidget {
  const _TrafficBox(
      {required this.icon,
      required this.color,
      required this.label,
      required this.active,
      required this.speed,
      required this.total});

  final IconData icon;
  final Color color;
  final String label;
  final bool active;
  final String speed;
  final String total;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = S.of(context);
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: tr(context, 'a11yTraffic', {'label': label, 'speed': speed, 'total': total}),
      child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon,
                size: 16, color: active ? color : scheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
          ]),
          const SizedBox(height: 2),
          Text(speed,
              textDirection: TextDirection.ltr,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: active ? null : scheme.onSurfaceVariant)),
          Text('${t.sessionLabel}: ${ltr(total)}',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11)),
        ],
      ),
    ));
  }
}

/// One row of the flat server list: a group header, one of its configs, or its empty note.
/// Rows are worked out per index from the group sizes, so even a list of thousands of
/// configs costs nothing until a row scrolls into view.
class _Row {
  const _Row(this.group, {this.config, this.empty = false, this.last = false});

  final ServerGroup group;
  final ProxyConfig? config;
  final bool empty;
  final bool last;
}

class _ServerList extends StatefulWidget {
  const _ServerList({required this.state});

  final AppState state;

  @override
  State<_ServerList> createState() => _ServerListState();
}

class _ServerListState extends State<_ServerList> {
  final _open = <String>{};
  final _scroll = ScrollController();
  final _flashKey = GlobalKey();
  ProxyConfig? _flash;
  Timer? _flashTimer;
  var _scrollTo = false;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    state.locateTick.addListener(_locate);
  }

  @override
  void dispose() {
    state.locateTick.removeListener(_locate);
    _flashTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  /// Opens the dropdown that holds the server, scrolls to it and tints it for a few seconds.
  void _locate() {
    final target = state.locateTarget;
    if (target == null) return;
    final group =
        state.groups.where((g) => g.configs.any((c) => identical(c, target))).firstOrNull;
    if (group == null) return;
    _flashTimer?.cancel();
    setState(() {
      _open.add(group.id);
      _flash = target;
      _scrollTo = true;
    });
    _flashTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _flash = null);
    });
  }

  void _toggle(ServerGroup g) => setState(() {
        if (!_open.remove(g.id)) _open.add(g.id);
      });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final locked = state.vpn.status != VpnStatus.stopped &&
        state.vpn.status != VpnStatus.error;
    // Each visible group takes its header row plus, when open, its configs (or one note).
    final groups = [
      for (final g in state.groups)
        if (g.kind != GroupKind.manual || g.configs.isNotEmpty) g
    ];
    final starts = <int>[];
    var count = 0;
    for (final g in groups) {
      starts.add(count);
      count += 1 +
          (_open.contains(g.id)
              ? (g.configs.isEmpty ? 1 : g.configs.length)
              : 0);
    }
    _Row rowAt(int i) {
      var s = starts.length - 1;
      while (starts[s] > i) {
        s--;
      }
      final g = groups[s];
      final local = i - starts[s];
      if (local == 0) return _Row(g);
      if (g.configs.isEmpty) return _Row(g, empty: true, last: true);
      return _Row(g,
          config: g.configs[local - 1], last: local == g.configs.length);
    }

    if (_scrollTo && _flash != null) {
      _scrollTo = false;
      var index = -1;
      for (var s = 0; s < groups.length && index < 0; s++) {
        final at = groups[s].configs.indexWhere((c) => identical(c, _flash));
        if (at >= 0) index = starts[s] + 1 + at;
      }
      if (index >= 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          if (!mounted || !_scroll.hasClients) return;
          // Rows are about this tall; the exact position is fixed once the row exists.
          await _scroll.animateTo(
              (index * 72.0 - 120).clamp(0, _scroll.position.maxScrollExtent),
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeOut);
          final box = _flashKey.currentContext;
          if (!mounted) return;
          if (box != null && box.mounted) {
            await Scrollable.ensureVisible(box,
                alignment: 0.3, duration: const Duration(milliseconds: 250));
          }
        });
      }
    }

    const radius = Radius.circular(18);
    return ReorderableListView.builder(
      scrollController: _scroll,
      padding: const EdgeInsets.only(top: 4, bottom: 24),
      buildDefaultDragHandles: false,
      itemCount: count,
      // Only a group title can be picked up; it lands before or after the group it is dropped on.
      onReorder: (from, to) {
        if (to > from) to--;
        final moved = rowAt(from);
        if (moved.config != null || moved.empty || to == from) return;
        final target = rowAt(to).group;
        if (identical(target, moved.group)) return;
        state.moveGroup(moved.group, target, after: to > from);
      },
      itemBuilder: (context, i) {
        final row = rowAt(i);
        final g = row.group;
        final open = _open.contains(g.id);
        final header = row.config == null && !row.empty;
        final Widget child;
        if (header) {
          final at = groups.indexOf(g);
          child = _GroupHeader(
              state: state,
              group: g,
              open: open,
              onToggle: () => _toggle(g),
              onMoveUp: at > 0 ? () => state.moveGroup(g, groups[at - 1], after: false) : null,
              onMoveDown: at < groups.length - 1
                  ? () => state.moveGroup(g, groups[at + 1], after: true)
                  : null);
        } else {
          child = Column(mainAxisSize: MainAxisSize.min, children: [
            Divider(height: 1, color: scheme.outlineVariant),
            if (row.config != null)
              KeyedSubtree(
                  key: identical(row.config, _flash) ? _flashKey : null,
                  child: _ConfigTile(
                      state: state,
                      group: g,
                      config: row.config!,
                      locked: locked,
                      flash: identical(row.config, _flash)))
            else
              Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(S.of(context).emptyGroup)),
          ]);
        }
        final key = ValueKey(header
            ? 'h-${g.id}'
            : row.config != null
                ? 'c-${g.id}-${row.config!.link}'
                : 'e-${g.id}');
        final item = Padding(
          key: key,
          padding: EdgeInsets.fromLTRB(
              12, header ? 6 : 0, 12, (header && !open) || row.last ? 6 : 0),
          child: ClipRRect(
            borderRadius: BorderRadius.vertical(
              top: header ? radius : Radius.zero,
              bottom: (header && !open) || row.last ? radius : Radius.zero,
            ),
            child: ColoredBox(color: scheme.surfaceContainerLow, child: child),
          ),
        );
        return header
            ? ReorderableDelayedDragStartListener(
                key: key, index: i, child: item)
            : item;
      },
    );
  }
}

/// Real delay can drop the configs that do not answer; null = cancelled.
Future<bool?> _askRemoveDead(BuildContext context) {
  var remove = false;
  return showDialog<bool>(
    context: context,
    builder: (dialog) => StatefulBuilder(builder: (dialog, setState) {
      final t = S.of(dialog);
      return AlertDialog(
        title: Text(t.removeDeadTitle),
        content: CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: remove,
          onChanged: (v) => setState(() => remove = v ?? false),
          title: Text(t.removeDeadOption),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog), child: Text(t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(dialog, remove),
              child: Text(t.start)),
        ],
      );
    }),
  );
}

/// Asks what to do with the servers that were not tested yet when the test is stopped:
/// keep them (the default) or delete them. Null = the user changed their mind.
Future<bool?> _askUntested(BuildContext context) {
  var remove = false;
  return showDialog<bool>(
    context: context,
    builder: (dialog) => StatefulBuilder(builder: (dialog, setState) {
      final t = S.of(dialog);
      return AlertDialog(
        title: Text(tr(dialog, 'cancelTest')),
        content: CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: remove,
          onChanged: (v) => setState(() => remove = v ?? false),
          title: Text(tr(dialog, 'removeUntested')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog), child: Text(t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(dialog, remove),
              child: Text(tr(dialog, 'cancelTest'))),
        ],
      );
    }),
  );
}

enum _GroupAction {
  tcping,
  realDelay,
  cancelTest,
  refresh,
  cancelRefresh,
  info,
  edit,
  share,
  delete,
  deleteAll,
  warpNext,
  warpOff,
}

/// Asks before every config added by hand is removed. Always asked, whatever the setting for single
/// deletions says: this removes the whole list at once.
Future<bool> _confirmDeleteAll(BuildContext context, int count) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialog) {
      final t = S.of(dialog);
      return AlertDialog(
        title: Text(tr(dialog, 'deleteAll')),
        content: Text(tr(dialog, 'deleteAllAsk', {'n': count})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(t.cancel)),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(t.delete)),
        ],
      );
    },
  );
  return ok == true;
}

/// The title row of a dropdown: the collector, a subscription, or configs added by hand.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader(
      {required this.state,
      required this.group,
      required this.open,
      required this.onToggle,
      this.onMoveUp,
      this.onMoveDown});

  final AppState state;
  final ServerGroup group;
  final bool open;
  final VoidCallback onToggle;

  /// Moves the group one place up or down (null: it is first or last). Dragging is not possible with
  /// a screen reader, so these are offered as actions of the row.
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;

  Map<CustomSemanticsAction, VoidCallback> _moveActions(BuildContext context) => {
        if (onMoveUp != null) CustomSemanticsAction(label: tr(context, 'a11yMoveUp')): onMoveUp!,
        if (onMoveDown != null) CustomSemanticsAction(label: tr(context, 'a11yMoveDown')): onMoveDown!,
      };

  String _title(S t) => switch (group.kind) {
        GroupKind.collector => t.collectorGroup,
        GroupKind.manual => t.manualGroup,
        GroupKind.warp => 'WARP',
        GroupKind.subscription => group.name,
      };

  IconData get _icon => switch (group.kind) {
        GroupKind.collector => Icons.public,
        GroupKind.manual => Icons.edit_note,
        GroupKind.warp => Icons.cloud_outlined,
        GroupKind.subscription => Icons.rss_feed,
      };

  void _onAction(BuildContext context, _GroupAction action) {
    switch (action) {
      case _GroupAction.tcping:
        state.ping(group, real: false);
      case _GroupAction.cancelTest:
        _askUntested(context).then((remove) {
          if (remove != null) state.cancelPing(group, removeUntested: remove);
        });
      case _GroupAction.realDelay:
        _askRemoveDead(context).then((remove) {
          if (remove != null) state.ping(group, real: true, removeDead: remove);
        });
      case _GroupAction.refresh:
        group.kind == GroupKind.collector
            ? state.refreshCollector()
            : state.refreshSubscription(group);
      case _GroupAction.cancelRefresh:
        state.cancelRefresh(group);
      case _GroupAction.info:
        Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => switch (group.kind) {
                  GroupKind.collector => CollectorInfoPage(state: state),
                  GroupKind.warp => WarpPage(state: state),
                  _ => SubscriptionInfoPage(state: state, group: group),
                }));
      case _GroupAction.edit:
        _editSubscription(context, state, group);
      case _GroupAction.share:
        showShareSheet(context,
            text: group.url ?? '',
            copyLabel: S.of(context).copySubscriptionLink);
      case _GroupAction.delete:
        confirmDeletion(context, state).then((ok) {
          if (ok) state.removeSubscription(group);
        });
      case _GroupAction.deleteAll:
        _confirmDeleteAll(context, group.configs.length).then((ok) {
          if (ok) state.clearManual();
        });
      case _GroupAction.warpNext:
        state.warp.nextMethod();
      case _GroupAction.warpOff:
        state.warp.disable();
    }
  }

  /// "N works - P%": only the count is green, the progress keeps the normal color.
  Widget _testStat(String text, ColorScheme scheme) {
    final i = text.indexOf(' · ');
    if (i < 0) return Text(text);
    return Text.rich(TextSpan(children: [
      TextSpan(
          text: text.substring(0, i),
          style: const TextStyle(
              color: Colors.green, fontWeight: FontWeight.w600)),
      TextSpan(text: text.substring(i)),
    ]));
  }

  /// The test result (public servers) or the way of connecting (WARP) and, once anything went through
  /// these free servers, how much (like the usage a subscription shows, but without a limit).
  Widget? _freeSubtitle(BuildContext context, S t, ColorScheme scheme) {
    final isWarp = group.kind == GroupKind.warp;
    final test = isWarp ? null : state.tests[group.id];
    return ListenableBuilder(
      listenable: Listenable.merge([state, state.traffic]),
      builder: (context, _) {
        final usage = isWarp ? state.warpUsage : state.publicUsage;
        final used = usage[0] + usage[1];
        final way = isWarp && state.warp.currentMethod != null
            ? tr(context, 'warpMethod', {
                'method': state.warp.currentMethod ?? '',
                'address': state.warp.currentAddress ?? '',
              })
            : null;
        if (test == null && way == null && used == 0) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (test != null) _testStat(t.testStat(test.alive, test.percent), scheme),
            if (way != null)
              Text(way,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textDirection: TextDirection.ltr,
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            if (used > 0)
              Padding(
                padding: EdgeInsetsDirectional.only(top: test == null ? 4 : 6, end: 8),
                child: Semantics(
                  container: true,
                  excludeSemantics: true,
                  label: tr(context, isWarp ? 'a11yWarpUsage' : 'a11yPubUsage', {'used': _bytes(used)}),
                  child: _UsageBar(
                    fraction: 1,
                    fill: Colors.purple.shade400,
                    track: scheme.surfaceContainerHighest,
                    used: _bytes(used),
                    total: null,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = S.of(context);
    final scheme = Theme.of(context).colorScheme;
    final isSub = group.kind == GroupKind.subscription;
    return Semantics(
      expanded: open,
      customSemanticsActions: _moveActions(context),
      child: ListTile(
      onTap: onToggle,
      contentPadding: const EdgeInsetsDirectional.only(start: 16, end: 4),
      leading: Stack(
        alignment: Alignment.center,
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: scheme.primaryContainer,
            child: Icon(_icon, size: 20, color: scheme.onPrimaryContainer),
          ),
          if (state.working.contains(group.id))
            const SizedBox(
                width: 42,
                height: 42,
                child: CircularProgressIndicator(strokeWidth: 2.5)),
        ],
      ),
      title: Text('${_title(t)} (${group.configs.length})',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600)),
      // A subscription whose provider sends no usage numbers shows nothing under its name.
      subtitle: isSub
          ? (group.info == null
              ? null
              : Padding(
                  padding: const EdgeInsetsDirectional.only(top: 4, end: 8),
                  child: _SubscriptionInfo(info: group.info!),
                ))
          : (group.kind == GroupKind.collector || group.kind == GroupKind.warp
              ? _freeSubtitle(context, t, scheme)
              : null),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PopupMenuButton<_GroupAction>(
            tooltip: t.more,
            icon: const Icon(Icons.more_vert),
            onSelected: (a) => _onAction(context, a),
            itemBuilder: (menu) => group.kind == GroupKind.warp
                ? [
                    PopupMenuItem(
                        value: _GroupAction.info,
                        child: _MenuRow(Icons.info_outline, tr(context, 'subInfo'))),
                    PopupMenuItem(
                        value: _GroupAction.warpNext,
                        child: _MenuRow(Icons.swap_horiz, tr(context, 'warpTryNext'))),
                    PopupMenuItem(
                        value: _GroupAction.warpOff,
                        child: _MenuRow(Icons.power_settings_new, tr(context, 'warpTurnOff'))),
                  ]
                : [
              if (state.tests[group.id]?.running ?? false)
                PopupMenuItem(
                    value: _GroupAction.cancelTest,
                    child: _MenuRow(Icons.stop_circle_outlined, tr(context, 'cancelTest'))),
              PopupMenuItem(
                  value: _GroupAction.tcping,
                  child: _MenuRow(Icons.network_check, t.tcping)),
              PopupMenuItem(
                  enabled: state.canTestReal,
                  value: _GroupAction.realDelay,
                  child: _MenuRow(Icons.speed, t.realDelay)),
              if (group.kind != GroupKind.manual)
                state.refreshing.contains(group.id)
                    ? PopupMenuItem(
                        value: _GroupAction.cancelRefresh,
                        child: _MenuRow(Icons.cancel_outlined,
                            tr(context, 'cancelUpdate')))
                    : PopupMenuItem(
                        value: _GroupAction.refresh,
                        child: _MenuRow(Icons.refresh, t.refreshList)),
              if (group.kind == GroupKind.manual && group.configs.isNotEmpty)
                PopupMenuItem(
                    value: _GroupAction.deleteAll,
                    child: _MenuRow(Icons.delete_sweep_outlined, tr(context, 'deleteAll'))),
              if (isSub || group.kind == GroupKind.collector)
                PopupMenuItem(
                    value: _GroupAction.info,
                    child: _MenuRow(Icons.info_outline, tr(context, 'subInfo'))),
              if (isSub) ...[
                PopupMenuItem(
                    value: _GroupAction.edit,
                    child: _MenuRow(Icons.edit, t.edit)),
                PopupMenuItem(
                    value: _GroupAction.share,
                    child: _MenuRow(Icons.share, t.share)),
                PopupMenuItem(
                    value: _GroupAction.delete,
                    child: _MenuRow(Icons.delete_outline, t.delete)),
              ],
            ],
          ),
          AnimatedRotation(
            turns: open ? 0.5 : 0,
            duration: const Duration(milliseconds: 250),
            child: const Icon(Icons.expand_more),
          ),
          const SizedBox(width: 8),
        ],
      ),
    ));
  }
}

/// Time left as a chip, and usage as a bar coloured by how much is used.
class _SubscriptionInfo extends StatefulWidget {
  const _SubscriptionInfo({required this.info});

  final SubInfo info;

  @override
  State<_SubscriptionInfo> createState() => _SubscriptionInfoState();
}

class _SubscriptionInfoState extends State<_SubscriptionInfo> {
  Timer? _timer;

  SubInfo get info => widget.info;

  @override
  void initState() {
    super.initState();
    // The time left is worked out from the clock, so it is redrawn as the minutes pass.
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = S.of(context);
    final scheme = Theme.of(context).colorScheme;

    // Time chip.
    IconData icon = Icons.schedule;
    String text;
    Color tone = scheme.primary;
    if (info.unlimitedTime) {
      icon = Icons.all_inclusive;
      text = t.timeWord;
    } else {
      final left = DateTime.fromMillisecondsSinceEpoch(info.expire * 1000)
          .difference(DateTime.now());
      if (left.inMinutes <= 0) {
        text = t.expired;
        tone = Colors.red;
      } else if (left.inDays >= 1) {
        text = t.daysLeft(left.inDays);
        if (left.inDays <= 3) tone = Colors.orange;
      } else if (left.inHours >= 1) {
        text = t.hoursLeft(left.inHours);
        tone = Colors.orange;
      } else {
        text = t.minutesLeft(left.inMinutes);
        tone = Colors.red;
      }
    }

    // Usage bar.
    final unlimited = info.unlimitedData;
    final fraction = unlimited ? 1.0 : (info.used / info.total).clamp(0.0, 1.0);
    final fill = unlimited
        ? Colors.purple.shade400
        : fraction < 0.6
            ? Colors.green.shade600
            : fraction < 0.85
                ? Colors.orange.shade700
                : Colors.red.shade600;

    // The time and the usage are drawn as a chip and a bar (the bar twice, for the two backgrounds):
    // a screen reader gets one plain sentence instead.
    final usageText = unlimited
        ? tr(context, 'a11yUsageUnlimited', {'used': _bytes(info.used)})
        : tr(context, 'a11yUsage', {'used': _bytes(info.used), 'total': _bytes(info.total)});
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: '$text, $usageText',
      child: Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: tone.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 14, color: tone),
            const SizedBox(width: 4),
            Text(text,
                style: TextStyle(
                    color: tone, fontSize: 12, fontWeight: FontWeight.w600)),
          ]),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _UsageBar(
            fraction: fraction,
            fill: fill,
            track: scheme.surfaceContainerHighest,
            used: _bytes(info.used),
            total: unlimited ? null : _bytes(info.total),
          ),
        ),
      ],
    ));
  }
}

/// The text is drawn twice, once per background, so it stays readable on both the
/// filled part and the empty part whatever colour the fill has.
class _UsageBar extends StatelessWidget {
  const _UsageBar(
      {required this.fraction,
      required this.fill,
      required this.track,
      required this.used,
      required this.total});

  final double fraction;
  final Color fill;
  final Color track;
  final String used;
  final String? total;

  static Color _on(Color bg) =>
      ThemeData.estimateBrightnessForColor(bg) == Brightness.dark
          ? Colors.white
          : Colors.black87;

  Widget _label(Color color) {
    final style =
        TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600);
    // Shrinks to fit when the bar is narrow (a small window or a large text size) instead of
    // running over its edge.
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('$used / ', style: style),
          if (total != null)
            Text(total!, style: style)
          else
            Icon(Icons.all_inclusive, size: 14, color: color),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: fraction),
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeOutCubic,
        builder: (context, f, _) => ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            // taller when the user has chosen larger text
            height: MediaQuery.textScalerOf(context).scale(22),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(
                    color: track, child: Center(child: _label(_on(track)))),
                ClipRect(
                  clipper: _FractionClipper(f),
                  child: ColoredBox(
                      color: fill, child: Center(child: _label(_on(fill)))),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FractionClipper extends CustomClipper<Rect> {
  const _FractionClipper(this.fraction);

  final double fraction;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTWH(0, 0, size.width * fraction, size.height);

  @override
  bool shouldReclip(_FractionClipper old) => old.fraction != fraction;
}

enum _ConfigAction { edit, share, tcping, realDelay, delete }

class _ConfigTile extends StatelessWidget {
  const _ConfigTile(
      {required this.state,
      required this.group,
      required this.config,
      required this.locked,
      this.flash = false});

  final AppState state;
  final ServerGroup group;
  final ProxyConfig config;
  final bool locked;

  /// Tinted for a moment after the user jumped here from the connection card.
  final bool flash;

  Future<void> _onAction(BuildContext context, _ConfigAction a) async {
    final t = S.of(context);
    switch (a) {
      case _ConfigAction.edit:
        final result = await Navigator.push<String>(
          context,
          MaterialPageRoute(builder: (_) => EditConfigPage(config: config)),
        );
        if (result != null) {
          await state.editConfig(group, config, result);
        }
      case _ConfigAction.share:
        showShareSheet(context, text: config.link, copyLabel: t.copyConfig);
      case _ConfigAction.delete:
        if (await confirmDeletion(context, state)) {
          state.removeConfig(group, config);
        }
      case _ConfigAction.tcping:
        state.testOne(config, real: false);
      case _ConfigAction.realDelay:
        if (!state.canTestReal) {
          toast(context, t.realDelayNeedsDisconnect);
        } else {
          state.testOne(config, real: true);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = S.of(context);
    final scheme = Theme.of(context).colorScheme;
    final selected = identical(state.selected, config);
    final ms = config.latencyMs;
    return AnimatedContainer(
        key: ValueKey(config.link),
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
        color: flash
            ? scheme.tertiaryContainer
            : selected ? scheme.primaryContainer : Colors.transparent,
        child: ListTile(
          contentPadding: const EdgeInsetsDirectional.only(start: 16, end: 4),
          selected: selected,
          selectedColor: flash ? scheme.onTertiaryContainer : scheme.onPrimaryContainer,
          title: FlagName(config.name),
          subtitle: Text.rich(
            TextSpan(children: [
              if (ms != null)
                TextSpan(
                  text: ms < 0 ? t.timeout : '$ms ms',
                  style: TextStyle(
                      color: ms < 0 ? Colors.red : _latencyColor(ms),
                      fontWeight: FontWeight.w600),
                ),
              TextSpan(
                  text:
                      '${ms == null ? '' : ' · '}${config.label} · ${config.maskedAddress}'),
            ]),
            textDirection: TextDirection.ltr,
            textAlign: TextAlign.start,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: state.canSelect
              ? () => state.select(config)
              : (state.connected && !state.restartOnChange
                  ? () => toast(context, tr(context, 'selectBlocked'))
                  : null),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: state.testing.contains(config)
                    ? const SizedBox(
                        key: ValueKey('t'),
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const SizedBox.shrink(key: ValueKey('n')),
              ),
              PopupMenuButton<_ConfigAction>(
                tooltip: t.more,
                icon: const Icon(Icons.more_vert),
                onSelected: (a) => _onAction(context, a),
                itemBuilder: (menu) => [
                  PopupMenuItem(
                      enabled: !(locked && selected),
                      value: _ConfigAction.edit,
                      child: _MenuRow(Icons.edit, t.edit)),
                  PopupMenuItem(
                      value: _ConfigAction.share,
                      child: _MenuRow(Icons.share, t.share)),
                  PopupMenuItem(
                      value: _ConfigAction.tcping,
                      child: _MenuRow(Icons.network_check, t.tcping)),
                  PopupMenuItem(
                      enabled: state.canTestReal,
                      value: _ConfigAction.realDelay,
                      child: _MenuRow(Icons.speed, t.realDelay)),
                  PopupMenuItem(
                      enabled: !(locked && selected),
                      value: _ConfigAction.delete,
                      child: _MenuRow(Icons.delete_outline, t.delete)),
                ],
              ),
            ],
          ),
        ));
  }
}

Future<void> _editSubscription(
    BuildContext context, AppState state, ServerGroup group) async {
  final name = TextEditingController(text: group.name);
  final url = TextEditingController(text: group.url);
  String? error;
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialog) => StatefulBuilder(
      builder: (dialog, setState) {
        final t = S.of(dialog);
        return AlertDialog(
          title: Text(t.editSubscriptionTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: InputDecoration(
                    labelText: t.subscriptionName,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: url,
                maxLines: 4,
                minLines: 1,
                textDirection: TextDirection.ltr,
                decoration: InputDecoration(
                  labelText: t.subscriptionUrl,
                  border: const OutlineInputBorder(),
                  errorText: error,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialog), child: Text(t.cancel)),
            FilledButton(
              onPressed: () {
                final u = url.text.trim();
                if (!u.startsWith('http://') && !u.startsWith('https://')) {
                  setState(() => error = t.invalidUrl);
                } else {
                  Navigator.pop(dialog, true);
                }
              },
              child: Text(t.save),
            ),
          ],
        );
      },
    ),
  );
  if (ok == true) {
    final n = name.text.trim();
    await state.editSubscription(
        group, n.isEmpty ? group.name : n, url.text.trim());
  }
}
