BeforeAll {
    # A silent logger with the real one's parameters, so tests can check what was logged with a ParameterFilter.
    function Write-CMTraceLog { param ([string]$Message, [string]$Component, [int]$Type) }
    . "$PSScriptRoot\_Import.ps1"

    $script:TestSid = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
    $script:OtherSid = 'S-1-5-21-1111111111-2222222222-3333333333-1002'
    $script:MappingsCount = 0

    # Facts in the Task 14 shape. Verified by default; pass overrides as a hashtable.
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

    # The whole Get-AUMappings result, built through the real loader. -CustomerRaw writes the customer
    # file as given (for an Invalid or TooLarge file) and allows the errors that causes.
    function New-TestMappings([string[]]$Customer = @(), [string[]]$PowerStacks = @(), [string]$CustomerRaw = $null)
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
        if ($CustomerRaw) { [IO.File]::WriteAllText($CustomerPath, $CustomerRaw) }
        elseif ($Customer.Count -gt 0)
        {
            [IO.File]::WriteAllText($CustomerPath, '{ "schemaVersion": 1, "customer": ' + (& $Split $Customer) + ' }')
        }
        $Result = Get-AUMappings -Embedded '' -BesideDir $Dir -CustomerPath $CustomerPath
        if (-not $CustomerRaw -and $Result.Errors.Count -gt 0) { throw "Test mappings are invalid: $($Result.Errors -join ' | ')" }
        return $Result
    }

    # A stored target in the F16 shape. Verified PowerStacks arpCompare for Contoso Alpha by default.
    function New-TestStored([hashtable]$Values = @{})
    {
        $Stored = [ordered]@{
            Section         = 'PowerStacks'
            MatchRuleId     = 'ps-arp-compare'
            RuleType        = 'arpCompare'
            TargetPattern   = 'Contoso Alpha'
            TargetPublisher = 'Contoso'
            ResolvedAppName = 'Contoso Alpha'
            ProductCode     = $null
            PackageFamily   = $null
            EvidenceUsed    = 'Verified'
        }
        foreach ($Key in $Values.Keys) { $Stored[$Key] = $Values[$Key] }
        return [pscustomobject]$Stored
    }

    # Every scope read this run.
    function New-TestScopeRead([hashtable]$Values = @{})
    {
        $Scopes = @{ Machine = 'Read'; $script:TestSid = 'Read' }
        foreach ($Key in $Values.Keys) { $Scopes[$Key] = $Values[$Key] }
        return $Scopes
    }

    $script:NoMatch = [pscustomobject]@{
        TargetPattern = $null; TargetPublisher = $null; ResolvedAppName = $null; ProductCode = $null; PackageFamily = $null
        MatchSection = 'None'; MatchRuleId = $null; RuleType = $null; InstalledStateDependent = $false; EvidenceUsed = 'None'; CandidateTargets = $null
    }

    $script:RuleArp = '{ "id": "ps-arp-compare", "type": "arpCompare" }'
    $script:RuleContoso = '{ "id": "ps-contoso-1", "type": "identity", "when": { "exeName": "tool.exe", "publisher": "Contoso*" }, "target": { "displayName": "Contoso*", "publisher": "Contoso*" } }'
    $script:RuleCustomerBeta = '{ "id": "c-tool-1", "type": "identity", "when": { "exeName": "tool.exe", "publisher": "Contoso*" }, "target": { "displayName": "Contoso Beta*", "publisher": "Contoso*" } }'
}

