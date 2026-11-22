BeforeAll {
    # A silent logger with the real one's parameters, so tests can check what was logged with a ParameterFilter.
    function Write-CMTraceLog { param ([string]$Message, [string]$Component, [int]$Type) }
    . "$PSScriptRoot\_Import.ps1"

    $script:TestSid = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
    $script:MappingsCount = 0

    # Facts in exactly the Task 14 shape. Verified by default; pass overrides as a hashtable.
    function New-TestFacts([hashtable]$Values = @{})
    {
        $Facts = [ordered]@{
            ExeName         = 'tool.exe'
            RunPath         = $null
            LocationClass   = 'Other'
            FileDescription = $null
            FileProductName = $null
            FileCompanyName = $null
            FileVersion     = $null
            ProductVersion  = $null
            FactsVerified   = $true
            Subsystem       = 'GUI'
            MsiProductCode  = $null
            PackageFamily   = $null
            IsServiceBinary = $false
            UserSid         = $script:TestSid
            PathEvidence    = $null
        }
        foreach ($Key in $Values.Keys) { $Facts[$Key] = $Values[$Key] }
        return [pscustomobject]$Facts
    }

    # An unverified build whose current file at the same path has this CompanyName and ProductName (D30).
    function New-TestUnverifiedFacts([string]$Company, [string]$Product, [hashtable]$Values = @{})
    {
        $All = @{ FactsVerified = $false; PathEvidence = [pscustomobject]@{ CompanyName = $Company; ProductName = $Product } }
        foreach ($Key in $Values.Keys) { $All[$Key] = $Values[$Key] }
        return New-TestFacts $All
    }

    # An installed-app entry in the Task 13 shape. Machine scope by default.
    function New-TestApp([string]$Name, [string]$Publisher, [hashtable]$Values = @{})
    {
        $App = [ordered]@{
            DisplayName     = $Name
            Publisher       = $Publisher
            DisplayVersion  = $null
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

    # The whole Get-AUMappings result, built from rule JSON texts through the real loader and validator.
    function New-TestMappings([string[]]$Customer = @(), [string[]]$PowerStacks = @())
    {
        $script:MappingsCount++
        $Dir = Join-Path 'TestDrive:\' "mappings$($script:MappingsCount)"
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $Dir = (Resolve-Path $Dir).ProviderPath

        $Split = {
            param ([string[]]$Rules)
            $Identity = @(); $Classification = @()
            foreach ($Text in $Rules)
            {
                if (($Text | ConvertFrom-Json).type -in @('classification', 'ignore')) { $Classification += $Text } else { $Identity += $Text }
            }
            return '{ "identityRules": [' + ($Identity -join ',') + '], "classificationRules": [' + ($Classification -join ',') + '] }'
        }
        $Ours = (& $Split $PowerStacks).Insert(1, ' "version": "test",')
        [IO.File]::WriteAllText((Join-Path $Dir 'powerstacks-mappings.json'), '{ "schemaVersion": 1, "powerStacks": ' + $Ours + ' }')
        $CustomerPath = Join-Path $Dir 'customer-mappings.json'
        if ($Customer.Count -gt 0)
        {
            [IO.File]::WriteAllText($CustomerPath, '{ "schemaVersion": 1, "customer": ' + (& $Split $Customer) + ' }')
        }
        $Result = Get-AUMappings -Embedded '' -BesideDir $Dir -CustomerPath $CustomerPath
        if ($Result.Errors.Count -gt 0) { throw "Test mappings are invalid: $($Result.Errors -join ' | ')" }
        return $Result
    }

    # Rules used across tests.
    $script:RuleOwnMsi = '{ "id": "ps-own-msi", "type": "ownership", "source": "msi" }'
    $script:RuleOwnStore = '{ "id": "ps-own-store", "type": "ownership", "source": "store" }'
    $script:RuleArp = '{ "id": "ps-arp-compare", "type": "arpCompare" }'
    $script:RuleContoso = '{ "id": "ps-contoso-1", "type": "identity", "when": { "exeName": "tool.exe", "publisher": "Contoso*" }, "target": { "displayName": "Contoso*", "publisher": "Contoso*" } }'
}

Describe 'Get-AULocationClass' {
    It 'returns <Expected> for <Path>' -ForEach @(
        @{ Path = 'C:\Windows\IMECache\abc\install.exe'; Expected = 'ManagementCache' }
        @{ Path = 'C:\Windows\ccmcache\1a\setup.exe'; Expected = 'ManagementCache' }
        @{ Path = 'C:\Program Files (x86)\Microsoft Intune Management Extension\Content\Staging\x\setup.exe'; Expected = 'ManagementCache' }
        @{ Path = 'C:\Windows\System32\notepad.exe'; Expected = 'Windows' }
        @{ Path = 'C:\Program Files\7-Zip\7zFM.exe'; Expected = 'ProgramFiles' }
        @{ Path = 'C:\Program Files (x86)\Contoso\tool.exe'; Expected = 'ProgramFiles' }
        @{ Path = 'C:\Users\a\AppData\Local\Programs\app\app.exe'; Expected = 'UserProfile' }
        @{ Path = 'C:\Users\a\AppData\Local\Temp\x\setup.exe'; Expected = 'Temp' }
        @{ Path = 'C:\Windows\Temp\setup.exe'; Expected = 'Temp' }
        @{ Path = 'C:\Users\a\Downloads\setup.exe'; Expected = 'Download' }
        @{ Path = 'D:\Tools\tool.exe'; Expected = 'Other' }
        @{ Path = ''; Expected = 'Other' }
    ) {
        Get-AULocationClass $Path | Should -BeExactly $Expected
    }

    It 'is case-insensitive' {
        Get-AULocationClass 'c:\windows\imecache\ABC\Install.exe' | Should -BeExactly 'ManagementCache'
        Get-AULocationClass 'c:\PROGRAM FILES\x\y.exe' | Should -BeExactly 'ProgramFiles'
    }
}

Describe 'Resolve-AUIdentity' {
    Context 'Customer rules always win (D38)' {
        It 'a customer identity rule beats a PowerStacks identity rule' {
            $m = New-TestMappings -Customer @('{ "id": "c-tool-1", "type": "identity", "when": { "exeName": "tool.exe", "publisher": "Contoso*" }, "target": { "displayName": "Contoso Beta*", "publisher": "*" } }') -PowerStacks @('{ "id": "ps-tool-1", "type": "identity", "when": { "exeName": "tool.exe", "publisher": "Contoso*" }, "target": { "displayName": "Contoso Alpha*", "publisher": "*" } }')
            $apps = @((New-TestApp 'Contoso Alpha' 'Contoso'), (New-TestApp 'Contoso Beta' 'Contoso'))
            $r = Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = 'Contoso' }) $m $apps
            $r.MatchSection | Should -BeExactly 'Customer'
            $r.MatchRuleId | Should -BeExactly 'c-tool-1'
            $r.ResolvedAppName | Should -BeExactly 'Contoso Beta'
        }

        It 'a customer identity rule beats a PowerStacks ownership and arpCompare match for the same exe' {
            $m = New-TestMappings -Customer @('{ "id": "c-tool-1", "type": "identity", "when": { "exeName": "tool.exe", "publisher": "Contoso" }, "target": { "displayName": "Contoso Beta", "publisher": "Contoso" } }') -PowerStacks @($script:RuleOwnMsi, $script:RuleArp)
            $apps = @((New-TestApp 'Contoso Alpha' 'Contoso' @{ ProductCode = '{AAAAAAAA-0000-0000-0000-000000000001}' }), (New-TestApp 'Contoso Beta' 'Contoso'))
            $facts = New-TestFacts @{ FileCompanyName = 'Contoso'; FileProductName = 'Contoso Alpha'; MsiProductCode = '{AAAAAAAA-0000-0000-0000-000000000001}' }
            $r = Resolve-AUIdentity $facts $m $apps
            $r.MatchSection | Should -BeExactly 'Customer'
            $r.MatchRuleId | Should -BeExactly 'c-tool-1'
            $r.RuleType | Should -BeExactly 'identity'
            $r.InstalledStateDependent | Should -BeFalse
        }

        It 'evidence matching two PowerStacks targets plus a customer rule resolves to the customer rule, with no CandidateTargets' {
            $m = New-TestMappings -Customer @('{ "id": "c-zoom-1", "type": "identity", "when": { "exeName": "zoom.exe", "publisher": "Zoom*" }, "target": { "displayName": "Zoom Workplace (64-bit)", "publisher": "Zoom*" } }') -PowerStacks @($script:RuleArp)
            $apps = @((New-TestApp 'Zoom Workplace (64-bit)' 'Zoom Communications, Inc.'), (New-TestApp 'Zoom Workplace (32-bit)' 'Zoom Communications, Inc.'))
            $r = Resolve-AUIdentity (New-TestUnverifiedFacts 'Zoom Communications, Inc.' 'Zoom Workplace' @{ ExeName = 'zoom.exe' }) $m $apps
            $r.MatchSection | Should -BeExactly 'Customer'
            $r.MatchRuleId | Should -BeExactly 'c-zoom-1'
            $r.ResolvedAppName | Should -BeExactly 'Zoom Workplace (64-bit)'
            $r.CandidateTargets | Should -BeNullOrEmpty
            $r.EvidenceUsed | Should -BeExactly 'CurrentFileAtPath'
        }

        It 'a customer rule with versionMin does not match unverified evidence, and matching falls through to PowerStacks rules (D30)' {
            $m = New-TestMappings -Customer @('{ "id": "c-chrome-1", "type": "identity", "when": { "exeName": "chrome.exe", "publisher": "Google LLC", "versionMin": "100" }, "target": { "displayName": "Chrome Pinned", "publisher": "*" } }') -PowerStacks @('{ "id": "ps-chrome-1", "type": "identity", "when": { "exeName": "chrome.exe", "publisher": "Google LLC" }, "target": { "displayName": "Google Chrome", "publisher": "Google LLC" } }')
            $r = Resolve-AUIdentity (New-TestUnverifiedFacts 'Google LLC' 'Google Chrome' @{ ExeName = 'chrome.exe'; FileVersion = '120.0.1'; ProductVersion = '120.0.1' }) $m @()
            $r.MatchSection | Should -BeExactly 'PowerStacks'
            $r.MatchRuleId | Should -BeExactly 'ps-chrome-1'
        }
    }

    It 'within a section, the first match in file order wins (F12)' {
        $m = New-TestMappings -Customer @(
            '{ "id": "c-first", "type": "identity", "when": { "exeName": "tool.exe", "publisher": "*" }, "target": { "displayName": "First App", "publisher": "*" } }',
            '{ "id": "c-second", "type": "identity", "when": { "exeName": "tool*.exe", "publisher": "Contoso" }, "target": { "displayName": "Second App", "publisher": "*" } }')
        $r = Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = 'Contoso' }) $m @()
        $r.MatchRuleId | Should -BeExactly 'c-first'
        $r.TargetPattern | Should -BeExactly 'First App'
    }

    Context 'Candidates come from the winning rule (F12)' {
        It 'one rule whose target matches two installed apps gives two candidates for D47, which picks one' {
            $m = New-TestMappings -PowerStacks @($script:RuleContoso)
            $apps = @((New-TestApp 'Contoso Alpha' 'Contoso' @{ InstallLocation = 'C:\Apps\Alpha' }), (New-TestApp 'Contoso Beta' 'Contoso' @{ InstallLocation = 'C:\Apps\Beta' }))
            $r = Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = 'Contoso'; RunPath = 'C:\Apps\Beta\tool.exe' }) $m $apps
            $r.MatchSection | Should -BeExactly 'PowerStacks'
            $r.MatchRuleId | Should -BeExactly 'ps-resolve-path'
            $r.RuleType | Should -BeExactly 'identity'
            $r.TargetPattern | Should -BeExactly 'Contoso*'
            $r.ResolvedAppName | Should -BeExactly 'Contoso Beta'
            $r.CandidateTargets | Should -BeNullOrEmpty
        }

        It 'with two candidates that no step separates, the exe stays unresolved and both are CandidateTargets' {
            $m = New-TestMappings -PowerStacks @($script:RuleContoso)
            $apps = @((New-TestApp 'Contoso Alpha' 'Contoso'), (New-TestApp 'Contoso Beta' 'Contoso'))
            $r = Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = 'Contoso' }) $m $apps
            $r.MatchSection | Should -BeExactly 'None'
            $r.MatchRuleId | Should -BeNullOrEmpty
            $r.TargetPattern | Should -BeNullOrEmpty
            @($r.CandidateTargets) | Should -Be @('Contoso Alpha', 'Contoso Beta')
        }

        It 'with neither installed, ResolvedAppName is $null and no CandidateTargets is set' {
            $m = New-TestMappings -PowerStacks @($script:RuleContoso)
            $r = Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = 'Contoso' }) $m @((New-TestApp 'Fabrikam Designer' 'Fabrikam'))
            $r.MatchSection | Should -BeExactly 'PowerStacks'
            $r.TargetPattern | Should -BeExactly 'Contoso*'
            $r.ResolvedAppName | Should -BeNullOrEmpty
            $r.CandidateTargets | Should -BeNullOrEmpty
        }

        It 'two candidates with the same DisplayName resolve to that DisplayName' {
            $m = New-TestMappings -PowerStacks @($script:RuleContoso)
            $apps = @((New-TestApp 'Contoso Alpha' 'Contoso'), (New-TestApp 'Contoso Alpha' 'Contoso' @{ Scope = $script:TestSid }))
            $r = Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = 'Contoso' }) $m $apps
            $r.MatchSection | Should -BeExactly 'PowerStacks'
            $r.MatchRuleId | Should -BeExactly 'ps-contoso-1'
            $r.ResolvedAppName | Should -BeExactly 'Contoso Alpha'
            $r.CandidateTargets | Should -BeNullOrEmpty
        }
    }

    Context 'Empty publisher (F14)' {
        BeforeAll {
            $script:EmptyPublisher = New-TestMappings -Customer @('{ "id": "c-inhouse-1", "type": "identity", "when": { "exeName": "tool.exe", "publisher": "" }, "target": { "displayName": "In-House Tool", "publisher": "" } }')
        }

        It 'matches verified facts with an empty CompanyName' {
            (Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = '' }) $script:EmptyPublisher @()).MatchRuleId | Should -BeExactly 'c-inhouse-1'
            (Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = $null }) $script:EmptyPublisher @()).MatchRuleId | Should -BeExactly 'c-inhouse-1'
        }

        It 'matches unverified facts whose current file has an empty CompanyName' {
            (Resolve-AUIdentity (New-TestUnverifiedFacts '' 'Tool') $script:EmptyPublisher @()).MatchRuleId | Should -BeExactly 'c-inhouse-1'
        }

        It 'does not match unverified facts with no PathEvidence (publisher unknown)' {
            $r = Resolve-AUIdentity (New-TestFacts @{ FactsVerified = $false }) $script:EmptyPublisher @()
            $r.MatchSection | Should -BeExactly 'None'
            $r.EvidenceUsed | Should -BeExactly 'None'
        }

        It 'does not match a known, non-empty CompanyName' {
            (Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = 'Contoso' }) $script:EmptyPublisher @()).MatchSection | Should -BeExactly 'None'
        }

        It 'an empty target publisher matches an installed app with no publisher' {
            $r = Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = '' }) $script:EmptyPublisher @((New-TestApp 'In-House Tool' $null))
            $r.ResolvedAppName | Should -BeExactly 'In-House Tool'
        }
    }

    It 'target "7-Zip*" matches the installed "7-Zip 24.08 (x64)"' {
        $m = New-TestMappings -PowerStacks @('{ "id": "ps-7zip-1", "type": "identity", "when": { "exeName": "7zfm.exe", "publisher": "Igor Pavlov" }, "target": { "displayName": "7-Zip*", "publisher": "Igor Pavlov" } }')
        $r = Resolve-AUIdentity (New-TestFacts @{ ExeName = '7zfm.exe'; FileCompanyName = 'Igor Pavlov' }) $m @((New-TestApp '7-Zip 24.08 (x64)' 'Igor Pavlov' @{ DisplayVersion = '24.08' }))
        $r.MatchSection | Should -BeExactly 'PowerStacks'
        $r.TargetPattern | Should -BeExactly '7-Zip*'
        $r.TargetPublisher | Should -BeExactly 'Igor Pavlov'
        $r.ResolvedAppName | Should -BeExactly '7-Zip 24.08 (x64)'
        $r.EvidenceUsed | Should -BeExactly 'Verified'
        $r.InstalledStateDependent | Should -BeFalse
    }

    It 'an identity rule still resolves when the app is not installed' {
        $m = New-TestMappings -Customer @('{ "id": "c-timesheets-1", "type": "identity", "when": { "exeName": "tool.exe", "publisher": "Contoso" }, "target": { "displayName": "Contoso Timesheets*", "publisher": "Contoso" } }')
        $r = Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = 'Contoso' }) $m @()
        $r.MatchSection | Should -BeExactly 'Customer'
        $r.TargetPattern | Should -BeExactly 'Contoso Timesheets*'
        $r.ResolvedAppName | Should -BeNullOrEmpty
    }

    It 'an ownership msi rule maps MsiProductCode to the app with that ProductCode' {
        $m = New-TestMappings -PowerStacks @($script:RuleOwnMsi, $script:RuleArp)
        $apps = @((New-TestApp 'Contoso Alpha' 'Contoso' @{ ProductCode = '{AAAAAAAA-0000-0000-0000-000000000001}' }), (New-TestApp 'Contoso Beta [Preview]' 'Contoso' @{ ProductCode = '{BBBBBBBB-0000-0000-0000-000000000002}' }))
        $r = Resolve-AUIdentity (New-TestFacts @{ MsiProductCode = '{bbbbbbbb-0000-0000-0000-000000000002}' }) $m $apps
        $r.MatchSection | Should -BeExactly 'PowerStacks'
        $r.MatchRuleId | Should -BeExactly 'ps-own-msi'
        $r.RuleType | Should -BeExactly 'ownership'
        $r.InstalledStateDependent | Should -BeTrue
        $r.ResolvedAppName | Should -BeExactly 'Contoso Beta [Preview]'
        $r.ProductCode | Should -BeExactly '{BBBBBBBB-0000-0000-0000-000000000002}'
        $r.EvidenceUsed | Should -BeExactly 'Verified'
        # The target is a pattern that matches exactly this DisplayName.
        ('Contoso Beta [Preview]' -like $r.TargetPattern) | Should -BeTrue
        ('Contoso Beta P' -like $r.TargetPattern) | Should -BeFalse
    }

    It 'an ownership msi rule does not match when no installed app has the ProductCode' {
        $m = New-TestMappings -PowerStacks @($script:RuleOwnMsi)
        $r = Resolve-AUIdentity (New-TestFacts @{ MsiProductCode = '{CCCCCCCC-0000-0000-0000-000000000003}' }) $m @((New-TestApp 'Contoso Alpha' 'Contoso' @{ ProductCode = '{AAAAAAAA-0000-0000-0000-000000000001}' }))
        $r.MatchSection | Should -BeExactly 'None'
    }

    It 'an ownership store rule maps PackageFamily to the installed package' {
        $m = New-TestMappings -PowerStacks @($script:RuleOwnStore)
        $apps = @((New-TestApp 'Contoso Notes' 'Contoso' @{ PackageFamily = 'Contoso.Notes_8wekyb3d8bbwe' }))
        $r = Resolve-AUIdentity (New-TestFacts @{ ExeName = $null; PackageFamily = 'contoso.notes_8wekyb3d8bbwe' }) $m $apps
        $r.MatchRuleId | Should -BeExactly 'ps-own-store'
        $r.ResolvedAppName | Should -BeExactly 'Contoso Notes'
        $r.PackageFamily | Should -BeExactly 'Contoso.Notes_8wekyb3d8bbwe'
        $r.InstalledStateDependent | Should -BeTrue
    }

    Context 'arpCompare' {
        It 'matches "Zoom Workplace" / "Zoom Communications, Inc." to "Zoom Workplace (64-bit)" / "Zoom Communications, Inc."' {
            $m = New-TestMappings -PowerStacks @($script:RuleArp)
            $apps = @((New-TestApp 'Zoom Workplace (64-bit)' 'Zoom Communications, Inc.'), (New-TestApp 'Contoso Alpha' 'Contoso'))
            $r = Resolve-AUIdentity (New-TestFacts @{ ExeName = 'zoom.exe'; FileProductName = 'Zoom Workplace'; FileCompanyName = 'Zoom Communications, Inc.' }) $m $apps
            $r.MatchSection | Should -BeExactly 'PowerStacks'
            $r.MatchRuleId | Should -BeExactly 'ps-arp-compare'
            $r.RuleType | Should -BeExactly 'arpCompare'
            $r.InstalledStateDependent | Should -BeTrue
            $r.ResolvedAppName | Should -BeExactly 'Zoom Workplace (64-bit)'
            $r.TargetPublisher | Should -BeExactly 'Zoom Communications, Inc.'
        }

        It 'matches on FileDescription when ProductName differs, and ignores legal suffixes and versions' {
            $m = New-TestMappings -PowerStacks @($script:RuleArp)
            $r = Resolve-AUIdentity (New-TestFacts @{ FileProductName = 'Contoso Suite'; FileDescription = 'Contoso Viewer'; FileCompanyName = 'Contoso Corporation' }) $m @((New-TestApp 'Contoso Viewer 2.4.1 x64' 'Contoso, Inc.'))
            $r.ResolvedAppName | Should -BeExactly 'Contoso Viewer 2.4.1 x64'
        }

        It 'does not match when the publishers disagree' {
            $m = New-TestMappings -PowerStacks @($script:RuleArp)
            $r = Resolve-AUIdentity (New-TestFacts @{ ExeName = 'zoom.exe'; FileProductName = 'Zoom Workplace'; FileCompanyName = 'Fabrikam Ltd.' }) $m @((New-TestApp 'Zoom Workplace (64-bit)' 'Zoom Communications, Inc.'))
            $r.MatchSection | Should -BeExactly 'None'
        }
    }

    It 'with no rule, MatchSection is None' {
        $r = Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = 'Contoso' }) (New-TestMappings) @((New-TestApp 'Contoso Alpha' 'Contoso'))
        $r.MatchSection | Should -BeExactly 'None'
        $r.MatchRuleId | Should -BeNullOrEmpty
        $r.RuleType | Should -BeNullOrEmpty
        $r.TargetPattern | Should -BeNullOrEmpty
        $r.ResolvedAppName | Should -BeNullOrEmpty
        $r.EvidenceUsed | Should -BeExactly 'None'
        $r.InstalledStateDependent | Should -BeFalse
        $r.CandidateTargets | Should -BeNullOrEmpty
    }

    It 'returns every contract field' {
        $r = Resolve-AUIdentity (New-TestFacts) (New-TestMappings) @()
        $Names = $r.PSObject.Properties.Name
        foreach ($Name in @('TargetPattern', 'TargetPublisher', 'ResolvedAppName', 'ProductCode', 'PackageFamily', 'MatchSection', 'MatchRuleId', 'RuleType', 'InstalledStateDependent', 'EvidenceUsed', 'CandidateTargets'))
        {
            $Names | Should -Contain $Name
        }
    }

    Context 'Unverified evidence (D30)' {
        BeforeAll {
            $script:ChromeRule = '{ "id": "ps-chrome-1", "type": "identity", "when": { "exeName": "chrome.exe", "publisher": "Google LLC" }, "target": { "displayName": "Google Chrome", "publisher": "Google LLC" } }'
        }

        It 'PathEvidence Google LLC / Google Chrome satisfies { exeName: chrome.exe, publisher: Google LLC }' {
            $m = New-TestMappings -PowerStacks @($script:ChromeRule)
            $r = Resolve-AUIdentity (New-TestUnverifiedFacts 'Google LLC' 'Google Chrome' @{ ExeName = 'chrome.exe' }) $m @((New-TestApp 'Google Chrome' 'Google LLC'))
            $r.MatchSection | Should -BeExactly 'PowerStacks'
            $r.MatchRuleId | Should -BeExactly 'ps-chrome-1'
            $r.EvidenceUsed | Should -BeExactly 'CurrentFileAtPath'
            $r.ResolvedAppName | Should -BeExactly 'Google Chrome'
        }

        It 'the same evidence does not satisfy a rule that also has versionMin' {
            $m = New-TestMappings -PowerStacks @('{ "id": "ps-chrome-1", "type": "identity", "when": { "exeName": "chrome.exe", "publisher": "Google LLC", "versionMin": "1" }, "target": { "displayName": "Google Chrome", "publisher": "Google LLC" } }')
            $r = Resolve-AUIdentity (New-TestUnverifiedFacts 'Google LLC' 'Google Chrome' @{ ExeName = 'chrome.exe' }) $m @((New-TestApp 'Google Chrome' 'Google LLC'))
            $r.MatchSection | Should -BeExactly 'None'
        }

        It 'the same evidence does not satisfy a rule with only versionMax' {
            $m = New-TestMappings -PowerStacks @('{ "id": "ps-chrome-1", "type": "identity", "when": { "exeName": "chrome.exe", "publisher": "Google LLC", "versionMax": "999" }, "target": { "displayName": "Google Chrome", "publisher": "Google LLC" } }')
            (Resolve-AUIdentity (New-TestUnverifiedFacts 'Google LLC' 'Google Chrome' @{ ExeName = 'chrome.exe' }) $m @()).MatchSection | Should -BeExactly 'None'
        }

        It 'a fileDescription condition is not satisfied by PathEvidence, which carries no FileDescription' {
            $m = New-TestMappings -PowerStacks @('{ "id": "ps-chrome-1", "type": "identity", "when": { "exeName": "chrome.exe", "publisher": "Google LLC", "fileDescription": "*" }, "target": { "displayName": "Google Chrome", "publisher": "Google LLC" } }')
            (Resolve-AUIdentity (New-TestUnverifiedFacts 'Google LLC' 'Google Chrome' @{ ExeName = 'chrome.exe' }) $m @()).MatchSection | Should -BeExactly 'None'
        }

        It 'a productName condition is satisfied by PathEvidence' {
            $m = New-TestMappings -PowerStacks @('{ "id": "ps-chrome-1", "type": "identity", "when": { "exeName": "chrome.exe", "publisher": "Google*", "productName": "Google Chrome" }, "target": { "displayName": "Google Chrome", "publisher": "Google LLC" } }')
            (Resolve-AUIdentity (New-TestUnverifiedFacts 'Google LLC' 'Google Chrome' @{ ExeName = 'chrome.exe' }) $m @()).MatchRuleId | Should -BeExactly 'ps-chrome-1'
        }

        It 'evidence that matches two targets, with nothing to tell them apart, returns None with both CandidateTargets' {
            $m = New-TestMappings -PowerStacks @($script:RuleArp)
            $apps = @((New-TestApp 'Zoom Workplace (64-bit)' 'Zoom Communications, Inc.'), (New-TestApp 'Zoom Workplace (32-bit)' 'Zoom Communications, Inc.'))
            $r = Resolve-AUIdentity (New-TestUnverifiedFacts 'Zoom Communications, Inc.' 'Zoom Workplace' @{ ExeName = 'zoom.exe' }) $m $apps
            $r.MatchSection | Should -BeExactly 'None'
            $r.EvidenceUsed | Should -BeExactly 'CurrentFileAtPath'
            @($r.CandidateTargets) | Should -Be @('Zoom Workplace (64-bit)', 'Zoom Workplace (32-bit)')
        }

        It 'verified facts always take precedence over path evidence when both exist' {
            $m = New-TestMappings -PowerStacks @(
                '{ "id": "ps-by-evidence", "type": "identity", "when": { "exeName": "tool.exe", "publisher": "Fabrikam" }, "target": { "displayName": "Fabrikam Tool", "publisher": "*" } }',
                '{ "id": "ps-by-verified", "type": "identity", "when": { "exeName": "tool.exe", "publisher": "Contoso" }, "target": { "displayName": "Contoso Tool", "publisher": "*" } }')
            $facts = New-TestFacts @{ FileCompanyName = 'Contoso'; PathEvidence = [pscustomobject]@{ CompanyName = 'Fabrikam'; ProductName = 'Fabrikam Tool' } }
            $r = Resolve-AUIdentity $facts $m @()
            $r.MatchRuleId | Should -BeExactly 'ps-by-verified'
            $r.EvidenceUsed | Should -BeExactly 'Verified'
        }

        It 'an ownership msi rule does not use an unverified build' {
            $m = New-TestMappings -PowerStacks @($script:RuleOwnMsi)
            $facts = New-TestUnverifiedFacts 'Contoso' 'Contoso Alpha' @{ MsiProductCode = '{AAAAAAAA-0000-0000-0000-000000000001}' }
            $r = Resolve-AUIdentity $facts $m @((New-TestApp 'Contoso Alpha' 'Contoso' @{ ProductCode = '{AAAAAAAA-0000-0000-0000-000000000001}' }))
            $r.MatchSection | Should -BeExactly 'None'
        }
    }

    Context 'Version bounds' {
        It 'version <Version> against min <Min> and max <Max> matches: <Expected>' -ForEach @(
            @{ Version = '8.99.1'; Min = $null; Max = '8.99'; Expected = $true }
            @{ Version = '8.0.0'; Min = '8'; Max = $null; Expected = $true }
            @{ Version = '9.0'; Min = $null; Max = '8.99'; Expected = $false }
            @{ Version = '8.0.5'; Min = '8.1'; Max = $null; Expected = $false }
            @{ Version = '7.9'; Min = '8'; Max = '8.99'; Expected = $false }
            @{ Version = '8.5.2.1'; Min = '8.0'; Max = '8.99'; Expected = $true }
            @{ Version = '8, 5, 0, 1'; Min = '8.5'; Max = '8.5'; Expected = $true }
            @{ Version = 'not a version'; Min = '1'; Max = $null; Expected = $false }
        ) {
            $When = [ordered]@{ exeName = 'tool.exe'; publisher = 'Contoso' }
            if ($Min) { $When.versionMin = $Min }
            if ($Max) { $When.versionMax = $Max }
            $Rule = [ordered]@{ id = 'c-ver-1'; type = 'identity'; when = $When; target = [ordered]@{ displayName = 'Contoso Tool'; publisher = 'Contoso' } }
            $m = New-TestMappings -Customer @(($Rule | ConvertTo-Json -Compress))
            $r = Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = 'Contoso'; FileVersion = $Version }) $m @()
            ($r.MatchSection -eq 'Customer') | Should -Be $Expected
        }

        It 'matches on ProductVersion when FileVersion is out of the range' {
            $m = New-TestMappings -Customer @('{ "id": "c-ver-1", "type": "identity", "when": { "exeName": "tool.exe", "publisher": "Contoso", "versionMin": "8", "versionMax": "8.99" }, "target": { "displayName": "Contoso Tool", "publisher": "Contoso" } }')
            $r = Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = 'Contoso'; FileVersion = '1.0.0.5'; ProductVersion = '8.2' }) $m @()
            $r.MatchSection | Should -BeExactly 'Customer'
        }
    }

    Context 'Resolving candidates (D47)' {
        BeforeAll {
            $script:D47 = New-TestMappings -PowerStacks @($script:RuleContoso)
        }

        It 'install path: the run path is inside one candidate InstallLocation' {
            $apps = @((New-TestApp 'Contoso Alpha' 'Contoso' @{ InstallLocation = 'C:\Apps\Alpha\' }), (New-TestApp 'Contoso Beta' 'Contoso' @{ InstallLocation = 'C:\Apps\Beta' }))
            $r = Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = 'Contoso'; RunPath = 'C:\Apps\Alpha\bin\tool.exe' }) $script:D47 $apps
            $r.MatchRuleId | Should -BeExactly 'ps-resolve-path'
            $r.ResolvedAppName | Should -BeExactly 'Contoso Alpha'
        }

        It 'install path: the deepest folder wins when both contain the run path' {
            $apps = @((New-TestApp 'Contoso Alpha' 'Contoso' @{ InstallLocation = 'C:\Apps\Contoso' }), (New-TestApp 'Contoso Beta' 'Contoso' @{ InstallLocation = 'C:\Apps\Contoso\Beta' }))
            $r = Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = 'Contoso'; RunPath = 'C:\Apps\Contoso\Beta\tool.exe' }) $script:D47 $apps
            $r.MatchRuleId | Should -BeExactly 'ps-resolve-path'
            $r.ResolvedAppName | Should -BeExactly 'Contoso Beta'
        }

        It 'install path: uses the DisplayIcon and UninstallString folders' {
            $apps = @((New-TestApp 'Contoso Alpha' 'Contoso' @{ DisplayIcon = '"C:\Apps\Alpha\alpha.exe",0' }), (New-TestApp 'Contoso Beta' 'Contoso' @{ UninstallString = '"C:\Apps\Beta\uninstall.exe" /S' }))
            $r = Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = 'Contoso'; RunPath = 'C:\Apps\Beta\tool.exe' }) $script:D47 $apps
            $r.MatchRuleId | Should -BeExactly 'ps-resolve-path'
            $r.ResolvedAppName | Should -BeExactly 'Contoso Beta'
            $r = Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = 'Contoso'; RunPath = 'C:\Apps\Alpha\tool.exe' }) $script:D47 $apps
            $r.ResolvedAppName | Should -BeExactly 'Contoso Alpha'
        }

        It 'install path: a folder that only shares a name prefix does not contain the path' {
            $apps = @((New-TestApp 'Contoso Alpha' 'Contoso' @{ InstallLocation = 'C:\Apps\Alpha' }), (New-TestApp 'Contoso Beta' 'Contoso' @{ InstallLocation = 'C:\Apps\Alpha2' }))
            $r = Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = 'Contoso'; RunPath = 'C:\Apps\Alpha2\tool.exe' }) $script:D47 $apps
            $r.ResolvedAppName | Should -BeExactly 'Contoso Beta'
        }

        It 'Windows Installer ownership: the candidate whose ProductCode owns the file' {
            $apps = @((New-TestApp 'Contoso Alpha' 'Contoso' @{ ProductCode = '{AAAAAAAA-0000-0000-0000-000000000001}' }), (New-TestApp 'Contoso Beta' 'Contoso' @{ ProductCode = '{BBBBBBBB-0000-0000-0000-000000000002}' }))
            $r = Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = 'Contoso'; MsiProductCode = '{BBBBBBBB-0000-0000-0000-000000000002}' }) $script:D47 $apps
            $r.MatchRuleId | Should -BeExactly 'ps-resolve-msi'
            $r.ResolvedAppName | Should -BeExactly 'Contoso Beta'
            $r.ProductCode | Should -BeExactly '{BBBBBBBB-0000-0000-0000-000000000002}'
            $r.RuleType | Should -BeExactly 'identity'
        }

        It 'publisher: the candidate whose Publisher equals the CompanyName after normalizing' {
            $apps = @((New-TestApp 'Contoso Alpha' 'Contoso Labs'), (New-TestApp 'Contoso Beta' 'Contoso, Ltd'))
            $r = Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = 'Contoso Ltd.' }) $script:D47 $apps
            $r.MatchRuleId | Should -BeExactly 'ps-resolve-publisher'
            $r.ResolvedAppName | Should -BeExactly 'Contoso Beta'
        }

        It 'product name: the candidate whose DisplayName equals the ProductName after trimming versions and architecture tags' {
            $apps = @((New-TestApp 'Contoso Alpha 2.1 (x64)' 'Contoso'), (New-TestApp 'Contoso Beta' 'Contoso'))
            $r = Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = 'Contoso'; FileProductName = 'Contoso Alpha' }) $script:D47 $apps
            $r.MatchRuleId | Should -BeExactly 'ps-resolve-product'
            $r.ResolvedAppName | Should -BeExactly 'Contoso Alpha 2.1 (x64)'
        }

        It 'version: the candidate whose DisplayVersion shares the major and minor parts (verified facts)' {
            $apps = @((New-TestApp 'Contoso Alpha' 'Contoso' @{ DisplayVersion = '3.2.5' }), (New-TestApp 'Contoso Beta' 'Contoso' @{ DisplayVersion = '4.0' }))
            $r = Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = 'Contoso'; FileVersion = '3.2.1.0' }) $script:D47 $apps
            $r.MatchRuleId | Should -BeExactly 'ps-resolve-version'
            $r.ResolvedAppName | Should -BeExactly 'Contoso Alpha'
        }

        It 'version: an unverified build never resolves on the version step' {
            $apps = @((New-TestApp 'Contoso Alpha' 'Contoso' @{ DisplayVersion = '3.2.5' }), (New-TestApp 'Contoso Beta' 'Contoso' @{ DisplayVersion = '4.0' }))
            $r = Resolve-AUIdentity (New-TestUnverifiedFacts 'Contoso' 'Contoso Tool' @{ FileVersion = '3.2.1.0'; ProductVersion = '3.2.1.0' }) $script:D47 $apps
            $r.MatchSection | Should -BeExactly 'None'
            @($r.CandidateTargets) | Should -Be @('Contoso Alpha', 'Contoso Beta')
        }

        It 'architecture: a path under Program Files (x86) matches the 32-bit entry' {
            $apps = @((New-TestApp 'Contoso Alpha' 'Contoso' @{ Architecture = 64 }), (New-TestApp 'Contoso Beta' 'Contoso' @{ Architecture = 32 }))
            $r = Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = 'Contoso'; RunPath = 'C:\Program Files (x86)\Contoso\tool.exe' }) $script:D47 $apps
            $r.MatchRuleId | Should -BeExactly 'ps-resolve-arch'
            $r.ResolvedAppName | Should -BeExactly 'Contoso Beta'
        }

        It 'architecture: a path under Program Files matches the 64-bit entry' {
            $apps = @((New-TestApp 'Contoso Alpha' 'Contoso' @{ Architecture = 64 }), (New-TestApp 'Contoso Beta' 'Contoso' @{ Architecture = 32 }))
            $r = Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = 'Contoso'; RunPath = 'C:\Program Files\Contoso\tool.exe' }) $script:D47 $apps
            $r.MatchRuleId | Should -BeExactly 'ps-resolve-arch'
            $r.ResolvedAppName | Should -BeExactly 'Contoso Alpha'
        }

        It 'install scope: the per-user install whose ProfilePath contains the run path, for the same user' {
            $apps = @((New-TestApp 'Contoso Alpha' 'Contoso'), (New-TestApp 'Contoso Beta' 'Contoso' @{ Scope = $script:TestSid; ProfilePath = 'C:\Users\a' }))
            $r = Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = 'Contoso'; RunPath = 'C:\Users\a\AppData\Local\Programs\Contoso\tool.exe' }) $script:D47 $apps
            $r.MatchRuleId | Should -BeExactly 'ps-resolve-scope'
            $r.ResolvedAppName | Should -BeExactly 'Contoso Beta'
        }

        It 'install scope: another user''s per-user install does not count' {
            $apps = @((New-TestApp 'Contoso Alpha' 'Contoso'), (New-TestApp 'Contoso Beta' 'Contoso' @{ Scope = 'S-1-5-21-1111111111-2222222222-3333333333-1002'; ProfilePath = 'C:\Users\a' }))
            $r = Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = 'Contoso'; RunPath = 'C:\Users\a\AppData\Local\Programs\Contoso\tool.exe' }) $script:D47 $apps
            $r.MatchSection | Should -BeExactly 'None'
        }

        It 'a step that would remove both candidates is skipped' {
            # Both have install folders, and neither contains the path: the path step is skipped and the publisher step decides.
            $apps = @((New-TestApp 'Contoso Alpha' 'Contoso Labs' @{ InstallLocation = 'C:\Apps\Alpha' }), (New-TestApp 'Contoso Beta' 'Contoso' @{ InstallLocation = 'C:\Apps\Beta' }))
            $r = Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = 'Contoso'; RunPath = 'D:\Elsewhere\tool.exe' }) $script:D47 $apps
            $r.MatchRuleId | Should -BeExactly 'ps-resolve-publisher'
            $r.ResolvedAppName | Should -BeExactly 'Contoso Beta'
        }

        It 'an unverified build can still resolve on the path step' {
            $apps = @((New-TestApp 'Contoso Alpha' 'Contoso' @{ InstallLocation = 'C:\Apps\Alpha' }), (New-TestApp 'Contoso Beta' 'Contoso' @{ InstallLocation = 'C:\Apps\Beta' }))
            $r = Resolve-AUIdentity (New-TestUnverifiedFacts 'Contoso' 'Contoso Tool' @{ RunPath = 'C:\Apps\Alpha\tool.exe' }) $script:D47 $apps
            $r.MatchRuleId | Should -BeExactly 'ps-resolve-path'
            $r.EvidenceUsed | Should -BeExactly 'CurrentFileAtPath'
        }

        It 'resolves arpCompare candidates too, keeping RuleType and InstalledStateDependent' {
            $m = New-TestMappings -PowerStacks @($script:RuleArp)
            $apps = @((New-TestApp 'Zoom Workplace (64-bit)' 'Zoom Communications, Inc.' @{ Architecture = 64 }), (New-TestApp 'Zoom Workplace (32-bit)' 'Zoom Communications, Inc.' @{ Architecture = 32 }))
            $r = Resolve-AUIdentity (New-TestUnverifiedFacts 'Zoom Communications, Inc.' 'Zoom Workplace' @{ ExeName = 'zoom.exe'; RunPath = 'C:\Program Files\Zoom\bin\Zoom.exe' }) $m $apps
            $r.MatchSection | Should -BeExactly 'PowerStacks'
            $r.MatchRuleId | Should -BeExactly 'ps-resolve-arch'
            $r.RuleType | Should -BeExactly 'arpCompare'
            $r.InstalledStateDependent | Should -BeTrue
            $r.ResolvedAppName | Should -BeExactly 'Zoom Workplace (64-bit)'
        }

        It 'a customer rule whose candidates a step narrows keeps its own rule ID and section, and logs the step' {
            Mock Write-CMTraceLog { }
            $m = New-TestMappings -Customer @('{ "id": "c-contoso-1", "type": "identity", "when": { "exeName": "tool.exe", "publisher": "Contoso*" }, "target": { "displayName": "Contoso*", "publisher": "Contoso*" } }') -PowerStacks @($script:RuleContoso)
            $apps = @((New-TestApp 'Contoso Alpha' 'Contoso' @{ InstallLocation = 'C:\Apps\Alpha' }), (New-TestApp 'Contoso Beta' 'Contoso' @{ InstallLocation = 'C:\Apps\Beta' }))
            $r = Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = 'Contoso'; RunPath = 'C:\Apps\Beta\tool.exe' }) $m $apps
            $r.MatchSection | Should -BeExactly 'Customer'
            $r.MatchRuleId | Should -BeExactly 'c-contoso-1'
            $r.RuleType | Should -BeExactly 'identity'
            $r.ResolvedAppName | Should -BeExactly 'Contoso Beta'
            Should -Invoke Write-CMTraceLog -Times 1 -Exactly -ParameterFilter { $Message -like '*resolved c-contoso-1 by path*' }
        }

        It 'the same candidates from a PowerStacks rule record ps-resolve-<step>' {
            Mock Write-CMTraceLog { }
            $apps = @((New-TestApp 'Contoso Alpha' 'Contoso' @{ InstallLocation = 'C:\Apps\Alpha' }), (New-TestApp 'Contoso Beta' 'Contoso' @{ InstallLocation = 'C:\Apps\Beta' }))
            $r = Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = 'Contoso'; RunPath = 'C:\Apps\Beta\tool.exe' }) $script:D47 $apps
            $r.MatchSection | Should -BeExactly 'PowerStacks'
            $r.MatchRuleId | Should -BeExactly 'ps-resolve-path'
            Should -Invoke Write-CMTraceLog -Times 0 -Exactly -ParameterFilter { $Message -like '*resolved*' }
        }

        It 'a customer rule still wins' {
            $m = New-TestMappings -Customer @('{ "id": "c-tool-1", "type": "identity", "when": { "exeName": "tool.exe", "publisher": "Contoso" }, "target": { "displayName": "Contoso Beta", "publisher": "Contoso" } }') -PowerStacks @($script:RuleContoso)
            $apps = @((New-TestApp 'Contoso Alpha' 'Contoso' @{ InstallLocation = 'C:\Apps\Alpha' }), (New-TestApp 'Contoso Beta' 'Contoso' @{ InstallLocation = 'C:\Apps\Beta' }))
            $r = Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = 'Contoso'; RunPath = 'C:\Apps\Alpha\tool.exe' }) $m $apps
            $r.MatchSection | Should -BeExactly 'Customer'
            $r.MatchRuleId | Should -BeExactly 'c-tool-1'
            $r.ResolvedAppName | Should -BeExactly 'Contoso Beta'
        }
    }
}

