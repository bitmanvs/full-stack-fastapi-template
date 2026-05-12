# =====================================================================
#  create_ksp.ps1
#  Installer for the WMI / monitor-app kill-switch service.
#
#  Run from ANY terminal -- the script auto-elevates via a hidden VBS
#  shim, does its install work in the background, and exits. Nothing
#  PowerShell-shaped remains in Task Manager after this script finishes.
#  The resident worker is a compiled .exe (see WORKER below).
#
#      .\create_ksp.ps1
#      powershell -ExecutionPolicy Bypass -File .\create_ksp.ps1
#
#  After install:
#      Ctrl+Alt+Shift+I  -> kill monitor-app + block all paths to server
#      Ctrl+Alt+Shift+O  -> unblock + restart monitor-app
#
#  WORKER
#  ------
#  The installer compiles the embedded C# into a standalone .exe
#  (default name WmiSvcHelper.exe). That .exe is:
#    * a Windows-subsystem PE -- NO console window at any point
#    * launched at every user logon by a Scheduled Task running with
#      Highest privileges (admin token, no UAC prompt at login)
#    * shown in Task Manager only as its file name (not as
#      "powershell.exe")
#
#  Honest limits: the .exe still appears in Task Manager / Get-Process,
#  and the Scheduled Task is still visible in Task Scheduler. Hiding
#  these from the OS itself would require rootkit-level tactics and is
#  out of scope.
# =====================================================================

# Reserved for the self-elevate handshake (do not pass this manually).
param([switch]$FromSelfElevate)


# =====================================================================
#  CONFIG  -- edit these if needed
# =====================================================================

$ServerIP   = '192.168.10.168'
$ServerPort = 8000

# Process EXE base names to kill (case-insensitive). Killed by name AND
# by path so renamed copies inside the target folders are still caught.
$TargetExeNames = @(
    'wmiprovider.exe',
    'wmistore.exe'
)

# Folders that contain the monitor-app installation. Add every plausible
# location -- the first existing one is also used to RELAUNCH the app
# when Hotkey2 fires.
$TargetPaths = @(
    'C:\Program Files\monitor-app-v0.1',
    'C:\Program Files (x86)\monitor-app-v0.1',
    "$env:LOCALAPPDATA\monitor-app-v0.1",
    "$env:APPDATA\monitor-app-v0.1",
    "$env:ProgramData\monitor-app-v0.1",
    'D:\Dev\python\full-stack-fastapi-template\monitor-app-v0.1'
)

# Identifiers that show up in Task Manager / Task Scheduler / Firewall.
# Change these freely; remove_ksp.ps1 must use the same values.
$WorkerExeName     = 'WmiSvcHelper.exe'
$InstallFolderName = 'WmiServiceCache'
$TaskName          = 'WmiSvcHelper'
$RuleNamePrefix    = 'WmiSvcHelper_'

# Legacy identifiers from earlier installer versions. We clean these up
# automatically during a fresh install so upgrades don't leave orphans.
$LegacyInstallNames   = @('Python_KS_Helper')
$LegacyTaskNames      = @('PythonKSHelperService')
$LegacyRulePrefixes   = @('PythonKSHelper_')
$LegacyScriptFileName = 'pythonkshelper_service.ps1'


# =====================================================================
#  ADMIN CHECK -- auto-elevate via UAC if we're not already admin
# =====================================================================

