import 'package:flutter/material.dart';

import 'lang_ar.dart';
import 'lang_ru.dart';
import 'lang_vi.dart';
import 'lang_zh_hans.dart';
import 'lang_zh_hant.dart';

/// UI strings in English, Chinese (simplified and traditional), Vietnamese, Russian, Persian
/// and Arabic. The language follows the phone's, English when it is none of those (see [SDelegate]).
abstract class S {
  static S of(BuildContext context) =>
      forcedLanguage != null ? forCode(forcedLanguage!) : Localizations.of<S>(context, S)!;

  /// While set, every text is looked up in this language (stored code, see [languageNames])
  /// whatever the context says. Used to build the Settings screen in each language for the
  /// search; always put back to null.
  static String? forcedLanguage;

  /// The texts of a stored language code.
  static S forCode(String code) => switch (code) {
        'fa' => const SFa(),
        'zh' => const SZhHans(),
        'zh-TW' => const SZhHant(),
        'vi' => const SVi(),
        'ru' => const SRu(),
        'ar' => const SAr(),
        _ => const SEn(),
      };

  static const delegate = SDelegate();
  static final traditionalChinese =
      Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant');
  static final supportedLocales = [
    const Locale('en'),
    const Locale('fa'),
    const Locale('zh'),
    traditionalChinese,
    const Locale('vi'),
    const Locale('ru'),
    const Locale('ar'),
  ];

  /// Languages offered in Settings: stored code and the name written in that language.
  static const languageNames = {
    'en': 'English',
    'zh': '中文简体',
    'zh-TW': '中文繁體',
    'vi': 'Tiếng Việt',
    'ru': 'Русский',
    'fa': 'فارسی',
    'ar': 'عربي',
  };

  /// The stored language code as a locale (zh-TW is Traditional Chinese).
  static Locale localeFor(String code) =>
      code == 'zh-TW' ? traditionalChinese : Locale(code);

  // connection state
  String get connected;
  String get disconnected;
  String get connecting;
  String get disconnecting;
  String get connectionError;
  String get autoFastest;
  String activeServers(int n);

  // groups
  String get collectorGroup;
  String get manualGroup;
  String get emptyGroup;

  // actions
  String get add;
  String get cancel;
  String get save;
  String get delete;
  String get edit;
  String get share;
  String get ping;
  String get refreshList;
  String get settings;
  String get more;
  String get timeout;

  // add menu
  String get addFromClipboard;
  String get addFromFile;
  String get scanQr;
  String get clipboardEmpty;
  String get scanTitle;
  String get pickFromGallery;
  String get noQrFound;
  String get cameraDenied;

  // edit / share
  String get editConfigTitle;
  String get editSubscriptionTitle;
  String get subscriptionName;
  String get nameSubscription;
  String get showCollector;
  String get showCollectorDesc;
  String get subscriptionUrl;
  String get invalidConfig;
  String get invalidUrl;
  String get copyConfig;
  String get copySubscriptionLink;
  String get copied;
  String get qrCode;
  String get shareImage;
  String get saveToGallery;
  String get savedToGallery;
  String saveFailed(Object e);
  String get password;
  String get ok;
  String get tcping;
  String get realDelay;
  String get realDelayNeedsDisconnect;
  String get advanced;
  String get language;
  String get languageSystem;
  String get scanHint;
  String get downloadLabel;
  String get uploadLabel;
  String get sessionLabel;
  String fieldLabel(String key);
  String listLoaded(int n);
  String addedConfigs(int n);
  String get subSettings;
  String get appSettings;
  String get uiSettings;
  String get coreSettings;
  String get autoUpdateSubs;
  String get autoUpdateSubsDesc;
  String get updateOnStartup;
  String get updateOnStartupDesc;
  String get allowInsecure;
  String get allowInsecureDesc;
  String get autoConnect;
  String get autoConnectDesc;
  String get restartOnChange;
  String get restartOnChangeDesc;
  String get confirmDelete;
  String get confirmDeleteDesc;
  String get uiMode;
  String get showSpeed;
  String get showSpeedDesc;
  String get delayUrlTitle;
  String get resetDefault;
  String get batteryTitle;
  String get batteryMessage;
  String get batteryAllow;
  String get later;
  String get batteryDone;
  String get deleteQuestion;
  String get unsupportedFile;
  String get deleteWarning;
  String daysLeft(int n);
  String hoursLeft(int n);
  String minutesLeft(int n);
  String get expired;
  String get unlimitedTime;
  String get noSubInfo;
  String get logs;
  String get logsDesc;
  String get logsEmpty;
  String get clearLogs;
  String get copyLogs;
  String get removeDeadTitle;
  String get removeDeadOption;
  String get start;
  String testStat(int alive, int percent);
  String get timeWord;
  String get unlimitedData;
  String usedOf(String used, String total);
  String usedUnlimited(String used); // settings
  String get theme;
  String get themeSystem;
  String get themeLight;
  String get themeDark;