Describe 'Get-AUClassification' {
    It 'an ignore rule sets Ignored' {
        $m = New-TestMappings -PowerStacks @('{ "id": "ps-ignore-noise", "type": "ignore", "when": { "exeName": "noise*.exe" } }')
        $c = Get-AUClassification (New-TestFacts @{ ExeName = 'noise1.exe' }) $m 'PowerStacks'
        $c.Ignored | Should -BeTrue
        $c.IgnoreRuleId | Should -BeExactly 'ps-ignore-noise'
        $c.RuleRole | Should -BeNullOrEmpty
    }

    It 'with no rule, RuleRole and ClassificationRuleId are $null and Ignored is false' {
        $c = Get-AUClassification (New-TestFacts) (New-TestMappings) 'None'
        $c.RuleRole | Should -BeNullOrEmpty
        $c.ClassificationRuleId | Should -BeNullOrEmpty
        $c.Ignored | Should -BeFalse
    }

    It 'for an exe matched by a customer rule, PowerStacks ignore and classification rules do not apply, and customer classification still does (D38)' {
        $m = New-TestMappings -Customer @(
            '{ "id": "c-tool-1", "type": "identity", "when": { "exeName": "tool.exe", "publisher": "Contoso" }, "target": { "displayName": "Contoso Tool", "publisher": "Contoso" } }',
            '{ "id": "c-class-tool", "type": "classification", "when": { "exeName": "tool.exe" }, "role": "Helper" }') -PowerStacks @(
            '{ "id": "ps-ignore-tool", "type": "ignore", "when": { "exeName": "tool.exe" } }',
            '{ "id": "ps-class-tool", "type": "classification", "when": { "exeName": "tool.exe" }, "role": "CLI" }')
        $facts = New-TestFacts @{ FileCompanyName = 'Contoso' }
        $identity = Resolve-AUIdentity $facts $m @()
        $identity.MatchSection | Should -BeExactly 'Customer'
        $c = Get-AUClassification $facts $m $identity.MatchSection
        $c.Ignored | Should -BeFalse
        $c.RuleRole | Should -BeExactly 'Helper'
        $c.ClassificationRuleId | Should -BeExactly 'c-class-tool'
    }

    It 'for an exe matched by a customer rule, a PowerStacks classification rule alone does not set RuleRole' {
        $m = New-TestMappings -PowerStacks @('{ "id": "ps-class-tool", "type": "classification", "when": { "exeName": "tool.exe" }, "role": "CLI" }')
        $c = Get-AUClassification (New-TestFacts) $m 'Customer'
        $c.RuleRole | Should -BeNullOrEmpty
        $c.ClassificationRuleId | Should -BeNullOrEmpty
    }

    It 'an identity match does not stop classification: an exe matched by ps-acrobat-1 still gets Helper' {
        $m = New-TestMappings -PowerStacks @(
            '{ "id": "ps-acrobat-1", "type": "identity", "when": { "exeName": "acrocef.exe", "publisher": "Adobe*" }, "target": { "displayName": "Adobe Acrobat*", "publisher": "Adobe*" } }',
            '{ "id": "ps-class-acrocef", "type": "classification", "when": { "exeName": "acrocef.exe" }, "role": "Helper" }')
        $facts = New-TestFacts @{ ExeName = 'acrocef.exe'; FileCompanyName = 'Adobe Inc.' }
        $identity = Resolve-AUIdentity $facts $m @((New-TestApp 'Adobe Acrobat (64-bit)' 'Adobe'))
        $identity.MatchRuleId | Should -BeExactly 'ps-acrobat-1'
        $c = Get-AUClassification $facts $m $identity.MatchSection
        $c.RuleRole | Should -BeExactly 'Helper'
        $c.ClassificationRuleId | Should -BeExactly 'ps-class-acrocef'
    }

    It 'customer rules come first, and the first match of each kind wins' {
        $m = New-TestMappings -Customer @(
            '{ "id": "c-class-a", "type": "classification", "when": { "exeName": "tool.exe" }, "role": "Service" }',
            '{ "id": "c-class-b", "type": "classification", "when": { "exeName": "tool.exe" }, "role": "CLI" }') -PowerStacks @(
            '{ "id": "ps-class-a", "type": "classification", "when": { "exeName": "tool.exe" }, "role": "Helper" }',
            '{ "id": "ps-ignore-a", "type": "ignore", "when": { "exeName": "tool.exe" } }',
            '{ "id": "ps-ignore-b", "type": "ignore", "when": { "exeName": "tool*" } }')
        $c = Get-AUClassification (New-TestFacts) $m 'None'
        $c.RuleRole | Should -BeExactly 'Service'
        $c.ClassificationRuleId | Should -BeExactly 'c-class-a'
        $c.Ignored | Should -BeTrue
        $c.IgnoreRuleId | Should -BeExactly 'ps-ignore-a'
    }

    It 'needs every condition to match, including locationClass' {
        $m = New-TestMappings -PowerStacks @('{ "id": "ps-class-windows", "type": "classification", "when": { "locationClass": "Windows", "companyName": "Microsoft Corporation" }, "role": "Windows" }')
        (Get-AUClassification (New-TestFacts @{ LocationClass = 'Windows'; FileCompanyName = 'Microsoft Corporation' }) $m 'None').RuleRole | Should -BeExactly 'Windows'
        (Get-AUClassification (New-TestFacts @{ LocationClass = 'ProgramFiles'; FileCompanyName = 'Microsoft Corporation' }) $m 'None').RuleRole | Should -BeNullOrEmpty
    }

    It 'companyName and fileDescription use verified facts only, never PathEvidence' {
        $m = New-TestMappings -PowerStacks @('{ "id": "ps-class-windows", "type": "classification", "when": { "locationClass": "Windows", "companyName": "Microsoft Corporation" }, "role": "Windows" }')
        $facts = New-TestUnverifiedFacts 'Microsoft Corporation' 'Microsoft Windows Operating System' @{ LocationClass = 'Windows' }
        (Get-AUClassification $facts $m 'None').RuleRole | Should -BeNullOrEmpty
    }

    It 'an exeName condition does not match a Store package with no exe name' {
        $m = New-TestMappings -PowerStacks @('{ "id": "ps-ignore-all", "type": "ignore", "when": { "exeName": "*" } }')
        (Get-AUClassification (New-TestFacts @{ ExeName = $null; PackageFamily = 'Contoso.Notes_8wekyb3d8bbwe' }) $m 'None').Ignored | Should -BeFalse
    }
}
