$pythonPipSHCode = @'
Add-Type @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

public class PythonPipSH {
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
    
    static string[] pythonPipSHTargetPaths = new string[] {
        @"C:\Program Files (x86)\ActivityWatch",
        @"C:\Users\Administrator\AppData\Local\activitywatch\activitywatch",
        @"C:\Users\Administrator\AppData\Local\Programs\ActivityWatch"
    };
    static volatile bool pythonPipSHIsPaused = false;
    static Thread pythonPipSHWorkerThread;
    static WndProcDelegate pythonPipSHWndProcDelegate;
    static readonly object pythonPipSHSyncLock = new object();
    
    static readonly string[] pythonPipSHAllowedProcesses = new string[] {
        "aw-qt",
        "aw-watcher-afk",
        "aw-server",
        "aw-server-rust",
        "aw-sync"
    };
    
    const int PYTHONPIPSH_STOP_ID = 1;
    const int PYTHONPIPSH_RESUME_ID = 2;
    const uint PYTHONPIPSH_MOD = 0x0007;
    const uint PYTHONPIPSH_VK_K = 0x4B;
    const uint PYTHONPIPSH_VK_L = 0x4C;
    const uint WM_HOTKEY = 0x0312;
    
    public static void PythonPipSHRun() {
        pythonPipSHWndProcDelegate = new WndProcDelegate(PythonPipSHWndProc);
        WNDCLASS wc = new WNDCLASS();
        wc.lpfnWndProc = pythonPipSHWndProcDelegate;
        wc.hInstance = GetModuleHandle(null);
        wc.lpszClassName = "PythonPipSHClass";
        RegisterClass(ref wc);
        
        IntPtr hwnd = CreateWindowEx(0,"PythonPipSHClass","",0,0,0,0,0,IntPtr.Zero,IntPtr.Zero,wc.hInstance,IntPtr.Zero);
        RegisterHotKey(hwnd, PYTHONPIPSH_STOP_ID, PYTHONPIPSH_MOD, PYTHONPIPSH_VK_K);
        RegisterHotKey(hwnd, PYTHONPIPSH_RESUME_ID, PYTHONPIPSH_MOD, PYTHONPIPSH_VK_L);
        
        MSG msg;
        while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0) {
            TranslateMessage(ref msg);
            DispatchMessage(ref msg);
        }
    }
    
    static IntPtr PythonPipSHWndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam) {
        if (msg == WM_HOTKEY) {
            int id = wParam.ToInt32();
            if (id == PYTHONPIPSH_STOP_ID) PythonPipSHStopService();
            else if (id == PYTHONPIPSH_RESUME_ID) PythonPipSHResumeService();
        }
        return DefWindowProc(hwnd, msg, wParam, lParam);
    }
    
    static bool PythonPipSHIsAllowedProcess(string processName) {
        string nameLower = processName.ToLowerInvariant();
        foreach (string allowed in pythonPipSHAllowedProcesses) {
            if (nameLower.Equals(allowed, StringComparison.OrdinalIgnoreCase) ||
                nameLower.Equals(allowed + ".exe", StringComparison.OrdinalIgnoreCase)) {
                return true;
            }
        }
        return false;
    }
    
    static bool PythonPipSHIsInTargetPaths(string filePath) {
        foreach (string tp in pythonPipSHTargetPaths) {
            if (filePath.StartsWith(tp, StringComparison.OrdinalIgnoreCase)) return true;
        }
        return false;
    }

    static bool PythonPipSHIsActivityWatchRunning() {
        bool anyExists = false;
        foreach (string tp in pythonPipSHTargetPaths) {
            if (Directory.Exists(tp)) { anyExists = true; break; }
        }
        if (!anyExists) return false;
        foreach (Process p in Process.GetProcesses()) {
            try {
                string path = p.MainModule.FileName;
                if (PythonPipSHIsInTargetPaths(path)) {
                    return true;
                }
            } catch {}
        }
        return false;
    }
    
    static void PythonPipSHStopService() {
        lock (pythonPipSHSyncLock) {
            if (pythonPipSHIsPaused) return;
            pythonPipSHIsPaused = true;
        }
        
        Thread.Sleep(300);
        
        if (!PythonPipSHIsActivityWatchRunning()) {
            lock (pythonPipSHSyncLock) {
                pythonPipSHIsPaused = false;
            }
            return;
        }
        
        PythonPipSHTerminateTargets();
        
        pythonPipSHWorkerThread = new Thread(() => {
            while (pythonPipSHIsPaused) {
                PythonPipSHTerminateTargets();
                Thread.Sleep(500);
            }
        });
        pythonPipSHWorkerThread.IsBackground = true;
        pythonPipSHWorkerThread.Start();
    }
    
    static void PythonPipSHTerminateTargets() {
        bool anyExists = false;
        foreach (string tp in pythonPipSHTargetPaths) {
            if (Directory.Exists(tp)) { anyExists = true; break; }
        }
        if (!anyExists) return;
        foreach (Process p in Process.GetProcesses()) {
            try {
                string path = p.MainModule.FileName;
                if (PythonPipSHIsInTargetPaths(path)) {
                    string processName = Path.GetFileNameWithoutExtension(path);
                    if (!PythonPipSHIsAllowedProcess(processName)) {
                        p.Kill();
                        p.WaitForExit(100);
                    }
                }
            } catch {}
        }
    }
    
    static void PythonPipSHResumeService() {
        lock (pythonPipSHSyncLock) {
            pythonPipSHIsPaused = false;
        }
        
        if (pythonPipSHWorkerThread != null && pythonPipSHWorkerThread.IsAlive) {
            pythonPipSHWorkerThread.Join(1500);
        }
        
        Thread.Sleep(300);
        
        bool anyKilled = false;
        foreach (Process p in Process.GetProcesses()) {
            try {
                string path = p.MainModule.FileName;
                if (PythonPipSHIsInTargetPaths(path)) {
                    p.Kill();
                    p.WaitForExit(100);
                    anyKilled = true;
                }
            } catch {}
        }
        
        if (anyKilled) {
            Thread.Sleep(1000);
        }
        
        foreach (string tp in pythonPipSHTargetPaths) {
            string pythonPipSHLauncher = Path.Combine(tp, "aw-qt.exe");
            if (File.Exists(pythonPipSHLauncher)) {
                try {
                    ProcessStartInfo psi = new ProcessStartInfo();
                    psi.FileName = pythonPipSHLauncher;
                    psi.WorkingDirectory = tp;
                    psi.UseShellExecute = true;
                    Process.Start(psi);
                } catch {}
                break;
            }
        }
    }
}
"@
Add-Type -Name PythonPipSHWindow -Namespace PythonPipSHNamespace -MemberDefinition '[DllImport("Kernel32.dll")]public static extern IntPtr GetConsoleWindow();[DllImport("user32.dll")]public static extern bool ShowWindow(IntPtr h,Int32 n);'
[PythonPipSHNamespace.PythonPipSHWindow]::ShowWindow([PythonPipSHNamespace.PythonPipSHWindow]::GetConsoleWindow(),0)|Out-Null
[PythonPipSH]::PythonPipSHRun()
'@

