; JawnOS - Inno Setup 6 script (phase-2 wrapper; NOT TESTED).
;
; This is a skeleton for a single Setup.exe around the portable bundle that
; build-portable.ps1 produces. The supported path today is Install.bat in the
; bundle; this file exists so the phase-2 wrapper has one place to grow.
;
; Build the payload first, then compile this script:
;   powershell -File installer\windows\build-portable.ps1 -RuntimeDir <strawberry>
;   set JAWNOS_VERSION=0.1.2679
;   iscc installer\windows\jawnos.iss
;
; [Run] passes the autostart task choice to install.ps1: a selected task omits
; -NoAutostart, an unselected one adds it. The installer asks for admin because
; the firewall rule is machine-wide.
;
; Caveat for phase 2: uninstall.ps1 removes {app} itself and Inno also removes
; it. That is acceptable in this skeleton, but verify the two do not race
; before this file is presented as tested.

#ifndef AppVersion
  #define AppVersion GetEnv("JAWNOS_VERSION")
#endif
#if AppVersion == ""
  #define AppVersion "0.0.0-dev"
#endif

#ifndef PayloadDir
  #define PayloadDir "..\..\dist"
#endif

[Setup]
AppId={{7E7D6F2A-3F2B-4C2D-9A55-6A3B1C0D9E11}
AppName=JawnOS
AppVersion={#AppVersion}
AppPublisher=JawnOS
DefaultDirName={autopf}\JawnOS
DefaultGroupName=JawnOS
DisableProgramGroupPage=yes
OutputDir={#PayloadDir}
OutputBaseFilename=JawnOS-{#AppVersion}-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
PrivilegesRequired=admin
UninstallDisplayIcon={app}\runtime\perl\bin\perl.exe

[Tasks]
Name: "autostart"; Description: "Start JawnOS with Windows"; GroupDescription: "Startup:"
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional icons:"; Flags: unchecked

[Files]
Source: "{#PayloadDir}\JawnOS-{#AppVersion}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\JawnOS"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\launch.vbs"""; WorkingDir: "{app}"
Name: "{autodesktop}\JawnOS"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\launch.vbs"""; WorkingDir: "{app}"; Tasks: desktopicon
Name: "{userstartup}\JawnOS"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\launch.vbs"""; WorkingDir: "{app}"; Tasks: autostart

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\install.ps1"" -InstallDir ""{app}"" -NoLaunch"; Flags: waituntilterminated; Check: WizardIsTaskSelected('autostart')
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\install.ps1"" -InstallDir ""{app}"" -NoLaunch -NoAutostart"; Flags: waituntilterminated; Check: not WizardIsTaskSelected('autostart')
Filename: "{sys}\wscript.exe"; Parameters: """{app}\launch.vbs"""; Description: "Launch JawnOS"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\uninstall.ps1"" -InstallDir ""{app}"""; Flags: waituntilterminated runhidden
