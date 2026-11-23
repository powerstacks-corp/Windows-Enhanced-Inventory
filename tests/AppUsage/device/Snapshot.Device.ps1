#Requires -Version 5.1
<#
.SYNOPSIS
    Task 12 device check: New-AUWorkDir, New-AUSnapshot, Read-AUSrum, and Remove-AUSnapshot, run as
    SYSTEM, with one compact JSON line as the result.

.DESCRIPTION
    The device has no repo, so this loads the APPUSAGE region from the inventory script it's given
    (the whole script, or a file holding just the region). It checks:
      - the work root and run folder ACLs while the run is in progress (owner, protection, entries)
      - the SRUM copy's ACL (inherited SYSTEM and Administrators entries only)
      - SRUM row counts, the epoch, Repaired and Complete, and that every date is Utc or null
      - afterwards: the run folder is gone, the shadow copy is gone, vssadmin lists no shadow copy,
        and no ESE files appeared in the working directory or the temp folder
    Test devices only: it takes and removes a shadow copy of the system drive.

.PARAMETER ScriptPath
    The inventory script, or a file holding its APPUSAGE region.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ScriptPath
)
$ErrorActionPreference = 'Stop'

$Text = [IO.File]::ReadAllText($ScriptPath, [Text.Encoding]::UTF8)
$Region = [regex]::Match($Text, '(?ms)^#region APPUSAGE\r?\n(.*?)^#endregion APPUSAGE')
if (-not $Region.Success) { throw "APPUSAGE region not found in $ScriptPath" }

# Region functions log with Write-CMTraceLog; keep warnings and errors for the result.
$Log = New-Object System.Collections.Generic.List[string]
function Write-CMTraceLog
{
    param([string]$Message, [string]$Component, [int]$Type = 1)
    if ($Type -ge 2) { $Log.Add("[$Type] $Message") }
}
. ([scriptblock]::Create($Region.Groups[1].Value))

function Get-AclSummary([string]$Path)
{
    $Acl = Get-Acl -LiteralPath $Path
    $Rules = @($Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object {
            '{0}:{1}:{2}:{3}' -f $_.IdentityReference.Value, $_.FileSystemRights, $_.AccessControlType, $(if ($_.IsInherited) { 'I' } else { 'E' })
        })
    $Sids = @($Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
    [ordered]@{
        Owner     = $Acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        Protected = $Acl.AreAccessRulesProtected
        OnlySysAdmins = (($Sids -join ',') -eq 'S-1-5-18,S-1-5-32-544')
        Rules     = $Rules
    }
}

function Get-EseLeftovers([string]$Folder)
{
    @(Get-ChildItem -LiteralPath $Folder -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '\.(edb|jfm|chk|jrs|log|RAW)$' -and $_.LastWriteTimeUtc -ge $Started } |
        ForEach-Object { $_.Name })
}

