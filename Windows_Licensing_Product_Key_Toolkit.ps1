#requires -Version 5.1
<#
.SYNOPSIS
    Windows licensing, activation-channel and OEM key inventory and repair toolkit.
.DESCRIPTION
    Collects Windows licensing evidence by default. Guarded repair actions restart
    licensing services, reinstall Windows license files, request online activation,
    run DISM or SFC, and open Activation Settings. No activation bypass is included.
.NOTES
    Created by Dewald Pretorius - L2 IT Support Engineer.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('Diagnose','RepairAllSafe','RestartLicensingServices','ReinstallLicenseFiles','AttemptActivation','RunDISM','RunSFC','OpenActivationSettings','ExportFullOemKey')]
    [string]$Action = 'Diagnose',
    [string]$OutputPath,
    [switch]$DryRun,
    [switch]$Yes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.0.0'
$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$ExitCode = 0
$SlmgrPath = Join-Path $env:SystemRoot 'System32\slmgr.vbs'

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path ([Environment]::GetFolderPath('Desktop')) "Windows_Licensing_$Stamp"
}
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$SensitivePath = Join-Path $OutputPath 'sensitive'
$LogPath = Join-Path $OutputPath 'toolkit.log'

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS','DRYRUN')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    switch ($Level) {
        'WARN' { Write-Host $Message -ForegroundColor Yellow }
        'ERROR' { Write-Host $Message -ForegroundColor Red }
        'SUCCESS' { Write-Host $Message -ForegroundColor Green }
        'DRYRUN' { Write-Host "DRY RUN: $Message" -ForegroundColor Cyan }
        default { Write-Host $Message }
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Require-Administrator {
    if (-not (Test-IsAdministrator)) {
        throw 'This licensing repair requires an elevated PowerShell session.'
    }
}

function Confirm-Action {
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Token = 'REPAIR'
    )
    if ($DryRun -or $Yes) { return $true }
    return (Read-Host "$Message Type $Token to continue") -eq $Token
}

function Protect-SensitiveDirectory {
    param([Parameter(Mandatory)][string]$Path)

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $systemSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($currentSid, 'FullControl', $inheritance, $propagation, $allow)))
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($systemSid, 'FullControl', $inheritance, $propagation, $allow)))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Get-LicenseStatusName {
    param([int]$Status)
    switch ($Status) {
        0 { 'Unlicensed' }
        1 { 'Licensed' }
        2 { 'OOBGrace' }
        3 { 'OOTGrace' }
        4 { 'NonGenuineGrace' }
        5 { 'Notification' }
        6 { 'ExtendedGrace' }
        default { "Unknown ($Status)" }
    }
}

function Get-OemKey {
    try {
        return [string](Get-CimInstance SoftwareLicensingService -ErrorAction Stop).OA3xOriginalProductKey
    } catch {
        return $null
    }
}

function Mask-ProductKey {
    param([string]$Key)
    if ([string]::IsNullOrWhiteSpace($Key)) { return $null }
    $clean = $Key.Trim()
    if ($clean.Length -le 5) { return ('*' * $clean.Length) }
    return ('*' * ($clean.Length - 5)) + $clean.Substring($clean.Length - 5)
}

function Get-WindowsLicenses {
    $windowsApplicationId = '55c92734-d682-4d71-983e-d6ec3f16059f'
    return @(
        Get-CimInstance SoftwareLicensingProduct -ErrorAction SilentlyContinue |
            Where-Object { $_.ApplicationID -eq $windowsApplicationId -and $_.PartialProductKey } |
            ForEach-Object {
                [pscustomobject]@{
                    Name = $_.Name
                    Description = $_.Description
                    LicenseStatus = $_.LicenseStatus
                    LicenseStatusName = Get-LicenseStatusName -Status ([int]$_.LicenseStatus)
                    PartialProductKey = $_.PartialProductKey
                    ProductKeyChannel = $_.ProductKeyChannel
                    GracePeriodRemainingMinutes = $_.GracePeriodRemaining
                    ID = $_.ID
                }
            }
    )
}

function Invoke-Slmgr {
    param(
        [Parameter(Mandatory)][string]$Argument,
        [Parameter(Mandatory)][string]$OutputFile
    )

    if (-not (Test-Path -LiteralPath $SlmgrPath)) { throw 'slmgr.vbs was not found.' }
    $output = & cscript.exe //NoLogo $SlmgrPath $Argument 2>&1
    $output | Set-Content -LiteralPath $OutputFile -Encoding UTF8
    $output | Add-Content -LiteralPath $LogPath
    return $LASTEXITCODE
}