  // status messages
  String get fetchingList;
  String testingServers(int n);
  String foundActive(int n);
  String get testingSaved;
  String get allSourcesFailed;
  String fetchFailed(Object e);
  String get noActiveServer;
  String get adding;
  String get noValidConfig;
  String importResult(int alive, int total);
  String importFailed(Object e);
  String subscriptionUpdated(int n);
  String get vpnPermissionDenied;
  String connectFailed(String reason);
}

class SDelegate extends LocalizationsDelegate<S> {
  const SDelegate();

  @override
  bool isSupported(Locale locale) =>
      const {'en', 'fa', 'zh', 'vi', 'ru', 'ar'}.contains(locale.languageCode);

  @override
  Future<S> load(Locale locale) async {
    switch (locale.languageCode) {
      case 'fa':
        return const SFa();
      case 'zh':
        final traditional = locale.scriptCode == 'Hant' ||
            const {'TW', 'HK', 'MO'}.contains(locale.countryCode);
        return traditional ? const SZhHant() : const SZhHans();
      case 'vi':
        return const SVi();
      case 'ru':
        return const SRu();
      case 'ar':
        return const SAr();
    }
    return const SEn();
  }

  @override
  bool shouldReload(SDelegate old) => false;
}

class SEn implements S {
  const SEn();

  @override
  String get connected => 'Connected';
  @override
  String get disconnected => 'Disconnected';
  @override
  String get connecting => 'Connecting...';
  @override
  String get disconnecting => 'Disconnecting...';
  @override
  String get connectionError => 'Connection error';
  @override
  String get autoFastest => 'Automatic (lowest ping)';
  @override
  String activeServers(int n) => '$n active servers';

  @override
  String get collectorGroup => 'Public servers';
  @override
  String get manualGroup => 'Added manually';
  @override
  String get emptyGroup => 'No configs here yet.';

  @override
  String get add => 'Add';
  @override
  String get cancel => 'Cancel';
  @override
  String get save => 'Save';
  @override
  String get delete => 'Delete';
  @override
  String get edit => 'Edit';
  @override
  String get share => 'Share';
  @override
  String get ping => 'Ping';
  @override
  String get refreshList => 'Refresh';
  @override
  String get settings => 'Settings';
  @override
  String get more => 'More';
  @override
  String get timeout => 'timeout';

  @override
  String get addFromClipboard => 'Add from clipboard';
  @override
  String get addFromFile => 'Add from file';
  @override
  String get scanQr => 'Scan QR code';
  @override
  String get clipboardEmpty =>
      'The clipboard has no config or subscription link.';
  @override
  String get scanTitle => 'Scan QR code';
  @override
  String get pickFromGallery => 'Choose from gallery';
  @override
  String get noQrFound => 'No QR code found in the image.';
  @override
  String get cameraDenied => 'Camera is not available. Check the permission.';

