import 'dart:io' show Platform;

import 'routing_rules.dart';

/// How apps are routed: everything, only the chosen apps, or everything except them.
enum AppMode { all, only, except }

/// DNS servers the user can pick; every one of them is reached through the proxy.
class DnsPreset {
  const DnsPreset(this.id, this.name, this.address);
  final String id;
  final String name;

  /// `https://host/path` = DNS over HTTPS, `h3://host/path` = DoH over HTTP/3, `tls://host` =
  /// DNS over TLS, `quic://host` = DNS over QUIC, `tcp://host` = plain DNS over TCP, otherwise
  /// plain UDP.
  final String address;
}

const dnsPresets = [
  DnsPreset('cloudflare', 'Cloudflare', 'https://1.1.1.1/dns-query'),
  DnsPreset('google', 'Google', 'https://8.8.8.8/dns-query'),
  DnsPreset('quad9', 'Quad9', 'https://9.9.9.9/dns-query'),
  DnsPreset('adguard', 'AdGuard', 'https://dns.adguard-dns.com/dns-query'),
  DnsPreset('cloudflare-dot', 'Cloudflare (DoT)', 'tls://1.1.1.1'),
  DnsPreset('google-dot', 'Google (DoT)', 'tls://8.8.8.8'),
  DnsPreset('cloudflare-h3', 'Cloudflare (DoH3)', 'h3://1.1.1.1/dns-query'),
  DnsPreset('adguard-quic', 'AdGuard (DoQ)', 'quic://dns.adguard-dns.com'),
  DnsPreset('cloudflare-tcp', 'Cloudflare (TCP)', 'tcp://1.1.1.1'),
];

/// Multiplexing protocols sing-box offers on the TCP-based outbounds.
const muxProtocols = ['h2mux', 'smux', 'yamux'];

/// Where the CA certificates for checking servers come from.
const certStores = ['system', 'mozilla', 'chrome'];

/// Android: how the phone picks between Wi-Fi and mobile data for the connection.
const networkStrategies = ['default', 'hybrid', 'fallback'];

/// The core a server is run with when both can carry it.
const cores = ['singbox', 'xray'];

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

/// Warnings show what goes wrong (a server that refuses, a rule that fails) without the noise
/// and the extra work of the chattier levels.
const defaultLogLevel = 'warn';

/// Everything in Settings that changes how traffic is carried.
class NetOptions {
  NetOptions();

  /// Tunnel the whole device: on by default on Android, off on the desktop (where it needs
  /// administrator rights). Off: a local proxy only, also set as the system proxy on the desktop.
  bool tun = Platform.isAndroid;
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
  String logLevel = defaultLogLevel;

  /// The core for a server both can carry: sing-box (default) or Xray. A server only one of
  /// them can carry always uses that one. Xray runs one chosen server at a time; the automatic
  /// group is always sing-box.
  String core = cores.first;

  /// Multiplexing protocol when MUX is on, and a TLS record split besides the handshake split.
  String muxProtocol = muxProtocols.first;
  bool tlsRecordFragment = false;

  /// Socket options for the connections to the server.
  bool tcpFastOpen = false;
  bool tcpMultiPath = false;

  /// Seconds to wait for a server to connect; 0 keeps the core's own default.
  int connectTimeout = 0;

  /// The CA list used to check servers (system / mozilla / chrome).
  String certStore = certStores.first;

  /// Look up names with fake addresses (TUN only): the real lookup happens at the server.
  bool fakeIp = false;

  /// Refuse the addresses of advertising and tracking sites (a ready-made list that is
  /// downloaded). Works with the local proxy too, not only the tunnel.
  bool blockAds = false;

  /// Keep every name lookup inside the VPN: the server names and the DNS server itself are
  /// looked up over encrypted DNS instead of the network's own resolver, and DNS over TLS that
  /// would skip the tunnel's resolver is refused.
  bool strictDns = false;

  /// Refuse STUN, which browsers use for WebRTC and which can show the address of the network
  /// instead of the VPN's.
  bool blockStun = false;

  /// Let the core set its own clock from a time server (protocols with time checks need it).
  bool ntp = false;

