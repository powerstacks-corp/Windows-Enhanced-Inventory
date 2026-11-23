#Requires -Version 5.1
<#
.SYNOPSIS
    Task 14 device check: kernel path translation, fingerprint verification, and executable facts
    against a real SRUM read, run as SYSTEM, with one compact JSON line as the result.

.DESCRIPTION
    The device has no repo, so this loads the APPUSAGE region from the inventory script it's given
    (the whole script, or a file holding just the region). It takes a SRUM copy (New-AUWorkDir,
    New-AUSnapshot, Read-AUSrum, Remove-AUSnapshot), then reports:
      - Probe: each distinct Resource kernel path under \Device\HarddiskVolumeN\ probed by existence
        under every fixed drive, the way Task 0.4 counted it (translated, ambiguous, not found)
      - Verify: of the translated paths whose exe has a Win32 fingerprint in the timeline, how many
        Resolve-AUKernelPath verifies, and the volume-to-drive map it cached
      - Entries: Find-AUExePath for every user and Win32 build in the timeline (found, none, no
        candidate), and Get-AUExeFacts for the found ones (verified, subsystem, Installer owner,
        service binary)
      - SecondVolume: E:\probe\ProbeOnE.exe through its SRUM rows (if any) and through a kernel
        path built from its own fingerprint
      - Services: Get-AUServiceBinaries counts, and facts for a few service executables
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

function Get-Short([string]$Value, [int]$Max = 90)
{
    if ($null -eq $Value -or $Value.Length -le $Max) { return $Value }
    return '...' + $Value.Substring($Value.Length - $Max + 3)
}

$Out = [ordered]@{
    Computer = $env:COMPUTERNAME
    User     = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    Build    = [Environment]::OSVersion.Version.ToString()
    Drives   = (Get-AUFixedDrives) -join ','
}
$RunId = "devcheck-$([guid]::NewGuid().ToString('N'))"
$WorkDir = $null
$Snapshot = $null
$Srum = $null
try
{
    $WorkDir = New-AUWorkDir -RunId $RunId
    $Snapshot = New-AUSnapshot -WorkDir $WorkDir
    $Srum = Read-AUSrum -DbPath $Snapshot.SrumDbPath
    $Out.Srum = [ordered]@{ Snapshot = $Snapshot.Status; Status = $Srum.Status; Timeline = @($Srum.Timeline).Count; Resource = @($Srum.Resource).Count }
}
catch { $Out.Error = $_.Exception.Message }
finally
{
    if ($null -eq $Snapshot -and $WorkDir) { $Snapshot = [pscustomobject]@{ WorkDir = $WorkDir; ShadowId = $null } }
    if ($null -ne $Snapshot) { Remove-AUSnapshot -Snapshot $Snapshot }
    $Out.RunFolderGone = -not ($WorkDir -and (Test-Path -LiteralPath $WorkDir))
}

