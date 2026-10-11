; Inno Setup script for ScreenVoicer (needs Inno Setup 6.7+ for the dark wizard; release.yml installs it).
; Build the exe first:  dotnet publish -c Release -o ./publish
; CI (.github/workflows/release.yml) passes the version from the git tag: iscc /DMyAppVersion=1.2.3 installer.iss
;
; Three screens and one click: «Вітаємо» → [Встановити] → «Готово» (with «Запустити ScreenVoicer» ticked).
; No folder, shortcut or task questions: it installs per user, starts with Windows like the Mac app does (the
; tray menu turns that off), and an update keeps whatever the user chose there.
; The artwork comes from installer/art.html (see installer/README.md).
#define MyAppName "ScreenVoicer"
#ifndef MyAppVersion
  #define MyAppVersion "1.12.0"
#endif
#define MyAppPublisher "ScreenVoicer"
#define MyAppExeName "ScreenVoicer.exe"
#define MyAppId "D37E5F92-4BA1-4C38-9B9B-89E6AA451290"

[Setup]
AppId={{{#MyAppId}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL=https://sv.mospan.com.ua/
AppSupportURL=https://sv.mospan.com.ua/
AppUpdatesURL=https://sv.mospan.com.ua/
VersionInfoVersion={#MyAppVersion}
VersionInfoDescription={#MyAppName} — знімок екрана з коментарем голосом
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableWelcomePage=no
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
ShowLanguageDialog=no
OutputDir=.\installer_output
; A fixed name, so .../releases/latest/download/ScreenVoicer-Setup.exe always points at the newest installer.
OutputBaseFilename=ScreenVoicer-Setup
SetupIconFile=Resources\AppIcon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}
Compression=lzma2
SolidCompression=yes
; The brand look: the dark wizard in the app's colours (#0F0F13 glass background, orange logo).
WizardStyle=modern dark includetitlebar hidebevels
WizardBackColor=#0F0F13
WizardImageFile=installer\wizard-100.png,installer\wizard-150.png,installer\wizard-200.png,installer\wizard-250.png
WizardImageBackColor=#0F0F13
WizardSmallImageFile=installer\small-100.png,installer\small-150.png,installer\small-200.png,installer\small-250.png
WizardSmallImageBackColor=#0F0F13
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
; Ask to close a running copy (current and pre-1.3 versions) before installing/uninstalling.
AppMutex=Local\ScreenVoicer.SingleInstance,Global\ScreenVoicer_Unique_App_Mutex_2026
CloseApplications=yes

[Languages]
Name: "ukrainian"; MessagesFile: "compiler:Languages\Ukrainian.isl"

[Messages]
SetupWindowTitle=Встановлення %1
WelcomeLabel1=ScreenVoicer
WelcomeLabel2=Знімок екрана з коментарем голосом за 10 секунд.%n%nНатисніть «Встановити», це займе кілька секунд. ScreenVoicer чекатиме в треї й запускатиметься разом з Windows (вимкнути можна в його меню).
WizardInstalling=Встановлюю ScreenVoicer
InstallingLabel=Ще кілька секунд…
FinishedHeadingLabel=Готово
FinishedLabelNoIcons=ScreenVoicer встановлено.%n%nЩоб зробити знімок, натисніть Alt+Shift+S або клацніть іконку в треї.
FinishedLabel=ScreenVoicer встановлено.%n%nЩоб зробити знімок, натисніть Alt+Shift+S або клацніть іконку в треї.
ClickNext=
ClickFinish=
ButtonFinish=&Готово

[Files]
; Single self-contained exe (the PDB is embedded).
Source: ".\publish\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"

[Registry]
; Same value the app's own «Запуск з Windows» toggle uses, so the tray checkbox shows the real state.
; --autostart keeps the app quietly in the tray at login (no gallery window). Written on the first install only:
; an update must not turn autostart back on after the user switched it off.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "{#MyAppName}"; \
    ValueData: """{app}\{#MyAppExeName}"" --autostart"; Flags: uninsdeletevalue; Check: IsFreshInstall

[InstallDelete]
; v1.0 used a Startup-folder shortcut in addition to the Run key, which started two instances at login.
Type: files; Name: "{userstartup}\{#MyAppName}.lnk"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Запустити ScreenVoicer"; Flags: nowait postinstall skipifsilent
; Silent run = the app updating itself: start it again (quietly in the tray) when done.
Filename: "{app}\{#MyAppExeName}"; Parameters: "--autostart"; Flags: nowait; Check: WizardSilent

[Code]
const
  UninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{{#MyAppId}}_is1';

var
  FreshInstall: Boolean;

function InitializeSetup: Boolean;
begin
  // decided before anything is written: the uninstall key appears during this very install
  FreshInstall := not RegKeyExists(HKCU, UninstallKey) and not RegKeyExists(HKLM, UninstallKey);
  Result := True;
end;

function IsFreshInstall: Boolean;
begin
  Result := FreshInstall;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  // the welcome screen is the only question: its button installs straight away
  if CurPageID = wpWelcome then
    WizardForm.NextButton.Caption := SetupMessage(msgButtonInstall);
  // no file paths flickering by: the status line and the bar are enough
  if CurPageID = wpInstalling then
    WizardForm.FilenameLabel.Visible := False;
end;
