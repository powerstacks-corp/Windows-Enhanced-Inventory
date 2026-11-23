BeforeDiscovery {
    . "$PSScriptRoot\_ImportInventory.ps1"
    $InventoryCases = @(Get-TestInventoryCases)
}

BeforeAll {
    . "$PSScriptRoot\_Import.ps1"
    . "$PSScriptRoot\_ImportInventory.ps1"

    $script:Fixture = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures\v19-appinventory.json'), [Text.Encoding]::UTF8))
    $script:ScriptText = Get-TestScriptText

    $script:MachineDomain = 'S-1-5-21-100-200-300'
    $script:SignedIn = 'S-1-12-1-1111-2222-3333-4444'
    $script:SignedOut = 'S-1-5-21-100-200-300-1002'
    $script:SystemSid = 'S-1-5-18'
    $script:Recent = [datetime]::SpecifyKind([datetime]'2026-11-20T15:30:00', [DateTimeKind]::Utc)

    function ConvertTo-TestEmbedded([string]$Json)
    {
        $Buffer = New-Object IO.MemoryStream
        $Zip = New-Object IO.Compression.GZipStream($Buffer, [IO.Compression.CompressionMode]::Compress)
        $Bytes = (New-Object Text.UTF8Encoding $false).GetBytes($Json)
        $Zip.Write($Bytes, 0, $Bytes.Length)
        $Zip.Dispose()
        return [Convert]::ToBase64String($Buffer.ToArray())
    }
    $script:Embedded = ConvertTo-TestEmbedded ('{"schemaVersion":1,"powerStacks":{"version":"2026.11.22.9","identityRules":[' +
        '{"id":"ps-alpha","type":"identity","when":{"exeName":"alpha.exe","publisher":"Contoso"},"target":{"displayName":"Contoso Alpha*","publisher":"Contoso"}}],' +
        '"classificationRules":[]}}')

    # The D20 device: machine apps, a signed-in user, and a signed-out user with two per-user apps,
    # one of them shared with the signed-in user at a lower version. Each app is given once and
    # turned into both shapes: version 19's Get-InstalledApplications output (the machine and the
    # signed-in user only) and Task 13's discovery output (every profile).
    $script:Uninstall = 'Software\Microsoft\Windows\CurrentVersion\Uninstall'
    $script:DeviceApps = @(
        @{ Name = 'Contoso Alpha'; Version = '2.0'; Publisher = 'Contoso'; Date = '20260901'; Scope = 'Machine'; Key = 'ContosoAlpha' }
        @{ Name = 'Fabrikam Tool'; Version = '4.1'; Publisher = 'Fabrikam'; Date = '20250101'; Scope = 'Machine'; Key = 'FabrikamTool' }
        @{ Name = 'Contoso Beta'; Version = '1.5'; Publisher = 'Contoso'; Date = '20260310'; Scope = $script:SignedIn; Key = 'ContosoBeta' }
        @{ Name = 'Litware Notes'; Version = '3.0'; Publisher = 'Litware'; Date = '20261001'; Scope = $script:SignedIn; Key = 'LitwareNotes' }
        @{ Name = 'Litware Notes'; Version = '2.0'; Publisher = 'Litware'; Date = '20240501'; Scope = $script:SignedOut; Key = 'LitwareNotes' }
        @{ Name = 'Proseware Diary'; Version = '1.0'; Publisher = 'Proseware'; Date = '20260202'; Scope = $script:SignedOut; Key = 'ProsewareDiary' }
    )

    function Get-TestRegPath($App)
    {
        if ($App.Scope -eq 'Machine') { return "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$($App.Key)" }
        return "HKEY_USERS\$($App.Scope)\$($script:Uninstall)\$($App.Key)"
    }

    # Version 19's read: the machine and the signed-in user.
    function New-TestV19Apps
    {
        return , @($script:DeviceApps | Where-Object { $_.Scope -eq 'Machine' -or $_.Scope -eq $script:SignedIn } | ForEach-Object {
                [pscustomobject][ordered]@{ DisplayName = $_.Name; DisplayVersion = $_.Version; Publisher = $_.Publisher; InstallDate = $_.Date; UninstallString = "C:\Apps\$($_.Key)\uninstall.exe"; PSPath = 'Microsoft.PowerShell.Core\Registry::' + (Get-TestRegPath $_) }
            })
    }

    function New-TestScopeRead
    {
        $ScopeRead = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
        foreach ($Scope in 'Machine', $script:SystemSid, $script:SignedIn, $script:SignedOut) { $ScopeRead[$Scope] = 'Read' }
        return $ScopeRead
    }

    # Task 13's read: every profile.
    function New-TestDiscovery([switch]$Failed)
    {
        $Apps = @($script:DeviceApps | ForEach-Object {
                [pscustomobject][ordered]@{
                    DisplayName = $_.Name; DisplayVersion = $_.Version; Publisher = $_.Publisher; ProductCode = $null; PackageFamily = $null; InstallLocation = $null; DisplayIcon = $null
                    UninstallString = "C:\Apps\$($_.Key)\uninstall.exe"; Architecture = 64; Scope = $_.Scope; ProfilePath = $null; InstallDate = $_.Date; AppType = 'Win32'; RegPath = (Get-TestRegPath $_)
                }
            })
        $ScopeRead = New-TestScopeRead
        if ($Failed) { $ScopeRead['Machine'] = 'Unread' }
        return [pscustomobject]@{ Apps = $Apps; ScopeRead = $ScopeRead; MsiFileMap = @{}; ProfilesFound = 3; ProfilesRead = 3; MsiFileMapRead = $true; HiveUnloadFailures = 0 }
    }

    function New-TestUsers
    {
        @(
            [pscustomobject]@{ Sid = $script:SystemSid; UserType = 'System'; ProfilePath = 'C:\Windows\system32\config\systemprofile'; ProfileState = 'Loaded' }
            [pscustomobject]@{ Sid = $script:SignedIn; UserType = 'CloudOnly'; ProfilePath = 'C:\Users\a'; ProfileState = 'Loaded' }
            [pscustomobject]@{ Sid = $script:SignedOut; UserType = 'Local'; ProfilePath = 'C:\Users\b'; ProfileState = 'Copied' }
        )
    }

    # The metering-on device: every boundary App Usage touches is mocked; the rest runs for real.
    function Use-TestMeteredDevice
    {
        $Id = [guid]::NewGuid().ToString('N')
        $script:LedgerPath = Join-Path $TestDrive "AppUsage_$Id.json"
        $script:OutboxDir = Join-Path $TestDrive "AppUsage_$($Id)_outbox"
        $script:AppUsageMappingsEmbedded = $script:Embedded
        $script:Discovery = New-TestDiscovery
        $script:Srum = [pscustomobject]@{ Epoch = 'E1'; Timeline = @([pscustomobject]@{ UserSid = $script:SignedIn; ExeInfo = '!!alpha.exe!2026/01/01:00:00:00!1a2b!'; AutoIncId = 100; EndTimeUtc = $script:Recent; FocusSeconds = 30; InputSeconds = 0 }); Resource = @(); Status = 'OK'; Repaired = $false; Complete = $true }
        $script:Metered = @{ CollectAppMetering = $true; AppUsageCustomerMappingsPath = (Join-Path $TestDrive 'absent-customer-mappings.json'); MinFocusSecondsForUse = 1 }

        # The ledger already knows alpha.exe's verified facts, so ps-alpha matches it to Contoso Alpha.
        $ExeInfo = '!!alpha.exe!2026/01/01:00:00:00!1a2b!'
        $Entry = New-AULedgerEntry $script:SignedIn $ExeInfo
        $Entry.Facts = [pscustomobject][ordered]@{
            ExeName = 'alpha.exe'; RunPath = 'C:\Program Files\Contoso\alpha.exe'; LocationClass = 'ProgramFiles'; FileDescription = 'alpha.exe'; FileProductName = 'alpha.exe'
            FileCompanyName = 'Contoso'; FileVersion = '2.0.0.0'; ProductVersion = '2.0.0.0'; FactsVerified = $true; Subsystem = 'GUI'; MsiProductCode = $null; PackageFamily = $null
            IsServiceBinary = $false; UserSid = $null; PathEvidence = $null
        }
        $Entry.FactsVerified = $true
        Update-AULedgerEntryTotal $Entry
        $Ledger = New-AULedger
        $Ledger.WatchingSince = [datetime]::SpecifyKind([datetime]'2026-10-01T08:00:00', [DateTimeKind]::Utc)
        $Ledger.Entries["$($script:SignedIn)|$ExeInfo"] = $Entry
        Write-AULedger -Ledger $Ledger -Path $script:LedgerPath

        Mock Get-AULanguageMode { 'FullLanguage' }
        Mock Get-AUOsBuild { 26200 }
        Mock Get-AUSerial { 'TESTSERIAL' }
        Mock Get-AULedgerPath { $script:LedgerPath }
        Mock Get-AUOutboxPath { $script:OutboxDir }
        # The run lock is mocked. The outbox lock is the real one: Send-AUInventoryRun's work refers
        # to its own variables, which a mock's scope doesn't see.
        Mock Invoke-AUWithLock -ParameterFilter { $Name -ne $script:AUOutboxLockName } {
            $Outcome = [pscustomobject]@{ Acquired = $true; Abandoned = $false; Result = $null; Error = $null }
            try { $Outcome.Result = & $Body } catch { $Outcome.Error = $_.Exception.Message }
            $Outcome
        }
        Mock New-AUWorkDir { Join-Path $TestDrive "run-$RunId" }
        Mock New-AUSnapshot { [pscustomobject]@{ WorkDir = $WorkDir; ShadowId = $null; ShadowRoot = $null; SrumDbPath = (Join-Path $WorkDir 'sru\SRUDB.dat'); HiveCopies = @{}; MachineDomainSid = $script:MachineDomain; Status = 'OK' } }
        Mock Remove-AUSnapshot { }
        Mock Get-AUUsers { New-TestUsers }
        Mock Get-AUInstalledApps { $script:Discovery }
        Mock Read-AUSrum { $script:Srum }
        Mock Get-AUServiceBinaries { @{} }
        Mock New-AUReadBudget { [pscustomobject]@{ Id = 'run-budget'; TimeoutMs = 5000; RemainingMs = 120000; Runspace = $null; ScriptText = $null; Reads = 0; TimedOut = 0; Skipped = 0; DirectRoots = @() } }
        Mock Close-AUReadBudget { }
        Mock Find-AUExePath { $null }
    }

    function Invoke-TestMetered([hashtable]$Settings = @{}, [scriptblock]$SendResponse, [switch]$Summary, [object[]]$Apps = (New-TestV19Apps), [switch]$RealUpload, [switch]$RealLogger)
    {
        $All = @{}
        foreach ($Key in $script:Metered.Keys) { $All[$Key] = $script:Metered[$Key] }
        foreach ($Key in $Settings.Keys) { $All[$Key] = $Settings[$Key] }
        return Invoke-TestAppInventory -ScriptText $script:ScriptText -Settings $All -Apps $Apps -SendResponse $SendResponse -Summary:$Summary -RealUpload:$RealUpload -RealLogger:$RealLogger
    }

    # A sent body as the service receives it.
    function ConvertFrom-TestSend($Send)
    {
        $Parsed = ConvertFrom-Json -InputObject $Send.Text
        if ($Send.Mode -eq 'LogIngestionAPI') { return @($Parsed)[0] }
        return $Parsed
    }

    # Windows PowerShell 5.1 ConvertFrom-Json writes an array as one object; this gives its items.
    function ConvertFrom-TestJsonArray([string]$Text)
    {
        $Parsed = ConvertFrom-Json -InputObject $Text
        return , @($Parsed | ForEach-Object { $_ })
    }

    function Get-TestEntryCore($Entries)
    {
        return @($Entries | ForEach-Object { $_ | Select-Object AppName, AppVersion, AppPublisher, AppType, AppInstallDate, AppUninstallString, AppUninstallRegPath } | Sort-Object AppName)
    }
}