$currentPrincipal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    # Silently relaunch elevated via a tiny VBS shim.
    #
    # Why VBS instead of `Start-Process -Verb RunAs -WindowStyle Hidden`:
    # Start-Process's WindowStyle is not reliably honored when combined
    # with -Verb RunAs (the elevated console flashes/stays visible). VBS
    # uses Shell.Application.ShellExecute whose 5th parameter (vShow=0)
    # reliably hides the new process. Standard idiom for truly hidden
    # UAC elevation on Windows.
    $thisScript = $MyInvocation.MyCommand.Path
    if (-not $thisScript) { $thisScript = $PSCommandPath }

    # Build the args for the elevated powershell.exe. VBS string literals
    # use "" to escape a quote, so every " in our args must be doubled.
    # We build the VBS content with string concatenation -- NOT with
    # `$(...)` interpolation -- because PowerShell's interpolation parser
    # post-processes doubled quotes inside `$()` and collapses them back
    # to single quotes (silent bug). Concatenation preserves them.
    $psArgsForElev   = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$thisScript"" -FromSelfElevate"
    $psArgsForVbs    = $psArgsForElev.Replace('"', '""')
    $q               = [char]34   # literal "

    $vbsContent =
        "Set objShell = CreateObject(" + $q + "Shell.Application" + $q + ")`r`n" +
        "objShell.ShellExecute " + $q + "powershell.exe" + $q + ", " +
        $q + $psArgsForVbs + $q + ", " +
        $q + $q + ", " +
        $q + "runas" + $q + ", 0`r`n"

    $tmpVbs = Join-Path $env:TEMP ("ksp_elev_" + [guid]::NewGuid().Guid + ".vbs")
    try {
        $vbsContent | Set-Content -Path $tmpVbs -Encoding Unicode -Force -ErrorAction Stop
        Start-Process -FilePath 'wscript.exe' -ArgumentList "`"$tmpVbs`"" -WindowStyle Hidden -Wait -ErrorAction Stop
    } catch {
        # silent by design
    } finally {
        Start-Sleep -Milliseconds 200
        Remove-Item $tmpVbs -Force -ErrorAction SilentlyContinue
    }
    exit 0
}


# =====================================================================
#  WORKER -- full C# source for the compiled .exe
#
#  This is a SELF-CONTAINED program with a Main() method. The placeholders
#  __SERVER_IP__, __SERVER_PORT__, __RULE_PREFIX__, __TARGET_EXES__,
#  __TARGET_PATHS__ are substituted with the config values above before
#  compilation. We compile with Add-Type -OutputType WindowsApplication
#  so the PE subsystem is GUI (no console allocated, ever).
# =====================================================================

$csSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;

[assembly: AssemblyTitle("WMI Service Helper")]
[assembly: AssemblyDescription("WMI service helper background task.")]
[assembly: AssemblyProduct("WMI Service Helper")]

public class WmiSvcCore {
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h,int id,uint m,uint k);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h,int id);
    [DllImport("user32.dll")] static extern IntPtr CreateWindowEx(uint a,string b,string c,uint d,int e,int f,int g,int h,IntPtr i,IntPtr j,IntPtr k,IntPtr l);
    [DllImport("user32.dll")] static extern int GetMessage(out MSG m,IntPtr h,uint a,uint b);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG m);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref MSG m);
    [DllImport("user32.dll")] static extern IntPtr DefWindowProc(IntPtr h,uint m,IntPtr w,IntPtr l);
    [DllImport("user32.dll")] static extern ushort RegisterClass(ref WNDCLASS c);
    [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string n);

    [StructLayout(LayoutKind.Sequential)] public struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int x; public int y; }
    [StructLayout(LayoutKind.Sequential)] public struct WNDCLASS { public uint style; public WndProcDelegate lpfnWndProc; public int cbClsExtra; public int cbWndExtra; public IntPtr hInstance; public IntPtr hIcon; public IntPtr hCursor; public IntPtr hbrBackground; public string lpszMenuName; public string lpszClassName; }
    public delegate IntPtr WndProcDelegate(IntPtr h, uint m, IntPtr w, IntPtr l);

    // -----------------------------------------------------------------
    // Configuration -- injected by create_ksp.ps1 before compilation
    // -----------------------------------------------------------------
    static string _serverIp   = "__SERVER_IP__";
    static int    _serverPort = __SERVER_PORT__;
    static string _rulePrefix = "__RULE_PREFIX__";
    static string[] _targetExeNames = new string[] {
__TARGET_EXES__
    };
    static string[] _targetPaths = new string[] {
__TARGET_PATHS__
    };

    // -----------------------------------------------------------------
    // Runtime state
    // -----------------------------------------------------------------
    static volatile bool _killActive = false;
    static Thread _killThread;
    static readonly object _sync = new object();
    static readonly HashSet<string> _blockedExePaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    static readonly List<string> _createdRuleNames = new List<string>();
    static WndProcDelegate _wndProcDelegate;

    // Hotkeys: MOD_ALT|MOD_CONTROL|MOD_SHIFT = 0x7
    const int  KILL_ID    = 1;
    const int  RESTORE_ID = 2;
    const uint MOD_CAS    = 0x0007;
    const uint VK_I       = 0x49;
    const uint VK_O       = 0x4F;
    const uint WM_HOTKEY  = 0x0312;

    // =================================================================
    // ENTRY POINT -- Main() because we compile as WindowsApplication
    // =================================================================
    [STAThread]
    public static void Main() {
        _wndProcDelegate = new WndProcDelegate(WndProc);
        WNDCLASS wc = new WNDCLASS();
        wc.lpfnWndProc = _wndProcDelegate;
        wc.hInstance = GetModuleHandle(null);
        wc.lpszClassName = "WmiSvcCoreMsgWindow";
        RegisterClass(ref wc);

        IntPtr hwnd = CreateWindowEx(0,"WmiSvcCoreMsgWindow","",0,0,0,0,0,IntPtr.Zero,IntPtr.Zero,wc.hInstance,IntPtr.Zero);
        RegisterHotKey(hwnd, KILL_ID,    MOD_CAS, VK_I);
        RegisterHotKey(hwnd, RESTORE_ID, MOD_CAS, VK_O);

        MSG msg;
        while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0) {
            TranslateMessage(ref msg);
            DispatchMessage(ref msg);
        }
    }

    static IntPtr WndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam) {
        if (msg == WM_HOTKEY) {
            int id = wParam.ToInt32();
            if      (id == KILL_ID)    EngageKillSwitch();
            else if (id == RESTORE_ID) DisengageKillSwitch();
        }
        return DefWindowProc(hwnd, msg, wParam, lParam);
    }

    // =================================================================
    // KILL SWITCH -- engage
    // =================================================================
    static void EngageKillSwitch() {
        lock (_sync) {
            if (_killActive) return;
            _killActive = true;
        }

        ApplyServerIpBlock();
        ScanAndBlockActiveConnections();
        KillTargetsOnce();

        _killThread = new Thread(delegate() {
            int rescanCounter = 0;
            while (_killActive) {
                KillTargetsOnce();
                rescanCounter++;
                // Every ~3s, re-scan netstat in case a new process tries
                // to talk to the server through a different port.
                if (rescanCounter >= 6) {
                    rescanCounter = 0;
                    try { ScanAndBlockActiveConnections(); } catch {}
                }
                Thread.Sleep(500);
            }
        });
        _killThread.IsBackground = true;
        _killThread.Start();
    }

    // =================================================================
    // KILL SWITCH -- disengage
    // =================================================================
    static void DisengageKillSwitch() {
        lock (_sync) {
            if (!_killActive) return;
            _killActive = false;
        }

        if (_killThread != null && _killThread.IsAlive) {
            _killThread.Join(1500);
        }

        RemoveAllFirewallRules();
        _blockedExePaths.Clear();
        _createdRuleNames.Clear();

        Thread.Sleep(500);
        LaunchTargets();
    }

    // =================================================================
    // PROCESS KILL
    // =================================================================
    static bool MatchesTargetByName(string processName) {
        if (string.IsNullOrEmpty(processName)) return false;
        foreach (string exe in _targetExeNames) {
            string baseName = Path.GetFileNameWithoutExtension(exe);
            if (processName.Equals(baseName, StringComparison.OrdinalIgnoreCase)) return true;
        }
        return false;
    }

    static bool MatchesTargetByPath(string fullPath) {
        if (string.IsNullOrEmpty(fullPath)) return false;
        foreach (string tp in _targetPaths) {
            if (fullPath.StartsWith(tp, StringComparison.OrdinalIgnoreCase)) return true;
        }
        return false;
    }

    static void KillTargetsOnce() {
        foreach (Process p in Process.GetProcesses()) {
            try {
                bool match = MatchesTargetByName(p.ProcessName);
                if (!match) {
                    try {
                        string path = p.MainModule.FileName;
                        if (MatchesTargetByPath(path)) match = true;
                    } catch {}
                }
                if (match) {
                    try { p.Kill(); } catch {}
                    try { p.WaitForExit(100); } catch {}
                }
            } catch {}
        }
    }

    // =================================================================
    // RELAUNCH (Hotkey2)
    // =================================================================
    static void LaunchTargets() {
        foreach (string tp in _targetPaths) {
            if (!Directory.Exists(tp)) continue;
            foreach (string exe in _targetExeNames) {
                string fullPath = Path.Combine(tp, exe);
                if (File.Exists(fullPath)) {
                    try {
                        ProcessStartInfo psi = new ProcessStartInfo();
                        psi.FileName = fullPath;
                        psi.WorkingDirectory = tp;
                        psi.UseShellExecute = true;
                        psi.WindowStyle = ProcessWindowStyle.Hidden;
                        Process.Start(psi);
                    } catch {}
                }
            }
            return; // launched from first folder that contains them
        }
    }

    // =================================================================
    // NETSH WRAPPER (silent)
    // =================================================================
    static int RunNetsh(string args) {
        try {
            ProcessStartInfo psi = new ProcessStartInfo("netsh.exe", args);
            psi.UseShellExecute        = false;
            psi.CreateNoWindow         = true;
            psi.WindowStyle            = ProcessWindowStyle.Hidden;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError  = true;
            Process p = Process.Start(psi);
            p.WaitForExit(5000);
            return p.ExitCode;
        } catch { return -1; }
    }

    // =================================================================
    // FIREWALL RULES -- broad block on the server IP (every port/program)
    // Plus an extra port-specific rule for belt-and-suspenders coverage.
    // =================================================================
    static void ApplyServerIpBlock() {
        string ruleOut     = _rulePrefix + "IP_OUT_" + _serverIp;
        string ruleIn      = _rulePrefix + "IP_IN_"  + _serverIp;
        string rulePortOut = _rulePrefix + "PORT_OUT_" + _serverIp + "_" + _serverPort;

        RunNetsh(string.Format("advfirewall firewall delete rule name=\"{0}\"", ruleOut));
        RunNetsh(string.Format("advfirewall firewall delete rule name=\"{0}\"", ruleIn));
        RunNetsh(string.Format("advfirewall firewall delete rule name=\"{0}\"", rulePortOut));

        if (RunNetsh(string.Format(
            "advfirewall firewall add rule name=\"{0}\" dir=out action=block remoteip={1} profile=any enable=yes",
            ruleOut, _serverIp)) == 0) _createdRuleNames.Add(ruleOut);
        if (RunNetsh(string.Format(
            "advfirewall firewall add rule name=\"{0}\" dir=in  action=block remoteip={1} profile=any enable=yes",
            ruleIn, _serverIp)) == 0) _createdRuleNames.Add(ruleIn);
        if (RunNetsh(string.Format(
            "advfirewall firewall add rule name=\"{0}\" dir=out action=block protocol=TCP remoteip={1} remoteport={2} profile=any enable=yes",
            rulePortOut, _serverIp, _serverPort)) == 0) _createdRuleNames.Add(rulePortOut);
    }

    // =================================================================
    // FIREWALL RULES -- per-program blocks for anything currently
    // talking to the server (catches alternate exfil ports/programs)
    // =================================================================
    static void ScanAndBlockActiveConnections() {
        ProcessStartInfo psi = new ProcessStartInfo("netstat.exe", "-ano -p tcp");
        psi.UseShellExecute        = false;
        psi.CreateNoWindow         = true;
        psi.WindowStyle            = ProcessWindowStyle.Hidden;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError  = true;
        string output;
        try {
            Process p = Process.Start(psi);
            output = p.StandardOutput.ReadToEnd();
            p.WaitForExit(5000);
        } catch { return; }

        HashSet<int> pidsTalkingToServer = new HashSet<int>();
        string needle = _serverIp + ":";

        foreach (string lineRaw in output.Split('\n')) {
            string line = lineRaw.Trim();
            if (line.Length == 0) continue;
            if (line.IndexOf(needle) < 0) continue;

            // typical row:
            //   TCP    192.168.x.x:54321   192.168.10.168:8000   ESTABLISHED   1234
            string[] cols = System.Text.RegularExpressions.Regex.Split(line, "\\s+");
            if (cols.Length < 5) continue;
            int pid;
            if (!int.TryParse(cols[cols.Length - 1], out pid)) continue;
            if (pid <= 4) continue; // skip System / Idle
            pidsTalkingToServer.Add(pid);
        }

        foreach (int pid in pidsTalkingToServer) {
            string exePath = null;
            try {
                Process proc = Process.GetProcessById(pid);
                exePath = proc.MainModule.FileName;
            } catch {}
            if (string.IsNullOrEmpty(exePath)) continue;
            if (_blockedExePaths.Contains(exePath)) continue;

            string ruleName = _rulePrefix + "PROG_OUT_" + Path.GetFileName(exePath) + "_" + Math.Abs(exePath.GetHashCode());
            RunNetsh(string.Format(
                "advfirewall firewall delete rule name=\"{0}\"", ruleName));
            int code = RunNetsh(string.Format(
                "advfirewall firewall add rule name=\"{0}\" dir=out action=block program=\"{1}\" profile=any enable=yes",
                ruleName, exePath));
            if (code == 0) {
                _blockedExePaths.Add(exePath);
                _createdRuleNames.Add(ruleName);
            }
        }
    }

    // =================================================================
    // FIREWALL RULES -- delete every rule created by us
    //
    // Two-pass approach so it works on ANY Windows locale:
    //   1. Delete every rule whose exact name we recorded this session
    //      (handles 99% of normal cases, fast, no parsing).
    //   2. Sweep with PowerShell's Get-NetFirewallRule (output is
    //      locale-independent) to catch any leftover rules from a
    //      previous crashed session.
    // =================================================================
    static void RemoveAllFirewallRules() {
        foreach (string ruleName in new List<string>(_createdRuleNames)) {
            RunNetsh(string.Format(
                "advfirewall firewall delete rule name=\"{0}\"", ruleName));
        }
        _createdRuleNames.Clear();
        _blockedExePaths.Clear();

        // Locale-independent sweep for any leftovers.
        try {
            string psCmd = string.Format(
                "Get-NetFirewallRule -DisplayName '{0}*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue",
                _rulePrefix);
            ProcessStartInfo pps = new ProcessStartInfo("powershell.exe",
                "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command \"" + psCmd + "\"");
            pps.UseShellExecute        = false;
            pps.CreateNoWindow         = true;
            pps.WindowStyle            = ProcessWindowStyle.Hidden;
            pps.RedirectStandardOutput = true;
            pps.RedirectStandardError  = true;
            Process p = Process.Start(pps);
            p.WaitForExit(15000);
        } catch {}
    }
}
'@


# =====================================================================
#  INJECT CONFIG VALUES INTO THE C# SOURCE
# =====================================================================

$exesCsharp  = ($TargetExeNames | ForEach-Object { '        @"' + $_ + '"' }) -join ",`r`n"
$pathsCsharp = ($TargetPaths    | ForEach-Object { '        @"' + $_ + '"' }) -join ",`r`n"

$csSource = $csSource.Replace('__SERVER_IP__',    $ServerIP)
$csSource = $csSource.Replace('__SERVER_PORT__',  [string]$ServerPort)
$csSource = $csSource.Replace('__RULE_PREFIX__',  $RuleNamePrefix)
$csSource = $csSource.Replace('__TARGET_EXES__',  $exesCsharp)
$csSource = $csSource.Replace('__TARGET_PATHS__', $pathsCsharp)


# =====================================================================
#  CLEAN UP STALE STATE FROM A PREVIOUS INSTALL (current + legacy)
#  We do this BEFORE writing the new worker, because Windows allows only
#  one registration per global hotkey per session.
# =====================================================================

# 1) Stop + unregister scheduled tasks (current + legacy)
$allTaskNames = @($TaskName) + $LegacyTaskNames
foreach ($tn in $allTaskNames) {
    try {
        if (Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask       -TaskName $tn -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
        }
    } catch {}
}

# 2) Kill any running worker process (current exe + legacy patterns)
$workerBaseName = [System.IO.Path]::GetFileNameWithoutExtension($WorkerExeName)
Get-Process -Name $workerBaseName -ErrorAction SilentlyContinue | ForEach-Object {
    try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch {}
}

# Legacy worker ran inside powershell.exe; identify by command line.
Get-Process powershell -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)" -ErrorAction SilentlyContinue).CommandLine
        if (-not $cmdLine) { return }
        $isLegacy = $false
        foreach ($n in $LegacyInstallNames)    { if ($cmdLine -like "*$n*") { $isLegacy = $true; break } }
        if (-not $isLegacy -and $cmdLine -like "*$LegacyScriptFileName*") { $isLegacy = $true }
        if (-not $isLegacy -and $cmdLine -like "*PythonKSHelper*")        { $isLegacy = $true }
        if ($isLegacy) {
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

# 3) Remove firewall rules (current + legacy prefixes)
$allRulePrefixes = @($RuleNamePrefix) + $LegacyRulePrefixes
foreach ($rp in $allRulePrefixes) {
    try {
        Get-NetFirewallRule -DisplayName "$rp*" -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue
    } catch {}
}

# 4) Remove legacy install folders (current folder gets rewritten below)
foreach ($legacyName in $LegacyInstallNames) {
    $legacyPath = Join-Path $env:APPDATA $legacyName
    if (Test-Path $legacyPath) {
        try { Remove-Item $legacyPath -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }
}


# =====================================================================
#  CREATE INSTALL FOLDER + COMPILE THE WORKER EXE
# =====================================================================

$installPath = Join-Path $env:APPDATA $InstallFolderName
$exePath     = Join-Path $installPath $WorkerExeName

if (Test-Path $installPath) {
    try { Remove-Item $installPath -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}
New-Item -ItemType Directory -Path $installPath -Force | Out-Null

# Compile the C# source into a standalone Windows-subsystem .exe.
#
# -OutputType WindowsApplication => /target:winexe under the hood.
# This sets the PE Subsystem field to IMAGE_SUBSYSTEM_WINDOWS_GUI, which
# means the OS does NOT allocate a console for this process AT ANY POINT.
# That's stronger than runtime console-hiding (ShowWindow(0)): there is
# literally no console to hide -- no flicker, no flash, ever.
try {
    Add-Type -TypeDefinition $csSource `
             -OutputAssembly $exePath `
             -OutputType WindowsApplication `
             -ErrorAction Stop
} catch {
    # Compile failed -- write a quiet diagnostic file so the user can
    # find out why (if they care) without us showing an alert.
    try {
        $logPath = Join-Path $installPath 'install_error.log'
        $_.Exception.ToString() | Set-Content -Path $logPath -Encoding UTF8 -Force
    } catch {}
    exit 1
}

