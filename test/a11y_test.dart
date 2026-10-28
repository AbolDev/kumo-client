import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/proxy_config.dart';
import 'package:kumo/core/sources.dart';
import 'package:kumo/l10n/strings.dart';
import 'package:kumo/screens/collector_info_page.dart';
import 'package:kumo/screens/connections_page.dart';
import 'package:kumo/screens/dns_leak_page.dart';
import 'package:kumo/screens/edit_config_page.dart';
import 'package:kumo/screens/home_page.dart';
import 'package:kumo/screens/logs_page.dart';
import 'package:kumo/screens/my_ip_page.dart';
import 'package:kumo/screens/onboarding_page.dart';
import 'package:kumo/screens/routing_rules_page.dart';
import 'package:kumo/screens/service_test_page.dart';
import 'package:kumo/screens/settings_page.dart';
import 'package:kumo/screens/subscription_info_page.dart';
import 'package:kumo/screens/troubleshoot_page.dart';
import 'package:kumo/screens/usage_page.dart';
import 'package:kumo/state/app_state.dart';

const _links = [
  'vless://11111111-1111-1111-1111-111111111111@v.example.com:443?security=tls&sni=v.example.com&type=ws&path=%2F#Germany%20CDN',
  'trojan://secret@t.example.com:443?sni=t.example.com#Japan',
  'ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ@s.example.com:8388#Sweden',
];

AppState _state() {
  final s = AppState();
  s.collector.configs.addAll(parseLinks(_links));
  s.collector.configs[0].latencyMs = 120;
  s.collector.configs[1].latencyMs = -1;
  final g = ServerGroup('sub-1', GroupKind.subscription, name: 'My provider', url: 'https://example.com/sub')
    ..info = SubInfo(upload: 1 << 30, download: 3 << 30, total: 50 << 30, expire: DateTime.now().millisecondsSinceEpoch ~/ 1000 + 86400 * 9)
    ..updatedAt = DateTime.now().millisecondsSinceEpoch;
  g.configs.addAll(parseLinks(_links.take(1).toList()));
  s.subscriptions.add(g);
  final today = DateTime.now();
  final key = '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
  s.dayUsage[key] = [5 << 20, 1 << 20, 600];
  s.serverUsage['Germany CDN'] = [5 << 20, 1 << 20, 600, DateTime.now().millisecondsSinceEpoch];
  return s;
}

ThemeData _theme(Brightness b) => ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFF0E9F8E), brightness: b);

Widget _app(Widget home, {Brightness brightness = Brightness.light, double scale = 1}) => MaterialApp(
      theme: _theme(brightness),
      supportedLocales: S.supportedLocales,
      localizationsDelegates: const [
        S.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: home,
    );

void main() {
  final pages = <String, Widget Function(AppState)>{
    'home': (s) => HomePage(state: s),
    'settings': (s) => SettingsPage(state: s),
    'usage': (s) => UsagePage(state: s),
    'collector info': (s) => CollectorInfoPage(state: s),
    'subscription info': (s) => SubscriptionInfoPage(state: s, group: s.subscriptions.first),
    'dns leak': (s) => DnsLeakPage(state: s),
    'my ip': (s) => MyIpPage(state: s),
    'services': (s) => ServiceTestPage(state: s),
    'troubleshoot': (s) => TroubleshootPage(state: s),
    'connections': (s) => ConnectionsPage(state: s),
    'logs': (s) => LogsPage(state: s),
    'onboarding': (s) => OnboardingPage(state: s),
    'routing rules': (s) => RoutingRulesPage(state: s),
    'edit config': (s) => EditConfigPage(config: s.collector.configs.first),
  };

  for (final e in pages.entries) {
    testWidgets('audit: ${e.key}', (tester) async {
      final handle = tester.ensureSemantics();
      tester.view.physicalSize = const Size(420 * 2, 860 * 2);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(e.value(_state())));
      await tester.pump(const Duration(milliseconds: 300));
      final results = <String, Evaluation>{
        'labeled': await labeledTapTargetGuideline.evaluate(tester),
        'android 48dp': await androidTapTargetGuideline.evaluate(tester),
      };
      for (final r in results.entries) {
        if (!r.value.passed) {
          // ignore: avoid_print
          print('FAIL ${e.key} / ${r.key}: ${r.value.reason}');
        }
      }
      final ex = tester.takeException();
      if (ex != null) {
        // ignore: avoid_print
        print('EXCEPTION ${e.key}: $ex');
      }
      await tester.pump(const Duration(seconds: 5));
      handle.dispose();
    });
  }
}
