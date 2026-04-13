<#
.SYNOPSIS
    Audits custom service logon accounts across servers via parallel PSExec sessions.
.DESCRIPTION
    Discovers Windows Services, Scheduled Tasks, IIS Application Pools, and COM+
    Applications configured with non-builtin logon accounts. Results are written
    to a temp file on each remote server then read back via admin share.

    Supports GUI file pickers when paths are not supplied via parameters.
    Tests port 445 connectivity before launching PSExec against each server.
.PARAMETER PSExecPath
    Full path to PsExec.exe or PsExec64.exe. Auto-detected from common locations
    if not supplied.
.PARAMETER ServerListPath
    Path to .txt file with one server name per line. Opens a file picker if not
    supplied.
.PARAMETER OutputCsv
    Destination CSV path. Opens a save dialog if not supplied.
.PARAMETER ThrottleLimit
    Max concurrent PSExec sessions (default: 5).
.PARAMETER Credential
    Alternate credentials for PSExec and admin share access.
.EXAMPLE
    PS> .\Get-ServiceAccountAudit.ps1
.EXAMPLE
    PS> .\Get-ServiceAccountAudit.ps1 -ServerListPath C:\Servers.txt -ThrottleLimit 10
.EXAMPLE
    PS> .\Get-ServiceAccountAudit.ps1 -PSExecPath "D:\Tools\PsExec64.exe"
.NOTES
    Permissions : Local admin required on each target server.
    Read-only   : This script makes no changes. No backups required.
    Columns     : Server, Type, ObjectName, Details, Account, UseSID
#>

param(
    [string]$PSExecPath,
    [string]$ServerListPath,
    [string]$OutputCsv,
    [ValidateRange(1, 50)]
    [int]$ThrottleLimit = 5,
    [PSCredential]$Credential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region --- PowerShell Version Check ---
if ($PSVersionTable.PSVersion.Major -lt 3) {
    Write-Error "PowerShell 3.0 or higher is required. Current version: $($PSVersionTable.PSVersion)"
    return
}
#endregion

#region --- GUI Helper Functions ---
function Get-FileViaDialog {
    param(
        [string]$Title,
        [string]$Filter,
        [string]$InitialDirectory = [Environment]::GetFolderPath('Desktop')
    )
    Add-Type -AssemblyName System.Windows.Forms
    $dialog                  = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title            = $Title
    $dialog.Filter           = $Filter
    $dialog.InitialDirectory = $InitialDirectory
    $dialog.Multiselect      = $false
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.FileName
    }
    return $null
}

function Save-FileViaDialog {
    param(
        [string]$Title,
        [string]$Filter,
        [string]$DefaultFileName,
        [string]$InitialDirectory = [Environment]::GetFolderPath('Desktop')
    )
    Add-Type -AssemblyName System.Windows.Forms
    $dialog                  = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title            = $Title
    $dialog.Filter           = $Filter
    $dialog.FileName         = $DefaultFileName
    $dialog.InitialDirectory = $InitialDirectory
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.FileName
    }
    return $null
}
#endregion

#region --- PSExec Auto-Detection ---
$commonPSExecPaths = @(
    'C:\Temp\Tools\PsExec64.exe',
    'C:\Temp\Tools\PsExec.exe',
    'C:\Tools\PsExec64.exe',
    'C:\Tools\PsExec.exe',
    'C:\Windows\System32\PsExec64.exe',
    'C:\Windows\System32\PsExec.exe',
    'C:\Sysinternals\PsExec64.exe',
    'C:\Sysinternals\PsExec.exe'
)

if ($PSExecPath) {
    if (-not (Test-Path -Path $PSExecPath -PathType Leaf)) {
        Write-Error "PSExec not found at specified path: $PSExecPath"
        return
    }
} else {
    foreach ($p in $commonPSExecPaths) {
        if (Test-Path -Path $p -PathType Leaf) {
            $PSExecPath = $p
            Write-Output "PSExec found: $PSExecPath"
            break
        }
    }

    if (-not $PSExecPath) {
        Write-Warning "PSExec not found in common locations."
        $PSExecPath = Read-Host "Enter full path to PsExec.exe or PsExec64.exe"
        if (-not (Test-Path -Path $PSExecPath -PathType Leaf)) {
            Write-Error "PSExec not found at: $PSExecPath"
            return
        }
    }
}
#endregion

#region --- Input Validation ---