# Hide the install folder + exe (Hidden + System => super-hidden:
# doesn't show in Explorer even with "Show hidden files" enabled,
# unless "Hide protected operating system files" is also disabled).
try {
    (Get-Item $installPath -Force).Attributes = 'Hidden,System,Directory'
} catch {}
try {
    (Get-Item $exePath -Force).Attributes = 'Hidden,System,ReadOnly,Archive'
} catch {}


# =====================================================================
#  PERSISTENCE -- Scheduled Task at logon, elevated, hidden
#  Launches the .exe DIRECTLY -- no powershell.exe wrapper.
# =====================================================================

$action    = New-ScheduledTaskAction    -Execute $exePath -WorkingDirectory $installPath
$trigger   = New-ScheduledTaskTrigger   -AtLogOn -User $env:USERNAME
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -Hidden `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask `
    -TaskName    $TaskName `
    -Action      $action `
    -Trigger     $trigger `
    -Principal   $principal `
    -Settings    $settings `
    -Description 'WMI service helper background task.' `
    -Force | Out-Null


# =====================================================================
#  START NOW (don't wait for next logon)
# =====================================================================

try {
    Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
} catch {
    # Fallback: launch the .exe directly, still as the elevated user.
    Start-Process -FilePath $exePath -WindowStyle Hidden -ErrorAction SilentlyContinue
}

exit 0
