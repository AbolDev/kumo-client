import 'strings.dart';

class SVi implements S {
  const SVi();

  @override
  String get connected => 'Đã kết nối';
  @override
  String get disconnected => 'Chưa kết nối';
  @override
  String get connecting => 'Đang kết nối...';
  @override
  String get disconnecting => 'Đang ngắt kết nối...';
  @override
  String get connectionError => 'Lỗi kết nối';
  @override
  String get autoFastest => 'Tự động (ping thấp nhất)';
  @override
  String activeServers(int n) => '${n} máy chủ hoạt động';
  @override
  String get collectorGroup => 'Máy chủ công cộng';
  @override
  String get manualGroup => 'Thêm thủ công';
  @override
  String get emptyGroup => 'Chưa có cấu hình nào ở đây.';
  @override
  String get add => 'Thêm';
  @override
  String get cancel => 'Hủy';
  @override
  String get save => 'Lưu';
  @override
  String get delete => 'Xóa';
  @override
  String get edit => 'Sửa';
  @override
  String get share => 'Chia sẻ';
  @override
  String get ping => 'Ping';
  @override
  String get refreshList => 'Làm mới';
  @override
  String get settings => 'Cài đặt';
  @override
  String get more => 'Thêm';
  @override
  String get timeout => 'quá thời gian';
  @override
  String get addFromClipboard => 'Thêm từ bộ nhớ tạm';
  @override
  String get addFromFile => 'Thêm từ tệp';
  @override
  String get scanQr => 'Quét mã QR';
  @override
  String get clipboardEmpty =>
      'Bộ nhớ tạm không có cấu hình hoặc liên kết đăng ký.';
  @override
  String get scanTitle => 'Quét mã QR';
  @override
  String get pickFromGallery => 'Chọn từ thư viện ảnh';
  @override
  String get noQrFound => 'Không tìm thấy mã QR trong ảnh.';
  @override
  String get cameraDenied => 'Không dùng được camera. Hãy kiểm tra quyền.';
  @override
  String get editConfigTitle => 'Sửa cấu hình';
  @override
  String get editSubscriptionTitle => 'Sửa đăng ký';
  @override
  String get subscriptionName => 'Tên';
  @override
  String get subscriptionUrl => 'Liên kết đăng ký';
  @override
  String get invalidConfig => 'Đây không phải liên kết cấu hình được hỗ trợ.';
  @override
  String get invalidUrl => 'Nhập liên kết http(s) hợp lệ.';
  @override
  String get copyConfig => 'Sao chép cấu hình';
  @override
  String get copySubscriptionLink => 'Sao chép liên kết đăng ký';
  @override
  String get copied => 'Đã sao chép';
  @override
  String get qrCode => 'Mã QR';
  @override
  String get shareImage => 'Chia sẻ ảnh';
  @override
  String get saveToGallery => 'Lưu vào thư viện ảnh';
  @override
  String get savedToGallery => 'Đã lưu vào thư viện ảnh';
  @override
  String saveFailed(Object e) => 'Không lưu được: ${e}';
  @override
  String get password => 'Mật khẩu';
  @override
  String get ok => 'OK';
  @override
  String get tcping => 'TCPing';
  @override
  String get realDelay => 'Độ trễ thực';
  @override
  String get realDelayNeedsDisconnect =>
      'Chỉ đo được độ trễ thực khi đã ngắt kết nối.';
  @override
  String get advanced => 'Nâng cao';
  @override
  String get language => 'Ngôn ngữ';
  @override
  String get languageSystem => 'Theo điện thoại';
  @override
  String get scanHint => 'Đặt mã QR vào trong khung';
  @override
  String get downloadLabel => 'Tải xuống';
  @override
  String get uploadLabel => 'Tải lên';
  @override
  String get sessionLabel => 'Phiên này';
  @override
  String listLoaded(int n) => 'Đã tải danh sách: ${n} cấu hình.';
  @override
  String addedConfigs(int n) => 'Đã thêm ${n} cấu hình.';
  @override
  String get subSettings => 'Cài đặt đăng ký';
  @override
  String get appSettings => 'Cài đặt ứng dụng';
  @override
  String get uiSettings => 'Cài đặt giao diện';
  @override
  String get coreSettings => 'Cài đặt lõi';
  @override
  String get autoUpdateSubs => 'Tự động cập nhật đăng ký';
  @override
  String get autoUpdateSubsDesc =>
      'Tự động cập nhật đăng ký theo chu kỳ trong nền. Tùy thiết bị, có thể không hoạt động.';
  @override
  String get updateOnStartup => 'Tự động cập nhật đăng ký khi mở ứng dụng';
  @override
  String get updateOnStartupDesc =>
      'Cập nhật đăng ký theo chu kỳ khi mở ứng dụng. Dùng khi cập nhật tự động trong nền không hoạt động.';
  @override
  String get allowInsecure => 'Cho phép kết nối không an toàn';
  @override
  String get allowInsecureDesc => 'Bỏ qua việc xác thực chứng chỉ SSL';
  @override
  String get autoConnect => 'Tự động kết nối khi khởi động máy';
  @override
  String get autoConnectDesc =>
      'Tự động kết nối bằng cấu hình đã chọn khi khởi động, có thể không thành công. Tùy thiết bị, tính năng này không phải lúc nào cũng hoạt động.';
  @override
  String get restartOnChange => 'Khởi động lại khi đổi cài đặt';
  @override
  String get restartOnChangeDesc =>
      'Tự động khởi động lại dịch vụ khi đổi cấu hình hoặc cài đặt';
  @override
  String get confirmDelete => 'Xác nhận xóa';
  @override
  String get confirmDeleteDesc => 'Yêu cầu xác nhận trước khi xóa dữ liệu';
  @override
  String get uiMode => 'Chế độ hiển thị';
  @override
  String get showSpeed => 'Hiển thị tốc độ';
  @override
  String get showSpeedDesc =>
      'Hiển thị tốc độ hiện tại và lưu lượng trong thông báo';
  @override
  String get delayUrlTitle => 'URL kiểm tra độ trễ thực (http/https)';
  @override
  String get resetDefault => 'Đặt lại mặc định';
  @override
  String get batteryTitle => 'Tối ưu hóa pin';
  @override
  String get batteryMessage =>
      'Để giữ kết nối hoạt động trong nền, hãy cho phép Kumo chạy không bị giới hạn bởi tối ưu hóa pin.';
  @override
  String get batteryAllow => 'Cho phép';
  @override
  String get later => 'Để sau';
  @override
  String get batteryDone => 'Tối ưu hóa pin đã được tắt cho Kumo.';
  @override
  String get unsupportedFile => 'Không thể mở tệp này tại đây.';
  @override
  String get deleteQuestion => 'Xóa?';
  @override
  String get deleteWarning => 'Hành động này không thể hoàn tác.';
  @override
  String daysLeft(int n) => 'Còn ${n} ngày';
  @override
  String hoursLeft(int n) => 'Còn ${n} giờ';
  @override
  String minutesLeft(int n) => 'Còn ${n} phút';
  @override
  String get expired => 'Đã hết hạn';
  @override
  String get unlimitedTime => 'Không giới hạn thời gian';
  @override
  String get noSubInfo => 'Nhà cung cấp này không cung cấp thông tin sử dụng';
  @override
  String get logs => 'Nhật ký';
  @override
  String get logsDesc => 'Lỗi kết nối và những gì ứng dụng đã làm';
  @override
  String get logsEmpty => 'Chưa có nhật ký.';
  @override
  String get clearLogs => 'Xóa';
  @override
  String get copyLogs => 'Sao chép tất cả';
  @override
  String get removeDeadTitle => 'Kiểm tra độ trễ thực';
  @override
  String get removeDeadOption => 'Xóa các cấu hình không phản hồi';
  @override
  String get start => 'Bắt đầu';
  @override
  String testStat(int alive, int percent) => '${alive} hoạt động · ${percent}%';
  @override
  String get timeWord => 'Thời gian';
  @override
  String get unlimitedData => 'Không giới hạn dung lượng';
  @override
  String usedOf(String used, String total) => 'Đã dùng ${used} / ${total}';
  @override
  String usedUnlimited(String used) => 'Đã dùng ${used}';
  @override
  String get theme => 'Giao diện';
  @override
  String get themeSystem => 'Theo hệ thống';
  @override
  String get themeLight => 'Sáng';
  @override
  String get themeDark => 'Tối';
  @override
  String get fetchingList => 'Đang tải danh sách cấu hình...';
  @override
  String testingServers(int n) => 'Đang kiểm tra ${n} máy chủ...';
  @override
  String foundActive(int n) => 'Đã tìm thấy ${n} máy chủ hoạt động...';
  @override
  String get testingSaved => 'Đang kiểm tra các máy chủ đã lưu...';
  @override
  String get allSourcesFailed =>
      'Không truy cập được nguồn nào. Hãy thêm liên kết đăng ký hoặc cấu hình thủ công.';
  @override
  String fetchFailed(Object e) => 'Không tải được danh sách: ${e}';
  @override
  String get noActiveServer => 'Không tìm thấy máy chủ hoạt động. Hãy thử lại.';
  @override
  String get adding => 'Đang thêm...';
  @override
  String get noValidConfig => 'Không tìm thấy cấu hình hợp lệ.';
  @override
  String importResult(int alive, int total) =>
      '${alive}/${total} cấu hình đang hoạt động.';
  @override
  String importFailed(Object e) => 'Không thêm được: ${e}';
  @override
  String subscriptionUpdated(int n) => 'Đã cập nhật đăng ký: ${n} cấu hình.';
  @override
  String get vpnPermissionDenied => 'Chưa được cấp quyền VPN.';
  @override
  String connectFailed(String reason) => 'Không kết nối được: ${reason}';
  @override
  String get nameSubscription => 'Đặt tên cho đăng ký này';
  @override
  String get showCollector => 'Máy chủ công cộng';
  @override
  String get showCollectorDesc =>
      'Hiển thị danh sách máy chủ công cộng miễn phí';
  @override
  String fieldLabel(String key) =>
      const {
        'name': 'Tên',
        'address': 'Địa chỉ',
        'port': 'Cổng',
        'uuid': 'ID người dùng (UUID)',
        'password': 'Mật khẩu',
        'security': 'Bảo mật',
        'type': 'Mạng',
        'net': 'Mạng',
        'tls': 'TLS',
        'sni': 'SNI',
        'host': 'Header Host',
        'path': 'Đường dẫn',
        'fp': 'Dấu vân tay',
        'alpn': 'ALPN',
        'flow': 'Flow',
        'pbk': 'Khóa công khai',
        'sid': 'Short ID',
        'spx': 'Đường dẫn Spider',
        'encryption': 'Mã hóa',
        'headerType': 'Loại header',
        'serviceName': 'Tên dịch vụ gRPC',
        'mode': 'Chế độ',
        'method': 'Thuật toán',
        'allowInsecure': 'Cho phép không an toàn',
        'insecure': 'Cho phép không an toàn',
        'aid': 'Alter ID',
        'scy': 'Thuật toán',
        'obfs': 'Làm rối',
        'obfs-password': 'Mật khẩu làm rối',
      }[key] ??
      key;
}
