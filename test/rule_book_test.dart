import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/routing_rules.dart';
import 'package:kumo/core/rule_book.dart';

RuleLists _book() => RuleLists(
      block: ['keyword:ads', 'app:com.annoying'],
      proxy: ['service:telegram', 'port:8443', '2001:db8::/32'],
      direct: ['example.com', 'full:www.bank.ir', '10.0.0.0/8', 'port:1000-2000', r'regex:(?i)^cdn[0-9]+\.', 'telegram.org'],
    );

RuleAction? _first(String q, {Map<String, String> apps = const {}}) {
  final hits = matchRules(_book(), q, appNames: apps);
  return hits.isEmpty ? null : hits.first.action;
}

void main() {
  group('typing a rule', () {
    test('a bare port is a port, anything else reads as before', () {
      expect(parseUserRule('443')!.text, 'port:443');
      expect(parseUserRule(' 1000 - 2000 ')!.text, 'port:1000-2000');
      expect(parseUserRule('70000'), isNull);
      expect(parseUserRule('https://www.Example.com/page')!.text, 'www.example.com');
      expect(parseUserRule('10.1.2.3')!.text, '10.1.2.3/32');
      expect(parseUserRule('keyword:ads')!.kind, RuleKind.keyword);
      expect(parseUserRule('not a rule!'), isNull);
      expect(parseUserRule('   '), isNull);
    });

    test('adding leaves out what is there already, and keeps the order', () {
      expect(withRules(['a.com', 'b.com'], ['b.com', 'c.com', 'c.com']), ['a.com', 'b.com', 'c.com']);
    });
  });

  group('export and import', () {
    test('what is exported comes back the same', () {
      final text = exportRules(_book());
      expect(text, contains('[block]'));
      expect(text, contains('[proxy]'));
      expect(text, contains('[direct]'));
      final back = parseRulesText(text);
      expect(back.skipped, 0);
      expect(back.rules.block, _book().block);
      expect(back.rules.proxy, _book().proxy);
      expect(back.rules.direct, _book().direct);
    });

    test('an empty list has no section', () {
      final text = exportRules(RuleLists(proxy: ['a.com']));
      expect(text, isNot(contains('[block]')));
      expect(text, isNot(contains('[direct]')));
      expect(parseRulesText(exportRules(RuleLists())).count, 0);
    });

    test('sections may be written in other ways, and lines that are not rules are counted', () {
      final r = parseRulesText('''
# my rules
[Block]
ads.example.com
[VPN]
service:youtube
443
[unknown]
whatever.com
[direct]
???
bank.ir
bank.ir
''');
      expect(r.rules.block, ['ads.example.com']);
      expect(r.rules.proxy, ['service:youtube', 'port:443']);
      expect(r.rules.direct, ['bank.ir']);
      // "whatever.com" is under a section that does not exist, and "???" is no rule.
      expect(r.skipped, 2);
      expect(r.count, 4);
    });

    test('lines before any section go to the chosen action', () {
      expect(parseRulesText('a.com\nb.com').rules.direct, ['a.com', 'b.com']);
      expect(parseRulesText('a.com', fallback: RuleAction.block).rules.block, ['a.com']);
    });

    test('windows line ends do not matter', () {
      expect(parseRulesText('[block]\r\na.com\r\n').rules.block, ['a.com']);
    });
  });

  group('testing what a rule does', () {
    test('a website and its sub-sites, an exact name, a word, a pattern', () {
      expect(_first('example.com'), RuleAction.direct);
      expect(_first('https://deep.sub.example.com/x?y=1'), RuleAction.direct);
      expect(_first('notexample.com'), isNull);
      expect(_first('www.bank.ir'), RuleAction.direct);
      expect(_first('login.www.bank.ir'), isNull);
      expect(_first('ads.something.org'), RuleAction.block);
      expect(_first('cdn42.site.org'), RuleAction.direct);
      expect(_first('CDN42.site.org'), RuleAction.direct);
      expect(_first('xcdn42.site.org'), isNull);
    });

    test('a service is all its names, and can be asked for by its name', () {
      expect(_first('t.me'), RuleAction.proxy);
      expect(_first('web.telegram.me'), RuleAction.proxy);
      expect(_first('telegram'), RuleAction.proxy);
      expect(_first('service:telegram'), RuleAction.proxy);
      expect(_first('youtube.com'), isNull);
    });

    test('an address is inside a network, for IPv4 and IPv6', () {
      expect(_first('10.20.30.40'), RuleAction.direct);
      expect(_first('11.0.0.1'), isNull);
      expect(_first('2001:db8:1::5'), RuleAction.proxy);
      expect(_first('2001:db9::1'), isNull);
    });

    test('a port, alone or after a name or an address', () {
      expect(_first('8443'), RuleAction.proxy);
      expect(_first('1500'), RuleAction.direct);
      expect(_first('2001'), isNull);
      expect(_first('somewhere.org:8443'), RuleAction.proxy);
      expect(_first('https://somewhere.org:1500/path'), RuleAction.direct);
      expect(_first('1.2.3.4:1999'), RuleAction.direct);
      expect(_first('99999'), isNull);
    });

    test('an app is found by its package, by app:, or by the name it is shown with', () {
      expect(_first('com.annoying'), RuleAction.block);
      expect(_first('COM.Annoying'), RuleAction.block);
      expect(_first('app:com.annoying'), RuleAction.block);
      expect(_first('annoying game', apps: {'com.annoying': 'Annoying Game'}), RuleAction.block);
      expect(_first('annoying game'), isNull);
    });

    test('the first of block, VPN, direct decides, and the others are listed after it', () {
      final lists = RuleLists(
        block: ['keyword:telegram'],
        proxy: ['service:telegram'],
        direct: ['telegram.org'],
      );
      final hits = matchRules(lists, 'telegram.org');
      expect([for (final h in hits) h.action], [RuleAction.block, RuleAction.proxy, RuleAction.direct]);
      expect(hits.first.rule, 'keyword:telegram');
      // Without the block rule the VPN comes before direct.
      lists.block.clear();
      expect(matchRules(lists, 'telegram.org').first.action, RuleAction.proxy);
    });

    test('nothing to test, or nothing that matches, is no hit', () {
      expect(matchRules(_book(), ''), isEmpty);
      expect(matchRules(_book(), '   '), isEmpty);
      expect(matchRules(RuleLists(), 'example.com'), isEmpty);
    });

    test('firstWith tells which list wins when a rule is in several', () {
      final l = RuleLists(proxy: ['a.com'], direct: ['a.com', 'b.com']);
      expect(l.firstWith('a.com'), RuleAction.proxy);
      expect(l.firstWith('b.com'), RuleAction.direct);
      expect(l.firstWith('c.com'), isNull);
    });
  });
}
