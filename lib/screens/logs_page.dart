import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/usage/crash_scrub.dart' show scrubText;
import '../l10n/extra.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'share_sheet.dart';

String _stamp(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
}

/// Lines that say something went wrong.
final _problem = RegExp(
    r"could not|couldn't|failed|error|unexpectedly|refused|timeout|timed out|unreadable|exception|skipped|not found",
    caseSensitive: false);

/// What the app did and why a connection failed, newest first. Can be searched and cut down to the lines
/// that tell of a problem, and copied with the version and the system for a bug report.
class LogsPage extends StatefulWidget {
  const LogsPage({super.key, required this.state});

  final AppState state;

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  var _onlyProblems = false;
  var _query = '';

  AppState get state => widget.state;

  List<LogEntry> _shown() {
    final q = _query.trim().toLowerCase();
    return [
      for (final e in state.logs.reversed)
        if ((!_onlyProblems || _problem.hasMatch(e.text)) && (q.isEmpty || e.text.toLowerCase().contains(q))) e
    ];
  }

  /// The lines shown, oldest first, under the version of the app and the system: what is needed to look
  /// into a problem. Links, addresses and the like are taken out first (as in the reports of crashes).
  Future<void> _copyReport(List<LogEntry> items) async {
    var version = '';
    try {
      final p = await PackageInfo.fromPlatform();
      version = '${p.version}+${p.buildNumber}';
    } catch (_) {}
    const build = String.fromEnvironment('KUMO_BUILD');
    final header = [
      'Kumo $version',
      if (build.isNotEmpty) build,
      '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'Language: ${state.languageCode ?? Platform.localeName}',
    ].join('\n');
    final lines = items.reversed.map((e) => '${_stamp(e.time)}  ${e.text}').join('\n');
    await Clipboard.setData(ClipboardData(text: '$header\n\n${scrubText(lines)}'));
    if (mounted) toast(context, S.of(context).copied, kind: ToastKind.ok);
  }

  @override
  Widget build(BuildContext context) {
    final t = S.of(context);
    return ListenableBuilder(
      // Each new line of the log is announced on its own, not as a change of the whole app state.
      listenable: Listenable.merge([state, state.logRevision]),
      builder: (context, _) {
        final all = state.logs;
        final items = _shown();
        return Scaffold(
          appBar: AppBar(
            title: Text(t.logs),
            actions: [
              IconButton(
                tooltip: tr(context, 'logsCopyReport'),
                icon: const Icon(Icons.bug_report_outlined),
                onPressed: items.isEmpty ? null : () => _copyReport(items),
              ),
              IconButton(
                tooltip: t.copyLogs,
                icon: const Icon(Icons.copy),
                onPressed: items.isEmpty
                    ? null
                    : () {
                        Clipboard.setData(ClipboardData(text: items.reversed.map((e) => '${_stamp(e.time)}  ${e.text}').join('\n')));
                        toast(context, t.copied, kind: ToastKind.ok);
                      },
              ),
              IconButton(
                tooltip: t.clearLogs,
                icon: const Icon(Icons.delete_outline),
                onPressed: all.isEmpty ? null : state.clearLogs,
              ),
            ],
          ),
          body: all.isEmpty
              ? Center(child: Text(t.logsEmpty))
              : Column(children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: TextField(
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: tr(context, 'logsSearch'),
                        prefixIcon: const Icon(Icons.search),
                        filled: true,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: BorderSide.none),
                      ),
                      onChanged: (v) => setState(() => _query = v),
                    ),
                  ),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                      child: FilterChip(
                        avatar: const Icon(Icons.error_outline, size: 18),
                        label: Text(tr(context, 'logsOnlyProblems')),
                        selected: _onlyProblems,
                        onSelected: (v) => setState(() => _onlyProblems = v),
                      ),
                    ),
                  ),
                  Expanded(
                    child: items.isEmpty
                        ? Center(child: Text(tr(context, 'logsNoMatch')))
                        : ListView.separated(
                            padding: const EdgeInsets.all(12),
                            itemCount: items.length,
                            separatorBuilder: (_, __) => const Divider(height: 16),
                            itemBuilder: (context, i) => Directionality(
                              textDirection: TextDirection.ltr,
                              child: SelectableText.rich(TextSpan(children: [
                                TextSpan(
                                    text: '${_stamp(items[i].time)}\n',
                                    style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                                TextSpan(
                                    text: items[i].text,
                                    style: TextStyle(
                                        fontSize: 13,
                                        color: _problem.hasMatch(items[i].text) ? Theme.of(context).colorScheme.error : null)),
                              ])),
                            ),
                          ),
                  ),
                ]),
        );
      },
    );
  }
}