  @override
  String get editConfigTitle => 'Edit config';
  @override
  String get editSubscriptionTitle => 'Edit subscription';
  @override
  String get subscriptionName => 'Name';
  @override
  String get nameSubscription => 'Name this subscription';
  @override
  String get showCollector => 'Public servers';
  @override
  String get showCollectorDesc => 'Show the list of free public servers';
  @override
  String get subscriptionUrl => 'Subscription link';
  @override
  String get invalidConfig => 'This is not a supported config link.';
  @override
  String get invalidUrl => 'Enter a valid http(s) link.';
  @override
  String get copyConfig => 'Copy config';
  @override
  String get copySubscriptionLink => 'Copy subscription link';
  @override
  String get copied => 'Copied';
  @override
  String get qrCode => 'QR code';
  @override
  String get shareImage => 'Share image';
  @override
  String get saveToGallery => 'Save to gallery';
  @override
  String get savedToGallery => 'Saved to gallery';
  @override
  String saveFailed(Object e) => 'Could not save: $e';
  @override
  String get password => 'Password';
  @override
  String get ok => 'OK';
  @override
  String get tcping => 'TCPing';
  @override
  String get realDelay => 'Real delay';
  @override
  String get realDelayNeedsDisconnect =>
      'Real delay can only be measured while disconnected.';
  @override
  String get advanced => 'Advanced';
  @override
  String get language => 'Language';
  @override
  String get languageSystem => 'Same as phone';
  @override
  String get scanHint => 'Put the QR code inside the square';
  @override
  String get downloadLabel => 'Download';
  @override
  String get uploadLabel => 'Upload';
  @override
  String get sessionLabel => 'This session';
  @override
  String listLoaded(int n) => 'List loaded: $n configs.';
  @override
  String addedConfigs(int n) => '$n configs added.';
  @override
  String get subSettings => 'Sub settings';
  @override
  String get appSettings => 'App settings';
  @override
  String get uiSettings => 'UI settings';
  @override
  String get coreSettings => 'Core settings';
  @override
  String get autoUpdateSubs => 'Automatic update subscriptions';
  @override
  String get autoUpdateSubsDesc =>
      'Update your subscriptions automatically at set intervals in the background. Depending on the device.';
  @override
  String get updateOnStartup => 'Automatic update subscriptions on startup';
  @override
  String get updateOnStartupDesc =>
      'Update your subscriptions automatically with an interval when the application is launched. If automatic update does not work in the background.';
  @override
  String get allowInsecure => 'Allow insecure';
  @override
  String get allowInsecureDesc => 'Ignore validation of SSL certificates';
  @override
  String get autoConnect => 'Auto connect at device startup';
  @override
  String get autoConnectDesc =>
      'Automatically connects with the selected config at startup, which may be unsuccessful. Depending on the device, this feature may not always work.';
  @override
  String get restartOnChange => 'Restart when changing settings';
  @override
  String get restartOnChangeDesc =>
      'Auto restart of services when changing settings';
  @override
  String get confirmDelete => 'Delete confirmation';
  @override
  String get confirmDeleteDesc => 'Require confirmation before deleting data';
  @override
  String get uiMode => 'UI mode settings';
  @override
  String get showSpeed => 'Enable speed display';
  @override
  String get showSpeedDesc =>
      'Display current speed and traffic volume in the notification';
  @override
  String get delayUrlTitle => 'True delay test URL (http/https)';
  @override
  String get resetDefault => 'Reset to default';
  @override
  String get batteryTitle => 'Battery optimization';
  @override
  String get batteryMessage =>
      'To keep the connection alive in the background, allow Kumo to run without battery optimization.';
  @override
  String get batteryAllow => 'Allow';
  @override
  String get later => 'Later';
  @override
  String get batteryDone => 'Battery optimization is already off for Kumo.';
  @override
  String get unsupportedFile => 'This file cannot be opened here.';
  @override
  String get deleteQuestion => 'Delete?';
  @override
  String get deleteWarning => 'This cannot be undone.';
  @override
  String daysLeft(int n) => n == 1 ? '1 Day left' : '$n Days left';
  @override
  String hoursLeft(int n) => n == 1 ? '1 Hour left' : '$n Hours left';
  @override
  String minutesLeft(int n) => n == 1 ? '1 Minute left' : '$n Minutes left';
  @override
  String get expired => 'Expired';
  @override
  String get unlimitedTime => 'Unlimited time';
  @override
  String get noSubInfo => 'No usage info from this provider';
  @override
  String get logs => 'Logs';
  @override
  String get logsDesc => 'Connection errors and what the app did';
  @override
  String get logsEmpty => 'Nothing logged yet.';
  @override
  String get clearLogs => 'Clear';
  @override
  String get copyLogs => 'Copy all';
  @override
  String get removeDeadTitle => 'Real delay test';
  @override
  String get removeDeadOption => 'Remove configs that do not respond';
  @override
  String get start => 'Start';
  @override
  String testStat(int alive, int percent) => '$alive works · $percent%';
  @override
  String get timeWord => 'Time';
  @override
  String get unlimitedData => 'Unlimited data';
  @override
  String usedOf(String used, String total) => '$used of $total used';
  @override
  String usedUnlimited(String used) => '$used used';
  @override
  String fieldLabel(String key) =>
      const {
        'name': 'Name',
        'address': 'Address',
        'port': 'Port',
        'uuid': 'User ID (UUID)',
        'password': 'Password',
        'security': 'Security',
        'type': 'Network',
        'net': 'Network',
        'tls': 'TLS',
        'sni': 'SNI',
        'host': 'Host header',
        'path': 'Path',
        'fp': 'Fingerprint',
        'alpn': 'ALPN',
        'flow': 'Flow',
        'pbk': 'Public key',
        'sid': 'Short ID',
        'spx': 'Spider path',
        'encryption': 'Encryption',
        'headerType': 'Header type',
        'serviceName': 'gRPC service name',
        'mode': 'Mode',
        'method': 'Cipher',
        'allowInsecure': 'Allow insecure',
        'insecure': 'Allow insecure',
        'aid': 'Alter ID',
        'scy': 'Cipher',
        'obfs': 'Obfuscation',
        'obfs-password': 'Obfuscation password',
      }[key] ??
      key;
  @override
  String get theme => 'Theme';
  @override
  String get themeSystem => 'System';
  @override
  String get themeLight => 'Light';
  @override
  String get themeDark => 'Dark';

