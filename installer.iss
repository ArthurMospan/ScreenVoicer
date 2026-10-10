; Inno Setup script for ScreenVoicer.
; Build the exe first:  dotnet publish -c Release -o ./publish
; CI (.github/workflows/release.yml) passes the version from the git tag: iscc /DMyAppVersion=1.2.3 installer.iss
#define MyAppName "ScreenVoicer"
#ifndef MyAppVersion
  #define MyAppVersion "1.10.0"
#endif
#define MyAppPublisher "ScreenVoicer"
#define MyAppExeName "ScreenVoicer.exe"

[Setup]
AppId={{D37E5F92-4BA1-4C38-9B9B-89E6AA451290}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL=https://sv.mospan.com.ua/
AppSupportURL=https://github.com/ArthurMospan/ScreenVoicer
AppUpdatesURL=https://github.com/ArthurMospan/ScreenVoicer/releases
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=.\installer_output
; A fixed name, so .../releases/latest/download/ScreenVoicer-Setup.exe always points at the newest installer.
OutputBaseFilename=ScreenVoicer-Setup
SetupIconFile=Resources\AppIcon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
; Ask to close a running copy (current and pre-1.3 versions) before installing/uninstalling.
AppMutex=Local\ScreenVoicer.SingleInstance,Global\ScreenVoicer_Unique_App_Mutex_2026
CloseApplications=yes

[Languages]
Name: "ukrainian"; MessagesFile: "compiler:Languages\Ukrainian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
ukrainian.StartupTask=Запускати ScreenVoicer разом з Windows
ukrainian.StartupGroup=Автозапуск:
english.StartupTask=Run ScreenVoicer automatically on Windows startup
english.StartupGroup=Startup:

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "startupicon"; Description: "{cm:StartupTask}"; GroupDescription: "{cm:StartupGroup}"

[Files]
; Single self-contained exe (the PDB is embedded).
Source: ".\publish\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Registry]
; Same value the app's own "Run with Windows" toggle uses, so the tray checkbox shows the real state.
; --autostart keeps the app quietly in the tray at login (no gallery window).
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "{#MyAppName}"; \
    ValueData: """{app}\{#MyAppExeName}"" --autostart"; Flags: uninsdeletevalue; Tasks: startupicon

[InstallDelete]
; v1.0 used a Startup-folder shortcut in addition to the Run key, which started two instances at login.
Type: files; Name: "{userstartup}\{#MyAppName}.lnk"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
; Silent run = the app updating itself: start it again (quietly in the tray) when done.
Filename: "{app}\{#MyAppExeName}"; Parameters: "--autostart"; Flags: nowait; Check: WizardSilent
