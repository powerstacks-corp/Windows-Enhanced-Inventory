BeforeAll {
    . "$PSScriptRoot\_Import.ps1"

    $script:T0 = [DateTime]::SpecifyKind([DateTime]'2026-11-10T09:00:00', [DateTimeKind]::Utc)
    $script:Local = 'S-1-5-21-1-2-3-1001'
    $script:Other = 'S-1-5-21-1-2-3-1002'
    $script:System = 'S-1-5-18'
    $script:UserTypes = @{ $script:Local = 'Local'; $script:Other = 'Local'; $script:System = 'System' }
    $script:Acro1 = '!!acrord32.exe!2025/01/01:10:00:00!1a2b!'
    $script:Acro2 = '!!acrord32.exe!2025/06/01:10:00:00!3c4d!'
    $script:Setup1 = '!!setup.exe!2024/03/01:10:00:00!aaaa!'
    $script:Setup2 = '!!setup.exe!2024/04/01:10:00:00!bbbb!'
    $script:Keeper = '!!keeper.exe!2025/02/01:10:00:00!cccc!'
    $script:Package = 'Microsoft.WindowsCalculator_8wekyb3d8bbwe!App'

    function New-Row([string]$Sid, [string]$ExeInfo, [long]$Id, [double]$Hours, [double]$Focus = 0, [double]$InputSeconds = 0)
    {
        return [pscustomobject]@{
            UserSid      = $Sid
            ExeInfo      = $ExeInfo
            AutoIncId    = $Id
            EndTimeUtc   = $script:T0.AddHours($Hours)
            FocusSeconds = $Focus
            InputSeconds = $InputSeconds
        }
    }

    function Invoke-Merge([pscustomobject]$Ledger, [object[]]$Rows, [string]$Epoch = 'E1', [double]$MinFocusSeconds = 1)
    {
        Merge-AUSrumRecords -Ledger $Ledger -Rows $Rows -Epoch $Epoch -UserTypes $script:UserTypes -MinFocusSeconds $MinFocusSeconds
    }

    function Get-TestEntry([pscustomobject]$Ledger, [string]$Sid, [string]$ExeInfo) { return $Ledger.Entries["$Sid|$ExeInfo"] }

    function New-EmptyLedger { return (Read-AULedger -Path (Join-Path $TestDrive 'absent-ledger.json')) }

    function New-TestFacts([string]$Company, [string]$Product)
    {
        return [pscustomobject]@{
            ExeName         = 'setup.exe'
            RunPath         = 'C:\Users\u\Downloads\setup.exe'
            LocationClass   = 'Download'
            FileDescription = "$Product Setup"
            FileProductName = $Product
            FileCompanyName = $Company
            FileVersion     = '1.2.3.4'
            ProductVersion  = '1.2'
            FactsVerified   = $true
            Subsystem       = 'GUI'
            MsiProductCode  = $null
            PackageFamily   = $null
            IsServiceBinary = $false
            UserSid         = $script:Local
        }
    }

    function New-TestStoredTarget([string]$Pattern = 'Adobe Acrobat Reader*')
    {
        $Target = [pscustomobject]@{
            TargetPattern   = $Pattern
            TargetPublisher = 'Adobe*'
            ResolvedAppName = 'Adobe Acrobat Reader (64-bit)'
            ProductCode     = '{AC76BA86-1033-FFFF-7760-BC15014EA700}'
            PackageFamily   = $null
            MatchSection    = 'PowerStacks'
            MatchRuleId     = 'ps-adobe-reader'
            RuleType        = 'identity'
            EvidenceUsed    = 'Verified'
            RetainedFrom    = $null
        }
        return (ConvertTo-AUStoredTarget $Target)
    }

    # Ages out every SRUM record of every entry except the keeper, by merging a run that holds only
    # the keeper's row.
    function Invoke-AgeOut([pscustomobject]$Ledger, [long]$Id = 900)
    {
        Invoke-Merge $Ledger @(New-Row $script:Local $script:Keeper $Id 50 1)
    }
}

