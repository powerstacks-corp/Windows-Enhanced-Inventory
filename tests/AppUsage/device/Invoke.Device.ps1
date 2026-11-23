#Requires -Version 5.1
<#
.SYNOPSIS
    Task 15a device check: Invoke-AppUsage end to end, run as SYSTEM, with one compact JSON line as the result.

.DESCRIPTION
    The device has no repo, so this loads the APPUSAGE region from the inventory script it's given
    (the whole script, or a file holding just the region), and embeds the PowerStacks mappings file it's
    given the way the build does (Base64 of GZip-compressed JSON, F43). It runs Invoke-AppUsage twice
    (the second run reads the ledger the first wrote) and reports, for each run: the status, the
    tokens, the counts (inventory apps, executable entries, matched and unmatched), the stage timings,
    and whether anything reached any output stream other than the one result (D40). Afterwards it
    checks the ledger (exists, entry count, owner, protected DACL, SYSTEM and Administrators only),
    that the run folders and shadow copies are gone, and that no AU_ hive mount is left.
    Test devices only: it takes and removes a shadow copy, and writes C:\Windows\AppUsage_<Serial>.json.

.PARAMETER ScriptPath
    The inventory script, or a file holding its APPUSAGE region.

.PARAMETER MappingsPath
    The PowerStacks mappings file (powerstacks-mappings.json) to embed.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ScriptPath,
    [Parameter(Mandatory)][string]$MappingsPath
)
$ErrorActionPreference = 'Stop'

$Text = [IO.File]::ReadAllText($ScriptPath, [Text.Encoding]::UTF8)
$Region = [regex]::Match($Text, '(?ms)^#region APPUSAGE\r?\n(.*?)^#endregion APPUSAGE')
if (-not $Region.Success) { throw "APPUSAGE region not found in $ScriptPath" }

# Region functions log with Write-CMTraceLog; keep warnings and errors, and the stage times.
$Log = New-Object System.Collections.Generic.List[string]
function Write-CMTraceLog
{
    param([string]$Message, [string]$Component, [int]$Type = 1)
    if ($Type -ge 2) { $Log.Add("[$Type] $Message") }
}
. ([scriptblock]::Create($Region.Groups[1].Value))

# Embed our rules as the build does.
$Bytes = [IO.File]::ReadAllBytes($MappingsPath)
$Buffer = New-Object IO.MemoryStream
$Zip = New-Object IO.Compression.GZipStream($Buffer, [IO.Compression.CompressionMode]::Compress)
$Zip.Write($Bytes, 0, $Bytes.Length)
$Zip.Dispose()
$script:AppUsageMappingsEmbedded = [Convert]::ToBase64String($Buffer.ToArray())

# The inventory's settings, at their defaults.
$CollectUWPInventory = $false
$MinFocusSecondsForUse = 1
$AppUsageCustomerMappingsPath = 'C:\ProgramData\PowerStacks\AppUsage\customer-mappings.json'
$ScriptVersion = '20 - device check'

function Get-AclSummary([string]$Path)
{
    $Acl = Get-Acl -LiteralPath $Path
    $Sids = @($Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
    [ordered]@{
        Owner         = $Acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        Protected     = $Acl.AreAccessRulesProtected
        OnlySysAdmins = (($Sids -join ',') -eq 'S-1-5-18,S-1-5-32-544')
    }
}

function Get-RunSummary($All)
{
    $Objects = @($All)
    $Result = $Objects | Where-Object { $_ -is [pscustomobject] -and $null -ne $_.PSObject.Properties['DeviceColumns'] } | Select-Object -First 1
    $Exes = @($Result.ExeEntries)
    $Statuses = @{}
    if ($null -ne $Result.AppFields)
    {
        foreach ($Value in $Result.AppFields.Values)
        {
            $Name = if ($null -eq $Value -or $null -eq $Value.AppUsageStatus) { 'Blank' } else { [string]$Value.AppUsageStatus }
            $Statuses[$Name] = 1 + [int]$Statuses[$Name]
        }
    }
    $Install = @{}
    foreach ($Exe in $Exes) { $Install[[string]$Exe.InstallStatus] = 1 + [int]$Install[[string]$Exe.InstallStatus] }
    $Roles = @{}
    foreach ($Exe in $Exes) { $Roles[[string]$Exe.Role] = 1 + [int]$Roles[[string]$Exe.Role] }
    [ordered]@{
        Outputs        = $Objects.Count
        Status         = $Result.Status
        InventoryApps  = $(if ($null -eq $Result.InventoryApps) { $null } else { @($Result.InventoryApps).Count })
        ExeEntries     = $Exes.Count
        Matched        = @($Exes | Where-Object { $_.MatchSection -ne 'None' }).Count
        Unmatched      = $Result.UnmatchedExeCount
        Verified       = @($Exes | Where-Object { $_.FactsVerified -eq $true }).Count
        UsageStatus    = $Statuses
        InstallStatus  = $Install
        Roles          = $Roles
        Profiles       = "$($Result.ProfilesRead)/$($Result.ProfilesFound)"
        WatchingSince  = $Result.DeviceColumns['WatchingSince_t']
        Mappings       = $Result.DeviceColumns['MappingsVersion_s']
        Timings        = $Result.Timings
        LedgerPath     = $Result.LedgerPath
    }
}

$Out = [ordered]@{
    Computer = $env:COMPUTERNAME
    User     = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    Build    = [Environment]::OSVersion.Version.ToString()
}
$Out.ShadowsBefore = @(Get-CimInstance -ClassName Win32_ShadowCopy).Count
$Ledger = Get-AULedgerPath -Serial (Get-AUSerial) -ComputerName $env:COMPUTERNAME
$Out.LedgerExistedBefore = [IO.File]::Exists($Ledger)
try
{
    $Out.Run1 = Get-RunSummary (Invoke-AppUsage -RunId ([guid]::NewGuid().ToString()) *>&1)
    $Out.Run2 = Get-RunSummary (Invoke-AppUsage -RunId ([guid]::NewGuid().ToString()) *>&1)
}
catch { $Out.Error = "$($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)" }

$Out.LedgerExists = [IO.File]::Exists($Ledger)
if ($Out.LedgerExists)
{
    $Out.LedgerBytes = (Get-Item -LiteralPath $Ledger).Length
    $Out.LedgerEntries = (Read-AULedger -Path $Ledger).Entries.Count
    $Out.LedgerAcl = Get-AclSummary $Ledger
}
$Out.WorkRootChildren = @(Get-ChildItem -LiteralPath $script:AUWorkRoot -Force -ErrorAction SilentlyContinue).Count
$Out.ShadowsAfter = @(Get-CimInstance -ClassName Win32_ShadowCopy).Count
$Out.MountsLeft = @([Microsoft.Win32.Registry]::Users.GetSubKeyNames() | Where-Object { $_ -like 'AU_*' }).Count
$Out.Warnings = $Log.Count
$Out.FirstWarnings = @($Log | Select-Object -First 6 | ForEach-Object { if ($_.Length -gt 160) { $_.Substring(0, 160) } else { $_ } })
$Out | ConvertTo-Json -Depth 5 -Compress
