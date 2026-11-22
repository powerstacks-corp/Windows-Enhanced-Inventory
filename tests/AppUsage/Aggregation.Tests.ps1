BeforeAll {
    . "$PSScriptRoot\_Import.ps1"

    $script:UserA = 'S-1-12-1-1111111111-2222222222-3333333333-4444444444'
    $script:UserB = 'S-1-5-21-1111111111-2222222222-3333333333-1002'
    $script:SystemSid = 'S-1-5-18'
    $script:MappingsCount = 0

    function New-TestUtc([string]$Text)
    {
        return [datetime]::SpecifyKind([datetime]::ParseExact($Text, 'yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture), [DateTimeKind]::Utc)
    }

    $script:Watching = New-TestUtc '2026-10-01T00:00:00'
    $script:Yesterday = New-TestUtc '2026-11-20T15:30:00'
    $script:Today = New-TestUtc '2026-11-21T09:45:12'

    # Facts in the Task 14 shape. A verified GUI build by default; pass overrides as a hashtable.
    function New-TestFacts([hashtable]$Values = @{})
    {
        $Facts = [ordered]@{
            ExeName         = 'alpha.exe'
            RunPath         = 'C:\Program Files\Contoso\Alpha\alpha.exe'
            LocationClass   = 'ProgramFiles'
            FileDescription = 'Contoso Alpha'
            FileProductName = 'Contoso Alpha'
            FileCompanyName = 'Contoso'
            FileVersion     = '1.0.0.0'
            ProductVersion  = '1.0.0.0'
            FactsVerified   = $true
            Subsystem       = 'GUI'
            MsiProductCode  = $null
            PackageFamily   = $null
            IsServiceBinary = $false
            UserSid         = $script:UserA
            PathEvidence    = $null
        }
        foreach ($Key in $Values.Keys) { $Facts[$Key] = $Values[$Key] }
        return [pscustomobject]$Facts
    }

    # An installed-app entry in the Task 13 shape (internal, with Scope). Machine scope by default.
    function New-TestApp([string]$Name, [string]$Publisher = 'Contoso', [hashtable]$Values = @{})
    {
        $App = [ordered]@{
            DisplayName     = $Name
            Publisher       = $Publisher
            DisplayVersion  = '1.0'
            ProductCode     = $null
            PackageFamily   = $null
            InstallLocation = $null
            DisplayIcon     = $null
            UninstallString = $null
            Architecture    = $null
            Scope           = 'Machine'
            ProfilePath     = $null
        }
        foreach ($Key in $Values.Keys) { $App[$Key] = $Values[$Key] }
        return [pscustomobject]$App
    }

    # A de-duplicated inventory entry (ConvertTo-AUInventoryApps shape) for an installed app.
    function ConvertTo-TestInventory([object[]]$Apps)
    {
        $Seen = @{}
        foreach ($App in $Apps)
        {
            if ($Seen.ContainsKey($App.DisplayName)) { continue }
            $Seen[$App.DisplayName] = $true
            [pscustomobject][ordered]@{
                AppName             = $App.DisplayName
                AppVersion          = $App.DisplayVersion
                AppPublisher        = $App.Publisher
                AppType             = 'Win32'
                AppInstallDate      = '01-09-2026'
                AppUninstallString  = $null
                AppUninstallRegPath = $null
            }
        }
    }

    # A Resolve-AUTarget result for the named app: a PowerStacks identity match by default.
    function New-TestTarget([string]$Name = 'Contoso Alpha', [hashtable]$Values = @{})
    {
        $Target = [ordered]@{
            TargetPattern           = $Name
            TargetPublisher         = 'Contoso'
            ResolvedAppName         = $Name
            ProductCode             = $null
            PackageFamily           = $null
            MatchSection            = 'PowerStacks'
            MatchRuleId             = 'ps-contoso-1'
            RuleType                = 'identity'
            InstalledStateDependent = $false
            EvidenceUsed            = 'Verified'
            CandidateTargets        = $null
            RetainedFrom            = $null
        }
        foreach ($Key in $Values.Keys) { $Target[$Key] = $Values[$Key] }
        return [pscustomobject]$Target
    }

    # An unresolved target: no match, with the given candidate DisplayNames (D47 survivors).
    function New-TestUnresolved([string[]]$Candidates = $null)
    {
        return New-TestTarget '' @{ TargetPattern = $null; TargetPublisher = $null; ResolvedAppName = $null; MatchSection = 'None'; MatchRuleId = $null; RuleType = $null; EvidenceUsed = 'None'; CandidateTargets = $Candidates }
    }

    function New-TestClassification([string]$IgnoreRuleId = $null, [string]$ClassificationRuleId = $null)
    {
        return [pscustomobject]@{ RuleRole = $null; ClassificationRuleId = $ClassificationRuleId; Ignored = [bool]$IgnoreRuleId; IgnoreRuleId = $IgnoreRuleId }
    }

    # A ledger entry with this run's Target, Classification, Role, UserType, and InstallStatus attached
    # (the shape Invoke-AppUsage builds). User A, matched to Contoso Alpha, nothing run, by default.
    function New-TestEntry([hashtable]$Values = @{})
    {
        $Entry = [ordered]@{
            UserSid                = $script:UserA
            ExeInfo                = '!!alpha.exe!2026/10/01:00:00:00!1a2b3!'
            ExeName                = 'alpha.exe'
            FirstSeen              = $script:Watching
            Counted                = @{}
            ArchivedFocus          = [double]0
            ArchivedInput          = [double]0
            LastFocusOrInputTime   = $null
            LastInteractiveRunTime = $null
            LastRanTime            = $null
            Facts                  = (New-TestFacts)
            FactsVerified          = $true
            StoredTarget           = $null
            FocusTotal             = [double]0
            Target                 = (New-TestTarget)
            Classification         = (New-TestClassification)
            Role                   = 'App'
            UserType               = 'CloudOnly'
            InstallStatus          = 'Installed'
        }
        foreach ($Key in $Values.Keys) { $Entry[$Key] = $Values[$Key] }
        return [pscustomobject]$Entry
    }

    # An entry the user focused at the given time.
    function New-TestUsedEntry([datetime]$When, [hashtable]$Values = @{})
    {
        $Base = @{ LastFocusOrInputTime = $When; LastInteractiveRunTime = $When; LastRanTime = $When; FocusTotal = [double]120 }
        foreach ($Key in $Values.Keys) { $Base[$Key] = $Values[$Key] }
        return New-TestEntry $Base
    }

    function New-TestScopeRead([hashtable]$Values = @{})
    {
        $Read = @{ Machine = 'Read'; $script:UserA = 'Read'; $script:UserB = 'Read'; $script:SystemSid = 'Read' }
        foreach ($Key in $Values.Keys) { $Read[$Key] = $Values[$Key] }
        return $Read
    }

    # Runs Get-AUAppUsage the way Invoke-AppUsage does: known exes from Get-AUKnownExes unless given.
    function Invoke-TestAppUsage
    {
        param (
            [object[]]$Entries = @(),
            [object[]]$Apps = @((New-TestApp 'Contoso Alpha')),
            [hashtable]$Known = $null,
            [object]$WatchingSince = $script:Watching,
            [hashtable]$ScopeRead = (New-TestScopeRead),
            [bool]$CollectionOk = $true
        )
        if ($null -eq $Known) { $Known = Get-AUKnownExes $Apps @{} $null $Entries }
        return Get-AUAppUsage -Entries $Entries -InventoryApps @(ConvertTo-TestInventory $Apps) -KnownExesByApp $Known -WatchingSince $WatchingSince -ScopeRead $ScopeRead -Apps $Apps -CollectionOk $CollectionOk
    }

    function New-TestKnown([hashtable]$Values)
    {
        $Known = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
        foreach ($Key in $Values.Keys)
        {
            $Set = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($Exe in @($Values[$Key])) { [void]$Set.Add($Exe) }
            $Known[$Key] = $Set
        }
        return $Known
    }

    # The whole Get-AUMappings result, built through the real loader from PowerStacks rule JSON texts.
    function New-TestMappings([string[]]$PowerStacks, [string[]]$Classification = @())
    {
        $script:MappingsCount++
        $Dir = Join-Path 'TestDrive:\' "mappings$($script:MappingsCount)"
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $Dir = (Resolve-Path $Dir).ProviderPath
        $Json = '{ "schemaVersion": 1, "powerStacks": { "version": "test", "identityRules": [' + ($PowerStacks -join ',') + '], "classificationRules": [' + ($Classification -join ',') + '] } }'
        [IO.File]::WriteAllText((Join-Path $Dir 'powerstacks-mappings.json'), $Json)
        $Result = Get-AUMappings -Embedded '' -BesideDir $Dir -CustomerPath (Join-Path $Dir 'customer-mappings.json')
        if ($Result.Errors.Count -gt 0) { throw "Test mappings are invalid: $($Result.Errors -join ' | ')" }
        return $Result
    }

    $script:AppFields = @('AppLastUsedDate', 'AppUsageStatus', 'AppLastRanDate', 'AppInFocusSeconds', 'AppUsersWithUse', 'AppMatchedExeCount', 'AppRunsAsService')
    $script:ExeFields = @('ExeInfo', 'ExeName', 'RunPath', 'LocationClass', 'FileDescription', 'FileProductName', 'FileCompanyName', 'FileVersion', 'ProductVersion', 'FactsVerified',
        'EvidenceCompanyName', 'EvidenceProductName', 'EvidenceSource', 'Subsystem', 'Role', 'ClassificationRuleId', 'ResolvedAppName', 'TargetPattern', 'Publisher', 'ProductCode',
        'MatchSection', 'MatchRuleId', 'InstallStatus', 'FirstSeen', 'LastUsedTime', 'LastRanTime', 'InFocusSeconds', 'UsersWithUse', 'RanAsSystemOnly')
}

Describe 'Get-AUAppUsage across users (D19)' {
    It 'gives one result with the latest use, both users, and Used when user A used it yesterday and user B today' {
        $entries = @(
            (New-TestUsedEntry $script:Yesterday)
            (New-TestUsedEntry $script:Today @{ UserSid = $script:UserB; UserType = 'Domain' })
        )
        $result = Invoke-TestAppUsage -Entries $entries
        $result.Count | Should -Be 1
        $value = $result['Contoso Alpha']
        $value.AppLastUsedDate | Should -BeExactly '2026-11-21T09:45:12.0000000Z'
        $value.AppUsersWithUse | Should -Be 2
        $value.AppUsageStatus | Should -BeExactly 'Used'
        $value.AppLastRanDate | Should -BeExactly '2026-11-21T09:45:12.0000000Z'
        $value.AppInFocusSeconds | Should -Be 240
        $value.AppMatchedExeCount | Should -Be 1
        $value.AppRunsAsService | Should -BeFalse
    }

    It 'keys the result by inventory DisplayName, ignoring case, with exactly the seven fields' {
        $result = Invoke-TestAppUsage -Entries @((New-TestUsedEntry $script:Today))
        $result['CONTOSO ALPHA'] | Should -Not -BeNullOrEmpty
        @($result['Contoso Alpha'].PSObject.Properties.Name) | Should -Be $script:AppFields
    }

    It 'is Used when user A used it and user B only ran it in the background' {
        $entries = @(
            (New-TestUsedEntry $script:Yesterday)
            (New-TestEntry @{ UserSid = $script:UserB; UserType = 'Domain'; LastInteractiveRunTime = $script:Today; LastRanTime = $script:Today })
        )
        $value = (Invoke-TestAppUsage -Entries $entries)['Contoso Alpha']
        $value.AppUsageStatus | Should -BeExactly 'Used'
        $value.AppUsersWithUse | Should -Be 1
        $value.AppLastUsedDate | Should -BeExactly '2026-11-20T15:30:00.0000000Z'
        $value.AppLastRanDate | Should -BeExactly '2026-11-21T09:45:12.0000000Z'
    }

    It 'is Used for a CLI tool with zero focus run by a user, dated at that run in the V71 format' {
        $run = New-TestUtc '2026-11-18T09:15:00'
        $git = New-TestEntry @{ ExeInfo = '!!git.exe!2026/10/08:00:00:00!3c4d5!'; ExeName = 'git.exe'; Role = 'CLI'; LastInteractiveRunTime = $run; LastRanTime = $run; Target = (New-TestTarget 'Git' @{ TargetPublisher = 'The Git Development Community' }) }
        $value = (Invoke-TestAppUsage -Entries @($git) -Apps @((New-TestApp 'Git' 'The Git Development Community')))['Git']
        $value.AppUsageStatus | Should -BeExactly 'Used'
        $value.AppLastUsedDate | Should -BeExactly '2026-11-18T09:15:00.0000000Z'
        $value.AppInFocusSeconds | Should -Be 0
        $value.AppUsersWithUse | Should -Be 1
    }

    It 'is RanNotUsed for SYSTEM-only runs, even with focus recorded' {
        $agent = New-TestEntry @{ UserSid = $script:SystemSid; UserType = 'System'; LastFocusOrInputTime = $script:Today; LastInteractiveRunTime = $script:Today; LastRanTime = $script:Today; FocusTotal = [double]30 }
        $value = (Invoke-TestAppUsage -Entries @($agent))['Contoso Alpha']
        $value.AppUsageStatus | Should -BeExactly 'RanNotUsed'
        $value.AppLastUsedDate | Should -BeNullOrEmpty
        $value.AppUsersWithUse | Should -Be 0
        $value.AppLastRanDate | Should -BeExactly '2026-11-21T09:45:12.0000000Z'
        $value.AppInFocusSeconds | Should -Be 0
    }

    It 'counts focus and users only for interactive users with a SID' {
        $entries = @(
            (New-TestUsedEntry $script:Today)
            (New-TestUsedEntry $script:Today @{ UserSid = ''; UserType = 'CloudOnly' })
            (New-TestEntry @{ UserSid = 'S-1-5-19'; UserType = 'Service'; LastRanTime = $script:Today; FocusTotal = [double]50 })
            (New-TestEntry @{ UserSid = 'S-1-5-99'; UserType = 'Unknown'; LastRanTime = $script:Today; FocusTotal = [double]70 })
        )
        $value = (Invoke-TestAppUsage -Entries $entries)['Contoso Alpha']
        $value.AppUsersWithUse | Should -Be 1
        $value.AppInFocusSeconds | Should -Be 240
        $out = (ConvertTo-AUExeUsage $entries)[0]
        $out.UsersWithUse | Should -Be 1
        $out.InFocusSeconds | Should -Be 240
    }

    It 'is NotUsed when its exes are known and none ran' {
        $value = (Invoke-TestAppUsage -Known (New-TestKnown @{ 'Contoso Alpha' = 'alpha.exe' }))['Contoso Alpha']
        $value.AppUsageStatus | Should -BeExactly 'NotUsed'
        $value.AppLastUsedDate | Should -BeNullOrEmpty
        $value.AppLastRanDate | Should -BeNullOrEmpty
        $value.AppInFocusSeconds | Should -Be 0
        $value.AppUsersWithUse | Should -Be 0
        $value.AppMatchedExeCount | Should -Be 0
        $value.AppRunsAsService | Should -BeFalse
    }

    It 'is NotCovered when no exe is known for it' {
        (Invoke-TestAppUsage)['Contoso Alpha'].AppUsageStatus | Should -BeExactly 'NotCovered'
    }

    It 'leaves every field blank, never NotUsed, when App Usage failed (F24)' {
        $apps = @((New-TestApp 'Contoso Alpha'), (New-TestApp 'Contoso Beta'))
        $result = Invoke-TestAppUsage -Apps $apps -Known (New-TestKnown @{ 'Contoso Alpha' = 'alpha.exe'; 'Contoso Beta' = 'beta.exe' }) -CollectionOk $false
        $result.Count | Should -Be 2
        foreach ($Name in @('Contoso Alpha', 'Contoso Beta'))
        {
            foreach ($Field in $script:AppFields) { $result[$Name].$Field | Should -BeNullOrEmpty -Because "$Name $Field" }
        }
    }

    It 'credits a renamed update through the target-app test (arpCompare normalized name)' {
        $target = New-TestTarget 'Contoso Alpha 1.0' @{ TargetPattern = 'Contoso Alpha 1.0'; RuleType = 'arpCompare'; InstalledStateDependent = $true; MatchRuleId = 'ps-arp-compare' }
        $value = (Invoke-TestAppUsage -Entries @((New-TestUsedEntry $script:Today @{ Target = $target })) -Apps @((New-TestApp 'Contoso Alpha 1.1')))['Contoso Alpha 1.1']
        $value.AppUsageStatus | Should -BeExactly 'Used'
    }

    It 'credits a Store package entry (no ExeName) by its package family' {
        $family = 'Contoso.Notes_8wekyb3d8bbwe'
        $entry = New-TestUsedEntry $script:Today @{ ExeInfo = 'Contoso.Notes_1.2.3.0_x64__8wekyb3d8bbwe'; ExeName = $null; Facts = (New-TestFacts @{ ExeName = $null; RunPath = $null; PackageFamily = $family }); Target = (New-TestTarget 'Contoso Notes' @{ PackageFamily = $family; RuleType = 'ownership'; InstalledStateDependent = $true; MatchRuleId = 'ps-own-store' }) }
        $apps = @((New-TestApp 'Contoso Notes' 'Contoso' @{ PackageFamily = $family }))
        $value = (Invoke-TestAppUsage -Entries @($entry) -Apps $apps)['Contoso Notes']
        $value.AppUsageStatus | Should -BeExactly 'Used'
        $value.AppMatchedExeCount | Should -Be 1
    }

    It 'leaves out a date that is not UTC instead of throwing' {
        $local = [datetime]::SpecifyKind($script:Today, [DateTimeKind]::Unspecified)
        $value = (Invoke-TestAppUsage -Entries @((New-TestUsedEntry $script:Yesterday @{ LastRanTime = $local })))['Contoso Alpha']
        $value.AppLastRanDate | Should -BeNullOrEmpty
        $value.AppLastUsedDate | Should -BeExactly '2026-11-20T15:30:00.0000000Z'
    }
}

Describe 'Get-AUAppUsage with a target resolved among siblings (D47, F11, I2)' {
    It 'credits none of the chosen app''s use to a sibling that stays installed after the chosen app is removed' {
        $apps = @((New-TestApp 'Contoso Tool (x86)' 'Contoso' @{ Architecture = 'x86' }))
        $target = New-TestTarget 'Contoso Tool' @{ MatchSection = 'Retained'; RetainedFrom = 'PowerStacks'; MatchRuleId = 'ps-resolve-arch'; RuleType = 'arpCompare'; InstalledStateDependent = $true }
        $tool = New-TestUsedEntry $script:Today @{ ExeInfo = '!!tool.exe!2026/09/15:00:00:00!aaaa1!'; ExeName = 'tool.exe'; Target = $target; InstallStatus = 'NotInstalled' }
        $value = (Invoke-TestAppUsage -Entries @($tool) -Apps $apps)['Contoso Tool (x86)']
        $value.AppUsageStatus | Should -BeExactly 'NotCovered'
        $value.AppLastUsedDate | Should -BeNullOrEmpty
        $value.AppInFocusSeconds | Should -Be 0
        $value.AppMatchedExeCount | Should -Be 0
    }
}

Describe 'Get-AUAppUsage Ambiguous (D30, D47)' {
    BeforeAll {
        $script:ViewerApps = @((New-TestApp 'Contoso Viewer'), (New-TestApp 'Contoso Viewer Pro'))
        $script:ViewerKnown = New-TestKnown @{ 'Contoso Viewer' = 'viewer.exe'; 'Contoso Viewer Pro' = 'viewerpro.exe' }
        $script:Unresolved = New-TestUsedEntry $script:Today @{ ExeInfo = '!!viewer.exe!2026/08/01:00:00:00!bbbb2!'; ExeName = 'viewer.exe'; Role = 'Unmatched'; InstallStatus = 'Unmatched'; Target = (New-TestUnresolved @('Contoso Viewer', 'Contoso Viewer Pro')) }
    }

    It 'is Ambiguous, never NotUsed, for each candidate of an unresolved exe that ran' {
        $result = Invoke-TestAppUsage -Entries @($script:Unresolved) -Apps $script:ViewerApps -Known $script:ViewerKnown
        $result['Contoso Viewer'].AppUsageStatus | Should -BeExactly 'Ambiguous'
        $result['Contoso Viewer Pro'].AppUsageStatus | Should -BeExactly 'Ambiguous'
        $result['Contoso Viewer'].AppUsersWithUse | Should -Be 0
    }

    It 'is Ambiguous even when the candidate has no known exes (over NotCovered)' {
        $result = Invoke-TestAppUsage -Entries @($script:Unresolved) -Apps $script:ViewerApps -Known (New-TestKnown @{})
        $result['Contoso Viewer'].AppUsageStatus | Should -BeExactly 'Ambiguous'
    }

    It 'is Used for a candidate that also has a matched exe with credited use' {
        $pro = New-TestUsedEntry $script:Yesterday @{ ExeInfo = '!!viewerpro.exe!2026/08/01:00:00:00!cccc3!'; ExeName = 'viewerpro.exe'; Target = (New-TestTarget 'Contoso Viewer Pro') }
        $result = Invoke-TestAppUsage -Entries @($script:Unresolved, $pro) -Apps $script:ViewerApps -Known $script:ViewerKnown
        $result['Contoso Viewer'].AppUsageStatus | Should -BeExactly 'Ambiguous'
        $result['Contoso Viewer Pro'].AppUsageStatus | Should -BeExactly 'Used'
    }
}

Describe 'Get-AUAppUsage known exe that ran unmatched (D30)' {
    BeforeAll {
        $script:AlphaCode = '{11111111-1111-1111-1111-111111111111}'
        $script:AlphaApps = @((New-TestApp 'Contoso Alpha' 'Contoso' @{ ProductCode = $script:AlphaCode }))
        # An unverified alpha.exe build that ran today with focus: MSI ownership needs a verified build,
        # so it stays unmatched with no candidates.
        function New-TestUnmatchedRun([string]$ExeName = 'alpha.exe', [hashtable]$Values = @{})
        {
            $Base = @{ UserSid = $script:UserB; UserType = 'Domain'; ExeInfo = "!!$ExeName!2026/11/01:00:00:00!77777!"; ExeName = $ExeName; Role = 'Unmatched'; InstallStatus = 'Unmatched'; Target = (New-TestUnresolved); Facts = (New-TestFacts @{ ExeName = $ExeName; FactsVerified = $false; FileVersion = $null; FileCompanyName = $null }); FactsVerified = $false; FocusTotal = [double]600 }
            foreach ($Key in $Values.Keys) { $Base[$Key] = $Values[$Key] }
            return New-TestUsedEntry $script:Today $Base
        }
    }

    It 'is Ambiguous, not NotUsed, when an exe Windows Installer lists for the app ran unmatched' {
        $run = New-TestUnmatchedRun
        $known = Get-AUKnownExes $script:AlphaApps @{ 'c:\program files\contoso\alpha\alpha.exe' = $script:AlphaCode } $null @($run)
        @($known['Contoso Alpha']) | Should -Be @('alpha.exe')
        (Invoke-TestAppUsage -Entries @($run) -Apps $script:AlphaApps -Known $known)['Contoso Alpha'].AppUsageStatus | Should -BeExactly 'Ambiguous'
    }

    It 'is Ambiguous when an exe an identity rule names for the app ran unmatched' {
        $mappings = New-TestMappings @('{ "id": "ps-alpha-1", "type": "identity", "when": { "exeName": "alpha.exe", "publisher": "Contoso*" }, "target": { "displayName": "Contoso Alpha", "publisher": "Contoso*" } }')
        $run = New-TestUnmatchedRun
        $known = Get-AUKnownExes $script:AlphaApps @{} $mappings @($run)
        (Invoke-TestAppUsage -Entries @($run) -Apps $script:AlphaApps -Known $known)['Contoso Alpha'].AppUsageStatus | Should -BeExactly 'Ambiguous'
    }

    It 'is Ambiguous when an earlier, matched build of the exe is known and a new build ran unmatched' {
        $old = New-TestEntry @{ ExeInfo = '!!alpha.exe!2026/06/01:00:00:00!11111!'; LastRanTime = (New-TestUtc '2026-09-01T00:00:00') }
        $run = New-TestUnmatchedRun
        $entries = @($old, $run)
        $value = (Invoke-TestAppUsage -Entries $entries -Apps $script:AlphaApps -Known (Get-AUKnownExes $script:AlphaApps @{} $null $entries))['Contoso Alpha']
        $value.AppUsageStatus | Should -BeExactly 'Ambiguous'
        $value.AppMatchedExeCount | Should -Be 1
    }

    It 'matches an unmatched run against a wildcard exeName with -like' {
        $mappings = New-TestMappings @('{ "id": "ps-alpha-2", "type": "identity", "when": { "exeName": "contoso*.exe", "publisher": "Contoso*" }, "target": { "displayName": "Contoso Alpha", "publisher": "Contoso*" } }')
        $known = Get-AUKnownExes $script:AlphaApps @{} $mappings @()
        @($known['Contoso Alpha']) | Should -Be @('contoso*.exe')
        (Invoke-TestAppUsage -Entries @((New-TestUnmatchedRun 'contosoalpha.exe')) -Apps $script:AlphaApps -Known $known)['Contoso Alpha'].AppUsageStatus | Should -BeExactly 'Ambiguous'
        (Invoke-TestAppUsage -Entries @((New-TestUnmatchedRun 'fabrikam.exe')) -Apps $script:AlphaApps -Known $known)['Contoso Alpha'].AppUsageStatus | Should -BeExactly 'NotUsed'
    }

    It 'is Ambiguous when the known exe ran unmatched only as SYSTEM' {
        $run = New-TestUnmatchedRun 'alpha.exe' @{ UserSid = $script:SystemSid; UserType = 'System' }
        $value = (Invoke-TestAppUsage -Entries @($run) -Apps $script:AlphaApps -Known (New-TestKnown @{ 'Contoso Alpha' = 'alpha.exe' }))['Contoso Alpha']
        $value.AppUsageStatus | Should -BeExactly 'Ambiguous'
    }

    It 'treats a Windows Installer name holding [ as literal: an unmatched run of that name is Ambiguous, without throwing' {
        $run = New-TestUnmatchedRun 'alpha[.exe'
        $known = Get-AUKnownExes $script:AlphaApps @{ 'c:\program files\contoso\alpha\alpha[.exe' = $script:AlphaCode } $null @($run)
        { Invoke-TestAppUsage -Entries @($run) -Apps $script:AlphaApps -Known $known } | Should -Not -Throw
        (Invoke-TestAppUsage -Entries @($run) -Apps $script:AlphaApps -Known $known)['Contoso Alpha'].AppUsageStatus | Should -BeExactly 'Ambiguous'
        (Invoke-TestAppUsage -Entries @((New-TestUnmatchedRun 'beta.exe')) -Apps $script:AlphaApps -Known $known)['Contoso Alpha'].AppUsageStatus | Should -BeExactly 'NotUsed'
    }

    It 'treats a Windows Installer name <Name> as literal: it matches itself and nothing else, without throwing' -ForEach @(
        @{ Name = 'a`[b].exe' }
        @{ Name = 'a`[b.exe' }
    ) {
        $known = Get-AUKnownExes $script:AlphaApps @{ ('c:\program files\contoso\alpha\' + $Name) = $script:AlphaCode } $null @()
        { Invoke-TestAppUsage -Entries @((New-TestUnmatchedRun $Name)) -Apps $script:AlphaApps -Known $known } | Should -Not -Throw
        (Invoke-TestAppUsage -Entries @((New-TestUnmatchedRun $Name)) -Apps $script:AlphaApps -Known $known)['Contoso Alpha'].AppUsageStatus | Should -BeExactly 'Ambiguous'
        foreach ($Other in @('a`b.exe', 'ab.exe', 'a[b].exe', 'a`].exe', 'a``[b].exe'))
        {
            (Invoke-TestAppUsage -Entries @((New-TestUnmatchedRun $Other)) -Apps $script:AlphaApps -Known $known)['Contoso Alpha'].AppUsageStatus | Should -BeExactly 'NotUsed' -Because $Other
        }
    }

    It 'treats a literal foo[1].exe as literal: an unmatched foo1.exe does not match it' {
        $known = Get-AUKnownExes $script:AlphaApps @{ 'c:\program files\contoso\alpha\foo[1].exe' = $script:AlphaCode } $null @()
        (Invoke-TestAppUsage -Entries @((New-TestUnmatchedRun 'foo1.exe')) -Apps $script:AlphaApps -Known $known)['Contoso Alpha'].AppUsageStatus | Should -BeExactly 'NotUsed'
        (Invoke-TestAppUsage -Entries @((New-TestUnmatchedRun 'foo[1].exe')) -Apps $script:AlphaApps -Known $known)['Contoso Alpha'].AppUsageStatus | Should -BeExactly 'Ambiguous'
    }

    It 'treats a matched exe name holding [ as literal too' {
        $old = New-TestEntry @{ ExeInfo = '!!foo[1].exe!2026/06/01:00:00:00!11111!'; ExeName = 'foo[1].exe'; LastRanTime = (New-TestUtc '2026-09-01T00:00:00') }
        $entries = @($old, (New-TestUnmatchedRun 'foo1.exe'))
        $known = Get-AUKnownExes $script:AlphaApps @{} $null $entries
        (Invoke-TestAppUsage -Entries $entries -Apps $script:AlphaApps -Known $known)['Contoso Alpha'].AppUsageStatus | Should -BeExactly 'NotUsed'
    }

    It 'never throws on a known-exe pattern that will not parse' {
        { $script:BadPattern = (Invoke-TestAppUsage -Entries @((New-TestUnmatchedRun 'beta.exe')) -Apps $script:AlphaApps -Known (New-TestKnown @{ 'Contoso Alpha' = 'alpha[.exe' }))['Contoso Alpha'] } | Should -Not -Throw
        $script:BadPattern.AppUsageStatus | Should -BeExactly 'NotUsed'
    }

    It 'stays NotUsed when the unmatched run is ignored, has another name, or ran before WatchingSince' {
        $known = New-TestKnown @{ 'Contoso Alpha' = 'alpha.exe' }
        $ignored = New-TestUnmatchedRun 'alpha.exe' @{ Classification = (New-TestClassification 'ps-ignore-1') }
        $other = New-TestUnmatchedRun 'beta.exe'
        $early = New-TestUnmatchedRun 'alpha.exe' @{ LastRanTime = (New-TestUtc '2026-09-01T00:00:00'); LastFocusOrInputTime = (New-TestUtc '2026-09-01T00:00:00'); LastInteractiveRunTime = (New-TestUtc '2026-09-01T00:00:00') }
        foreach ($Entry in @($ignored, $other, $early))
        {
            (Invoke-TestAppUsage -Entries @($Entry) -Apps $script:AlphaApps -Known $known)['Contoso Alpha'].AppUsageStatus | Should -BeExactly 'NotUsed' -Because $Entry.ExeInfo
        }
    }

    It 'keeps NotUsed for an app whose known exe ran but resolved to another app (sample 11)' {
        $apps = @((New-TestApp 'Fabrikam Studio 7' 'Fabrikam' @{ ProductCode = '{77777777-7777-7777-7777-777777777777}' }), (New-TestApp 'Fabrikam Studio Pro 7' 'Fabrikam'))
        $editor = New-TestUsedEntry $script:Today @{ ExeInfo = '!!editor.exe!2026/09/15:00:00:00!cccc3!'; ExeName = 'editor.exe'; Target = (New-TestTarget 'Fabrikam Studio Pro 7' @{ TargetPublisher = 'Fabrikam'; MatchRuleId = 'ps-resolve-path' }) }
        $known = Get-AUKnownExes $apps @{ 'c:\program files\fabrikam\studio\editor.exe' = '{77777777-7777-7777-7777-777777777777}' } $null @($editor)
        $result = Invoke-TestAppUsage -Entries @($editor) -Apps $apps -Known $known
        $result['Fabrikam Studio 7'].AppUsageStatus | Should -BeExactly 'NotUsed'
        $result['Fabrikam Studio Pro 7'].AppUsageStatus | Should -BeExactly 'Used'
    }
}

Describe 'Get-AUAppUsage coverage (D32, F24)' {
    It 'is blank, not NotUsed, when the per-user scope holding the app is <State>' -ForEach @(
        @{ State = 'Unread' }, @{ State = 'Deleted' }
    ) {
        $apps = @((New-TestApp 'Contoso Alpha' 'Contoso' @{ Scope = $script:UserA }))
        $value = (Invoke-TestAppUsage -Apps $apps -Known (New-TestKnown @{ 'Contoso Alpha' = 'alpha.exe' }) -ScopeRead (New-TestScopeRead @{ $script:UserA = $State }))['Contoso Alpha']
        $value.AppUsageStatus | Should -BeNullOrEmpty
    }

    It 'is blank when the scope holding the app is missing from ScopeRead' {
        $apps = @((New-TestApp 'Contoso Alpha' 'Contoso' @{ Scope = 'S-1-5-21-1111111111-2222222222-3333333333-1009' }))
        (Invoke-TestAppUsage -Apps $apps -Known (New-TestKnown @{ 'Contoso Alpha' = 'alpha.exe' }))['Contoso Alpha'].AppUsageStatus | Should -BeNullOrEmpty
    }

    It 'is blank when one of two scopes holding the app is unread' {
        $apps = @((New-TestApp 'Contoso Alpha'), (New-TestApp 'Contoso Alpha' 'Contoso' @{ Scope = $script:UserB }))
        $value = (Invoke-TestAppUsage -Apps $apps -Known (New-TestKnown @{ 'Contoso Alpha' = 'alpha.exe' }) -ScopeRead (New-TestScopeRead @{ $script:UserB = 'Unread' }))['Contoso Alpha']
        $value.AppUsageStatus | Should -BeNullOrEmpty
    }

    It 'is NotUsed when every scope holding the app was read' {
        $apps = @((New-TestApp 'Contoso Alpha'), (New-TestApp 'Contoso Alpha' 'Contoso' @{ Scope = $script:UserB }))
        (Invoke-TestAppUsage -Apps $apps -Known (New-TestKnown @{ 'Contoso Alpha' = 'alpha.exe' }))['Contoso Alpha'].AppUsageStatus | Should -BeExactly 'NotUsed'
    }

    It 'is blank when WatchingSince is unknown, but keeps the usage facts' {
        $value = (Invoke-TestAppUsage -Entries @((New-TestUsedEntry $script:Today)) -WatchingSince $null)['Contoso Alpha']
        $value.AppUsageStatus | Should -BeNullOrEmpty
        $value.AppLastUsedDate | Should -BeExactly '2026-11-21T09:45:12.0000000Z'
        $value.AppUsersWithUse | Should -Be 1
    }
}

Describe 'Get-AUAppUsage service-backed apps (D32)' {
    It 'is RanNotUsed with AppRunsAsService when the service ran with no focus' {
        $svc = New-TestEntry @{ UserSid = $script:SystemSid; UserType = 'System'; Role = 'Service'; LastRanTime = $script:Today; Facts = (New-TestFacts @{ IsServiceBinary = $true }) }
        $value = (Invoke-TestAppUsage -Entries @($svc))['Contoso Alpha']
        $value.AppUsageStatus | Should -BeExactly 'RanNotUsed'
        $value.AppRunsAsService | Should -BeTrue
    }

    It 'is NotUsed with AppRunsAsService only when the service never ran' {
        $svc = New-TestEntry @{ UserSid = $script:SystemSid; UserType = 'System'; Role = 'Service'; Facts = (New-TestFacts @{ IsServiceBinary = $true }) }
        $value = (Invoke-TestAppUsage -Entries @($svc))['Contoso Alpha']
        $value.AppUsageStatus | Should -BeExactly 'NotUsed'
        $value.AppRunsAsService | Should -BeTrue
    }

    It 'flags a service binary whose role came from a classification rule' {
        $svc = New-TestEntry @{ Role = 'Helper'; LastRanTime = $script:Today; Facts = (New-TestFacts @{ IsServiceBinary = $true }) }
        (Invoke-TestAppUsage -Entries @($svc))['Contoso Alpha'].AppRunsAsService | Should -BeTrue
    }
}

Describe 'Ignored executables (F22)' {
    BeforeAll {
        $script:Ignore = New-TestClassification 'ps-ignore-updater'
    }

    It 'an ignored exe that ran with focus does not make its app Used' {
        $entry = New-TestUsedEntry $script:Today @{ ExeInfo = '!!alphaupdate.exe!2026/10/01:00:00:00!9f9f9!'; ExeName = 'alphaupdate.exe'; Classification = $script:Ignore }
        $value = (Invoke-TestAppUsage -Entries @($entry))['Contoso Alpha']
        $value.AppUsageStatus | Should -BeExactly 'NotCovered'
        $value.AppLastUsedDate | Should -BeNullOrEmpty
        $value.AppMatchedExeCount | Should -Be 0
    }

    It 'an ignored unmatched exe is not counted as unmatched' {
        $ignored = New-TestUsedEntry $script:Today @{ ExeInfo = '!!helper.exe!2026/10/01:00:00:00!1!'; ExeName = 'helper.exe'; Role = 'Unmatched'; InstallStatus = 'Unmatched'; Target = (New-TestUnresolved); Classification = $script:Ignore }
        $plain = New-TestUsedEntry $script:Today @{ ExeInfo = '!!other.exe!2026/10/01:00:00:00!2!'; ExeName = 'other.exe'; Role = 'Unmatched'; InstallStatus = 'Unmatched'; Target = (New-TestUnresolved) }
        Get-AUUnmatchedExeCount @($ignored, $plain) | Should -Be 1
        Get-AUUnmatchedExeCount @($ignored) | Should -Be 0
    }

    It 'an ignored unresolved exe does not make a candidate app Ambiguous' {
        $entry = New-TestUsedEntry $script:Today @{ ExeInfo = '!!viewer.exe!2026/08/01:00:00:00!bbbb2!'; ExeName = 'viewer.exe'; Role = 'Unmatched'; InstallStatus = 'Unmatched'; Target = (New-TestUnresolved @('Contoso Viewer', 'Contoso Viewer Pro')); Classification = $script:Ignore }
        $apps = @((New-TestApp 'Contoso Viewer'), (New-TestApp 'Contoso Viewer Pro'))
        $result = Invoke-TestAppUsage -Entries @($entry) -Apps $apps -Known (New-TestKnown @{ 'Contoso Viewer' = 'viewer.exe' })
        $result['Contoso Viewer'].AppUsageStatus | Should -BeExactly 'NotUsed'
        $result['Contoso Viewer Pro'].AppUsageStatus | Should -BeExactly 'NotCovered'
    }

    It 'an ignored exe stays in the executable output with the ignore rule ID' {
        $entry = New-TestUsedEntry $script:Today @{ ExeInfo = '!!alphaupdate.exe!2026/10/01:00:00:00!9f9f9!'; ExeName = 'alphaupdate.exe'; Classification = $script:Ignore }
        $out = @(ConvertTo-AUExeUsage @($entry))
        $out.Count | Should -Be 1
        $out[0].ClassificationRuleId | Should -BeExactly 'ps-ignore-updater'
        $out[0].LastUsedTime | Should -BeExactly '2026-11-21T09:45:12.0000000Z'
    }

    It 'reports the classification rule ID when the exe is not ignored' {
        $entry = New-TestEntry @{ Classification = (New-TestClassification $null 'c-class-1'); Role = 'Helper' }
        (ConvertTo-AUExeUsage @($entry))[0].ClassificationRuleId | Should -BeExactly 'c-class-1'
    }
}

Describe 'Get-AUKnownExes (F23)' {
    BeforeAll {
        $script:KnownApps = @(
            (New-TestApp 'Contoso Alpha' 'Contoso' @{ ProductCode = '{11111111-1111-1111-1111-111111111111}' })
            (New-TestApp 'Contoso Beta')
            (New-TestApp 'Contoso Gamma')
            (New-TestApp 'Contoso Delta')
        )
        $script:MsiMap = @{
            'c:\program files\contoso\alpha\alpha.exe'     = '{11111111-1111-1111-1111-111111111111}'
            'c:\program files\contoso\alpha\alphacore.dll' = '{11111111-1111-1111-1111-111111111111}'
            'c:\program files\other\other.exe'             = '{22222222-2222-2222-2222-222222222222}'
        }
        $script:KnownMappings = New-TestMappings @('{ "id": "ps-beta-1", "type": "identity", "when": { "exeName": "Beta.exe", "publisher": "Contoso*" }, "target": { "displayName": "Contoso Beta", "publisher": "Contoso*" } }')
        $script:GammaEntry = New-TestEntry @{ ExeInfo = '!!gamma.exe!2026/10/01:00:00:00!4!'; ExeName = 'gamma.exe'; Target = (New-TestTarget 'Contoso Gamma') }
        $script:KnownResult = Get-AUKnownExes $script:KnownApps $script:MsiMap $script:KnownMappings @($script:GammaEntry)
    }

    It 'lists an exe Windows Installer records for the app''s ProductCode, and no other file' {
        @($script:KnownResult['Contoso Alpha']) | Should -Be @('alpha.exe')
    }

    It 'lists the exe an identity rule names, lowercased, when the rule''s target matches the app' {
        @($script:KnownResult['Contoso Beta']) | Should -Be @('beta.exe')
    }

    It 'lists a matched entry''s exe' {
        @($script:KnownResult['contoso gamma']) | Should -Be @('gamma.exe')
    }

    It 'leaves out an app with none of the three, so it is NotCovered' {
        $script:KnownResult.ContainsKey('Contoso Delta') | Should -BeFalse
        $result = Get-AUAppUsage -Entries @($script:GammaEntry) -InventoryApps @(ConvertTo-TestInventory $script:KnownApps) -KnownExesByApp $script:KnownResult -WatchingSince $script:Watching -ScopeRead (New-TestScopeRead) -Apps $script:KnownApps -CollectionOk $true
        $result['Contoso Delta'].AppUsageStatus | Should -BeExactly 'NotCovered'
        $result['Contoso Alpha'].AppUsageStatus | Should -BeExactly 'NotUsed'
        $result['Contoso Beta'].AppUsageStatus | Should -BeExactly 'NotUsed'
        $result['Contoso Gamma'].AppUsageStatus | Should -BeExactly 'NotUsed'
    }

    It 'leaves out ignored and unmatched entries' {
        $ignored = New-TestEntry @{ ExeInfo = '!!delta.exe!2026/10/01:00:00:00!5!'; ExeName = 'delta.exe'; Target = (New-TestTarget 'Contoso Delta'); Classification = (New-TestClassification 'ps-ignore-1') }
        $unmatched = New-TestEntry @{ ExeInfo = '!!delta2.exe!2026/10/01:00:00:00!6!'; ExeName = 'delta2.exe'; Target = (New-TestUnresolved @('Contoso Delta', 'Contoso Gamma')) }
        (Get-AUKnownExes $script:KnownApps @{} $null @($ignored, $unmatched)).Count | Should -Be 0
    }

    It 'lists a Store package entry by its ExeInfo' {
        $family = 'Contoso.Notes_8wekyb3d8bbwe'
        $apps = @((New-TestApp 'Contoso Notes' 'Contoso' @{ PackageFamily = $family }))
        $entry = New-TestEntry @{ ExeInfo = 'Contoso.Notes_1.2.3.0_x64__8wekyb3d8bbwe'; ExeName = $null; Target = (New-TestTarget 'Contoso Notes' @{ PackageFamily = $family }) }
        @((Get-AUKnownExes $apps @{} $null @($entry))['Contoso Notes']) | Should -Be @('contoso.notes_1.2.3.0_x64__8wekyb3d8bbwe')
    }
}

Describe 'ConvertTo-AUExeUsage (D30, D31, F25, F26)' {
    It 'gives one entry per exe build and target, with users combined' {
        $entries = @(
            (New-TestUsedEntry $script:Yesterday @{ FirstSeen = $script:Watching })
            (New-TestUsedEntry $script:Today @{ UserSid = $script:UserB; UserType = 'Domain'; FirstSeen = $script:Yesterday })
        )
        $out = @(ConvertTo-AUExeUsage $entries)
        $out.Count | Should -Be 1
        $out[0].UsersWithUse | Should -Be 2
        $out[0].InFocusSeconds | Should -Be 240
        $out[0].FirstSeen | Should -BeExactly '2026-10-01T00:00:00.0000000Z'
        $out[0].LastUsedTime | Should -BeExactly '2026-11-21T09:45:12.0000000Z'
        $out[0].LastRanTime | Should -BeExactly '2026-11-21T09:45:12.0000000Z'
        $out[0].RanAsSystemOnly | Should -BeFalse
        $out[0].ExeName | Should -BeExactly 'alpha.exe'
        $out[0].ResolvedAppName | Should -BeExactly 'Contoso Alpha'
        $out[0].Publisher | Should -BeExactly 'Contoso'
        $out[0].MatchSection | Should -BeExactly 'PowerStacks'
        $out[0].MatchRuleId | Should -BeExactly 'ps-contoso-1'
        $out[0].FileVersion | Should -BeExactly '1.0.0.0'
    }

    It 'carries the spec''s per-executable fields in order, and no CandidateTargets on a resolved exe' {
        $out = @(ConvertTo-AUExeUsage @((New-TestEntry)))
        @($out[0].PSObject.Properties.Name) | Should -Be $script:ExeFields
    }

    It 'keeps separate entries for the same build with different targets' {
        $entries = @(
            (New-TestEntry)
            (New-TestEntry @{ UserSid = $script:UserB; Target = (New-TestTarget 'Contoso Alpha (User)') })
        )
        @(ConvertTo-AUExeUsage $entries).Count | Should -Be 2
    }

    It 'gives install status <Expected> for users with <First> and <Second>' -ForEach @(
        @{ First = 'Installed'; Second = 'NotInstalled'; Expected = 'Installed' }
        @{ First = 'NotInstalled'; Second = 'Installed'; Expected = 'Installed' }
        @{ First = 'Unknown'; Second = 'NotInstalled'; Expected = 'Unknown' }
        @{ First = 'Installed'; Second = 'Unknown'; Expected = 'Installed' }
        @{ First = 'NotInstalled'; Second = 'NotInstalled'; Expected = 'NotInstalled' }
    ) {
        $entries = @(
            (New-TestEntry @{ InstallStatus = $First })
            (New-TestEntry @{ UserSid = $script:UserB; InstallStatus = $Second })
        )
        (ConvertTo-AUExeUsage $entries)[0].InstallStatus | Should -BeExactly $Expected
    }

    It 'is Unmatched only when there is no target' {
        $out = @(ConvertTo-AUExeUsage @((New-TestEntry @{ Target = (New-TestUnresolved); InstallStatus = 'Unmatched'; Role = 'Unmatched' })))
        $out[0].InstallStatus | Should -BeExactly 'Unmatched'
        $out[0].MatchSection | Should -BeExactly 'None'
        $out[0].ResolvedAppName | Should -BeNullOrEmpty
    }

    It 'carries CandidateTargets as an array of both DisplayNames on an ambiguous exe' {
        $entry = New-TestEntry @{ Target = (New-TestUnresolved @('Contoso Viewer', 'Contoso Viewer Pro')); InstallStatus = 'Unmatched'; Role = 'Unmatched' }
        $out = (ConvertTo-AUExeUsage @($entry))[0]
        @($out.PSObject.Properties.Name) | Should -Be ($script:ExeFields + 'CandidateTargets')
        , $out.CandidateTargets | Should -BeOfType [string[]]
        $out.CandidateTargets | Should -Be @('Contoso Viewer', 'Contoso Viewer Pro')
        $json = ConvertTo-Json @($out) -Depth 5 -Compress
        $json | Should -Match '"CandidateTargets":\["Contoso Viewer","Contoso Viewer Pro"\]'
    }

    It 'has no CandidateTargets on an unresolved exe with fewer than two candidates' {
        $entry = New-TestEntry @{ Target = (New-TestUnresolved @('Contoso Viewer')); InstallStatus = 'Unmatched'; Role = 'Unmatched' }
        (ConvertTo-AUExeUsage @($entry))[0].PSObject.Properties.Name | Should -Not -Contain 'CandidateTargets'
    }

    It 'marks a build run only by SYSTEM as RanAsSystemOnly, with no use' {
        $entry = New-TestEntry @{ UserSid = $script:SystemSid; UserType = 'System'; LastFocusOrInputTime = $script:Today; LastRanTime = $script:Today }
        $out = (ConvertTo-AUExeUsage @($entry))[0]
        $out.RanAsSystemOnly | Should -BeTrue
        $out.LastUsedTime | Should -BeNullOrEmpty
        $out.UsersWithUse | Should -Be 0
        $out.InFocusSeconds | Should -Be 0
    }

    It 'is RanAsSystemOnly <Expected> for runs by <Types>' -ForEach @(
        @{ Types = @('System', 'Service'); Expected = $true }
        @{ Types = @('Service'); Expected = $true }
        @{ Types = @('Unknown'); Expected = $false }
        @{ Types = @('System', 'Unknown'); Expected = $false }
        @{ Types = @('System', 'CloudOnly'); Expected = $false }
    ) {
        $i = 0
        $entries = @(foreach ($Type in $Types) { $i++; New-TestEntry @{ UserSid = "S-1-5-21-9-9-9-$i"; UserType = $Type; LastRanTime = $script:Today } })
        (ConvertTo-AUExeUsage $entries)[0].RanAsSystemOnly | Should -Be $Expected
    }

    It 'is not RanAsSystemOnly when it never ran' {
        (ConvertTo-AUExeUsage @((New-TestEntry @{ UserSid = $script:SystemSid; UserType = 'System' })))[0].RanAsSystemOnly | Should -BeFalse
    }

    It 'labels unverified identity evidence and blanks the build-specific facts' {
        $facts = New-TestFacts @{ FactsVerified = $false; FileVersion = '9.9'; FileCompanyName = 'Wrong'; PathEvidence = [pscustomobject]@{ CompanyName = 'Google LLC'; ProductName = 'Google Chrome' } }
        $out = (ConvertTo-AUExeUsage @((New-TestEntry @{ Facts = $facts; FactsVerified = $false })))[0]
        $out.FactsVerified | Should -BeFalse
        $out.EvidenceCompanyName | Should -BeExactly 'Google LLC'
        $out.EvidenceProductName | Should -BeExactly 'Google Chrome'
        $out.EvidenceSource | Should -BeExactly 'CurrentFileAtPath'
        foreach ($Field in @('FileDescription', 'FileProductName', 'FileCompanyName', 'FileVersion', 'ProductVersion')) { $out.$Field | Should -BeNullOrEmpty -Because $Field }
        $out.RunPath | Should -BeExactly 'C:\Program Files\Contoso\Alpha\alpha.exe'
    }

    It 'has no evidence fields on a verified build' {
        $out = (ConvertTo-AUExeUsage @((New-TestEntry)))[0]
        $out.EvidenceSource | Should -BeNullOrEmpty
        $out.EvidenceCompanyName | Should -BeNullOrEmpty
    }

    It 'keeps unmatched entries, entries with a Retained target, and NotInstalled entries' {
        $entries = @(
            (New-TestEntry @{ ExeInfo = '!!one.exe!2026/10/01:00:00:00!1!'; ExeName = 'one.exe'; Target = (New-TestUnresolved); InstallStatus = 'Unmatched'; Role = 'Unmatched' })
            (New-TestEntry @{ ExeInfo = '!!two.exe!2026/10/01:00:00:00!2!'; ExeName = 'two.exe'; Target = (New-TestTarget 'Contoso Two' @{ MatchSection = 'Retained'; RetainedFrom = 'Customer'; MatchRuleId = 'c-two-1' }); InstallStatus = 'Installed' })
            (New-TestEntry @{ ExeInfo = '!!visio.exe!2026/05/02:01:00:00!55aa1!'; ExeName = 'visio.exe'; Target = (New-TestTarget 'Microsoft Visio - en-us' @{ MatchSection = 'Customer'; MatchRuleId = 'c-visio-1' }); InstallStatus = 'NotInstalled' })
        )
        $out = @(ConvertTo-AUExeUsage $entries)
        $out.Count | Should -Be 3
        ($out | Where-Object ExeName -EQ 'one.exe').InstallStatus | Should -BeExactly 'Unmatched'
        ($out | Where-Object ExeName -EQ 'two.exe').MatchSection | Should -BeExactly 'Retained'
        ($out | Where-Object ExeName -EQ 'visio.exe').InstallStatus | Should -BeExactly 'NotInstalled'
        ($out | Where-Object ExeName -EQ 'visio.exe').ResolvedAppName | Should -BeExactly 'Microsoft Visio - en-us'
    }

    It 'keeps a Store package entry with ExeName blank and the package family as ProductCode' {
        $family = 'Contoso.Notes_8wekyb3d8bbwe'
        $entry = New-TestEntry @{ ExeInfo = 'Contoso.Notes_1.2.3.0_x64__8wekyb3d8bbwe'; ExeName = $null; Facts = (New-TestFacts @{ ExeName = $null; RunPath = $null; PackageFamily = $family }); Target = (New-TestTarget 'Contoso Notes' @{ PackageFamily = $family }) }
        $out = (ConvertTo-AUExeUsage @($entry))[0]
        $out.ExeName | Should -BeNullOrEmpty
        $out.ExeInfo | Should -BeExactly 'Contoso.Notes_1.2.3.0_x64__8wekyb3d8bbwe'
        $out.ProductCode | Should -BeExactly $family
    }

    It 'returns nothing for no entries' {
        @(ConvertTo-AUExeUsage @()).Count | Should -Be 0
    }
}

Describe 'No user identity in the output (D19, D31)' {
    It 'has no user SID, UPN, or scope in any key or field' {
        $apps = @((New-TestApp 'Contoso Alpha' 'Contoso' @{ Scope = $script:UserA }), (New-TestApp 'Contoso Viewer'), (New-TestApp 'Contoso Viewer Pro'))
        $facts = New-TestFacts @{ RunPath = 'C:\Program Files\Contoso\Alpha\alpha.exe'; UserSid = $script:UserA }
        $entries = @(
            (New-TestUsedEntry $script:Yesterday @{ Facts = $facts })
            (New-TestUsedEntry $script:Today @{ UserSid = $script:UserB; UserType = 'Domain' })
            (New-TestEntry @{ UserSid = $script:SystemSid; UserType = 'System'; LastRanTime = $script:Today })
            (New-TestUsedEntry $script:Today @{ ExeInfo = '!!viewer.exe!2026/08/01:00:00:00!bbbb2!'; ExeName = 'viewer.exe'; Target = (New-TestUnresolved @('Contoso Viewer', 'Contoso Viewer Pro')); InstallStatus = 'Unmatched'; Role = 'Unmatched' })
        )
        $appUsage = Invoke-TestAppUsage -Entries $entries -Apps $apps
        $exeUsage = @(ConvertTo-AUExeUsage $entries)
        $json = (ConvertTo-Json @($appUsage) -Depth 6 -Compress) + (ConvertTo-Json $exeUsage -Depth 6 -Compress)
        foreach ($Sid in @($script:UserA, $script:UserB, $script:SystemSid)) { $json.Contains($Sid) | Should -BeFalse -Because $Sid }
        $json | Should -Not -Match 'S-1-\d'
        $json | Should -Not -Match '@'
        $names = @($appUsage.Keys) + @($appUsage.Values | ForEach-Object { $_.PSObject.Properties.Name }) + @($exeUsage | ForEach-Object { $_.PSObject.Properties.Name })
        foreach ($Bad in @('UserSid', 'Scope', 'AppScope', 'Upn', 'UserPrincipalName', 'AppLastUsedBy', 'LastUsedBy', 'ProfilePath'))
        {
            $names | Should -Not -Contain $Bad
        }
    }
}