Describe 'Get-AUInstallStatus' {
    BeforeAll {
        $script:Target = [pscustomobject]@{ MatchSection = 'PowerStacks'; MatchRuleId = 'ps-contoso-1'; TargetPattern = 'Contoso Alpha*'; TargetPublisher = 'Contoso*'; ProductCode = $null; PackageFamily = $null }
    }

    It 'is Installed when the target is present' {
        Get-AUInstallStatus $script:Target @((New-TestApp 'Contoso Alpha 2.1' 'Contoso Ltd')) (New-TestScopeRead) $script:TestSid | Should -BeExactly 'Installed'
    }

    It 'is Installed when the target is a per-user install of the entry user, even with the Machine scope unread' {
        $apps = @((New-TestApp 'Contoso Alpha' 'Contoso' @{ Scope = $script:TestSid }))
        Get-AUInstallStatus $script:Target $apps (New-TestScopeRead @{ Machine = 'Unread' }) $script:TestSid | Should -BeExactly 'Installed'
    }

    It 'is Installed when the ProductCode matches after the DisplayName changed in an update' {
        $t = [pscustomobject]@{ MatchSection = 'Retained'; MatchRuleId = 'ps-own-msi'; TargetPattern = 'Contoso Alpha 1.0'; TargetPublisher = 'Contoso'; ProductCode = '{AAAAAAAA-0000-0000-0000-000000000001}'; PackageFamily = $null }
        $apps = @((New-TestApp 'Contoso Alpha 1.1' 'Contoso' @{ ProductCode = '{aaaaaaaa-0000-0000-0000-000000000001}' }))
        Get-AUInstallStatus $t $apps (New-TestScopeRead) $script:TestSid | Should -BeExactly 'Installed'
    }

    It 'is NotInstalled when every scope was Read and the target is absent, and leaves the target unchanged (D17)' {
        $before = $script:Target | ConvertTo-Json -Compress
        Get-AUInstallStatus $script:Target @((New-TestApp 'Fabrikam Designer' 'Fabrikam')) (New-TestScopeRead) $script:TestSid | Should -BeExactly 'NotInstalled'
        $script:Target.MatchSection | Should -BeExactly 'PowerStacks'
        $script:Target.MatchRuleId | Should -BeExactly 'ps-contoso-1'
        ($script:Target | ConvertTo-Json -Compress) | Should -BeExactly $before
    }

    It 'is Unknown when the per-user scope is Unread' {
        Get-AUInstallStatus $script:Target @() (New-TestScopeRead @{ $script:TestSid = 'Unread' }) $script:TestSid | Should -BeExactly 'Unknown'
    }

    It 'is Unknown when the Machine scope is Unread' {
        Get-AUInstallStatus $script:Target @() (New-TestScopeRead @{ Machine = 'Unread' }) $script:TestSid | Should -BeExactly 'Unknown'
    }

    It 'is NotInstalled when the entry user''s profile is Deleted' {
        Get-AUInstallStatus $script:Target @() (New-TestScopeRead @{ $script:TestSid = 'Deleted' }) $script:TestSid | Should -BeExactly 'NotInstalled'
    }

    It 'is Unknown for a SID missing from ScopeRead (F29)' {
        Get-AUInstallStatus $script:Target @() (New-TestScopeRead) $script:OtherSid | Should -BeExactly 'Unknown'
    }

    It 'is Unknown with no ScopeRead at all' {
        Get-AUInstallStatus $script:Target @() $null $script:TestSid | Should -BeExactly 'Unknown'
    }

    It 'checks Machine plus the entry user only: another user''s per-user install doesn''t count (F30)' {
        $apps = @((New-TestApp 'Contoso Alpha' 'Contoso' @{ Scope = $script:OtherSid }))
        Get-AUInstallStatus $script:Target $apps (New-TestScopeRead @{ $script:OtherSid = 'Read' }) $script:TestSid | Should -BeExactly 'NotInstalled'
    }

    It 'is Installed for a per-user target present in the entry user''s scope (F30)' {
        $apps = @((New-TestApp 'Contoso Alpha' 'Contoso' @{ Scope = $script:OtherSid }))
        Get-AUInstallStatus $script:Target $apps @{ Machine = 'Read'; $script:OtherSid = 'Read' } $script:OtherSid | Should -BeExactly 'Installed'
    }

    It 'is NotInstalled for a per-user target whose user scope is Read and absent (F30)' {
        Get-AUInstallStatus $script:Target @() @{ Machine = 'Read'; $script:OtherSid = 'Read' } $script:OtherSid | Should -BeExactly 'NotInstalled'
    }

    It 'is Unknown with a blank UserSid, even with Machine Read, because the user scope is unknown' {
        Get-AUInstallStatus $script:Target @() (New-TestScopeRead) '' | Should -BeExactly 'Unknown'
        Get-AUInstallStatus $script:Target @() (New-TestScopeRead) $null | Should -BeExactly 'Unknown'
        Get-AUInstallStatus $script:Target @((New-TestApp 'Contoso Alpha' 'Contoso')) (New-TestScopeRead) '' | Should -BeExactly 'Installed'
    }

    It 'is Installed after an update renames the entry and changes its ProductCode, on an unverified run (arpCompare)' {
        Mock Write-CMTraceLog { }
        $m = New-TestMappings -PowerStacks @($script:RuleArp)
        $old = @((New-TestApp 'Contoso Alpha 1.0' 'Contoso Ltd' @{ ProductCode = '{AAAAAAAA-0000-0000-0000-000000000001}' }))
        $new = @((New-TestApp 'Contoso Alpha 1.1' 'Contoso Ltd' @{ ProductCode = '{AAAAAAAA-0000-0000-0000-000000000002}' }))

        # First run, verified: the target is stored as the exact DisplayName Contoso Alpha 1.0.
        $stored = ConvertTo-AUStoredTarget (Resolve-AUTarget (Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = 'Contoso'; FileProductName = 'Contoso Alpha' }) $m $old) $null $m)
        $stored.TargetPattern | Should -BeExactly 'Contoso Alpha 1.0'

        # After the update, an unverified run: the stored target is kept (D30) and the renamed entry still counts.
        $identity = Resolve-AUIdentity (New-TestUnverifiedFacts 'Contoso' 'Contoso Alpha') $m $new
        $identity.EvidenceUsed | Should -BeExactly 'CurrentFileAtPath'
        $identity.ResolvedAppName | Should -BeExactly 'Contoso Alpha 1.1'
        $t = Resolve-AUTarget $identity $stored $m
        $t.MatchSection | Should -BeExactly 'Retained'
        $t.TargetPattern | Should -BeExactly 'Contoso Alpha 1.0'
        Get-AUInstallStatus $t $new (New-TestScopeRead) $script:TestSid | Should -BeExactly 'Installed'

        # A different app from the same publisher doesn't count.
        Get-AUInstallStatus $t @((New-TestApp 'Contoso Beta 1.1' 'Contoso Ltd')) (New-TestScopeRead) $script:TestSid | Should -BeExactly 'NotInstalled'
    }

    It 'keeps identity-rule targets on their pattern only: no normalized-name match' {
        $t = [pscustomobject]@{ MatchSection = 'Customer'; MatchRuleId = 'c-tool-1'; RuleType = 'identity'; InstalledStateDependent = $false; TargetPattern = 'Contoso Alpha 1.0'; TargetPublisher = 'Contoso'; ResolvedAppName = 'Contoso Alpha 1.0'; ProductCode = $null; PackageFamily = $null }
        Get-AUInstallStatus $t @((New-TestApp 'Contoso Alpha 1.1' 'Contoso')) (New-TestScopeRead) $script:TestSid | Should -BeExactly 'NotInstalled'
    }

    It 'is Unmatched with no target' {
        Get-AUInstallStatus $script:NoMatch @((New-TestApp 'Contoso Alpha' 'Contoso')) (New-TestScopeRead) $script:TestSid | Should -BeExactly 'Unmatched'
        Get-AUInstallStatus $null @() (New-TestScopeRead) $script:TestSid | Should -BeExactly 'Unmatched'
    }
}

