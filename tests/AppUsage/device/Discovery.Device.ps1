#Requires -Version 5.1
<#
.SYNOPSIS
    Task 13 device check: Get-AUUsers, Get-AUInstalledApps, and ConvertTo-AUInventoryApps on a real
    snapshot, run as SYSTEM, with one compact JSON line as the result.

.DESCRIPTION
    The device has no repo, so this loads the APPUSAGE region from the inventory script it's given
    (the whole script, or a file holding just the region). When the file also holds version 19's
    Get-InstalledApplications, the check compares the inventory with it. It checks:
      - every ProfileList user's ProfileState; a signed-out user is Copied and their per-user apps
        are listed, with RegPath under HKEY_USERS\<SID> and a ProfilePath
      - ScopeRead, ProfilesFound and ProfilesRead, and the MsiFileMap size
      - parity: the HKLM and signed-in-user part of the list equals version 19's read
      - Store packages only with -IncludeStore
      - a hive copy deleted by hand gives CopyFailed and Unread; a copy that isn't a hive gives
        CopyFailed when its load fails
      - afterwards: no AU_* key under HKEY_USERS (reg query HKU) and the run folder is gone
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

# Region functions log with Write-CMTraceLog; keep warnings and errors for the result. Version 19's
# Get-InstalledApplications passes -WarningMsg and -ErrorMsg.
$Log = New-Object System.Collections.Generic.List[string]
function Write-CMTraceLog
{
    param([string]$Message, [string]$Path, [string]$Component, [int]$Type = 1, [switch]$WarningMsg, [switch]$ErrorMsg)
    if ($Type -ge 2 -or $WarningMsg -or $ErrorMsg) { $Log.Add("[$Type] $Message") }
}
. ([scriptblock]::Create($Region.Groups[1].Value))
$Ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
$V19Read = $Ast.Find({ param ($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'Get-InstalledApplications' }, $true)
if ($V19Read) { . ([scriptblock]::Create($V19Read.Extent.Text)) }

function Get-AUMounts { @(& reg.exe query HKU 2>&1 | Where-Object { $_ -match '\\AU_' } | ForEach-Object { ([string]$_).Trim() }) }
function Get-Tail([string]$Sid) { if ($Sid -match '-(\d+)$') { $Matches[1] } else { $Sid } }
function Get-ScopeText($ScopeRead) { @($ScopeRead.Keys | Sort-Object | ForEach-Object { "$(Get-Tail $_)=$($ScopeRead[$_])" }) -join ',' }

$Out = [ordered]@{
    Computer = $env:COMPUTERNAME
    User     = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    Build    = [Environment]::OSVersion.Version.ToString()
    MountsBefore = (Get-AUMounts).Count
}
$WorkDir = $null
$Snapshot = $null
try
{
    $WorkDir = New-AUWorkDir -RunId "devcheck-$([guid]::NewGuid().ToString('N'))"
    $Snapshot = New-AUSnapshot -WorkDir $WorkDir
    $Out.Snapshot = "$($Snapshot.Status); $(@($Snapshot.HiveCopies.Values | Where-Object { $_ }).Count) of $($Snapshot.HiveCopies.Count) signed-out hives copied"

    $Users = @(Get-AUUsers -Snapshot $Snapshot)
    $Out.Users = @($Users | ForEach-Object { "$(Get-Tail $_.Sid):$($_.UserType):$($_.ProfileState)" })

    $Timer = [Diagnostics.Stopwatch]::StartNew()
    $Read = Get-AUInstalledApps -Users $Users -Snapshot $Snapshot
    $Out.DiscoveryMs = $Timer.ElapsedMilliseconds
    $Apps = @($Read.Apps)
    $Out.Discovery = [ordered]@{
        Apps          = $Apps.Count
        ByScope       = @($Apps | Group-Object Scope | ForEach-Object { "$(Get-Tail $_.Name)=$($_.Count)" })
        ScopeRead     = Get-ScopeText $Read.ScopeRead
        ProfilesFound = $Read.ProfilesFound
        ProfilesRead  = $Read.ProfilesRead
        MsiFileMap    = $Read.MsiFileMap.Count
        Uwp           = @($Apps | Where-Object AppType -eq 'UWP').Count
        BadRegPath    = @($Apps | Where-Object { $_.RegPath -match 'AU_' }).Count
        Arch          = @($Apps | Group-Object Architecture | ForEach-Object { "$($_.Name)=$($_.Count)" })
        MountsAfter   = (Get-AUMounts).Count
    }
    $Copied = @($Users | Where-Object { $_.ProfileState -eq 'Copied' })
    $Out.CopiedUsers = @(foreach ($User in $Copied)
        {
            $Mine = @($Apps | Where-Object Scope -eq $User.Sid)
            [ordered]@{
                Sid         = Get-Tail $User.Sid
                Read        = $Read.ScopeRead[$User.Sid]
                Apps        = $Mine.Count
                Names       = @($Mine | Select-Object -First 4 | ForEach-Object { [string]$_.DisplayName })
                RegPathOk   = @($Mine | Where-Object { $_.RegPath -like "HKEY_USERS\$($User.Sid)\*" }).Count
                ProfilePath = @($Mine | Where-Object { $_.ProfilePath -eq $User.ProfilePath }).Count
            }
        })

    $Inventory = @(ConvertTo-AUInventoryApps -Apps $Apps)
    $Out.Inventory = [ordered]@{ Entries = $Inventory.Count; Fields = (@($Inventory[0].PSObject.Properties.Name) -join ',') }
    if ($V19Read)
    {
        # Version 19 reads HKLM and the one signed-in user. Compare with the same part of the discovery.
        $SignedIn = @($Users | Where-Object { $_.ProfileState -eq 'Loaded' -and $_.UserType -in @('CloudOnly', 'Domain', 'Local') })
        $Sid = $null
        if ($SignedIn.Count -ge 1) { $Sid = $SignedIn[0].Sid }
        $V19Apps = Get-InstalledApplications -UserSid $Sid
        $V19Apps | ForEach-Object { $_ | Add-Member -NotePropertyName AppType -NotePropertyValue 'Win32' -Force }
        $Expected = @(ConvertTo-AUAppArray -Apps $V19Apps)
        $Same = @($Apps | Where-Object { $_.RegPath -like 'HKEY_LOCAL_MACHINE\*' -or ($Sid -and $_.Scope -eq $Sid) })
        $Actual = @(ConvertTo-AUInventoryApps -Apps $Same)
        $Out.Parity = [ordered]@{
            SignedIn = $(if ($Sid) { Get-Tail $Sid } else { 'none' })
            V19      = $Expected.Count
            Same     = (($Expected | ConvertTo-Json -Depth 3) -ceq ($Actual | ConvertTo-Json -Depth 3))
            Added    = @($Inventory | Where-Object { $_.AppName -notin @($Expected | ForEach-Object AppName) } | Select-Object -First 5 | ForEach-Object AppName)
            AddedCount = @($Inventory | Where-Object { $_.AppName -notin @($Expected | ForEach-Object AppName) }).Count
        }
    }

    # Store packages only with -IncludeStore (D46).
    $Timer.Restart()
    $WithStore = Get-AUInstalledApps -Users @(Get-AUUsers -Snapshot $Snapshot) -Snapshot $Snapshot -IncludeStore
    $StoreApps = @($WithStore.Apps | Where-Object AppType -eq 'UWP')
    $Out.Store = [ordered]@{
        Ms         = $Timer.ElapsedMilliseconds
        Entries    = $StoreApps.Count
        Packages   = @($StoreApps | ForEach-Object PackageFamily | Sort-Object -Unique).Count
        ScopeRead  = Get-ScopeText $WithStore.ScopeRead
        InInventory = @(ConvertTo-AUInventoryApps -Apps $WithStore.Apps | Where-Object AppType -eq 'UWP').Count
    }

    if ($Copied.Count -gt 0)
    {
        $Target = $Copied[0]
        $Copy = [string]$Snapshot.HiveCopies[$Target.Sid]
        # A copy that isn't a hive: reg load fails, so CopyFailed.
        $Saved = "$Copy.saved"
        [IO.File]::Move($Copy, $Saved)
        [IO.File]::WriteAllText($Copy, 'not a registry hive')
        $Users2 = @(Get-AUUsers -Snapshot $Snapshot)
        $Before = ($Users2 | Where-Object Sid -eq $Target.Sid).ProfileState
        $Read2 = Get-AUInstalledApps -Users $Users2 -Snapshot $Snapshot
        $Out.BadCopy = "$Before->$(($Users2 | Where-Object Sid -eq $Target.Sid).ProfileState); $($Read2.ScopeRead[$Target.Sid]); mounts $((Get-AUMounts).Count)"
        # The hive copy deleted by hand.
        [IO.File]::Delete($Copy)
        [IO.File]::Delete($Saved)
        foreach ($LogFile in @("$Copy.LOG1", "$Copy.LOG2")) { if ([IO.File]::Exists($LogFile)) { [IO.File]::Delete($LogFile) } }
        $Users3 = @(Get-AUUsers -Snapshot $Snapshot)
        $Read3 = Get-AUInstalledApps -Users $Users3 -Snapshot $Snapshot
        $Out.DeletedCopy = "$(($Users3 | Where-Object Sid -eq $Target.Sid).ProfileState); $($Read3.ScopeRead[$Target.Sid]); read $($Read3.ProfilesRead) of $($Read3.ProfilesFound)"
    }
}
catch { $Out.Error = "$($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)" }
finally
{
    if ($null -eq $Snapshot -and $WorkDir) { $Snapshot = [pscustomobject]@{ WorkDir = $WorkDir; ShadowId = $null } }
    Remove-AUSnapshot -Snapshot $Snapshot
}

$Out.After = [ordered]@{
    AUMounts      = Get-AUMounts
    RunFolderGone = -not ($WorkDir -and (Test-Path -LiteralPath $WorkDir))
    Shadows       = @(Get-CimInstance -ClassName Win32_ShadowCopy).Count
}
$Out.Log = @($Log | Select-Object -Last 6 | ForEach-Object { if ($_.Length -gt 160) { $_.Substring(0, 160) } else { $_ } })
$Out | ConvertTo-Json -Compress -Depth 5
