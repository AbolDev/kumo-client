import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/updater.dart';
import '../core/vpn_channel.dart';
import '../core/desktop_vpn.dart' show DesktopVpn;
import '../l10n/extra.dart';
import 'share_sheet.dart';

Future<void> openLink(String url) async {
  try {
    if (Platform.isWindows) {
      await Process.run('cmd', ['/c', 'start', '', url]);
    } else if (Platform.isMacOS) {
      await Process.run('open', [url]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [url]);
    } else {
      await VpnChannel.openUrl(url);
    }
  } catch (_) {}
}

/// Looks for a newer stable release. With [silent] nothing is shown unless there is one
/// (used when the app starts); otherwise the answer is always shown.
Future<void> checkAndPrompt(BuildContext context, {required bool silent}) async {
  final current = (await PackageInfo.fromPlatform()).version;
  if (!context.mounted) return;
  // A check the user asks for first asks whether test versions count too; the answer is only
  // for this check. The check at startup never includes them.
  var tests = false;
  if (!silent) {
    final answer = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        icon: const Icon(Icons.science_outlined),
        title: Text(tr(dialog, 'prereleaseUpdates')),
        content: Text(tr(dialog, 'prereleaseUpdatesDesc')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text(tr(dialog, 'updNo'))),
          FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(tr(dialog, 'updYes'))),
        ],
      ),
    );
    if (answer == null || !context.mounted) return;
    tests = answer;
    toast(context, tr(context, 'checkingUpdate'));
  }
  UpdateInfo? found;
  includePrerelease = tests;
  try {
    found = await checkForUpdate(current);
  } catch (_) {}
  includePrerelease = false;
  if (!context.mounted) return;
  if (!silent) ScaffoldMessenger.of(context).hideCurrentSnackBar();
  if (found != null && found.newer) {
    await _offer(context, found, current);
  } else if (!silent) {
    await showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        icon: Icon(found == null ? Icons.cloud_off : Icons.check_circle_outline),
        title: Text(found == null
            ? tr(dialog, 'updateFailed')
            : tr(dialog, 'upToDate', {'v': current})),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: Text(MaterialLocalizations.of(dialog).closeButtonLabel)),
        ],
      ),
    );
  }
}

/// The release text without the download table and the checksums, in the app's language when
/// the release has both English and Persian parts (separated by a line of dashes).
String _notesFor(BuildContext context, String raw) {
  var text = raw.replaceAll('\r', '');
  final locale = Localizations.localeOf(context);
  final code = locale.languageCode == 'zh' && locale.scriptCode == 'Hant'
      ? 'zh-TW'
      : locale.languageCode;
  // The release page shows English only. The other languages sit in hidden comments of the form
  // <!-- lang:xx ... --> that GitHub does not display; the text outside them is English. A
  // language without a block falls back to English. (Older releases marked each language with
  // a bare <!-- lang:xx --> line, and the oldest had English first and Persian last.)
  final hidden = RegExp(r'<!--\s*lang:([\w-]+)[ \t]*\n([\s\S]*?)-->').allMatches(text).toList();
  final marks = RegExp(r'<!--\s*lang:([\w-]+)\s*-->').allMatches(text).toList();
  if (hidden.isNotEmpty) {
    final blocks = <String, String>{
      for (final m in hidden) m[1]!: m[2]!,
      'en': text.replaceAll(RegExp(r'<!--\s*lang:[\w-]+[ \t]*\n[\s\S]*?-->'), ''),
    };
    text = blocks[code] ?? (code == 'zh-TW' ? blocks['zh'] : null) ?? blocks['en']!;
  } else if (marks.isNotEmpty) {
    final blocks = <String, String>{
      for (var i = 0; i < marks.length; i++)
        marks[i][1]!: text.substring(
            marks[i].end, i + 1 < marks.length ? marks[i + 1].start : text.length),
    };
    text = blocks[code] ??
        (code == 'zh-TW' ? blocks['zh'] : null) ??
        blocks['en'] ??
        blocks.values.first;
  } else {
    final parts = text.split(RegExp(r'\n-{3,}\n'));
    if (parts.length > 1) text = code == 'fa' ? parts.last : parts.first;
  }
  final cut = RegExp(r'\n#{1,3} (Downloads|SHA-256|دانلود)').firstMatch(text);
  if (cut != null) text = text.substring(0, cut.start);
  final lines = <String>[];
  for (var line in text.split('\n')) {
    line = line.trim();
    if (line.isEmpty || RegExp(r'^#\s').hasMatch(line)) continue; // the release title
    line = line.replaceFirst(RegExp(r'^##+\s*'), '');
    line = line.replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (m) => m[1]!);
    line = line.replaceAllMapped(RegExp(r'\*(.+?)\*'), (m) => m[1]!);
    line = line.replaceAll('`', '');
    lines.add(line.startsWith('- ') ? '•  ${line.substring(2)}' : line);
  }
  return lines.join('\n\n').trim();
}

