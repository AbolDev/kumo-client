import 'strings.dart';

class SRu implements S {
  const SRu();

  @override
  String get connected => 'Подключено';
  @override
  String get disconnected => 'Отключено';
  @override
  String get connecting => 'Подключение...';
  @override
  String get disconnecting => 'Отключение...';
  @override
  String get connectionError => 'Ошибка подключения';
  @override
  String get autoFastest => 'Авто (минимальный пинг)';
  @override
  String activeServers(int n) => 'Активных серверов: ${n}';
  @override
  String get collectorGroup => 'Публичные серверы';
  @override
  String get manualGroup => 'Добавлено вручную';
  @override
  String get emptyGroup => 'Здесь пока нет конфигураций.';
  @override
  String get add => 'Добавить';
  @override
  String get cancel => 'Отмена';
  @override
  String get save => 'Сохранить';
  @override
  String get delete => 'Удалить';
  @override
  String get edit => 'Изменить';
  @override
  String get share => 'Поделиться';
  @override
  String get ping => 'Пинг';
  @override
  String get refreshList => 'Обновить';
  @override
  String get settings => 'Настройки';
  @override
  String get more => 'Ещё';
  @override
  String get timeout => 'тайм-аут';
  @override
  String get addFromClipboard => 'Добавить из буфера';
  @override
  String get addFromFile => 'Добавить из файла';
  @override
  String get scanQr => 'Сканировать QR-код';
  @override
  String get clipboardEmpty =>
      'В буфере обмена нет конфигурации или ссылки подписки.';
  @override
  String get scanTitle => 'Сканировать QR-код';
  @override
  String get pickFromGallery => 'Выбрать из галереи';
  @override
  String get noQrFound => 'На изображении не найден QR-код.';
  @override
  String get cameraDenied => 'Камера недоступна. Проверьте разрешение.';
  @override
  String get editConfigTitle => 'Изменить конфигурацию';
  @override
  String get editSubscriptionTitle => 'Изменить подписку';
  @override
  String get subscriptionName => 'Название';
  @override
  String get subscriptionUrl => 'Ссылка подписки';
  @override
  String get invalidConfig => 'Это не поддерживаемая ссылка конфигурации.';
  @override
  String get invalidUrl => 'Введите корректную ссылку http(s).';
  @override
  String get copyConfig => 'Копировать конфигурацию';
  @override
  String get copySubscriptionLink => 'Копировать ссылку подписки';
  @override
  String get copied => 'Скопировано';
  @override
  String get qrCode => 'QR-код';
  @override
  String get shareImage => 'Поделиться изображением';
  @override
  String get saveToGallery => 'Сохранить в галерею';
  @override
  String get savedToGallery => 'Сохранено в галерею';
  @override
  String saveFailed(Object e) => 'Не удалось сохранить: ${e}';
  @override
  String get password => 'Пароль';
  @override
  String get ok => 'OK';
  @override
  String get tcping => 'TCPing';
  @override
  String get realDelay => 'Реальная задержка';
  @override
  String get realDelayNeedsDisconnect =>
      'Реальную задержку можно измерить только при отключённом VPN.';
  @override
  String get advanced => 'Дополнительно';
  @override
  String get language => 'Язык';
  @override
  String get languageSystem => 'Как в телефоне';
  @override
  String get scanHint => 'Поместите QR-код в рамку';
  @override
  String get downloadLabel => 'Загрузка';
  @override
  String get uploadLabel => 'Отдача';
  @override
  String get sessionLabel => 'За сеанс';
  @override
  String listLoaded(int n) => 'Список загружен: ${n} конфигураций.';
  @override
  String addedConfigs(int n) => 'Добавлено конфигураций: ${n}.';
  @override
  String get subSettings => 'Настройки подписок';
  @override
  String get appSettings => 'Настройки приложения';
  @override
  String get uiSettings => 'Настройки интерфейса';
  @override
  String get coreSettings => 'Настройки ядра';
  @override
  String get autoUpdateSubs => 'Автообновление подписок';
  @override
  String get autoUpdateSubsDesc =>
      'Подписки обновляются автоматически через заданные промежутки времени в фоне. На некоторых устройствах может не работать.';
  @override
  String get updateOnStartup => 'Обновлять подписки при запуске';
  @override
  String get updateOnStartupDesc =>
      'Подписки обновляются при запуске приложения с заданным интервалом. Подходит, если фоновое обновление не работает.';
  @override
  String get allowInsecure => 'Разрешить небезопасное подключение';
  @override
  String get allowInsecureDesc => 'Не проверять SSL-сертификаты';
  @override
  String get autoConnect => 'Автоподключение при включении устройства';
  @override
  String get autoConnectDesc =>
      'При включении устройства автоматически подключается с выбранной конфигурацией; может не получиться. На некоторых устройствах функция работает не всегда.';
  @override
  String get restartOnChange => 'Перезапуск при смене настроек';
  @override
  String get restartOnChangeDesc =>
      'Автоматически перезапускать службу при смене конфигурации или настроек';
  @override
  String get confirmDelete => 'Подтверждение удаления';
  @override
  String get confirmDeleteDesc =>
      'Запрашивать подтверждение перед удалением данных';
  @override
  String get uiMode => 'Режим отображения';
  @override
  String get showSpeed => 'Показывать скорость';
  @override
  String get showSpeedDesc =>
      'Показывать текущую скорость и объём трафика в уведомлении';
  @override
  String get delayUrlTitle => 'URL проверки реальной задержки (http/https)';
  @override
  String get resetDefault => 'Сбросить по умолчанию';
  @override
  String get batteryTitle => 'Оптимизация батареи';
  @override
  String get batteryMessage =>
      'Чтобы соединение работало в фоне, разрешите Kumo работать без ограничений оптимизации батареи.';
  @override
  String get batteryAllow => 'Разрешить';
  @override
  String get later => 'Позже';
  @override
  String get batteryDone => 'Оптимизация батареи для Kumo уже отключена.';
  @override
  String get unsupportedFile => 'Этот файл нельзя открыть здесь.';
  @override
  String get deleteQuestion => 'Удалить?';
  @override
  String get deleteWarning => 'Это действие нельзя отменить.';
  @override
  String daysLeft(int n) => 'Осталось дней: ${n}';
  @override
  String hoursLeft(int n) => 'Осталось часов: ${n}';
  @override
  String minutesLeft(int n) => 'Осталось минут: ${n}';
  @override
  String get expired => 'Истекла';
  @override
  String get unlimitedTime => 'Без ограничения по времени';
  @override
  String get noSubInfo => 'Провайдер не предоставляет данные об использовании';
  @override
  String get logs => 'Журнал';
  @override
  String get logsDesc => 'Ошибки подключения и действия приложения';
  @override
  String get logsEmpty => 'Записей пока нет.';
  @override
  String get clearLogs => 'Очистить';
  @override
  String get copyLogs => 'Копировать всё';
  @override
  String get removeDeadTitle => 'Проверка реальной задержки';
  @override
  String get removeDeadOption => 'Удалить конфигурации, которые не отвечают';
  @override
  String get start => 'Начать';
  @override
  String testStat(int alive, int percent) => 'Работают: ${alive} · ${percent}%';
  @override
  String get timeWord => 'Время';
  @override
  String get unlimitedData => 'Безлимитный трафик';
  @override
  String usedOf(String used, String total) =>
      'Использовано ${used} из ${total}';
  @override
  String usedUnlimited(String used) => 'Использовано ${used}';
  @override
  String get theme => 'Тема';
  @override
  String get themeSystem => 'Системная';
  @override
  String get themeLight => 'Светлая';
  @override
  String get themeDark => 'Тёмная';
  @override
  String get fetchingList => 'Загрузка списка конфигураций...';
  @override
  String testingServers(int n) => 'Проверка серверов: ${n}...';
  @override
  String foundActive(int n) => 'Найдено активных серверов: ${n}...';
  @override
  String get testingSaved => 'Проверка сохранённых серверов...';
  @override
  String get allSourcesFailed =>
      'Ни один источник недоступен. Добавьте ссылку подписки или конфигурацию вручную.';
  @override
  String fetchFailed(Object e) => 'Не удалось загрузить список: ${e}';
  @override
  String get noActiveServer => 'Активный сервер не найден. Попробуйте снова.';
  @override
  String get adding => 'Добавление...';
  @override
  String get noValidConfig => 'Допустимая конфигурация не найдена.';
  @override
  String importResult(int alive, int total) =>
      'Активны ${alive} из ${total} конфигураций.';
  @override
  String importFailed(Object e) => 'Не удалось добавить: ${e}';
  @override
  String subscriptionUpdated(int n) => 'Подписка обновлена: ${n} конфигураций.';
  @override
  String get vpnPermissionDenied => 'Разрешение VPN не предоставлено.';
  @override
  String connectFailed(String reason) => 'Не удалось подключиться: ${reason}';
  @override
  String get nameSubscription => 'Назовите эту подписку';
  @override
  String get showCollector => 'Публичные серверы';
  @override
  String get showCollectorDesc =>
      'Показывать список бесплатных публичных серверов';
  @override
  String fieldLabel(String key) =>
      const {
        'name': 'Имя',
        'address': 'Адрес',
        'port': 'Порт',
        'uuid': 'ID пользователя (UUID)',
        'password': 'Пароль',
        'security': 'Безопасность',
        'type': 'Сеть',
        'net': 'Сеть',
        'tls': 'TLS',
        'sni': 'SNI',
        'host': 'Заголовок Host',
        'path': 'Путь',
        'fp': 'Отпечаток',
        'alpn': 'ALPN',
        'flow': 'Flow',
        'pbk': 'Открытый ключ',
        'sid': 'Short ID',
        'spx': 'Путь Spider',
        'encryption': 'Шифрование',
        'headerType': 'Тип заголовка',
        'serviceName': 'Имя службы gRPC',
        'mode': 'Режим',
        'method': 'Шифр',
        'allowInsecure': 'Разрешить небезопасное',
        'insecure': 'Разрешить небезопасное',
        'aid': 'Alter ID',
        'scy': 'Шифр',
        'obfs': 'Обфускация',
        'obfs-password': 'Пароль обфускации',
      }[key] ??
      key;
}
