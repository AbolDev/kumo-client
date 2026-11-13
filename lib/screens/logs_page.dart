import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/app_log.dart';
import '../core/usage/crash_scrub.dart' show scrubText;
import '../l10n/extra.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'share_sheet.dart';

String _two(int n) => n.toString().padLeft(2, '0');

String _clock(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';

String _day(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

String _stamp(DateTime d) => '${_two(d.month)}-${_two(d.day)} ${_clock(d)}';

/// A line as it is copied: the time, the level, the subject and the text.
String logLineText(LogEntry e) => '${_stamp(e.time)} ${e.level.name.toUpperCase().padRight(5)} [${e.tag.name}] ${e.text}';

IconData _levelIcon(LogLevel l) => switch (l) {
      LogLevel.error => Icons.error_outline,
      LogLevel.warn => Icons.warning_amber_outlined,
      LogLevel.info => Icons.info_outline,
      LogLevel.debug => Icons.notes,
    };

Color _levelColor(LogLevel l, ColorScheme scheme) => switch (l) {
      LogLevel.error => scheme.error,
      LogLevel.warn => Colors.orange.shade800,
      LogLevel.info => scheme.primary,
      LogLevel.debug => scheme.onSurfaceVariant,
    };

IconData _tagIcon(LogTag t) => switch (t) {
      LogTag.connection => Icons.power_settings_new,
      LogTag.test => Icons.speed,
      LogTag.servers => Icons.dns_outlined,
      LogTag.core => Icons.memory,
      LogTag.app => Icons.apps,
    };

String _tagKey(LogTag t) => switch (t) {
      LogTag.connection => 'logsTagConnection',
      LogTag.test => 'logsTagTest',
      LogTag.servers => 'logsTagServers',
      LogTag.core => 'logsTagCore',
      LogTag.app => 'logsTagApp',
    };

/// What the app did and why something failed, newest first: every line with its time, how much it matters and
/// what it is about. Can be searched, cut down to the problems or to one subject, and copied (one line by a tap,
/// or all that is shown with the version and the system, for a bug report).
class LogsPage extends StatefulWidget {
  const LogsPage({super.key, required this.state});

  final AppState state;

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  var _onlyProblems = false;
  var _details = true;
  LogTag? _tag;
  var _query = '';

  AppState get state => widget.state;

  bool _fits(LogEntry e, {bool ignoreTag = false}) {
    if (_onlyProblems && !e.isProblem) return false;
    if (!_details && e.level == LogLevel.debug) return false;
    if (!ignoreTag && _tag != null && e.tag != _tag) return false;
    final q = _query.trim().toLowerCase();
    return q.isEmpty || e.text.toLowerCase().contains(q);
  }

  List<LogEntry> _shown() => [
        for (final e in state.logs.reversed)
          if (_fits(e)) e
      ];

  String _plain(List<LogEntry> items) => items.reversed.map(logLineText).join('\n');

  /// The lines shown, oldest first, under the version of the app and the system: what is needed to look
  /// into a problem. Links, addresses and the like are taken out first (as in the reports of crashes).
  Future<String> _report(List<LogEntry> items) async {
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
      'Core: ${state.net.core} · ${state.net.tun ? 'whole device' : 'proxy only'}',
    ].join('\n');
    return '$header\n\n${scrubText(_plain(items))}';
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) toast(context, S.of(context).copied, kind: ToastKind.ok);
  }

  Future<void> _confirmClear() async {
    final t = S.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(tr(dialog, 'logsClearQuestion')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(t.cancel)),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(t.clearLogs)),
        ],
      ),
    );
    if (ok == true) state.clearLogs();
  }

  Widget _chips(BuildContext context, List<LogEntry> all) {
    final problems = all.where((e) => e.isProblem).length;
    // How many lines each subject has under the other filters, so that a chip says what it would show.
    final perTag = <LogTag, int>{};
    for (final e in all) {
      if (_fits(e, ignoreTag: true)) perTag[e.tag] = (perTag[e.tag] ?? 0) + 1;
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(children: [
        FilterChip(
          key: const ValueKey('logs-problems'),
          avatar: const Icon(Icons.error_outline, size: 18),
          label: Text('${tr(context, 'logsOnlyProblems')} · $problems'),
          selected: _onlyProblems,
          onSelected: (v) => setState(() => _onlyProblems = v),
        ),
        const SizedBox(width: 8),
        FilterChip(
          key: const ValueKey('logs-details'),
          avatar: const Icon(Icons.notes, size: 18),
          label: Text(tr(context, 'logsDetails')),
          selected: _details,
          onSelected: (v) => setState(() => _details = v),
        ),
        for (final tag in LogTag.values)
          if ((perTag[tag] ?? 0) > 0 || _tag == tag)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 8),
              child: FilterChip(
                key: ValueKey('logs-tag-${tag.name}'),
                avatar: Icon(_tagIcon(tag), size: 18),
                label: Text('${tr(context, _tagKey(tag))} · ${perTag[tag] ?? 0}'),
                selected: _tag == tag,
                onSelected: (v) => setState(() => _tag = v ? tag : null),
              ),
            ),
      ]),
    );
  }

  Widget _row(BuildContext context, LogEntry e, {required bool newDay}) {
    final scheme = Theme.of(context).colorScheme;
    final color = _levelColor(e.level, scheme);
    final detail = e.level == LogLevel.debug;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (newDay)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(_day(e.time),
              textDirection: TextDirection.ltr,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
        ),
      InkWell(
        // A tap copies the line; the text can still be read out and is not a trap for the keyboard.
        onTap: () => _copy(logLineText(e)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: EdgeInsetsDirectional.fromSTEB(detail ? 40 : 16, 6, 16, 6),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(_levelIcon(e.level), size: 16, color: color, semanticLabel: e.level.name),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (!detail)
                      Text('${_clock(e.time)} · ${tr(context, _tagKey(e.tag))}',
                          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
                    Text(
                      detail ? e.text.trimLeft() : e.text,
                      style: TextStyle(
                        fontSize: detail ? 12 : 13,
                        fontFamily: detail ? 'monospace' : null,
                        color: e.level == LogLevel.error
                            ? scheme.error
                            : detail
                                ? scheme.onSurfaceVariant
                                : null,
                      ),
                    ),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
    ]);
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
            title: Text(all.isEmpty ? t.logs : '${t.logs} (${items.length}/${all.length})'),
            actions: [
              IconButton(
                tooltip: tr(context, 'logsCopyReport'),
                icon: const Icon(Icons.bug_report_outlined),
                onPressed: items.isEmpty ? null : () async => _copy(await _report(items)),
              ),
              IconButton(
                tooltip: t.copyLogs,
                icon: const Icon(Icons.copy),
                onPressed: items.isEmpty ? null : () => _copy(_plain(items)),
              ),
              IconButton(
                tooltip: t.clearLogs,
                icon: const Icon(Icons.delete_outline),
                onPressed: all.isEmpty ? null : _confirmClear,
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
                  Align(alignment: AlignmentDirectional.centerStart, child: _chips(context, all)),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(tr(context, 'logsTapHint'),
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                    ),
                  ),
                  Expanded(
                    child: items.isEmpty
                        ? Center(child: Text(tr(context, 'logsNoMatch')))
                        : ListView.builder(
                            padding: const EdgeInsets.only(bottom: 24),
                            itemCount: items.length,
                            itemBuilder: (context, i) => _row(context, items[i],
                                newDay: i == 0 || _day(items[i].time) != _day(items[i - 1].time)),
                          ),
                  ),
                ]),
        );
      },
    );
  }
}
