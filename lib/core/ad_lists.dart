/// What "Block ads and trackers" uses: lists that are downloaded and kept up to date, a big list
/// built into the app (used when the downloads cannot be had: GitHub is often unreachable), and a
/// short list of the worst offenders that is always there.
library;

/// How much is blocked: [standard] is ads and trackers; [strong] adds a much bigger list, the
/// telemetry and the ad servers of the big companies, and the public encrypted-DNS servers that
/// apps could use to hide their lookups; [max] adds the biggest lists there are (HaGeZi Ultimate,
/// OISD, AdGuard DNS, PersianBlocker and the trackers of phone and TV makers: more memory, and now and
/// then a site that needs an exception).
const adLevels = ['standard', 'strong', 'max'];
const defaultAdLevel = 'strong';

/// Tags of the ad rule-sets all start with this.
const adTagPrefix = 'ads-';

/// The list built into the app, and the one-file list of the max level.
const adBaseTag = '${adTagPrefix}base';
const adMaxTag = '${adTagPrefix}max';

/// The built-in list: a binary rule-set that comes with the app (made by tools/make_ad_base.py from
/// [adBaseSource], HaGeZi Pro mini), and how many domains it holds (the tool prints it).
const adBaseAsset = 'assets/rules/ads-base.srs';
const adBaseSource = 'tools/ad_base/base.txt';
const adBaseCount = 99476;

/// One list: its tag, the addresses to try, and whether it is a plain list of domains (turned into
/// a sing-box rule-set after the download) or a ready rule-set file.
typedef AdSource = ({String tag, List<String> urls, bool text});

/// A list of domains of the max level (merged with the others into one rule-set): its name, the
/// addresses to try, and how many entries it has at least (fewer means a failed download).
typedef AdTextSource = ({String name, List<String> urls, int min});

List<String> _jsd(String repo, String branch, String path) => [
      'https://cdn.jsdelivr.net/gh/$repo@$branch/$path',
      'https://fastly.jsdelivr.net/gh/$repo@$branch/$path',
      'https://gcore.jsdelivr.net/gh/$repo@$branch/$path',
      'https://testingcf.jsdelivr.net/gh/$repo@$branch/$path',
      'https://raw.githubusercontent.com/$repo/$branch/$path',
    ];

List<String> _sager(String name) => _jsd('SagerNet/sing-geosite', 'rule-set', 'geosite-$name.srs');

List<String> _hagezi(String name) => _jsd('hagezi/dns-blocklists', 'main', 'wildcard/$name-onlydomains.txt');

AdSource _geo(String name) =>
    (tag: '$adTagPrefix${name.replaceAll('@', '-')}', urls: _sager(name), text: false);

// The ad servers of the big companies, and telemetry: for the strong and max levels.
const _companyAds = [
  'google@ads', 'youtube@ads', 'alphabet@ads', 'facebook@ads', 'meta@ads', 'instagram@ads',
  'x@ads', 'twitter@ads', 'tiktok@ads', 'bytedance@ads', 'microsoft@ads', 'msn@ads',
  'bing@ads', 'amazon@ads', 'yahoo@ads', 'snap@ads', 'apple@ads', 'samsung@ads',
  'xiaomi@ads', 'huawei@ads', 'yandex@ads', 'vk@ads', 'mailru@ads', 'unity@ads',
  'adjust@ads', 'openx@ads', 'ogury@ads', 'supersonic@ads', 'segment@ads', 'amplitude@ads',
  'google@telemetry', 'microsoft@telemetry', 'firebase@telemetry', 'unity@telemetry',
];

