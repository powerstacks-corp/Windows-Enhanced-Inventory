BeforeAll {
    . "$PSScriptRoot\_Import.ps1"

    $script:FocusTime = [DateTime]::SpecifyKind([DateTime]'2026-11-10T09:00:00', [DateTimeKind]::Utc)
    $script:InteractiveRunTime = [DateTime]::SpecifyKind([DateTime]'2026-11-12T10:00:00', [DateTimeKind]::Utc)
    $script:RanTime = [DateTime]::SpecifyKind([DateTime]'2026-11-14T11:00:00', [DateTimeKind]::Utc)

    # A ledger entry's usage dates. Pass overrides as a hashtable.
    function New-TestEntry([hashtable]$Values = @{})
    {
        $Entry = [ordered]@{
            LastFocusOrInputTime   = $script:FocusTime
            LastInteractiveRunTime = $script:InteractiveRunTime
            LastRanTime            = $script:RanTime
        }
        foreach ($Key in $Values.Keys) { $Entry[$Key] = $Values[$Key] }
        return [pscustomobject]$Entry
    }
}

Describe 'Test-AUFocusRecord' {
    It 'is false with no focus and no input' {
        Test-AUFocusRecord -UserType 'Local' -FocusSeconds 0 -InputSeconds 0 -MinFocusSeconds 1 | Should -BeFalse
    }

    It 'is true with focus at the floor by an interactive user' {
        Test-AUFocusRecord -UserType 'Local' -FocusSeconds 1 -InputSeconds 0 -MinFocusSeconds 1 | Should -BeTrue
        Test-AUFocusRecord -UserType 'CloudOnly' -FocusSeconds 1 -InputSeconds 0 -MinFocusSeconds 1 | Should -BeTrue
        Test-AUFocusRecord -UserType 'Domain' -FocusSeconds 1 -InputSeconds 0 -MinFocusSeconds 1 | Should -BeTrue
    }

    It 'is true with input and no focus' {
        Test-AUFocusRecord -UserType 'Local' -FocusSeconds 0 -InputSeconds 2 -MinFocusSeconds 1 | Should -BeTrue
    }

    It 'is false below the floor' {
        Test-AUFocusRecord -UserType 'Local' -FocusSeconds 0.5 -InputSeconds 0.5 -MinFocusSeconds 1 | Should -BeFalse
    }

    It 'is false for SYSTEM even with focus' {
        Test-AUFocusRecord -UserType 'System' -FocusSeconds 1 -InputSeconds 0 -MinFocusSeconds 1 | Should -BeFalse
    }

    It 'is false for a service account or an unknown user' {
        Test-AUFocusRecord -UserType 'Service' -FocusSeconds 5 -InputSeconds 5 -MinFocusSeconds 1 | Should -BeFalse
        Test-AUFocusRecord -UserType 'Unknown' -FocusSeconds 5 -InputSeconds 5 -MinFocusSeconds 1 | Should -BeFalse
    }

    It 'never credits a record with no focus and no input, even with a zero floor (F3)' {
        Test-AUFocusRecord -UserType 'Local' -FocusSeconds 0 -InputSeconds 0 -MinFocusSeconds 0 | Should -BeFalse
    }
}

Describe 'Get-AUDerivedUse' {
    It 'gives no credited use when the current user type is System, even with a focus date (F6)' {
        $Use = Get-AUDerivedUse -Entry (New-TestEntry) -Role 'App' -UserType 'System'
        $Use.HasCreditedUse | Should -BeFalse
        $Use.LastUsedTime | Should -BeNullOrEmpty
        $Use.LastRanTime | Should -Be $script:RanTime
    }

    It 'credits a CLI run by an interactive user with zero focus, dated by the interactive run' {
        $Entry = New-TestEntry @{ LastFocusOrInputTime = $null }
        $Use = Get-AUDerivedUse -Entry $Entry -Role 'CLI' -UserType 'Local'
        $Use.HasCreditedUse | Should -BeTrue
        $Use.LastUsedTime | Should -Be $script:InteractiveRunTime
        $Use.LastUsedTime.Kind | Should -Be ([DateTimeKind]::Utc)
    }

    It 'gives an App with no focus and no input no credited use, but keeps LastRanTime' {
        $Entry = New-TestEntry @{ LastFocusOrInputTime = $null }
        $Use = Get-AUDerivedUse -Entry $Entry -Role 'App' -UserType 'Local'
        $Use.HasCreditedUse | Should -BeFalse
        $Use.LastUsedTime | Should -BeNullOrEmpty
        $Use.LastRanTime | Should -Be $script:RanTime
    }

    It 'gives a CLI run only by SYSTEM no credited use' {
        $Entry = New-TestEntry @{ LastFocusOrInputTime = $null; LastInteractiveRunTime = $null }
        $Use = Get-AUDerivedUse -Entry $Entry -Role 'CLI' -UserType 'System'
        $Use.HasCreditedUse | Should -BeFalse
        $Use.LastUsedTime | Should -BeNullOrEmpty
        $Use.LastRanTime | Should -Be $script:RanTime
    }

    It 'gives a CLI entry with no interactive run no credited use, even for an interactive user type' {
        $Entry = New-TestEntry @{ LastInteractiveRunTime = $null }
        $Use = Get-AUDerivedUse -Entry $Entry -Role 'CLI' -UserType 'Local'
        $Use.HasCreditedUse | Should -BeFalse
        $Use.LastUsedTime | Should -BeNullOrEmpty
    }

    It 'dates a non-CLI entry by its focus or input time, not its interactive run' {
        foreach ($Role in @('App', 'Helper', 'Service', 'Installer', 'Windows', 'Unmatched'))
        {
            $Use = Get-AUDerivedUse -Entry (New-TestEntry) -Role $Role -UserType 'Domain'
            $Use.HasCreditedUse | Should -BeTrue -Because $Role
            $Use.LastUsedTime | Should -Be $script:FocusTime -Because $Role
        }
    }

    It 'credits input with zero focus for a non-CLI role' {
        # Input 2, focus 0: the record passes the focus test, so the ledger sets LastFocusOrInputTime.
        Test-AUFocusRecord -UserType 'CloudOnly' -FocusSeconds 0 -InputSeconds 2 -MinFocusSeconds 1 | Should -BeTrue
        $Use = Get-AUDerivedUse -Entry (New-TestEntry) -Role 'Helper' -UserType 'CloudOnly'
        $Use.HasCreditedUse | Should -BeTrue
        $Use.LastUsedTime | Should -Be $script:FocusTime
    }

    It 'compares the role with exact canonical casing' {
        $Entry = New-TestEntry @{ LastFocusOrInputTime = $null }
        $Use = Get-AUDerivedUse -Entry $Entry -Role 'cli' -UserType 'Local'
        $Use.HasCreditedUse | Should -BeFalse
    }

    It 'gives no use and no run for a missing entry' {
        $Use = Get-AUDerivedUse -Entry $null -Role 'App' -UserType 'Local'
        $Use.HasCreditedUse | Should -BeFalse
        $Use.LastUsedTime | Should -BeNullOrEmpty
        $Use.LastRanTime | Should -BeNullOrEmpty
    }
}
