import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/updater.dart';
import '../core/vpn_channel.dart';
import '../l10n/extra.dart';
import 'share_sheet.dart';

Future<void> openLink(String url) async {
  if (Platform.isWindows) {
    await Process.run('cmd', ['/c', 'start', '', url]);
  } else {
    await VpnChannel.openUrl(url);
  }
}

/// Looks for a newer stable release. With [silent] nothing is shown unless there is one
/// (used when the app starts); otherwise the answer is always shown.
Future<void> checkAndPrompt(BuildContext context, {required bool silent}) async {
  final current = (await PackageInfo.fromPlatform()).version;
  if (!context.mounted) return;
  if (!silent) toast(context, tr(context, 'checkingUpdate'));
  UpdateInfo? found;
  try {
    found = await checkForUpdate(current);
  } catch (_) {}
  if (!context.mounted) return;
  if (!silent) ScaffoldMessenger.of(context).hideCurrentSnackBar();
  if (found != null && found.newer) {
    await _offer(context, found);
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

Future<void> _offer(BuildContext context, UpdateInfo info) async {
  final choice = await showDialog<String>(
    context: context,
    builder: (dialog) => AlertDialog(
      icon: const Icon(Icons.system_update),
      title: Text(tr(dialog, 'updateAvailable', {'v': info.version})),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(MaterialLocalizations.of(dialog).closeButtonLabel)),
        TextButton(
            onPressed: () => Navigator.pop(dialog, 'page'),
            child: Text(tr(dialog, 'updateOpen'))),
        FilledButton(
            onPressed: () => Navigator.pop(dialog, 'install'),
            child: Text(tr(dialog, 'updateInstall'))),
      ],
    ),
  );
  if (choice == 'page') {
    await openLink(info.url);
  } else if (choice == 'install' && context.mounted) {
    await _install(context, info);
  }
}

/// Downloads the file made for this device and starts its installer.
Future<void> _install(BuildContext context, UpdateInfo info) async {
  final asset = await pickAsset(info);
  if (asset == null) {
    await openLink(info.url);
    return;
  }
  // Android: the permission to install apps is asked for before anything is downloaded.
  if (!Platform.isWindows && !await _allowInstalls(context)) return;
  if (!context.mounted) return;
  final progress = ValueNotifier<_Progress>(const _Progress(0, -1, 0));
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialog) => AlertDialog(
      title: Text(tr(dialog, 'updateDownloading')),
      content: ValueListenableBuilder<_Progress>(
        valueListenable: progress,
        builder: (_, p, __) {
          final share = p.total > 0 ? p.received / p.total : null;
          return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(asset.name, textDirection: TextDirection.ltr, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: share),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text(share == null ? '' : '${(share * 100).round()}%'),
              Text(
                p.total > 0
                    ? '${_size(p.received)} / ${_size(p.total)}'
                    : _size(p.received),
                textDirection: TextDirection.ltr,
              ),
            ]),
            const SizedBox(height: 4),
            Text('${_size(p.speed.round())}/s', textDirection: TextDirection.ltr),
          ]);
        },
      ),
    )
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
    });
  } catch (_) {}
  if (!context.mounted) return;
  Navigator.of(context, rootNavigator: true).pop();
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