Describe 'Resolve-AUTarget' {
    Context 'Retained targets (D17, F11)' {
        It 'keeps an arpCompare target after the app is uninstalled: Retained, same rule, NotInstalled' {
            $m = New-TestMappings -PowerStacks @($script:RuleArp)
            $facts = New-TestFacts @{ FileCompanyName = 'Contoso'; FileProductName = 'Contoso Alpha' }
            $installed = @((New-TestApp 'Contoso Alpha' 'Contoso'))

            # First run: the app is installed, so arpCompare matches and the target is stored.
            $first = Resolve-AUTarget (Resolve-AUIdentity $facts $m $installed) $null $m
            $first.MatchSection | Should -BeExactly 'PowerStacks'
            $stored = ConvertTo-AUStoredTarget $first
            $stored.Section | Should -BeExactly 'PowerStacks'
            $stored.MatchRuleId | Should -BeExactly 'ps-arp-compare'

            # Later run: the app is gone, so the identity no longer matches.
            $identity = Resolve-AUIdentity $facts $m @()
            $identity.MatchSection | Should -BeExactly 'None'
            $t = Resolve-AUTarget $identity $stored $m
            $t.MatchSection | Should -BeExactly 'Retained'
            $t.RetainedFrom | Should -BeExactly 'PowerStacks'
            $t.MatchRuleId | Should -BeExactly 'ps-arp-compare'
            $t.RuleType | Should -BeExactly 'arpCompare'
            $t.InstalledStateDependent | Should -BeTrue
            $t.ResolvedAppName | Should -BeExactly 'Contoso Alpha'
            Get-AUInstallStatus $t @() (New-TestScopeRead) $script:TestSid | Should -BeExactly 'NotInstalled'
        }

        It 'keeps a ps-resolve-path target after the app is uninstalled: Retained, same rule, NotInstalled (D47, F11)' {
            $m = New-TestMappings -PowerStacks @($script:RuleArp)
            $facts = New-TestFacts @{ FileCompanyName = 'Contoso'; FileProductName = 'Contoso Tool'; RunPath = 'C:\Program Files\Contoso Tool\tool.exe' }
            $installed = @(
                (New-TestApp 'Contoso Tool' 'Contoso' @{ InstallLocation = 'C:\Program Files\Contoso Tool' })
                (New-TestApp 'Contoso Tool (x86)' 'Contoso' @{ InstallLocation = 'C:\Program Files (x86)\Contoso Tool' })
            )
            $first = Resolve-AUTarget (Resolve-AUIdentity $facts $m $installed) $null $m
            $first.MatchRuleId | Should -BeExactly 'ps-resolve-path'
            $stored = ConvertTo-AUStoredTarget $first

            $t = Resolve-AUTarget (Resolve-AUIdentity $facts $m @()) $stored $m
            $t.MatchSection | Should -BeExactly 'Retained'
            $t.MatchRuleId | Should -BeExactly 'ps-resolve-path'
            $t.ResolvedAppName | Should -BeExactly 'Contoso Tool'
            Get-AUInstallStatus $t @() (New-TestScopeRead) $script:TestSid | Should -BeExactly 'NotInstalled'
        }

        It 'drops a stored target whose rule ID is gone, so the entry re-resolves from scratch' {
            $m = New-TestMappings -PowerStacks @($script:RuleContoso)
            $t = Resolve-AUTarget $script:NoMatch (New-TestStored @{ MatchRuleId = 'ps-deleted-1' }) $m
            $t.MatchSection | Should -BeExactly 'None'
            $t.MatchRuleId | Should -BeNullOrEmpty
            $t.RetainedFrom | Should -BeNullOrEmpty
            Get-AUInstallStatus $t @() (New-TestScopeRead) $script:TestSid | Should -BeExactly 'Unmatched'
        }

        It 'keeps CandidateTargets on a None result with no stored target' {
            $identity = $script:NoMatch.PSObject.Copy()
            $identity.CandidateTargets = @('Contoso Alpha', 'Contoso Beta')
            $t = Resolve-AUTarget $identity $null (New-TestMappings -PowerStacks @($script:RuleContoso))
            $t.MatchSection | Should -BeExactly 'None'
            $t.CandidateTargets | Should -Be @('Contoso Alpha', 'Contoso Beta')
        }

        It 'keeps the last concrete DisplayName when the same target now resolves to no installed app' {
            $m = New-TestMappings -Customer @($script:RuleCustomerBeta)
            $stored = New-TestStored @{ Section = 'Customer'; MatchRuleId = 'c-tool-1'; RuleType = 'identity'; TargetPattern = 'Contoso Beta*'; TargetPublisher = 'Contoso*'; ResolvedAppName = 'Contoso Beta 3' }
            $identity = Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = 'Contoso' }) $m @()
            $identity.ResolvedAppName | Should -BeNullOrEmpty
            $t = Resolve-AUTarget $identity $stored $m
            $t.MatchSection | Should -BeExactly 'Customer'
            $t.ResolvedAppName | Should -BeExactly 'Contoso Beta 3'
            (ConvertTo-AUStoredTarget $t).ResolvedAppName | Should -BeExactly 'Contoso Beta 3'
        }
    }

    Context 'Precedence (D38, D30, F15)' {
        It 'a new customer identity match beats a stored PowerStacks target' {
            $m = New-TestMappings -Customer @($script:RuleCustomerBeta) -PowerStacks @($script:RuleArp)
            $identity = Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = 'Contoso' }) $m @((New-TestApp 'Contoso Beta' 'Contoso'))
            $t = Resolve-AUTarget $identity (New-TestStored) $m
            $t.MatchSection | Should -BeExactly 'Customer'
            $t.MatchRuleId | Should -BeExactly 'c-tool-1'
            $t.ResolvedAppName | Should -BeExactly 'Contoso Beta'
            $t.RetainedFrom | Should -BeNullOrEmpty
        }

        It 'a customer match on current-file evidence still replaces a stored PowerStacks target and keeps EvidenceUsed CurrentFileAtPath' {
            $m = New-TestMappings -Customer @($script:RuleCustomerBeta) -PowerStacks @($script:RuleArp)
            $identity = Resolve-AUIdentity (New-TestUnverifiedFacts 'Contoso' 'Contoso Tool') $m @((New-TestApp 'Contoso Beta' 'Contoso'))
            $t = Resolve-AUTarget $identity (New-TestStored) $m
            $t.MatchSection | Should -BeExactly 'Customer'
            $t.EvidenceUsed | Should -BeExactly 'CurrentFileAtPath'
        }

        It 'a stored customer target beats a new PowerStacks identity match' {
            # The customer rule's version range doesn't cover this build, so only the PowerStacks rule matches it.
            $m = New-TestMappings -Customer @('{ "id": "c-tool-1", "type": "identity", "when": { "exeName": "tool.exe", "publisher": "Contoso*", "versionMin": "3.0" }, "target": { "displayName": "Contoso Beta*", "publisher": "Contoso*" } }') -PowerStacks @($script:RuleContoso)
            $identity = Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = 'Contoso'; FileVersion = '2.0.0.0' }) $m @((New-TestApp 'Contoso Alpha' 'Contoso'))
            $identity.MatchSection | Should -BeExactly 'PowerStacks'
            $identity.EvidenceUsed | Should -BeExactly 'Verified'
            $stored = New-TestStored @{ Section = 'Customer'; MatchRuleId = 'c-tool-1'; RuleType = 'identity'; TargetPattern = 'Contoso Beta*'; TargetPublisher = 'Contoso*'; ResolvedAppName = 'Contoso Beta' }
            $t = Resolve-AUTarget $identity $stored $m
            $t.MatchSection | Should -BeExactly 'Retained'
            $t.RetainedFrom | Should -BeExactly 'Customer'
            $t.MatchRuleId | Should -BeExactly 'c-tool-1'
            $t.TargetPattern | Should -BeExactly 'Contoso Beta*'
        }

        It 'a stored PowerStacks target beats an unverified PowerStacks match for a different target, and the conflict is logged (F15)' {
            Mock Write-CMTraceLog { }
            $m = New-TestMappings -PowerStacks @($script:RuleContoso, $script:RuleArp)
            $identity = Resolve-AUIdentity (New-TestUnverifiedFacts 'Contoso' 'Contoso Tool') $m @((New-TestApp 'Contoso Beta' 'Contoso'))
            $identity.MatchSection | Should -BeExactly 'PowerStacks'
            $identity.EvidenceUsed | Should -BeExactly 'CurrentFileAtPath'
            $t = Resolve-AUTarget $identity (New-TestStored) $m
            $t.MatchSection | Should -BeExactly 'Retained'
            $t.RetainedFrom | Should -BeExactly 'PowerStacks'
            $t.MatchRuleId | Should -BeExactly 'ps-arp-compare'
            $t.ResolvedAppName | Should -BeExactly 'Contoso Alpha'
            $t.EvidenceUsed | Should -BeExactly 'Verified'
            Should -Invoke Write-CMTraceLog -Times 1 -Exactly -ParameterFilter { $Message -like '*kept stored target ps-arp-compare*over CurrentFileAtPath match ps-contoso-1*' }
        }

        It 'a stored PowerStacks target beats an unverified match for the same target, with nothing logged' {
            Mock Write-CMTraceLog { }
            $m = New-TestMappings -PowerStacks @($script:RuleContoso)
            $identity = Resolve-AUIdentity (New-TestUnverifiedFacts 'Contoso' 'Contoso Tool') $m @((New-TestApp 'Contoso Alpha' 'Contoso'))
            $stored = New-TestStored @{ MatchRuleId = 'ps-contoso-1'; RuleType = 'identity'; TargetPattern = 'Contoso*'; TargetPublisher = 'Contoso*' }
            $t = Resolve-AUTarget $identity $stored $m
            $t.MatchSection | Should -BeExactly 'Retained'
            $t.EvidenceUsed | Should -BeExactly 'Verified'
            Should -Invoke Write-CMTraceLog -Times 0 -Exactly -ParameterFilter { $Message -like '*kept stored target*' }
        }

        It 'a Verified PowerStacks match for a different target replaces a stored PowerStacks target (F15)' {
            $m = New-TestMappings -PowerStacks @($script:RuleContoso, $script:RuleArp)
            $identity = Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = 'Contoso' }) $m @((New-TestApp 'Contoso Beta' 'Contoso'))
            $identity.EvidenceUsed | Should -BeExactly 'Verified'
            $t = Resolve-AUTarget $identity (New-TestStored) $m
            $t.MatchSection | Should -BeExactly 'PowerStacks'
            $t.MatchRuleId | Should -BeExactly 'ps-contoso-1'
            $t.ResolvedAppName | Should -BeExactly 'Contoso Beta'
        }
    }

    Context 'Customer file state (D41, D45)' {
        It 'with the customer file <State>, keeps a stored customer target whose rule ID isn''t loaded' -ForEach @(
            @{ State = 'Invalid'; Raw = '{ "schemaVersion": 1, "customer": ' }
            @{ State = 'TooLarge'; Raw = ('{ "schemaVersion": 1 }' + (' ' * 1048576)) }
        ) {
            $m = New-TestMappings -PowerStacks @($script:RuleContoso) -CustomerRaw $Raw
            $m.CustomerSource | Should -BeExactly $State
            $m.RuleIds.Contains('c-tool-1') | Should -BeFalse
            $stored = New-TestStored @{ Section = 'Customer'; MatchRuleId = 'c-tool-1'; RuleType = 'identity'; TargetPattern = 'Contoso Beta*'; TargetPublisher = 'Contoso*'; ResolvedAppName = 'Contoso Beta' }
            $identity = Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = 'Contoso' }) $m @((New-TestApp 'Contoso Alpha' 'Contoso'))
            $identity.MatchSection | Should -BeExactly 'PowerStacks'

            $t = Resolve-AUTarget $identity $stored $m -CustomerRulesUnavailable
            $t.MatchSection | Should -BeExactly 'Retained'
            $t.RetainedFrom | Should -BeExactly 'Customer'
            $t.MatchRuleId | Should -BeExactly 'c-tool-1'

            # An entry with no stored target resolves on our rules.
            $fresh = Resolve-AUTarget $identity $null $m -CustomerRulesUnavailable
            $fresh.MatchSection | Should -BeExactly 'PowerStacks'
            $fresh.MatchRuleId | Should -BeExactly 'ps-contoso-1'
        }

        It 'with the customer file Absent, a stored customer target whose rule is gone re-resolves from our rules' {
            $m = New-TestMappings -PowerStacks @($script:RuleContoso)
            $m.CustomerSource | Should -BeExactly 'Absent'
            $stored = New-TestStored @{ Section = 'Customer'; MatchRuleId = 'c-tool-1'; RuleType = 'identity'; TargetPattern = 'Contoso Beta*'; TargetPublisher = 'Contoso*'; ResolvedAppName = 'Contoso Beta' }
            $identity = Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = 'Contoso' }) $m @((New-TestApp 'Contoso Alpha' 'Contoso'))
            $t = Resolve-AUTarget $identity $stored $m
            $t.MatchSection | Should -BeExactly 'PowerStacks'
            $t.MatchRuleId | Should -BeExactly 'ps-contoso-1'
            $t.ResolvedAppName | Should -BeExactly 'Contoso Alpha'
        }
    }
}

