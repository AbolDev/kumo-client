import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/error_hint.dart';

void main() {
  test('the usual failures get a plain reason', () {
    expect(errorHintKey('dial tcp 1.2.3.4:443: i/o timeout'), 'errHintTimeout');
    expect(errorHintKey('context deadline exceeded'), 'errHintTimeout');
    expect(errorHintKey('dial tcp 1.2.3.4:443: connect: connection refused'), 'errHintRefused');
    expect(errorHintKey('lookup example.com: no such host'), 'errHintDns');
    expect(errorHintKey('x509: certificate signed by unknown authority'), 'errHintTls');
    expect(errorHintKey('connect: network is unreachable'), 'errHintNetwork');
    expect(errorHintKey('authentication failed'), 'errHintAuth');
    expect(errorHintKey('json: unknown field "x"'), 'errHintConfig');
    expect(errorHintKey('VPN permission was not granted'), 'errHintPermission');
  });

  test('nothing is said for what the user did, or what is not known', () {
    expect(errorHintKey('revoked'), isNull);
    expect(errorHintKey(''), isNull);
    expect(errorHintKey(null), isNull);
    expect(errorHintKey('something nobody expected'), isNull);
  });

  test('a message with no plain reason is cut to its first line', () {
    expect(shortReason('first line\nsecond line'), 'first line');
    expect(shortReason(null), '');
    final cut = shortReason('x' * 200, max: 20);
    expect(cut.length, 20);
    expect(cut.endsWith('…'), isTrue);
  });
}
