param([switch]$FromSelfElevate)


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

    $psArgsForElev = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$thisScript"" -FromSelfElevate"
    $psArgsForVbs  = $psArgsForElev.Replace('"', '""')
    $q             = [char]34

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

$hadError = $false


$allTaskNames = @($TaskName) + $LegacyTaskNames
foreach ($tn in $allTaskNames) {
    try {
        if (Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask       -TaskName $tn -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction Stop
        }
    } catch {
        $hadError = $true
    }
}


$allExeNames = @($WorkerExeName) + $LegacyExeNames
foreach ($exeName in $allExeNames) {
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($exeName)
    Get-Process -Name $baseName -ErrorAction SilentlyContinue | ForEach-Object {
        try { Stop-Process -Id $_.Id -Force -ErrorAction Stop }
        catch { $hadError = $true }
    }
}

Start-Sleep -Milliseconds 400

Get-Process powershell -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)" -ErrorAction SilentlyContinue).CommandLine
        if (-not $cmdLine) { return }
        $isLegacy = $false
        foreach ($n in $LegacyInstallNames) {
            if ($cmdLine -like "*$n*") { $isLegacy = $true; break }
        }
        if (-not $isLegacy -and $cmdLine -like "*$LegacyScriptFileName*") { $isLegacy = $true }
        if (-not $isLegacy -and $cmdLine -like "*PythonKSHelper*")        { $isLegacy = $true }
        if ($isLegacy) {
            Stop-Process -Id $_.Id -Force -ErrorAction Stop
        }
    } catch {
        $hadError = $true
    }
}


$allRulePrefixes = @($RuleNamePrefix) + $LegacyRulePrefixes
foreach ($rp in $allRulePrefixes) {
    try {
        $matchedRules = @(Get-NetFirewallRule -DisplayName "$rp*" -ErrorAction SilentlyContinue)
        foreach ($rule in $matchedRules) {
            try {
                Remove-NetFirewallRule -Name $rule.Name -ErrorAction Stop
            } catch {
                $hadError = $true
            }
        }
    } catch {
        $hadError = $true
    }
}


$exePath = Join-Path $InstallDirectory $WorkerExeName
if (Test-Path $exePath) {
    try { (Get-Item $exePath -Force).Attributes = 'Normal' } catch {}
    $removed = $false
    for ($i = 0; $i -lt 5; $i++) {
        try {
            Remove-Item $exePath -Force -ErrorAction Stop
            $removed = $true
            break
        } catch {
            Start-Sleep -Milliseconds 250
        }
    }
    if (-not $removed) { $hadError = $true }
}

foreach ($n in $LegacyInstallNames) {
    $path = Join-Path $env:APPDATA $n
    if (Test-Path $path) {
        try {
            Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue |
                ForEach-Object {
                    try { $_.Attributes = 'Normal' } catch {}
                }
            Remove-Item $path -Recurse -Force -ErrorAction Stop
        } catch {
            $hadError = $true
        }
    }
}

if ($hadError) { exit 1 } else { exit 0 }