Describe 'ConvertTo-AUStoredTarget' {
    It 'stores a Retained target from Customer with Section Customer, never Retained (F16)' {
        $m = New-TestMappings -Customer @($script:RuleCustomerBeta)
        $retained = Resolve-AUTarget $script:NoMatch (New-TestStored @{ Section = 'Customer'; MatchRuleId = 'c-tool-1'; RuleType = 'identity'; TargetPattern = 'Contoso Beta*'; TargetPublisher = 'Contoso*' }) $m
        $retained.MatchSection | Should -BeExactly 'Retained'
        $s = ConvertTo-AUStoredTarget $retained
        $s.Section | Should -BeExactly 'Customer'
        $s.MatchRuleId | Should -BeExactly 'c-tool-1'
        @($s.PSObject.Properties.Name) | Should -Be @('Section', 'MatchRuleId', 'RuleType', 'TargetPattern', 'TargetPublisher', 'ResolvedAppName', 'ProductCode', 'PackageFamily', 'EvidenceUsed')
    }

    It 'doesn''t store an unverified PowerStacks identity match (F16, D30)' {
        $m = New-TestMappings -PowerStacks @($script:RuleContoso)
        $t = Resolve-AUTarget (Resolve-AUIdentity (New-TestUnverifiedFacts 'Contoso' 'Contoso Tool') $m @((New-TestApp 'Contoso Alpha' 'Contoso'))) $null $m
        $t.MatchSection | Should -BeExactly 'PowerStacks'
        $t.EvidenceUsed | Should -BeExactly 'CurrentFileAtPath'
        ConvertTo-AUStoredTarget $t | Should -BeNullOrEmpty
    }

    It 'stores a customer match, even on current-file evidence' {
        $m = New-TestMappings -Customer @($script:RuleCustomerBeta)
        $t = Resolve-AUTarget (Resolve-AUIdentity (New-TestUnverifiedFacts 'Contoso' 'Contoso Tool') $m @((New-TestApp 'Contoso Beta' 'Contoso'))) $null $m
        $s = ConvertTo-AUStoredTarget $t
        $s.Section | Should -BeExactly 'Customer'
        $s.EvidenceUsed | Should -BeExactly 'CurrentFileAtPath'
    }

    It 'stores a Verified PowerStacks identity match and an unverified arpCompare match' {
        $m = New-TestMappings -PowerStacks @($script:RuleContoso)
        $verified = Resolve-AUTarget (Resolve-AUIdentity (New-TestFacts @{ FileCompanyName = 'Contoso' }) $m @((New-TestApp 'Contoso Alpha' 'Contoso'))) $null $m
        (ConvertTo-AUStoredTarget $verified).Section | Should -BeExactly 'PowerStacks'

        $arp = New-TestMappings -PowerStacks @($script:RuleArp)
        $unverified = Resolve-AUTarget (Resolve-AUIdentity (New-TestUnverifiedFacts 'Contoso' 'Contoso Alpha') $arp @((New-TestApp 'Contoso Alpha' 'Contoso'))) $null $arp
        $unverified.RuleType | Should -BeExactly 'arpCompare'
        (ConvertTo-AUStoredTarget $unverified).MatchRuleId | Should -BeExactly 'ps-arp-compare'
    }

    It 'stores nothing for no target' {
        ConvertTo-AUStoredTarget $script:NoMatch | Should -BeNullOrEmpty
        ConvertTo-AUStoredTarget $null | Should -BeNullOrEmpty
    }

    It 'no Task 7 function or field references ARP history (D17)' {
        $text = [IO.File]::ReadAllText((Resolve-Path "$PSScriptRoot\..\..\Intune_Windows_Inventory.ps1").Path)
        foreach ($Name in @('Get-AUStoredTargetSection', 'Test-AUSameTarget', 'Resolve-AUTarget', 'ConvertTo-AUStoredTarget', 'Get-AUInstallStatus'))
        {
            $body = [regex]::Match($text, "(?ms)^function $Name\r?\n.*?^\}#endfunction").Value
            $body | Should -Not -BeNullOrEmpty
            $body | Should -Not -Match 'LastSeenInArp|ArpHistory|UninstallDate|PreviouslyInstalled'
        }
    }
}
