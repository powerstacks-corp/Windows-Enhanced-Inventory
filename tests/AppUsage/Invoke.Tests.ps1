BeforeAll {
    . "$PSScriptRoot\_Import.ps1"

    $script:MachineDomain = 'S-1-5-21-100-200-300'
    $script:UserA = 'S-1-12-1-1111-2222-3333-4444'
    $script:UserB = 'S-1-5-21-100-200-300-1002'
    $script:Gone = 'S-1-12-1-9999-9999-9999-9999'
    $script:SystemSid = 'S-1-5-18'

    function New-TestUtc([string]$Text)
    {
        return [datetime]::SpecifyKind([datetime]::ParseExact($Text, 'yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture), [DateTimeKind]::Utc)
    }
    $script:Earlier = New-TestUtc '2026-10-01T08:00:00'
    $script:Recent = New-TestUtc '2026-11-20T15:30:00'

    function New-TestExeInfo([string]$Name) { return "!!$Name!2026/01/01:00:00:00!1a2b!" }

    # Base64 of GZip-compressed UTF-8 JSON, the embedded-mappings format (F43).
    function ConvertTo-TestEmbedded([string]$Json)
    {
        $Buffer = New-Object IO.MemoryStream
        $Zip = New-Object IO.Compression.GZipStream($Buffer, [IO.Compression.CompressionMode]::Compress)
        $Bytes = (New-Object Text.UTF8Encoding $false).GetBytes($Json)
        $Zip.Write($Bytes, 0, $Bytes.Length)
        $Zip.Dispose()
        return [Convert]::ToBase64String($Buffer.ToArray())
    }

    $script:OurJson = '{"schemaVersion":1,"powerStacks":{"version":"2026.11.22.9","identityRules":[' +
    '{"id":"ps-alpha","type":"identity","when":{"exeName":"alpha.exe","publisher":"Contoso"},"target":{"displayName":"Contoso Alpha*","publisher":"Contoso"}},' +
    '{"id":"ps-gamma","type":"identity","when":{"exeName":"gamma.exe","publisher":"Contoso"},"target":{"displayName":"Contoso Gamma*","publisher":"Contoso"}}],' +
    '"classificationRules":[{"id":"ps-ignore-noise","type":"ignore","when":{"exeName":"noise*.exe"}},{"id":"ps-ignore-tool","type":"ignore","when":{"exeName":"tool.exe"}}]}}'
    $script:EmbeddedValid = ConvertTo-TestEmbedded $script:OurJson
    $script:CustomerToolRule = '{"id":"c-tool","type":"identity","when":{"exeName":"tool.exe","publisher":"Fabrikam"},"target":{"displayName":"Fabrikam Tool*","publisher":"Fabrikam"}}'
    $script:CustomerBetaRule = '{"id":"c-beta","type":"identity","when":{"exeName":"beta.exe","publisher":"Contoso"},"target":{"displayName":"Contoso Beta*","publisher":"Contoso"}}'

    function Set-TestCustomerFile([string[]]$Rules)
    {
        $Json = '{"schemaVersion":1,"customer":{"identityRules":[' + ($Rules -join ',') + '],"classificationRules":[]}}'
        [IO.File]::WriteAllText($script:CustomerPath, $Json, (New-Object Text.UTF8Encoding $false))
    }

    # Facts in the Task 14 shape: a verified GUI build by default.
    function New-TestFacts([string]$ExeName, [hashtable]$Values = @{})
    {
        $Facts = [ordered]@{
            ExeName         = $ExeName
            RunPath         = "C:\Program Files\Contoso\$ExeName"
            LocationClass   = 'ProgramFiles'
            FileDescription = $ExeName
            FileProductName = $ExeName
            FileCompanyName = 'Contoso'
            FileVersion     = '2.0.0.0'
            ProductVersion  = '2.0.0.0'
            FactsVerified   = $true
            Subsystem       = 'GUI'
            MsiProductCode  = $null
            PackageFamily   = $null
            IsServiceBinary = $false
            UserSid         = $null
            PathEvidence    = $null
        }
        foreach ($Key in $Values.Keys) { $Facts[$Key] = $Values[$Key] }
        return [pscustomobject]$Facts
    }

    # A ledger entry (Task 9 shape). Counted is keyed <epoch>|<AutoIncId>.
    function New-TestEntry([string]$Sid, [string]$ExeName, [hashtable]$Values = @{})
    {
        $Entry = New-AULedgerEntry $Sid (New-TestExeInfo $ExeName)
        foreach ($Key in $Values.Keys) { $Entry.$Key = $Values[$Key] }
        if ($null -ne $Entry.Facts) { $Entry.FactsVerified = ($Entry.Facts.FactsVerified -eq $true) }
        Update-AULedgerEntryTotal $Entry
        return $Entry
    }

    # Writes the ledger. Unless it's given, UserA's alpha.exe with verified facts is added, so the
    # default SRUM row (alpha.exe) merges into an entry ps-alpha matches.
    function Save-TestLedger([object[]]$Entries, $WatchingSince = $script:Earlier)
    {
        $Entries = @($Entries)
        if (-not ($Entries | Where-Object { $_.UserSid -eq $script:UserA -and $_.ExeName -eq 'alpha.exe' }))
        {
            $Entries += New-TestEntry $script:UserA 'alpha.exe' @{ Facts = (New-TestFacts 'alpha.exe') }
        }
        $Ledger = New-AULedger
        $Ledger.WatchingSince = $WatchingSince
        foreach ($Entry in $Entries) { $Ledger.Entries["$($Entry.UserSid)|$($Entry.ExeInfo)"] = $Entry }
        Write-AULedger -Ledger $Ledger -Path $script:LedgerPath
    }

    function Get-TestLedgerEntry([string]$Sid, [string]$ExeName)
    {
        return (Read-AULedger -Path $script:LedgerPath).Entries["$Sid|$(New-TestExeInfo $ExeName)"]
    }

    # An installed-app entry in the Task 13 shape, machine scope by default.
    function New-TestApp([string]$Name, [string]$Publisher = 'Contoso', [hashtable]$Values = @{})
    {
        $App = [ordered]@{
            DisplayName     = $Name
            DisplayVersion  = '2.0'
            Publisher       = $Publisher
            ProductCode     = $null
            PackageFamily   = $null
            InstallLocation = $null
            DisplayIcon     = $null
            UninstallString = "MsiExec.exe /X$Name"
            Architecture    = 64
            Scope           = 'Machine'
            ProfilePath     = $null
            InstallDate     = '20260901'
            AppType         = 'Win32'
            RegPath         = "HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Uninstall\$Name"
        }
        foreach ($Key in $Values.Keys) { $App[$Key] = $Values[$Key] }
        return [pscustomobject]$App
    }

    function New-TestUsers
    {
        @(
            [pscustomobject]@{ Sid = $script:SystemSid; UserType = 'System'; ProfilePath = 'C:\Windows\system32\config\systemprofile'; ProfileState = 'Loaded' }
            [pscustomobject]@{ Sid = $script:UserA; UserType = 'CloudOnly'; ProfilePath = 'C:\Users\a'; ProfileState = 'Loaded' }
            [pscustomobject]@{ Sid = $script:UserB; UserType = 'Local'; ProfilePath = 'C:\Users\b'; ProfileState = 'Copied' }
        )
    }

    function New-TestScopeRead([hashtable]$Values = @{})
    {
        $ScopeRead = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
        $ScopeRead['Machine'] = 'Read'
        $ScopeRead[$script:SystemSid] = 'Read'
        $ScopeRead[$script:UserA] = 'Read'
        $ScopeRead[$script:UserB] = 'Read'
        foreach ($Key in $Values.Keys) { $ScopeRead[$Key] = $Values[$Key] }
        return $ScopeRead
    }

    function New-TestDiscovery([hashtable]$Values = @{})
    {
        $Discovery = [ordered]@{
            Apps               = @(
                (New-TestApp 'Contoso Alpha')
                (New-TestApp 'Contoso Beta' 'Contoso' @{ DisplayVersion = '1.0' })
                (New-TestApp 'Contoso Beta' 'Contoso' @{ DisplayVersion = '1.5'; Scope = $script:UserB; RegPath = "HKEY_USERS\$($script:UserB)\Software\Microsoft\Windows\CurrentVersion\Uninstall\Beta" })
                (New-TestApp 'Fabrikam Tool' 'Fabrikam')
            )
            ScopeRead          = (New-TestScopeRead)
            MsiFileMap         = @{}
            ProfilesFound      = 3
            ProfilesRead       = 3
            MsiFileMapRead     = $true
            HiveUnloadFailures = 0
        }
        foreach ($Key in $Values.Keys) { $Discovery[$Key] = $Values[$Key] }
        return [pscustomobject]$Discovery
    }

    function New-TestRow([string]$Sid, [string]$ExeName, [long]$Id, [double]$Focus = 30, $Time = $script:Recent, [string]$ExeInfo)
    {
        if (-not $ExeInfo) { $ExeInfo = New-TestExeInfo $ExeName }
        return [pscustomobject]@{ UserSid = $Sid; ExeInfo = $ExeInfo; AutoIncId = $Id; EndTimeUtc = $Time; FocusSeconds = $Focus; InputSeconds = 0 }
    }

    function New-TestSrum([object[]]$Rows, [hashtable]$Values = @{})
    {
        $Read = [ordered]@{ Epoch = 'E1'; Timeline = @($Rows); Resource = @(); Status = 'OK'; Repaired = $false; Complete = $true }
        foreach ($Key in $Values.Keys) { $Read[$Key] = $Values[$Key] }
        return [pscustomobject]$Read
    }

    function Get-TestExe([object]$Result, [string]$ExeName)
    {
        return , @($Result.ExeEntries | Where-Object { $_.ExeName -eq $ExeName })
    }

    function Get-TestTokens([object]$Result) { return @($Result.Status -split '; ') }

    # The default device: a supported build, Full Language, the lock free, a snapshot, three
    # profiles, four apps, and a SRUM read with alpha.exe rows. Each test changes what it needs.
    function Use-TestDevice
    {
        $script:LedgerPath = Join-Path $TestDrive "AppUsage_$([guid]::NewGuid().ToString('N')).json"
        $script:CustomerPath = Join-Path $TestDrive "customer-$([guid]::NewGuid().ToString('N')).json"
        Set-TestCustomerFile @($script:CustomerToolRule)
        $script:AppUsageMappingsEmbedded = $script:EmbeddedValid
        $script:AppUsageCustomerMappingsPath = $script:CustomerPath
        $script:CollectUWPInventory = $false
        $script:MinFocusSecondsForUse = 1
        $script:ScriptVersion = '20 - test'
        $script:LogAPIMode = 'LogIngestionAPI'
        $script:Discovery = New-TestDiscovery
        $script:Srum = New-TestSrum @((New-TestRow $script:UserA 'alpha.exe' 100))
        $script:Users = New-TestUsers
        Save-TestLedger @()

        Mock Get-AULanguageMode { 'FullLanguage' }
        Mock Get-AUOsBuild { 26200 }
        Mock Get-AUSerial { 'TESTSERIAL' }
        Mock Get-AULedgerPath { $script:LedgerPath }
        Mock Invoke-AUWithLock {
            $Outcome = [pscustomobject]@{ Acquired = $true; Abandoned = $false; Result = $null; Error = $null }
            try { $Outcome.Result = & $Body } catch { $Outcome.Error = $_.Exception.Message }
            $Outcome
        }
        Mock New-AUWorkDir { Join-Path $TestDrive "run-$RunId" }
        Mock New-AUSnapshot { [pscustomobject]@{ WorkDir = $WorkDir; ShadowId = $null; ShadowRoot = $null; SrumDbPath = (Join-Path $WorkDir 'sru\SRUDB.dat'); HiveCopies = @{}; MachineDomainSid = $script:MachineDomain; Status = 'OK' } }
        Mock Remove-AUSnapshot { }
        Mock Get-AUUsers { $script:Users }
        Mock Get-AUInstalledApps { $script:Discovery }
        Mock Read-AUSrum { $script:Srum }
        Mock Get-AUServiceBinaries { @{} }
        Mock New-AUReadBudget { [pscustomobject]@{ Id = 'run-budget'; TimeoutMs = 5000; RemainingMs = 120000; Runspace = $null; ScriptText = $null; Reads = 0; TimedOut = 0; Skipped = 0; UntrustedOwner = 0 } }
        Mock Close-AUReadBudget { }
        Mock Find-AUExePath { $null }
    }

    $script:Run = [guid]::NewGuid().ToString()
}

Describe 'Format-AUStatus and the status token list (F42)' {
    It 'joins two problems with "; "' {
        Format-AUStatus @('SrumReadFailed:EsentMissing', 'ProfileUnread:1') | Should -BeExactly 'SrumReadFailed:EsentMissing; ProfileUnread:1'
    }

    It 'gives OK for none' {
        Format-AUStatus @() | Should -BeExactly 'OK'
        Format-AUStatus $null | Should -BeExactly 'OK'
        Format-AUStatus @('OK', '') | Should -BeExactly 'OK'
    }

    It 'keeps first-seen order and gives a repeated token once' {
        Format-AUStatus @('LedgerReset', 'PendingRows', 'LedgerReset') | Should -BeExactly 'LedgerReset; PendingRows'
    }

    It 'throws for a token not on the list: <Token>' -ForEach @(
        @{ Token = 'Bogus' }
        @{ Token = 'ProfileUnread:0' }
        @{ Token = 'ProfileUnread:x' }
        @{ Token = 'srumreadfailed:EsentMissing' }
        @{ Token = 'SrumReadFailed:Whatever' }
        @{ Token = 'LanguageMode:Constrained Language' }
    ) {
        { Format-AUStatus @('OK', $Token) } | Should -Throw "*$Token*"
    }

    It 'formats the language-mode skip as the brief gives it' {
        Format-AUStatus @('LanguageMode:ConstrainedLanguage', 'skipped') | Should -BeExactly 'LanguageMode:ConstrainedLanguage; skipped'
    }

    It 'lists every SrumReadFailed reason the region can produce' {
        $Reasons = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($Match in [regex]::Matches($AURegionText, "\`$Reason = '(\w+)'|\`$Stage = '(\w+)'|SrumReadFailed:(\w+)'"))
        {
            foreach ($Group in @($Match.Groups[1], $Match.Groups[2], $Match.Groups[3])) { if ($Group.Success) { [void]$Reasons.Add($Group.Value) } }
        }
        $Reasons.Count | Should -BeGreaterThan 10
        foreach ($Reason in $Reasons) { Test-AUStatusToken "SrumReadFailed:$Reason" | Should -BeTrue -Because "SrumReadFailed:$Reason is a status" }
        Test-AUStatusToken $script:AUWorkDirUntrustedStatus | Should -BeTrue
    }

    It 'lists each token once, in ASCII, with no "; " inside a token' {
        $script:AUStatusTokens.Count | Should -Be @($script:AUStatusTokens | Sort-Object -Unique -CaseSensitive).Count
        foreach ($Token in $script:AUStatusTokens)
        {
            $Token | Should -Match '^[\x21-\x7E]+$'
            $Token.Contains(';') | Should -BeFalse
        }
        foreach ($Name in @('OK', 'UnsupportedOS', 'AppUsageBusy', 'ShadowCopyFailed', 'LedgerReset', 'LedgerWriteFailed', 'DiscoveryFailed', 'InvalidCustomerMappings',
                'AppUsageFailed:Serial', 'AppUsageFailed:OsBuild', 'PendingRows', 'OutboxSkipped', 'AppUsageFailed', 'MsiFileMapFailed', 'skipped', 'LowDiskSpace'))
        {
            $script:AUStatusTokens | Should -Contain $Name
        }
    }
}

Describe 'App Usage log lines carry no other user''s identity (D18)' {
    BeforeAll {
        # The inventory log is readable by standard users, so App Usage logs counts and exe names only:
        # no SIDs, no profile paths, and no paths under a profile. These variables and properties hold
        # one, and may reach a log line only through Get-AUSafeLogText (SIDs and profile folders
        # replaced) or Get-AUFileLeaf (the file name).
        $script:Forbidden = @('RunPath', 'ProfilePath', 'UserSid', 'Sid', 'KernelPath', 'Kernel', 'MountName', 'Mount', 'ShownBase')
        # Error and Result: a lock outcome's or run's raw error text and stray output.
        $script:ForbiddenMembers = @('RunPath', 'ProfilePath', 'UserSid', 'Sid', 'KernelPath', 'Error', 'Result')
        # In these functions, these variables hold a user's file, a profile folder, or a hive copy.
        $script:UserFileVariables = @('Path', 'Source', 'Pair', 'Candidate')
        $script:UserFileFunctions = @('Read-AUFile', 'Read-AUFileFacts', 'Get-AUFileOwner', 'Get-AUKernelProbe', 'Select-AUVerifiedPath', 'Resolve-AUKernelPath', 'Find-AUExePath',
            'Get-AUExeFacts', 'Copy-AUShadowFile', 'Get-AUCopyBytes', 'New-AUSnapshot', 'Mount-AUHive', 'Dismount-AUHive', 'Read-AUUserApps', 'Read-AUArpEntries')
        $script:SafeCommands = @('Get-AUSafeLogText', 'Get-AUFileLeaf')

        function Test-UnderSafeCommand($Node, $Top)
        {
            $Parent = $Node.Parent
            while ($null -ne $Parent -and -not [object]::ReferenceEquals($Parent, $Top.Parent))
            {
                if ($Parent -is [Management.Automation.Language.CommandAst] -and $script:SafeCommands -contains $Parent.GetCommandName()) { return $true }
                $Parent = $Parent.Parent
            }
            return $false
        }

        # The App Usage log calls: every one in the region, and those in the inline App Inventory
        # section's App Usage code (the bodies of its if statements on $CollectAppMetering or $AUResult;
        # never an else branch, which is version 19's read).
        function Get-TestLogCalls
        {
            $IsLog = { param ($Node) $Node -is [Management.Automation.Language.CommandAst] -and $Node.GetCommandName() -eq 'Write-CMTraceLog' }
            $Calls = New-Object 'System.Collections.Generic.List[object]'
            $Region = [Management.Automation.Language.Parser]::ParseInput($AURegionText, [ref]$null, [ref]$null)
            foreach ($Call in $Region.FindAll($IsLog, $true)) { $Calls.Add($Call) }
            $Inline = [regex]::Match($AUScriptText, '(?ms)^# region APPINVENTORY\r?\n(.*?)^# end region APPINVENTORY')
            if (-not $Inline.Success) { throw 'The App Inventory section was not found.' }
            $InlineAst = [Management.Automation.Language.Parser]::ParseInput($Inline.Groups[1].Value, [ref]$null, [ref]$null)
            $Seen = New-Object 'System.Collections.Generic.HashSet[int]'
            foreach ($If in $InlineAst.FindAll({ param ($Node) $Node -is [Management.Automation.Language.IfStatementAst] }, $true))
            {
                foreach ($Clause in $If.Clauses)
                {
                    if ($Clause.Item1.Extent.Text -notmatch '\$CollectAppMetering|\$AUResult') { continue }
                    foreach ($Call in $Clause.Item2.FindAll($IsLog, $true)) { if ($Seen.Add($Call.Extent.StartOffset)) { $Calls.Add($Call) } }
                }
            }
            return , $Calls.ToArray()
        }

        function Get-TestLogLeaks
        {
            $Leaks = New-Object 'System.Collections.Generic.List[string]'
            foreach ($Call in (Get-TestLogCalls))
            {
                $Function = $Call.Parent
                while ($null -ne $Function -and $Function -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $Function = $Function.Parent }
                $FunctionName = if ($null -ne $Function) { $Function.Name } else { '' }
                $Elements = @($Call.CommandElements)
                $Message = $null
                for ($i = 1; $i -lt $Elements.Count; $i++)
                {
                    if ($Elements[$i] -is [Management.Automation.Language.CommandParameterAst] -and $Elements[$i].ParameterName -eq 'Message') { $Message = $Elements[$i + 1]; break }
                }
                if ($null -eq $Message -and $Elements.Count -gt 1 -and $Elements[1] -isnot [Management.Automation.Language.CommandParameterAst]) { $Message = $Elements[1] }
                if ($null -eq $Message) { continue }
                $Line = "$FunctionName line $($Call.Extent.StartLineNumber): $($Call.Extent.Text)"
                foreach ($Variable in $Message.FindAll({ param ($Node) $Node -is [Management.Automation.Language.VariableExpressionAst] }, $true))
                {
                    if (Test-UnderSafeCommand $Variable $Message) { continue }
                    $Name = $Variable.VariablePath.UserPath
                    if ($script:Forbidden -contains $Name -or ($script:UserFileVariables -contains $Name -and $script:UserFileFunctions -contains $FunctionName)) { $Leaks.Add("`$$Name in $Line") }
                }
                foreach ($Member in $Message.FindAll({ param ($Node) $Node -is [Management.Automation.Language.MemberExpressionAst] }, $true))
                {
                    if (Test-UnderSafeCommand $Member $Message) { continue }
                    $MemberName = [string]$Member.Member.Value
                    if ($script:ForbiddenMembers -contains $MemberName) { $Leaks.Add(".$MemberName in $Line") }
                    # An exception's message can name a file under a profile, or a SID.
                    if ($MemberName -eq 'Message' -and $Member.Expression -is [Management.Automation.Language.MemberExpressionAst] -and [string]$Member.Expression.Member.Value -eq 'Exception') { $Leaks.Add(".Exception.Message in $Line") }
                }
            }
            return , $Leaks.ToArray()
        }
    }

    It 'never logs a SID, a profile path, a path under a profile, or an unfiltered exception message' {
        $Leaks = Get-TestLogLeaks
        $Leaks | Should -BeNullOrEmpty
    }

    It 'scans the inline App Inventory section''s App Usage log lines, the row sender''s included' {
        $Texts = @((Get-TestLogCalls) | ForEach-Object { $_.Extent.Text })
        @($Texts | Where-Object { $_ -like '*App Usage failed, so the inventory uses its own read*' }).Count | Should -Be 1
        @($Texts | Where-Object { $_ -clike 'Write-CMTraceLog "App inventory row upload failed*' }).Count | Should -Be 1
        @($Texts | Where-Object { $_ -like '*could not be sent with App Usage*' }).Count | Should -Be 1
        # Version 19's own lines aren't App Usage's.
        @($Texts | Where-Object { $_ -like '*Starting App Inventory Collection*' }).Count | Should -Be 0
    }

    Context 'on a run' {
        BeforeAll {
            # The real exe-path search and read budget, so the file reads and their failures are logged.
            $script:RealFind = ${function:Find-AUExePath}
            $script:RealBudget = ${function:New-AUReadBudget}
            $script:RealClose = ${function:Close-AUReadBudget}
        }
        BeforeEach { Use-TestDevice }

        It 'logs no SID or profile path on a run that reads another user''s files and fails' {
            $script:Logged = New-Object 'System.Collections.Generic.List[string]'
            function Write-CMTraceLog { param ([string]$Message, [string]$Component, [int]$Type) $script:Logged.Add($Message) }
            Mock Find-AUExePath { & $script:RealFind -KernelPaths $KernelPaths -ExeInfo $ExeInfo -VolumeCache $VolumeCache -ReadBudget $ReadBudget }
            Mock New-AUReadBudget { & $script:RealBudget }
            Mock Close-AUReadBudget { & $script:RealClose -ReadBudget $ReadBudget }
            $script:FakeDrive = Join-Path $TestDrive "drive-$([guid]::NewGuid().ToString('N'))"
            $File = Join-Path $script:FakeDrive 'Users\a\AppData\Local\Contoso\omega.exe'
            [void](New-Item -ItemType Directory -Force -Path (Split-Path $File))
            [IO.File]::WriteAllText($File, 'not read')
            Mock Get-AUFixedDrives { $script:FakeDrive }
            # Every read fails with a message that names the user's folder and SID.
            Mock Get-AUFileReadScript { "throw 'Access to the path C:\Users\a\AppData\Local\Contoso\omega.exe is denied for $($script:UserA).'" }
            Mock Get-AUUsers { Write-Warning "user $($script:UserB) at C:\Users\b"; $script:Users }
            $script:Srum = New-TestSrum @((New-TestRow $script:UserA 'alpha.exe' 100), (New-TestRow $script:UserA 'omega.exe' 101)) @{ Resource = @([pscustomobject]@{ UserSid = $script:UserA; ExeName = 'omega.exe'; KernelPath = '\Device\HarddiskVolume3\Users\a\AppData\Local\Contoso\omega.exe'; TimeStampUtc = $script:Recent }) }

            $Result = Invoke-AppUsage -RunId $script:Run
            Get-TestTokens $Result | Should -Not -Contain 'AppUsageFailed'
            # The reads and the stray output were logged ...
            @($script:Logged | Where-Object { $_ -like "*couldn't read omega.exe*" }).Count | Should -BeGreaterThan 0
            @($script:Logged | Where-Object { $_ -like '*unexpected output*' }).Count | Should -Be 1
            # ... with no SID, no profile folder, and no path under a profile.
            foreach ($Line in $script:Logged)
            {
                $Line | Should -Not -Match ([regex]::Escape($script:UserA))
                $Line | Should -Not -Match ([regex]::Escape($script:UserB))
                $Line | Should -Not -Match '(?i)C:\\Users\\(a|b)\b'
                $Line | Should -Not -Match '(?i)\\Users\\a\\AppData'
            }
        }
    }

    Context 'under the run lock' {
        BeforeAll { $script:RealLock = ${function:Invoke-AUWithLock} }
        BeforeEach { Use-TestDevice }

        It 'logs no SID or profile path from work under the lock that <Case>' -ForEach @(
            @{ Case = 'throws' }
            @{ Case = 'writes stray output' }
        ) {
            $script:Logged = New-Object 'System.Collections.Generic.List[string]'
            function Write-CMTraceLog { param ([string]$Message, [string]$Component, [int]$Type) $script:Logged.Add($Message) }
            # The real lock, so its outcome's Error and Result reach Invoke-AURun.
            Mock Invoke-AUWithLock { & $script:RealLock -Body $Body -TimeoutSeconds $TimeoutSeconds -Name "Global\PowerStacksAppUsageTest-$([guid]::NewGuid().ToString('N'))" }
            $script:LeakSid = 'S-1-5-21-555-666-777-1009'
            $script:LeakText = "Access to the path 'C:\Users\au-leak-user\NTUSER.DAT' is denied for $($script:LeakSid)."
            if ($Case -eq 'throws') { Mock Get-AUUsers { throw $script:LeakText } }
            else { Mock Remove-AUSnapshot { $script:LeakText } }
            $Result = Invoke-AppUsage -RunId $script:Run
            if ($Case -eq 'throws')
            {
                Get-TestTokens $Result | Should -Contain 'AppUsageFailed'
                @($script:Logged | Where-Object { $_ -like 'App Usage: the run failed*' }).Count | Should -Be 1
            }
            else { @($script:Logged | Where-Object { $_ -like '*unexpected output*' }).Count | Should -BeGreaterThan 0 }
            foreach ($Line in $script:Logged)
            {
                $Line | Should -Not -Match ([regex]::Escape($script:LeakSid))
                $Line | Should -Not -Match 'au-leak-user'
            }
        }
    }

    It 'replaces user SIDs and the folder under \Users with placeholders, and keeps the rest' {
        $Text = "Access to 'C:\Users\Jane Doe\AppData\Local\x.exe' is denied for S-1-5-21-111-222-333-1001 at HKU\AU_S-1-12-1-1-2-3-4; C:\Users\bob: gone"
        $Safe = Get-AUSafeLogText $Text
        $Safe | Should -Not -Match 'Jane|bob|S-1-5-21-111|S-1-12-1-1-2'
        $Safe | Should -Match '\\Users\\<user>\\AppData\\Local\\x\.exe'
        $Safe | Should -Match '<SID>'
        $Safe | Should -Match ': gone$'
        Get-AUSafeLogText 'S-1-5-18 and S-1-5-32-544 stay' | Should -BeExactly 'S-1-5-18 and S-1-5-32-544 stay'
        Get-AUSafeLogText '' | Should -BeExactly ''
        Get-AUFileLeaf '\Device\HarddiskVolume3\Users\bob\AppData\Local\Contoso\tool.exe' | Should -BeExactly 'tool.exe'
        Get-AUFileLeaf 'C:\Users\bob\tool.exe' | Should -BeExactly 'tool.exe'
        Get-AUFileLeaf 'tool.exe' | Should -BeExactly 'tool.exe'
        Get-AUFileLeaf $null | Should -BeExactly ''
    }
}

Describe 'Get-AULedgerPath (F44)' {
    It 'replaces invalid file-name characters in the serial' {
        Get-AULedgerPath 'AB/12:34' 'PC1' | Should -Be 'C:\Windows\AppUsage_AB_12_34.json'
    }

    It 'falls back to the computer name for a blank serial' {
        Get-AULedgerPath '' 'PC1' | Should -Be 'C:\Windows\AppUsage_PC1.json'
        Get-AULedgerPath '   ' 'PC1' | Should -Be 'C:\Windows\AppUsage_PC1.json'
    }

    It 'uses the same sanitized serial as the outbox' {
        $Ledger = Get-AULedgerPath 'AB/12:34' 'PC1'
        Get-AUOutboxPath 'AB/12:34' 'PC1' | Should -BeExactly ($Ledger.Substring(0, $Ledger.Length - 5) + '_outbox')
    }
}

Describe 'The embedded mappings markers (F43)' {
    It 'appear exactly once each, with the embedded variable between them' {
        ([regex]::Matches($AURegionText, '(?m)^# BEGIN APPUSAGE MAPPINGS\r?$')).Count | Should -Be 1
        ([regex]::Matches($AURegionText, '(?m)^# END APPUSAGE MAPPINGS\r?$')).Count | Should -Be 1
        $Block = [regex]::Match($AURegionText, '(?ms)^# BEGIN APPUSAGE MAPPINGS\r?\n(.*?)^# END APPUSAGE MAPPINGS')
        $Block.Success | Should -BeTrue
        $Block.Groups[1].Value.Trim() | Should -BeExactly "`$script:AppUsageMappingsEmbedded = ''"
    }
}

Describe 'Get-AUSerial' {
    It 'returns the trimmed serial, blank when the BIOS has none, and $null when it cannot be read' {
        Mock Get-CimInstance { [pscustomobject]@{ SerialNumber = ' SN-123 ' } }
        Get-AUSerial | Should -BeExactly 'SN-123'
        Mock Get-CimInstance { [pscustomobject]@{ SerialNumber = '   ' } }
        Get-AUSerial | Should -BeExactly ''
        Mock Get-CimInstance { throw 'WMI is broken' }
        Get-AUSerial | Should -BeNullOrEmpty
        $null -eq (Get-AUSerial) | Should -BeTrue
        Mock Get-CimInstance { }
        $null -eq (Get-AUSerial) | Should -BeTrue
    }
}

Describe 'Get-AUOsBuild and Get-AULanguageMode (F40)' {
    It 'reads the build number and the language mode' {
        Get-AUOsBuild | Should -BeGreaterThan 0
        Get-AUOsBuild | Should -BeOfType [int]
        Get-AULanguageMode | Should -BeExactly 'FullLanguage'
    }
}

Describe 'Invoke-AppUsage skips' {
    BeforeEach { Use-TestDevice }

    It 'reports UnsupportedOS below build 26200 and takes no snapshot (D42)' {
        Mock Get-AUOsBuild { 26100 }
        $Result = Invoke-AppUsage -RunId $script:Run
        $Result.Status | Should -BeExactly 'UnsupportedOS'
        Should -Invoke New-AUWorkDir -Times 0 -Exactly
        Should -Invoke New-AUSnapshot -Times 0 -Exactly
        Should -Invoke Invoke-AUWithLock -Times 0 -Exactly
        $Result.InventoryApps | Should -BeNullOrEmpty
        $Result.AppFields | Should -BeNullOrEmpty
        $Result.DeviceColumns['AppUsageCollectionStatus_s'] | Should -BeExactly 'UnsupportedOS'
        $Result.DeviceColumns['AppUsageEnabled_b'] | Should -BeTrue
    }

    It 'reports AppUsageFailed:OsBuild, not UnsupportedOS, when the build number cannot be read' {
        Mock Get-AUOsBuild { 0 }
        $Result = Invoke-AppUsage -RunId $script:Run
        $Result.Status | Should -BeExactly 'AppUsageFailed:OsBuild'
        Should -Invoke New-AUSnapshot -Times 0 -Exactly
        Should -Invoke Invoke-AUWithLock -Times 0 -Exactly
        $Result.DeviceColumns['AppUsageCollectionStatus_s'] | Should -BeExactly 'AppUsageFailed:OsBuild'
    }

    It 'reports AppUsageFailed:Serial and skips when the serial number cannot be read' {
        Mock Get-AUSerial { $null }
        $Before = [IO.File]::ReadAllBytes($script:LedgerPath)
        $Result = Invoke-AppUsage -RunId $script:Run
        $Result.Status | Should -BeExactly 'AppUsageFailed:Serial'
        Should -Invoke Get-AULedgerPath -Times 0 -Exactly
        Should -Invoke Invoke-AUWithLock -Times 0 -Exactly
        $Result.LedgerPath | Should -BeNullOrEmpty
        $Result.OutboxPath | Should -BeNullOrEmpty
        [IO.File]::ReadAllBytes($script:LedgerPath) | Should -Be $Before
    }

    It 'names the ledger after the computer name when the serial is blank (F44)' {
        Mock Get-AUSerial { '' }
        $Result = Invoke-AppUsage -RunId $script:Run -ComputerName 'PC-BLANK'
        $Result.Status | Should -BeExactly 'OK'
        Should -Invoke Get-AULedgerPath -Times 1 -Exactly -ParameterFilter { $Serial -eq '' -and $ComputerName -eq 'PC-BLANK' }
        $Result.OutboxPath | Should -Match 'AppUsage_PC-BLANK_outbox$'
    }

    It 'reports the language mode and skips before the OS check (D37)' {
        Mock Get-AULanguageMode { 'ConstrainedLanguage' }
        $Result = Invoke-AppUsage -RunId $script:Run
        $Result.Status | Should -BeExactly 'LanguageMode:ConstrainedLanguage; skipped'
        $Result.StatusTokens | Should -Be @('LanguageMode:ConstrainedLanguage', 'skipped')
        Should -Invoke Get-AUOsBuild -Times 0 -Exactly
        Should -Invoke Invoke-AUWithLock -Times 0 -Exactly
        $Result.InventoryApps | Should -BeNullOrEmpty
        $Result.DeviceColumns['AppUsageCollectionStatus_s'] | Should -BeExactly 'LanguageMode:ConstrainedLanguage; skipped'
    }

    It 'skips in a real Constrained Language session, with one result and its device columns' {
        # Invoke-AppUsage must build its result from plain types only in this mode.
        $Region = Join-Path $TestDrive 'clm-region.ps1'
        [IO.File]::WriteAllText($Region, $AURegionText)
        $Child = Join-Path $TestDrive 'clm-child.ps1'
        [IO.File]::WriteAllText($Child, @"
`$ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage'
function Write-CMTraceLog { param (`$Message, `$Component, `$Type) }
`$ScriptVersion = 'clm'
`$LogAPIMode = 'LogIngestionAPI'
`$LoadRecords = @(. '$Region' *>&1)
"loadrecords=`$(`$LoadRecords.Count)"
`$All = @(Invoke-AppUsage -RunId '$($script:Run)' *>&1)
"outputs=`$(`$All.Count)"
"status=`$(`$All[0].Status)"
"column=`$(`$All[0].DeviceColumns['AppUsageCollectionStatus_s'])"
"runid=`$(`$All[0].RunId)"
"@)
        $Lines = @(& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Child 2>&1 | ForEach-Object { "$_" })
        # The region itself loads cleanly in this mode: no error record or other output.
        $Lines | Should -Contain 'loadrecords=0'
        $Lines | Should -Contain 'outputs=1'
        $Lines | Should -Contain 'status=LanguageMode:ConstrainedLanguage; skipped'
        $Lines | Should -Contain 'column=LanguageMode:ConstrainedLanguage; skipped'
        $Lines | Should -Contain "runid=$($script:Run)"
    }

    It 'reports AppUsageBusy when the lock is not acquired, and does nothing under it' {
        Mock Invoke-AUWithLock { [pscustomobject]@{ Acquired = $false; Abandoned = $false; Result = $null; Error = $null } }
        $Result = Invoke-AppUsage -RunId $script:Run
        Get-TestTokens $Result | Should -Contain 'AppUsageBusy'
        Should -Invoke New-AUSnapshot -Times 0 -Exactly
        $Result.InventoryApps | Should -BeNullOrEmpty
        $Result.AppFields | Should -BeNullOrEmpty
        $Result.ExeEntries | Should -BeNullOrEmpty
        $Before = [IO.File]::ReadAllBytes($script:LedgerPath)
        $null = Invoke-AppUsage -RunId $script:Run
        [IO.File]::ReadAllBytes($script:LedgerPath) | Should -Be $Before
    }

    It 'skips the run when our embedded rules are missing (Source None)' {
        $script:AppUsageMappingsEmbedded = ''
        $Result = Invoke-AppUsage -RunId $script:Run
        Get-TestTokens $Result | Should -Contain 'MappingsUnavailable:Missing'
        Should -Invoke Invoke-AUWithLock -Times 0 -Exactly
        $Result.InventoryApps | Should -BeNullOrEmpty
        $Result.DeviceColumns['MappingsVersion_s'] | Should -BeExactly ''
    }

    It 'skips the run when our embedded rules are invalid, leaving the ledger untouched' {
        $Entry = New-TestEntry $script:UserA 'alpha.exe' @{ StoredTarget = [pscustomobject]@{ Section = 'PowerStacks'; MatchRuleId = 'ps-alpha'; RuleType = 'identity'; TargetPattern = 'Contoso Alpha*'; TargetPublisher = 'Contoso'; ResolvedAppName = 'Contoso Alpha'; ProductCode = $null; PackageFamily = $null; EvidenceUsed = 'Verified' } }
        Save-TestLedger @($Entry)
        $Before = [IO.File]::ReadAllBytes($script:LedgerPath)
        $script:AppUsageMappingsEmbedded = ConvertTo-TestEmbedded '{"schemaVersion":1,"powerStacks":{"identityRules":[]}}'
        $Result = Invoke-AppUsage -RunId $script:Run
        Get-TestTokens $Result | Should -Contain 'MappingsUnavailable:Invalid'
        Should -Invoke Invoke-AUWithLock -Times 0 -Exactly
        [IO.File]::ReadAllBytes($script:LedgerPath) | Should -Be $Before
    }

    It 'skips the run with SrumReadFailed:WorkDirUntrusted when the work root is untrusted' {
        Mock New-AUWorkDir { throw "$($script:AUWorkDirUntrustedStatus): C:\Windows\PowerStacksAppUsage isn't a folder only SYSTEM and Administrators control, so it was left alone." }
        $Result = Invoke-AppUsage -RunId $script:Run
        Get-TestTokens $Result | Should -Contain 'SrumReadFailed:WorkDirUntrusted'
        Get-TestTokens $Result | Should -Not -Contain 'AppUsageFailed'
        Should -Invoke New-AUSnapshot -Times 0 -Exactly
        Should -Invoke Get-AUInstalledApps -Times 0 -Exactly
        Should -Invoke Remove-AUSnapshot -Times 0 -Exactly
        $Result.InventoryApps | Should -BeNullOrEmpty
    }

    It 'skips the run with ShadowCopyFailed, and still removes the work folder' {
        Mock New-AUSnapshot { [pscustomobject]@{ WorkDir = $WorkDir; ShadowId = $null; SrumDbPath = $null; HiveCopies = @{}; MachineDomainSid = ''; Status = 'ShadowCopyFailed' } }
        $Result = Invoke-AppUsage -RunId $script:Run
        Get-TestTokens $Result | Should -Contain 'ShadowCopyFailed'
        Should -Invoke Get-AUInstalledApps -Times 0 -Exactly
        Should -Invoke Read-AUSrum -Times 0 -Exactly
        Should -Invoke Remove-AUSnapshot -Times 1 -Exactly
        $Result.InventoryApps | Should -BeNullOrEmpty
    }

    It 'skips the run with LowDiskSpace, and still removes the work folder (I4)' {
        Mock New-AUSnapshot { [pscustomobject]@{ WorkDir = $WorkDir; ShadowId = $null; SrumDbPath = $null; HiveCopies = @{}; MachineDomainSid = ''; Status = 'LowDiskSpace' } }
        $Result = Invoke-AppUsage -RunId $script:Run
        Get-TestTokens $Result | Should -Be @('LowDiskSpace')
        $Result.DeviceColumns['AppUsageCollectionStatus_s'] | Should -BeExactly 'LowDiskSpace'
        Should -Invoke Get-AUInstalledApps -Times 0 -Exactly
        Should -Invoke Read-AUSrum -Times 0 -Exactly
        Should -Invoke Remove-AUSnapshot -Times 1 -Exactly
        $Result.InventoryApps | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-AppUsage never throws and stays silent (D28, D40)' {
    BeforeEach { Use-TestDevice }

    It 'turns an unexpected error before the lock into AppUsageFailed' {
        Mock Get-AUOsBuild { throw 'registry gone' }
        $Result = Invoke-AppUsage -RunId $script:Run
        $Result.Status | Should -BeExactly 'AppUsageFailed'
        $Result.InventoryApps | Should -BeNullOrEmpty
        $Result.DeviceColumns['AppUsageCollectionStatus_s'] | Should -BeExactly 'AppUsageFailed'
    }

    It 'turns an error under the lock into AppUsageFailed, with blank results, the budget closed, and the snapshot removed' {
        Mock Get-AUKnownExes { throw 'aggregation failed' }
        $Result = Invoke-AppUsage -RunId $script:Run
        Get-TestTokens $Result | Should -Contain 'AppUsageFailed'
        $Result.InventoryApps | Should -BeNullOrEmpty
        $Result.AppFields | Should -BeNullOrEmpty
        $Result.ExeEntries | Should -BeNullOrEmpty
        $Result.UnmatchedExeCount | Should -BeNullOrEmpty
        Should -Invoke New-AUReadBudget -Times 1 -Exactly
        Should -Invoke Close-AUReadBudget -Times 1 -Exactly -ParameterFilter { $ReadBudget.Id -eq 'run-budget' }
        Should -Invoke Remove-AUSnapshot -Times 1 -Exactly
    }

    It 'writes nothing to any stream but its one result' {
        Mock Get-AUUsers { Write-Host 'host'; Write-Warning 'warning'; Write-Information 'information'; Write-Error 'error'; $script:Users }
        Mock Remove-AUSnapshot { Write-Output 'stray output'; Write-Host 'host again'; Write-Error 'another error' }
        Mock Get-AUServiceBinaries { Write-Warning 'service warning'; @{} }
        $All = @(Invoke-AppUsage -RunId $script:Run *>&1)
        $All.Count | Should -Be 1
        $All[0].RunId | Should -BeExactly $script:Run
        $All[0].ExeEntries | Should -Not -BeNullOrEmpty
    }

    It 'keeps its results when the caller''s error preference is Stop and the log is locked' {
        # GitHub's shell: powershell runs under Stop, and the real logger writes an error when the log is locked.
        function Write-CMTraceLog { param ([string]$Message, [string]$Component, [int]$Type) Write-Error 'Write-CMTraceLog failed: the log is being used by another process.' }
        Mock Get-AUUsers { Write-Error 'stray error'; $script:Users }
        $ErrorActionPreference = 'Stop'
        try { $All = @(Invoke-AppUsage -RunId $script:Run 2>$null) }
        finally { $ErrorActionPreference = 'Continue' }
        $Results = @($All | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] })
        $Results.Count | Should -Be 1
        $Results[0].RunId | Should -BeExactly $script:Run
        Get-TestTokens $Results[0] | Should -Not -Contain 'AppUsageFailed'
        $Results[0].ExeEntries | Should -Not -BeNullOrEmpty
    }
}

Describe 'Invoke-AppUsage results' {
    BeforeEach { Use-TestDevice }

    It 'returns the contract fields, with the device columns in the spec order' {
        $Result = Invoke-AppUsage -RunId $script:Run
        @($Result.PSObject.Properties.Name) | Should -Be @('RunId', 'Status', 'StatusTokens', 'InventoryApps', 'AppFields', 'ExeEntries', 'UnmatchedExeCount', 'WatchingSince',
            'ProfilesFound', 'ProfilesRead', 'MappingsVersion', 'CustomerMappingsHash', 'DeviceColumns', 'LedgerPath', 'OutboxPath', 'Timings')
        $Result.RunId | Should -BeExactly $script:Run
        $Result.Status | Should -BeExactly 'OK'
        @($Result.DeviceColumns.Keys) | Should -Be @('AppUsageEnabled_b', 'WatchingSince_t', 'AppUsageScriptVersion_s', 'MappingsVersion_s', 'CustomerMappingsHash_s',
            'UnmatchedExeCount_d', 'ProfilesFound_d', 'ProfilesRead_d', 'AppUsageCollectionStatus_s')
        $Result.DeviceColumns['AppUsageScriptVersion_s'] | Should -BeExactly '20 - test'
        $Result.DeviceColumns['MappingsVersion_s'] | Should -BeExactly '2026.11.22.9'
        $Result.DeviceColumns['CustomerMappingsHash_s'] | Should -Match '^[0-9a-f]{64}$'
        $Result.DeviceColumns['WatchingSince_t'] | Should -BeExactly '2026-10-01T08:00:00.0000000Z'
        $Result.DeviceColumns['ProfilesFound_d'] | Should -Be 3
        $Result.DeviceColumns['ProfilesRead_d'] | Should -Be 3
        $Result.LedgerPath | Should -BeExactly $script:LedgerPath
        $Result.OutboxPath | Should -Match 'AppUsage_TESTSERIAL_outbox$'
        foreach ($Stage in @('Snapshot', 'Discovery', 'LedgerRead', 'SrumRead', 'Merge', 'Facts', 'Aggregation', 'LedgerWrite', 'Total')) { $Result.Timings.Contains($Stage) | Should -BeTrue -Because $Stage }
    }

    It 'names the device columns without suffixes for the classic API' {
        $script:LogAPIMode = 'DataCollectorAPI'
        $Result = Invoke-AppUsage -RunId $script:Run
        @($Result.DeviceColumns.Keys) | Should -Contain 'AppUsageCollectionStatus'
        @($Result.DeviceColumns.Keys) | Should -Not -Contain 'AppUsageCollectionStatus_s'
    }

    It 'gives the run a new GUID when the RunId is not one' {
        $Result = Invoke-AppUsage -RunId 'not-a-guid'
        [guid]::Parse($Result.RunId) | Should -Not -Be ([guid]::Empty)
        Should -Invoke New-AUWorkDir -Times 1 -Exactly -ParameterFilter { $RunId -eq $Result.RunId }
    }

    It 'builds the inventory entries and their usage fields from discovery, one per DisplayName' {
        $Result = Invoke-AppUsage -RunId $script:Run
        @($Result.InventoryApps.AppName) | Should -Be @('Contoso Alpha', 'Contoso Beta', 'Fabrikam Tool')
        @($Result.InventoryApps | Where-Object AppName -eq 'Contoso Beta').AppVersion | Should -BeExactly '1.5'
        $Result.AppFields['Contoso Alpha'].AppUsageStatus | Should -BeExactly 'Used'
        $Result.AppFields['Contoso Alpha'].AppLastUsedDate | Should -BeExactly '2026-11-20T15:30:00.0000000Z'
        $Alpha = Get-TestExe $Result 'alpha.exe'
        $Alpha.Count | Should -Be 1
        Should -Invoke Get-AUServiceBinaries -Times 1 -Exactly
        Should -Invoke New-AUReadBudget -Times 1 -Exactly
        Should -Invoke Close-AUReadBudget -Times 1 -Exactly
        Should -Invoke Remove-AUSnapshot -Times 1 -Exactly
    }

    It 'writes the ledger with the merged rows and the stored target' {
        $Facts = New-TestFacts 'alpha.exe'
        Save-TestLedger @((New-TestEntry $script:UserA 'alpha.exe' @{ Facts = $Facts }))
        $null = Invoke-AppUsage -RunId $script:Run
        $Entry = Get-TestLedgerEntry $script:UserA 'alpha.exe'
        @($Entry.Counted.Keys) | Should -Be @('E1|100')
        $Entry.StoredTarget.MatchRuleId | Should -BeExactly 'ps-alpha'
        $Entry.StoredTarget.ResolvedAppName | Should -BeExactly 'Contoso Alpha'
        $Entry.FactsVerified | Should -BeTrue
    }

    It 'reports DiscoveryFailed and leaves the inventory to its own read, but keeps the usage evidence' {
        $script:Discovery = New-TestDiscovery @{ ScopeRead = (New-TestScopeRead @{ Machine = 'Unread' }) }
        $Result = Invoke-AppUsage -RunId $script:Run
        Get-TestTokens $Result | Should -Contain 'DiscoveryFailed'
        $Result.InventoryApps | Should -BeNullOrEmpty
        $Result.AppFields | Should -BeNullOrEmpty
        (Get-TestExe $Result 'alpha.exe').Count | Should -Be 1
        [IO.File]::Exists($script:LedgerPath) | Should -BeTrue
    }

    It 'reports DiscoveryFailed when a signed-in user was not read' {
        $script:Discovery = New-TestDiscovery @{ ScopeRead = (New-TestScopeRead @{ $script:UserA = 'Unread' }); ProfilesRead = 2 }
        $Result = Invoke-AppUsage -RunId $script:Run
        Get-TestTokens $Result | Should -Contain 'DiscoveryFailed'
        Get-TestTokens $Result | Should -Contain 'ProfileUnread:1'
    }

    It 'reports unread profiles, hive copies left loaded, and an unread Windows Installer map' {
        $script:Discovery = New-TestDiscovery @{ ScopeRead = (New-TestScopeRead @{ $script:UserB = 'Unread' }); ProfilesRead = 2; HiveUnloadFailures = 2; MsiFileMapRead = $false }
        $Result = Invoke-AppUsage -RunId $script:Run
        $Tokens = Get-TestTokens $Result
        $Tokens | Should -Contain 'ProfileUnread:1'
        $Tokens | Should -Contain 'HiveUnloadFailed:2'
        $Tokens | Should -Contain 'MsiFileMapFailed'
        $Tokens | Should -Not -Contain 'DiscoveryFailed'
        $Result.InventoryApps | Should -Not -BeNullOrEmpty
    }

    It 'reports the customer file: <Case>' -ForEach @(
        @{ Case = 'invalid'; Token = 'InvalidCustomerMappings'; Setup = { [IO.File]::WriteAllText($script:CustomerPath, '{ not json') } }
        @{ Case = 'too large'; Token = 'InvalidCustomerMappings:TooLarge'; Setup = { [IO.File]::WriteAllText($script:CustomerPath, (' ' * 1048577)) } }
        @{ Case = 'unsafe path'; Token = 'InvalidCustomerMappings:UnsafePath'; Setup = { $script:AppUsageCustomerMappingsPath = 'relative\customer-mappings.json' } }
    ) {
        & $Setup
        $Result = Invoke-AppUsage -RunId $script:Run
        Get-TestTokens $Result | Should -Contain $Token
        $Result.ExeEntries | Should -Not -BeNullOrEmpty
        $Result.DeviceColumns['CustomerMappingsHash_s'] | Should -BeExactly ''
    }

    It 'reports OK when there is no customer file: the blank hash says so' {
        Remove-Item -LiteralPath $script:CustomerPath
        $Result = Invoke-AppUsage -RunId $script:Run
        $Result.Status | Should -BeExactly 'OK'
        $Result.ExeEntries | Should -Not -BeNullOrEmpty
        $Result.DeviceColumns['CustomerMappingsHash_s'] | Should -BeExactly ''
        $Result.DeviceColumns['AppUsageCollectionStatus_s'] | Should -BeExactly 'OK'
    }

    It 'reports LedgerReset for an unreadable ledger' {
        [IO.File]::WriteAllText($script:LedgerPath, '{ broken')
        $Result = Invoke-AppUsage -RunId $script:Run
        Get-TestTokens $Result | Should -Contain 'LedgerReset'
    }

    It 'folds the ledger before writing it, and reports LedgerWriteFailed without losing the results' {
        $script:Order = New-Object 'System.Collections.Generic.List[string]'
        Mock Invoke-AULedgerFold { $script:Order.Add('Fold') }
        Mock Write-AULedger { $script:Order.Add('Write'); throw 'disk full' }
        $Result = Invoke-AppUsage -RunId $script:Run
        @($script:Order) | Should -Be @('Fold', 'Write')
        Get-TestTokens $Result | Should -Contain 'LedgerWriteFailed'
        Get-TestTokens $Result | Should -Not -Contain 'AppUsageFailed'
        $Result.InventoryApps | Should -Not -BeNullOrEmpty
        $Result.ExeEntries | Should -Not -BeNullOrEmpty
    }

    It 'logs the time each stage took' {
        $script:Logged = New-Object 'System.Collections.Generic.List[string]'
        function Write-CMTraceLog { param ([string]$Message, [string]$Component, [int]$Type) $script:Logged.Add($Message) }
        $null = Invoke-AppUsage -RunId $script:Run
        foreach ($Stage in @('Snapshot', 'Discovery', 'LedgerRead', 'SrumRead', 'Merge', 'Facts', 'Aggregation', 'LedgerWrite'))
        {
            @($script:Logged | Where-Object { $_ -like "App Usage: stage $Stage took * ms." }).Count | Should -Be 1 -Because $Stage
        }
    }

    It 'logs how many files had an untrusted owner, as a count (I2)' {
        $script:Logged = New-Object 'System.Collections.Generic.List[string]'
        function Write-CMTraceLog { param ([string]$Message, [string]$Component, [int]$Type) $script:Logged.Add($Message) }
        Mock New-AUReadBudget { [pscustomobject]@{ Id = 'run-budget'; TimeoutMs = 5000; RemainingMs = 120000; Runspace = $null; ScriptText = $null; Reads = 3; TimedOut = 0; Skipped = 0; UntrustedOwner = 2 } }
        $null = Invoke-AppUsage -RunId $script:Run
        @($script:Logged | Where-Object { $_ -like 'App Usage: recalculated * 3 timed file reads, 0 timed out, 0 skipped, 2 with an untrusted owner.' }).Count | Should -Be 1
    }
}

Describe 'Invoke-AppUsage and SRUM (F10, F35, carries)' {
    BeforeEach {
        Use-TestDevice
        $Counted = @{ 'E1|90' = @{ F = [double]40; I = [double]0; T = $script:Earlier }; 'E1|95' = @{ F = [double]5; I = [double]0; T = $script:Earlier } }
        Save-TestLedger @((New-TestEntry $script:UserA 'alpha.exe' @{ Facts = (New-TestFacts 'alpha.exe'); Counted = $Counted; LastFocusOrInputTime = $script:Earlier; LastRanTime = $script:Earlier }))
    }

    It 'never merges after a failed or empty SRUM read: <Case>' -ForEach @(
        @{ Case = 'EsentMissing'; Read = @{ Status = 'SrumReadFailed:EsentMissing'; Timeline = @(); Epoch = $null }; Token = 'SrumReadFailed:EsentMissing' }
        @{ Case = 'OK with no rows'; Read = @{ Timeline = @() }; Token = 'SrumReadFailed:NoRows' }
    ) {
        $script:Srum = New-TestSrum @() $Read
        Mock Merge-AUSrumRecords { }
        $Result = Invoke-AppUsage -RunId $script:Run
        Should -Invoke Merge-AUSrumRecords -Times 0 -Exactly
        Get-TestTokens $Result | Should -Contain $Token
        $Result.AppFields['Contoso Alpha'].AppUsageStatus | Should -BeNullOrEmpty
    }

    It 'leaves the counted keys unchanged after a failed SRUM read' {
        $script:Srum = New-TestSrum @() @{ Status = 'SrumReadFailed:EsentMissing'; Epoch = $null }
        $null = Invoke-AppUsage -RunId $script:Run
        $Entry = Get-TestLedgerEntry $script:UserA 'alpha.exe'
        @($Entry.Counted.Keys | Sort-Object) | Should -Be @('E1|90', 'E1|95')
        $Entry.ArchivedFocus | Should -Be 0
    }

    It 'reports a snapshot that could not copy SRUM, and does not read it' {
        Mock New-AUSnapshot { [pscustomobject]@{ WorkDir = $WorkDir; ShadowId = $null; SrumDbPath = $null; HiveCopies = @{}; MachineDomainSid = $script:MachineDomain; Status = 'SrumReadFailed:CopyFailed' } }
        Mock Merge-AUSrumRecords { }
        $Result = Invoke-AppUsage -RunId $script:Run
        Get-TestTokens $Result | Should -Contain 'SrumReadFailed:CopyFailed'
        Should -Invoke Read-AUSrum -Times 0 -Exactly
        Should -Invoke Merge-AUSrumRecords -Times 0 -Exactly
        $Result.InventoryApps | Should -Not -BeNullOrEmpty
    }

    It 'merges with -NoArchive when the copy was repaired or the read is incomplete: <Case>' -ForEach @(
        @{ Case = 'clean'; Repaired = $false; Complete = $true; NoArchive = $false }
        @{ Case = 'repaired'; Repaired = $true; Complete = $true; NoArchive = $true }
        @{ Case = 'incomplete'; Repaired = $false; Complete = $false; NoArchive = $true }
    ) {
        $script:Srum = New-TestSrum @((New-TestRow $script:UserA 'alpha.exe' 100)) @{ Repaired = $Repaired; Complete = $Complete }
        $script:Merged = $null
        Mock Merge-AUSrumRecords { $script:Merged = [pscustomobject]@{ NoArchive = $NoArchive.IsPresent; Rows = $Rows; UserTypes = $UserTypes; Lowest = $LowestAutoIncId; Epoch = $Epoch; MinFocus = $MinFocusSeconds } }
        $null = Invoke-AppUsage -RunId $script:Run
        $script:Merged.NoArchive | Should -Be $NoArchive
        $script:Merged.Epoch | Should -BeExactly 'E1'
        $script:Merged.MinFocus | Should -Be 1
    }

    It 'archives nothing of a repaired read, end to end' {
        $script:Srum = New-TestSrum @((New-TestRow $script:UserA 'alpha.exe' 100)) @{ Epoch = 'E2'; Repaired = $true }
        $null = Invoke-AppUsage -RunId $script:Run
        @((Get-TestLedgerEntry $script:UserA 'alpha.exe').Counted.Keys | Sort-Object) | Should -Be @('E1|90', 'E1|95', 'E2|100')
    }

    It 'builds UserTypes from the SRUM rows'' SIDs, case-insensitively, not from ProfileList' {
        $script:Srum = New-TestSrum @((New-TestRow $script:UserA.ToLowerInvariant() 'alpha.exe' 100), (New-TestRow $script:Gone 'gamma.exe' 101), (New-TestRow $null 'system' 102 0 $script:Recent 'System'))
        $script:Merged = $null
        Mock Merge-AUSrumRecords { $script:Merged = [pscustomobject]@{ UserTypes = $UserTypes } }
        $null = Invoke-AppUsage -RunId $script:Run
        $Types = $script:Merged.UserTypes
        $Types[$script:UserA] | Should -BeExactly 'CloudOnly'
        $Types[$script:UserA.ToLowerInvariant()] | Should -BeExactly 'CloudOnly'
        $Types[$script:Gone] | Should -BeExactly 'CloudOnly'
        $Types[''] | Should -BeExactly 'Unknown'
        $Types.ContainsKey($script:UserB) | Should -BeFalse
        $Types.Count | Should -Be 3
    }

    It 'drops Store and MSIX rows before the merge when Store inventory is off, keeping the read''s lowest ID (F35)' {
        $Package = 'Microsoft.WindowsCalculator_8wekyb3d8bbwe!App'
        $script:Srum = New-TestSrum @((New-TestRow $script:UserA 'alpha.exe' 100), (New-TestRow $script:UserA '' 50 30 $script:Recent $Package))
        $script:Merged = $null
        Mock Merge-AUSrumRecords { $script:Merged = [pscustomobject]@{ Rows = $Rows; Lowest = $LowestAutoIncId } }
        $null = Invoke-AppUsage -RunId $script:Run
        @($script:Merged.Rows | Where-Object { $_.ExeInfo -eq $Package }).Count | Should -Be 0
        @($script:Merged.Rows).Count | Should -Be 1
        $script:Merged.Lowest | Should -Be 50
        Should -Invoke Get-AUInstalledApps -Times 1 -Exactly -ParameterFilter { -not $IncludeStore }
    }

    It 'skips a blank AutoIncId when it finds the read''s lowest ID' {
        $Blank = New-TestRow $script:UserA 'alpha.exe' 1
        $Blank.AutoIncId = ''
        $Spaces = New-TestRow $script:UserA 'alpha.exe' 1
        $Spaces.AutoIncId = '  '
        $script:Srum = New-TestSrum @((New-TestRow $script:UserA 'alpha.exe' 200), $Blank, (New-TestRow $script:UserA 'alpha.exe' 150), $Spaces)
        $script:Merged = $null
        Mock Merge-AUSrumRecords { $script:Merged = [pscustomobject]@{ Rows = $Rows; Lowest = $LowestAutoIncId } }
        $null = Invoke-AppUsage -RunId $script:Run
        $script:Merged.Lowest | Should -Be 150
    }

    It 'passes Store and MSIX rows and discovery on when Store inventory is on (D46)' {
        $CollectUWPInventory = $true
        $Package = 'Microsoft.WindowsCalculator_8wekyb3d8bbwe!App'
        $script:Srum = New-TestSrum @((New-TestRow $script:UserA 'alpha.exe' 100), (New-TestRow $script:UserA '' 50 30 $script:Recent $Package))
        $script:Merged = $null
        Mock Merge-AUSrumRecords { $script:Merged = [pscustomobject]@{ Rows = $Rows } }
        $null = Invoke-AppUsage -RunId $script:Run
        @($script:Merged.Rows | Where-Object { $_.ExeInfo -eq $Package }).Count | Should -Be 1
        Should -Invoke Get-AUInstalledApps -Times 1 -Exactly -ParameterFilter { $IncludeStore }
    }

    It 'leaves a Store entry out of the results when Store inventory is off, and keeps it in the ledger' {
        $Package = 'Microsoft.WindowsCalculator_8wekyb3d8bbwe!App'
        $Store = New-AULedgerEntry $script:UserA $Package
        $Store.LastRanTime = $script:Earlier
        $Ledger = Read-AULedger -Path $script:LedgerPath
        $Ledger.Entries["$($script:UserA)|$Package"] = $Store
        Write-AULedger -Ledger $Ledger -Path $script:LedgerPath
        $Result = Invoke-AppUsage -RunId $script:Run
        @($Result.ExeEntries | Where-Object { $_.ExeInfo -eq $Package }).Count | Should -Be 0
        (Read-AULedger -Path $script:LedgerPath).Entries.ContainsKey("$($script:UserA)|$Package") | Should -BeTrue
    }
}

Describe 'Invoke-AppUsage recalculates every entry (D13, F16, F17, F22, F29)' {
    BeforeEach { Use-TestDevice }

    It 'runs the per-entry steps in order, classifying a retained customer target as Customer (F17)' {
        $script:Calls = New-Object 'System.Collections.Generic.List[string]'
        Save-TestLedger @((New-TestEntry $script:UserA 'zeta.exe'))
        $script:Srum = New-TestSrum @((New-TestRow $script:UserA 'alpha.exe' 100)) @{ Resource = @([pscustomobject]@{ UserSid = $script:UserA; ExeName = 'zeta.exe'; KernelPath = '\Device\HarddiskVolume3\Apps\zeta.exe'; TimeStampUtc = $script:Recent }) }
        Mock Find-AUExePath { $script:Calls.Add("Find:$($ExeInfo.ExeName)"); if ($ExeInfo.ExeName -eq 'zeta.exe') { [pscustomobject]@{ Path = 'C:\Apps\zeta.exe'; Verified = $true } } }
        Mock Get-AUExeFacts { $script:Calls.Add("Facts:$($ExeInfo.ExeName)"); New-TestFacts $ExeInfo.ExeName @{ RunPath = $Path } }
        Mock Resolve-AUIdentity { $script:Calls.Add("Identity:$($Facts.ExeName)"); [pscustomobject]@{ TargetPattern = $null; TargetPublisher = $null; ResolvedAppName = $null; ProductCode = $null; PackageFamily = $null; MatchSection = 'None'; MatchRuleId = $null; RuleType = $null; InstalledStateDependent = $false; EvidenceUsed = 'Verified'; CandidateTargets = $null } }
        Mock Resolve-AUTarget {
            $script:Calls.Add("Target:$($Identity.MatchSection)")
            [pscustomobject]@{ TargetPattern = 'Fabrikam Tool*'; TargetPublisher = 'Fabrikam'; ResolvedAppName = 'Fabrikam Tool'; ProductCode = $null; PackageFamily = $null; MatchSection = 'Retained'; MatchRuleId = 'c-tool'; RuleType = 'identity'; InstalledStateDependent = $false; EvidenceUsed = 'Verified'; CandidateTargets = $null; RetainedFrom = 'Customer' }
        }
        Mock Get-AUClassification { $script:Calls.Add("Classification:$MatchSection"); [pscustomobject]@{ RuleRole = $null; ClassificationRuleId = $null; Ignored = $false; IgnoreRuleId = $null } }
        Mock Get-AURole { $script:Calls.Add("Role:$($Classification.Ignored)"); 'App' }
        $null = Invoke-AppUsage -RunId $script:Run
        $Zeta = @($script:Calls | Select-Object -Last 6)
        $Zeta | Should -Be @('Find:zeta.exe', 'Facts:zeta.exe', 'Identity:zeta.exe', 'Target:None', 'Classification:Customer', 'Role:False')
        # alpha.exe, then zeta.exe (the entries run in key order).
        Should -Invoke Get-AUClassification -ParameterFilter { $MatchSection -eq 'Customer' } -Times 2 -Exactly
    }

    It 'keeps a PowerStacks ignore rule off an exe held by a retained customer target (F17)' {
        # The customer rule c-tool still exists, but this build's verified company isn't Fabrikam, so
        # the stored customer target is retained. PowerStacks' ps-ignore-tool names tool.exe.
        $Stored = [pscustomobject]@{ Section = 'Customer'; MatchRuleId = 'c-tool'; RuleType = 'identity'; TargetPattern = 'Fabrikam Tool*'; TargetPublisher = 'Fabrikam'; ResolvedAppName = 'Fabrikam Tool'; ProductCode = $null; PackageFamily = $null; EvidenceUsed = 'Verified' }
        Save-TestLedger @((New-TestEntry $script:UserA 'tool.exe' @{ Facts = (New-TestFacts 'tool.exe'); StoredTarget = $Stored; LastRanTime = $script:Earlier }))
        $Result = Invoke-AppUsage -RunId $script:Run
        $Tool = Get-TestExe $Result 'tool.exe'
        $Tool.Count | Should -Be 1
        $Tool[0].MatchSection | Should -BeExactly 'Retained'
        $Tool[0].ClassificationRuleId | Should -BeNullOrEmpty
        $Tool[0].InstallStatus | Should -BeExactly 'Installed'
    }

    It 'marks a ledger user missing from ProfileList Deleted, so their per-user target is NotInstalled (F29)' {
        $script:Discovery = New-TestDiscovery @{ ScopeRead = (New-TestScopeRead @{ $script:UserB = 'Unread' }); ProfilesRead = 2 }
        Save-TestLedger @(
            (New-TestEntry $script:Gone 'gamma.exe' @{ Facts = (New-TestFacts 'gamma.exe'); LastRanTime = $script:Earlier })
            (New-TestEntry $script:UserB 'gamma.exe' @{ Facts = (New-TestFacts 'gamma.exe'); LastRanTime = $script:Earlier })
        )
        $script:Srum = New-TestSrum @((New-TestRow $script:Gone 'gamma.exe' 100 30))
        $Result = Invoke-AppUsage -RunId $script:Run
        $Gamma = @(Get-TestExe $Result 'gamma.exe')
        # Both users' entries share the build and target, so they combine: Unknown wins over NotInstalled.
        $Gamma.Count | Should -Be 1
        $Gamma[0].MatchSection | Should -BeExactly 'PowerStacks'
        $Gamma[0].InstallStatus | Should -BeExactly 'Unknown'
        $Gamma[0].UsersWithUse | Should -Be 1
        $Gamma[0].LastUsedTime | Should -BeExactly '2026-11-20T15:30:00.0000000Z'
    }

    It 'doesn''t mark the Window Manager and Font Driver Host virtual accounts Deleted (Task 21)' {
        $Dwm = 'S-1-5-90-0-1'
        $Umfd = 'S-1-5-96-0-1'
        Save-TestLedger @(
            (New-TestEntry $Dwm 'dwm.exe' @{ Facts = (New-TestFacts 'dwm.exe'); LastRanTime = $script:Earlier })
            (New-TestEntry $Umfd 'fontdrvhost.exe' @{ Facts = (New-TestFacts 'fontdrvhost.exe'); LastRanTime = $script:Earlier })
            (New-TestEntry $script:Gone 'gamma.exe' @{ Facts = (New-TestFacts 'gamma.exe'); LastRanTime = $script:Earlier })
        )
        $script:ScopeSeen = $null
        Mock Get-AUInstallStatus { if ($null -eq $script:ScopeSeen) { $script:ScopeSeen = $ScopeRead.Clone() }; 'Unmatched' }
        $script:Logged = New-Object 'System.Collections.Generic.List[string]'
        function Write-CMTraceLog { param ([string]$Message, [string]$Component, [int]$Type) $script:Logged.Add($Message) }
        $null = Invoke-AppUsage -RunId $script:Run
        $script:ScopeSeen[$script:Gone] | Should -BeExactly 'Deleted'
        $script:ScopeSeen.ContainsKey($Dwm) | Should -BeFalse
        $script:ScopeSeen.ContainsKey($Umfd) | Should -BeFalse
        @($script:Logged | Where-Object { $_ -like 'App Usage: * ledger users are no longer in ProfileList (Deleted).' }) | Should -Be @('App Usage: 1 ledger users are no longer in ProfileList (Deleted).')
    }

    It 'gives the deleted user''s per-user target NotInstalled on its own (F29)' {
        Save-TestLedger @((New-TestEntry $script:Gone 'gamma.exe' @{ Facts = (New-TestFacts 'gamma.exe'); LastRanTime = $script:Earlier }))
        $script:Entries = $null
        Mock ConvertTo-AUExeUsage { $script:Entries = $Entries; @() }
        $null = Invoke-AppUsage -RunId $script:Run
        $Entry = @($script:Entries | Where-Object { $_.UserSid -eq $script:Gone })
        $Entry.Count | Should -Be 1
        $Entry[0].InstallStatus | Should -BeExactly 'NotInstalled'
        $Entry[0].UserType | Should -BeExactly 'CloudOnly'
        @($script:Entries | Where-Object { $_.UserSid -eq $script:UserA })[0].InstallStatus | Should -BeExactly 'Installed'
    }

    It 'keeps an ignored exe in ExeEntries and out of UnmatchedExeCount_d (F22)' {
        Save-TestLedger @(
            (New-TestEntry $script:UserA 'noise1.exe' @{ Facts = (New-TestFacts 'noise1.exe' @{ FileCompanyName = 'Noise' }); LastRanTime = $script:Earlier })
            (New-TestEntry $script:UserA 'other.exe' @{ Facts = (New-TestFacts 'other.exe' @{ FileCompanyName = 'Other' }); LastRanTime = $script:Earlier })
        )
        $Result = Invoke-AppUsage -RunId $script:Run
        $Noise = Get-TestExe $Result 'noise1.exe'
        $Noise.Count | Should -Be 1
        $Noise[0].ClassificationRuleId | Should -BeExactly 'ps-ignore-noise'
        $Noise[0].MatchSection | Should -BeExactly 'None'
        (Get-TestExe $Result 'other.exe')[0].MatchSection | Should -BeExactly 'None'
        $Result.UnmatchedExeCount | Should -Be 1
        $Result.DeviceColumns['UnmatchedExeCount_d'] | Should -Be 1
    }

    It 'matches an Unmatched entry absent from SRUM once a new customer rule names its exe (D13)' {
        Save-TestLedger @((New-TestEntry $script:UserA 'beta.exe' @{ Facts = (New-TestFacts 'beta.exe'); LastRanTime = $script:Recent; LastFocusOrInputTime = $script:Recent }))
        $First = Invoke-AppUsage -RunId $script:Run
        (Get-TestExe $First 'beta.exe')[0].InstallStatus | Should -BeExactly 'Unmatched'
        $First.AppFields['Contoso Beta'].AppUsageStatus | Should -BeExactly 'NotCovered'

        Set-TestCustomerFile @($script:CustomerToolRule, $script:CustomerBetaRule)
        $Second = Invoke-AppUsage -RunId ([guid]::NewGuid().ToString())
        $Beta = Get-TestExe $Second 'beta.exe'
        $Beta[0].MatchSection | Should -BeExactly 'Customer'
        $Beta[0].MatchRuleId | Should -BeExactly 'c-beta'
        $Beta[0].InstallStatus | Should -BeExactly 'Installed'
        $Second.AppFields['Contoso Beta'].AppUsageStatus | Should -BeExactly 'Used'
        (Get-TestLedgerEntry $script:UserA 'beta.exe').StoredTarget.MatchRuleId | Should -BeExactly 'c-beta'
    }

    It 'clears a stored target whose rule was dropped' {
        $Stored = [pscustomobject]@{ Section = 'Customer'; MatchRuleId = 'c-removed'; RuleType = 'identity'; TargetPattern = 'Contoso Old*'; TargetPublisher = 'Contoso'; ResolvedAppName = 'Contoso Old'; ProductCode = $null; PackageFamily = $null; EvidenceUsed = 'Verified' }
        Save-TestLedger @((New-TestEntry $script:UserA 'old.exe' @{ Facts = (New-TestFacts 'old.exe'); StoredTarget = $Stored; LastRanTime = $script:Earlier }))
        $Result = Invoke-AppUsage -RunId $script:Run
        (Get-TestExe $Result 'old.exe')[0].MatchSection | Should -BeExactly 'None'
        (Get-TestLedgerEntry $script:UserA 'old.exe').StoredTarget | Should -BeNullOrEmpty
    }

    It 'keeps a stored customer target while the customer file is invalid (D45)' {
        $Stored = [pscustomobject]@{ Section = 'Customer'; MatchRuleId = 'c-removed'; RuleType = 'identity'; TargetPattern = 'Contoso Old*'; TargetPublisher = 'Contoso'; ResolvedAppName = 'Contoso Old'; ProductCode = $null; PackageFamily = $null; EvidenceUsed = 'Verified' }
        Save-TestLedger @((New-TestEntry $script:UserA 'old.exe' @{ Facts = (New-TestFacts 'old.exe'); StoredTarget = $Stored; LastRanTime = $script:Earlier }))
        [IO.File]::WriteAllText($script:CustomerPath, '{ not json')
        $Result = Invoke-AppUsage -RunId $script:Run
        (Get-TestExe $Result 'old.exe')[0].MatchSection | Should -BeExactly 'Retained'
        (Get-TestLedgerEntry $script:UserA 'old.exe').StoredTarget.MatchRuleId | Should -BeExactly 'c-removed'
    }

    It 'keeps stored verified facts without reading the file again, and reads facts for a build with none' {
        Save-TestLedger @(
            (New-TestEntry $script:UserA 'alpha.exe' @{ Facts = (New-TestFacts 'alpha.exe'); LastRanTime = $script:Earlier })
            (New-TestEntry $script:UserA 'delta.exe' @{ LastRanTime = $script:Earlier })
        )
        $script:Srum = New-TestSrum @((New-TestRow $script:UserA 'alpha.exe' 100)) @{ Resource = @(
                [pscustomobject]@{ UserSid = $script:UserA; ExeName = 'alpha.exe'; KernelPath = '\Device\HarddiskVolume3\Program Files\Contoso\alpha.exe'; TimeStampUtc = $script:Recent }
                [pscustomobject]@{ UserSid = $script:UserA; ExeName = 'delta.exe'; KernelPath = '\Device\HarddiskVolume3\Apps\delta.exe'; TimeStampUtc = $script:Recent }
            )
        }
        Mock Find-AUExePath { [pscustomobject]@{ Path = 'C:\Apps\delta.exe'; Verified = $true } }
        Mock Get-AUExeFacts { New-TestFacts 'delta.exe' @{ RunPath = $Path; FileCompanyName = 'Delta' } }
        $null = Invoke-AppUsage -RunId $script:Run
        Should -Invoke Find-AUExePath -Times 1 -Exactly -ParameterFilter { $ExeInfo.ExeName -eq 'delta.exe' -and $ReadBudget.Id -eq 'run-budget' -and @($KernelPaths) -contains '\Device\HarddiskVolume3\Apps\delta.exe' }
        Should -Invoke Find-AUExePath -Times 0 -Exactly -ParameterFilter { $ExeInfo.ExeName -eq 'alpha.exe' }
        Should -Invoke Get-AUExeFacts -Times 1 -Exactly -ParameterFilter { $Path -eq 'C:\Apps\delta.exe' -and $ReadBudget.Id -eq 'run-budget' -and $ExeInfoText -eq (New-TestExeInfo 'delta.exe') }
        $Delta = Get-TestLedgerEntry $script:UserA 'delta.exe'
        $Delta.FactsVerified | Should -BeTrue
        $Delta.Facts.FileCompanyName | Should -BeExactly 'Delta'
    }
}

Describe 'Discovery reports what Invoke-AppUsage surfaces' {
    It 'Read-AUUserApps flags a hive copy that will not unload' {
        $User = [pscustomobject]@{ Sid = 'S-1-5-21-100-200-300-1002'; UserType = 'Local'; ProfilePath = 'C:\Users\b'; ProfileState = 'Copied' }
        $Snapshot = [pscustomobject]@{ HiveCopies = @{ 'S-1-5-21-100-200-300-1002' = 'C:\copy\NTUSER.DAT' } }
        Mock Mount-AUHive { $true }
        Mock Open-AURegistryBase { [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software') }
        Mock Read-AUArpEntries { $true }
        Mock Dismount-AUHive { $false }
        $Native = New-Object 'System.Collections.Generic.List[object]'
        $Wow = New-Object 'System.Collections.Generic.List[object]'
        Read-AUUserApps -User $User -Snapshot $Snapshot -Native $Native -Wow $Wow | Should -BeTrue
        $User.HiveUnloadFailed | Should -BeTrue

        Mock Dismount-AUHive { $true }
        $Clean = [pscustomobject]@{ Sid = 'S-1-5-21-100-200-300-1002'; UserType = 'Local'; ProfilePath = 'C:\Users\b'; ProfileState = 'Copied' }
        Read-AUUserApps -User $Clean -Snapshot $Snapshot -Native $Native -Wow $Wow | Should -BeTrue
        $Clean.HiveUnloadFailed | Should -BeFalse
    }

    It 'Get-AUInstalledApps reports an unread Windows Installer map and counts hives left loaded' {
        Mock Open-AURegistryBase { [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software') }
        Mock Read-AUArpEntries { $true }
        Mock Read-AUMsiFileMap { $false }
        Mock Read-AUUserApps { if ($User.ProfileState -eq 'Copied') { $User | Add-Member -NotePropertyName HiveUnloadFailed -NotePropertyValue $true -Force }; $true }
        $Users = @(
            [pscustomobject]@{ Sid = 'S-1-5-18'; UserType = 'System'; ProfilePath = ''; ProfileState = 'Loaded' }
            [pscustomobject]@{ Sid = 'S-1-5-21-100-200-300-1002'; UserType = 'Local'; ProfilePath = 'C:\Users\b'; ProfileState = 'Copied' }
        )
        $Result = Get-AUInstalledApps -Users $Users -Snapshot $null
        $Result.MsiFileMapRead | Should -BeFalse
        $Result.HiveUnloadFailures | Should -Be 1

        Mock Read-AUMsiFileMap { $true }
        Mock Read-AUUserApps { $true }
        $Users = @($Users | ForEach-Object { [pscustomobject]@{ Sid = $_.Sid; UserType = $_.UserType; ProfilePath = $_.ProfilePath; ProfileState = $_.ProfileState } })
        $Result = Get-AUInstalledApps -Users $Users -Snapshot $null
        $Result.MsiFileMapRead | Should -BeTrue
        $Result.HiveUnloadFailures | Should -Be 0
    }

    It 'Get-AUAppxPackages applies the 24H2 fix before Get-AppxPackage' {
        $script:Order = New-Object 'System.Collections.Generic.List[string]'
        Mock Initialize-AUAppxSupport { $script:Order.Add('Fix') }
        Mock Get-AppxPackage { $script:Order.Add('Get-AppxPackage'); @() }
        $null = Get-AUAppxPackages
        @($script:Order) | Should -Be @('Fix', 'Get-AppxPackage')
        Should -Invoke Get-AppxPackage -Times 1 -Exactly -ParameterFilter { $AllUsers }
    }
}

Describe 'Merge-AUSrumRecords with a filtered read' {
    It 'ages out keys by the whole read''s lowest ID when the caller passes it' {
        $Make = {
            $Ledger = New-AULedger
            $Entry = New-AULedgerEntry 'S-1-12-1-1-2-3-4' '!!alpha.exe!2026/01/01:00:00:00!1a2b!'
            $Entry.Counted['E1|5'] = @{ F = [double]10; I = [double]0; T = $script:Earlier }
            $Ledger.Entries["$($Entry.UserSid)|$($Entry.ExeInfo)"] = $Entry
            $Ledger
        }
        $Rows = @([pscustomobject]@{ UserSid = 'S-1-12-1-1-2-3-4'; ExeInfo = '!!beta.exe!2026/01/01:00:00:00!1a2b!'; AutoIncId = 10; EndTimeUtc = $script:Recent; FocusSeconds = 1; InputSeconds = 0 })

        $Kept = & $Make
        Merge-AUSrumRecords -Ledger $Kept -Rows $Rows -Epoch 'E1' -UserTypes @{} -MinFocusSeconds 1 -LowestAutoIncId 3
        @($Kept.Entries.Values | ForEach-Object { $_.Counted.Keys }) | Should -Contain 'E1|5'

        $Aged = & $Make
        Merge-AUSrumRecords -Ledger $Aged -Rows $Rows -Epoch 'E1' -UserTypes @{} -MinFocusSeconds 1
        @($Aged.Entries.Values | ForEach-Object { $_.Counted.Keys }) | Should -Not -Contain 'E1|5'
    }
}