  @override
  String get fetchingList => 'Downloading the config list...';
  @override
  String testingServers(int n) => 'Testing $n servers...';
  @override
  String foundActive(int n) => '$n active servers found...';
  @override
  String get testingSaved => 'Testing saved servers...';
  @override
  String get allSourcesFailed =>
      'None of the sources could be reached. Add a subscription link or config manually.';
  @override
  String fetchFailed(Object e) => 'Could not download the list: $e';
  @override
  String get noActiveServer => 'No active server found. Try again.';
  @override
  String get adding => 'Adding...';
  @override
  String get noValidConfig => 'No valid config found.';
  @override
  String importResult(int alive, int total) =>
      '$alive of $total configs are active.';
  @override
  String importFailed(Object e) => 'Could not add: $e';
  @override
  String subscriptionUpdated(int n) => 'Subscription updated: $n configs.';
  @override
  String get vpnPermissionDenied => 'VPN permission was not granted.';
  @override
  String connectFailed(String reason) => 'Could not connect: $reason';
}

class SFa implements S {
  const SFa();

  @override
  String get connected => 'متصل است';
  @override
  String get disconnected => 'قطع است';
  @override
  String get connecting => 'در حال اتصال...';
  @override
  String get disconnecting => 'در حال قطع...';
  @override
  String get connectionError => 'خطا در اتصال';
  @override
  String get autoFastest => 'خودکار (کمترین پینگ)';
  @override
  String activeServers(int n) => '$n سرور فعال';

  @override
  String get collectorGroup => 'سرورهای عمومی';
  @override
  String get manualGroup => 'افزوده‌شده دستی';
  @override
  String get emptyGroup => 'هنوز کانفیگی اینجا نیست.';

  @override
  String get add => 'افزودن';
  @override
  String get cancel => 'انصراف';
  @override
  String get save => 'ذخیره';
  @override
  String get delete => 'حذف';
  @override
  String get edit => 'ویرایش';
  @override
  String get share => 'اشتراک‌گذاری';
  @override
  String get ping => 'پینگ';
  @override
  String get refreshList => 'به‌روزرسانی';
  @override
  String get settings => 'تنظیمات';
  @override
  String get more => 'بیشتر';
  @override
  String get timeout => 'بدون پاسخ';

  @override
  String get addFromClipboard => 'افزودن از کلیپ‌بورد';
  @override
  String get addFromFile => 'افزودن از فایل';
  @override
  String get scanQr => 'اسکن QR Code';
  @override
  String get clipboardEmpty => 'کلیپ‌بورد کانفیگ یا لینک اشتراک ندارد.';
  @override
  String get scanTitle => 'اسکن QR Code';
  @override
  String get pickFromGallery => 'انتخاب از گالری';
  @override
  String get noQrFound => 'QR Code ای در تصویر پیدا نشد.';
  @override
  String get cameraDenied => 'دوربین در دسترس نیست. مجوز را بررسی کنید.';

