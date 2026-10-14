; Inno Setup script for the Imagyn Windows installer.
;
; Built by scripts/package_windows.ps1, which defines Version, SourceDir,
; OutputDir, LicenseFile and IconFile on the iscc command line.
;
; The wizard is English only: Inno does not bundle a Simplified Chinese
; translation, and shipping a third-party .isl file is a separate decision.
;
; Requires Inno Setup 6.3 or newer, the first release that understands
; ArchitecturesAllowed=x64compatible; an older 6.x fails to parse that line.
; scripts/package_windows.ps1 checks the compiler version before running.

#define AppName "Imagyn"
#define AppPublisher "Dai2010"
#define AppUrl "https://github.com/Dai2010/imagyn"

[Setup]
AppId={{7C4A1F62-9D3E-4B18-8A57-2E6B0C9D41F3}
AppName={#AppName}
AppVersion={#Version}
AppVerName={#AppName} {#Version}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}
LicenseFile={#LicenseFile}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename=imagyn-{#Version}-windows-x64-setup
SetupIconFile={#IconFile}
UninstallDisplayIcon={app}\imagyn.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; Flutter ships no 32-bit Windows embedder, so x64 is the only architecture.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Let the user choose per-user or per-machine installation.
PrivilegesRequiredOverridesAllowed=dialog

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\imagyn.exe"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\imagyn.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\imagyn.exe"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
