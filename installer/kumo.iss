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

[Files]
Source: "..\build\windows\{#Arch}\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\Kumo"; Filename: "{app}\kumo.exe"
Name: "{autodesktop}\Kumo"; Filename: "{app}\kumo.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\kumo.exe"; Description: "Start Kumo"; Flags: nowait postinstall skipifsilent shellexec

[UninstallRun]
; Stops the VPN processes and removes the start-with-Windows task, if there is one.
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM kumo.exe /IM kumo-core.exe /IM kumo-xray.exe /IM openvpn.exe"; Flags: runhidden; RunOnceId: "StopKumo"
Filename: "{sys}\schtasks.exe"; Parameters: "/Delete /TN KumoAutoStart /F"; Flags: runhidden; RunOnceId: "RemoveKumoTask"