/// The lists of [level] that are separate rule-sets. (At the max level the big domain lists are
/// merged into one, see [maxTextSources].)
List<AdSource> adSources(String level) {
  final strong = level == 'strong' || level == 'max';
  return [
    if (level != 'max')
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

/// The lists of the max level that are merged into one rule-set (duplicates removed).
final List<AdTextSource> maxTextSources = [
  (name: 'hagezi-ultimate', urls: _hagezi('ultimate'), min: 50000),
  (name: 'hagezi-popupads', urls: _hagezi('popupads'), min: 1000),
  for (final vendor in ['samsung', 'xiaomi', 'huawei', 'apple', 'oppo-realme', 'vivo', 'tiktok', 'lgwebos', 'amazon'])
    (name: 'hagezi-native-$vendor', urls: _hagezi('native.$vendor'), min: 10),
  (name: 'oisd-big', urls: _jsd('sjhgvr/oisd', 'main', 'domainswild2_big.txt'), min: 50000),
  (
    name: 'adguard-dns',
    urls: _jsd('AdguardTeam/AdGuardSDNSFilter', 'gh-pages', 'Filters/filter.txt'),
    min: 10000,
  ),
  (name: 'persianblocker', urls: _jsd('MasterKia/PersianBlocker', 'main', 'PersianBlockerHosts.txt'), min: 20),
  (name: 'persianblocker-ads', urls: _jsd('MasterKia/PersianBlocker', 'main', 'PersianBlockerAds-Domains.txt'), min: 5),
  (
    name: 'persianblocker-trackers',
    urls: _jsd('MasterKia/PersianBlocker', 'main', 'PersianBlockerTrackers-Domains.txt'),
    min: 5,
  ),
];

final _domain = RegExp(r'^[a-z0-9_]([a-z0-9_.-]*[a-z0-9])?$');
final _hosts = RegExp(r'^(?:0\.0\.0\.0|127\.0\.0\.1|::1?|::)\s+(\S+)');
final _abp = RegExp(r'^(@@)?\|\|([^\^/\$|*]+)\^(\$(.*))?$');

/// The domains a block list names, in any of the usual forms: one domain a line (`example.com`,
/// `*.example.com`, `.example.com`), hosts files (`0.0.0.0 example.com`) and the simple rules of
/// ad-block lists (`||example.com^`; exceptions `@@||example.com^` are returned as [allow]). Rules
/// with paths, wildcards inside, or modifiers other than `important` are left out: they do not mean
/// a whole domain.
({Set<String> block, Set<String> allow}) parseBlocklist(String text) {
  final block = <String>{}, allow = <String>{};
  for (var line in text.split('\n')) {
    line = line.trim().toLowerCase();
    if (line.isEmpty || line.startsWith('#') || line.startsWith('!') || line.startsWith('[')) continue;
    String? name;
    var isAllow = false;
    final abp = _abp.firstMatch(line);
    if (abp != null) {
      final mods = abp[4];
      if (mods != null && mods.isNotEmpty && mods != 'important') continue;
      isAllow = abp[1] != null;
      name = abp[2];
    } else if (_hosts.hasMatch(line)) {
      name = _hosts.firstMatch(line)![1];
    } else if (!line.contains(' ') && !line.contains('/') && !line.contains('|')) {
      name = line;
    }
    if (name == null) continue;
    if (name.startsWith('*.')) name = name.substring(2);
    if (name.startsWith('.')) name = name.substring(1);
    if (name == 'localhost' || !name.contains('.') || !_domain.hasMatch(name)) continue;
    (isAllow ? allow : block).add(name);
  }
  return (block: block, allow: allow);
}

/// A sing-box rule-set (source format) blocking [domains] and everything under them.
String ruleSetOf(Iterable<String> domains) {
  final b = StringBuffer('{"version":3,"rules":[{"domain_suffix":["');
  b.writeAll(domains, '","');
  b.write('"]}]}');
  return b.toString();
}

/// Turns a block list into a sing-box rule-set in the source format. Null when it holds too few
/// domains to be a real list (a failed or cut-off download).
String? domainListToRuleSet(String text, {int min = 1000}) {
  final p = parseBlocklist(text);
  final domains = withoutNeverBlocked(p.block.difference(p.allow));
  if (domains.length < min) return null;
  return ruleSetOf(domains);
}

/// Names some lists block although apps and sites stop working without them: the Facebook API
/// (the Facebook app and every "Log in with Facebook"), YouTube's own servers and the video-ad SDK
/// players wait for, Instagram's API, app deep links, the click links of newsletters, support chat,
/// feature flags, Google Tag Manager's own page, and the fraud check some shops run at checkout.
const adNeverBlock = [
  'graph.facebook.com', 'i.instagram.com', 'youtubei.googleapis.com', 's.youtube.com',
  'redirector.googlevideo.com', 'imasdk.googleapis.com', 'dai.google.com', 'bnc.lt', 'app.link',
  'click.mailchimp.com', 'list-manage.com', 'mailchi.mp', 'widget.intercom.io', 'api-iam.intercom.io',
  'clientstream.launchdarkly.com', 'ssl.p.jwpcdn.com', 'cdn.jwplayer.com', 'tagmanager.google.com',
  'siftscience.com', 'sift.com',
];

/// [domains] less the names of [adNeverBlock] and the names under them.
Set<String> withoutNeverBlocked(Set<String> domains) {
  final never = adNeverBlock.toSet();
  bool kept(String d) {
    for (var s = d;;) {
      if (never.contains(s)) return false;
      final dot = s.indexOf('.');
      if (dot < 0) return true;
      s = s.substring(dot + 1);
    }
  }

  return domains.where(kept).toSet();
}

/// The domains of several lists merged: what any of them blocks, less what any of them allows.
Set<String> mergeBlocklists(Iterable<String> texts) {
  final block = <String>{}, allow = <String>{};
  for (final t in texts) {
    final p = parseBlocklist(t);
    block.addAll(p.block);
    allow.addAll(p.allow);
  }
  return withoutNeverBlocked(block.difference(allow));
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
  // Ad technology the big lists name only in part (a few subdomains of each)
  'adroll.com', 'doubleverify.com', 'adsafeprotected.com', 'mathtag.com', 'everesttech.net',
  '3lift.com', 'smartyads.com', 'quantcast.com', 'liftoff.io', 'ad.gt', 'insightexpressai.com',
  'mineralt.io', 'tremorhub.com', 'connatix.com', 'fwmrm.net', 'dynamicyield.com', 'sonobi.com',
  'gumgum.com', 'kargo.com', 'pangleglobal.com', 'crwdcntrl.net', 'prod.uidapi.com', 'pippio.com',
  'onetag-sys.com', 'innovid.com', 'jwpsrv.com', 'jwpltx.com',
  // Measurement that apps and sites send in the background
  'snap.licdn.com', 'px.ads.linkedin.com', 'eu.posthog.com', 'us.posthog.com', 'eu.i.posthog.com',
  'us.i.posthog.com', 'track.customer.io', 'bam.nr-data.net', 'bam-cell.nr-data.net',
  'analytics.pinterest.com', 'analytics.x.com', 'udc.yahoo.com', 'xp.apple.com', 'ngfts.lge.com',
  'device-metrics-us.amazon.com', 'device-metrics-us-2.amazon.com', 'fls-na.amazon.com',
  'books-analytics-events.apple.com', 'weather-analytics-events.apple.com',
  'notes-analytics-events.apple.com', 'stocks-analytics-events.apple.com', 'metrics.mzstatic.com',
  'iadsdk.apple.com', 'api-adservices.apple.com', 'freshmarketer.com', 'shareasale-analytics.com',
  'trackcmp.net', 'track.hubspot.com', 'munchkin.marketo.net', 'js.driftt.com', 'metrics.brightcove.com',
  'statdynamic.com', 'smetrics.samsung.com', 'nmetrics.samsung.com', 'dataplane.rudderstack.com',
  'cdn.rudderlabs.com', 'hosted.rudderlabs.com',
];

/// Cookie-consent banners (optional): blocking them hides most banners, but a site that waits for
/// the answer may not show its content or remember choices.
const cookieBannerDomains = [
  'cookielaw.org', 'cdn.cookielaw.org', 'geolocation.onetrust.com', 'cookiebot.com',
  'consent.trustarc.com', 'consent-pref.trustarc.com', 'privacy-center.org', 'privacy-mgmt.com',
  'usercentrics.eu', 'cmp.osano.com', 'fundingchoicesmessages.google.com', 'consensu.org',
  'cookiehub.net', 'iubenda.com', 'termly.io', 'cookieyes.com', 'cookie-script.com',
  'privacyportal.onetrust.com',
];

/// Affiliate links (optional): the redirects shops pay for. Blocking them stops the tracking, but a
/// link that goes through one of them (a "buy at ..." link) does not open.
const affiliateDomains = [
  'anrdoezrs.net', 'dpbolvw.net', 'tkqlhce.com', 'jdoqocy.com', 'kqzyfj.com', 'emjcd.com',
  'shareasale.com', 'linksynergy.com', 'awin1.com', 'zenaps.com', 'prf.hn', 'pepperjamnetwork.com',
  'skimresources.com', 'redirectingat.com', 'viglink.com', 'go.skimlinks.com', 'avantlink.com',
  'impactradius-go.com', 'ojrq.net', 'sjv.io', 'pxf.io',
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

/// The addresses of the same public resolvers: an app can ask them by address, without a name to
/// block. Their encrypted ports (443 for DNS over HTTPS and HTTP/3, 853 for DNS over TLS and QUIC)
/// are refused for the apps, which then use the resolver of the tunnel. (Kumo's own lookups do not
/// go through these rules.)
const encryptedDnsIps = [
  '8.8.8.8/32', '8.8.4.4/32', '1.1.1.1/32', '1.0.0.1/32', '1.1.1.2/32', '1.0.0.2/32',
  '1.1.1.3/32', '1.0.0.3/32', '9.9.9.9/32', '149.112.112.112/32', '9.9.9.11/32',
  '149.112.112.11/32', '208.67.222.222/32', '208.67.220.220/32', '94.140.14.14/32',
  '94.140.15.15/32', '94.140.14.15/32', '94.140.15.16/32', '185.228.168.9/32',
  '185.228.169.9/32', '76.76.2.0/24', '76.76.10.0/24', '45.90.28.0/24', '45.90.30.0/24',
  '223.5.5.5/32', '223.6.6.6/32', '1.12.12.12/32', '120.53.53.53/32', '185.222.222.222/32',
  '45.11.45.11/32',
  '2001:4860:4860::8888/128', '2001:4860:4860::8844/128', '2606:4700:4700::1111/128',
  '2606:4700:4700::1001/128', '2620:fe::fe/128', '2620:fe::9/128', '2620:119:35::35/128',
  '2620:119:53::53/128', '2a10:50c0::ad1:ff/128', '2a10:50c0::ad2:ff/128',
];

/// Words in a name that nearly always mean an ad server.
const adKeywords = [
  'doubleclick', 'googlesyndication', 'googleadservices', 'adservice.', 'pagead',
  'adsystem', 'adserver.', 'adtech.', 'admob',
];

/// What the user wants never blocked, made fit: lower case, no `*.` or `.` in front, real names only
/// (at most 500).
List<String> cleanAllowList(Iterable<String> raw) {
  final out = <String>{};
  for (var d in raw) {
    d = d.trim().toLowerCase();
    if (d.startsWith('*.')) d = d.substring(2);
    if (d.startsWith('.')) d = d.substring(1);
    final host = Uri.tryParse(d.contains('://') ? d : 'http://$d')?.host ?? '';
    if (host.contains('.') && _domain.hasMatch(host)) out.add(host);
    if (out.length >= 500) break;
  }
  return out.toList();
}