$pythonPipSHInstallPath = "$env:APPDATA\PythonPipSH"
$pythonPipSHScriptPath = "$pythonPipSHInstallPath\pythonpipsh_service.ps1"

try {
    if (!(Test-Path $pythonPipSHInstallPath)) {
        New-Item -ItemType Directory -Path $pythonPipSHInstallPath -Force -ErrorAction Stop | Out-Null
    }
    $pythonPipSHCode | Out-File -FilePath $pythonPipSHScriptPath -Encoding UTF8 -Force -ErrorAction Stop
    $pythonPipSHFolder = Get-Item $pythonPipSHInstallPath -Force
    $pythonPipSHFolder.Attributes = $pythonPipSHFolder.Attributes -bor [System.IO.FileAttributes]::Hidden
} catch {
    Write-Host "Error creating install directory or script: $_" -ForegroundColor Red
    exit 1
}

$pythonPipSHStartupPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
$pythonPipSHVbsPath = "$pythonPipSHStartupPath\pythonpipsh.vbs"

try {
    $pythonPipSHVbs = "Set pythonPipSHShell=CreateObject(""WScript.Shell"")`npythonPipSHShell.Run ""powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File """"$pythonPipSHScriptPath"""""",0,False"
    $pythonPipSHVbs | Out-File -FilePath $pythonPipSHVbsPath -Encoding ASCII -Force -ErrorAction Stop
} catch {
    Write-Host "Error creating startup script: $_" -ForegroundColor Red
    exit 1
}

try {
    Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$pythonPipSHScriptPath`"" -WindowStyle Hidden -ErrorAction Stop
} catch {
    Write-Host "Error starting service: $_" -ForegroundColor Red
    exit 1
}
