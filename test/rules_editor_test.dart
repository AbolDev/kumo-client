import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/net_options.dart';
import 'package:kumo/core/proxy_config.dart';
import 'package:kumo/core/routing_rules.dart';
import 'package:kumo/core/rule_services.dart';
import 'package:kumo/core/singbox_config.dart';
import 'package:kumo/l10n/strings.dart';
import 'package:kumo/screens/routing_rules_page.dart';
import 'package:kumo/state/app_state.dart';

final _server = parseLink('trojan://secret@example.com:443?security=tls&sni=example.com#t')!;

Map<String, dynamic> _config(NetOptions o, {required bool windows}) =>
    jsonDecode(buildSingBoxConfig([_server], options: o, windows: windows)) as Map<String, dynamic>;

List<Map<String, dynamic>> _routeRules(Map<String, dynamic> c) =>
    [for (final r in (c['route'] as Map)['rules'] as List) r as Map<String, dynamic>];

void main() {
  group('rules about apps and services', () {
    test('an app and a service are rules like the others, and keep what they were written as', () {
      expect(normalizeRouteRule('app:org.telegram.messenger'), 'app:org.telegram.messenger');
      expect(normalizeRouteRule('app:Chrome.exe'), 'app:Chrome.exe');
      expect(normalizeRouteRule('app:My Program.exe'), 'app:My Program.exe');
      expect(normalizeRouteRule('app:'), isNull);
      expect(normalizeRouteRule('service:telegram'), 'service:telegram');
      expect(normalizeRouteRule('SERVICE:Telegram'), 'service:telegram');
      expect(normalizeRouteRule('service:nothing-like-it'), isNull);
      expect(parseRouteRule('app:a.b')!.kind, RuleKind.app);
      expect(parseRouteRule('service:youtube')!.kind, RuleKind.service);
    });

    test('every service has a name, a group and domains that are really domains', () {
      expect(ruleServiceList.map((s) => s.id).toSet().length, ruleServiceList.length);
      for (final s in ruleServiceList) {
        expect(s.name, isNotEmpty);
        expect(s.group, startsWith('ruleGroup'));
        expect(s.domains, isNotEmpty, reason: s.id);
        for (final d in s.domains) {
          expect(normalizeRouteRule(d), d, reason: '${s.id}: $d');
        }
      }
    });

    test('on the phone an app is told by its package, and a service is all its domains', () {
      final o = NetOptions()
        ..tun = true
        ..directRules = ['app:com.bank.app', 'service:telegram']
        ..proxyRules = ['app:org.browser']
        ..blockRules = ['app:com.annoying'];
      final rules = _routeRules(_config(o, windows: false));
      expect(rules, contains(allOf(containsPair('package_name', ['com.annoying']), containsPair('action', 'reject'))));
      expect(rules, contains(allOf(containsPair('package_name', ['org.browser']), containsPair('outbound', 'proxy'))));
      expect(rules, contains(allOf(containsPair('package_name', ['com.bank.app']), containsPair('outbound', 'direct'))));
      final telegram = rules.firstWhere((r) => r['domain_suffix'] is List && (r['domain_suffix'] as List).contains('t.me'));
      expect(telegram['outbound'], 'direct');
      expect(telegram['domain_suffix'], containsAll(ruleServices['telegram']!.domains));
      expect(rules.any((r) => r.containsKey('process_name')), isFalse);
      expect(((_config(o, windows: false)['route']) as Map).containsKey('find_process'), isFalse);
    });

    test('on a computer an app is told by its program, and the core is asked to find it', () {
      final o = NetOptions()
        ..tun = true
        ..directRules = ['app:chrome.exe'];
      final c = _config(o, windows: true);
      expect(_routeRules(c), contains(allOf(containsPair('process_name', ['chrome.exe']), containsPair('outbound', 'direct'))));
      expect((c['route'] as Map)['find_process'], isTrue);
      expect(_routeRules(c).any((r) => r.containsKey('package_name')), isFalse);
    });

    test('apps are not in the rules of names (DNS)', () {
      final o = NetOptions()
        ..tun = true
        ..directRules = ['app:chrome.exe', 'example.com']
        ..blockRules = ['app:com.annoying'];
      for (final windows in [true, false]) {
        final dns = (_config(o, windows: windows)['dns'] as Map)['rules'] as List;
        for (final r in dns) {
          expect((r as Map).containsKey('process_name'), isFalse);
          expect(r.containsKey('package_name'), isFalse);
        }
      }
    });
  });

  group('adding a rule from a list', () {
    Widget host() => MaterialApp(
          supportedLocales: S.supportedLocales,
          localizationsDelegates: const [
            S.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          home: RoutingRulesPage(state: AppState()),
        );

    testWidgets('the sheet offers every kind, and the services are in groups to tick', (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      // Nothing yet: an invitation, not an empty list.
      expect(find.text('No rules yet.'), findsOneWidget);
      await tester.tap(find.text('Add a rule').first);
      await tester.pumpAndSettle();
      for (final title in ['A popular service', 'A website', 'An IP address or range', 'A port', 'Advanced']) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
      await tester.tap(find.text('A popular service'));
      await tester.pumpAndSettle();
      expect(find.text('Choose services'), findsOneWidget);
      expect(find.text('Social and messages'), findsOneWidget);
      expect(find.text('Choose what to add'), findsOneWidget);
      await tester.tap(find.text('Telegram'));
      await tester.tap(find.text('YouTube'));
      await tester.pump();
      expect(find.text('Add 2'), findsOneWidget);
      // The search narrows the list.
      await tester.enterText(find.byType(TextField), 'spot');
      await tester.pump();
      expect(find.text('Spotify'), findsOneWidget);
      expect(find.text('Telegram'), findsNothing);
    });
  });
}
