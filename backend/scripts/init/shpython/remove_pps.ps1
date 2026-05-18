$pythonPipSHHasError = $false

Get-Process powershell -ErrorAction SilentlyContinue | Where-Object { 
    try { $_.MainModule.FileName } catch { $null } 
} | ForEach-Object {
    try {
        $pythonPipSHCmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)" -ErrorAction SilentlyContinue).CommandLine
        if ($pythonPipSHCmdLine -and ($pythonPipSHCmdLine -like "*PythonPipSH*" -or $pythonPipSHCmdLine -like "*pythonpipsh*" -or $pythonPipSHCmdLine -like "*pythonpipsh_service.ps1*")) {
            Stop-Process -Id $_.Id -Force -ErrorAction Stop
        }
    } catch {
        Write-Host "Error stopping process $($_.Id): $_" -ForegroundColor Red
        $pythonPipSHHasError = $true
    }
}

$pythonPipSHVbsPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\pythonpipsh.vbs"
if (Test-Path $pythonPipSHVbsPath) { 
    try {
        Remove-Item $pythonPipSHVbsPath -Force -ErrorAction Stop
    } catch {
        Write-Host "Error removing startup script: $_" -ForegroundColor Red
        $pythonPipSHHasError = $true
    }
}

$pythonPipSHInstallPath = "$env:APPDATA\PythonPipSH"
if (Test-Path $pythonPipSHInstallPath) { 
    try {
        Remove-Item $pythonPipSHInstallPath -Recurse -Force -ErrorAction Stop
    } catch {
        Write-Host "Error removing install directory: $_" -ForegroundColor Red
        $pythonPipSHHasError = $true
    }
}

if ($pythonPipSHHasError) {
    exit 1
}
