<#
.SYNOPSIS
    Times App Usage's compute stages at a synthetic scale: 3,000 ledger entries and 300 installed apps by default.
.DESCRIPTION
    Not a Pester test. It loads only the APPUSAGE region of the inventory script (as the tests do),
    builds synthetic installed apps, SRUM rows, and verified facts (no device data, no file reads, no
    registry, no shadow copy), and runs the stages Invoke-AUCollection runs on them: the merge, the
    per-entry recalculation (Facts), the aggregation, and the ledger write and read, then the run-row
    build. It prints each stage's time, the total, and a SHA-256 of the results (every entry's target,
    role, and install status, and every app's usage fields), so two versions of the script can be
    compared for identical results as well as for speed.
    Most apps are Contoso App NNN (publisher Contoso N); about a third have a ProductCode, every tenth is
    a per-user install, and each names its first executable in DisplayIcon. Half the executables describe
    themselves as the installed app (arpCompare matches), the rest as a Fabrikam Tool that isn't
    installed. The first four apps are Microsoft 365 Apps, Visual Studio Code, OneDrive, and Adobe
    Creative Cloud, with the executable names the shipping identity rules use, so wildcard targets are
    covered too.
.PARAMETER ScriptPath
    The inventory script (source or release build). Default: the repository's source script.
.PARAMETER MappingsPath
    The PowerStacks mappings file, used when the script has none embedded. Default: the repository's
    powerstacks-mappings.json.
.PARAMETER AppCount
    Installed apps. Default 300.
.PARAMETER ExesPerApp
    Executables (ledger entries) per app. Default 10.
.PARAMETER RowsPerEntry
    SRUM rows per executable. Default 10.
.PARAMETER ProfileFacts
    Also times the per-entry functions (Resolve-AUIdentity, Resolve-AUTarget, Get-AUClassification,
    Get-AURole, Get-AUInstallStatus) in a second pass.
.EXAMPLE
    powershell.exe -NoProfile -File tests\AppUsage\perf\Measure-AUScale.ps1
#>
param (
    [string]$ScriptPath = (Join-Path $PSScriptRoot '..\..\..\Intune_Windows_Inventory.ps1'),
    [string]$MappingsPath = (Join-Path $PSScriptRoot '..\..\..\powerstacks-mappings.json'),
    [int]$AppCount = 300,
    [int]$ExesPerApp = 10,
    [int]$RowsPerEntry = 10,
    [switch]$ProfileFacts
)

$ErrorActionPreference = 'Stop'
$Text = [IO.File]::ReadAllText((Resolve-Path $ScriptPath).Path, [Text.Encoding]::UTF8)
$Region = [regex]::Match($Text, '(?ms)^#region APPUSAGE\r?\n(.*?)^#endregion APPUSAGE')
if (-not $Region.Success) { throw "APPUSAGE region not found in $ScriptPath" }
function Write-CMTraceLog { param($Message, $Component, $Type) }
. ([scriptblock]::Create($Region.Groups[1].Value))