Describe 'Merge-AUSrumRecords' {
    It 'adds an entry keyed UserSid|ExeInfo with its exe name and focus total' {
        $L = New-EmptyLedger
        Invoke-Merge $L @((New-Row $script:Local $script:Acro1 1 0 10 2), (New-Row $script:Local $script:Acro1 2 1 5 1))
        $E = Get-TestEntry $L $script:Local $script:Acro1
        $E.UserSid | Should -Be $script:Local
        $E.ExeInfo | Should -Be $script:Acro1
        $E.ExeName | Should -Be 'acrord32.exe'
        $E.Counted.Count | Should -Be 2
        $E.Counted['E1|1'].F | Should -Be 10
        $E.Counted['E1|1'].I | Should -Be 2
        $E.Counted['E1|1'].T | Should -Be $script:T0
        $E.FocusTotal | Should -Be 15
    }

    It 'leaves FocusTotal unchanged when the same rows are merged twice (duplicate)' {
        $L = New-EmptyLedger
        $Rows = @((New-Row $script:Local $script:Acro1 1 0 10), (New-Row $script:Local $script:Acro1 2 1 5))
        Invoke-Merge $L $Rows
        Invoke-Merge $L $Rows
        (Get-TestEntry $L $script:Local $script:Acro1).FocusTotal | Should -Be 15
    }

    It 'adds only the difference when a record is updated' {
        $L = New-EmptyLedger
        Invoke-Merge $L @(New-Row $script:Local $script:Acro1 1 0 10)
        Invoke-Merge $L @(New-Row $script:Local $script:Acro1 1 0 25)
        $E = Get-TestEntry $L $script:Local $script:Acro1
        $E.FocusTotal | Should -Be 25
        $E.Counted['E1|1'].F | Should -Be 25
    }

    It 'counts a late-arriving record older than every counted record, and moves last-time fields only forward' {
        $L = New-EmptyLedger
        Invoke-Merge $L @(New-Row $script:Local $script:Acro1 5 2 10)
        Invoke-Merge $L @((New-Row $script:Local $script:Acro1 5 2 10), (New-Row $script:Local $script:Acro1 3 -5 7))
        $E = Get-TestEntry $L $script:Local $script:Acro1
        $E.FocusTotal | Should -Be 17
        $E.LastFocusOrInputTime | Should -Be $script:T0.AddHours(2)
        $E.LastRanTime | Should -Be $script:T0.AddHours(2)

        Invoke-Merge $L @((New-Row $script:Local $script:Acro1 5 2 10), (New-Row $script:Local $script:Acro1 3 -5 7), (New-Row $script:Local $script:Acro1 9 4 1))
        $E.FocusTotal | Should -Be 18
        $E.LastFocusOrInputTime | Should -Be $script:T0.AddHours(4)
    }

    It 'counts two records with equal timestamps separately' {
        $L = New-EmptyLedger
        Invoke-Merge $L @((New-Row $script:Local $script:Acro1 1 0 5), (New-Row $script:Local $script:Acro1 2 0 6))
        (Get-TestEntry $L $script:Local $script:Acro1).FocusTotal | Should -Be 11
    }

    It 'moves an aged-out record into the archived totals without changing FocusTotal' {
        $L = New-EmptyLedger
        Invoke-Merge $L @((New-Row $script:Local $script:Acro1 1 0 10 3), (New-Row $script:Local $script:Acro1 2 1 20 4))
        Invoke-Merge $L @(New-Row $script:Local $script:Acro1 2 1 20 4)
        $E = Get-TestEntry $L $script:Local $script:Acro1
        $E.ArchivedFocus | Should -Be 10
        $E.ArchivedInput | Should -Be 3
        $E.Counted.ContainsKey('E1|1') | Should -BeFalse
        $E.Counted.ContainsKey('E1|2') | Should -BeTrue
        $E.FocusTotal | Should -Be 30
    }

    It 'ages out the records of an entry that has no rows in this run' {
        $L = New-EmptyLedger
        Invoke-Merge $L @((New-Row $script:Local $script:Acro1 1 0 10), (New-Row $script:Local $script:Keeper 2 0 1))
        Invoke-AgeOut $L
        $E = Get-TestEntry $L $script:Local $script:Acro1
        $E.Counted.Count | Should -Be 0
        $E.ArchivedFocus | Should -Be 10
        $E.FocusTotal | Should -Be 10
    }

    It 'keeps counting a key of this epoch that one run missed, so it is never counted twice when it returns' {
        $L = New-EmptyLedger
        $All = @((New-Row $script:Local $script:Acro1 1 0 10), (New-Row $script:Local $script:Acro1 2 1 20), (New-Row $script:Local $script:Acro1 3 2 30))
        Invoke-Merge $L $All
        Invoke-Merge $L @($All[0], $All[2])
        $E = Get-TestEntry $L $script:Local $script:Acro1
        $E.Counted.ContainsKey('E1|2') | Should -BeTrue
        $E.ArchivedFocus | Should -Be 0
        $E.FocusTotal | Should -Be 60
        Invoke-Merge $L $All
        $E.FocusTotal | Should -Be 60
        $E.ArchivedFocus | Should -Be 0
    }

    It 'archives nothing with -NoArchive, even a missing key below the lowest ID' {
        $L = New-EmptyLedger
        Invoke-Merge $L @((New-Row $script:Local $script:Acro1 1 0 10), (New-Row $script:Local $script:Acro1 2 1 20), (New-Row $script:Local $script:Acro1 3 2 30))
        Merge-AUSrumRecords -Ledger $L -Rows @((New-Row $script:Local $script:Acro1 2 1 20), (New-Row $script:Local $script:Acro1 3 2 30)) -Epoch 'E1' -UserTypes $script:UserTypes -MinFocusSeconds 1 -NoArchive
        $E = Get-TestEntry $L $script:Local $script:Acro1
        $E.Counted.ContainsKey('E1|1') | Should -BeTrue
        $E.ArchivedFocus | Should -Be 0
        $E.FocusTotal | Should -Be 60
    }

    It 'archives a key below the lowest ID in this run once, and never again' {
        $L = New-EmptyLedger
        Invoke-Merge $L @((New-Row $script:Local $script:Acro1 1 0 10), (New-Row $script:Local $script:Acro1 2 1 20), (New-Row $script:Local $script:Acro1 3 2 30))
        $Later = @((New-Row $script:Local $script:Acro1 2 1 20), (New-Row $script:Local $script:Acro1 3 2 30))
        Invoke-Merge $L $Later
        Invoke-Merge $L $Later
        $E = Get-TestEntry $L $script:Local $script:Acro1
        $E.Counted.ContainsKey('E1|1') | Should -BeFalse
        $E.ArchivedFocus | Should -Be 10
        $E.FocusTotal | Should -Be 60
        Invoke-Merge $L @((New-Row $script:Local $script:Acro1 3 2 30), (New-Row $script:Local $script:Acro1 4 3 5))
        $E.ArchivedFocus | Should -Be 30
        $E.FocusTotal | Should -Be 65
    }

    It 'archives every old-epoch key on a new epoch and counts the new-epoch rows once' {
        $L = New-EmptyLedger
        Invoke-Merge $L @((New-Row $script:Local $script:Acro1 1 0 10), (New-Row $script:Local $script:Acro1 2 1 20)) -Epoch 'E1'
        $NewRows = @((New-Row $script:Local $script:Acro1 1 30 4), (New-Row $script:Local $script:Acro1 2 31 6))
        Invoke-Merge $L $NewRows -Epoch 'E2'
        Invoke-Merge $L $NewRows -Epoch 'E2'
        $E = Get-TestEntry $L $script:Local $script:Acro1
        $E.ArchivedFocus | Should -Be 30
        @($E.Counted.Keys | Sort-Object) | Should -Be @('E2|1', 'E2|2')
        $E.FocusTotal | Should -Be 40
    }

    It 'sets FirstSeen once, to the earliest end time of the merge that created the entry' {
        $L = New-EmptyLedger
        Invoke-Merge $L @((New-Row $script:Local $script:Acro1 2 3 1), (New-Row $script:Local $script:Acro1 1 1 1))
        $E = Get-TestEntry $L $script:Local $script:Acro1
        $E.FirstSeen | Should -Be $script:T0.AddHours(1)
        Invoke-Merge $L @((New-Row $script:Local $script:Acro1 2 3 1), (New-Row $script:Local $script:Acro1 1 1 1), (New-Row $script:Local $script:Acro1 3 -10 1))
        $E.FirstSeen | Should -Be $script:T0.AddHours(1)
    }

    It 'sets WatchingSince on the first merge only, to the earliest end time in its rows (F9)' {
        $L = New-EmptyLedger
        $L.WatchingSince | Should -BeNullOrEmpty
        Invoke-Merge $L @((New-Row $script:Local $script:Acro1 1 5 1), (New-Row $script:Other $script:Setup1 2 -2 0), (New-Row $script:Local $script:Keeper 3 1 0))
        $L.WatchingSince | Should -Be $script:T0.AddHours(-2)
        $L.WatchingSince.Kind | Should -Be 'Utc'
        Invoke-Merge $L @(New-Row $script:Local $script:Acro1 4 -48 1)
        $L.WatchingSince | Should -Be $script:T0.AddHours(-2)
    }

    It 'updates only LastRanTime for a SYSTEM row, even with focus (F6)' {
        $L = New-EmptyLedger
        Invoke-Merge $L @(New-Row $script:System $script:Acro1 1 2 30 30)
        $E = Get-TestEntry $L $script:System $script:Acro1
        $E.LastRanTime | Should -Be $script:T0.AddHours(2)
        $E.LastInteractiveRunTime | Should -BeNullOrEmpty
        $E.LastFocusOrInputTime | Should -BeNullOrEmpty
    }

    It 'treats a SID missing from UserTypes as not interactive' {
        $L = New-EmptyLedger
        Invoke-Merge $L @(New-Row 'S-1-5-21-9-9-9-500' $script:Acro1 1 2 30)
        $E = Get-TestEntry $L 'S-1-5-21-9-9-9-500' $script:Acro1
        $E.LastRanTime | Should -Be $script:T0.AddHours(2)
        $E.LastInteractiveRunTime | Should -BeNullOrEmpty
        $E.LastFocusOrInputTime | Should -BeNullOrEmpty
    }

    It 'sets LastFocusOrInputTime for a focus-1 row by a Local user with -MinFocusSeconds 1, and not for a focus-0 row (F3)' {
        $L = New-EmptyLedger
        Invoke-Merge $L @((New-Row $script:Local $script:Acro1 1 1 1), (New-Row $script:Local $script:Setup1 2 1 0)) -MinFocusSeconds 1
        $Focused = Get-TestEntry $L $script:Local $script:Acro1
        $Focused.LastFocusOrInputTime | Should -Be $script:T0.AddHours(1)
        $Background = Get-TestEntry $L $script:Local $script:Setup1
        $Background.LastFocusOrInputTime | Should -BeNullOrEmpty
        $Background.LastInteractiveRunTime | Should -Be $script:T0.AddHours(1)
        $Background.LastRanTime | Should -Be $script:T0.AddHours(1)
    }

    It 'keys a Store package entry by its ExeInfo, with ExeName $null' {
        $L = New-EmptyLedger
        Invoke-Merge $L @(New-Row $script:Local $script:Package 1 0 3)
        $E = Get-TestEntry $L $script:Local $script:Package
        $E | Should -Not -BeNullOrEmpty
        $E.ExeName | Should -BeNullOrEmpty
        $E.FocusTotal | Should -Be 3
    }

    It 'changes nothing when there are no rows, so a failed read never archives counted keys (F10)' {
        $L = New-EmptyLedger
        Invoke-Merge $L @(New-Row $script:Local $script:Acro1 1 0 10)
        Merge-AUSrumRecords -Ledger $L -Rows @() -Epoch 'E1' -UserTypes $script:UserTypes -MinFocusSeconds 1
        $E = Get-TestEntry $L $script:Local $script:Acro1
        $E.Counted.Count | Should -Be 1
        $E.ArchivedFocus | Should -Be 0
    }

    It 'finds entries ignoring case' {
        $L = New-EmptyLedger
        Invoke-Merge $L @(New-Row $script:Local $script:Acro1 1 0 10)
        $L.Entries["$($script:Local.ToLowerInvariant())|$($script:Acro1.ToUpperInvariant())"] | Should -Not -BeNullOrEmpty
    }

    It 'writes nothing to the output stream' {
        $L = New-EmptyLedger
        $Output = @(Invoke-Merge $L @(New-Row $script:Local $script:Acro1 1 0 10))
        $Output.Count | Should -Be 0
    }
}

