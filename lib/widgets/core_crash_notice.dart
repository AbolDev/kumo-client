import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/vpn_channel.dart';
import '../l10n/extra.dart';

/// The part of the core's error output that says what happened and where: from the first line of the panic or the
/// fatal error to [limit] characters. What comes before it (ordinary messages of the core) is left out.
String coreCrashExcerpt(String text, {int limit = 6000}) {
  final clean = text.replaceAll('\u0000', '');
  final starts = [
    for (final mark in const ['kumo: panic', 'panic:', 'fatal error:', 'SIGSEGV', 'SIGABRT', 'unexpected signal'])
      clean.indexOf(mark),
  ].where((i) => i >= 0);
  final from = starts.isEmpty ? 0 : starts.reduce((a, b) => a < b ? a : b);
  final rest = clean.substring(from).trim();
  return rest.length > limit ? rest.substring(0, limit) : rest;
}

/// On Android the core runs inside the app, so an error in it closes the app with nothing said. The core leaves
/// its last words in a file; the next time the app is opened this shows them once, with a button to copy them.
class CoreCrashNotice extends StatefulWidget {
  const CoreCrashNotice({super.key, required this.child});

  final Widget child;

  @override
  State<CoreCrashNotice> createState() => _CoreCrashNoticeState();
}

class _CoreCrashNoticeState extends State<CoreCrashNotice> {
  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) _check();
  }

  Future<void> _check() async {
    final text = await VpnChannel.coreCrash();
    if (text == null || text.trim().isEmpty || !mounted) return;
    var version = '';
    try {
      final p = await PackageInfo.fromPlatform();
      version = '${p.version}+${p.buildNumber}';
    } catch (_) {}
    if (!mounted) return;
    final report = 'Kumo $version, Android ${Platform.operatingSystemVersion}\n\n${coreCrashExcerpt(text)}';
    await showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(tr(dialog, 'coreCrashTitle')),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(tr(dialog, 'coreCrashBody')),
                const SizedBox(height: 12),
                Directionality(
                  textDirection: TextDirection.ltr,
                  child: SelectableText(
                    report.length > 1200 ? '${report.substring(0, 1200)}…' : report,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog), child: Text(tr(dialog, 'coreCrashClose'))),
          FilledButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: report));
              if (!dialog.mounted) return;
              ScaffoldMessenger.maybeOf(dialog)?.showSnackBar(SnackBar(content: Text(tr(dialog, 'coreCrashCopied'))));
            },
            child: Text(tr(dialog, 'coreCrashCopy')),
          ),
        ],
      ),
    );
    await VpnChannel.clearCoreCrash();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
