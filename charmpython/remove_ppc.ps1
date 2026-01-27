Get-Process powershell | Where-Object { 
    try { $_.MainModule.FileName } catch { $null } 
} | ForEach-Object {
    try {
        $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)" -ErrorAction SilentlyContinue).CommandLine
        if ($cmdLine -and ($cmdLine -like "*PythonPIPCharm*" -or $cmdLine -like "*Python_PIP_Charm*" -or $cmdLine -like "*store.ps1*")) {
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

$vbsPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\pythonpipcharm.vbs"
if (Test-Path $vbsPath) { 
    Remove-Item $vbsPath -Force -ErrorAction SilentlyContinue 
}

$installPath = "$env:APPDATA\Python_PIP_Charm"
if (Test-Path $installPath) { 
    Remove-Item $installPath -Recurse -Force -ErrorAction SilentlyContinue 
}