try
{
    $Timer = [Diagnostics.Stopwatch]::StartNew()
    $Resource = @($Srum.Resource)
    $Timeline = @($Srum.Timeline)
    $Drives = @(Get-AUFixedDrives)

    # Win32 fingerprints in the timeline, by exe name.
    $InfoByExe = @{}
    $Entries = @{}
    foreach ($Row in $Timeline)
    {
        $Info = ConvertFrom-AUExeInfo ([string]$Row.ExeInfo)
        if ($Info.Kind -ne 'Win32' -or $null -eq $Info.LinkTimeUtc -or $null -eq $Info.CheckSum) { continue }
        if (-not $InfoByExe.ContainsKey($Info.ExeName)) { $InfoByExe[$Info.ExeName] = @{} }
        $InfoByExe[$Info.ExeName][[string]$Row.ExeInfo] = $Info
        $Entries["$($Row.UserSid)|$($Row.ExeInfo)"] = [pscustomobject]@{ UserSid = [string]$Row.UserSid; Text = [string]$Row.ExeInfo; Info = $Info }
    }

    # Task 0.4's count: existence under each fixed drive.
    $Kernels = @($Resource | ForEach-Object { [string]$_.KernelPath } | Where-Object { $_ -match '^\\Device\\HarddiskVolume\d+\\.+\.exe$' } | Sort-Object -Unique)
    $Probe = [ordered]@{ Paths = $Kernels.Count; Translated = 0; Ambiguous = 0; NotFound = 0 }
    $Verify = [ordered]@{ WithFingerprint = 0; Verified = 0; Mismatch = 0 }
    $Cache = @{}
    $NotFound = New-Object System.Collections.Generic.List[string]
    $Mismatch = New-Object System.Collections.Generic.List[string]
    foreach ($Kernel in $Kernels)
    {
        $Rest = $Kernel -replace '^\\Device\\HarddiskVolume\d+\\', ''
        $Hits = @($Drives | Where-Object { [IO.File]::Exists("$_\$Rest") })
        if ($Hits.Count -eq 0) { $Probe.NotFound++; if ($NotFound.Count -lt 4) { $NotFound.Add((Get-Short $Kernel 70)) }; continue }
        if ($Hits.Count -gt 1) { $Probe.Ambiguous++; continue }
        $Probe.Translated++
        $Exe = $Rest.Substring($Rest.LastIndexOf('\') + 1).ToLowerInvariant()
        if (-not $InfoByExe.ContainsKey($Exe)) { continue }
        $Verify.WithFingerprint++
        $Path = $null
        foreach ($Info in $InfoByExe[$Exe].Values) { $Path = Resolve-AUKernelPath $Kernel $Info $Cache; if ($Path) { break } }
        if ($Path) { $Verify.Verified++ } else { $Verify.Mismatch++; if ($Mismatch.Count -lt 4) { $Mismatch.Add((Get-Short $Kernel 70)) } }
    }
    $Out.Probe = $Probe
    $Out.Verify = $Verify
    $Out.VolumeCache = @($Cache.Keys | Sort-Object | ForEach-Object { "$_=$($Cache[$_])" }) -join ','
    $Out.NotFoundSamples = $NotFound.ToArray()
    $Out.MismatchSamples = $Mismatch.ToArray()

    # Entry-level: Find-AUExePath and Get-AUExeFacts, as Task 15 will run them.
    $ByUserExe = @{}
    foreach ($Row in $Resource) { $Key = "$($Row.UserSid)|$($Row.ExeName)"; if (-not $ByUserExe.ContainsKey($Key)) { $ByUserExe[$Key] = New-Object System.Collections.Generic.List[string] }; $ByUserExe[$Key].Add([string]$Row.KernelPath) }
    $Services = Get-AUServiceBinaries
    $Msi = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
    $Base = Open-AURegistryBase -Hive Machine
    try { [void](Read-AUMsiFileMap -Base $Base -Into $Msi) } finally { $Base.Close() }
    $EntryStats = [ordered]@{ Entries = $Entries.Count; Found = 0; None = 0; NoCandidate = 0; MultiCandidateFound = 0; Verified = 0; GUI = 0; Console = 0; OtherSubsystem = 0; MsiOwned = 0; ServiceBinary = 0; WithCompany = 0 }
    $Samples = New-Object System.Collections.Generic.List[string]
    $ServiceFound = New-Object System.Collections.Generic.List[string]
    $EntryCache = @{}
    foreach ($Entry in $Entries.Values)
    {
        $Candidates = $ByUserExe["$($Entry.UserSid)|$($Entry.Info.ExeName)"]
        if ($null -eq $Candidates) { $EntryStats.NoCandidate++; continue }
        $Path = Find-AUExePath $Candidates.ToArray() $Entry.Info $EntryCache
        if (-not $Path) { $EntryStats.None++; continue }
        $EntryStats.Found++
        if (@($Candidates | Sort-Object -Unique).Count -gt 1) { $EntryStats.MultiCandidateFound++ }
        $Facts = Get-AUExeFacts $Path $Entry.Info $Msi $Services $Entry.UserSid -ExeInfoText $Entry.Text
        if ($Facts.FactsVerified) { $EntryStats.Verified++ }
        switch ($Facts.Subsystem) { 'GUI' { $EntryStats.GUI++ } 'Console' { $EntryStats.Console++ } 'Other' { $EntryStats.OtherSubsystem++ } }
        if ($Facts.MsiProductCode) { $EntryStats.MsiOwned++ }
        if ($Facts.FileCompanyName) { $EntryStats.WithCompany++ }
        if ($Facts.IsServiceBinary) { $EntryStats.ServiceBinary++; if ($ServiceFound.Count -lt 4) { $ServiceFound.Add("$($Facts.RunPath) ($($Services[$Facts.RunPath.ToLowerInvariant()]))") } }
        if ($Samples.Count -lt 3 -and $Facts.RunPath -notmatch '\\Windows\\') { $Samples.Add(('{0} | {1} | {2} | {3} | {4}' -f (Get-Short $Facts.RunPath 60), $Facts.FileCompanyName, $Facts.FileVersion, $Facts.Subsystem, $Facts.LocationClass)) }
    }
    $Out.Entries = $EntryStats
    $Out.FactSamples = $Samples.ToArray()
    $Out.ServiceBinariesInSrum = $ServiceFound.ToArray()

    # The second volume.
    $ProbeFile = 'E:\probe\ProbeOnE.exe'
    $Second = [ordered]@{ FileExists = [IO.File]::Exists($ProbeFile) }
    $SrumRows = @($Resource | Where-Object { $_.KernelPath -like '*\probe\ProbeOnE.exe' })
    $Second.SrumKernelPaths = @($SrumRows | ForEach-Object { $_.KernelPath } | Sort-Object -Unique)
    if ($InfoByExe.ContainsKey('probeone.exe') -and $SrumRows.Count)
    {
        $Second.SrumResolved = @(foreach ($Info in $InfoByExe['probeone.exe'].Values) { Find-AUExePath ([string[]]@($SrumRows | ForEach-Object { $_.KernelPath })) $Info $Cache }) | Where-Object { $_ } | Select-Object -First 1
    }
    if ($Second.FileExists)
    {
        $Own = Get-AUPeFingerprint $ProbeFile
        $OwnInfo = ConvertFrom-AUExeInfo ('!!probeone.exe!{0}!{1}!' -f $Own.LinkTimeUtc.ToString('yyyy/MM/dd:HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture), $Own.CheckSum.ToString('x'))
        $FreshCache = @{}
        $Second.OwnFingerprintResolved = Resolve-AUKernelPath '\Device\HarddiskVolume99\probe\ProbeOnE.exe' $OwnInfo $FreshCache
        $Second.FreshCache = @($FreshCache.Keys | ForEach-Object { "$_=$($FreshCache[$_])" }) -join ','
        $Second.WrongBuildResolved = Resolve-AUKernelPath '\Device\HarddiskVolume98\probe\ProbeOnE.exe' (ConvertFrom-AUExeInfo '!!probeone.exe!2001/01/01:00:00:00!1!') @{}
        $ProbeFacts = Get-AUExeFacts $ProbeFile $OwnInfo $Msi $Services 'S-1-5-18'
        $Second.Facts = '{0} | {1} | {2}' -f $ProbeFacts.FactsVerified, $ProbeFacts.Subsystem, $ProbeFacts.LocationClass
    }
    $Out.SecondVolume = $Second

    # Service binaries.
    $Keys = @($Services.Keys)
    $ServiceExes = @($Keys | Where-Object { $_ -like '*.exe' -and $_ -notlike '*\svchost.exe' } | Sort-Object)
    $ServiceSamples = New-Object System.Collections.Generic.List[string]
    foreach ($Exe in $ServiceExes)
    {
        if ($ServiceSamples.Count -ge 4) { break }
        $Fp = Get-AUPeFingerprint $Exe
        if ($null -eq $Fp) { continue }
        $Name = [IO.Path]::GetFileName($Exe)
        $Info = ConvertFrom-AUExeInfo ('!!{0}!{1}!{2}!' -f $Name, $Fp.LinkTimeUtc.ToString('yyyy/MM/dd:HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture), $Fp.CheckSum.ToString('x'))
        $F = Get-AUExeFacts $Exe $Info $Msi $Services 'S-1-5-18'
        $ServiceSamples.Add(('{0} ({1}) svc={2} ver={3} {4}' -f (Get-Short $Exe 55), $Services[$Exe], $F.IsServiceBinary, $F.FactsVerified, $F.Subsystem))
    }
    $Out.Services = [ordered]@{
        Mapped     = $Services.Count
        Exe        = $ServiceExes.Count
        HostedDll  = @($Keys | Where-Object { $_ -like '*.dll' }).Count
        Samples    = $ServiceSamples.ToArray()
    }
    $Out.MsiFiles = $Msi.Count
    $Out.AnalysisMs = $Timer.ElapsedMilliseconds
}
catch { $Out.AnalysisError = "$($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)" }

$Out.Log = @($Log | Select-Object -Last 4 | ForEach-Object { Get-Short $_ 140 })
$Out | ConvertTo-Json -Compress -Depth 5