Future<void> _offer(BuildContext context, UpdateInfo info, String current) async {
  final asset = await pickAsset(info);
  if (!context.mounted) return;
  final size = asset == null ? null : info.sizes[asset.name];
  final choice = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (sheet) {
      final scheme = Theme.of(sheet).colorScheme;
      // One release: its text. Several skipped ones: a short block per version, newest first.
      final many = info.history.length > 1;
      final notes = many ? '' : _notesFor(sheet, info.notes);
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(sheet).size.height * 0.85),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CircleAvatar(
                  radius: 32,
                  backgroundColor: scheme.primaryContainer,
                  child: Icon(Icons.system_update_alt,
                      size: 32, color: scheme.onPrimaryContainer),
                ),
                const SizedBox(height: 16),
                Text(tr(sheet, 'updNewVersion'),
                    textAlign: TextAlign.center,
                    style: Theme.of(sheet).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text('v${info.version}',
                    textAlign: TextAlign.center,
                    textDirection: TextDirection.ltr,
                    style: Theme.of(sheet).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w700, color: scheme.primary)),
                const SizedBox(height: 8),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  children: [
                    Chip(
                      avatar: const Icon(Icons.phone_android, size: 18),
                      label: Text(tr(sheet, 'updYouHave', {'v': current}),
                          textDirection: TextDirection.ltr),
                    ),
                    if (size != null)
                      Chip(
                        avatar: const Icon(Icons.download_outlined, size: 18),
                        label: Text(_size(size), textDirection: TextDirection.ltr),
                      ),
                  ],
                ),
                if (many) ...[
                  const SizedBox(height: 12),
                  Text(tr(sheet, 'updWhatsNewSince', {'v': current}),
                      style: Theme.of(sheet).textTheme.titleSmall),
                  const SizedBox(height: 6),
                  Flexible(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                        child: ListView(
                          shrinkWrap: true,
                          children: [
                            for (final (i, r) in info.history.indexed)
                              ExpansionTile(
                                initiallyExpanded: i == 0,
                                shape: const Border(),
                                collapsedShape: const Border(),
                                title: Text('v${r.version}',
                                    textDirection: TextDirection.ltr,
                                    style: const TextStyle(fontWeight: FontWeight.w600)),
                                childrenPadding:
                                    const EdgeInsets.fromLTRB(16, 0, 16, 12),
                                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                                children: [Text(_notesFor(sheet, r.notes))],
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
                if (notes.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(tr(sheet, 'updWhatsNew'),
                      style: Theme.of(sheet).textTheme.titleSmall),
                  const SizedBox(height: 6),
                  Flexible(
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: SingleChildScrollView(child: Text(notes)),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton.icon(
                  autofocus: true,
                  icon: const Icon(Icons.download),
                  label: Text(tr(sheet, 'updateInstall')),
                  onPressed: () => Navigator.pop(sheet, 'install'),
                ),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: TextButton(
                        onPressed: () => Navigator.pop(sheet),
                        child: Text(tr(sheet, 'updLater'))),
                  ),
                  Expanded(
                    child: TextButton(
                        onPressed: () => Navigator.pop(sheet, 'page'),
                        child: Text(tr(sheet, 'updateOpen'))),
                  ),
                ]),
              ],
            ),
          ),
        ),
      );
    },
  );
  if (choice == 'page') {
    await openLink(info.url);
  } else if (choice == 'install' && context.mounted) {
    await _install(context, info, asset);
  }
}

