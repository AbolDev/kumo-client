import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/widgets/core_crash_notice.dart';

void main() {
  test('the report starts at the panic and leaves the messages before it out', () {
    const text = 'ERROR[0001] outbound/vless[proxy]: dial tcp 203.0.113.9:443: i/o timeout\n'
        'panic: runtime error: invalid memory address or nil pointer dereference\n'
        '[signal SIGSEGV: segmentation violation code=0x1 addr=0x0 pc=0x1234]\n\n'
        'goroutine 42 [running]:\n'
        'github.com/sagernet/sing-box/transport/wireguard.(*Endpoint).Start(...)\n';
    final report = coreCrashExcerpt(text);
    expect(report.startsWith('panic: runtime error'), isTrue);
    expect(report.contains('203.0.113.9'), isFalse);
    expect(report.contains('wireguard.(*Endpoint).Start'), isTrue);
  });

  test('a fatal error and a recovered panic of a test core are found too', () {
    expect(coreCrashExcerpt('x\nfatal error: stack overflow\n\ngoroutine 1 [running]:\n'),
        startsWith('fatal error: stack overflow'));
    expect(coreCrashExcerpt('x\nkumo: panic in a test core: boom\n\ngoroutine 0 [recovered]:\n'),
        startsWith('kumo: panic in a test core: boom'));
  });

  test('the report is cut to the limit and has no NUL bytes', () {
    final report = coreCrashExcerpt('\u0000\u0000panic: x\n${'a' * 9000}', limit: 100);
    expect(report.length, 100);
    expect(report.contains('\u0000'), isFalse);
  });

  test('with no mark the text is given as it is', () {
    expect(coreCrashExcerpt('  goroutine 7 [select]:\n  '), 'goroutine 7 [select]:');
  });
}
