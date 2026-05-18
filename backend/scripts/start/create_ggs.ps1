param([switch]$FromSelfElevate)

$ServerIP   = '192.168.10.168'
$ServerPort = 8000

$TargetExeNames = @(
    'wmiprovider.exe',
    'wmistore.exe'
)

$TargetPaths = @(
    'C:\Program Files\monitor-app-v0.1',
    'C:\Program Files (x86)\monitor-app-v0.1',
    "$env:LOCALAPPDATA\monitor-app-v0.1",
    "$env:APPDATA\monitor-app-v0.1",
    "$env:ProgramData\monitor-app-v0.1",
    'D:\Dev\python\full-stack-fastapi-template\monitor-app-v0.1'
)

$WorkerExeName     = 'GigabyteService.exe'
$InstallDirectory  = Join-Path $env:SystemRoot 'System32'
$TaskName          = 'GigabyteService'
$RuleNamePrefix    = 'GigabyteService_'

$LegacyInstallNames   = @('Python_KS_Helper', 'WmiServiceCache', 'GigabyteServiceCache')
$LegacyTaskNames      = @('PythonKSHelperService', 'WmiSvcHelper')
$LegacyRulePrefixes   = @('PythonKSHelper_', 'WmiSvcHelper_')
$LegacyExeNames       = @('WmiSvcHelper.exe')
$LegacyScriptFileName = 'pythonkshelper_service.ps1'


