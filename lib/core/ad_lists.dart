/// What "Block ads and trackers" uses: lists that are downloaded and kept up to date, plus a short
/// built-in list that works even when no download is possible (GitHub is often unreachable).
library;

/// How much is blocked: [standard] is ads and trackers; [strong] adds a much bigger list, the
/// telemetry and the ad servers of the big companies, and the public encrypted-DNS servers that
/// apps could use to hide their lookups.
const adLevels = ['standard', 'strong'];
const defaultAdLevel = 'strong';

/// Tags of the ad rule-sets all start with this.
const adTagPrefix = 'ads-';

/// One list: its tag, the addresses to try, and whether it is a plain list of domains (turned into
/// a sing-box rule-set after the download) or a ready rule-set file.
typedef AdSource = ({String tag, List<String> urls, bool text});

List<String> _sager(String name) => [
      'https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-$name.srs',
      'https://fastly.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-$name.srs',
      'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-$name.srs',
    ];

List<String> _hagezi(String name) => [
      'https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@main/wildcard/$name-onlydomains.txt',
      'https://fastly.jsdelivr.net/gh/hagezi/dns-blocklists@main/wildcard/$name-onlydomains.txt',
      'https://gcore.jsdelivr.net/gh/hagezi/dns-blocklists@main/wildcard/$name-onlydomains.txt',
      'https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/$name-onlydomains.txt',
    ];

AdSource _geo(String name) =>
    (tag: '$adTagPrefix${name.replaceAll('@', '-')}', urls: _sager(name), text: false);

// The ad servers of the big companies, and telemetry: only for the strong level.
const _companyAds = [
  'google@ads', 'youtube@ads', 'alphabet@ads', 'facebook@ads', 'meta@ads', 'instagram@ads',
  'x@ads', 'twitter@ads', 'tiktok@ads', 'bytedance@ads', 'microsoft@ads', 'msn@ads',
  'bing@ads', 'amazon@ads', 'yahoo@ads', 'snap@ads', 'apple@ads', 'samsung@ads',
  'xiaomi@ads', 'huawei@ads', 'yandex@ads', 'vk@ads', 'mailru@ads', 'unity@ads',
  'adjust@ads', 'openx@ads', 'ogury@ads', 'supersonic@ads', 'segment@ads', 'amplitude@ads',
  'google@telemetry', 'microsoft@telemetry', 'firebase@telemetry', 'unity@telemetry',
];

/// The lists of [level].
List<AdSource> adSources(String level) {
  final strong = level == 'strong';
  return [
    (
      tag: '${adTagPrefix}hagezi-${strong ? 'pro' : 'light'}',
      urls: _hagezi(strong ? 'pro' : 'light'),
      text: true,
    ),
    _geo('category-ads-all'),
    _geo('category-ads-ir'),
    _geo('trackernetwork'),
    if (strong) ...[
      _geo('category-ads'),
      _geo('category-ads-and-telemetry'),
      _geo('category-telemetry'),
      for (final c in _companyAds) _geo(c),
    ],
  ];
}

/// Turns a list of domains (one a line, `#` for comments) into a sing-box rule-set in the source
/// format. Null when it holds too few domains to be a real list (a failed or cut-off download).
String? domainListToRuleSet(String text) {
  final domain = RegExp(r'^[a-z0-9_]([a-z0-9_.-]*[a-z0-9])?$');
  final seen = <String>{};
  for (var line in text.split('\n')) {
    line = line.trim().toLowerCase();
    if (line.isEmpty || line.startsWith('#') || line.startsWith('!')) continue;
    if (line.startsWith('*.')) line = line.substring(2);
    if (line.startsWith('.')) line = line.substring(1);
    if (line.contains('.') && domain.hasMatch(line)) seen.add(line);
  }
  if (seen.length < 1000) return null;
  final b = StringBuffer('{"version":3,"rules":[{"domain_suffix":["');
  b.writeAll(seen, '","');
  b.write('"]}]}');
  return b.toString();
}

