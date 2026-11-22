BeforeAll {
    . "$PSScriptRoot\_Import.ps1"

    $script:TestSid = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
    $script:MappingsCount = 0

    # Facts in the Task 14 shape. A verified GUI build by default; pass overrides as a hashtable.
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

    # A Resolve-AUTarget result. A PowerStacks arpCompare target for Contoso Alpha by default.
    function New-TestTarget([hashtable]$Values = @{})
    {
        $Target = [ordered]@{
            TargetPattern           = 'Contoso Alpha'
            TargetPublisher         = 'Contoso'
            ResolvedAppName         = 'Contoso Alpha'
            ProductCode             = $null
            PackageFamily           = $null
            MatchSection            = 'PowerStacks'
            MatchRuleId             = 'ps-arp-compare'
            RuleType                = 'arpCompare'
            InstalledStateDependent = $true
            EvidenceUsed            = 'Verified'
            CandidateTargets        = $null
            RetainedFrom            = $null
        }
        foreach ($Key in $Values.Keys) { $Target[$Key] = $Values[$Key] }
        return [pscustomobject]$Target
    }

    # A Get-AUClassification result with no rule hit, or with the given role.
    function New-TestClassification([string]$Role = $null)
    {
        $Id = $null
        if ($Role) { $Id = 'c-class-test-1' }
        return [pscustomobject]@{ RuleRole = $Role; ClassificationRuleId = $Id; Ignored = $false; IgnoreRuleId = $null }
    }

    # The whole Get-AUMappings result, built through the real loader from PowerStacks rule JSON texts.
    function New-TestMappings([string[]]$PowerStacks)
    {
        $script:MappingsCount++
        $Dir = Join-Path 'TestDrive:\' "mappings$($script:MappingsCount)"
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $Dir = (Resolve-Path $Dir).ProviderPath
        $Json = '{ "schemaVersion": 1, "powerStacks": { "version": "test", "identityRules": [' + ($PowerStacks -join ',') + '], "classificationRules": [] } }'
        [IO.File]::WriteAllText((Join-Path $Dir 'powerstacks-mappings.json'), $Json)
        $Result = Get-AUMappings -Embedded '' -BesideDir $Dir -CustomerPath (Join-Path $Dir 'customer-mappings.json')
        if ($Result.Errors.Count -gt 0) { throw "Test mappings are invalid: $($Result.Errors -join ' | ')" }
        return $Result
    }

    # Runs the real identity and target resolution, then the role.
    function Get-TestRole([pscustomobject]$Facts, [pscustomobject]$Mappings, [object[]]$Apps, [pscustomobject]$StoredTarget = $null)
    {
        $Identity = Resolve-AUIdentity $Facts $Mappings $Apps
        $Target = Resolve-AUTarget $Identity $StoredTarget $Mappings
        return Get-AURole $Facts $Target (New-TestClassification) $Apps
    }

    $script:NoTarget = New-TestTarget @{ TargetPattern = $null; TargetPublisher = $null; ResolvedAppName = $null; MatchSection = 'None'; MatchRuleId = $null; RuleType = $null; InstalledStateDependent = $false; EvidenceUsed = 'None' }
    $script:RuleTarget = New-TestTarget @{ TargetPattern = 'Contoso Alpha*'; TargetPublisher = 'Contoso*'; MatchRuleId = 'ps-contoso-1'; RuleType = 'identity'; InstalledStateDependent = $false }
    $script:RuleArp = '{ "id": "ps-arp-compare", "type": "arpCompare" }'
    $script:RuleAcrobat = '{ "id": "ps-acrobat-1", "type": "identity", "when": { "exeName": "acrobat.exe", "publisher": "Adobe*" }, "target": { "displayName": "Adobe Acrobat*", "publisher": "Adobe*" } }'
}

