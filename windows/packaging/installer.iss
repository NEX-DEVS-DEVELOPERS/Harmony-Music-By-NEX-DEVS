; Inno Setup script used by CI (.github/workflows/release.yml).
; Build:  iscc /DMyAppVersion=1.12.3 windows\packaging\installer.iss
; Output: dist\HarmonyMusic-Setup-<version>.exe
#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif

[Setup]
; Same AppId + folder as the original Harmony Music installer, so installing this
; UPGRADES an existing install in place (your library in %APPDATA% is kept).
AppId=B9F6E402-0CAE-4045-BDE6-14BD6C39C4EA
AppVersion={#MyAppVersion}
AppName=Harmony Music
AppPublisher=NEX-DEVS
AppPublisherURL=https://github.com/NEX-DEVS-DEVELOPERS/Harmony-Music-By-NEX-DEVS
AppSupportURL=https://github.com/NEX-DEVS-DEVELOPERS/Harmony-Music-By-NEX-DEVS/issues
DefaultDirName={autopf}\harmonymusic
DisableProgramGroupPage=yes
SourceDir=..\..
OutputDir=dist
OutputBaseFilename=HarmonyMusic-Setup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
SetupIconFile=windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\harmonymusic.exe
WizardStyle=modern
PrivilegesRequired=lowest
LicenseFile=LICENSE
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=force
RestartApplications=no
UsePreviousAppDir=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Harmony Music"; Filename: "{app}\harmonymusic.exe"
Name: "{autodesktop}\Harmony Music"; Filename: "{app}\harmonymusic.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\harmonymusic.exe"; Description: "{cm:LaunchProgram,Harmony Music}"; Flags: nowait postinstall skipifsilent
