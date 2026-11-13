import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/app_log.dart';
import 'package:kumo/screens/logs_page.dart' show logLineText;

void main() {
  test('a line is written to the file and read back with its level and its subject', () {
    final e = LogEntry(DateTime.fromMillisecondsSinceEpoch(1700000000000), 'Real delay of A|B: timeout',
        level: LogLevel.warn, tag: LogTag.test);
    final back = LogEntry.decode(e.encode())!;
    expect(back.time, e.time);
    expect(back.text, 'Real delay of A|B: timeout');
    expect(back.level, LogLevel.warn);
    expect(back.tag, LogTag.test);
  });

  test('a line of an older version (time and text only) is still read, its level told from the text', () {
    final e = LogEntry.decode('1700000000000|Could not start the connection: x')!;
    expect(e.text, 'Could not start the connection: x');
    expect(e.level, LogLevel.error);
    expect(e.tag, LogTag.connection);
    expect(LogEntry.decode('not a line'), isNull);
    expect(LogEntry.decode(''), isNull);
  });

  test('a new line in the text does not break the file', () {
    final e = LogEntry(DateTime.fromMillisecondsSinceEpoch(5), 'a\nb', level: LogLevel.info, tag: LogTag.app);
    expect(e.encode().contains('\n'), isFalse);
    expect(LogEntry.decode(e.encode())!.text, 'a b');
  });

  test('the level and the subject of a line written without them', () {
    expect(guessLogLevel('Connected'), LogLevel.info);
    expect(guessLogLevel('Real delay test failed'), LogLevel.error);
    expect(guessLogLevel('Server X stopped answering, switching to Y'), LogLevel.warn);
    expect(guessLogLevel('  result: -1'), LogLevel.debug);
    expect(guessLogTag('Tested 12 servers in Manual configs: 3 answered'), LogTag.test);
    expect(guessLogTag('Connecting to X'), LogTag.connection);
    expect(guessLogTag('The saved subscriptions were skipped: x'), LogTag.servers);
    expect(guessLogTag('Kumo opened on android 14'), LogTag.app);
  });

  test('warnings and errors are the problems', () {
    LogEntry of(LogLevel l) => LogEntry(DateTime(2026), 'x', level: l, tag: LogTag.app);
    expect(of(LogLevel.error).isProblem, isTrue);
    expect(of(LogLevel.warn).isProblem, isTrue);
    expect(of(LogLevel.info).isProblem, isFalse);
    expect(of(LogLevel.debug).isProblem, isFalse);
  });

  test('a copied line carries the time, the level and the subject', () {
    final e = LogEntry(DateTime(2026, 11, 13, 9, 5, 7), 'Connected in 420 ms', level: LogLevel.info, tag: LogTag.connection);
    expect(logLineText(e), '11-13 09:05:07 INFO  [connection] Connected in 420 ms');
  });
}