$Started = [DateTime]::UtcNow
$Out = [ordered]@{
    Computer = $env:COMPUTERNAME
    User     = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    Build    = [Environment]::OSVersion.Version.ToString()
}
$Cwd = (Get-Location).ProviderPath
$Temp = [IO.Path]::GetTempPath()
$Out.ShadowsBefore = @(Get-CimInstance -ClassName Win32_ShadowCopy).Count
$RunId = "devcheck-$([guid]::NewGuid().ToString('N'))"
$WorkDir = $null
$Snapshot = $null
$Stale = $null
$StaleShadowId = $null
try
{
    # A run killed 25 hours ago: its folder and a real shadow copy named in its marker. This run's
    # New-AUWorkDir must remove both.
    # The root's state before this check: it must be C:\Windows\PowerStacksAppUsage.
    $Out.RootExistedBefore = Test-Path -LiteralPath $script:AUWorkRoot
    $Stale = New-AUWorkDir -RunId "devcheck-stale-$([guid]::NewGuid().ToString('N'))"
    [IO.Directory]::SetCreationTimeUtc($Stale, [DateTime]::UtcNow.AddHours(-25))
    $Created = Invoke-CimMethod -ClassName Win32_ShadowCopy -MethodName Create -Arguments @{ Volume = "$($env:SystemDrive)\"; Context = 'ClientAccessible' }
    $StaleShadowId = [string]$Created.ShadowID
    Write-AUShadowMarker -Folder $Stale -ShadowId $StaleShadowId
    [IO.File]::WriteAllText((Join-Path $Stale 'SRUDB.dat'), 'left by a killed run')
    $Out.StaleShadowCreated = [bool]@(Get-CimInstance -ClassName Win32_ShadowCopy | Where-Object { $_.ID -eq $StaleShadowId }).Count

    $WorkDir = New-AUWorkDir -RunId $RunId
    $Out.StaleSweep = [ordered]@{
        FolderGone = -not (Test-Path -LiteralPath $Stale)
        ShadowGone = -not @(Get-CimInstance -ClassName Win32_ShadowCopy | Where-Object { $_.ID -eq $StaleShadowId }).Count
    }
    $Out.WorkDir = $WorkDir
    $Out.RootAcl = Get-AclSummary ([IO.Path]::GetDirectoryName($WorkDir))
    $Out.RunAcl = Get-AclSummary $WorkDir

    $Timer = [Diagnostics.Stopwatch]::StartNew()
    $Snapshot = New-AUSnapshot -WorkDir $WorkDir
    $Out.SnapshotMs = $Timer.ElapsedMilliseconds
    $Out.Snapshot = [ordered]@{
        Status           = $Snapshot.Status
        ShadowId         = $Snapshot.ShadowId
        ShadowRoot       = $Snapshot.ShadowRoot
        SrumDbPath       = $Snapshot.SrumDbPath
        MachineDomainSid = $Snapshot.MachineDomainSid
        SignedOutHives   = $Snapshot.HiveCopies.Count
        HivesCopied      = @($Snapshot.HiveCopies.Values | Where-Object { $_ }).Count
    }
    # New-AUSnapshot releases its shadow copy once the copies are made.
    $Out.ShadowsAfterSnapshot = @(Get-CimInstance -ClassName Win32_ShadowCopy).Count
    $Out.MarkerAfterSnapshot = Test-Path -LiteralPath (Join-Path $WorkDir 'shadow.id')
    if ($Snapshot.SrumDbPath) { $Out.SrumCopyAcl = Get-AclSummary $Snapshot.SrumDbPath }
    $Hive = @($Snapshot.HiveCopies.Values | Where-Object { $_ }) | Select-Object -First 1
    if ($Hive) { $Out.HiveCopyAcl = Get-AclSummary $Hive }

    $Timer.Restart()
    $Srum = Read-AUSrum -DbPath $Snapshot.SrumDbPath
    $Out.ReadMs = $Timer.ElapsedMilliseconds
    $Timeline = @($Srum.Timeline)
    $Ids = @($Timeline | Where-Object { $null -ne $_.AutoIncId } | ForEach-Object { [long]$_.AutoIncId } | Sort-Object)
    $Out.Srum = [ordered]@{
        Status        = $Srum.Status
        Epoch         = $Srum.Epoch
        Repaired      = $Srum.Repaired
        Complete      = $Srum.Complete
        TimelineRows  = $Timeline.Count
        ResourceRows  = @($Srum.Resource).Count
        NoExeInfo     = @($Timeline | Where-Object { -not $_.ExeInfo }).Count
        NoUserSid     = @($Timeline | Where-Object { -not $_.UserSid }).Count
        MinAutoIncId  = $(if ($Ids.Count) { $Ids[0] } else { $null })
        MaxAutoIncId  = $(if ($Ids.Count) { $Ids[-1] } else { $null })
        UniqueIds     = @($Ids | Select-Object -Unique).Count
        FocusRows     = @($Timeline | Where-Object { $_.FocusSeconds -gt 0 }).Count
        Users         = @($Timeline | ForEach-Object { $_.UserSid } | Where-Object { $_ } | Sort-Object -Unique).Count
        NullEndTime   = @($Timeline | Where-Object { $null -eq $_.EndTimeUtc }).Count
        NonUtcDates   = @($Timeline | Where-Object { $null -ne $_.EndTimeUtc -and $_.EndTimeUtc.Kind -ne 'Utc' }).Count + @($Srum.Resource | Where-Object { $null -ne $_.TimeStampUtc -and $_.TimeStampUtc.Kind -ne 'Utc' }).Count
        NewestEndUtc  = $(($Timeline | Where-Object { $_.EndTimeUtc } | Sort-Object EndTimeUtc | Select-Object -Last 1).EndTimeUtc.ToString('o'))
        KernelPaths   = @($Srum.Resource | Where-Object { $_.KernelPath -like '\Device\*' }).Count
    }
    $Out.WorkDirFiles = @(Get-ChildItem -LiteralPath $WorkDir -Recurse -Force -File | ForEach-Object { $_.FullName.Substring($WorkDir.Length + 1) })
}
catch { $Out.Error = $_.Exception.Message }
finally
{
    if ($null -eq $Snapshot -and $WorkDir) { $Snapshot = [pscustomobject]@{ WorkDir = $WorkDir; ShadowId = $null } }
    Remove-AUSnapshot -Snapshot $Snapshot
    # If the sweep didn't remove the planted stale run, remove it here so the check leaves nothing.
    if ($Stale -and (Test-Path -LiteralPath $Stale)) { Remove-AUSnapshot -Snapshot ([pscustomobject]@{ WorkDir = $Stale; ShadowId = $StaleShadowId }) }
    elseif ($StaleShadowId) { [void](Remove-AUShadowCopy -ShadowId $StaleShadowId) }
}

$Out.After = [ordered]@{
    RunFolderGone      = -not ($WorkDir -and (Test-Path -LiteralPath $WorkDir))
    RootChildren       = @(Get-ChildItem -LiteralPath $script:AUWorkRoot -Force -ErrorAction SilentlyContinue).Count
    ShadowStillThere   = [bool]($Snapshot.ShadowId -and @(Get-CimInstance -ClassName Win32_ShadowCopy | Where-Object { $_.ID -eq $Snapshot.ShadowId }).Count)
    ShadowsAfter       = @(Get-CimInstance -ClassName Win32_ShadowCopy).Count
    VssadminShadowIds  = @(& vssadmin.exe list shadows 2>&1 | Select-String -Pattern 'Shadow Copy ID').Count
    VssadminNoItems    = [bool](& vssadmin.exe list shadows 2>&1 | Select-String -Pattern 'No items found')
    EseFilesInCwd      = Get-EseLeftovers $Cwd
    EseFilesInTemp     = Get-EseLeftovers $Temp
}
$Out.Log = @($Log | Select-Object -Last 8)
$Out | ConvertTo-Json -Compress -Depth 5
