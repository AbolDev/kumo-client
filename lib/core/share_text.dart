/// A language the message that shares Kumo can be written in, with its name in itself, whether it is read from
/// right to left, the page of Kumo's site in it, and the message.
class ShareLang {
  const ShareLang(this.code, this.name, this.rtl, this.site, this.text);

  final String code, name, site, text;
  final bool rtl;

  /// The message with the address under it, as it is sent.
  String message() => '$text\n$site';
}

const shareLangs = <ShareLang>[
  ShareLang(
    'en',
    'English',
    false,
    'https://kumo-client.ir',
    'Kumo: a free, open-source VPN client for Android, Windows, macOS and Linux. No account, one tap to connect, and it opens your own V2Ray, Xray and sing-box configs and subscriptions.',
  ),
  ShareLang(
    'fa',
    'فارسی',
    true,
    'https://kumo-client.ir/fa/',
    'کومو: برنامهٔ VPN رایگان و متن‌باز برای اندروید، ویندوز، مک و لینوکس. بدون ثبت‌نام، با یک لمس وصل می‌شود و کانفیگ‌ها و اشتراک‌های V2Ray، Xray و sing-box خودتان را هم باز می‌کند.',
  ),
  ShareLang(
    'ar',
    'العربية',
    true,
    'https://kumo-client.ir/ar/',
    'Kumo: عميل VPN مجاني ومفتوح المصدر لأندرويد وويندوز وmacOS ولينكس. بلا حساب، يتصل بلمسة واحدة، ويفتح إعدادات واشتراكات V2Ray وXray وsing-box الخاصة بك.',
  ),
  ShareLang(
    'ru',
    'Русский',
    false,
    'https://kumo-client.ir/ru/',
    'Kumo — бесплатный VPN-клиент с открытым исходным кодом для Android, Windows, macOS и Linux. Без регистрации, подключение одним нажатием; открывает ваши конфиги и подписки V2Ray, Xray и sing-box.',
  ),
  ShareLang(
    'vi',
    'Tiếng Việt',
    false,
    'https://kumo-client.ir/vi/',
    'Kumo là ứng dụng VPN miễn phí, mã nguồn mở cho Android, Windows, macOS và Linux. Không cần tài khoản, kết nối một chạm, và mở được cấu hình và gói đăng ký V2Ray, Xray, sing-box của riêng bạn.',
  ),
  ShareLang(
    'zh',
    '简体中文',
    false,
    'https://kumo-client.ir/zh/',
    'Kumo：免费、开源的 VPN 客户端，支持 Android、Windows、macOS 和 Linux。无需注册，一键连接，也能打开你自己的 V2Ray、Xray 和 sing-box 配置与订阅。',
  ),
  ShareLang(
    'zh-Hant',
    '繁體中文',
    false,
    'https://kumo-client.ir/zh-hant/',
    'Kumo：免費、開源的 VPN 用戶端，支援 Android、Windows、macOS 和 Linux。不需要註冊，一鍵連線，也能開啟你自己的 V2Ray、Xray 和 sing-box 設定與訂閱。',
  ),
];

/// The language of the message for an app language ([languageCode] and, for Chinese, [scriptCode]); English
/// when Kumo has none for it.
ShareLang shareLangFor(String languageCode, [String? scriptCode]) {
  final code = languageCode == 'zh' && scriptCode == 'Hant' ? 'zh-Hant' : languageCode;
  return shareLangs.firstWhere((l) => l.code == code, orElse: () => shareLangs.first);
}