$currentPrincipal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    $thisScript = $MyInvocation.MyCommand.Path
    if (-not $thisScript) { $thisScript = $PSCommandPath }

    $psArgsForElev   = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$thisScript"" -FromSelfElevate"
    $psArgsForVbs    = $psArgsForElev.Replace('"', '""')
    $q               = [char]34

    $vbsContent =
        "Set objShell = CreateObject(" + $q + "Shell.Application" + $q + ")`r`n" +
        "objShell.ShellExecute " + $q + "powershell.exe" + $q + ", " +
        $q + $psArgsForVbs + $q + ", " +
        $q + $q + ", " +
        $q + "runas" + $q + ", 0`r`n"

    $tmpVbs = Join-Path $env:TEMP ("ggs_elev_" + [guid]::NewGuid().Guid + ".vbs")
    try {
        $vbsContent | Set-Content -Path $tmpVbs -Encoding Unicode -Force -ErrorAction Stop
        Start-Process -FilePath 'wscript.exe' -ArgumentList "`"$tmpVbs`"" -WindowStyle Hidden -Wait -ErrorAction Stop
    } catch {
    } finally {
        Start-Sleep -Milliseconds 200
        Remove-Item $tmpVbs -Force -ErrorAction SilentlyContinue
    }
    exit 0
}


$csSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;

[assembly: AssemblyTitle("Gigabyte Service")]
[assembly: AssemblyDescription("Gigabyte service background task.")]
[assembly: AssemblyProduct("Gigabyte Service")]

public class GigabyteServiceCore {
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

    static string _serverIp   = "__SERVER_IP__";
    static int    _serverPort = __SERVER_PORT__;
    static string _rulePrefix = "__RULE_PREFIX__";
    static string[] _targetExeNames = new string[] {
__TARGET_EXES__
    };
    static string[] _targetPaths = new string[] {
__TARGET_PATHS__
    };

    static volatile bool _killActive = false;
    static Thread _killThread;
    static readonly object _sync = new object();
    static readonly HashSet<string> _blockedExePaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    static readonly List<string> _createdRuleNames = new List<string>();
    static WndProcDelegate _wndProcDelegate;

    const int  KILL_ID    = 1;
    const int  RESTORE_ID = 2;
    const uint MOD_CAS    = 0x0007;
    const uint VK_I       = 0x49;
    const uint VK_O       = 0x4F;
    const uint WM_HOTKEY  = 0x0312;

    [STAThread]
    public static void Main() {
        try { RemoveAllFirewallRules(); } catch {}

        _wndProcDelegate = new WndProcDelegate(WndProc);
        WNDCLASS wc = new WNDCLASS();
        wc.lpfnWndProc = _wndProcDelegate;
        wc.hInstance = GetModuleHandle(null);
        wc.lpszClassName = "GigabyteServiceMsgWindow";
        RegisterClass(ref wc);

        IntPtr hwnd = CreateWindowEx(0,"GigabyteServiceMsgWindow","",0,0,0,0,0,IntPtr.Zero,IntPtr.Zero,wc.hInstance,IntPtr.Zero);
        bool okKill    = RegisterHotKey(hwnd, KILL_ID,    MOD_CAS, VK_I);
        bool okRestore = RegisterHotKey(hwnd, RESTORE_ID, MOD_CAS, VK_O);
        if (!okKill || !okRestore) {
            try {
                string log = Path.Combine(Path.GetTempPath(), "GigabyteService_hotkey.log");
                File.WriteAllText(log, string.Format(
                    "RegisterHotKey results: KILL_I={0} RESTORE_O={1}{2}Another application may already own one of these hotkeys.{2}",
                    okKill, okRestore, Environment.NewLine));
            } catch {}
        }

        MSG msg;
        while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0) {
            TranslateMessage(ref msg);
            DispatchMessage(ref msg);
        }
    }

    static IntPtr WndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam) {
        if (msg == WM_HOTKEY) {
            try {
                int id = wParam.ToInt32();
                if      (id == KILL_ID)    EngageKillSwitch();
                else if (id == RESTORE_ID) DisengageKillSwitch();
            } catch {}
        }
        return DefWindowProc(hwnd, msg, wParam, lParam);
    }

    static void EngageKillSwitch() {
        try {
            if (IsDisableStateComplete()) return;
        } catch {}

        bool needWorkerThread;
        lock (_sync) {
            try {
                if (IsDisableStateComplete()) return;
            } catch {}

            needWorkerThread = !_killActive || _killThread == null || !_killThread.IsAlive;
            _killActive = true;
        }

        try {
            ApplyServerIpBlock();
            ScanAndBlockActiveConnections();
            KillTargetsOnce();
        } catch {}

        if (!needWorkerThread) return;

        _killThread = new Thread(delegate() {
            int rescanCounter = 0;
            while (_killActive) {
                try { KillTargetsOnce(); } catch {}
                rescanCounter++;
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

    static void DisengageKillSwitch() {
        try {
            if (IsEnableStateComplete()) return;
        } catch {}

        bool wasActive;
        Thread killThreadSnapshot;
        lock (_sync) {
            try {
                if (IsEnableStateComplete()) return;
            } catch {}

            wasActive = _killActive;
            _killActive = false;
            killThreadSnapshot = _killThread;
        }

        if (wasActive && killThreadSnapshot != null && killThreadSnapshot.IsAlive) {
            try { killThreadSnapshot.Join(10000); } catch {}
        }

        for (int pass = 0; pass < 2; pass++) {
            try { RemoveAllFirewallRules(); } catch {}
            try {
                if (!AreAnyOurFirewallRulesPresent()) break;
            } catch { break; }
        }

        Thread.Sleep(300);
        try { LaunchTargetsIfNeeded(); } catch {}
    }

    static string RemoteIpSpec() {
        if (string.IsNullOrEmpty(_serverIp)) return _serverIp;
        if (_serverIp.IndexOf(':') >= 0) return _serverIp;
        if (_serverIp.IndexOf('/') >= 0) return _serverIp;
        return _serverIp + "/32";
    }

    static void TrackRuleName(string ruleName) {
        lock (_sync) {
            if (!_createdRuleNames.Contains(ruleName))
                _createdRuleNames.Add(ruleName);
        }
    }

    static bool IsDisableStateComplete() {
        bool active;
        Thread worker;
        lock (_sync) {
            active = _killActive;
            worker = _killThread;
        }
        if (!active) return false;
        if (worker == null || !worker.IsAlive) return false;
        if (!AreCoreBlockRulesPresent()) return false;
        if (AreAnyTargetProcessesRunning()) return false;
        return true;
    }

    static bool IsEnableStateComplete() {
        bool active;
        Thread worker;
        lock (_sync) {
            active = _killActive;
            worker = _killThread;
        }
        if (active) return false;
        if (worker != null && worker.IsAlive) return false;
        if (AreAnyOurFirewallRulesPresent()) return false;
        if (!AreAllLaunchableTargetsRunning()) return false;
        return true;
    }

    static bool AreCoreBlockRulesPresent() {
        return FirewallRuleExists(_rulePrefix + "A")
            && FirewallRuleExists(_rulePrefix + "B")
            && FirewallRuleExists(_rulePrefix + "C");
    }

    static bool AreAnyOurFirewallRulesPresent() {
        try {
            return CountOurFirewallRules() > 0;
        } catch {}
        return false;
    }

    static bool FirewallRuleExists(string ruleName) {
        try {
            ProcessStartInfo psi = new ProcessStartInfo("netsh.exe",
                string.Format("advfirewall firewall show rule name=\"{0}\"", ruleName));
            psi.UseShellExecute        = false;
            psi.CreateNoWindow         = true;
            psi.WindowStyle            = ProcessWindowStyle.Hidden;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError  = true;
            Process p = Process.Start(psi);
            string output = p.StandardOutput.ReadToEnd();
            p.WaitForExit(3000);
            if (p.ExitCode != 0) return false;
            return output.IndexOf(ruleName, StringComparison.OrdinalIgnoreCase) >= 0;
        } catch { return false; }
    }

    static bool AreAnyTargetProcessesRunning() {
        foreach (string exe in _targetExeNames) {
            string baseName = Path.GetFileNameWithoutExtension(exe);
            if (IsTargetProcessRunning(baseName)) return true;
        }
        return false;
    }

    static bool AreAllLaunchableTargetsRunning() {
        bool anyLaunchable = false;
        foreach (string tp in _targetPaths) {
            if (!Directory.Exists(tp)) continue;
            bool foundInFolder = false;
            bool allRunningInFolder = true;
            foreach (string exe in _targetExeNames) {
                string fullPath = Path.Combine(tp, exe);
                if (!File.Exists(fullPath)) continue;
                foundInFolder = true;
                anyLaunchable = true;
                string baseName = Path.GetFileNameWithoutExtension(exe);
                if (!IsTargetProcessRunning(baseName)) allRunningInFolder = false;
            }
            if (foundInFolder) return allRunningInFolder;
        }
        return !anyLaunchable;
    }

    static bool IsTargetProcessRunning(string processNameWithoutExtension) {
        if (string.IsNullOrEmpty(processNameWithoutExtension)) return false;
        foreach (Process p in Process.GetProcesses()) {
            try {
                if (p.ProcessName.Equals(processNameWithoutExtension, StringComparison.OrdinalIgnoreCase))
                    return true;
            } catch {}
        }
        return false;
    }

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

    static void LaunchTargetsIfNeeded() {
        foreach (string tp in _targetPaths) {
            if (!Directory.Exists(tp)) continue;
            bool foundAnyExeInFolder = false;
            foreach (string exe in _targetExeNames) {
                string fullPath = Path.Combine(tp, exe);
                if (!File.Exists(fullPath)) continue;
                foundAnyExeInFolder = true;
                string baseName = Path.GetFileNameWithoutExtension(exe);
                if (IsTargetProcessRunning(baseName)) continue;
                try {
                    ProcessStartInfo psi = new ProcessStartInfo();
                    psi.FileName = fullPath;
                    psi.WorkingDirectory = tp;
                    psi.UseShellExecute = true;
                    psi.WindowStyle = ProcessWindowStyle.Hidden;
                    Process.Start(psi);
                } catch {}
            }
            if (foundAnyExeInFolder) return;
        }
    }

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

    static void ApplyServerIpBlock() {
        string ruleOut     = _rulePrefix + "A";
        string ruleIn      = _rulePrefix + "B";
        string rulePortOut = _rulePrefix + "C";
        string remoteIp    = RemoteIpSpec();

        DeleteFirewallRuleByName(ruleOut);
        DeleteFirewallRuleByName(ruleIn);
        DeleteFirewallRuleByName(rulePortOut);

        if (RunNetsh(string.Format(
            "advfirewall firewall add rule name=\"{0}\" dir=out action=block remoteip={1} profile=any enable=yes",
            ruleOut, remoteIp)) == 0) TrackRuleName(ruleOut);
        if (RunNetsh(string.Format(
            "advfirewall firewall add rule name=\"{0}\" dir=in action=block remoteip={1} profile=any enable=yes",
            ruleIn, remoteIp)) == 0) TrackRuleName(ruleIn);
        if (RunNetsh(string.Format(
            "advfirewall firewall add rule name=\"{0}\" dir=out action=block protocol=TCP remoteip={1} remoteport={2} profile=any enable=yes",
            rulePortOut, remoteIp, _serverPort)) == 0) TrackRuleName(rulePortOut);

        EnsureCoreBlockRulesPresent();
    }

    static void EnsureCoreBlockRulesPresent() {
        string ruleOut     = _rulePrefix + "A";
        string ruleIn      = _rulePrefix + "B";
        string rulePortOut = _rulePrefix + "C";
        string remoteIp    = RemoteIpSpec();

        if (!FirewallRuleExists(ruleOut)) {
            DeleteFirewallRuleByName(ruleOut);
            if (RunNetsh(string.Format(
                "advfirewall firewall add rule name=\"{0}\" dir=out action=block remoteip={1} profile=any enable=yes",
                ruleOut, remoteIp)) == 0) TrackRuleName(ruleOut);
        }
        if (!FirewallRuleExists(ruleIn)) {
            DeleteFirewallRuleByName(ruleIn);
            if (RunNetsh(string.Format(
                "advfirewall firewall add rule name=\"{0}\" dir=in action=block remoteip={1} profile=any enable=yes",
                ruleIn, remoteIp)) == 0) TrackRuleName(ruleIn);
        }
        if (!FirewallRuleExists(rulePortOut)) {
            DeleteFirewallRuleByName(rulePortOut);
            if (RunNetsh(string.Format(
                "advfirewall firewall add rule name=\"{0}\" dir=out action=block protocol=TCP remoteip={1} remoteport={2} profile=any enable=yes",
                rulePortOut, remoteIp, _serverPort)) == 0) TrackRuleName(rulePortOut);
        }
    }

    static void DeleteFirewallRuleByName(string ruleName) {
        try {
            RunNetsh(string.Format("advfirewall firewall delete rule name=\"{0}\"", ruleName));
        } catch {}
    }

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

            string[] cols = System.Text.RegularExpressions.Regex.Split(line, "\\s+");
            if (cols.Length < 5) continue;
            int pid;
            if (!int.TryParse(cols[cols.Length - 1], out pid)) continue;
            if (pid <= 4) continue;
            pidsTalkingToServer.Add(pid);
        }

        foreach (int pid in pidsTalkingToServer) {
            string exePath = null;
            try {
                Process proc = Process.GetProcessById(pid);
                exePath = proc.MainModule.FileName;
            } catch {}
            if (string.IsNullOrEmpty(exePath)) continue;

            bool alreadyBlocked;
            lock (_sync) { alreadyBlocked = _blockedExePaths.Contains(exePath); }
            if (alreadyBlocked) continue;

            string ruleName = _rulePrefix + (exePath.GetHashCode() & 0x7FFFFFFF).ToString();
            DeleteFirewallRuleByName(ruleName);
            int code = RunNetsh(string.Format(
                "advfirewall firewall add rule name=\"{0}\" dir=out action=block program=\"{1}\" profile=any enable=yes",
                ruleName, exePath));
            if (code == 0) {
                lock (_sync) {
                    _blockedExePaths.Add(exePath);
                }
                TrackRuleName(ruleName);
            }
        }
    }

    static void RemoveAllFirewallRules() {
        List<string> snapshot;
        lock (_sync) {
            snapshot = new List<string>(_createdRuleNames);
        }
        foreach (string ruleName in snapshot) {
            DeleteFirewallRuleByName(ruleName);
        }

        DeleteFirewallRuleByName(_rulePrefix + "A");
        DeleteFirewallRuleByName(_rulePrefix + "B");
        DeleteFirewallRuleByName(_rulePrefix + "C");

        lock (_sync) {
            _createdRuleNames.Clear();
            _blockedExePaths.Clear();
        }

        SweepFirewallRulesByPrefix();
    }

    static void SweepFirewallRulesByPrefix() {
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
            p.WaitForExit(20000);
        } catch {}
    }

    static int CountOurFirewallRules() {
        try {
            string psCmd = string.Format(
                "(Get-NetFirewallRule -DisplayName '{0}*' -ErrorAction SilentlyContinue | Measure-Object).Count",
                _rulePrefix);
            ProcessStartInfo psi = new ProcessStartInfo("powershell.exe",
                "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command \"" + psCmd + "\"");
            psi.UseShellExecute        = false;
            psi.CreateNoWindow         = true;
            psi.WindowStyle            = ProcessWindowStyle.Hidden;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError  = true;
            Process p = Process.Start(psi);
            string output = p.StandardOutput.ReadToEnd().Trim();
            p.WaitForExit(20000);
            int count;
            if (int.TryParse(output, out count)) return count;
        } catch {}
        int fallback = 0;
        if (FirewallRuleExists(_rulePrefix + "A")) fallback++;
        if (FirewallRuleExists(_rulePrefix + "B")) fallback++;
        if (FirewallRuleExists(_rulePrefix + "C")) fallback++;
        return fallback;
    }
}
'@


$exesCsharp  = ($TargetExeNames | ForEach-Object { '        @"' + $_ + '"' }) -join ",`r`n"
$pathsCsharp = ($TargetPaths    | ForEach-Object { '        @"' + $_ + '"' }) -join ",`r`n"

$csSource = $csSource.Replace('__SERVER_IP__',    $ServerIP)
$csSource = $csSource.Replace('__SERVER_PORT__',  [string]$ServerPort)
$csSource = $csSource.Replace('__RULE_PREFIX__',  $RuleNamePrefix)
$csSource = $csSource.Replace('__TARGET_EXES__',  $exesCsharp)
$csSource = $csSource.Replace('__TARGET_PATHS__', $pathsCsharp)


$allTaskNames = @($TaskName) + $LegacyTaskNames
foreach ($tn in $allTaskNames) {
    try {
        if (Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask       -TaskName $tn -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
        }
    } catch {}
}

$allExeNames = @($WorkerExeName) + $LegacyExeNames
foreach ($exeName in $allExeNames) {
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($exeName)
    Get-Process -Name $baseName -ErrorAction SilentlyContinue | ForEach-Object {
        try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
}

Start-Sleep -Milliseconds 400

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

$allRulePrefixes = @($RuleNamePrefix) + $LegacyRulePrefixes
foreach ($rp in $allRulePrefixes) {
    try {
        Get-NetFirewallRule -DisplayName "$rp*" -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue
    } catch {}
}

foreach ($legacyName in $LegacyInstallNames) {
    $legacyPath = Join-Path $env:APPDATA $legacyName
    if (Test-Path $legacyPath) {
        try { Remove-Item $legacyPath -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }
}


$exePath = Join-Path $InstallDirectory $WorkerExeName

if (Test-Path $exePath) {
    try { (Get-Item $exePath -Force).Attributes = 'Normal' } catch {}
    try { Remove-Item $exePath -Force -ErrorAction SilentlyContinue } catch {}
}

try {
    Add-Type -TypeDefinition $csSource `
             -OutputAssembly $exePath `
             -OutputType WindowsApplication `
             -ErrorAction Stop
} catch {
    try {
        $logPath = Join-Path $env:TEMP 'install_error.log'
        $_.Exception.ToString() | Set-Content -Path $logPath -Encoding UTF8 -Force
    } catch {}
    exit 1
}

