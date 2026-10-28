import 'strings.dart';

class SZhHans implements S {
  const SZhHans();

  @override
  String get connected => '已连接';
  @override
  String get disconnected => '未连接';
  @override
  String get connecting => '正在连接...';
  @override
  String get disconnecting => '正在断开...';
  @override
  String get connectionError => '连接错误';
  @override
  String get autoFastest => '自动（最低延迟）';
  @override
  String activeServers(int n) => '$n 个可用服务器';
  @override
  String get collectorGroup => '公共服务器';
  @override
  String get manualGroup => '手动添加';
  @override
  String get emptyGroup => '这里还没有配置。';
  @override
  String get add => '添加';
  @override
  String get cancel => '取消';
  @override
  String get save => '保存';
  @override
  String get delete => '删除';
  @override
  String get edit => '编辑';
  @override
  String get share => '分享';
  @override
  String get ping => 'Ping';
  @override
  String get refreshList => '刷新';
  @override
  String get settings => '设置';
  @override
  String get more => '更多';
  @override
  String get timeout => '超时';
  @override
  String get addFromClipboard => '从剪贴板添加';
  @override
  String get addFromFile => '从文件添加';
  @override
  String get scanQr => '扫描二维码';
  @override
  String get clipboardEmpty => '剪贴板中没有配置或订阅链接。';
  @override
  String get scanTitle => '扫描二维码';
  @override
  String get pickFromGallery => '从相册选择';
  @override
  String get noQrFound => '图片中未找到二维码。';
  @override
  String get cameraDenied => '无法使用相机，请检查权限。';
  @override
  String get editConfigTitle => '编辑配置';
  @override
  String get editSubscriptionTitle => '编辑订阅';
  @override
  String get subscriptionName => '名称';
  @override
  String get subscriptionUrl => '订阅链接';
  @override
  String get invalidConfig => '这不是受支持的配置链接。';
  @override
  String get invalidUrl => '请输入有效的 http(s) 链接。';
  @override
  String get copyConfig => '复制配置';
  @override
  String get copySubscriptionLink => '复制订阅链接';
  @override
  String get copied => '已复制';
  @override
  String get qrCode => '二维码';
  @override
  String get shareImage => '分享图片';
  @override
  String get saveToGallery => '保存到相册';
  @override
  String get savedToGallery => '已保存到相册';
  @override
  String saveFailed(Object e) => '保存失败：$e';
  @override
  String get password => '密码';
  @override
  String get ok => '确定';
  @override
  String get tcping => 'TCPing';
  @override
  String get realDelay => '真实延迟';
  @override
  String get realDelayNeedsDisconnect => '真实延迟只能在断开连接时测量。';
  @override
  String get advanced => '高级';
  @override
  String get language => '语言';
  @override
  String get languageSystem => '跟随手机';
  @override
  String get scanHint => '请将二维码放入方框内';
  @override
  String get downloadLabel => '下载';
  @override
  String get uploadLabel => '上传';
  @override
  String get sessionLabel => '本次连接';
  @override
  String listLoaded(int n) => '列表已加载：$n 个配置。';
  @override
  String addedConfigs(int n) => '已添加 $n 个配置。';
  @override
  String get subSettings => '订阅设置';
  @override
  String get appSettings => '应用设置';
  @override
  String get uiSettings => '界面设置';
  @override
  String get coreSettings => '核心设置';
  @override
  String get autoUpdateSubs => '自动更新订阅';
  @override
  String get autoUpdateSubsDesc => '在后台按设定的时间间隔自动更新订阅。取决于设备，可能无法生效。';
  @override
  String get updateOnStartup => '启动应用时自动更新订阅';
  @override
  String get updateOnStartupDesc => '启动应用时按时间间隔自动更新订阅。适用于后台自动更新不起作用的情况。';
  @override
  String get allowInsecure => '允许不安全连接';
  @override
  String get allowInsecureDesc => '即使提供商的证书无法验证也下载订阅。关闭更安全；这不影响你的服务器的检查方式。';
  @override
  String get autoConnect => '开机自动连接';
  @override
  String get autoConnectDesc => '开机后自动使用所选配置连接，可能不会成功。取决于设备，此功能不一定总是有效。';
  @override
  String get restartOnChange => '更改设置时重启';
  @override
  String get restartOnChangeDesc => '更改配置或设置时自动重启服务';
  @override
  String get confirmDelete => '删除确认';
  @override
  String get confirmDeleteDesc => '删除数据前需要确认';
  @override
  String get uiMode => '显示模式';
  @override
  String get showSpeed => '显示速度';
  @override
  String get showSpeedDesc => '在通知中显示当前速度和流量';
  @override
  String get delayUrlTitle => '真实延迟测试地址 (http/https)';
  @override
  String get resetDefault => '恢复默认';
  @override
  String get batteryTitle => '电池优化';
  @override
  String get batteryMessage => '为了让连接在后台保持运行，请允许 Kumo 不受电池优化限制。';
  @override
  String get batteryAllow => '允许';
  @override
  String get later => '稍后';
  @override
  String get batteryDone => 'Kumo 的电池优化已经关闭。';
  @override
  String get unsupportedFile => '无法在此打开该文件。';
  @override
  String get deleteQuestion => '要删除吗？';
  @override
  String get deleteWarning => '此操作无法撤销。';
  @override
  String daysLeft(int n) => '剩余 $n 天';
  @override
  String hoursLeft(int n) => '剩余 $n 小时';
  @override
  String minutesLeft(int n) => '剩余 $n 分钟';
  @override
  String get expired => '已过期';
  @override
  String get unlimitedTime => '不限时间';
  @override
  String get noSubInfo => '该服务商未提供用量信息';
  @override
  String get logs => '日志';
  @override
  String get logsDesc => '连接错误和应用执行的操作';
  @override
  String get logsEmpty => '暂无日志。';
  @override
  String get clearLogs => '清除';
  @override
  String get copyLogs => '复制全部';
  @override
  String get removeDeadTitle => '真实延迟测试';
  @override
  String get removeDeadOption => '删除无响应的配置';
  @override
  String get start => '开始';
  @override
  String testStat(int alive, int percent) => '$alive 个可用 · $percent%';
  @override
  String get timeWord => '时间';
  @override
  String get unlimitedData => '不限流量';
  @override
  String usedOf(String used, String total) => '已用 $used / $total';
  @override
  String usedUnlimited(String used) => '已用 $used';
  @override
  String get theme => '主题';
  @override
  String get themeSystem => '跟随系统';
  @override
  String get themeLight => '浅色';
  @override
  String get themeDark => '深色';
  @override
  String get fetchingList => '正在下载配置列表...';
  @override
  String testingServers(int n) => '正在测试 $n 个服务器...';
  @override
  String foundActive(int n) => '已找到 $n 个可用服务器...';
  @override
  String get testingSaved => '正在测试已保存的服务器...';
  @override
  String get allSourcesFailed => '所有来源都无法访问。请手动添加订阅链接或配置。';
  @override
  String fetchFailed(Object e) => '无法下载列表：$e';
  @override
  String get noActiveServer => '未找到可用服务器，请重试。';
  @override
  String get adding => '正在添加...';
  @override
  String get noValidConfig => '未找到有效配置。';
  @override
  String importResult(int alive, int total) => '$total 个配置中有 $alive 个可用。';
  @override
  String importFailed(Object e) => '无法添加：$e';
  @override
  String subscriptionUpdated(int n) => '订阅已更新：$n 个配置。';
  @override
  String get vpnPermissionDenied => '未授予 VPN 权限。';
  @override
  String connectFailed(String reason) => '无法连接：$reason';
  @override
  String get nameSubscription => '为这个订阅起个名字';
  @override
  String get showCollector => '公共服务器';
  @override
  String get showCollectorDesc => '显示免费公共服务器列表';
  @override
  String fieldLabel(String key) =>
      const {
        'name': '名称',
        'address': '地址',
        'port': '端口',
        'uuid': '用户 ID (UUID)',
        'password': '密码',
        'security': '安全',
        'type': '网络',
        'net': '网络',
        'tls': 'TLS',
        'sni': 'SNI',
        'host': 'Host 头',
        'path': '路径',
        'fp': '指纹',
        'alpn': 'ALPN',
        'flow': 'Flow',
        'pbk': '公钥',
        'sid': 'Short ID',
        'spx': 'Spider 路径',
        'encryption': '加密',
        'headerType': '头部类型',
        'serviceName': 'gRPC 服务名',
        'mode': '模式',
        'method': '加密方式',
        'allowInsecure': '允许不安全',
        'insecure': '允许不安全',
        'aid': 'Alter ID',
        'scy': '加密方式',
        'obfs': '混淆',
        'obfs-password': '混淆密码',
      }[key] ??
      key;
}
