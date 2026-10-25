import 'strings.dart';

class SAr implements S {
  const SAr();

  @override
  String get connected => 'متصل';
  @override
  String get disconnected => 'غير متصل';
  @override
  String get connecting => 'جارٍ الاتصال...';
  @override
  String get disconnecting => 'جارٍ قطع الاتصال...';
  @override
  String get connectionError => 'خطأ في الاتصال';
  @override
  String get autoFastest => 'تلقائي (أقل بينغ)';
  @override
  String activeServers(int n) => '${n} خوادم نشطة';
  @override
  String get collectorGroup => 'الخوادم العامة';
  @override
  String get manualGroup => 'مضافة يدويًا';
  @override
  String get emptyGroup => 'لا توجد إعدادات هنا بعد.';
  @override
  String get add => 'إضافة';
  @override
  String get cancel => 'إلغاء';
  @override
  String get save => 'حفظ';
  @override
  String get delete => 'حذف';
  @override
  String get edit => 'تعديل';
  @override
  String get share => 'مشاركة';
  @override
  String get ping => 'بينغ';
  @override
  String get refreshList => 'تحديث';
  @override
  String get settings => 'الإعدادات';
  @override
  String get more => 'المزيد';
  @override
  String get timeout => 'انتهت المهلة';
  @override
  String get addFromClipboard => 'إضافة من الحافظة';
  @override
  String get addFromFile => 'إضافة من ملف';
  @override
  String get scanQr => 'مسح رمز QR';
  @override
  String get clipboardEmpty => 'لا تحتوي الحافظة على إعداد أو رابط اشتراك.';
  @override
  String get scanTitle => 'مسح رمز QR';
  @override
  String get pickFromGallery => 'اختيار من المعرض';
  @override
  String get noQrFound => 'لم يتم العثور على رمز QR في الصورة.';
  @override
  String get cameraDenied => 'الكاميرا غير متاحة. تحقق من الإذن.';
  @override
  String get editConfigTitle => 'تعديل الإعداد';
  @override
  String get editSubscriptionTitle => 'تعديل الاشتراك';
  @override
  String get subscriptionName => 'الاسم';
  @override
  String get subscriptionUrl => 'رابط الاشتراك';
  @override
  String get invalidConfig => 'هذا ليس رابط إعداد مدعومًا.';
  @override
  String get invalidUrl => 'أدخل رابط http(s) صالحًا.';
  @override
  String get copyConfig => 'نسخ الإعداد';
  @override
  String get copySubscriptionLink => 'نسخ رابط الاشتراك';
  @override
  String get copied => 'تم النسخ';
  @override
  String get qrCode => 'رمز QR';
  @override
  String get shareImage => 'مشاركة الصورة';
  @override
  String get saveToGallery => 'حفظ في المعرض';
  @override
  String get savedToGallery => 'تم الحفظ في المعرض';
  @override
  String saveFailed(Object e) => 'تعذّر الحفظ: ${e}';
  @override
  String get password => 'كلمة المرور';
  @override
  String get ok => 'موافق';
  @override
  String get tcping => 'TCPing';
  @override
  String get realDelay => 'التأخير الفعلي';
  @override
  String get realDelayNeedsDisconnect =>
      'لا يمكن قياس التأخير الفعلي إلا أثناء قطع الاتصال.';
  @override
  String get advanced => 'متقدم';
  @override
  String get language => 'اللغة';
  @override
  String get languageSystem => 'مثل الهاتف';
  @override
  String get scanHint => 'ضع رمز QR داخل المربع';
  @override
  String get downloadLabel => 'تنزيل';
  @override
  String get uploadLabel => 'رفع';
  @override
  String get sessionLabel => 'هذه الجلسة';
  @override
  String listLoaded(int n) => 'تم تحميل القائمة: ${n} إعدادات.';
  @override
  String addedConfigs(int n) => 'تمت إضافة ${n} إعدادات.';
  @override
  String get subSettings => 'إعدادات الاشتراكات';
  @override
  String get appSettings => 'إعدادات التطبيق';
  @override
  String get uiSettings => 'إعدادات الواجهة';
  @override
  String get coreSettings => 'إعدادات النواة';
  @override
  String get autoUpdateSubs => 'تحديث الاشتراكات تلقائيًا';
  @override
  String get autoUpdateSubsDesc =>
      'تحديث الاشتراكات تلقائيًا على فترات محددة في الخلفية. قد لا يعمل حسب الجهاز.';
  @override
  String get updateOnStartup => 'تحديث الاشتراكات عند تشغيل التطبيق';
  @override
  String get updateOnStartupDesc =>
      'تحديث الاشتراكات بفاصل زمني عند فتح التطبيق. مفيد إذا لم يعمل التحديث التلقائي في الخلفية.';
  @override
  String get allowInsecure => 'السماح بالاتصال غير الآمن';
  @override
  String get allowInsecureDesc => 'تجاهل التحقق من شهادات SSL';
  @override
  String get autoConnect => 'الاتصال تلقائيًا عند تشغيل الجهاز';
  @override
  String get autoConnectDesc =>
      'يتصل تلقائيًا بالإعداد المحدد عند التشغيل، وقد لا ينجح. حسب الجهاز، قد لا تعمل هذه الميزة دائمًا.';
  @override
  String get restartOnChange => 'إعادة التشغيل عند تغيير الإعدادات';
  @override
  String get restartOnChangeDesc =>
      'إعادة تشغيل الخدمة تلقائيًا عند تغيير الإعداد أو الإعدادات';
  @override
  String get confirmDelete => 'تأكيد الحذف';
  @override
  String get confirmDeleteDesc => 'طلب التأكيد قبل حذف البيانات';
  @override
  String get uiMode => 'وضع العرض';
  @override
  String get showSpeed => 'عرض السرعة';
  @override
  String get showSpeedDesc => 'عرض السرعة الحالية وحجم الاستهلاك في الإشعار';
  @override
  String get delayUrlTitle => 'عنوان اختبار التأخير الفعلي (http/https)';
  @override
  String get resetDefault => 'إعادة الضبط الافتراضي';
  @override
  String get batteryTitle => 'تحسين البطارية';
  @override
  String get batteryMessage =>
      'للحفاظ على الاتصال في الخلفية، اسمح لـ Kumo بالعمل دون قيود تحسين البطارية.';
  @override
  String get batteryAllow => 'السماح';
  @override
  String get later => 'لاحقًا';
  @override
  String get batteryDone => 'تحسين البطارية معطّل بالفعل لـ Kumo.';
  @override
  String get unsupportedFile => 'لا يمكن فتح هذا الملف هنا.';
  @override
  String get deleteQuestion => 'هل تريد الحذف؟';
  @override
  String get deleteWarning => 'لا يمكن التراجع عن هذا الإجراء.';
  @override
  String daysLeft(int n) => 'متبقي ${n} يوم';
  @override
  String hoursLeft(int n) => 'متبقي ${n} ساعة';
  @override
  String minutesLeft(int n) => 'متبقي ${n} دقيقة';
  @override
  String get expired => 'منتهي';
  @override
  String get unlimitedTime => 'وقت غير محدود';
  @override
  String get noSubInfo => 'هذا المزوّد لا يوفّر معلومات الاستهلاك';
  @override
  String get logs => 'السجلات';
  @override
  String get logsDesc => 'أخطاء الاتصال وما فعله التطبيق';
  @override
  String get logsEmpty => 'لا توجد سجلات بعد.';
  @override
  String get clearLogs => 'مسح';
  @override
  String get copyLogs => 'نسخ الكل';
  @override
  String get removeDeadTitle => 'اختبار التأخير الفعلي';
  @override
  String get removeDeadOption => 'حذف الإعدادات التي لا تستجيب';
  @override
  String get start => 'ابدأ';
  @override
  String testStat(int alive, int percent) => '${alive} تعمل · ${percent}٪';
  @override
  String get timeWord => 'الوقت';
  @override
  String get unlimitedData => 'بيانات غير محدودة';
  @override
  String usedOf(String used, String total) => 'تم استخدام ${used} من ${total}';
  @override
  String usedUnlimited(String used) => 'تم استخدام ${used}';
  @override
  String get theme => 'المظهر';
  @override
  String get themeSystem => 'النظام';
  @override
  String get themeLight => 'فاتح';
  @override
  String get themeDark => 'داكن';
  @override
  String get fetchingList => 'جارٍ تنزيل قائمة الإعدادات...';
  @override
  String testingServers(int n) => 'جارٍ اختبار ${n} خوادم...';
  @override
  String foundActive(int n) => 'تم العثور على ${n} خوادم نشطة...';
  @override
  String get testingSaved => 'جارٍ اختبار الخوادم المحفوظة...';
  @override
  String get allSourcesFailed =>
      'تعذّر الوصول إلى أي مصدر. أضف رابط اشتراك أو إعدادًا يدويًا.';
  @override
  String fetchFailed(Object e) => 'تعذّر تنزيل القائمة: ${e}';
  @override
  String get noActiveServer => 'لم يتم العثور على خادم نشط. حاول مرة أخرى.';
  @override
  String get adding => 'جارٍ الإضافة...';
  @override
  String get noValidConfig => 'لم يتم العثور على إعداد صالح.';
  @override
  String importResult(int alive, int total) =>
      '${alive} من ${total} إعدادات نشطة.';
  @override
  String importFailed(Object e) => 'تعذّرت الإضافة: ${e}';
  @override
  String subscriptionUpdated(int n) => 'تم تحديث الاشتراك: ${n} إعدادات.';
  @override
  String get vpnPermissionDenied => 'لم يتم منح إذن VPN.';
  @override
  String connectFailed(String reason) => 'تعذّر الاتصال: ${reason}';
  @override
  String get nameSubscription => 'سمِّ هذا الاشتراك';
  @override
  String get showCollector => 'الخوادم العامة';
  @override
  String get showCollectorDesc => 'عرض قائمة الخوادم العامة المجانية';
  @override
  String fieldLabel(String key) =>
      const {
        'name': 'الاسم',
        'address': 'العنوان',
        'port': 'المنفذ',
        'uuid': 'معرّف المستخدم (UUID)',
        'password': 'كلمة المرور',
        'security': 'الأمان',
        'type': 'الشبكة',
        'net': 'الشبكة',
        'tls': 'TLS',
        'sni': 'SNI',
        'host': 'ترويسة Host',
        'path': 'المسار',
        'fp': 'البصمة',
        'alpn': 'ALPN',
        'flow': 'Flow',
        'pbk': 'المفتاح العام',
        'sid': 'Short ID',
        'spx': 'مسار Spider',
        'encryption': 'التشفير',
        'headerType': 'نوع الترويسة',
        'serviceName': 'اسم خدمة gRPC',
        'mode': 'الوضع',
        'method': 'خوارزمية التشفير',
        'allowInsecure': 'السماح بغير الآمن',
        'insecure': 'السماح بغير الآمن',
        'aid': 'Alter ID',
        'scy': 'خوارزمية التشفير',
        'obfs': 'التمويه',
        'obfs-password': 'كلمة مرور التمويه',
      }[key] ??
      key;
}