if (-not (Test-Path $exePath) -or (Get-Item $exePath -Force).Length -lt 1024) {
    try {
        $logPath = Join-Path $env:TEMP 'install_error.log'
        'Worker EXE missing or truncated after compile (possible AV/Defender/SmartAppControl quarantine of System32 write).' |
            Set-Content -Path $logPath -Encoding UTF8 -Force
    } catch {}
    exit 1
}

try {
    (Get-Item $exePath -Force).Attributes = 'Hidden,System,ReadOnly,Archive'
} catch {}


$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value

$action    = New-ScheduledTaskAction    -Execute $exePath -WorkingDirectory $InstallDirectory
$trigger   = New-ScheduledTaskTrigger   -AtLogOn -User $currentSid
$principal = New-ScheduledTaskPrincipal -UserId $currentSid -LogonType Interactive -RunLevel Highest
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
    -Description 'Background service helper.' `
    -Force | Out-Null


try {
    Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
} catch {
    Start-Process -FilePath $exePath -WindowStyle Hidden -ErrorAction SilentlyContinue
}

Start-Sleep -Milliseconds 1500
$workerBase = [System.IO.Path]::GetFileNameWithoutExtension($WorkerExeName)
if (-not (Get-Process -Name $workerBase -ErrorAction SilentlyContinue)) {
    Start-Process -FilePath $exePath -WindowStyle Hidden -ErrorAction SilentlyContinue
}

exit 0