# Server list — parameter, then file picker, then typed path
if (-not $ServerListPath) {
    Write-Output "Select your server list file..."
    $ServerListPath = Get-FileViaDialog `
        -Title  "Select Server List" `
        -Filter "Text Files (*.txt)|*.txt|All Files (*.*)|*.*"

    if (-not $ServerListPath) {
        $ServerListPath = Read-Host "Server list path (file picker cancelled)"
    }
}

if (-not (Test-Path -Path $ServerListPath -PathType Leaf)) {
    Write-Error "Server list not found: $ServerListPath"
    return
}

# Output CSV — parameter, then save dialog, then typed path
if (-not $OutputCsv) {
    $defaultName = "ServiceAccountAudit_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    Write-Output "Choose where to save the output CSV..."
    $OutputCsv = Save-FileViaDialog `
        -Title           "Save Audit Results As" `
        -Filter          "CSV Files (*.csv)|*.csv|All Files (*.*)|*.*" `
        -DefaultFileName $defaultName

    if (-not $OutputCsv) {
        $OutputCsv = Read-Host "Output CSV path (dialog cancelled)"
    }
}

$csvDir = Split-Path -Path $OutputCsv -Parent
if ($csvDir -and -not (Test-Path -Path $csvDir)) {
    New-Item -ItemType Directory -Path $csvDir -Force | Out-Null
}

$servers = @(
    Get-Content -Path $ServerListPath |
    Where-Object  { $_ -match '\S' } |
    ForEach-Object { $_.Trim() } |
    Where-Object  { $_ -ne '' } |
    Select-Object -Unique
)

if ($servers.Count -eq 0) {
    Write-Error "No servers found in: $ServerListPath"
    return
}

Write-Output ''
Write-Output "Servers  : $($servers.Count)"
Write-Output "Throttle : $ThrottleLimit concurrent sessions"
Write-Output "PSExec   : $PSExecPath"
Write-Output "Output   : $OutputCsv"
Write-Output ''

#endregion

#region --- Remote Script Template ---
# Single-quoted here-string: NO escaping needed. Every $ is already literal.
# PLACEHOLDER_TEMPFILE is replaced per-server before encoding.

$remoteScriptTemplate = @'
$skipPatterns = @(
    'LocalSystem','SYSTEM','LocalService','NetworkService','NETWORK SERVICE','NETWORK_SERVICE',
    'LOCAL SERVICE','LOCAL_SERVICE','Interactive User','Run As User','N/A',
    'NT AUTHORITY\*','IIS APPPOOL\*'
)
$skipTaskPattern = 'S-1-5-\d+-\d+-\d+-\d+-\d+|\{[0-9A-Fa-f\-]{36}\}|^User_Feed_Synchronization|^OneDrive|^MicrosoftEdgeUpdateTaskUser'

function Test-BuiltInAccount {
    param([string]$Account)
    if (-not $Account -or $Account.Trim() -eq '') { return $true }
    foreach ($pattern in $skipPatterns) {
        if ($Account -like $pattern) { return $true }
    }
    return $false
}

function Get-LocalAccountSID {
    param([string]$Account)
    if (-not ($Account -like 'NT SERVICE\*') -and
        -not ($Account -like "$env:COMPUTERNAME\*") -and
        -not ($Account -match '^(\.\\|localhost\\)')) { return '' }
    try {
        (New-Object System.Security.Principal.NTAccount($Account)).Translate(
            [System.Security.Principal.SecurityIdentifier]).Value
    } catch { '' }
}

$out = [System.Collections.Generic.List[string]]::new()

# Windows Services
try {
    $svcs = @(Get-WmiObject -Class Win32_Service | Where-Object {
        $_.StartName -and -not (Test-BuiltInAccount -Account $_.StartName)
    })
    foreach ($svc in $svcs) {
        $out.Add("##|SVC|$($svc.DisplayName)|$($svc.Name)|$($svc.StartName)|$(Get-LocalAccountSID $svc.StartName)")
    }
} catch {}

# Scheduled Tasks - root level only (TaskPath eq '\')
try {
    if ($PSVersionTable.PSVersion.Major -ge 4) {
        $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
            $_.Principal -and
            $_.Principal.UserId -and
            $_.TaskPath -eq '\' -and
            $_.TaskName -notmatch $skipTaskPattern -and
            -not (Test-BuiltInAccount -Account $_.Principal.UserId)
        })
        foreach ($task in $tasks) {
            $path = $task.TaskPath.TrimEnd('\')
            $out.Add("##|TASK|$($task.TaskName)|$path|$($task.Principal.UserId)|$(Get-LocalAccountSID $task.Principal.UserId)")
        }
    } else {
        $raw = @(schtasks /query /fo CSV /v 2>&1 | Where-Object { $_ -match '\S' })
        if ($raw.Count -gt 0) {
            $parsed = @($raw | ConvertFrom-Csv -ErrorAction SilentlyContinue | Where-Object {
                $_.'Run As User' -and
                $_.'Run As User' -ne 'Run As User' -and
                $_.'TaskName'    -match '^\\\[^\\\]+$' -and
                $_.'TaskName'    -notmatch $skipTaskPattern -and
                -not (Test-BuiltInAccount -Account $_.'Run As User')
            })
            foreach ($t in $parsed) {
                $out.Add("##|TASK|$($t.'TaskName')|$($t.'Status')|$($t.'Run As User')|$(Get-LocalAccountSID $t.'Run As User')")
            }
        }
    }
} catch {}

# IIS Application Pools
try {
    if (Get-Service -Name W3SVC -ErrorAction SilentlyContinue) {
        if (Get-Module -ListAvailable -Name WebAdministration -ErrorAction SilentlyContinue) {
            Import-Module -Name WebAdministration -ErrorAction Stop
            $pools = @(Get-ChildItem -Path 'IIS:\AppPools' -ErrorAction SilentlyContinue | Where-Object {
                $_.processModel.identityType -eq 'SpecificUser' -and
                $_.processModel.userName -and
                -not (Test-BuiltInAccount -Account $_.processModel.userName)
            })
            foreach ($pool in $pools) {
                $out.Add("##|IIS|$($pool.Name)|AppPool|$($pool.processModel.userName)|$(Get-LocalAccountSID $pool.processModel.userName)")
            }
        } else {
            $out.Add('##|WARN|WebAdministration module not installed|IIS is running - check App Pools manually in IIS Manager|UNKNOWN|')
        }
    }
} catch {}

# COM+ Applications
try {
    $catalog = New-Object -ComObject COMAdmin.COMAdminCatalog
    $apps    = $catalog.GetCollection('Applications')
    $apps.Populate()
    for ($i = 0; $i -lt $apps.Count; $i++) {
        $app      = $apps.Item($i)
        $identity = $app.Value('Identity')
        if (-not (Test-BuiltInAccount -Account $identity)) {
            $out.Add("##|COM|$($app.Value('Name'))|COMPlusApp|$identity|$(Get-LocalAccountSID $identity)")
        }
    }
} catch {}

$out | Out-File -FilePath 'PLACEHOLDER_TEMPFILE' -Encoding UTF8 -Force
'@

#endregion

#region --- Connectivity Check + Launch Parallel PSExec Jobs ---

$jobMap      = @{}
$launched    = 0
$skipped     = @()

foreach ($server in $servers) {
    $launched++

    Write-Progress -Activity 'Checking connectivity and launching sessions' `
        -Status "$server  ($launched of $($servers.Count))" `
        -PercentComplete ([math]::Floor($launched / $servers.Count * 50))

    # Test port 445 (SMB) before spending a PSExec timeout slot
    $reachable = $false
    try {
        $tcpTest = New-Object System.Net.Sockets.TcpClient
        $connect = $tcpTest.BeginConnect($server, 445, $null, $null)
        $wait    = $connect.AsyncWaitHandle.WaitOne(2000, $false)
        if ($wait) {
            $tcpTest.EndConnect($connect)
            $reachable = $true
        }
        $tcpTest.Close()
    } catch {
        $reachable = $false
    }

    if (-not $reachable) {
        Write-Warning "$server — port 445 not reachable, skipping"
        $skipped += $server
        continue
    }

    # Wait for a throttle slot
    while (
        @($jobMap.Values | Where-Object { $_.State -eq 'Running' }).Count -ge $ThrottleLimit
    ) {
        Start-Sleep -Milliseconds 500
    }

    $remoteTempFile = "C:\Windows\Temp\PSExecAudit_$server.txt"
    $remoteScript   = $remoteScriptTemplate -replace 'PLACEHOLDER_TEMPFILE', $remoteTempFile
    $encodedBytes   = [System.Text.Encoding]::Unicode.GetBytes($remoteScript)
    $encodedCommand = [System.Convert]::ToBase64String($encodedBytes)

    $argList = [System.Collections.Generic.List[string]]@(
        "\\$server", '-accepteula', '-h', '-n', '30',
        'powershell.exe', '-NoProfile', '-NonInteractive',
        '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedCommand
    )

    if ($Credential) {
        $argList.Insert(1, '-u')
        $argList.Insert(2, $Credential.UserName)
        $argList.Insert(3, '-p')
        $argList.Insert(4, $Credential.GetNetworkCredential().Password)
    }

    $argArray        = $argList.ToArray()
    $jobMap[$server] = Start-Job -Name $server -ScriptBlock {
        param($exe, $argArray)
        & $exe @argArray 2>&1
    } -ArgumentList $PSExecPath, $argArray
}

Write-Output "Sessions launched: $($jobMap.Count)  |  Skipped (unreachable): $($skipped.Count)"
if ($jobMap.Count -gt 0) {
    $null = $jobMap.Values | Wait-Job -Timeout 300
}
$jobMap.Values | Remove-Job -Force

#endregion

#region --- Collect Results via UNC and Export ---

$results = New-Object System.Collections.Generic.List[PSCustomObject]
$idx     = 0

# Add skipped servers directly
foreach ($srv in $skipped) {
    $results.Add([PSCustomObject]@{
        Server  = $srv
        Type    = 'Warning'
        ObjectName = 'Server not reachable'
        Details = 'Port 445 (SMB) did not respond — server may be offline or firewalled'
        Account = 'UNKNOWN'
        UseSID     = ''
    })
}

foreach ($srv in $jobMap.Keys) {
    $idx++
    Write-Progress -Activity 'Reading results' `
        -Status "$srv  ($idx of $($jobMap.Count))" `
        -PercentComplete (50 + [math]::Floor($idx / [math]::Max($jobMap.Count, 1) * 50))

    $tempFileUNC = "\\$srv\C`$\Windows\Temp\PSExecAudit_$srv.txt"

    if (-not (Test-Path -Path $tempFileUNC)) {
        $results.Add([PSCustomObject]@{
            Server  = $srv
            Type    = 'Warning'
            ObjectName = 'No output file found'
            Details = 'PSExec may have failed or timed out'
            Account = 'UNKNOWN'
            UseSID     = ''
        })
        continue
    }

    $lines = Get-Content -Path $tempFileUNC -Encoding UTF8
    Remove-Item -Path $tempFileUNC -Force -ErrorAction SilentlyContinue

    $validLines = @($lines | Where-Object { $_ -and $_.StartsWith('##|') })
    if ($validLines.Count -eq 0) {
        $results.Add([PSCustomObject]@{
            Server  = $srv
            Type    = 'Clean'
            ObjectName = 'No custom accounts found'
            Details = 'Server was reached and returned no results'
            Account = 'N/A'
            UseSID     = ''
        })
        continue
    }


    foreach ($line in $validLines) {
        $parts = $line -split '\|', 6
        if ($parts.Count -lt 6) { continue }

        $typeLabel = switch ($parts[1]) {
            'SVC'  { 'Service'       }
            'TASK' { 'ScheduledTask' }
            'IIS'  { 'IISAppPool'    }
            'COM'  { 'COMPlusApp'    }
            'WARN' { 'Warning'       }
            default { $parts[1]     }
        }

        $results.Add([PSCustomObject]@{
            Server  = $srv
            Type    = $typeLabel
            ObjectName = $parts[2].Trim()
            Details = if ($parts[4].Trim() -like 'NT SERVICE\*') {
                        "$($parts[3].Trim()) [NT SERVICE virtual account — local to this server, no password]"
                    } else {
                        $parts[3].Trim()
                    }
            Account = $parts[4].Trim()
            UseSID     = if ($parts.Count -eq 6) { $parts[5].Trim() } else { '' }
        })
    }
}

Write-Progress -Activity 'Complete' -Completed

if ($results.Count -gt 0) {
    $results |
        Sort-Object -Property Server, Type, ObjectName |
        Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8

    Write-Output ''
    Write-Output "Results  : $($results.Count) entries"
    Write-Output "Servers  : $($servers.Count) total  |  $($jobMap.Count) scanned  |  $($skipped.Count) unreachable"
    Write-Output "CSV      : $OutputCsv"
} else {
    Write-Warning 'No results returned. Check that servers are reachable and PSExec has access.'
}

#endregion
