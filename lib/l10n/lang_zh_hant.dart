import 'strings.dart';

class SZhHant implements S {
  const SZhHant();

  @override
  String get connected => '已連線';
  @override
  String get disconnected => '未連線';
  @override
  String get connecting => '正在連線...';
  @override
  String get disconnecting => '正在中斷...';
  @override
  String get connectionError => '連線錯誤';
  @override
  String get autoFastest => '自動（最低延遲）';
  @override
  String activeServers(int n) => '${n} 個可用伺服器';
  @override
  String get collectorGroup => '公共伺服器';
  @override
  String get manualGroup => '手動新增';
  @override
  String get emptyGroup => '這裡還沒有設定。';
  @override
  String get add => '新增';
  @override
  String get cancel => '取消';
  @override
  String get save => '儲存';
  @override
  String get delete => '刪除';
  @override
  String get edit => '編輯';
  @override
  String get share => '分享';
  @override
  String get ping => 'Ping';
  @override
  String get refreshList => '重新整理';
  @override
  String get settings => '設定';
  @override
  String get more => '更多';
  @override
  String get timeout => '逾時';
  @override
  String get addFromClipboard => '從剪貼簿新增';
  @override
  String get addFromFile => '從檔案新增';
  @override
  String get scanQr => '掃描 QR 碼';
  @override
  String get clipboardEmpty => '剪貼簿中沒有設定或訂閱連結。';
  @override
  String get scanTitle => '掃描 QR 碼';
  @override
  String get pickFromGallery => '從相簿選擇';
  @override
  String get noQrFound => '圖片中找不到 QR 碼。';
  @override
  String get cameraDenied => '無法使用相機，請檢查權限。';
  @override
  String get editConfigTitle => '編輯設定';
  @override
  String get editSubscriptionTitle => '編輯訂閱';
  @override
  String get subscriptionName => '名稱';
  @override
  String get subscriptionUrl => '訂閱連結';
  @override
  String get invalidConfig => '這不是支援的設定連結。';
  @override
  String get invalidUrl => '請輸入有效的 http(s) 連結。';
  @override
  String get copyConfig => '複製設定';
  @override
  String get copySubscriptionLink => '複製訂閱連結';
  @override
  String get copied => '已複製';
  @override
  String get qrCode => 'QR 碼';
  @override
  String get shareImage => '分享圖片';
  @override
  String get saveToGallery => '儲存到相簿';
  @override
  String get savedToGallery => '已儲存到相簿';
  @override
  String saveFailed(Object e) => '儲存失敗：${e}';
  @override
  String get password => '密碼';
  @override
  String get ok => '確定';
  @override
  String get tcping => 'TCPing';
  @override
  String get realDelay => '真實延遲';
  @override
  String get realDelayNeedsDisconnect => '真實延遲只能在中斷連線時測量。';
  @override
  String get advanced => '進階';
  @override
  String get language => '語言';
  @override
  String get languageSystem => '跟隨手機';
  @override
  String get scanHint => '請將 QR 碼放入方框內';
  @override
  String get downloadLabel => '下載';
  @override
  String get uploadLabel => '上傳';
  @override
  String get sessionLabel => '本次連線';
  @override
  String listLoaded(int n) => '清單已載入：${n} 個設定。';
  @override
  String addedConfigs(int n) => '已新增 ${n} 個設定。';
  @override
  String get subSettings => '訂閱設定';
  @override
  String get appSettings => '應用程式設定';
  @override
  String get uiSettings => '介面設定';
  @override
  String get coreSettings => '核心設定';
  @override
  String get autoUpdateSubs => '自動更新訂閱';
  @override
  String get autoUpdateSubsDesc => '在背景依設定的時間間隔自動更新訂閱。視裝置而定，可能無法運作。';
  @override
  String get updateOnStartup => '啟動應用程式時自動更新訂閱';
  @override
  String get updateOnStartupDesc => '啟動應用程式時依時間間隔自動更新訂閱。適用於背景自動更新無效的情況。';
  @override
  String get allowInsecure => '允許不安全連線';
  @override
  String get allowInsecureDesc => '忽略 SSL 憑證驗證';
  @override
  String get autoConnect => '開機自動連線';
  @override
  String get autoConnectDesc => '開機後自動使用所選設定連線，可能不會成功。視裝置而定，此功能不一定總是有效。';
  @override
  String get restartOnChange => '變更設定時重新啟動';
  @override
  String get restartOnChangeDesc => '變更設定時自動重新啟動服務';
  @override
  String get confirmDelete => '刪除確認';
  @override
  String get confirmDeleteDesc => '刪除資料前需要確認';
  @override
  String get uiMode => '顯示模式';
  @override
  String get showSpeed => '顯示速度';
  @override
  String get showSpeedDesc => '在通知中顯示目前速度和流量';
  @override
  String get delayUrlTitle => '真實延遲測試網址 (http/https)';
  @override
  String get resetDefault => '還原預設值';
  @override
  String get batteryTitle => '電池最佳化';
  @override
  String get batteryMessage => '為了讓連線在背景持續運作，請允許 Kumo 不受電池最佳化限制。';
  @override
  String get batteryAllow => '允許';
  @override
  String get later => '稍後';
  @override
  String get batteryDone => 'Kumo 的電池最佳化已經關閉。';
  @override
  String get unsupportedFile => '無法在此開啟該檔案。';
  @override
  String get deleteQuestion => '要刪除嗎？';
  @override
  String get deleteWarning => '此操作無法復原。';
  @override
  String daysLeft(int n) => '剩餘 ${n} 天';
  @override
  String hoursLeft(int n) => '剩餘 ${n} 小時';
  @override
  String minutesLeft(int n) => '剩餘 ${n} 分鐘';
  @override
  String get expired => '已過期';
  @override
  String get unlimitedTime => '不限時間';
  @override
  String get noSubInfo => '此服務商未提供用量資訊';
  @override
  String get logs => '記錄';
  @override
  String get logsDesc => '連線錯誤與應用程式執行的操作';
  @override
  String get logsEmpty => '尚無記錄。';
  @override
  String get clearLogs => '清除';
  @override
  String get copyLogs => '複製全部';
  @override
  String get removeDeadTitle => '真實延遲測試';
  @override
  String get removeDeadOption => '刪除沒有回應的設定';
  @override
  String get start => '開始';
  @override
  String testStat(int alive, int percent) => '${alive} 個可用 · ${percent}%';
  @override
  String get timeWord => '時間';
  @override
  String get unlimitedData => '不限流量';
  @override
  String usedOf(String used, String total) => '已用 ${used} / ${total}';
  @override
  String usedUnlimited(String used) => '已用 ${used}';
  @override
  String get theme => '主題';
  @override
  String get themeSystem => '跟隨系統';
  @override
  String get themeLight => '淺色';
  @override
  String get themeDark => '深色';
  @override
  String get fetchingList => '正在下載設定清單...';
  @override
  String testingServers(int n) => '正在測試 ${n} 個伺服器...';
  @override
  String foundActive(int n) => '已找到 ${n} 個可用伺服器...';
  @override
  String get testingSaved => '正在測試已儲存的伺服器...';
  @override
  String get allSourcesFailed => '所有來源都無法連線。請手動新增訂閱連結或設定。';
  @override
  String fetchFailed(Object e) => '無法下載清單：${e}';
  @override
  String get noActiveServer => '找不到可用伺服器，請重試。';
  @override
  String get adding => '正在新增...';
  @override
  String get noValidConfig => '找不到有效設定。';
  @override
  String importResult(int alive, int total) => '${total} 個設定中有 ${alive} 個可用。';
  @override
  String importFailed(Object e) => '無法新增：${e}';
  @override
  String subscriptionUpdated(int n) => '訂閱已更新：${n} 個設定。';
  @override
  String get vpnPermissionDenied => '未授予 VPN 權限。';
  @override
  String connectFailed(String reason) => '無法連線：${reason}';
  @override
  String get nameSubscription => '為這個訂閱取個名稱';
  @override
  String get showCollector => '公共伺服器';
  @override
  String get showCollectorDesc => '顯示免費公共伺服器清單';
  @override
  String fieldLabel(String key) =>
      const {
        'name': '名稱',
        'address': '位址',
        'port': '連接埠',
        'uuid': '使用者 ID (UUID)',
        'password': '密碼',
        'security': '安全性',
        'type': '網路',
        'net': '網路',
        'tls': 'TLS',
        'sni': 'SNI',
        'host': 'Host 標頭',
        'path': '路徑',
        'fp': '指紋',
        'alpn': 'ALPN',
        'flow': 'Flow',
        'pbk': '公開金鑰',
        'sid': 'Short ID',
        'spx': 'Spider 路徑',
        'encryption': '加密',
        'headerType': '標頭類型',
        'serviceName': 'gRPC 服務名稱',
        'mode': '模式',
        'method': '加密方式',
        'allowInsecure': '允許不安全',
        'insecure': '允許不安全',
        'aid': 'Alter ID',
        'scy': '加密方式',
        'obfs': '混淆',
        'obfs-password': '混淆密碼',
      }[key] ??
      key;
}