  /// Android: how Wi-Fi and mobile data are used together.
  String networkStrategy = networkStrategies.first;

  /// Android: the connection stays off (direct) while the phone is on one of these Wi-Fi names.
  List<String> directWifi = [];

  /// Your own JSON, merged into every sing-box proxy outbound and into the stream settings of
  /// the Xray outbound (for options the app has no switch for: fragmenting, final masks ...).
  String extraSingbox = '';
  String extraXray = '';

  /// Domains and addresses the user sends straight out, or always through the VPN, whatever the
  /// country and app settings say (stored as `example.com` or `10.0.0.0/8`).
  List<String> directRules = [];
  List<String> proxyRules = [];

  /// Domains, addresses and ports that are always refused (an ad and tracker block list).
  List<String> blockRules = [];

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

  /// Desktop: the local proxy keeps running after the VPN is turned off (without the tunnel and
  /// without being set as the system proxy).
  bool keepProxy = false;

  /// A login for the local proxy while the tunnel is used or the proxy is kept running. Empty: none.
  String proxyUser = '';
  String proxyPassword = '';

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
        'core': core,
        'muxProtocol': muxProtocol,
        'tlsRecordFragment': tlsRecordFragment,
        'tcpFastOpen': tcpFastOpen,
        'tcpMultiPath': tcpMultiPath,
        'connectTimeout': connectTimeout,
        'certStore': certStore,
        'fakeIp': fakeIp,
        'blockAds': blockAds,
        'strictDns': strictDns,
        'blockStun': blockStun,
        'ntp': ntp,
        'networkStrategy': networkStrategy,
        'directWifi': directWifi,
        'extraSingbox': extraSingbox,
        'extraXray': extraXray,
        'directRules': directRules,
        'proxyRules': proxyRules,
        'blockRules': blockRules,
        'shareLan': shareLan,
        'lanPort': lanPort,
        'lanUser': lanUser,
        'lanPassword': lanPassword,
        'killSwitch': killSwitch,
        'failover': failover,
        'chain': chain,
        'minimizeToTray': minimizeToTray,
        'startWithWindows': startWithWindows,
        'keepProxy': keepProxy,
        'proxyUser': proxyUser,
        'proxyPassword': proxyPassword,
      };

  void load(Map<String, dynamic> j) {
    bool flag(String k, bool d) => j[k] is bool ? j[k] as bool : d;
    tun = flag('tun', Platform.isAndroid);
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
    logLevel = level is String && logLevels.contains(level) ? level : defaultLogLevel;
    List<String> rules(Object? v) =>
        v is List ? v.whereType<String>().map(normalizeRouteRule).whereType<String>().toList() : [];
    directRules = rules(j['directRules']);
    proxyRules = rules(j['proxyRules']);
    blockRules = rules(j['blockRules']);
    String pick(String key, List<String> allowed) =>
        j[key] is String && allowed.contains(j[key]) ? j[key] as String : allowed.first;
    core = pick('core', cores);
    muxProtocol = pick('muxProtocol', muxProtocols);
    certStore = pick('certStore', certStores);
    networkStrategy = pick('networkStrategy', networkStrategies);
    tlsRecordFragment = flag('tlsRecordFragment', false);
    tcpFastOpen = flag('tcpFastOpen', false);
    tcpMultiPath = flag('tcpMultiPath', false);
    fakeIp = flag('fakeIp', false);
    blockAds = flag('blockAds', false);
    strictDns = flag('strictDns', false);
    blockStun = flag('blockStun', false);
    ntp = flag('ntp', false);
    final timeout = j['connectTimeout'];
    connectTimeout = timeout is int && timeout >= 0 && timeout <= 120 ? timeout : 0;
    final wifi = j['directWifi'];
    directWifi = wifi is List ? wifi.whereType<String>().toList() : [];
    extraSingbox = j['extraSingbox'] is String ? j['extraSingbox'] as String : '';
    extraXray = j['extraXray'] is String ? j['extraXray'] as String : '';
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
    keepProxy = flag('keepProxy', false);
    proxyUser = j['proxyUser'] is String ? j['proxyUser'] as String : '';
    proxyPassword = j['proxyPassword'] is String ? j['proxyPassword'] as String : '';
  }
}