Describe 'Write-AULedger and Read-AULedger' {
    BeforeEach {
        $script:Path = Join-Path $TestDrive "AppUsage_SER$([guid]::NewGuid().ToString('N').Substring(0, 8)).json"
    }

    It 'reads a missing file as an empty ledger with no status' {
        $L = Read-AULedger -Path $script:Path
        $L.Entries.Count | Should -Be 0
        $L.WatchingSince | Should -BeNullOrEmpty
        @($L.Status).Count | Should -Be 0
        $L.Writable | Should -BeTrue
    }

    It 'round-trips every field, with Utc dates, and a repeat merge leaves FocusTotal unchanged (F7)' {
        $L = New-EmptyLedger
        $Rows = @(
            (New-Row $script:Local $script:Acro1 11 1 12.5 3),
            (New-Row $script:Local $script:Acro1 12 2 7 0),
            (New-Row $script:Local $script:Package 13 3 0 0)
        )
        Invoke-Merge $L @((New-Row $script:Local $script:Acro1 10 -1 40 5), $Rows[0], $Rows[1], $Rows[2])
        Invoke-Merge $L $Rows
        $A = Get-TestEntry $L $script:Local $script:Acro1
        $A.Facts = New-TestFacts 'Adobe Inc.' 'Adobe Acrobat Reader'
        $A.FactsVerified = $true
        $A.StoredTarget = New-TestStoredTarget
        # A fractional-second date, to check that all seven fraction digits survive.
        $A.LastRanTime = $script:T0.AddHours(2).AddTicks(1234567)
        $P = Get-TestEntry $L $script:Local $script:Package

        $A.Counted.Count | Should -Be 2
        $A.ArchivedFocus | Should -Be 40
        $A.ArchivedInput | Should -Be 5
        $A.LastFocusOrInputTime | Should -Not -BeNullOrEmpty
        $A.LastInteractiveRunTime | Should -Not -BeNullOrEmpty

        Write-AULedger -Ledger $L -Path $script:Path
        $R = Read-AULedger -Path $script:Path

        @($R.Status).Count | Should -Be 0
        $R.WatchingSince | Should -Be $L.WatchingSince
        $R.WatchingSince.Kind | Should -Be 'Utc'
        $R.Entries.Count | Should -Be 2
        foreach ($Original in @($A, $P))
        {
            $Copy = Get-TestEntry $R $Original.UserSid $Original.ExeInfo
            $Copy | Should -Not -BeNullOrEmpty
            foreach ($Name in @('UserSid', 'ExeInfo', 'ExeName', 'ArchivedFocus', 'ArchivedInput', 'FactsVerified', 'FocusTotal'))
            {
                $Copy.$Name | Should -Be $Original.$Name -Because $Name
            }
            foreach ($Name in @('FirstSeen', 'LastFocusOrInputTime', 'LastInteractiveRunTime', 'LastRanTime'))
            {
                if ($null -eq $Original.$Name) { $Copy.$Name | Should -BeNullOrEmpty -Because $Name; continue }
                $Copy.$Name | Should -BeOfType [datetime]
                $Copy.$Name.Kind | Should -Be 'Utc' -Because $Name
                $Copy.$Name.Ticks | Should -Be $Original.$Name.Ticks -Because $Name
            }
            @($Copy.Counted.Keys | Sort-Object) | Should -Be @($Original.Counted.Keys | Sort-Object)
            foreach ($Key in $Original.Counted.Keys)
            {
                $Copy.Counted[$Key].F | Should -Be $Original.Counted[$Key].F
                $Copy.Counted[$Key].I | Should -Be $Original.Counted[$Key].I
                $Copy.Counted[$Key].T.Kind | Should -Be 'Utc'
                $Copy.Counted[$Key].T | Should -Be $Original.Counted[$Key].T
            }
        }

        $CopyA = Get-TestEntry $R $script:Local $script:Acro1
        $FactNames = @($A.Facts.PSObject.Properties.Name)
        @($CopyA.Facts.PSObject.Properties.Name) | Should -Be $FactNames
        foreach ($Name in $FactNames) { $CopyA.Facts.$Name | Should -Be $A.Facts.$Name -Because "Facts.$Name" }
        $TargetNames = @($A.StoredTarget.PSObject.Properties.Name)
        @($CopyA.StoredTarget.PSObject.Properties.Name) | Should -Be $TargetNames
        foreach ($Name in $TargetNames) { $CopyA.StoredTarget.$Name | Should -Be $A.StoredTarget.$Name -Because "StoredTarget.$Name" }
        $CopyA.StoredTarget.Section | Should -Be 'PowerStacks'

        $CopyP = Get-TestEntry $R $script:Local $script:Package
        $CopyP.Facts | Should -BeNullOrEmpty
        $CopyP.StoredTarget | Should -BeNullOrEmpty

        $R.Entries["$($script:Local.ToLowerInvariant())|$($script:Acro1.ToUpperInvariant())"] | Should -Not -BeNullOrEmpty

        Invoke-Merge $R $Rows
        (Get-TestEntry $R $script:Local $script:Acro1).FocusTotal | Should -Be $A.FocusTotal
        (Get-TestEntry $R $script:Local $script:Acro1).FocusTotal | Should -Be 59.5
    }

    It 'writes UTF-8 JSON without a BOM, with Entries and Counted as arrays and absent dates as null' {
        $L = New-EmptyLedger
        Invoke-Merge $L @(New-Row $script:Local $script:Acro1 1 0 10)
        (Get-TestEntry $L $script:Local $script:Acro1).LastFocusOrInputTime | Should -Not -BeNullOrEmpty
        Invoke-Merge $L @(New-Row $script:System $script:Setup1 2 0 0)
        Write-AULedger -Ledger $L -Path $script:Path
        $Bytes = [IO.File]::ReadAllBytes($script:Path)
        $Bytes[0] | Should -Be ([byte][char]'{')
        $Text = [IO.File]::ReadAllText($script:Path)
        $Text | Should -Match '"Entries":\['
        $Text | Should -Match '"Counted":\[\{'
        $Text | Should -Match '"LastFocusOrInputTime":null'
        $Text | Should -Not -Match '"LastFocusOrInputTime":""'
        $Text | Should -Match ([regex]::Escape('"T":"2026-11-10T09:00:00.0000000Z"'))
        Test-Path "$($script:Path).tmp" | Should -BeFalse
    }

    It 'writes a single entry with a single counted key as arrays' {
        $L = New-EmptyLedger
        Invoke-Merge $L @(New-Row $script:Local $script:Acro1 1 0 10)
        Write-AULedger -Ledger $L -Path $script:Path
        $R = Read-AULedger -Path $script:Path
        @($R.Status).Count | Should -Be 0
        (Get-TestEntry $R $script:Local $script:Acro1).Counted['E1|1'].F | Should -Be 10
    }

    It 'replaces an existing ledger file' {
        $L = New-EmptyLedger
        Invoke-Merge $L @(New-Row $script:Local $script:Acro1 1 0 10)
        Write-AULedger -Ledger $L -Path $script:Path
        Invoke-Merge $L @((New-Row $script:Local $script:Acro1 1 0 10), (New-Row $script:Local $script:Setup1 2 0 4))
        Write-AULedger -Ledger $L -Path $script:Path
        (Read-AULedger -Path $script:Path).Entries.Count | Should -Be 2
    }

    It 'moves a corrupt file aside with its bytes intact and reports LedgerReset' {
        $Bytes = [Text.Encoding]::UTF8.GetBytes('{"SchemaVersion":1,"Entries":[{"UserSid":')
        [IO.File]::WriteAllBytes($script:Path, $Bytes)
        $L = Read-AULedger -Path $script:Path
        $L.Entries.Count | Should -Be 0
        $L.WatchingSince | Should -BeNullOrEmpty
        @($L.Status) | Should -Contain 'LedgerReset'
        Test-Path $script:Path | Should -BeFalse
        $Base = [IO.Path]::GetFileNameWithoutExtension($script:Path)
        $Aside = @(Get-ChildItem -Path $TestDrive -Filter "$Base.corrupt-*.json")
        $Aside.Count | Should -Be 1
        $Aside[0].Name | Should -Match ('^' + [regex]::Escape($Base) + '\.corrupt-\d{14}\.json$')
        [IO.File]::ReadAllBytes($Aside[0].FullName) | Should -Be $Bytes
    }

    It 'treats a file in another format (the prototype array) as unreadable' {
        [IO.File]::WriteAllText($script:Path, '[{"Key":"S-1-5-21-1|x.exe","InFocusSeconds":5}]')
        $L = Read-AULedger -Path $script:Path
        @($L.Status) | Should -Contain 'LedgerReset'
        $L.Entries.Count | Should -Be 0
        Test-Path $script:Path | Should -BeFalse
    }

    It 'treats a date that is not a Utc ledger date as unreadable' {
        $L = New-EmptyLedger
        Invoke-Merge $L @(New-Row $script:Local $script:Acro1 1 0 10)
        Write-AULedger -Ledger $L -Path $script:Path
        $Text = [IO.File]::ReadAllText($script:Path).Replace('2026-11-10T09:00:00.0000000Z', '2026-11-10T09:00:00.0000000+02:00')
        [IO.File]::WriteAllText($script:Path, $Text)
        $R = Read-AULedger -Path $script:Path
        @($R.Status) | Should -Contain 'LedgerReset'
        $R.Entries.Count | Should -Be 0
    }

    It 'writes a fresh ledger after a reset without touching the corrupt copy' {
        [IO.File]::WriteAllText($script:Path, 'not json')
        $L = Read-AULedger -Path $script:Path
        Invoke-Merge $L @(New-Row $script:Local $script:Acro1 1 0 10)
        Write-AULedger -Ledger $L -Path $script:Path
        $Base = [IO.Path]::GetFileNameWithoutExtension($script:Path)
        $Aside = @(Get-ChildItem -Path $TestDrive -Filter "$Base.corrupt-*.json")
        [IO.File]::ReadAllText($Aside[0].FullName) | Should -Be 'not json'
        (Read-AULedger -Path $script:Path).Entries.Count | Should -Be 1
    }

    It 'never overwrites an unreadable file it could not move aside' {
        [IO.File]::WriteAllText($script:Path, '{"SchemaVersion":1,"Entries":[]}')
        $Before = [IO.File]::ReadAllBytes($script:Path)
        $Stream = [IO.File]::Open($script:Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        try
        {
            $L = Read-AULedger -Path $script:Path
            @($L.Status) | Should -Contain 'LedgerReset'
            $L.Writable | Should -BeFalse
            Invoke-Merge $L @(New-Row $script:Local $script:Acro1 1 0 10)
            { Write-AULedger -Ledger $L -Path $script:Path } | Should -Not -Throw
        }
        finally { $Stream.Dispose() }
        [IO.File]::ReadAllBytes($script:Path) | Should -Be $Before
    }

    It 'leaves the original bytes unchanged when the swap fails, and removes the temp file (F8)' {
        $L = New-EmptyLedger
        Invoke-Merge $L @(New-Row $script:Local $script:Acro1 1 0 10)
        Write-AULedger -Ledger $L -Path $script:Path
        $Before = [IO.File]::ReadAllBytes($script:Path)
        Invoke-Merge $L @((New-Row $script:Local $script:Acro1 1 0 10), (New-Row $script:Local $script:Setup1 2 0 4))

        Mock Move-AUFileAtomic { throw 'swap failed' }
        { Write-AULedger -Ledger $L -Path $script:Path } | Should -Throw
        Should -Invoke Move-AUFileAtomic -Times 1 -Exactly

        [IO.File]::ReadAllBytes($script:Path) | Should -Be $Before
        Test-Path "$($script:Path).tmp" | Should -BeFalse
    }
}

Describe 'Move-AUFileAtomic' {
    It 'replaces an existing target' {
        $Source = Join-Path $TestDrive 'swap-source.json'
        $Target = Join-Path $TestDrive 'swap-target.json'
        [IO.File]::WriteAllText($Source, 'new')
        [IO.File]::WriteAllText($Target, 'old')
        Move-AUFileAtomic -Source $Source -Target $Target
        [IO.File]::ReadAllText($Target) | Should -Be 'new'
        Test-Path $Source | Should -BeFalse
    }

    It 'moves the source when the target is absent' {
        $Source = Join-Path $TestDrive 'move-source.json'
        $Target = Join-Path $TestDrive 'move-target.json'
        [IO.File]::WriteAllText($Source, 'new')
        Move-AUFileAtomic -Source $Source -Target $Target
        [IO.File]::ReadAllText($Target) | Should -Be 'new'
        Test-Path $Source | Should -BeFalse
    }
}

Describe 'Invoke-AULedgerFold' {
    It 'never folds a build whose SRUM rows are still counted (F9)' {
        $L = New-EmptyLedger
        Invoke-Merge $L @((New-Row $script:Local $script:Acro1 1 0 10), (New-Row $script:Local $script:Acro2 2 1 10))
        foreach ($Exe in @($script:Acro1, $script:Acro2)) { (Get-TestEntry $L $script:Local $Exe).StoredTarget = New-TestStoredTarget }
        Invoke-AULedgerFold -Ledger $L
        $L.Entries.Count | Should -Be 2
    }

    It 'folds an aged-out build into a live build with the same target' {
        $L = New-EmptyLedger
        Invoke-Merge $L @((New-Row $script:Local $script:Acro1 1 0 10), (New-Row $script:Local $script:Acro2 2 1 6))
        foreach ($Exe in @($script:Acro1, $script:Acro2)) { (Get-TestEntry $L $script:Local $Exe).StoredTarget = New-TestStoredTarget }
        Invoke-Merge $L @(New-Row $script:Local $script:Acro2 2 1 6)
        Invoke-AULedgerFold -Ledger $L
        $L.Entries.Count | Should -Be 1
        $E = Get-TestEntry $L $script:Local $script:Acro2
        $E.ArchivedFocus | Should -Be 10
        $E.Counted.Count | Should -Be 1
        $E.FocusTotal | Should -Be 16
    }

    It 'folds two aged-out acrord32.exe builds with the same target, keeping the earliest FirstSeen, the latest last-time fields, and the summed archive' {
        $L = New-EmptyLedger
        Invoke-Merge $L @((New-Row $script:Local $script:Acro1 1 0 10 1), (New-Row $script:Local $script:Acro2 2 1 20 2), (New-Row $script:Local $script:Keeper 3 0 1))
        Invoke-AgeOut $L
        $Old = Get-TestEntry $L $script:Local $script:Acro1
        $New = Get-TestEntry $L $script:Local $script:Acro2
        foreach ($E in @($Old, $New)) { $E.StoredTarget = New-TestStoredTarget }
        $Old.FirstSeen = $script:T0.AddDays(-30)
        $New.FirstSeen = $script:T0.AddDays(-10)
        $Old.LastFocusOrInputTime = $script:T0.AddDays(-5)
        $New.LastFocusOrInputTime = $script:T0.AddDays(-2)
        $Old.LastInteractiveRunTime = $script:T0.AddDays(-1)
        $New.LastInteractiveRunTime = $script:T0.AddDays(-2)
        $Old.LastRanTime = $script:T0.AddDays(-1)
        $New.LastRanTime = $script:T0.AddDays(1)

        Invoke-AULedgerFold -Ledger $L

        $L.Entries.Count | Should -Be 2
        $Kept = @($L.Entries.Values | Where-Object { $_.ExeName -eq 'acrord32.exe' })
        $Kept.Count | Should -Be 1
        $Kept[0].ExeInfo | Should -Be $script:Acro2
        $Kept[0].FirstSeen | Should -Be $script:T0.AddDays(-30)
        $Kept[0].LastFocusOrInputTime | Should -Be $script:T0.AddDays(-2)
        $Kept[0].LastInteractiveRunTime | Should -Be $script:T0.AddDays(-1)
        $Kept[0].LastRanTime | Should -Be $script:T0.AddDays(1)
        $Kept[0].ArchivedFocus | Should -Be 30
        $Kept[0].ArchivedInput | Should -Be 3
        $Kept[0].FocusTotal | Should -Be 30
    }

    It 'never folds two setup.exe builds for one user with different verified CompanyNames' {
        $L = New-EmptyLedger
        Invoke-Merge $L @((New-Row $script:Local $script:Setup1 1 0 10), (New-Row $script:Local $script:Setup2 2 1 10), (New-Row $script:Local $script:Keeper 3 0 1))
        Invoke-AgeOut $L
        $First = Get-TestEntry $L $script:Local $script:Setup1
        $First.Facts = New-TestFacts 'Contoso Ltd' 'Installer'
        $First.FactsVerified = $true
        $Second = Get-TestEntry $L $script:Local $script:Setup2
        $Second.Facts = New-TestFacts 'Fabrikam Inc' 'Installer'
        $Second.FactsVerified = $true
        Invoke-AULedgerFold -Ledger $L
        $L.Entries.Count | Should -Be 3
    }

    It 'folds two unmatched aged-out builds with the same verified CompanyName and ProductName' {
        $L = New-EmptyLedger
        Invoke-Merge $L @((New-Row $script:Local $script:Setup1 1 0 10), (New-Row $script:Local $script:Setup2 2 1 10), (New-Row $script:Local $script:Keeper 3 0 1))
        Invoke-AgeOut $L
        foreach ($Exe in @($script:Setup1, $script:Setup2))
        {
            $E = Get-TestEntry $L $script:Local $Exe
            $E.Facts = New-TestFacts 'Contoso Ltd' 'Installer'
            $E.FactsVerified = $true
        }
        Invoke-AULedgerFold -Ledger $L
        $L.Entries.Count | Should -Be 2
    }

    It 'never folds builds with no target and no verified facts' {
        $L = New-EmptyLedger
        Invoke-Merge $L @((New-Row $script:Local $script:Setup1 1 0 10), (New-Row $script:Local $script:Setup2 2 1 10), (New-Row $script:Local $script:Keeper 3 0 1))
        Invoke-AgeOut $L
        $Unverified = Get-TestEntry $L $script:Local $script:Setup2
        $Unverified.Facts = New-TestFacts 'Contoso Ltd' 'Installer'
        $Unverified.Facts.FactsVerified = $false
        $Unverified.FactsVerified = $false
        Invoke-AULedgerFold -Ledger $L
        $L.Entries.Count | Should -Be 3
    }

    It 'never folds unmatched builds whose verified facts have no CompanyName or ProductName' {
        $L = New-EmptyLedger
        Invoke-Merge $L @((New-Row $script:Local $script:Setup1 1 0 10), (New-Row $script:Local $script:Setup2 2 1 10), (New-Row $script:Local $script:Keeper 3 0 1))
        Invoke-AgeOut $L
        foreach ($Exe in @($script:Setup1, $script:Setup2))
        {
            $E = Get-TestEntry $L $script:Local $Exe
            $E.Facts = New-TestFacts '' ''
            $E.FactsVerified = $true
        }
        Invoke-AULedgerFold -Ledger $L
        $L.Entries.Count | Should -Be 3
    }

    It 'never folds a matched build into an unmatched one, or builds with different targets' {
        $L = New-EmptyLedger
        Invoke-Merge $L @((New-Row $script:Local $script:Acro1 1 0 10), (New-Row $script:Local $script:Acro2 2 1 10), (New-Row $script:Local $script:Keeper 3 0 1))
        Invoke-AgeOut $L
        $First = Get-TestEntry $L $script:Local $script:Acro1
        $First.StoredTarget = New-TestStoredTarget
        $Second = Get-TestEntry $L $script:Local $script:Acro2
        $Second.Facts = New-TestFacts 'Adobe Inc.' 'Adobe Acrobat Reader'
        $Second.FactsVerified = $true
        Invoke-AULedgerFold -Ledger $L
        $L.Entries.Count | Should -Be 3

        $Second.StoredTarget = New-TestStoredTarget 'Adobe Acrobat DC*'
        Invoke-AULedgerFold -Ledger $L
        $L.Entries.Count | Should -Be 3
    }

    It 'never folds builds of different users' {
        $L = New-EmptyLedger
        Invoke-Merge $L @((New-Row $script:Local $script:Acro1 1 0 10), (New-Row $script:Other $script:Acro2 2 1 10), (New-Row $script:Local $script:Keeper 3 0 1))
        Invoke-AgeOut $L
        (Get-TestEntry $L $script:Local $script:Acro1).StoredTarget = New-TestStoredTarget
        (Get-TestEntry $L $script:Other $script:Acro2).StoredTarget = New-TestStoredTarget
        Invoke-AULedgerFold -Ledger $L
        $L.Entries.Count | Should -Be 3
    }

    It 'never folds Store package entries, which have no exe name' {
        $L = New-EmptyLedger
        $Package2 = 'Microsoft.WindowsCalculator_11.2401.0.0_x64__8wekyb3d8bbwe'
        Invoke-Merge $L @((New-Row $script:Local $script:Package 1 0 10), (New-Row $script:Local $Package2 2 1 10), (New-Row $script:Local $script:Keeper 3 0 1))
        Invoke-AgeOut $L
        foreach ($Exe in @($script:Package, $Package2)) { (Get-TestEntry $L $script:Local $Exe).StoredTarget = New-TestStoredTarget }
        Invoke-AULedgerFold -Ledger $L
        $L.Entries.Count | Should -Be 3
    }
}

Describe 'Ledger file access (D18)' {
    BeforeAll {
        function Assert-ProtectedAcl([string]$Path)
        {
            $Acl = Get-Acl -LiteralPath $Path
            $Acl.AreAccessRulesProtected | Should -BeTrue
            $Rules = @($Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
            $Rules.Count | Should -Be 2
            @($Rules | ForEach-Object { $_.IdentityReference.Value } | Sort-Object) | Should -Be @('S-1-5-18', 'S-1-5-32-544')
            foreach ($Rule in $Rules)
            {
                $Rule.AccessControlType | Should -Be 'Allow'
                $Rule.FileSystemRights | Should -Be ([Security.AccessControl.FileSystemRights]::FullControl)
                $Rule.IsInherited | Should -BeFalse
            }
        }
    }

    BeforeEach {
        $script:Path = Join-Path $TestDrive "AppUsage_ACL$([guid]::NewGuid().ToString('N').Substring(0, 8)).json"
    }

    It 'gives a new ledger file a protected DACL for SYSTEM and Administrators only' {
        $L = New-EmptyLedger
        Invoke-Merge $L @(New-Row $script:Local $script:Acro1 1 0 10)
        Write-AULedger -Ledger $L -Path $script:Path
        Assert-ProtectedAcl $script:Path
    }

    It 'protects an existing ledger that had an inherited DACL when it replaces it' {
        [IO.File]::WriteAllText($script:Path, '{"SchemaVersion":1,"WatchingSince":null,"Entries":[]}')
        (Get-Acl -LiteralPath $script:Path).AreAccessRulesProtected | Should -BeFalse
        $L = New-EmptyLedger
        Invoke-Merge $L @(New-Row $script:Local $script:Acro1 1 0 10)
        Write-AULedger -Ledger $L -Path $script:Path
        Assert-ProtectedAcl $script:Path
        (Read-AULedger -Path $script:Path).Entries.Count | Should -Be 1
    }

    It 'logs only the reason and counts for an unreadable ledger, never its text: <Case>' -ForEach @(
        @{ Case = 'invalid JSON'; Reason = "it isn't valid JSON"; Text = '{"SchemaVersion":1,"WatchingSince":null,"Entries":[{"UserSid":"S-1-5-21-1-2-3-1001","ExeInfo":"\Device\HarddiskVolume3\Users\alice\AppData\Local\Secret\secret.exe","Counted":' }
        @{ Case = 'a repeated entry'; Reason = 'entry 2 of 2 repeats an earlier one'; Text = 'DUPLICATE' }
        @{ Case = 'a malformed entry'; Reason = "entry 1 of 1 isn't valid"; Text = 'BADDATE' }
    ) {
        function Write-CMTraceLog { param ([string]$Message, [string]$Component, [int]$Type) }
        $script:Logged = [Collections.Generic.List[string]]::new()
        Mock Write-CMTraceLog { $script:Logged.Add([string]$Message) }
        $Exe = '\Device\HarddiskVolume3\Users\alice\AppData\Local\Secret\secret.exe'
        if ($Text -eq 'DUPLICATE' -or $Text -eq 'BADDATE')
        {
            $L = New-EmptyLedger
            Invoke-Merge $L @(New-Row $script:Local $Exe 1 0 10)
            Write-AULedger -Ledger $L -Path $script:Path
            $Data = [IO.File]::ReadAllText($script:Path) | ConvertFrom-Json
            if ($Text -eq 'DUPLICATE') { $Data.Entries = @($Data.Entries[0], $Data.Entries[0]) }
            else { $Data.Entries[0].FirstSeen = 'C:\Users\alice\AppData\Local\Secret\secret.exe' }
            $Text = $Data | ConvertTo-Json -Depth 8 -Compress
        }
        [IO.File]::WriteAllText($script:Path, $Text)
        @((Read-AULedger -Path $script:Path).Status) | Should -Contain 'LedgerReset'
        $Line = @($script:Logged | Where-Object { $_ -like '*is unreadable*' })
        $Line.Count | Should -Be 1
        $Line[0] | Should -BeLike ("*($Reason; *characters)*")
        foreach ($Private in @('secret', 'alice', 'S-1-5-21')) { $Line[0] | Should -Not -BeLike "*$Private*" -Because $Private }
    }

    It 'protects the moved-aside copy of an unreadable ledger' {
        [IO.File]::WriteAllText($script:Path, 'not json')
        $null = Read-AULedger -Path $script:Path
        $Base = [IO.Path]::GetFileNameWithoutExtension($script:Path)
        $Aside = @(Get-ChildItem -Path $TestDrive -Filter "$Base.corrupt-*.json")
        $Aside.Count | Should -Be 1
        Assert-ProtectedAcl $Aside[0].FullName
    }

    It 'still writes the ledger when the DACL cannot be set' {
        Mock Set-AUProtectedAcl { throw 'acl failed' }
        $L = New-EmptyLedger
        Invoke-Merge $L @(New-Row $script:Local $script:Acro1 1 0 10)
        { Write-AULedger -Ledger $L -Path $script:Path } | Should -Not -Throw
        Should -Invoke Set-AUProtectedAcl -Times 1
        (Get-TestEntry (Read-AULedger -Path $script:Path) $script:Local $script:Acro1).FocusTotal | Should -Be 10
        Test-Path "$($script:Path).tmp" | Should -BeFalse
    }
}
