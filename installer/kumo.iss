; Builds kumo-windows-<arch>-setup.exe from the Windows release folder.
;   ISCC.exe /DAppVersion=1.0.0 /DArch=x64 installer\kumo.iss   (Arch: x64 or arm64)
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

[Setup]
AppId={{7D2C5E0A-4B1F-4C7A-9E3B-5A6F0D8C1B24}
AppName=Kumo
AppVersion={#AppVersion}
AppPublisher=Kumo
DefaultDirName={autopf}\Kumo
DefaultGroupName=Kumo
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed={#InnoArch}
ArchitecturesInstallIn64BitMode={#InnoArch}
OutputDir=..\dist
OutputBaseFilename=kumo-windows-{#Arch}-setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\kumo.exe
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; Kumo and its cores are closed before their files are replaced or removed.
CloseApplications=force
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"
Name: "linkhandler"; Description: "Open vless://, vmess://, ss:// and other server links with Kumo (it asks before it adds anything)"

[Files]
Source: "..\build\windows\{#Arch}\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

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
Filename: "{app}\kumo.exe"; Description: "Start Kumo"; Flags: nowait postinstall skipifsilent shellexec

[UninstallRun]
; Stops the VPN processes and removes the start-with-Windows task, if there is one.
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM kumo.exe /IM kumo-core.exe /IM kumo-xray.exe /IM openvpn.exe"; Flags: runhidden; RunOnceId: "StopKumo"
Filename: "{sys}\schtasks.exe"; Parameters: "/Delete /TN KumoAutoStart /F"; Flags: runhidden; RunOnceId: "RemoveKumoTask"