Describe 'Get-AURole precedence' {
    It 'is Installer for a run from <Class>, over a classification role, a service, and a main exe' -ForEach @(
        @{ Class = 'Temp' }, @{ Class = 'Download' }, @{ Class = 'ManagementCache' }
    ) {
        $facts = New-TestFacts @{ LocationClass = $Class; IsServiceBinary = $true }
        Get-AURole $facts $script:RuleTarget (New-TestClassification 'Helper') @() | Should -BeExactly 'Installer'
    }

    It 'uses the classification role over a service binary' {
        $facts = New-TestFacts @{ IsServiceBinary = $true; Subsystem = 'Console' }
        Get-AURole $facts $script:RuleTarget (New-TestClassification 'Windows') @() | Should -BeExactly 'Windows'
    }

    It 'uses the classification role over the subsystem: a console exe classified Helper is Helper' {
        $facts = New-TestFacts @{ Subsystem = 'Console' }
        Get-AURole $facts $script:NoTarget (New-TestClassification 'Helper') @() | Should -BeExactly 'Helper'
    }

    It 'uses the classification role over the subsystem: a GUI main exe classified CLI is CLI' {
        Get-AURole (New-TestFacts) $script:RuleTarget (New-TestClassification 'CLI') @() | Should -BeExactly 'CLI'
    }

    It 'is Service for a service binary, over the console subsystem and a main exe' {
        Get-AURole (New-TestFacts @{ IsServiceBinary = $true; Subsystem = 'Console' }) $script:RuleTarget (New-TestClassification) @() | Should -BeExactly 'Service'
        Get-AURole (New-TestFacts @{ IsServiceBinary = $true }) $script:RuleTarget (New-TestClassification) @() | Should -BeExactly 'Service'
    }

    It 'is CLI for a console exe, matched or not' {
        Get-AURole (New-TestFacts @{ Subsystem = 'Console' }) $script:RuleTarget (New-TestClassification) @() | Should -BeExactly 'CLI'
        Get-AURole (New-TestFacts @{ Subsystem = 'Console' }) $script:NoTarget (New-TestClassification) @() | Should -BeExactly 'CLI'
    }

    It 'is App for a matched GUI main exe' {
        Get-AURole (New-TestFacts) $script:RuleTarget (New-TestClassification) @() | Should -BeExactly 'App'
    }

    It 'is Helper for a matched GUI exe that is not the main exe' {
        Get-AURole (New-TestFacts) (New-TestTarget) (New-TestClassification) @() | Should -BeExactly 'Helper'
    }

    It 'is Unmatched for a GUI exe with no target' {
        Get-AURole (New-TestFacts) $script:NoTarget (New-TestClassification) @() | Should -BeExactly 'Unmatched'
    }

    It 'is Unmatched for an unresolved exe with candidate targets' {
        $target = New-TestTarget @{ TargetPattern = $null; TargetPublisher = $null; ResolvedAppName = $null; MatchSection = 'None'; MatchRuleId = $null; RuleType = $null; CandidateTargets = @('Contoso Alpha', 'Contoso Beta') }
        Get-AURole (New-TestFacts) $target (New-TestClassification) @() | Should -BeExactly 'Unmatched'
    }

    It 'is Unmatched with no target and no classification' {
        Get-AURole (New-TestFacts) $null $null @() | Should -BeExactly 'Unmatched'
    }

    It 'treats a matched exe whose subsystem is unknown as GUI, so a mapped exe stays mapped' {
        Get-AURole (New-TestFacts @{ Subsystem = $null }) $script:RuleTarget (New-TestClassification) @() | Should -BeExactly 'App'
        Get-AURole (New-TestFacts @{ Subsystem = $null }) (New-TestTarget) (New-TestClassification) @() | Should -BeExactly 'Helper'
        Get-AURole (New-TestFacts @{ Subsystem = $null }) $script:NoTarget (New-TestClassification) @() | Should -BeExactly 'Unmatched'
    }

    It 'never returns System, whoever ran the exe' {
        $facts = New-TestFacts @{ UserSid = 'S-1-5-18' }
        Get-AURole $facts $script:NoTarget (New-TestClassification) @() | Should -BeExactly 'Unmatched'
        Get-AURole $facts $script:RuleTarget (New-TestClassification) @() | Should -BeExactly 'App'
    }
}

