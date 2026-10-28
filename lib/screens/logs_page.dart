import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'share_sheet.dart';

String _stamp(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
}

/// What the app did and why a connection failed, newest first.
class LogsPage extends StatelessWidget {
  const LogsPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final t = S.of(context);
    return ListenableBuilder(
      // Each new line of the log is announced on its own, not as a change of the whole app state.
      listenable: Listenable.merge([state, state.logRevision]),
      builder: (context, _) {
        final items = state.logs.reversed.toList();
        return Scaffold(
          appBar: AppBar(
            title: Text(t.logs),
            actions: [
              IconButton(
                tooltip: t.copyLogs,
                icon: const Icon(Icons.copy),
                onPressed: items.isEmpty
                    ? null
                    : () {
                        Clipboard.setData(ClipboardData(
                            text: state.logs
                                .map((e) => '${_stamp(e.time)}  ${e.text}')
                                .join('\n')));
                        toast(context, t.copied);
                      },
              ),
              IconButton(
                tooltip: t.clearLogs,
                icon: const Icon(Icons.delete_outline),
                onPressed: items.isEmpty ? null : state.clearLogs,
              ),
            ],
          ),
          body: items.isEmpty
              ? Center(child: Text(t.logsEmpty))
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const Divider(height: 16),
                  itemBuilder: (context, i) => Directionality(
                    textDirection: TextDirection.ltr,
                    child: SelectableText.rich(TextSpan(children: [
                      TextSpan(
                          text: '${_stamp(items[i].time)}\n',
                          style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant)),
                      TextSpan(
                          text: items[i].text,
                          style: const TextStyle(fontSize: 13)),
                    ])),
                  ),
                ),
        );
      },
    );
  }
}