/// Downloads the file made for this device and starts its installer.
Future<void> _install(BuildContext context, UpdateInfo info,
    ({String name, String url})? asset) async {
  // The portable build is not installed by the setup file: the new zip is taken from the page.
  if (asset == null || (Platform.isWindows && DesktopVpn.portable)) {
    await openLink(info.url);
    return;
  }
  // Android: the permission to install apps is asked for before anything is downloaded.
  if (Platform.isAndroid && !await _allowInstalls(context)) return;
  if (!context.mounted) return;
  final progress = ValueNotifier<_Progress>(const _Progress(0, -1, 0));
  final cancel = DownloadCancel();
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialog) => PopScope(
      canPop: false,
      onPopInvokedWithResult: (_, __) => cancel.cancel(),
      child: AlertDialog(
        icon: const Icon(Icons.downloading),
        title: Text(tr(dialog, 'updateDownloading')),
        content: ValueListenableBuilder<_Progress>(
          valueListenable: progress,
          builder: (_, p, __) {
            final share = p.total > 0 ? (p.received / p.total).clamp(0.0, 1.0) : null;
            final left = p.total > 0 && p.speed > 0
                ? Duration(seconds: ((p.total - p.received) / p.speed).ceil())
                : null;
            return Column(mainAxisSize: MainAxisSize.min, children: [
              Text(share == null ? '…' : '${(share * 100).round()}%',
                  style: Theme.of(dialog)
                      .textTheme
                      .displaySmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(value: share, minHeight: 10),
              ),
              const SizedBox(height: 10),
              Text(
                p.total > 0
                    ? '${_size(p.received)} / ${_size(p.total)}'
                    : _size(p.received),
                textDirection: TextDirection.ltr,
              ),
              const SizedBox(height: 4),
              Text(
                [
                  if (p.speed > 0) '${_size(p.speed.round())}/s',
                  if (left != null) tr(dialog, 'updEta', {'t': _duration(left)}),
                ].join('  ·  '),
                textDirection: TextDirection.ltr,
                style: Theme.of(dialog).textTheme.bodySmall,
              ),
              const SizedBox(height: 6),
              Text(asset.name,
                  textDirection: TextDirection.ltr,
                  style: Theme.of(dialog).textTheme.bodySmall),
            ]);
          },
        ),
        actions: [
          TextButton.icon(
            autofocus: true,
            icon: const Icon(Icons.close),
            label: Text(tr(dialog, 'updCancelDownload')),
            onPressed: cancel.cancel,
          ),
        ],
      ),
    ),
  );
  String? path;
  try {
    final clock = Stopwatch()..start();
    var lastMs = 0, lastBytes = 0;
    var speed = 0.0;
    path = await downloadUpdate(asset.url, asset.name, (got, total) {
      final ms = clock.elapsedMilliseconds;
      if (ms - lastMs >= 500 || (total > 0 && got >= total)) {
        final now = (got - lastBytes) * 1000 / (ms - lastMs).clamp(1, 1 << 30);
        // Smoothed, so the figure does not jump with every chunk.
        speed = speed == 0 ? now : speed * 0.6 + now * 0.4;
        lastMs = ms;
        lastBytes = got;
      }
      progress.value = _Progress(got, total, speed);
    }, cancel: cancel);
  } catch (_) {}
  if (!context.mounted) return;
  Navigator.of(context, rootNavigator: true).pop();
  if (cancel.cancelled) {
    toast(context, tr(context, 'updCancelled'));
    return;
  }
  if (path == null) {
    toast(context, tr(context, 'updateFailed'));
    return;
  }
  if (Platform.isWindows) {
    // The VPN is put away first; the installer then closes Kumo and replaces it.
    await VpnChannel.stop();
    await Process.start(path, const [], mode: ProcessStartMode.detached);
    exit(0);
  }
  final result = await VpnChannel.installApk(path);
  if (!context.mounted) return;
  if (result == 'permission') {
    toast(context, tr(context, 'updatePermission'));
  } else if (result != 'ok') {
    toast(context, tr(context, 'updateFailed'));
  }
}

String _duration(Duration d) {
  if (d.inMinutes >= 1) return '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  return '${d.inSeconds}s';
}

/// What the download dialog shows: bytes received, the total (-1 if unknown) and bytes/second.
class _Progress {
  const _Progress(this.received, this.total, this.speed);

  final int received;
  final int total;
  final double speed;
}

String _size(int bytes) {
  if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
  if (bytes >= 1 << 10) return '${(bytes / (1 << 10)).round()} KB';
  return '$bytes B';
}

/// Android: asks the user to allow installs from Kumo and waits until they are back from the
/// system screen. Returns whether installing is now allowed.
Future<bool> _allowInstalls(BuildContext context) async {
  if (await VpnChannel.canInstallApk()) return true;
  if (!context.mounted) return false;
  toast(context, tr(context, 'updatePermission'));
  final back = Completer<void>();
  final watcher = _ResumeWatcher(back);
  WidgetsBinding.instance.addObserver(watcher);
  try {
    await VpnChannel.allowInstallApk();
    await back.future.timeout(const Duration(minutes: 5), onTimeout: () {});
  } finally {
    WidgetsBinding.instance.removeObserver(watcher);
  }
  return VpnChannel.canInstallApk();
}

class _ResumeWatcher with WidgetsBindingObserver {
  _ResumeWatcher(this.done);

  final Completer<void> done;
  var _left = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) _left = true;
    if (state == AppLifecycleState.resumed && _left && !done.isCompleted) done.complete();
  }
}