/// Ad, tracker and measurement servers that are always blocked, whether or not the lists could be
/// downloaded. (The lists have these too; this is what is left when they are not there.)
const builtInAdDomains = [
  // Google
  'doubleclick.net', 'googlesyndication.com', 'googleadservices.com', 'google-analytics.com',
  'googletagmanager.com', 'googletagservices.com', 'adservice.google.com', '2mdn.net',
  'admob.com', 'app-measurement.com', 'pagead2.googlesyndication.com', 'adsense.google.com',
  'ads.youtube.com', 'googleoptimize.com', 'ad.doubleclick.net',
  // Meta, X, TikTok, Microsoft, Amazon, Yahoo, Snap, Pinterest, LinkedIn
  'pixel.facebook.com', 'an.facebook.com', 'ads.facebook.com', 'ads-api.twitter.com',
  'static.ads-twitter.com', 'analytics.twitter.com', 'ads.twitter.com', 'ads.tiktok.com',
  'analytics.tiktok.com', 'log.byteoversea.com', 'ads.linkedin.com', 'ads.pinterest.com',
  'ads.yahoo.com', 'advertising.com', 'ads.snapchat.com', 'sc-analytics.appspot.com',
  'bat.bing.com', 'ads.msn.com', 'adnxs.com', 'amazon-adsystem.com', 'aax.amazon-adsystem.com',
  // Ad networks and exchanges
  'criteo.com', 'criteo.net', 'taboola.com', 'outbrain.com', 'rubiconproject.com',
  'pubmatic.com', 'openx.net', 'casalemedia.com', 'adsrvr.org', 'yieldmo.com', 'moatads.com',
  'adform.net', 'media.net', 'bidswitch.net', 'smartadserver.com', 'teads.tv', 'zedo.com',
  'sharethrough.com', 'indexww.com', 'contextweb.com', 'lijit.com', 'sovrn.com',
  'adcolony.com', 'applovin.com', 'applvn.com', 'mopub.com', 'inmobi.com', 'chartboost.com',
  'vungle.com', 'ironsrc.com', 'supersonicads.com', 'startapp.com', 'tapjoy.com', 'fyber.com',
  'smaato.net', 'unityads.unity3d.com', 'ads.unity3d.com', 'adserver.unityads.unity3d.com',
  'mgid.com', 'revcontent.com', 'popads.net', 'propellerads.com', 'exoclick.com',
  'trafficjunky.com', 'juicyads.com', 'adsterra.com', 'trafficfactory.biz', 'clickadu.com',
  'hilltopads.net',
  // Measurement and tracking
  'scorecardresearch.com', 'quantserve.com', 'adjust.com', 'adjust.io', 'appsflyer.com',
  'kochava.com', 'singular.net', 'flurry.com', 'mixpanel.com', 'amplitude.com', 'segment.io',
  'hotjar.com', 'crazyegg.com', 'mouseflow.com', 'fullstory.com', 'newrelic.com',
  'bugsnag.com', 'sentry.io', 'comscore.com', 'chartbeat.com',
  'parsely.com', 'optimizely.com', 'omtrdc.net', 'demdex.net', 'krxd.net', 'bluekai.com',
  'agkn.com', 'rlcdn.com', 'tapad.com', 'liadm.com', 'id5-sync.com', 'thetradedesk.com',
  // Yandex, Russia, Iran
  'an.yandex.ru', 'mc.yandex.ru', 'yabs.yandex.ru', 'adfox.ru', 'yektanet.com',
  'tapsell.ir', 'adivery.com', 'sabavision.com', 'adro.co', 
  // Phones
  'ads.samsung.com', 'samsungads.com', 'ads.xiaomi.com', 'adsfs.oppomobile.com',
  'tracking.miui.com', 'data.mistat.xiaomi.com', 'iad.apple.com', 'metrics.icloud.com',
];

/// Public encrypted-DNS servers: an app that uses one asks for ad names where nothing can see
/// them. Refusing the connection makes it fall back to the system's resolver, which is checked.
const encryptedDnsDomains = [
  'dns.google', 'dns.google.com', 'dns64.dns.google', 'cloudflare-dns.com',
  'mozilla.cloudflare-dns.com', 'chrome.cloudflare-dns.com', 'one.one.one.one',
  'security.cloudflare-dns.com', 'family.cloudflare-dns.com', 'dns.quad9.net',
  'dns9.quad9.net', 'dns.adguard-dns.com', 'dns.adguard.com', 'doh.opendns.com',
  'doh.cleanbrowsing.org', 'dns.nextdns.io', 'doh.dns.sb', 'doh.libredns.gr',
  'dns.twnic.tw', 'doh.pub', 'dns.alidns.com', 'doh.360.cn', 'dns.rubyfish.cn',
];

/// Words in a name that nearly always mean an ad server.
const adKeywords = [
  'doubleclick', 'googlesyndication', 'googleadservices', 'adservice.', 'pagead',
  'adsystem', 'adserver.', 'adtech.', 'admob',
];