$Work = Join-Path ([IO.Path]::GetTempPath()) ('au-scale-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Work | Out-Null
try
{
    Copy-Item -LiteralPath (Resolve-Path $MappingsPath).Path -Destination (Join-Path $Work 'powerstacks-mappings.json')
    $Times = [ordered]@{}
    $Clock = New-Object Diagnostics.Stopwatch
    $Time = {
        param ([string]$Name, [scriptblock]$Body)
        $Clock.Restart()
        $Out = & $Body
        $Times[$Name] = $Clock.ElapsedMilliseconds
        return $Out
    }

    $Map = & $Time 'Mappings' { Get-AUMappings -Embedded $script:AppUsageMappingsEmbedded -BesideDir $Work -CustomerPath (Join-Path $Work 'customer-mappings.json') }
    if (@($Map.Errors).Count -gt 0 -or $Map.Source -eq 'None') { throw "Mappings didn't load: $(@($Map.Errors) -join '; ')" }

    $DomainSid = 'S-1-5-21-1000000000-2000000000-3000000000'
    $Users = @('S-1-12-1-1111111111-2222222222-3333333333-4444444444', "$DomainSid-1001", "$DomainSid-1002")
    $Named = @(
        @{ Name = 'Microsoft 365 Apps for enterprise - en-us'; Publisher = 'Microsoft Corporation'; Exes = @('WINWORD.EXE', 'EXCEL.EXE', 'POWERPNT.EXE', 'OUTLOOK.EXE', 'ONENOTE.EXE', 'MSACCESS.EXE') }
        @{ Name = 'Microsoft Visual Studio Code (User)'; Publisher = 'Microsoft Corporation'; Exes = @('Code.exe') }
        @{ Name = 'Microsoft OneDrive'; Publisher = 'Microsoft Corporation'; Exes = @('OneDrive.Sync.Service.exe') }
        @{ Name = 'Adobe Creative Cloud'; Publisher = 'Adobe Inc.'; Exes = @('Creative Cloud.exe', 'Creative Cloud Helper.exe', 'CoreSync.exe') }
    )
    $Apps = New-Object 'System.Collections.Generic.List[object]'
    $ExeNames = @{}
    for ($a = 1; $a -le $AppCount; $a++)
    {
        $Folder = 'C:\Program Files\Contoso\App{0:D3}' -f $a
        $Name = 'Contoso App {0:D3}' -f $a
        $Publisher = 'Contoso {0}' -f ($a % 25)
        $Exes = @(for ($k = 1; $k -le $ExesPerApp; $k++) { 'app{0:D3}_{1}.exe' -f $a, $k })
        if ($a -le $Named.Count)
        {
            $Name = $Named[$a - 1].Name
            $Publisher = $Named[$a - 1].Publisher
            for ($k = 0; $k -lt $Named[$a - 1].Exes.Count -and $k -lt $Exes.Count; $k++) { $Exes[$k] = $Named[$a - 1].Exes[$k] }
        }
        $ExeNames[$a] = $Exes
        $Scope = 'Machine'
        $ProfilePath = $null
        if ($a % 10 -eq 0)
        {
            $Scope = $Users[$a % $Users.Count]
            $ProfilePath = 'C:\Users\user{0}' -f ($a % $Users.Count)
        }
        $Code = $null
        if ($a % 3 -eq 0) { $Code = '{' + ('{0:D8}-0000-0000-0000-{1:D12}' -f $a, $a) + '}' }
        $Apps.Add([pscustomobject][ordered]@{
                DisplayName     = $Name
                Publisher       = $Publisher
                DisplayVersion  = "1.$a"
                ProductCode     = $Code
                PackageFamily   = $null
                InstallLocation = $Folder
                DisplayIcon     = "$Folder\$($Exes[0]),0"
                UninstallString = "`"$Folder\uninstall.exe`""
                Architecture    = 'x64'
                Scope           = $Scope
                ProfilePath     = $ProfilePath
                AppType         = 'Win32'
                RegPath         = "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\App$a"
                InstallDate     = $null
            })
    }

    $Rows = New-Object 'System.Collections.Generic.List[object]'
    $Id = 100000
    $Start = [datetime]::SpecifyKind([datetime]'2026-11-15T00:00:00', 'Utc')
    $Infos = @{}
    for ($a = 1; $a -le $AppCount; $a++)
    {
        for ($k = 1; $k -le $ExesPerApp; $k++)
        {
            $Exe = $ExeNames[$a][$k - 1]
            $Info = "!!$($Exe.ToLowerInvariant())!2026/10/01:00:00:00!$('{0:x}' -f (0x1a000 + $a * 16 + $k))!"
            $Sid = $Users[($a + $k) % $Users.Count]
            $Infos["$Sid|$Info"] = @($a, $k, $Exe)
            for ($r = 0; $r -lt $RowsPerEntry; $r++)
            {
                $Id++
                $Rows.Add([pscustomobject]@{ AutoIncId = $Id; EndTimeUtc = $Start.AddHours($r * 7 + $k); ExeInfo = $Info; FocusSeconds = [double](30 * ($r % 3)); InputSeconds = [double](10 * ($r % 2)); UserSid = $Sid })
            }
        }
    }
    $UserTypes = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
    foreach ($User in $Users) { $UserTypes[$User] = Get-AUUserType -Sid $User -MachineDomainSid $DomainSid }

    $Ledger = New-AULedger
    $Ledger.WatchingSince = $Start
    & $Time 'Merge' { Merge-AUSrumRecords -Ledger $Ledger -Rows $Rows.ToArray() -Epoch 'Create time:11/01/2026 00:00:00.000 Rand:1 Computer:' -UserTypes $UserTypes -MinFocusSeconds 1 -LowestAutoIncId 100001 } | Out-Null

    # Verified facts already stored, as on a device after its first run, so nothing reads a file.
    foreach ($Key in @($Ledger.Entries.Keys))
    {
        $Entry = $Ledger.Entries[$Key]
        $a, $k, $Exe = $Infos[$Key]
        $App = $Apps[$a - 1]
        $Description = 'Fabrikam Tool {0:D3}' -f $a
        if ($a % 2 -eq 0 -or $a -le $Named.Count) { $Description = $App.DisplayName }
        $Entry.Facts = [pscustomobject][ordered]@{
            ExeName = $Exe; RunPath = "$($App.InstallLocation)\$Exe"; LocationClass = 'ProgramFiles'; FileDescription = $Description; FileProductName = $Description
            FileCompanyName = $App.Publisher; FileVersion = "1.$a"; ProductVersion = "1.$a"; FactsVerified = $true; Subsystem = 'GUI'; MsiProductCode = $null
            PackageFamily = $null; IsServiceBinary = $false; UserSid = $Entry.UserSid; PathEvidence = $null
        }
        $Entry.FactsVerified = $true
    }

    $ScopeRead = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
    $ScopeRead['Machine'] = 'Read'
    foreach ($User in $Users) { $ScopeRead[$User] = 'Read' }
    $NewTable = { New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase) }
    $Context = [pscustomobject]@{
        Mappings = $Map; CustomerRulesUnavailable = $false; Apps = $Apps.ToArray(); AppIndex = $null; ScopeRead = $ScopeRead; MsiFileMap = (& $NewTable)
        ServiceBinaries = (& $NewTable); ResourcePaths = (& $NewTable); VolumeCache = (& $NewTable); ReadBudget = (New-AUReadBudget)
        UserTypes = $UserTypes; MachineDomainSid = $DomainSid
    }
    $Keys = [string[]]@($Ledger.Entries.Keys)
    [Array]::Sort($Keys, [StringComparer]::Ordinal)
    $Entries = New-Object 'System.Collections.Generic.List[object]'
    # As Invoke-AUCollection does, in the Facts stage: the installed-app index, once per run.
    & $Time 'Facts' { $Context.AppIndex = New-AUAppIndex $Context.Apps; foreach ($Key in $Keys) { $Entry = $Ledger.Entries[$Key]; Set-AUEntryResult -Entry $Entry -Context $Context; $Entries.Add($Entry) } } | Out-Null
    $All = $Entries.ToArray()

    $Profile = $null
    if ($ProfileFacts)
    {
        $Profile = [ordered]@{ Identity = [long]0; Target = [long]0; Classification = [long]0; Role = [long]0; InstallStatus = [long]0 }
        foreach ($Entry in $All)
        {
            $Clock.Restart(); $Identity = Resolve-AUIdentity -Facts $Entry.Facts -Mappings $Map -InstalledApps $Context.Apps -AppIndex $Context.AppIndex; $Profile.Identity += $Clock.ElapsedTicks
            $Clock.Restart(); $Target = Resolve-AUTarget -Identity $Identity -StoredTarget $Entry.StoredTarget -Mappings $Map -CustomerRulesUnavailable:$false; $Profile.Target += $Clock.ElapsedTicks
            $Clock.Restart(); $Class = Get-AUClassification -Facts $Entry.Facts -Mappings $Map -MatchSection ([string]$Target.MatchSection); $Profile.Classification += $Clock.ElapsedTicks
            $Clock.Restart(); $null = Get-AURole -Facts $Entry.Facts -Target $Target -Classification $Class -InstalledApps $Context.Apps -AppIndex $Context.AppIndex; $Profile.Role += $Clock.ElapsedTicks
            $Clock.Restart(); $null = Get-AUInstallStatus -Target $Target -InstalledApps $Context.Apps -ScopeRead $ScopeRead -UserSid $Entry.UserSid -AppIndex $Context.AppIndex; $Profile.InstallStatus += $Clock.ElapsedTicks
        }
    }

    $Agg = [ordered]@{}
    & $Time 'Aggregation' {
        $Clock2 = [Diagnostics.Stopwatch]::StartNew()
        Invoke-AULedgerFold -Ledger $Ledger
        $Agg.Fold = $Clock2.ElapsedMilliseconds; $Clock2.Restart()
        $script:Inv = @(ConvertTo-AUInventoryApps -Apps $Context.Apps)
        $Agg.InventoryApps = $Clock2.ElapsedMilliseconds; $Clock2.Restart()
        $script:Known = Get-AUKnownExes -Apps $Context.Apps -MsiFileMap $Context.MsiFileMap -Mappings $Map -Entries $All
        $Agg.KnownExes = $Clock2.ElapsedMilliseconds; $Clock2.Restart()
        $script:Fields = Get-AUAppUsage -Entries $All -InventoryApps $script:Inv -KnownExesByApp $script:Known -WatchingSince $Ledger.WatchingSince -ScopeRead $ScopeRead -Apps $Context.Apps -CollectionOk $true
        $Agg.AppUsage = $Clock2.ElapsedMilliseconds; $Clock2.Restart()
        $script:ExeUsage = @(ConvertTo-AUExeUsage -Entries $All)
        $script:Unmatched = [int](Get-AUUnmatchedExeCount -Entries $All)
        $Agg.ExeUsage = $Clock2.ElapsedMilliseconds
    } | Out-Null

    $LedgerPath = Join-Path $Work 'AppUsage_SCALE.json'
    & $Time 'LedgerWrite' { Write-AULedger -Ledger $Ledger -Path $LedgerPath } | Out-Null
    $Back = & $Time 'LedgerRead' { Read-AULedger -Path $LedgerPath }
    $ExeJson = & $Time 'ExeUsageJson' { ConvertTo-AUExeUsageJson -ExeEntries $script:ExeUsage }
    $AppArray = @(ConvertTo-AUAppArray -Apps $Context.Apps)
    Add-AUAppFields -AppArray $AppArray -AppFields $script:Fields
    $AppJson = $AppArray | ConvertTo-Json
    $Main = [pscustomobject][ordered]@{ ComputerName_s = 'SCALE01'; ManagedDeviceID_g = '00000000-0000-0000-0000-000000000001' }
    $RunRows = & $Time 'RunRows' { New-AURunRows -MainColumns $Main -InstalledAppsJson $AppJson -ExeUsageJson $ExeJson -LogAPIMode 'LogIngestionAPI' -RunId '00000000-0000-0000-0000-000000000002' }

    # The results, in a stable order, for comparing two versions of the script.
    $Lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($Entry in $All)
    {
        $T = $Entry.Target
        $Lines.Add(('{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}' -f $Entry.UserSid, $Entry.ExeInfo, $T.MatchSection, $T.MatchRuleId, $T.ResolvedAppName, (@($T.CandidateTargets) -join ','), $Entry.Role, $Entry.InstallStatus))
    }
    $Names = [string[]]@($script:Fields.Keys)
    [Array]::Sort($Names, [StringComparer]::OrdinalIgnoreCase)
    foreach ($Name in $Names) { $Lines.Add($Name + '|' + ($script:Fields[$Name] | ConvertTo-Json -Compress)) }
    foreach ($Name in @($script:Known.Keys | Sort-Object)) { $Lines.Add('known|' + $Name + '|' + ((@($script:Known[$Name]) | Sort-Object) -join ',')) }
    $Lines.Add($ExeJson)
    $Sha = [Security.Cryptography.SHA256]::Create()
    $Hash = -join ($Sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($Lines -join "`n"))) | ForEach-Object { $_.ToString('x2') })

    $Statuses = ($All | Group-Object InstallStatus | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '
    $Roles = ($All | Group-Object Role | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '
    $Used = @($script:Fields.Values | Where-Object { $_.AppUsageStatus -eq 'Used' }).Count
    $Total = [long]0
    foreach ($Value in $Times.Values) { $Total += $Value }
    "Scale: $($Ledger.Entries.Count) entries, $($Rows.Count) SRUM rows, $($Context.Apps.Count) apps, $(@($script:ExeUsage).Count) exe usage rows, $($script:Unmatched) unmatched, $Used apps Used"
    "Install status: $Statuses"
    "Role: $Roles"
    "Ledger: $((Get-Item -LiteralPath $LedgerPath).Length) bytes, read back $($Back.Entries.Count) entries; run rows: $(@($RunRows).Count)"
    'Stage ms: ' + (($Times.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')
    'Aggregation ms: ' + (($Agg.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')
    if ($null -ne $Profile) { 'Facts profile ms (second pass): ' + (($Profile.GetEnumerator() | ForEach-Object { "$($_.Key)=$([long]($_.Value * 1000 / [Diagnostics.Stopwatch]::Frequency))" }) -join ' ') }
    "Total ms: $Total"
    "Results SHA-256: $Hash"
    "PowerShell $($PSVersionTable.PSVersion); $((Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim()); $([Environment]::ProcessorCount) logical processors"
}
finally
{
    Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
}
