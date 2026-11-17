; Builds kumo-windows-<arch>-setup.exe from the Windows release folder.
;   ISCC.exe /DAppVersion=1.0.0 /DArch=x64 installer\kumo.iss   (Arch: x64 or arm64)
;
; This file is saved as UTF-8 with a signature (BOM): the texts of the other languages are in it.
;
; The program updates itself through this installer: the update dialog runs it with /SILENT /UPDATE, which shows
; only the progress window and starts Kumo again when it is done. Run by hand over an installed Kumo it says it
; is an update, shows the version it replaces and asks before it goes back to an older one.
#ifndef Arch
  #define Arch "x64"
#endif
#if Arch == "arm64"
  #define InnoArch "arm64"
#else
  #define InnoArch "x64compatible"
#endif
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
; The number of the file properties has four plain numbers: 1.12.2-beta.15 is 1.12.2.0 (the text version has the rest).
#define DashAt Pos("-", AppVersion)
#if DashAt > 0
  #define BaseVersion Copy(AppVersion, 1, DashAt - 1)
#else
  #define BaseVersion AppVersion
#endif

[Setup]
AppId={{7D2C5E0A-4B1F-4C7A-9E3B-5A6F0D8C1B24}
AppName=Kumo
AppVersion={#AppVersion}
AppPublisher=Kumo
AppPublisherURL=https://github.com/AbolDev/kumo-client
AppSupportURL=https://github.com/AbolDev/kumo-client/issues
AppUpdatesURL=https://github.com/AbolDev/kumo-client/releases
VersionInfoVersion={#BaseVersion}.0
VersionInfoProductVersion={#BaseVersion}.0
VersionInfoProductTextVersion={#AppVersion}
VersionInfoCompany=Kumo
VersionInfoDescription=Kumo setup
VersionInfoProductName=Kumo
VersionInfoCopyright=GNU General Public License v3
DefaultDirName={autopf}\Kumo
DefaultGroupName=Kumo
DisableProgramGroupPage=yes
; An update goes to the folder Kumo is in, without asking for it again.
DisableDirPage=auto
; The language dialog is shown only to someone whose Windows language is not one of these; an update keeps the
; language of the first install.
ShowLanguageDialog=auto
PrivilegesRequired=admin
ArchitecturesAllowed={#InnoArch}
ArchitecturesInstallIn64BitMode={#InnoArch}
OutputDir=..\dist
OutputBaseFilename=kumo-windows-{#Arch}-setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\kumo.exe
LicenseFile=..\LICENSE
WizardImageFile=wizard.bmp
WizardSmallImageFile=wizard-small.bmp
; Two setups at the same time would fight over the same files.
SetupMutex=KumoSetupMutex
#ifdef Fast
Compression=lzma2/fast
#else
Compression=lzma2/max
#endif
SolidCompression=yes
WizardStyle=modern
; Kumo and its cores are closed before their files are replaced or removed (it is told to end its connection first,
; see PrepareToInstall below).
CloseApplications=force
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "persian"; MessagesFile: "languages\Farsi.isl"
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "chinesesimplified"; MessagesFile: "languages\ChineseSimplified.isl"
Name: "vietnamese"; MessagesFile: "languages\Vietnamese.isl"
Name: "arabic"; MessagesFile: "languages\Arabic.isl"

[CustomMessages]
english.DesktopIconTask=Create a desktop shortcut
english.LinkHandlerTask=Open vless://, vmess://, ss:// and other server links with Kumo (it asks before it adds anything)
english.StartKumo=Start Kumo
english.UpdateWelcomeTitle=Update Kumo
english.UpdateWelcomeText=Kumo %1 is installed. This updates it to %2.%n%nYour settings and servers are kept. If Kumo is running, its connection is ended and it is closed first; it starts again when the update is done.
english.SameVersionWelcomeText=Kumo %1 is already installed. This installs it again over the same version.%n%nYour settings and servers are kept.
english.UpdateReadyText=Kumo will be updated from %1 to %2.
english.RunningNote=Kumo is running: its connection will be ended and it will be closed before the update.
english.UpdateButton=&Update
english.DowngradeAsk=A newer version of Kumo (%1) is installed. Do you want to replace it with the older %2?
english.UninstallDataAsk=Also delete your Kumo settings, servers and saved data?%n%nChoose No to keep them for a later install.

persian.DesktopIconTask=ایجاد میان‌بر روی دسکتاپ
persian.LinkHandlerTask=باز کردن پیوندهای vless://، vmess://، ss:// و دیگر پیوندهای سرور با Kumo (پیش از افزودن هر چیزی می‌پرسد)
persian.StartKumo=اجرای Kumo
persian.UpdateWelcomeTitle=به‌روزرسانی Kumo
persian.UpdateWelcomeText=Kumo %1 نصب است. این کار آن را به %2 به‌روز می‌کند.%n%nتنظیمات و سرورهای شما حفظ می‌شود. اگر Kumo در حال اجراست، ابتدا اتصال آن قطع و بسته می‌شود و پس از پایان به‌روزرسانی دوباره اجرا می‌شود.
persian.SameVersionWelcomeText=Kumo %1 از قبل نصب است. این کار آن را دوباره روی همان نسخه نصب می‌کند.%n%nتنظیمات و سرورهای شما حفظ می‌شود.
persian.UpdateReadyText=Kumo از %1 به %2 به‌روز خواهد شد.
persian.RunningNote=Kumo در حال اجراست: پیش از به‌روزرسانی اتصال آن قطع و برنامه بسته می‌شود.
persian.UpdateButton=&به‌روزرسانی
persian.DowngradeAsk=نسخه جدیدتری از Kumo (%1) نصب است. می‌خواهید آن را با نسخه قدیمی‌تر %2 جایگزین کنید؟
persian.UninstallDataAsk=تنظیمات، سرورها و داده‌های ذخیره‌شده Kumo هم حذف شوند؟%n%nبرای نگه داشتن آن‌ها برای نصب بعدی «خیر» را بزنید.

russian.DesktopIconTask=Создать ярлык на рабочем столе
russian.LinkHandlerTask=Открывать ссылки vless://, vmess://, ss:// и другие ссылки серверов в Kumo (перед добавлением он спрашивает)
russian.StartKumo=Запустить Kumo
russian.UpdateWelcomeTitle=Обновление Kumo
russian.UpdateWelcomeText=Установлен Kumo %1. Он будет обновлён до %2.%n%nВаши настройки и серверы сохранятся. Если Kumo запущен, его соединение будет разорвано, а сам он закрыт; после обновления он запустится снова.
russian.SameVersionWelcomeText=Kumo %1 уже установлен. Он будет установлен заново поверх той же версии.%n%nВаши настройки и серверы сохранятся.
russian.UpdateReadyText=Kumo будет обновлён с %1 до %2.
russian.RunningNote=Kumo запущен: перед обновлением его соединение будет разорвано, а программа закрыта.
russian.UpdateButton=&Обновить
russian.DowngradeAsk=Установлена более новая версия Kumo (%1). Заменить её более старой версией %2?
russian.UninstallDataAsk=Удалить также настройки, серверы и сохранённые данные Kumo?%n%nВыберите «Нет», чтобы сохранить их для следующей установки.

chinesesimplified.DesktopIconTask=创建桌面快捷方式
chinesesimplified.LinkHandlerTask=用 Kumo 打开 vless://、vmess://、ss:// 等服务器链接（添加任何内容前都会询问）
chinesesimplified.StartKumo=启动 Kumo
chinesesimplified.UpdateWelcomeTitle=更新 Kumo
chinesesimplified.UpdateWelcomeText=已安装 Kumo %1。此操作会将其更新到 %2。%n%n您的设置和服务器会保留。如果 Kumo 正在运行，会先断开连接并关闭它，更新完成后重新启动。
chinesesimplified.SameVersionWelcomeText=已安装 Kumo %1。此操作会在相同版本上重新安装。%n%n您的设置和服务器会保留。
chinesesimplified.UpdateReadyText=Kumo 将从 %1 更新到 %2。
chinesesimplified.RunningNote=Kumo 正在运行：更新前会断开其连接并关闭它。
chinesesimplified.UpdateButton=更新(&U)
chinesesimplified.DowngradeAsk=已安装较新的 Kumo 版本 (%1)。要用较旧的 %2 替换它吗？
chinesesimplified.UninstallDataAsk=是否同时删除 Kumo 的设置、服务器和已保存的数据？%n%n选择“否”可保留它们以便以后安装。

vietnamese.DesktopIconTask=Tạo lối tắt trên màn hình nền
vietnamese.LinkHandlerTask=Mở các liên kết vless://, vmess://, ss:// và liên kết máy chủ khác bằng Kumo (Kumo luôn hỏi trước khi thêm)
vietnamese.StartKumo=Khởi động Kumo
vietnamese.UpdateWelcomeTitle=Cập nhật Kumo
vietnamese.UpdateWelcomeText=Kumo %1 đã được cài đặt. Thao tác này sẽ cập nhật lên %2.%n%nCài đặt và máy chủ của bạn được giữ nguyên. Nếu Kumo đang chạy, kết nối của nó sẽ bị ngắt và nó sẽ được đóng trước; Kumo khởi động lại khi cập nhật xong.
vietnamese.SameVersionWelcomeText=Kumo %1 đã được cài đặt. Thao tác này cài lại đè lên cùng phiên bản.%n%nCài đặt và máy chủ của bạn được giữ nguyên.
vietnamese.UpdateReadyText=Kumo sẽ được cập nhật từ %1 lên %2.
vietnamese.RunningNote=Kumo đang chạy: kết nối của nó sẽ bị ngắt và Kumo sẽ được đóng trước khi cập nhật.
vietnamese.UpdateButton=&Cập nhật
vietnamese.DowngradeAsk=Đã cài phiên bản Kumo mới hơn (%1). Bạn có muốn thay bằng phiên bản cũ hơn %2 không?
vietnamese.UninstallDataAsk=Xóa luôn cài đặt, máy chủ và dữ liệu đã lưu của Kumo?%n%nChọn Không để giữ lại cho lần cài sau.

arabic.DesktopIconTask=إنشاء اختصار على سطح المكتب
arabic.LinkHandlerTask=فتح روابط vless:// وvmess:// وss:// وغيرها من روابط الخوادم باستخدام Kumo (يسأل قبل إضافة أي شيء)
arabic.StartKumo=تشغيل Kumo
arabic.UpdateWelcomeTitle=تحديث Kumo
arabic.UpdateWelcomeText=الإصدار %1 من Kumo مثبّت. سيتم تحديثه إلى %2.%n%nستبقى إعداداتك وخوادمك. إذا كان Kumo يعمل فسيتم إنهاء اتصاله وإغلاقه أولاً، ثم يبدأ من جديد بعد انتهاء التحديث.
arabic.SameVersionWelcomeText=Kumo %1 مثبّت بالفعل. سيُثبَّت مرة أخرى فوق الإصدار نفسه.%n%nستبقى إعداداتك وخوادمك.
arabic.UpdateReadyText=سيتم تحديث Kumo من %1 إلى %2.
arabic.RunningNote=Kumo يعمل: سيتم إنهاء اتصاله وإغلاقه قبل التحديث.
arabic.UpdateButton=&تحديث
arabic.DowngradeAsk=يوجد إصدار أحدث من Kumo (%1) مثبّت. هل تريد استبداله بالإصدار الأقدم %2؟
arabic.UninstallDataAsk=هل تريد أيضاً حذف إعدادات Kumo وخوادمه وبياناته المحفوظة؟%n%nاختر «لا» للاحتفاظ بها لتثبيت لاحق.

[Tasks]
Name: "desktopicon"; Description: "{cm:DesktopIconTask}"
Name: "linkhandler"; Description: "{cm:LinkHandlerTask}"

[Files]
Source: "..\build\windows\{#Arch}\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[InstallDelete]
; The files of the screens and pictures of an older version that this one no longer has would stay otherwise.
Type: filesandordirs; Name: "{app}\data\flutter_assets"

[Icons]
; The icon file, not kumo.exe: Windows keeps showing the icon it cached for the exe before an
; update, on the taskbar too. Kumo points these at the icon picked in its Settings when it starts.
Name: "{group}\Kumo"; Filename: "{app}\kumo.exe"; IconFilename: "{app}\data\flutter_assets\assets\app_icons\teal_night.ico"
Name: "{autodesktop}\Kumo"; Filename: "{app}\kumo.exe"; IconFilename: "{app}\data\flutter_assets\assets\app_icons\teal_night.ico"; Tasks: desktopicon

[Registry]
; Links of servers and subscriptions (vless://, vmess://, ...) open with Kumo. The program is started with the
; link on its command line; a copy that already runs gets it. Kumo asks before it adds anything.
Root: HKA; Subkey: "Software\Classes\vless"; ValueType: string; ValueName: ""; ValueData: "URL:Kumo link"; Flags: uninsdeletekey; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\vless"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\vless\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\kumo.exe"" ""%1"""; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\vmess"; ValueType: string; ValueName: ""; ValueData: "URL:Kumo link"; Flags: uninsdeletekey; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\vmess"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\vmess\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\kumo.exe"" ""%1"""; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\trojan"; ValueType: string; ValueName: ""; ValueData: "URL:Kumo link"; Flags: uninsdeletekey; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\trojan"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\trojan\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\kumo.exe"" ""%1"""; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\ss"; ValueType: string; ValueName: ""; ValueData: "URL:Kumo link"; Flags: uninsdeletekey; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\ss"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\ss\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\kumo.exe"" ""%1"""; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\hysteria"; ValueType: string; ValueName: ""; ValueData: "URL:Kumo link"; Flags: uninsdeletekey; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\hysteria"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\hysteria\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\kumo.exe"" ""%1"""; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\hysteria2"; ValueType: string; ValueName: ""; ValueData: "URL:Kumo link"; Flags: uninsdeletekey; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\hysteria2"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\hysteria2\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\kumo.exe"" ""%1"""; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\hy2"; ValueType: string; ValueName: ""; ValueData: "URL:Kumo link"; Flags: uninsdeletekey; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\hy2"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\hy2\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\kumo.exe"" ""%1"""; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\tuic"; ValueType: string; ValueName: ""; ValueData: "URL:Kumo link"; Flags: uninsdeletekey; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\tuic"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\tuic\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\kumo.exe"" ""%1"""; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\anytls"; ValueType: string; ValueName: ""; ValueData: "URL:Kumo link"; Flags: uninsdeletekey; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\anytls"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\anytls\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\kumo.exe"" ""%1"""; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\wireguard"; ValueType: string; ValueName: ""; ValueData: "URL:Kumo link"; Flags: uninsdeletekey; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\wireguard"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\wireguard\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\kumo.exe"" ""%1"""; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\clash"; ValueType: string; ValueName: ""; ValueData: "URL:Kumo link"; Flags: uninsdeletekey; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\clash"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\clash\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\kumo.exe"" ""%1"""; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\sing-box"; ValueType: string; ValueName: ""; ValueData: "URL:Kumo link"; Flags: uninsdeletekey; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\sing-box"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\sing-box\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\kumo.exe"" ""%1"""; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\hiddify"; ValueType: string; ValueName: ""; ValueData: "URL:Kumo link"; Flags: uninsdeletekey; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\hiddify"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""; Tasks: linkhandler
Root: HKA; Subkey: "Software\Classes\hiddify\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\kumo.exe"" ""%1"""; Tasks: linkhandler

[Run]
Filename: "{app}\kumo.exe"; Description: "{cm:StartKumo}"; Flags: nowait postinstall skipifsilent shellexec
; The update made by the program itself (/UPDATE) shows no last page: Kumo is started again here.
Filename: "{app}\kumo.exe"; Flags: nowait shellexec; Check: UpdateInBackground

[UninstallRun]
; Stops the VPN processes and removes the start-with-Windows task, if there is one.
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM kumo.exe /IM kumo-core.exe /IM kumo-xray.exe /IM kumo-awg.exe /IM openvpn.exe"; Flags: runhidden; RunOnceId: "StopKumo"
Filename: "{sys}\schtasks.exe"; Parameters: "/Delete /TN KumoAutoStart /F"; Flags: runhidden; RunOnceId: "RemoveKumoTask"
; The network adapter OpenVPN servers use (made by Kumo the first time one is connected).
Filename: "{app}\openvpn\tapctl.exe"; Parameters: "delete KumoOpenVPN"; Flags: runhidden; RunOnceId: "RemoveKumoAdapter"; Check: AdapterToolExists

[Code]
const
  // The key Inno Setup writes for this app (its AppId): it holds the version that is installed.
  UninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{7D2C5E0A-4B1F-4C7A-9E3B-5A6F0D8C1B24}_is1';
  // The name the running Kumo holds (one copy per user, see lib/core/single_instance.dart).
  RunningMutex = 'KumoVpnClient';

var
  OldVersion: String;
  Updating: Boolean;
  UninstallWasRunning: Boolean;

function InstalledVersion: String;
begin
  Result := '';
  if not RegQueryStringValue(HKLM, UninstallKey, 'DisplayVersion', Result) then
    if not RegQueryStringValue(HKCU, UninstallKey, 'DisplayVersion', Result) then
      Result := '';
end;

{ Reads "1.12.2" or "1.12.2-beta.15" as four numbers: major, minor, patch, beta (a release that is not a beta is
  after all its betas). }
procedure ParseVersion(V: String; var Parts: array of Integer);
var
  I, At: Integer;
  Beta: String;
begin
  for I := 0 to 2 do
    Parts[I] := 0;
  Parts[3] := 999999;
  At := Pos('-', V);
  if At > 0 then
  begin
    Beta := Copy(V, At + 1, Length(V));
    V := Copy(V, 1, At - 1);
    Parts[3] := 0;
    I := Pos('.', Beta);
    if I > 0 then
      Parts[3] := StrToIntDef(Copy(Beta, I + 1, Length(Beta)), 0);
  end;
  for I := 0 to 2 do
  begin
    At := Pos('.', V);
    if At = 0 then
      At := Length(V) + 1;
    Parts[I] := StrToIntDef(Copy(V, 1, At - 1), 0);
    Delete(V, 1, At);
  end;
end;

{ -1 when A is older than B, 0 when they are the same, 1 when A is newer. }
function CompareVersions(A, B: String): Integer;
var
  PA, PB: array of Integer;
  I: Integer;
begin
  SetArrayLength(PA, 4);
  SetArrayLength(PB, 4);
  ParseVersion(A, PA);
  ParseVersion(B, PB);
  Result := 0;
  for I := 0 to 3 do
  begin
    if PA[I] < PB[I] then
    begin
      Result := -1;
      Exit;
    end;
    if PA[I] > PB[I] then
    begin
      Result := 1;
      Exit;
    end;
  end;
end;

function HasParam(Name: String): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
    if CompareText(ParamStr(I), '/' + Name) = 0 then
    begin
      Result := True;
      Exit;
    end;
end;

{ True for the update the program makes by itself (/SILENT /UPDATE): Kumo is started again at the end. }
function UpdateInBackground: Boolean;
begin
  Result := Updating and HasParam('UPDATE');
end;

function AdapterToolExists: Boolean;
begin
  Result := FileExists(ExpandConstant('{app}\openvpn\tapctl.exe'));
end;

{ Tells a running Kumo to end its connection (it puts the system proxy back as it does for any disconnect) and
  gives it a moment. What is still running afterwards is closed by the setup. }
procedure AskKumoToDisconnect(Dir: String);
var
  Code: Integer;
begin
  if FileExists(Dir + '\kumo.exe') then
    Exec(Dir + '\kumo.exe', '--disconnect', Dir, SW_HIDE, ewNoWait, Code);
  Sleep(3000);
end;

function InitializeSetup: Boolean;
begin
  Result := True;
  OldVersion := InstalledVersion;
  Updating := OldVersion <> '';
end;

procedure InitializeWizard;
begin
  if not Updating then
    Exit;
  WizardForm.WelcomeLabel1.Caption := ExpandConstant('{cm:UpdateWelcomeTitle}');
  if CompareVersions(OldVersion, '{#AppVersion}') = 0 then
    WizardForm.WelcomeLabel2.Caption := ExpandConstant('{cm:SameVersionWelcomeText,' + OldVersion + '}')
  else
    WizardForm.WelcomeLabel2.Caption := ExpandConstant('{cm:UpdateWelcomeText,' + OldVersion + ',{#AppVersion}}');
end;

{ An update has no license page (it was accepted) and no page of tasks (what was chosen is kept). }
function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := Updating and ((PageID = wpLicense) or (PageID = wpSelectTasks));
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if Updating and (CurPageID = wpWelcome) and (CompareVersions(OldVersion, '{#AppVersion}') > 0) then
    Result := MsgBox(ExpandConstant('{cm:DowngradeAsk,' + OldVersion + ',{#AppVersion}}'),
      mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if Updating and (CurPageID = wpReady) then
    WizardForm.NextButton.Caption := ExpandConstant('{cm:UpdateButton}');
end;

function JoinBlocks(A, B, NewLine: String): String;
begin
  if A = '' then
    Result := B
  else if B = '' then
    Result := A
  else
    Result := A + NewLine + NewLine + B;
end;

function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo, MemoComponentsInfo,
  MemoGroupInfo, MemoTasksInfo: String): String;
begin
  if Updating then
  begin
    Result := ExpandConstant('{cm:UpdateReadyText,' + OldVersion + ',{#AppVersion}}');
    if CheckForMutexes(RunningMutex) then
      Result := JoinBlocks(Result, ExpandConstant('{cm:RunningNote}'), NewLine);
    Result := JoinBlocks(Result, MemoDirInfo, NewLine);
  end
  else
    Result := JoinBlocks(MemoDirInfo, MemoTasksInfo, NewLine);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if CheckForMutexes(RunningMutex) then
    AskKumoToDisconnect(ExpandConstant('{app}'));
end;

function InitializeUninstall: Boolean;
begin
  Result := True;
  UninstallWasRunning := CheckForMutexes(RunningMutex);
  if UninstallWasRunning then
    AskKumoToDisconnect(ExpandConstant('{app}'));
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Dir: String;
begin
  if CurUninstallStep <> usPostUninstall then
    Exit;
  { The settings, servers and subscriptions are the user's: they are deleted only when the user says so. }
  Dir := ExpandConstant('{userappdata}\Kumo');
  if DirExists(Dir) and (not UninstallSilent) then
    if MsgBox(ExpandConstant('{cm:UninstallDataAsk}') + #13#10#13#10 + Dir, mbConfirmation,
      MB_YESNO or MB_DEFBUTTON2) = IDYES then
      DelTree(Dir, True, True, True);
end;