  @override
  String get editConfigTitle => 'ویرایش کانفیگ';
  @override
  String get editSubscriptionTitle => 'ویرایش اشتراک';
  @override
  String get subscriptionName => 'نام';
  @override
  String get nameSubscription => 'یک نام برای این اشتراک بگذارید';
  @override
  String get showCollector => 'سرورهای عمومی';
  @override
  String get showCollectorDesc => 'نمایش فهرست سرورهای عمومی رایگان';
  @override
  String get subscriptionUrl => 'لینک اشتراک';
  @override
  String get invalidConfig => 'این لینک، کانفیگ پشتیبانی‌شده‌ای نیست.';
  @override
  String get invalidUrl => 'یک لینک معتبر http(s) وارد کنید.';
  @override
  String get copyConfig => 'کپی کانفیگ';
  @override
  String get copySubscriptionLink => 'کپی لینک اشتراک';
  @override
  String get copied => 'کپی شد';
  @override
  String get qrCode => 'QR Code';
  @override
  String get shareImage => 'اشتراک‌گذاری تصویر';
  @override
  String get saveToGallery => 'ذخیره در گالری';
  @override
  String get savedToGallery => 'در گالری ذخیره شد';
  @override
  String saveFailed(Object e) => 'ذخیره نشد: $e';
  @override
  String get password => 'رمز عبور';
  @override
  String get ok => 'تأیید';
  @override
  String get tcping => 'TCPing';
  @override
  String get realDelay => 'ریل دیلی';
  @override
  String get realDelayNeedsDisconnect =>
      'ریل دیلی فقط در حالت قطع اتصال قابل اندازه‌گیری است.';
  @override
  String get advanced => 'پیشرفته';
  @override
  String get language => 'زبان';
  @override
  String get languageSystem => 'مطابق گوشی';
  @override
  String get scanHint => 'QR Code را داخل کادر قرار دهید';
  @override
  String get downloadLabel => 'دانلود';
  @override
  String get uploadLabel => 'آپلود';
  @override
  String get sessionLabel => 'از ابتدای اتصال';
  @override
  String listLoaded(int n) => 'لیست دریافت شد: $n کانفیگ.';
  @override
  String addedConfigs(int n) => '$n کانفیگ اضافه شد.';
  @override
  String get subSettings => 'تنظیمات اشتراک';
  @override
  String get appSettings => 'تنظیمات برنامه';
  @override
  String get uiSettings => 'تنظیمات رابط کاربری';
  @override
  String get coreSettings => 'تنظیمات هسته';
  @override
  String get autoUpdateSubs => 'به‌روزرسانی خودکار اشتراک‌ها';
  @override
  String get autoUpdateSubsDesc =>
      'اشتراک‌ها در فاصله‌های زمانی مشخص در پس‌زمینه به‌روز می‌شوند. بسته به دستگاه ممکن است کار نکند.';
  @override
  String get updateOnStartup => 'به‌روزرسانی اشتراک‌ها هنگام اجرای برنامه';
  @override
  String get updateOnStartupDesc =>
      'اشتراک‌ها هنگام باز شدن برنامه، با یک فاصلهٔ زمانی، به‌روز می‌شوند. برای وقتی که به‌روزرسانی پس‌زمینه کار نمی‌کند.';
  @override
  String get allowInsecure => 'اجازه اتصال ناامن';
  @override
  String get allowInsecureDesc => 'نادیده گرفتن بررسی گواهی SSL';
  @override
  String get autoConnect => 'اتصال خودکار هنگام روشن شدن گوشی';
  @override
  String get autoConnectDesc =>
      'پس از روشن شدن دستگاه با کانفیگ انتخاب‌شده وصل می‌شود؛ ممکن است موفق نباشد. بسته به دستگاه ممکن است همیشه کار نکند.';
  @override
  String get restartOnChange => 'راه‌اندازی مجدد هنگام تغییر تنظیمات';
  @override
  String get restartOnChangeDesc =>
      'با تغییر کانفیگ یا تنظیمات، سرویس خودکار دوباره راه‌اندازی می‌شود';
  @override
  String get confirmDelete => 'تأیید حذف';
  @override
  String get confirmDeleteDesc => 'پیش از حذف داده‌ها تأیید گرفته شود';
  @override
  String get uiMode => 'حالت نمایش';
  @override
  String get showSpeed => 'نمایش سرعت';
  @override
  String get showSpeedDesc =>
      'سرعت لحظه‌ای و حجم مصرف‌شده در اعلان نمایش داده شود';
  @override
  String get delayUrlTitle => 'آدرس تست ریل دیلی (http/https)';
  @override
  String get resetDefault => 'بازگشت به پیش‌فرض';
  @override
  String get batteryTitle => 'بهینه‌سازی باتری';
  @override
  String get batteryMessage =>
      'برای اینکه اتصال در پس‌زمینه قطع نشود، اجازه دهید Kumo بدون محدودیت باتری اجرا شود.';
  @override
  String get batteryAllow => 'اجازه می‌دهم';
  @override
  String get later => 'بعداً';
  @override
  String get batteryDone => 'محدودیت باتری برای Kumo از قبل برداشته شده است.';
  @override
  String get unsupportedFile => 'این فایل قابل باز شدن نیست.';
  @override
  String get deleteQuestion => 'حذف شود؟';
  @override
  String get deleteWarning => 'این کار قابل بازگشت نیست.';
  @override
  String daysLeft(int n) => '$n روز مانده';
  @override
  String hoursLeft(int n) => '$n ساعت مانده';
  @override
  String minutesLeft(int n) => '$n دقیقه مانده';
  @override
  String get expired => 'منقضی شده';
  @override
  String get unlimitedTime => 'زمان نامحدود';
  @override
  String get noSubInfo => 'این سرویس اطلاعات مصرف ارائه نمی‌دهد';
  @override
  String get logs => 'لاگ‌ها';
  @override
  String get logsDesc => 'خطاهای اتصال و کارهایی که برنامه انجام داده';
  @override
  String get logsEmpty => 'هنوز چیزی ثبت نشده.';
  @override
  String get clearLogs => 'پاک کردن';
  @override
  String get copyLogs => 'کپی همه';
  @override
  String get removeDeadTitle => 'تست ریل دیلی';
  @override
  String get removeDeadOption => 'کانفیگ‌هایی که پاسخ نمی‌دهند حذف شوند';
  @override
  String get start => 'شروع';
  @override
  String testStat(int alive, int percent) => '$alive سالم · $percent٪';
  @override
  String get timeWord => 'زمان';
  @override
  String get unlimitedData => 'حجم نامحدود';
  @override
  String usedOf(String used, String total) => '$used از $total مصرف شده';
  @override
  String usedUnlimited(String used) => '$used مصرف شده';
  @override
  String fieldLabel(String key) =>
      const {
        'name': 'نام',
        'address': 'آدرس',
        'port': 'پورت',
        'uuid': 'شناسه کاربر (UUID)',
        'password': 'رمز عبور',
        'security': 'امنیت',
        'type': 'شبکه',
        'net': 'شبکه',
        'tls': 'TLS',
        'sni': 'SNI',
        'host': 'هدر Host',
        'path': 'مسیر',
        'fp': 'اثر انگشت',
        'alpn': 'ALPN',
        'flow': 'Flow',
        'pbk': 'کلید عمومی',
        'sid': 'Short ID',
        'spx': 'مسیر Spider',
        'encryption': 'رمزنگاری',
        'headerType': 'نوع هدر',
        'serviceName': 'نام سرویس gRPC',
        'mode': 'حالت',
        'method': 'الگوریتم',
        'allowInsecure': 'اجازه اتصال ناامن',
        'insecure': 'اجازه اتصال ناامن',
        'aid': 'Alter ID',
        'scy': 'الگوریتم',
        'obfs': 'مبهم‌سازی',
        'obfs-password': 'رمز مبهم‌سازی',
      }[key] ??
      key;
  @override
  String get theme => 'تم';
  @override
  String get themeSystem => 'سیستم';
  @override
  String get themeLight => 'روشن';
  @override
  String get themeDark => 'تاریک';

