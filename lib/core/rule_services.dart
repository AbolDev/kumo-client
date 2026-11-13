/// A popular service whose names can be added to a routing rule in one step ("Telegram" instead of the
/// fifteen domains it uses). The domains cover their sub-domains.
class RuleService {
  const RuleService(this.id, this.name, this.domains, this.group);

  /// What a rule stores: `service:telegram`.
  final String id;
  final String name;
  final List<String> domains;

  /// The key of the text that names the group the service is listed in.
  final String group;
}

const _social = 'ruleGroupSocial';
const _media = 'ruleGroupMedia';
const _tech = 'ruleGroupTech';
const _games = 'ruleGroupGames';

/// The services, in the order they are listed.
const ruleServiceList = <RuleService>[
  RuleService('telegram', 'Telegram',
      ['telegram.org', 't.me', 'telegram.me', 'telesco.pe', 'tdesktop.com', 'telegra.ph', 'graph.org', 'cdn-telegram.org'], _social),
  RuleService('whatsapp', 'WhatsApp', ['whatsapp.com', 'whatsapp.net', 'wa.me'], _social),
  RuleService('instagram', 'Instagram', ['instagram.com', 'cdninstagram.com', 'instagr.am'], _social),
  RuleService('facebook', 'Facebook', ['facebook.com', 'fbcdn.net', 'fb.com', 'fb.me', 'messenger.com', 'fbsbx.com'], _social),
  RuleService('x', 'X (Twitter)', ['x.com', 'twitter.com', 'twimg.com', 't.co'], _social),
  RuleService('tiktok', 'TikTok', ['tiktok.com', 'tiktokv.com', 'tiktokcdn.com', 'byteoversea.com', 'musical.ly'], _social),
  RuleService('discord', 'Discord', ['discord.com', 'discordapp.com', 'discord.gg', 'discordapp.net', 'discord.media'], _social),
  RuleService('reddit', 'Reddit', ['reddit.com', 'redd.it', 'redditmedia.com', 'redditstatic.com'], _social),
  RuleService('linkedin', 'LinkedIn', ['linkedin.com', 'licdn.com'], _social),
  RuleService('youtube', 'YouTube',
      ['youtube.com', 'youtu.be', 'googlevideo.com', 'ytimg.com', 'youtube-nocookie.com', 'ggpht.com'], _media),
  RuleService('netflix', 'Netflix', ['netflix.com', 'nflxvideo.net', 'nflximg.net', 'nflxext.com', 'nflxso.net'], _media),
  RuleService('spotify', 'Spotify', ['spotify.com', 'scdn.co', 'spotifycdn.com'], _media),
  RuleService('twitch', 'Twitch', ['twitch.tv', 'ttvnw.net', 'jtvnw.net'], _media),
  RuleService('google', 'Google',
      ['google.com', 'googleapis.com', 'gstatic.com', 'googleusercontent.com', 'gvt1.com', 'gvt2.com', 'google.com.hk'], _tech),
  RuleService('chatgpt', 'ChatGPT', ['openai.com', 'chatgpt.com', 'oaistatic.com', 'oaiusercontent.com'], _tech),
  RuleService('github', 'GitHub', ['github.com', 'githubusercontent.com', 'githubassets.com', 'github.io'], _tech),
  RuleService('microsoft', 'Microsoft',
      ['microsoft.com', 'live.com', 'office.com', 'office365.com', 'windows.com', 'bing.com', 'msn.com'], _tech),
  RuleService('apple', 'Apple', ['apple.com', 'icloud.com', 'mzstatic.com', 'cdn-apple.com', 'apple-dns.net'], _tech),
  RuleService('zoom', 'Zoom', ['zoom.us', 'zoom.com'], _tech),
  RuleService('steam', 'Steam', ['steampowered.com', 'steamcommunity.com', 'steamstatic.com', 'steamcontent.com'], _games),
  RuleService('epic', 'Epic Games', ['epicgames.com', 'unrealengine.com', 'fortnite.com'], _games),
];

/// The services by the id a rule stores.
final ruleServices = {for (final s in ruleServiceList) s.id: s};