Describe 'Get-AURole main exe by identity rule (F19)' {
    BeforeAll {
        $script:Mappings = New-TestMappings @($script:RuleAcrobat, $script:RuleArp)
        $script:Apps = @((New-TestApp 'Adobe Acrobat (64-bit)' 'Adobe Inc.'))
        $script:AcrobatFacts = @{ FileCompanyName = 'Adobe Inc.'; FileProductName = 'Adobe Acrobat'; LocationClass = 'ProgramFiles' }
    }

    It 'makes the exe the rule names App' {
        $facts = New-TestFacts ($script:AcrobatFacts + @{ ExeName = 'acrobat.exe'; RunPath = 'C:\Program Files\Adobe\Acrobat DC\Acrobat\Acrobat.exe' })
        Get-TestRole $facts $script:Mappings $script:Apps | Should -BeExactly 'App'
    }

    It 'makes another GUI exe with the same target Helper' {
        $facts = New-TestFacts ($script:AcrobatFacts + @{ ExeName = 'acrocef.exe'; RunPath = 'C:\Program Files\Adobe\Acrobat DC\Acrobat\acrocef_1\AcroCEF.exe' })
        $target = Resolve-AUTarget (Resolve-AUIdentity $facts $script:Mappings $script:Apps) $null $script:Mappings
        $target.ResolvedAppName | Should -BeExactly 'Adobe Acrobat (64-bit)'
        Get-AURole $facts $target (New-TestClassification) $script:Apps | Should -BeExactly 'Helper'
    }
}

Describe 'Get-AURole main exe by DisplayIcon (F19)' {
    BeforeAll {
        $script:Mappings = New-TestMappings @($script:RuleArp)
        $script:ZoomFacts = @{ FileCompanyName = 'Zoom Communications, Inc.'; FileProductName = 'Zoom Workplace'; LocationClass = 'ProgramFiles' }
        $script:ZoomApp = @{ DisplayIcon = 'C:\Program Files\Zoom\bin\Zoom.exe,0'; InstallLocation = 'C:\Program Files\Zoom\bin' }
    }

    It 'makes the exe at the arpCompare target app''s DisplayIcon path App' {
        $apps = @((New-TestApp 'Zoom Workplace (64-bit)' 'Zoom Communications, Inc.' $script:ZoomApp))
        $facts = New-TestFacts ($script:ZoomFacts + @{ ExeName = 'zoom.exe'; RunPath = 'C:\Program Files\Zoom\bin\Zoom.exe' })
        Get-TestRole $facts $script:Mappings $apps | Should -BeExactly 'App'
    }

    It 'compares the path ignoring case, quotes, and the icon index' {
        $apps = @((New-TestApp 'Zoom Workplace (64-bit)' 'Zoom Communications, Inc.' @{ DisplayIcon = '"C:\Program Files\Zoom\bin\Zoom.exe",0' }))
        $facts = New-TestFacts ($script:ZoomFacts + @{ ExeName = 'zoom.exe'; RunPath = 'c:\program files\zoom\BIN\zoom.exe' })
        Get-TestRole $facts $script:Mappings $apps | Should -BeExactly 'App'
    }

    It 'makes another exe of the same app Helper' {
        $apps = @((New-TestApp 'Zoom Workplace (64-bit)' 'Zoom Communications, Inc.' $script:ZoomApp))
        $facts = New-TestFacts ($script:ZoomFacts + @{ ExeName = 'zoom_launcher.exe'; RunPath = 'C:\Program Files\Zoom\bin\Zoom_launcher.exe' })
        Get-TestRole $facts $script:Mappings $apps | Should -BeExactly 'Helper'
    }

    It 'needs a verified run path' {
        $apps = @((New-TestApp 'Zoom Workplace (64-bit)' 'Zoom Communications, Inc.' $script:ZoomApp))
        $facts = New-TestFacts ($script:ZoomFacts + @{ ExeName = 'zoom.exe'; RunPath = 'C:\Program Files\Zoom\bin\Zoom.exe' })
        $target = Resolve-AUTarget (Resolve-AUIdentity $facts $script:Mappings $apps) $null $script:Mappings
        $facts.FactsVerified = $false
        Get-AURole $facts $target (New-TestClassification) $apps | Should -BeExactly 'Helper'
    }

    It 'uses only the target app''s DisplayIcon, not another app''s' {
        $target = New-TestTarget
        $apps = @(
            (New-TestApp 'Contoso Alpha' 'Contoso'),
            (New-TestApp 'Zoom Workplace (64-bit)' 'Zoom Communications, Inc.' $script:ZoomApp)
        )
        $facts = New-TestFacts ($script:ZoomFacts + @{ ExeName = 'zoom.exe'; RunPath = 'C:\Program Files\Zoom\bin\Zoom.exe' })
        Get-AURole $facts $target (New-TestClassification) $apps | Should -BeExactly 'Helper'
    }

    It 'finds the target app by ProductCode after an update renamed it' {
        $target = New-TestTarget @{ RuleType = 'ownership'; MatchRuleId = 'ps-own-msi'; ProductCode = '{11111111-2222-3333-4444-555555555555}' }
        $apps = @((New-TestApp 'Contoso Alpha 2' 'Contoso' @{ ProductCode = '{11111111-2222-3333-4444-555555555555}'; DisplayIcon = 'C:\Program Files\Contoso\alpha.exe' }))
        $facts = New-TestFacts @{ ExeName = 'alpha.exe'; RunPath = 'C:\Program Files\Contoso\alpha.exe' }
        Get-AURole $facts $target (New-TestClassification) $apps | Should -BeExactly 'App'
    }
}

