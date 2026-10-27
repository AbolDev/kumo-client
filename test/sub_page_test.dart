import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/sources.dart';

String page(String data) =>
    '<html><head><script>window.X_UI_BASE_PATH="/subscription/";window.__SUB_PAGE_DATA__=$data;</script></head><body></body></html>';

void main() {
  test('the owner name is read from a 3x-ui information page', () {
    expect(
        pageSubscriptionTitle(page('{"emails":["Test","Test"],"subTitle":"","links":["vless://a@b:1#x"]}')),
        'Test');
    expect(pageSubscriptionTitle(page('{"emails":["a","b","a"],"subTitle":""}')), 'a, b');
  });

  test('a subscription title wins over the user names', () {
    expect(pageSubscriptionTitle(page('{"emails":["Test"],"subTitle":"My plan"}')), 'My plan');
  });

  test('other pages and empty data give no name', () {
    expect(pageSubscriptionTitle('<html><body>hello</body></html>'), isNull);
    expect(pageSubscriptionTitle(page('{"emails":[],"subTitle":""}')), isNull);
    expect(pageSubscriptionTitle(page('not json')), isNull);
  });
}
