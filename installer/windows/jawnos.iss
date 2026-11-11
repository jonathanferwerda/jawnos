; JawnOS - Inno Setup 6 script.
;
; One per-user Setup.exe around the portable bundle that build-portable.ps1
; produces. Inno owns the files, the shortcuts and the uninstall; install.ps1
; only seeds the config/database and starts the house; firewall.ps1 owns the
; single firewall rule and elevates itself only when the person asks for LAN
; access.
;
; Build the payload first, then compile:
;   powershell -File installer\windows\build-portable.ps1 -RuntimeDir <strawberry>
;   set JAWNOS_VERSION=0.1.2707
;   iscc installer\windows\jawnos.iss
;
; The install is per user under %LOCALAPPDATA%\JawnOS, so the app can write its
; config, database and log without administrator rights. The firewall rule is
; the only machine-wide step, and it is the only reason Setup ever raises a
; UAC prompt.
;
; A fresh install seeds an empty config and database. An upgrade stops the
; running house in PrepareToInstall first (Inno cannot replace a locked
; perl.exe) and otherwise keeps the existing config and database.

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
DefaultDirName={localappdata}\JawnOS
DefaultGroupName=JawnOS
DisableProgramGroupPage=yes
OutputDir={#PayloadDir}
OutputBaseFilename=JawnOS-{#AppVersion}-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64
PrivilegesRequired=lowest
; PrepareToInstall stops the house itself. Restart Manager cannot close a
; console perl.exe reliably, so it must not try.
CloseApplications=no
RestartApplications=no
UninstallDisplayIcon={app}\runtime\perl\bin\perl.exe

[Tasks]
Name: "lanaccess"; Description: "Allow other devices on this network to reach JawnOS (needs administrator)"; GroupDescription: "Network:"; Flags: checkedonce
Name: "autostart"; Description: "Start JawnOS with Windows"; GroupDescription: "Startup:"
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional icons:"; Flags: unchecked

[Files]
Source: "{#PayloadDir}\JawnOS-{#AppVersion}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\JawnOS"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\launch.vbs"""; WorkingDir: "{app}"
Name: "{autodesktop}\JawnOS"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\launch.vbs"""; WorkingDir: "{app}"; Tasks: desktopicon
Name: "{userstartup}\JawnOS"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\launch.vbs"""; WorkingDir: "{app}"; Tasks: autostart

[Run]
; The interactive entry launches the house, waits for the port and opens the
; manager; it also shows the unlock code. A silent install must not open a
; browser or wait for the server, so it gets its own entry.
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\install.ps1"" -InstallDir ""{app}"" -SkipShortcuts -SkipFirewall"; StatusMsg: "Starting JawnOS (the first run can take a minute) ..."; Flags: waituntilterminated; Check: not WizardSilent
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\install.ps1"" -InstallDir ""{app}"" -SkipShortcuts -SkipFirewall -NoLaunch -NoBrowser -Quiet"; Flags: waituntilterminated runhidden; Check: WizardSilent
; install.ps1 skipped the rule because a per-user install has no admin.
; firewall.ps1 re-runs itself through UAC; declining leaves the house working
; locally and can be retried later from an elevated prompt.
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\firewall.ps1"" -InstallDir ""{app}"" -Elevate"; StatusMsg: "Allowing JawnOS through the private firewall ..."; Flags: waituntilterminated runhidden; Check: WizardIsTaskSelected('lanaccess')

[UninstallRun]
; RunOnceId keeps each step from repeating on a resumed uninstall. Inno removes
; the files and shortcuts; these entries only stop the house and drop the rule.
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\uninstall.ps1"" -InstallDir ""{app}"" -KeepFolder -SkipShortcuts -SkipFirewall"; Flags: waituntilterminated runhidden; RunOnceId: "StopJawnOS"
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\firewall.ps1"" -InstallDir ""{app}"" -Remove -Elevate"; Flags: waituntilterminated runhidden; RunOnceId: "RemoveJawnOSFirewall"

[Code]
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Script: String;
  ResultCode: Integer;
begin
  Result := '';
  Script := ExpandConstant('{app}\uninstall.ps1');
  if FileExists(Script) then
    Exec('powershell.exe',
      '-NoProfile -ExecutionPolicy Bypass -File "' + Script + '" -InstallDir "' +
      ExpandConstant('{app}') + '" -KeepFolder -SkipShortcuts -SkipFirewall',
      '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;