  @override
  String get fetchingList => 'در حال دریافت لیست کانفیگ‌ها...';
  @override
  String testingServers(int n) => 'در حال تست سرعت $n سرور...';
  @override
  String foundActive(int n) => '$n سرور فعال پیدا شد...';
  @override
  String get testingSaved => 'در حال تست سرورهای ذخیره‌شده...';
  @override
  String get allSourcesFailed =>
      'هیچ‌کدام از منابع در دسترس نبود. لینک اشتراک یا کانفیگ را دستی اضافه کنید.';
  @override
  String fetchFailed(Object e) => 'خطا در دریافت لیست: $e';
  @override
  String get noActiveServer => 'سرور فعالی پیدا نشد؛ دوباره امتحان کنید.';
  @override
  String get adding => 'در حال افزودن...';
  @override
  String get noValidConfig => 'کانفیگ معتبری پیدا نشد.';
  @override
  String importResult(int alive, int total) =>
      '$alive از $total کانفیگ فعال بود.';
  @override
  String importFailed(Object e) => 'افزودن ناموفق بود: $e';
  @override
  String subscriptionUpdated(int n) => 'اشتراک به‌روز شد: $n کانفیگ.';
  @override
  String get vpnPermissionDenied => 'مجوز VPN داده نشد.';
  @override
  String connectFailed(String reason) => 'اتصال برقرار نشد: $reason';
}
