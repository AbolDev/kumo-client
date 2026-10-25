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
  if (!context.mounted) return;
  final progress = ValueNotifier<double>(0);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialog) => AlertDialog(
      title: Text(tr(dialog, 'updateDownloading')),
      content: ValueListenableBuilder<double>(
        valueListenable: progress,
        builder: (_, v, __) => Column(mainAxisSize: MainAxisSize.min, children: [
          LinearProgressIndicator(value: v > 0 ? v : null),
          const SizedBox(height: 8),
          Text('${(v * 100).round()}%'),
        ]),
      ),
    ),
  );
  String? path;
  try {
    path = await downloadUpdate(asset.url, asset.name, (v) => progress.value = v);
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