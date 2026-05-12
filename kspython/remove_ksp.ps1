# =====================================================================
#  remove_ksp.ps1
#  Uninstaller for the WMI / monitor-app kill-switch service.
#
#  Run it from ANY terminal -- the script auto-elevates via a hidden VBS
#  shim, removes everything, and exits silently.
#      .\remove_ksp.ps1
#      powershell -ExecutionPolicy Bypass -File .\remove_ksp.ps1
#
#  This script removes:
#    1. The scheduled task that auto-starts the worker at logon
#    2. Any running worker .exe (and legacy powershell-based worker)
#    3. Every firewall rule created by the kill-switch
#    4. The hidden install folder under %APPDATA% (and legacy folders)
#
#  After this script runs, the system is fully restored to its
#  pre-install state -- no startup hook, no firewall blocks, no hotkeys.
# =====================================================================

# Reserved for the self-elevate handshake (do not pass this manually).
param([switch]$FromSelfElevate)


# =====================================================================
#  CONFIG  -- must match create_ksp.ps1
# =====================================================================

$WorkerExeName     = 'WmiSvcHelper.exe'
$InstallFolderName = 'WmiServiceCache'
$TaskName          = 'WmiSvcHelper'
$RuleNamePrefix    = 'WmiSvcHelper_'

# Legacy identifiers from earlier installer versions -- cleaned up too.
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
    # Silently relaunch elevated via a tiny VBS shim (see create_ksp.ps1
    # for why this is more reliable than Start-Process -Verb RunAs).
    $thisScript = $MyInvocation.MyCommand.Path
    if (-not $thisScript) { $thisScript = $PSCommandPath }

    # See create_ksp.ps1 for why we use concatenation + [char]34 instead
    # of `$(...)` interpolation when building the VBS content.
    $psArgsForElev = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$thisScript"" -FromSelfElevate"
    $psArgsForVbs  = $psArgsForElev.Replace('"', '""')
    $q             = [char]34

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
    } finally {
        Start-Sleep -Milliseconds 200
        Remove-Item $tmpVbs -Force -ErrorAction SilentlyContinue
    }
    exit 0
}

$hadError = $false


# =====================================================================
#  1) Unregister scheduled tasks (current + legacy)
# =====================================================================

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


# =====================================================================
#  2) Kill any running worker process
#     - current: a process matching $WorkerExeName
#     - legacy : a powershell.exe whose command line references the
#                legacy install folder / worker script
# =====================================================================

$workerBaseName = [System.IO.Path]::GetFileNameWithoutExtension($WorkerExeName)
Get-Process -Name $workerBaseName -ErrorAction SilentlyContinue | ForEach-Object {
    try { Stop-Process -Id $_.Id -Force -ErrorAction Stop }
    catch { $hadError = $true }
}

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


# =====================================================================
#  3) Remove all firewall rules created by the kill-switch
#     (current prefix + every legacy prefix)
# =====================================================================

$allRulePrefixes = @($RuleNamePrefix) + $LegacyRulePrefixes
foreach ($rp in $allRulePrefixes) {
    try {
        # Get-NetFirewallRule returns objects with English property names
        # regardless of system locale (unlike netsh's translated output).
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


# =====================================================================
#  4) Remove install folders (current + legacy)
# =====================================================================

$allInstallNames = @($InstallFolderName) + $LegacyInstallNames
foreach ($n in $allInstallNames) {
    $path = Join-Path $env:APPDATA $n
    if (Test-Path $path) {
        try {
            # Clear hidden+system+readonly attributes so Remove-Item
            # doesn't refuse on protected files.
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