function Save-State {
    param([Parameter(Mandatory)][string]$Stage)

    $os = Get-CimInstance Win32_OperatingSystem
    $service = Get-CimInstance SoftwareLicensingService -ErrorAction SilentlyContinue
    $licenses = @(Get-WindowsLicenses)
    $oemKey = Get-OemKey
    $services = @(Get-Service sppsvc, ClipSVC, LicenseManager -ErrorAction SilentlyContinue |
        Select-Object Name, Status, StartType)

    $state = [ordered]@{
        Stage = $Stage
        Generated = (Get-Date).ToString('o')
        ScriptVersion = $ScriptVersion
        Computer = $env:COMPUTERNAME
        IsAdministrator = (Test-IsAdministrator)
        OperatingSystem = [ordered]@{
            Caption = $os.Caption
            Version = $os.Version
            BuildNumber = $os.BuildNumber
            OSArchitecture = $os.OSArchitecture
        }
        LicensingService = if ($service) {
            [ordered]@{
                Version = $service.Version
                KeyManagementServiceMachine = $service.KeyManagementServiceMachine
                KeyManagementServicePort = $service.KeyManagementServicePort
                OA3xOriginalProductKeyMasked = Mask-ProductKey -Key $oemKey
            }
        } else { $null }
        WindowsLicenses = $licenses
        Services = $services
    }

    $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputPath "$Stage.json") -Encoding UTF8
    $licenses | Export-Csv -LiteralPath (Join-Path $OutputPath "$Stage-windows-licenses.csv") -NoTypeInformation -Encoding UTF8
    $services | Export-Csv -LiteralPath (Join-Path $OutputPath "$Stage-licensing-services.csv") -NoTypeInformation -Encoding UTF8

    if (Test-Path -LiteralPath $SlmgrPath) {
        [void](Invoke-Slmgr -Argument '/dlv' -OutputFile (Join-Path $OutputPath "$Stage-slmgr-dlv.txt"))
        [void](Invoke-Slmgr -Argument '/xpr' -OutputFile (Join-Path $OutputPath "$Stage-slmgr-xpr.txt"))
    }

    Write-Log "Saved $Stage Windows licensing state." 'SUCCESS'
    return $state
}

function Invoke-RestartLicensingServices {
    Require-Administrator
    if (-not (Confirm-Action 'Start or restart available Windows licensing services?')) { throw 'User cancelled.' }

    foreach ($serviceName in @('sppsvc','ClipSVC','LicenseManager')) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if (-not $service) {
            Write-Log "Service $serviceName is not present on this Windows edition." 'WARN'
            continue
        }

        if ($DryRun) {
            Write-Log "Would start or restart $serviceName." 'DRYRUN'
            continue
        }

        try {
            if ($service.Status -eq 'Running') {
                Restart-Service -Name $serviceName -Force -ErrorAction Stop
            } else {
                Start-Service -Name $serviceName -ErrorAction Stop
            }
            Write-Log "Licensing service $serviceName is running or was successfully triggered." 'SUCCESS'
        } catch {
            Write-Log "Could not restart $serviceName directly: $($_.Exception.Message). Trigger-start services may stop when idle." 'WARN'
        }
    }
}

function Invoke-AttemptActivation {
    Require-Administrator
    if (-not (Confirm-Action 'Request legitimate online Windows activation using the installed licence?')) { throw 'User cancelled.' }
    if ($DryRun) {
        Write-Log 'Would run slmgr.vbs /ato.' 'DRYRUN'
        return
    }

    $code = Invoke-Slmgr -Argument '/ato' -OutputFile (Join-Path $OutputPath 'slmgr-ato.txt')
    if ($code -ne 0) { throw "Activation request returned exit code $code." }
    Write-Log 'Windows activation request completed. Review slmgr-ato.txt and the after-state report.' 'SUCCESS'
}

function Invoke-ReinstallLicenseFiles {
    Require-Administrator
    if (-not (Confirm-Action 'Reinstall Windows system licence files using slmgr /rilc? A restart may be required.')) { throw 'User cancelled.' }
    if ($DryRun) {
        Write-Log 'Would run slmgr.vbs /rilc.' 'DRYRUN'
        return
    }

    $code = Invoke-Slmgr -Argument '/rilc' -OutputFile (Join-Path $OutputPath 'slmgr-rilc.txt')
    if ($code -ne 0) { throw "Licence-file reinstall returned exit code $code." }
    Write-Log 'Windows system licence files were reinstalled. Restart Windows before final validation if activation remains inconsistent.' 'SUCCESS'
}