Describe 'App Inventory with metering off: byte-identical to version 19 (F32, F39)' {
    It 'matches the version 19 fixture for <Name>' -ForEach $InventoryCases {
        Mock Invoke-AppUsage { throw 'App Usage must not run with metering off.' }
        $Expected = @($script:Fixture.Cases | Where-Object { $_.Name -eq $Name })[0].Result
        $Run = Invoke-TestAppInventory -ScriptText $script:ScriptText -Settings $Settings -Apps (New-TestInventoryApps -Filler $Filler)
        @($Run.Errors) | Should -BeNullOrEmpty
        $Actual = ConvertTo-TestInventorySummary (ConvertTo-TestInventoryCapture $Run) -WithText:($Filler -eq 0)
        $Actual.SendCount | Should -Be $Expected.SendCount
        $Actual.LogType | Should -BeExactly $Expected.LogType
        @($Actual.MainAppNames) | Should -Be @($Expected.MainAppNames)
        $Actual.MainAppSha256 | Should -BeExactly $Expected.MainAppSha256
        $Actual.BodyLength | Should -Be $Expected.BodyLength
        $Actual.BodySha256 | Should -BeExactly $Expected.BodySha256
        $Actual.DecodedLength | Should -Be $Expected.DecodedLength
        $Actual.DecodedSha256 | Should -BeExactly $Expected.DecodedSha256
        $Actual.Response | Should -BeExactly $Expected.Response
        if ($Filler -eq 0)
        {
            $Actual.Body | Should -BeExactly $Expected.Body
            $Actual.DecodedPayload | Should -BeExactly $Expected.DecodedPayload
        }
        Should -Invoke Invoke-AppUsage -Times 0 -Exactly
    }

    It 'reads Store apps exactly when $CollectUWPInventory is on, as version 19 does (D46)' {
        foreach ($Store in $false, $true)
        {
            $Run = Invoke-TestAppInventory -ScriptText $script:ScriptText -Settings @{ CollectUWPInventory = $Store }
            $Run.Calls.InstalledApplications | Should -Be 1
            $Run.Calls.AppxInstalledApplications | Should -Be ([int]$Store)
            $V19 = Invoke-TestAppInventory -ScriptText (Get-TestV19ScriptText) -Settings @{ CollectUWPInventory = $Store }
            $V19.Calls.AppxInstalledApplications | Should -Be ([int]$Store)
        }
    }

    It 'gives the version 19 summary message' {
        $V19 = Invoke-TestAppInventory -ScriptText (Get-TestV19ScriptText) -Summary
        $Now = Invoke-TestAppInventory -ScriptText $script:ScriptText -Summary
        $Pattern = '^InventoryDate: \d\d-\d\d \d\d:\d\d  AppInventory: OK 204 : Upload payload size is [\d.]+Kb $'
        $V19.Message | Should -Match $Pattern
        $Now.Message | Should -Match $Pattern
        ($Now.Message -replace '^InventoryDate: \S+ \S+ ', '') | Should -BeExactly ($V19.Message -replace '^InventoryDate: \S+ \S+ ', '')
        @($Now.Output) | Should -Be @($Now.Message)
        @($Now.BlockOutput) | Should -BeNullOrEmpty
    }

    It 'still stops on an InstalledApps blob over 10 pieces, as version 19 does' {
        $Huge = New-TestInventoryApps -Filler 5000
        $V19Error = $null
        try { [void](Invoke-TestAppInventory -ScriptText (Get-TestV19ScriptText) -Settings @{ LogAPIMode = 'DataCollectorAPI' } -Apps $Huge) } catch { $V19Error = $_.Exception.Message }
        $NowError = $null
        try { [void](Invoke-TestAppInventory -ScriptText $script:ScriptText -Settings @{ LogAPIMode = 'DataCollectorAPI' } -Apps $Huge) } catch { $NowError = $_.Exception.Message }
        $V19Error | Should -Match 'InstallApp is too big'
        $NowError | Should -BeExactly $V19Error
    }
}

