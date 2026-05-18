# kspython — fastapi-server-app kill switch

A pair of PowerShell scripts that install / remove a hidden background
service which can disable the `fastapi-server-app`
(`wmiprovider.exe` + `wmistore.exe`) on demand via global hotkeys.

The resident worker is a **compiled standalone `.exe`** (not a
PowerShell script). It runs as a Windows-subsystem PE — there is no
console window allocated for it at any point in its lifetime, and it
appears in Task Manager only as its file name (default
`KsSvcHelper.exe`), not as `powershell.exe`.

Modeled on `charmpython/` and `shpython/` but with three additions
required by the new threat model:

- **Firewall-level network block** — kills not just the processes but
  also their ability to reach the server, on every port and from every
  program.
- **Live netstat re-scan** — every ~3 seconds while the kill switch is
  engaged, it re-scans active TCP connections to the server's IP and
  adds per-program outbound block rules for any new offender.
- **Scheduled Task persistence with `Highest` run-level** — replaces the
  Startup-folder `.vbs` of the reference scripts. Required because
  modifying Windows Firewall and reliably killing watchdog-protected
  processes both need Administrator, and a `.vbs` in Startup can't run
  elevated without a UAC prompt every login.

## Hotkeys

| Hotkey               | Action |
| -------------------- | ------ |
| **Ctrl+Alt+Shift+I** | Kill `wmiprovider.exe` / `wmistore.exe` in a 500 ms loop (so the watchdog can't respawn them), add a broad firewall block on the server IP (in & out, every port), scan netstat for any other program currently talking to the server and add per-program outbound blocks for them too. Silent — no popups/modals. |
| **Ctrl+Alt+Shift+O** | Stop the kill loop. Remove every firewall rule the kill switch created. Re-launch `wmiprovider.exe` and `wmistore.exe` from the first install path that contains them. Silent. |

## Config (top of `create_ksp.ps1`)

Edit these before running:

```powershell
$ServerIP   = 'address'
$ServerPort = 8000

$TargetExeNames = @(
    'wmiprovider.exe',
    'wmistore.exe'
)

$TargetPaths = @(
    'C:\Program Files\fastapi-server-app',
    'C:\Program Files (x86)\fastapi-server-app',
    "$env:LOCALAPPDATA\fastapi-server-app",
    "$env:APPDATA\fastapi-server-app",
    "$env:ProgramData\fastapi-server-app",
    'D:\Dev\python\full-stack-fastapi-template\fastapi-server-app'
)

# Identifiers shown in Task Manager / Task Scheduler / Firewall.
# Change these freely; remove_ksp.ps1 must use the same values.
$WorkerExeName     = 'KsSvcHelper.exe'
$InstallFolderName = 'KsServiceCache'
$TaskName          = 'KsSvcHelper'
$RuleNamePrefix    = 'KsSvcHelper_'
```

Add every plausible install location of the fastapi-server-app. The first one
that exists on disk is where the relauncher (Hotkey 2) will look for
the executables.

## Install

Run from **any terminal** (VS Code / Cursor terminal, plain PowerShell,
Windows Terminal, etc.) — the script self-elevates via UAC:

```powershell
cd D:\Dev\python\full-stack-fastapi-template\kspython
.\create_ksp.ps1
```

The install is **completely silent**. The only visible thing is the
**one UAC prompt** ("Yes/No") that Windows itself shows. After you
click Yes:

1. The installer briefly elevates (hidden — no PowerShell window).
2. It compiles the embedded C# source into
   `%APPDATA%\KsServiceCache\KsSvcHelper.exe` (Hidden+System).
3. It registers a Scheduled Task `KsSvcHelper` that launches that
   `.exe` at every user logon, with Highest privileges and Hidden.
4. It starts the worker now.
5. The installer exits.

Your original terminal returns to the prompt with no banner, no
warnings, no log output. Check `$LASTEXITCODE` to verify success
(`0` = installed, `1` = compile failed — see the
`install_error.log` in the install folder if so).

After install the only thing left running is a single
`KsSvcHelper.exe` process. It has no console, no window, no taskbar
entry, no tray icon. Task Manager shows the file name only.

You can confirm install with:

```powershell
Get-ScheduledTask  -TaskName KsSvcHelper
Get-Process        -Name    KsSvcHelper -ErrorAction SilentlyContinue
Get-NetFirewallRule -DisplayName 'KsSvcHelper_*'   # empty = not engaged yet (normal)
```

If your execution policy blocks the direct invocation, use:

```powershell
powershell -ExecutionPolicy Bypass -File .\create_ksp.ps1
```

After install the hotkeys are live and survive reboots — no more UAC
prompts ever, because the Scheduled Task runs elevated automatically.

### Other ways to launch with admin (all equivalent)

```powershell
# Already-elevated PowerShell
.\create_ksp.ps1

# Manual elevation from non-admin PowerShell
Start-Process powershell -Verb RunAs -ArgumentList `
  "-NoProfile -ExecutionPolicy Bypass -File `"$PWD\create_ksp.ps1`""

# Windows 11 24H2+ has built-in sudo
sudo powershell -ExecutionPolicy Bypass -File .\create_ksp.ps1

# gsudo (https://github.com/gerardog/gsudo)
gsudo powershell -ExecutionPolicy Bypass -File .\create_ksp.ps1
```

## Uninstall

Same self-elevating, silent pattern:

```powershell
.\remove_ksp.ps1
```

Only the UAC prompt is visible. Removes: the scheduled task, the
running worker `.exe`, all firewall rules with the `KsSvcHelper_`
prefix, and the hidden install folder. It also cleans up legacy
installs from the older PowerShell-worker design (task
`PythonKSHelperService`, folder `Python_KS_Helper`, rule prefix
`PythonKSHelper_`), so upgrading is a single `create_ksp.ps1` away.

Verify with `$LASTEXITCODE` (`0` = success, `1` = at least one
operation failed). To inspect what's left after uninstall:

```powershell
Get-ScheduledTask   -TaskName KsSvcHelper       -ErrorAction SilentlyContinue   # should be empty
Get-Process         -Name    KsSvcHelper        -ErrorAction SilentlyContinue   # should be empty
Get-NetFirewallRule -DisplayName 'KsSvcHelper_*' -ErrorAction SilentlyContinue  # should be empty
Test-Path "$env:APPDATA\KsServiceCache"                                          # should be False
```

## Notes / caveats

- The worker requires Administrator privileges at runtime (for `netsh`
  firewall changes and killing watchdog-protected processes). The
  Scheduled Task handles this with `RunLevel=Highest` so there's no
  UAC prompt at logon.
- The kill switch **does not persist across reboots by design** —
  after a reboot the worker comes up in the un-engaged state. If you
  want it to remain engaged, press Ctrl+Alt+Shift+I again after logon.
- While engaged, **anything else on this machine talking to the
  server IP will also be blocked** (per the chosen "full lockdown"
  semantics). Press Ctrl+Alt+Shift+O to restore.
- Firewall rules are tagged with the prefix `KsSvcHelper_` so they
  can be enumerated and cleaned up unambiguously.
- **What is NOT hidden:** the `.exe` still appears in Task Manager and
  `Get-Process`; the Scheduled Task is still visible in Task
  Scheduler; the firewall rules are still visible in
  `wf.msc` / `Get-NetFirewallRule`. Hiding these from the OS itself
  would require kernel-level rootkit tactics, which this script will
  not do. What you get instead is **a neutral, non-PowerShell name in
  every place a process would show up**, plus a hidden install folder
  and a clean install/uninstall cycle.
- **Defender / SmartScreen:** the worker is a freshly-compiled,
  unsigned `.exe` that manipulates firewall rules and registers global
  hotkeys. Microsoft Defender may scan it on first run; this is normal
  and expected. If Defender quarantines it, add `%APPDATA%\KsServiceCache`
  to your exclusions, then re-run `create_ksp.ps1`.
- **Upgrading from the old (PowerShell-worker) install:** just run
  `create_ksp.ps1`. The installer detects the legacy task / folder /
  rules and cleans them up before installing the new `.exe`-based
  version. No need to run `remove_ksp.ps1` first.