function Invoke-DismRestoreHealth {
    Require-Administrator
    if (-not (Confirm-Action 'Run DISM RestoreHealth for Windows component repair?')) { throw 'User cancelled.' }
    if ($DryRun) {
        Write-Log 'Would run DISM /Online /Cleanup-Image /RestoreHealth.' 'DRYRUN'
        return
    }
    & dism.exe /Online /Cleanup-Image /RestoreHealth 2>&1 | Tee-Object -FilePath (Join-Path $OutputPath 'dism-restorehealth.txt') | Add-Content -LiteralPath $LogPath
    if ($LASTEXITCODE -ne 0) { throw "DISM returned exit code $LASTEXITCODE." }
    Write-Log 'DISM RestoreHealth completed successfully.' 'SUCCESS'
}

function Invoke-SystemFileChecker {
    Require-Administrator
    if (-not (Confirm-Action 'Run System File Checker?')) { throw 'User cancelled.' }
    if ($DryRun) {
        Write-Log 'Would run sfc.exe /scannow.' 'DRYRUN'
        return
    }
    & sfc.exe /scannow 2>&1 | Tee-Object -FilePath (Join-Path $OutputPath 'sfc-scannow.txt') | Add-Content -LiteralPath $LogPath
    if ($LASTEXITCODE -notin 0,1,2,3) { throw "SFC returned unexpected exit code $LASTEXITCODE." }
    Write-Log "System File Checker completed with exit code $LASTEXITCODE." 'SUCCESS'
}

function Invoke-OpenActivationSettings {
    if ($DryRun) {
        Write-Log 'Would open Windows Activation Settings.' 'DRYRUN'
        return
    }
    Start-Process 'ms-settings:activation'
    Write-Log 'Opened Windows Activation Settings.' 'SUCCESS'
}

function Invoke-ExportFullOemKey {
    $key = Get-OemKey
    if ([string]::IsNullOrWhiteSpace($key)) { throw 'No OEM firmware product key was reported by Windows.' }
    if (-not (Confirm-Action 'Export the full OEM firmware product key to a restricted local folder? Treat it as sensitive.' -Token 'SENSITIVE')) {
        throw 'User cancelled.'
    }

    if ($DryRun) {
        Write-Log 'Would export the full OEM firmware key to a restricted local file.' 'DRYRUN'
        return
    }

    Protect-SensitiveDirectory -Path $SensitivePath
    $file = Join-Path $SensitivePath 'OEM-Firmware-Product-Key.txt'
    Set-Content -LiteralPath $file -Encoding UTF8 -Value @(
        'SENSITIVE - DO NOT COMMIT OR SHARE PUBLICLY'
        "Computer: $env:COMPUTERNAME"
        "Generated: $((Get-Date).ToString('o'))"
        "OEM Firmware Product Key: $key"
    )
    Write-Log "Exported the OEM firmware product key to the restricted file $file." 'SUCCESS'
}

Write-Log "Windows Licensing Product Key Toolkit $ScriptVersion started. Action=$Action DryRun=$DryRun"
$before = Save-State -Stage 'before'

try {
    switch ($Action) {
        'Diagnose' { }
        'RepairAllSafe' {
            Invoke-RestartLicensingServices
            Invoke-AttemptActivation
        }
        'RestartLicensingServices' { Invoke-RestartLicensingServices }
        'ReinstallLicenseFiles' { Invoke-ReinstallLicenseFiles }
        'AttemptActivation' { Invoke-AttemptActivation }
        'RunDISM' { Invoke-DismRestoreHealth }
        'RunSFC' { Invoke-SystemFileChecker }
        'OpenActivationSettings' { Invoke-OpenActivationSettings }
        'ExportFullOemKey' { Invoke-ExportFullOemKey }
    }
} catch {
    if ($_.Exception.Message -eq 'User cancelled.') {
        $ExitCode = 10
        Write-Log 'Action cancelled by the user.' 'WARN'
    } elseif ($_.Exception.Message -match 'elevated') {
        $ExitCode = 4
        Write-Log $_.Exception.Message 'ERROR'
    } elseif ($_.Exception.Message -match 'No OEM|not found') {
        $ExitCode = 2
        Write-Log $_.Exception.Message 'ERROR'
    } else {
        $ExitCode = 20
        Write-Log $_.Exception.Message 'ERROR'
    }
} finally {
    try { [void](Save-State -Stage 'after') } catch { Write-Log "Post-action snapshot failed: $($_.Exception.Message)" 'WARN' }
}

if ($ExitCode -eq 0) {
    Write-Log "Completed successfully. Output: $OutputPath" 'SUCCESS'
} else {
    Write-Log "Completed with exit code $ExitCode. Output: $OutputPath" 'ERROR'
}
exit $ExitCode
