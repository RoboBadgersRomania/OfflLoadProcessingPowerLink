; Computing Power Network - Windows installer (Inno Setup 6). Build: installer\build-installer.bat
;
; Installs the whole kit + the dashboard app, adds Start-menu shortcuts and an entry in
; Settings > Apps (with uninstaller). After copying files it runs the full setup (both roles:
; WSL 2, Ubuntu, ROS 2, Docker, Tailscale, agent...). When Windows needs a restart, setup asks,
; restarts and continues by itself after login. Which role is ACTIVE (NodeUser / Both /
; ProcessingNode) is chosen later in the app: My PC tab.
;
; Install folder's drive = where Ubuntu, WSL swap and Tailscale go (keep C: free by picking D:).

#define AppName "Computing Power Network"
#define AppVersion "1.1.1"
#define Publisher "RoboBadgers Romania"
#define Repo "https://github.com/RoboBadgersRomania/PowerCluster"

[Setup]
AppId={{7C3E5B2A-4F1D-4C8E-9B6A-2D5F0E1C9A77}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#Publisher}
AppPublisherURL={#Repo}
AppSupportURL={#Repo}/issues
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19045
OutputDir=..\dist
OutputBaseFilename=ComputingPowerNetwork-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\ComputingPowerNetwork.exe
CloseApplications=yes

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "runsetup"; Description: "Set up this PC now (WSL 2, Ubuntu, ROS 2, Docker, Tailscale - 30-60 min, may ask to restart)"; GroupDescription: "Setup:"
Name: "desktopicon"; Description: "Desktop shortcut for the dashboard"; GroupDescription: "Shortcuts:"

[Files]
; the kit (scripts, docker, extension, skill, listener...)
Source: "..\*"; DestDir: "{app}"; Excludes: ".git\*,installer\*,dist\*,dashboard\build\*,dashboard\dist\*,*.spec,__pycache__\*,ws\build\*,ws\install\*,ws\log\*,ws\.jobs\*"; Flags: recursesubdirs createallsubdirs ignoreversion
; the compiled dashboard (dashboard\build.bat makes it; the installer build runs that first)
Source: "..\dashboard\dist\ComputingPowerNetwork.exe"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\ComputingPowerNetwork.exe"; WorkingDir: "{app}"
Name: "{group}\Set up / repair this PC"; Filename: "{app}\SETUP-everything.cmd"; WorkingDir: "{app}"
Name: "{group}\Readme"; Filename: "{#Repo}#readme"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\ComputingPowerNetwork.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\setup.ps1"" -Role both"; \
  StatusMsg: "Setting up this PC (a console window shows the progress)..."; Flags: waituntilterminated; Tasks: runsetup
Filename: "{app}\ComputingPowerNetwork.exe"; Description: "Open {#AppName}"; Flags: nowait postinstall skipifsilent skipifdoesntexist

[UninstallRun]
; Undo both roles (each step asks; deleting Ubuntu / WSL itself is optional and defaults to "keep")
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\uninstall.ps1"" -Role offload"; Flags: waituntilterminated; RunOnceId: "UninstallOffload"
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\uninstall.ps1"" -Role me"; Flags: waituntilterminated; RunOnceId: "UninstallMe"

[UninstallDelete]
Type: filesandordirs; Name: "{app}\dashboard\__pycache__"
