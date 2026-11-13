/// How much a line of the app's log matters.
enum LogLevel { debug, info, warn, error }

/// What a line of the log is about. The names are the ones written in the file.
enum LogTag { connection, test, servers, core, app }

final _error = RegExp(
    r"could not|couldn't|failed|error|unexpectedly|refused|unreadable|exception|not found|panic|denied",
    caseSensitive: false);
final _warn = RegExp(r'timeout|timed out|skipped|stopped answering|did not|removed|notice:|alert:', caseSensitive: false);

/// The level of a line that was written without one: by what it says.
LogLevel guessLogLevel(String text) {
  if (text.startsWith('  ')) return LogLevel.debug; // the lines of a report under their heading
  if (_error.hasMatch(text)) return LogLevel.error;
  if (_warn.hasMatch(text)) return LogLevel.warn;
  return LogLevel.info;
}

final _tags = <LogTag, RegExp>{
  LogTag.test: RegExp(r'\btest(ed|ing)?\b|real delay|ping|safety check|speed|answered', caseSensitive: false),
  LogTag.connection: RegExp(
      r'connect|disconnect|server .* stopped|switching to|race:|proxy|permission|openvpn|tunnel', caseSensitive: false),
  LogTag.core: RegExp(r'sing-box|xray|\bcore\b|libbox|wireguard:', caseSensitive: false),
  LogTag.servers: RegExp(
      r'config|subscription|list|source|clean-ip|added|imported|restored|saved|lists', caseSensitive: false),
};

/// The subject of a line that was written without one: by what it says.
LogTag guessLogTag(String text) {
  for (final e in _tags.entries) {
    if (e.value.hasMatch(text)) return e.key;
  }
  return LogTag.app;
}

class LogEntry {
  LogEntry(this.time, this.text, {LogLevel? level, LogTag? tag})
      : level = level ?? guessLogLevel(text),
        tag = tag ?? guessLogTag(text);

  final DateTime time;
  final String text;
  final LogLevel level;
  final LogTag tag;

  bool get isProblem => level == LogLevel.warn || level == LogLevel.error;

  /// One line of the log file: the time, the first letter of the level, the subject and the text.
  String encode() => '${time.millisecondsSinceEpoch}|${level.name[0]}|${tag.name}|${text.replaceAll('\n', ' ')}';

  static final _line = RegExp(r'^(\d+)\|([diwe])\|([a-z]+)\|(.*)$');

  /// Reads a line of the log file: the form of [encode], or the older one (`time|text`). Null for anything else.
  static LogEntry? decode(String line) {
    final m = _line.firstMatch(line);
    if (m != null) {
      final time = DateTime.fromMillisecondsSinceEpoch(int.parse(m[1]!));
      final level = LogLevel.values.where((l) => l.name[0] == m[2]).first;
      final tag = LogTag.values.where((t) => t.name == m[3]).firstOrNull;
      // A subject this version does not know: the line is kept whole, under the app.
      if (tag == null) return LogEntry(time, '${m[3]}|${m[4]}', level: level, tag: LogTag.app);
      return LogEntry(time, m[4]!, level: level, tag: tag);
    }
    final i = line.indexOf('|');
    final ms = i > 0 ? int.tryParse(line.substring(0, i)) : null;
    if (ms == null) return null;
    // The older form kept the leading spaces of a report line too.
    return LogEntry(DateTime.fromMillisecondsSinceEpoch(ms), line.substring(i + 1));
  }
}
