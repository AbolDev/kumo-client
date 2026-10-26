import 'dart:io' show Platform;

import 'routing_rules.dart';

/// How apps are routed: everything, only the chosen apps, or everything except them.
enum AppMode { all, only, except }

/// DNS servers the user can pick; every one of them is reached through the proxy.
class DnsPreset {
  const DnsPreset(this.id, this.name, this.address);
  final String id;
  final String name;

  /// `https://host/path` = DNS over HTTPS, `tls://host` = DNS over TLS, otherwise plain UDP.
  final String address;
}

const dnsPresets = [
  DnsPreset('cloudflare', 'Cloudflare', 'https://1.1.1.1/dns-query'),
  DnsPreset('google', 'Google', 'https://8.8.8.8/dns-query'),
  DnsPreset('quad9', 'Quad9', 'https://9.9.9.9/dns-query'),
  DnsPreset('adguard', 'AdGuard', 'https://dns.adguard-dns.com/dns-query'),
  DnsPreset('cloudflare-dot', 'Cloudflare (DoT)', 'tls://1.1.1.1'),
  DnsPreset('google-dot', 'Google (DoT)', 'tls://8.8.8.8'),
];

/// Countries whose sites can go direct (code, English name).
const bypassCountries = {
  'ir': 'Iran',
  'cn': 'China',
  'ru': 'Russia',
  'tr': 'Turkey',
  'ae': 'United Arab Emirates',
  'sa': 'Saudi Arabia',
  'iq': 'Iraq',
  'af': 'Afghanistan',
  'pk': 'Pakistan',
  'in': 'India',
  'bd': 'Bangladesh',
  'eg': 'Egypt',
  'by': 'Belarus',
  'kz': 'Kazakhstan',
  'uz': 'Uzbekistan',
  'az': 'Azerbaijan',
  'ua': 'Ukraine',
  'vn': 'Vietnam',
  'th': 'Thailand',
  'id': 'Indonesia',
  'my': 'Malaysia',
  'kr': 'South Korea',
  'jp': 'Japan',
  'de': 'Germany',
  'fr': 'France',
  'gb': 'United Kingdom',
  'us': 'United States',
  'ca': 'Canada',
  'br': 'Brazil',
  'mx': 'Mexico',
};

/// uTLS fingerprints sing-box knows; '' keeps each config's own choice.
const fingerprints = [
  '',
  'chrome',
  'firefox',
  'safari',
  'edge',
  'ios',
  'android',
  'random',
  'randomized',
];

/// How much the core logs, quietest first; the first is the default.
const logLevels = ['error', 'warn', 'info', 'debug'];

/// Everything in Settings that changes how traffic is carried.
class NetOptions {
  NetOptions();

  /// Tunnel the whole device: on by default on Android, off on Windows. Off: a local proxy only
  /// (on Windows it is also set as the system proxy).
  bool tun = !Platform.isWindows;
  int proxyPort = 2080;

  AppMode appMode = AppMode.all;

  /// Package names on Android, process names (like chrome.exe) on Windows.
  List<String> apps = [];

  /// Two-letter country codes (lower case) whose addresses and sites skip the VPN.
  List<String> bypass = [];

  String dns = 'cloudflare';
  String customDns = '';

  bool tlsFragment = false;
  bool mux = false;
  int mtu = 9000;
  String fingerprint = '';

  /// Log level of the core (sing-box, and Xray when it runs).
  String logLevel = logLevels.first;

  /// Domains and addresses the user sends straight out, or always through the VPN, whatever the
  /// country and app settings say (stored as `example.com` or `10.0.0.0/8`).
  List<String> directRules = [];
  List<String> proxyRules = [];

  /// Share the connection with other devices on the same network: a second proxy that listens on
  /// all addresses, always with a user name and password.
  bool shareLan = false;
  int lanPort = 2081;
  String lanUser = 'kumo';
  String lanPassword = '';

  /// Block the internet when the connection drops instead of leaking the real address.
  bool killSwitch = false;

  /// Move to the next best server when the current one stops answering.
  bool failover = true;

  /// Link of a server every connection goes through first (a proxy chain). Empty = none.
  String chain = '';

  /// Windows: hide to the tray when the window is closed, and start with Windows.
  bool minimizeToTray = true;
  bool startWithWindows = false;

  String get dnsAddress {
    if (dns == 'custom' && customDns.trim().isNotEmpty) return customDns.trim();
    return dnsPresets
        .firstWhere((p) => p.id == dns, orElse: () => dnsPresets.first)
        .address;
  }

  Map<String, dynamic> toJson() => {
        'tun': tun,
        'proxyPort': proxyPort,
        'appMode': appMode.name,
        'apps': apps,
        'bypass': bypass,
        'dns': dns,
        'customDns': customDns,
        'tlsFragment': tlsFragment,
        'mux': mux,
        'mtu': mtu,
        'fingerprint': fingerprint,
        'logLevel': logLevel,
        'directRules': directRules,
        'proxyRules': proxyRules,
        'shareLan': shareLan,
        'lanPort': lanPort,
        'lanUser': lanUser,
        'lanPassword': lanPassword,
        'killSwitch': killSwitch,
        'failover': failover,
        'chain': chain,
        'minimizeToTray': minimizeToTray,
        'startWithWindows': startWithWindows,
      };

  void load(Map<String, dynamic> j) {
    bool flag(String k, bool d) => j[k] is bool ? j[k] as bool : d;
    tun = flag('tun', !Platform.isWindows);
    final port = j['proxyPort'];
    if (port is int && port > 0 && port < 65536) proxyPort = port;
    appMode = AppMode.values.firstWhere((m) => m.name == j['appMode'],
        orElse: () => AppMode.all);
    final list = j['apps'];
    if (list is List) apps = list.whereType<String>().toList();
    final countries = j['bypass'];
    if (countries is List) {
      bypass = countries.whereType<String>().map((c) => c.toLowerCase()).toList();
    } else if (flag('bypassIran', false)) {
      bypass = ['ir'];
    }
    dns = j['dns'] is String ? j['dns'] as String : 'cloudflare';
    customDns = j['customDns'] is String ? j['customDns'] as String : '';
    tlsFragment = flag('tlsFragment', false);
    mux = flag('mux', false);
    final m = j['mtu'];
    if (m is int && m >= 1280 && m <= 65535) mtu = m;
    final fp = j['fingerprint'];
    fingerprint = fp is String && fingerprints.contains(fp) ? fp : '';
    final level = j['logLevel'];
    logLevel = level is String && logLevels.contains(level) ? level : logLevels.first;
    List<String> rules(Object? v) =>
        v is List ? v.whereType<String>().map(normalizeRouteRule).whereType<String>().toList() : [];
    directRules = rules(j['directRules']);
    proxyRules = rules(j['proxyRules']);
    shareLan = flag('shareLan', false);
    final lp = j['lanPort'];
    if (lp is int && lp > 1023 && lp < 65536) lanPort = lp;
    lanUser = j['lanUser'] is String && (j['lanUser'] as String).isNotEmpty
        ? j['lanUser'] as String
        : 'kumo';
    lanPassword = j['lanPassword'] is String ? j['lanPassword'] as String : '';
    killSwitch = flag('killSwitch', false);
    failover = flag('failover', true);
    chain = j['chain'] is String ? j['chain'] as String : '';
    minimizeToTray = flag('minimizeToTray', true);
    startWithWindows = flag('startWithWindows', false);
  }
}