Describe 'App Inventory with metering on' {
    BeforeEach { Use-TestMeteredDevice }

    It 'gives the version 19 entries plus the signed-out user''s other app, the shared app once at its higher version, every entry with the usage fields (D20)' {
        $Off = Invoke-TestAppInventory -ScriptText $script:ScriptText -Apps (New-TestV19Apps)
        $On = Invoke-TestMetered
        @($On.Errors) | Should -BeNullOrEmpty
        $On.Calls.InstalledApplications | Should -Be 0

        $Expected = @(Get-TestEntryCore $Off.AppArray) + @(Get-TestEntryCore @($On.AppArray | Where-Object { $_.AppName -eq 'Proseware Diary' }))
        $Expected = @($Expected | Sort-Object AppName)
        $Actual = Get-TestEntryCore $On.AppArray
        ($Actual | ConvertTo-Json -Compress) | Should -BeExactly ($Expected | ConvertTo-Json -Compress)
        @($On.AppArray | Where-Object { $_.AppName -eq 'Litware Notes' }).Count | Should -Be 1
        @($On.AppArray | Where-Object { $_.AppName -eq 'Litware Notes' })[0].AppVersion | Should -BeExactly '3.0'
        @($On.AppArray | Where-Object { $_.AppName -eq 'Proseware Diary' })[0].AppUninstallRegPath | Should -BeExactly "HKEY_USERS\$($script:SignedOut)\$($script:Uninstall)\ProsewareDiary"
        foreach ($Entry in $On.AppArray)
        {
            $Names = @($Entry.PSObject.Properties.Name)
            $Names.Count | Should -Be 14
            @($Names | Select-Object -Last 7) | Should -Be $script:AUAppFieldNames
        }
        @($On.AppArray | Where-Object { $_.AppName -eq 'Contoso Alpha' })[0].AppUsageStatus | Should -BeExactly 'Used'
    }

    It 'sends one row, 1 of 1, with the run columns, the device columns, and both blobs' {
        $Run = Invoke-TestMetered
        @($Run.Sends).Count | Should -Be 1
        $Row = ConvertFrom-TestSend $Run.Sends[0]
        $Run.Sends[0].LogType | Should -BeExactly 'PowerStacksAppInventory_CL'
        $Row.RunId_g | Should -Match '^[0-9a-f]{8}-'
        $Row.RowIndex_d | Should -Be 1
        $Row.RowCount_d | Should -Be 1
        $Row.ComputerName_s | Should -BeExactly 'TESTPC-0001'
        $Row.AppUsageEnabled_b | Should -BeTrue
        $Row.AppUsageCollectionStatus_s | Should -BeExactly 'OK'
        $Row.MappingsVersion_s | Should -BeExactly '2026.11.22.9'
        $Row.ProfilesFound_d | Should -Be 3
        $Apps = ConvertFrom-TestJsonArray (Expand-TestInventoryPieces (Get-TestRowPieces $Row 'InstalledApps'))
        @($Apps).Count | Should -Be 5
        @($Apps | Where-Object { $_.AppName -eq 'Contoso Alpha' })[0].AppUsageStatus | Should -BeExactly 'Used'
        $Exes = ConvertFrom-TestJsonArray (Expand-TestInventoryPieces (Get-TestRowPieces $Row 'ExeUsage'))
        @($Exes | Where-Object { $_.ExeName -eq 'alpha.exe' }).Count | Should -Be 1
        @($Run.MainApp.PSObject.Properties.Name) | Should -Be @('ComputerName_s', 'ManagedDeviceID_g', 'AppUsageEnabled_b', 'WatchingSince_t', 'AppUsageScriptVersion_s', 'MappingsVersion_s', 'CustomerMappingsHash_s', 'UnmatchedExeCount_d', 'ProfilesFound_d', 'ProfilesRead_d', 'AppUsageCollectionStatus_s')
        $Run.Response | Should -Match '^204 : Upload payload size is [\d.]+Kb \(1 row\) $'
    }

    It 'uses the inventory''s own read and reports DiscoveryFailed when the all-profile read fails (D36)' {
        $script:Discovery = New-TestDiscovery -Failed
        $Off = Invoke-TestAppInventory -ScriptText $script:ScriptText -Apps (New-TestV19Apps)
        $Run = Invoke-TestMetered
        $Run.Calls.InstalledApplications | Should -Be 1
        $Row = ConvertFrom-TestSend $Run.Sends[0]
        @($Row.AppUsageCollectionStatus_s -split '; ') | Should -Contain 'DiscoveryFailed'
        ((Get-TestEntryCore $Run.AppArray) | ConvertTo-Json -Compress) | Should -BeExactly ((Get-TestEntryCore $Off.AppArray) | ConvertTo-Json -Compress)
        foreach ($Entry in $Run.AppArray) { foreach ($Field in $script:AUAppFieldNames) { $Entry.PSObject.Properties[$Field] | Should -Not -BeNullOrEmpty; $Entry.$Field | Should -BeNullOrEmpty } }
        (ConvertFrom-TestJsonArray (Expand-TestInventoryPieces (Get-TestRowPieces $Row 'ExeUsage'))).Count | Should -BeGreaterThan 0
    }

    It 'leaves the inventory unchanged when App Usage skips: <Case>' -ForEach @(
        @{ Case = 'UnsupportedOS (D42)'; Token = 'UnsupportedOS'; Setup = { Mock Get-AUOsBuild { 26100 } } }
        @{ Case = 'Constrained Language (D37)'; Token = 'LanguageMode:ConstrainedLanguage'; Setup = { Mock Get-AULanguageMode { 'ConstrainedLanguage' } } }
        @{ Case = 'serial unread'; Token = 'AppUsageFailed:Serial'; Setup = { Mock Get-AUSerial { $null } } }
    ) {
        & $Setup
        $Off = Invoke-TestAppInventory -ScriptText $script:ScriptText -Apps (New-TestV19Apps)
        $Run = Invoke-TestMetered
        @($Run.Errors) | Should -BeNullOrEmpty
        Should -Invoke New-AUSnapshot -Times 0 -Exactly
        $Run.Calls.InstalledApplications | Should -Be 1
        ((Get-TestEntryCore $Run.AppArray) | ConvertTo-Json -Compress) | Should -BeExactly ((Get-TestEntryCore $Off.AppArray) | ConvertTo-Json -Compress)
        $Row = ConvertFrom-TestSend $Run.Sends[0]
        @($Row.AppUsageCollectionStatus_s -split '; ') | Should -Contain $Token
        $Row.RowCount_d | Should -Be 1
        $Run.Response | Should -Match '^204 : '
    }

    It 'with Store inventory off, neither discovers nor meters Store apps (D46)' {
        $Run = Invoke-TestMetered
        Should -Invoke Get-AUInstalledApps -Times 1 -Exactly -ParameterFilter { -not $IncludeStore }
        $Run.Calls.AppxInstalledApplications | Should -Be 0
    }

    It 'with Store inventory on, discovers and meters them (D46)' {
        $Run = Invoke-TestMetered -Settings @{ CollectUWPInventory = $true }
        Should -Invoke Get-AUInstalledApps -Times 1 -Exactly -ParameterFilter { $IncludeStore }
        # The all-profile read has the Store apps, so the inventory's own Store read isn't needed.
        $Run.Calls.AppxInstalledApplications | Should -Be 0
        $script:Discovery = New-TestDiscovery -Failed
        $Fallback = Invoke-TestMetered -Settings @{ CollectUWPInventory = $true }
        $Fallback.Calls.AppxInstalledApplications | Should -Be 1
    }

    It 'still uploads the inventory, through the run rows, when Invoke-AppUsage throws (F45)' {
        Mock Invoke-AppUsage { throw 'simulated App Usage failure' }
        $Run = Invoke-TestMetered
        @($Run.Errors) | Should -BeNullOrEmpty
        $Run.Calls.InstalledApplications | Should -Be 1
        @($Run.Sends).Count | Should -Be 1
        $Row = ConvertFrom-TestSend $Run.Sends[0]
        $Row.InstalledApps1_s | Should -Not -BeNullOrEmpty
        $Row.RunId_g | Should -Match '^[0-9a-f]{8}-'
        $Row.RowCount_d | Should -Be 1
        $Row.AppUsageCollectionStatus_s | Should -BeExactly 'AppUsageFailed'
        $Row.PSObject.Properties['ExeUsage1_s'] | Should -BeNullOrEmpty
        foreach ($Entry in $Run.AppArray) { $Entry.AppUsageStatus | Should -BeNullOrEmpty }
        $Run.Response | Should -Match '^204 : '
    }

    It 'falls back to the version 19 upload when the run rows cannot be built' {
        Mock New-AURunRows { throw 'simulated row failure' }
        $Run = Invoke-TestMetered
        @($Run.Sends).Count | Should -Be 1
        $Row = ConvertFrom-TestSend $Run.Sends[0]
        @($Row.PSObject.Properties.Name) | Should -Be @('ComputerName_s', 'ManagedDeviceID_g', 'InstalledApps1_s')
        $Run.Response | Should -Match '^204 : Upload payload size is [\d.]+Kb $'
    }

    It 'reports AppUsageBusy when the run lock is busy, uses its own read, and leaves the usage fields blank' {
        Mock Invoke-AUWithLock -ParameterFilter { $Name -ne $script:AUOutboxLockName } { [pscustomobject]@{ Acquired = $false; Abandoned = $false; Result = $null; Error = $null } }
        $Run = Invoke-TestMetered
        $Run.Calls.InstalledApplications | Should -Be 1
        $Row = ConvertFrom-TestSend $Run.Sends[0]
        @($Row.AppUsageCollectionStatus_s -split '; ') | Should -Contain 'AppUsageBusy'
        foreach ($Entry in $Run.AppArray) { foreach ($Field in $script:AUAppFieldNames) { $Entry.$Field | Should -BeNullOrEmpty } }
        Should -Invoke New-AUSnapshot -Times 0 -Exactly
    }

    It 'sends a device too large for one row as a split run instead of stopping (D44, F45)' {
        $Huge = New-TestInventoryApps -Filler 5000
        $script:Discovery = New-TestDiscovery -Failed
        $Run = Invoke-TestMetered -Settings @{ LogAPIMode = 'DataCollectorAPI' } -Apps $Huge -Summary
        @($Run.Errors) | Should -BeNullOrEmpty
        @($Run.Sends).Count | Should -BeGreaterThan 1
        $Rows = @($Run.Sends | ForEach-Object { ConvertFrom-TestSend $_ })
        @($Rows | ForEach-Object { $_.RunId } | Sort-Object -Unique).Count | Should -Be 1
        @($Rows | ForEach-Object { $_.RowCount } | Sort-Object -Unique) | Should -Be @($Rows.Count)
        $Pieces = New-Object Collections.Generic.List[string]
        foreach ($Row in @($Rows | Sort-Object { [int]$_.RowIndex })) { foreach ($Piece in (Get-TestRowPieces $Row 'InstalledApps')) { $Pieces.Add($Piece) } }
        (ConvertFrom-TestJsonArray (Expand-TestInventoryPieces $Pieces.ToArray())).Count | Should -Be @($Run.AppArray).Count
        $Run.Response | Should -Match "^200 : Upload payload size is [\d.]+Kb \($($Rows.Count) rows\) $"
        $Run.Message | Should -Match ' AppInventory: OK 200 : '
    }

    It 'sends the outbox first and reports PendingRows on row 1 when a waiting row still fails' {
        # An earlier run's row waits in the outbox and fails again (one attempt); this run's row
        # then fails too and is saved.
        $Earlier = '33333333-3333-4333-8333-333333333333'
        $Budget = [ref]1
        $Rows = New-AURunRows -MainColumns ([ordered]@{ ComputerName_s = 'TESTPC-0001'; ManagedDeviceID_g = 'x' }) -LogAPIMode 'LogIngestionAPI' -RunId $Earlier
        [void](Send-AURunRows -Rows $Rows -OutboxDir $script:OutboxDir -RetryBudget $Budget -LogAPIMode 'LogIngestionAPI' -Sender { $false })
        $Run = Invoke-TestMetered -SendResponse { param ($Mode, $Body) $script:LastSubmissionStatusCode = 503; 'DCR upload failed after retries : ' } -Summary
        @($Run.Sends).Count | Should -Be 2
        (ConvertFrom-TestSend $Run.Sends[0]).RunId_g | Should -BeExactly $Earlier
        (ConvertFrom-TestSend $Run.Sends[1]).RunId_g | Should -Match '^[0-9a-f]{8}-'
        (ConvertFrom-TestSend $Run.Sends[1]).RunId_g | Should -Not -BeExactly $Earlier
        $Run.MainApp.AppUsageCollectionStatus_s | Should -BeExactly 'PendingRows'
        @(Get-ChildItem -LiteralPath $script:OutboxDir -Filter '*.json').Count | Should -Be 2
        $Run.Response | Should -BeExactly 'Sent 0 of 1 row '
        $Run.Message | Should -Match ' AppInventory: Fail $'
    }

    It 'discards a waiting row the service rejects permanently, and still sends this run''s row' {
        $Earlier = '44444444-4444-4444-8444-444444444444'
        $Budget = [ref]1
        $Rows = New-AURunRows -MainColumns ([ordered]@{ ComputerName_s = 'TESTPC-0001'; ManagedDeviceID_g = 'x' }) -LogAPIMode 'LogIngestionAPI' -RunId $Earlier
        [void](Send-AURunRows -Rows $Rows -OutboxDir $script:OutboxDir -RetryBudget $Budget -LogAPIMode 'LogIngestionAPI' -Sender { $false })
        $script:Earlier = $Earlier
        $Run = Invoke-TestMetered -SendResponse {
            param ($Mode, $Body)
            if ([Text.Encoding]::UTF8.GetString($Body).Contains($script:Earlier)) { $script:LastSubmissionStatusCode = 400; return 'DCR upload failed after retries : ' }
            $script:LastSubmissionStatusCode = 204
            '204 : Upload payload size is 1Kb '
        }
        @($Run.Sends).Count | Should -Be 2
        @(Get-ChildItem -LiteralPath $script:OutboxDir -Filter '*.json') | Should -BeNullOrEmpty
        $Run.MainApp.AppUsageCollectionStatus_s | Should -BeExactly 'OK'
        $Run.Response | Should -Match '^204 : '
    }

    It 'stops the drain on a throttled (429) waiting row, keeps it, and still tries this run''s row' {
        $Earlier = '55555555-5555-4555-8555-555555555555'
        $Budget = [ref]1
        $Rows = New-AURunRows -MainColumns ([ordered]@{ ComputerName_s = 'TESTPC-0001'; ManagedDeviceID_g = 'x' }) -LogAPIMode 'LogIngestionAPI' -RunId $Earlier
        [void](Send-AURunRows -Rows $Rows -OutboxDir $script:OutboxDir -RetryBudget $Budget -LogAPIMode 'LogIngestionAPI' -Sender { $false })
        $Run = Invoke-TestMetered -SendResponse { param ($Mode, $Body) $script:LastSubmissionStatusCode = 429; 'DCR upload failed after retries : ' }
        @($Run.Sends).Count | Should -Be 2
        @(Get-ChildItem -LiteralPath $script:OutboxDir -Filter "$Earlier-*.json").Count | Should -Be 1
        $Run.MainApp.AppUsageCollectionStatus_s | Should -BeExactly 'PendingRows'
    }

    It 'counts a sender failure that throws, such as the token request, as a failed send' {
        $Run = Invoke-TestMetered -SendResponse { param ($Mode, $Body) throw 'token request failed' }
        @($Run.Errors) | Should -BeNullOrEmpty
        $Run.Response | Should -BeExactly 'Sent 0 of 1 row '
        @(Get-ChildItem -LiteralPath $script:OutboxDir -Filter '*.json').Count | Should -Be 1
    }

    It 'sends without the outbox, and says so, when another run holds the outbox lock' {
        Mock Invoke-AUWithLock -ParameterFilter { $Name -eq $script:AUOutboxLockName } { [pscustomobject]@{ Acquired = $false; Abandoned = $false; Result = $null; Error = $null } }
        $Run = Invoke-TestMetered
        @($Run.Sends).Count | Should -Be 1
        (ConvertFrom-TestSend $Run.Sends[0]).AppUsageCollectionStatus_s | Should -BeExactly 'OutboxSkipped'
        $Run.Response | Should -Match '^204 : '
    }

    It 'prints one summary line, with no App Usage clause, under 2,048 characters (D40, F41)' {
        $Run = Invoke-TestMetered -Summary
        @($Run.Output).Count | Should -Be 1
        @($Run.BlockOutput) | Should -BeNullOrEmpty
        $Line = [string]$Run.Output[0]
        $Line | Should -Match '^InventoryDate: \d\d-\d\d \d\d:\d\d  AppInventory: OK 204 : Upload payload size is [\d.]+Kb \(1 row\) $'
        $Line | Should -Not -Match 'Usage|Metering'
        $Line.Length | Should -BeLessOrEqual 2048
    }

    It 'reports AppInventory: Fail when any row of the run is not sent' {
        $Run = Invoke-TestMetered -SendResponse { param ($Mode, $Body) $script:LastSubmissionStatusCode = 500; 'DCR upload failed after retries : ' } -Summary
        @($Run.Output).Count | Should -Be 1
        [string]$Run.Output[0] | Should -Match '^InventoryDate: \S+ \S+  AppInventory: Fail $'
    }
}