Describe 'Get-AURole with a retained target (F20)' {
    BeforeAll {
        $script:Mappings = New-TestMappings @($script:RuleAcrobat, $script:RuleArp)
        $script:Unverified = @{ FactsVerified = $false; Subsystem = $null; RunPath = $null }
    }

    It 'is App for the rule-named exe after the app is uninstalled' {
        $stored = [pscustomobject]@{ Section = 'PowerStacks'; MatchRuleId = 'ps-acrobat-1'; RuleType = 'identity'; TargetPattern = 'Adobe Acrobat*'; TargetPublisher = 'Adobe*'; ResolvedAppName = 'Adobe Acrobat (64-bit)'; ProductCode = $null; PackageFamily = $null; EvidenceUsed = 'Verified' }
        $facts = New-TestFacts ($script:Unverified + @{ ExeName = 'acrobat.exe' })
        $target = Resolve-AUTarget (Resolve-AUIdentity $facts $script:Mappings @()) $stored $script:Mappings
        $target.MatchSection | Should -BeExactly 'Retained'
        Get-AURole $facts $target (New-TestClassification) @() | Should -BeExactly 'App'
    }

    It 'is Helper, never Unmatched, for another exe of the uninstalled app' {
        $stored = [pscustomobject]@{ Section = 'PowerStacks'; MatchRuleId = 'ps-arp-compare'; RuleType = 'arpCompare'; TargetPattern = 'Adobe Acrobat (64-bit)'; TargetPublisher = 'Adobe Inc.'; ResolvedAppName = 'Adobe Acrobat (64-bit)'; ProductCode = $null; PackageFamily = $null; EvidenceUsed = 'Verified' }
        $facts = New-TestFacts ($script:Unverified + @{ ExeName = 'acrocef.exe' })
        $target = Resolve-AUTarget (Resolve-AUIdentity $facts $script:Mappings @()) $stored $script:Mappings
        $target.MatchSection | Should -BeExactly 'Retained'
        Get-AURole $facts $target (New-TestClassification) @() | Should -BeExactly 'Helper'
    }
}
