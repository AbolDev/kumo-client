import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/sources.dart';

void main() {
  test('subscription-userinfo is read, and missing values mean unlimited', () {
    final a =
        SubInfo.parse('upload=10; download=20; total=1000; expire=1893456000')!;
    expect(a.used, 30);
    expect(a.total, 1000);
    expect(a.unlimitedData, isFalse);
    expect(a.unlimitedTime, isFalse);

    final b = SubInfo.parse('upload=0; download=5; total=0; expire=0')!;
    expect(b.unlimitedData, isTrue);
    expect(b.unlimitedTime, isTrue);

    expect(SubInfo.parse(null), isNull);
    expect(SubInfo.parse('garbage'), isNull);
  });

  test('provider titles are decoded', () {
    expect(subscriptionTitle('base64:S3VtbyBWUE4=', null, ''), 'Kumo VPN');
    expect(subscriptionTitle(null, 'attachment; filename="My%20Sub.txt"', ''),
        'My Sub');
    expect(subscriptionTitle(null, null, '#profile-title: Hello\nvless://x'),
        'Hello');
  });
}