Describe 'The version 19 source fixture' {
    It 'is in the repo, so the comparisons need no git history, and holds both parts of 094a084' {
        Test-Path -LiteralPath $script:AUV19SourcePath | Should -BeTrue -Because 'tests\AppUsage\fixtures\v19-appinventory-source.txt must be committed (CI clones one commit)'
        $Text = Get-TestV19ScriptText
        $Text | Should -Match '094a084'
        Get-TestAppInventoryBlock $Text | Should -Match 'Get-InstalledApplications -UserSid \$UserSid'
        Get-TestSummaryBlock $Text | Should -Match 'AppInventory: OK'
    }
}

Describe 'The App Inventory row sender (fix round 1)' {
    BeforeAll {
        # An exception like Invoke-WebRequest's for an HTTP error: Response.StatusCode is the status.
        function New-TestHttpError([int]$Code)
        {
            $Exception = New-Object System.Exception "The remote server returned an error: ($Code)."
            Add-Member -InputObject $Exception -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = $Code })
            return $Exception
        }

        # Saves one row for each RunId in the outbox, oldest first.
        function Save-TestOutboxRows([string[]]$RunIds)
        {
            $Age = $RunIds.Count
            foreach ($RunId in $RunIds)
            {
                $Budget = [ref]1
                $Rows = New-AURunRows -MainColumns ([ordered]@{ ComputerName_s = 'TESTPC-0001'; ManagedDeviceID_g = 'x' }) -LogAPIMode 'LogIngestionAPI' -RunId $RunId
                [void](Send-AURunRows -Rows $Rows -OutboxDir $script:OutboxDir -RetryBudget $Budget -LogAPIMode 'LogIngestionAPI' -Sender { $false })
                [IO.File]::SetLastWriteTimeUtc((Join-Path $script:OutboxDir "$RunId-1.json"), [datetime]::UtcNow.AddMinutes(-10 * $Age))
                $Age--
            }
        }

        function Get-TestSavedRunIds
        {
            return @(Get-ChildItem -LiteralPath $script:OutboxDir -Filter '*.json' | ForEach-Object { $_.Name.Substring(0, 36) } | Sort-Object)
        }

        $script:RunA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
        $script:RunB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
        $script:RunC = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
        $script:Retries = @{ SubmissionMaxRetries = 2; SubmissionInitialWaitSeconds = 60; SubmissionMaxWaitSeconds = 360 }
    }

    BeforeEach {
        Use-TestMeteredDevice
        # The real upload chain (Send-LogIngestionAPI and Invoke-LogSubmission) with the network and
        # the clock stubbed: Respond gives the DCR's status for a body; Start-Sleep only counts.
        . ([scriptblock]::Create((Get-TestScriptFunction 'Send-LogIngestionAPI')))
        . ([scriptblock]::Create((Get-TestScriptFunction 'Invoke-LogSubmission')))
        $script:Web = [pscustomobject]@{ Calls = (New-Object 'System.Collections.Generic.List[string]'); Sleeps = 0; Respond = { param ($Text) 204 }; Token = { 'token' } }
        function New-BearerToken { & $script:Web.Token }
        function Invoke-WebRequest
        {
            param ($Uri, $Method, $Headers, $Body, $ContentType, [switch]$UseBasicParsing)
            $Text = [Text.Encoding]::UTF8.GetString($Body)
            $script:Web.Calls.Add($Text)
            $Code = [int](& $script:Web.Respond $Text)
            if ($Code -ge 300) { throw (New-TestHttpError $Code) }
            [pscustomobject]@{ StatusCode = $Code }
        }
        function Start-Sleep { param ($Seconds) $script:Web.Sleeps++ }
    }

    It 'drains saved rows with one attempt each and no backoff, discards only the row the DCR rejects (400), and stops at the first transient failure' {
        Save-TestOutboxRows @($script:RunA, $script:RunB, $script:RunC)
        $script:Web.Respond = { param ($Text) if ($Text.Contains($script:RunA)) { 400 } elseif ($Text.Contains($script:RunB)) { 503 } else { 204 } }
        $Run = Invoke-TestMetered -Settings $script:Retries -RealUpload
        $script:Web.Sleeps | Should -Be 0
        $script:Web.Calls.Count | Should -Be 3
        $script:Web.Calls[0] | Should -Match $script:RunA
        $script:Web.Calls[1] | Should -Match $script:RunB
        $script:Web.Calls[2] | Should -Not -Match "$($script:RunA)|$($script:RunB)|$($script:RunC)"
        $script:Web.Calls[2] | Should -Match '"AppUsageEnabled_b":true'
        # B and C waited (PendingRows) until this run's row was sent in full, which supersedes them.
        @($Run.Log | Where-Object { $_ -like '*rejected permanently*' }).Count | Should -Be 1
        @($Run.Log | Where-Object { $_ -like "*run $($script:RunA)*rejected permanently*" }).Count | Should -Be 1
        @($Run.Log | Where-Object { $_ -like '*sent 0 row(s) from the outbox; 2 still wait.*' }).Count | Should -Be 1
        $Run.MainApp.AppUsageCollectionStatus_s | Should -BeExactly 'PendingRows'
        $Run.Response | Should -Match '^204 : Upload payload size is [\d.]+Kb \(1 row\) $'
    }

    It 'keeps every saved row when the DCR answers <Code>, after one attempt' -ForEach @(@{ Code = 401 }, @{ Code = 403 }, @{ Code = 404 }, @{ Code = 429 }) {
        Save-TestOutboxRows @($script:RunA, $script:RunB)
        $script:Code = $Code
        $script:Web.Respond = { param ($Text) if ($Text.Contains($script:RunA) -or $Text.Contains($script:RunB)) { $script:Code } else { 204 } }
        $Run = Invoke-TestMetered -Settings $script:Retries -RealUpload
        @($script:Web.Calls | Where-Object { $_.Contains($script:RunA) -or $_.Contains($script:RunB) }).Count | Should -Be 1
        $script:Web.Sleeps | Should -Be 0
        @($Run.Log | Where-Object { $_ -like '*rejected permanently*' }) | Should -BeNullOrEmpty
        @($Run.Log | Where-Object { $_ -like '*sent 0 row(s) from the outbox; 2 still wait.*' }).Count | Should -Be 1
        $Run.MainApp.AppUsageCollectionStatus_s | Should -BeExactly 'PendingRows'
        $Run.Response | Should -Match '^204 : '
    }

    It 'never discards a saved row when the token request fails with 401, and sends nothing' {
        Save-TestOutboxRows @($script:RunA)
        $script:Web.Token = { throw (New-TestHttpError 401) }
        $Run = Invoke-TestMetered -Settings $script:Retries -RealUpload
        $script:Web.Calls.Count | Should -Be 0
        @(Get-TestSavedRunIds) -contains $script:RunA | Should -BeTrue
        @(Get-TestSavedRunIds).Count | Should -Be 2
        $Run.Response | Should -BeExactly 'Sent 0 of 1 row '
    }

    It 'gives this run''s own rows the inventory''s normal retry' {
        $script:Web.Respond = { param ($Text) 503 }
        $Run = Invoke-TestMetered -Settings $script:Retries -RealUpload
        $script:Web.Calls.Count | Should -Be 3
        $script:Web.Sleeps | Should -Be 2
        @(Get-TestSavedRunIds).Count | Should -Be 1
        $Run.Response | Should -BeExactly 'Sent 0 of 1 row '
    }

    It 'reports an accepted row as sent when the log file is locked' {
        . ([scriptblock]::Create((Get-TestScriptFunction 'Write-CMTraceLog')))
        $SavedLog = $script:CMLog
        $script:CMLog = Join-Path $TestDrive "locked-$([guid]::NewGuid().ToString('N')).log"
        $Lock = [IO.File]::Open($script:CMLog, [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try
        {
            $Run = Invoke-TestMetered -Settings $script:Retries -RealUpload -RealLogger
        }
        finally
        {
            $Lock.Dispose()
            $script:CMLog = $SavedLog
        }
        $script:Web.Calls.Count | Should -Be 1
        $Run.Response | Should -Match '^204 : Upload payload size is [\d.]+Kb \(1 row\) $'
        @(Get-ChildItem -LiteralPath $script:OutboxDir -Filter '*.json' -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
    }
}

Describe 'Exit code (D28)' {
    BeforeAll {
        $script:PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        # The upload and the reads are stubbed; App Usage returns a failure, as a broken device would.
        $script:Stubs = @'
function Get-InstalledApplications { param ($UserSid) @([pscustomobject]@{ DisplayName = 'Contoso Alpha'; DisplayVersion = '2.0'; Publisher = 'Contoso'; PSPath = 'Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Contoso' }) }
function Get-WmiObject { [pscustomobject]@{ UserName = $null } }
function Send-LogIngestionAPI { param ($tenantId, $clientId, $clientSecret, $body, $dceURI, $dcrImmutableId, $logType)
    [IO.File]::AppendAllText($env:AU_TEST_SENDS, [Text.Encoding]::UTF8.GetString($body) + "`n")
    if ($env:AU_TEST_FAIL -eq '1') { $script:LastSubmissionStatusCode = 503; return 'DCR upload failed after retries : ' }
    $script:LastSubmissionStatusCode = 204
    "204 : Upload payload size is 1.0Kb " }
function Invoke-AppUsage { param ($RunId, $Serial, $ComputerName)
    $Result = New-AUFailedResult -RunId $RunId -LogAPIMode $LogAPIMode -ScriptVersion $ScriptVersion
    $Result.Status = 'SrumReadFailed:EsentMissing'
    $Result.StatusTokens = @('SrumReadFailed:EsentMissing')
    $Result.DeviceColumns = New-AUDeviceColumns -Result $Result -LogAPIMode $LogAPIMode -ScriptVersion $ScriptVersion
    $Result }
'@

        function Invoke-TestChild([bool]$Metering, [bool]$Fail)
        {
            $Id = [guid]::NewGuid().ToString('N')
            $Dir = Join-Path $TestDrive "child-$Id"
            New-Item -ItemType Directory -Path $Dir | Out-Null
            $Copy = Join-Path $Dir 'Intune_Windows_Inventory.ps1'
            $Settings = @{ CollectAppMetering = "`$$Metering"; CollectDeviceInventory = '$false'; CollectDriverInventory = '$false'; SubmissionMaxRetries = '0' }
            New-TestInventoryCopy -Path $Copy -Settings $Settings -Stubs $script:Stubs -LogDir $Dir
            $env:AU_TEST_SENDS = Join-Path $Dir 'sends.txt'
            $env:AU_TEST_FAIL = $(if ($Fail) { '1' } else { '0' })
            try
            {
                $Output = @(& $script:PowerShellExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Copy 2>&1 | ForEach-Object { "$_" })
                $Code = $LASTEXITCODE
            }
            finally
            {
                Remove-Item Env:\AU_TEST_SENDS, Env:\AU_TEST_FAIL -ErrorAction SilentlyContinue
            }
            $Sends = @()
            if (Test-Path -LiteralPath (Join-Path $Dir 'sends.txt')) { $Sends = @([IO.File]::ReadAllLines((Join-Path $Dir 'sends.txt')) | Where-Object { $_ }) }
            return [pscustomobject]@{ Code = $Code; Output = $Output; Sends = $Sends }
        }
    }

    It 'is version 19''s for the same inventory result when App Usage fails: upload <Upload>' -ForEach @(
        @{ Upload = 'accepted'; Fail = $false; Clause = 'AppInventory: OK' }
        @{ Upload = 'rejected'; Fail = $true; Clause = 'AppInventory: Fail' }
    ) {
        $Off = Invoke-TestChild -Metering $false -Fail $Fail
        $On = Invoke-TestChild -Metering $true -Fail $Fail
        $On.Code | Should -Be $Off.Code
        $Off.Code | Should -Be 0
        @($Off.Output).Count | Should -Be 1
        @($On.Output).Count | Should -Be 1
        $Off.Output[0] | Should -Match $Clause
        $On.Output[0] | Should -Match $Clause
        $Row = (ConvertFrom-TestJsonArray $On.Sends[-1])[0]
        $Row.AppUsageCollectionStatus_s | Should -BeExactly 'SrumReadFailed:EsentMissing'
        $Row.RunId_g | Should -Match '^[0-9a-f]{8}-'
        ((ConvertFrom-TestJsonArray $Off.Sends[-1])[0]).PSObject.Properties['AppUsageCollectionStatus_s'] | Should -BeNullOrEmpty
    }
}
