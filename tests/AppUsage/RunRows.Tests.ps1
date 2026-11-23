BeforeAll {
    . "$PSScriptRoot\_Import.ps1"

    # Deterministic generated devices. The JSON is built as text, so a 4,000-app device takes
    # well under a second; the random hex keeps GZip from shrinking it to nothing.
    function Get-TestHex([Random]$Rng, [int]$Bytes)
    {
        $Buffer = New-Object byte[] $Bytes
        $Rng.NextBytes($Buffer)
        return [BitConverter]::ToString($Buffer).Replace('-', '')
    }

    function Get-TestGuid([Random]$Rng)
    {
        $Buffer = New-Object byte[] 16
        $Rng.NextBytes($Buffer)
        return (New-Object guid (, $Buffer)).ToString()
    }

    function New-TestAppsJson([int]$Count, [int]$Seed)
    {
        $Rng = New-Object Random $Seed
        $Text = New-Object Text.StringBuilder
        [void]$Text.Append('[')
        for ($i = 0; $i -lt $Count; $i++)
        {
            if ($i -gt 0) { [void]$Text.Append(',') }
            $Guid = Get-TestGuid $Rng
            [void]$Text.AppendFormat('{{"AppName":"Generated App {0} {1}","AppVersion":"{2}.{3}.{4}","AppPublisher":"Vendor {5}","AppInstallDate":"2026-0{6}-1{7}","ProductID":"{{{8}}}","AppUninstallString":"MsiExec.exe /X{{{8}}}","AppType":"Win32","AppLastUsedDate":"2026-10-1{7}T08:00:00.0000000Z","AppUsageStatus":"Used","AppNotes":"{9}"}}',
                $i, (Get-TestHex $Rng 4), $Rng.Next(1, 30), $Rng.Next(0, 10), $Rng.Next(0, 9999), $Rng.Next(1, 400), $Rng.Next(1, 9), $Rng.Next(0, 9), $Guid, (Get-TestHex $Rng 100))
        }
        [void]$Text.Append(']')
        return $Text.ToString()
    }

    function New-TestExesJson([int]$Count, [int]$Seed)
    {
        $Rng = New-Object Random $Seed
        $Text = New-Object Text.StringBuilder
        [void]$Text.Append('[')
        for ($i = 0; $i -lt $Count; $i++)
        {
            if ($i -gt 0) { [void]$Text.Append(',') }
            $Hex = Get-TestHex $Rng 4
            [void]$Text.AppendFormat('{{"ExeInfo":"!!gen{0}-{1}.exe!2026/01/01:10:00:00!{2}!","ExeName":"gen{0}-{1}.exe","RunPath":"C:\\Users\\user{3}\\AppData\\Local\\{1}\\gen{0}-{1}.exe","FileCompanyName":"Vendor {3}","FileProductName":"Product {1}","FactsVerified":true,"Role":"App","MatchSection":"None","InFocusSeconds":{4},"UsersWithUse":{5},"Evidence":"{6}"}}',
                $i, $Hex, (Get-TestHex $Rng 3), $Rng.Next(1, 41), $Rng.Next(0, 90000), $Rng.Next(1, 6), (Get-TestHex $Rng 200))
        }
        [void]$Text.Append(']')
        return $Text.ToString()
    }

    function New-TestMain([string]$ComputerName = 'PC-0001', [string]$Mode = 'LogIngestionAPI')
    {
        $Main = [ordered]@{}
        $Main[(Get-AUColumnName 'ComputerName' 's' $Mode)] = $ComputerName
        $Main[(Get-AUColumnName 'ManagedDeviceID' 'g' $Mode)] = '6f2c1d1e-2b3a-4c5d-8e9f-0a1b2c3d4e5f'
        $Main[(Get-AUColumnName 'AppUsageEnabled' 'b' $Mode)] = $true
        $Main[(Get-AUColumnName 'WatchingSince' 't' $Mode)] = '2026-08-01T09:00:00.0000000Z'
        $Main[(Get-AUColumnName 'AppUsageScriptVersion' 's' $Mode)] = '20'
        $Main[(Get-AUColumnName 'MappingsVersion' 's' $Mode)] = '2026.11.1'
        $Main[(Get-AUColumnName 'CustomerMappingsHash' 's' $Mode)] = ''
        $Main[(Get-AUColumnName 'UnmatchedExeCount' 'd' $Mode)] = 12
        $Main[(Get-AUColumnName 'ProfilesFound' 'd' $Mode)] = 3
        $Main[(Get-AUColumnName 'ProfilesRead' 'd' $Mode)] = 3
        $Main[(Get-AUColumnName 'AppUsageCollectionStatus' 's' $Mode)] = 'OK'
        return $Main
    }

    # Decodes pieces as Power BI does: Base64, then GUnzip, then UTF-8.
    function Expand-TestPieces([string[]]$Pieces)
    {
        $Bytes = [Convert]::FromBase64String(-join $Pieces)
        $Gzip = New-Object IO.Compression.GZipStream((New-Object IO.MemoryStream(, $Bytes)), [IO.Compression.CompressionMode]::Decompress)
        $Reader = New-Object IO.StreamReader($Gzip, (New-Object Text.UTF8Encoding $false))
        try { return $Reader.ReadToEnd() } finally { $Reader.Dispose() }
    }

    # The rows as the service receives them: each body parsed back from its JSON.
    function ConvertFrom-TestBody([byte[]]$Body, [string]$Mode = 'LogIngestionAPI')
    {
        $Parsed = ConvertFrom-Json -InputObject ([Text.Encoding]::UTF8.GetString($Body))
        if ($Mode -eq 'LogIngestionAPI') { return @($Parsed)[0] }
        return $Parsed
    }

    # The D44 reassembly rule: pieces from every row, ordered by RowIndex_d, then column number.
    function Join-TestBlob([object[]]$Rows, [string]$Blob, [string]$Mode = 'LogIngestionAPI')
    {
        $Suffix = if ($Mode -eq 'LogIngestionAPI') { '_s' } else { '' }
        $IndexColumn = Get-AUColumnName 'RowIndex' 'd' $Mode
        $Pieces = New-Object Collections.Generic.List[string]
        foreach ($Row in @($Rows | Sort-Object { [int]$_.$IndexColumn }))
        {
            $Names = @($Row.PSObject.Properties.Name | Where-Object { $_ -match "^$Blob(\d+)$Suffix$" } | Sort-Object { [int]($_ -replace "^$Blob(\d+)$Suffix$", '$1') })
            foreach ($Name in $Names) { $Pieces.Add($Row.$Name) }
        }
        if ($Pieces.Count -eq 0) { return $null }
        return (Expand-TestPieces $Pieces.ToArray())
    }

    function Get-TestPieceNumbers($Row, [string]$Blob)
    {
        return @($Row.PSObject.Properties.Name | Where-Object { $_ -match "^$Blob(\d+)_s$" } | ForEach-Object { [int]($_ -replace "^$Blob(\d+)_s$", '$1') } | Sort-Object)
    }

    # A sender that records every body and fails the calls whose number is in $Fail (1-based), or every call.
    function New-TestSender([int[]]$Fail = @(), [switch]$AlwaysFail)
    {
        $State = [pscustomobject]@{ Bodies = (New-Object Collections.Generic.List[byte[]]); Calls = 0; Fail = $Fail; AlwaysFail = [bool]$AlwaysFail }
        $Block = {
            param([byte[]]$Body, [string]$LogAPIMode, [string]$LogType)
            $State.Calls++
            $State.Bodies.Add($Body)
            if ($State.AlwaysFail -or $State.Fail -contains $State.Calls) { return $false }
            return $true
        }.GetNewClosure()
        return [pscustomobject]@{ State = $State; Block = $Block }
    }

    function Get-TestOutboxNames([string]$Dir)
    {
        if (-not (Test-Path -LiteralPath $Dir)) { return @() }
        return @(Get-ChildItem -LiteralPath $Dir -File | Where-Object { $_.Name -like '*.json' } | ForEach-Object Name | Sort-Object)
    }

    function Get-TestRunBodies([object[]]$Rows)
    {
        return @($Rows | ForEach-Object { , (ConvertTo-AURowBody -Row $_ -LogAPIMode 'LogIngestionAPI') })
    }

    function Test-TestBytesEqual([byte[]]$A, [byte[]]$B)
    {
        if ($A.Length -ne $B.Length) { return $false }
        for ($i = 0; $i -lt $A.Length; $i++) { if ($A[$i] -ne $B[$i]) { return $false } }
        return $true
    }

    $script:Normal = @{ Apps = (New-TestAppsJson 120 1); Exes = (New-TestExesJson 300 2) }
    $script:Mixed = @{ Apps = (New-TestAppsJson 600 3); Exes = (New-TestExesJson 3000 4) }
    $script:ManyApps = @{ Apps = (New-TestAppsJson 4000 5); Exes = (New-TestExesJson 40 6) }
    $script:RunA = '11111111-1111-4111-8111-111111111111'
}

Describe 'Row-size limit (F48)' {
    It 'is the inventory guard, 0.9 MB rounded down' {
        $script:AUMaxRowBytes | Should -Be 943718
        $script:AUMaxRowBytes | Should -Be ([int][Math]::Floor(0.9 * 1024 * 1024))
    }

    Context 'Send-LogIngestionAPI' {
        BeforeAll {
            $Text = [IO.File]::ReadAllText((Resolve-Path (Join-Path $PSScriptRoot '..\..\Intune_Windows_Inventory.ps1')).Path, [Text.Encoding]::UTF8)
            $Ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
            $script:SendFunction = $Ast.Find({ param($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'Send-LogIngestionAPI' }, $true)
            . ([scriptblock]::Create($script:SendFunction.Extent.Text))
            function New-BearerToken { 'token' }
            function Invoke-LogSubmission { [pscustomobject]@{ StatusCode = 204 } }
            $BrokerUrl = $null
            $ManagedDeviceID = $null
        }

        It 'checks the body against $script:AUMaxRowBytes, or 943718 when it is not defined' {
            $script:SendFunction.Extent.Text | Should -Match ([regex]::Escape('$maxBodyBytes = $script:AUMaxRowBytes'))
            $script:SendFunction.Extent.Text | Should -Match ([regex]::Escape('$maxBodyBytes = 943718'))
            $script:SendFunction.Extent.Text | Should -Match ([regex]::Escape('if ($body.Length -gt $maxBodyBytes)'))
            $script:SendFunction.Extent.Text | Should -Not -Match ([regex]::Escape('0.9 * 1024 * 1024'))
        }

        It 'keeps the same limit when $script:AUMaxRowBytes is not defined' {
            $Saved = $script:AUMaxRowBytes
            try
            {
                Remove-Variable -Name AUMaxRowBytes -Scope Script
                foreach ($Length in 943718, 943719)
                {
                    $Threw = $false
                    try { [void](Send-LogIngestionAPI -tenantId 't' -clientId 'c' -clientSecret 's' -body (New-Object byte[] $Length) -dceURI 'https://dce' -dcrImmutableId 'dcr-1' -logType 'PowerStacksAppInventory_CL') }
                    catch { $Threw = $true; $_.Exception.Message | Should -Match 'Upload payload is too big' }
                    $Threw | Should -Be ($Length -gt 943718) -Because "a body of $Length bytes"
                }
            }
            finally { $script:AUMaxRowBytes = $Saved }
        }

        It 'accepts a body of exactly the limit and refuses one byte more, as version 19 did' {
            foreach ($Length in 943716, 943717, 943718, 943719, 943720)
            {
                $V19Throws = ($Length -gt (0.9 * 1024 * 1024))
                $Body = New-Object byte[] $Length
                $Threw = $false
                try { [void](Send-LogIngestionAPI -tenantId 't' -clientId 'c' -clientSecret 's' -body $Body -dceURI 'https://dce' -dcrImmutableId 'dcr-1' -logType 'PowerStacksAppInventory_CL') }
                catch { $Threw = $true; $_.Exception.Message | Should -Match 'Upload payload is too big' }
                $Threw | Should -Be $V19Throws -Because "a body of $Length bytes"
            }
        }
    }
}

Describe 'Get-AUOutboxPath (F44, F50)' {
    It 'puts the outbox next to the ledger, with the sanitized serial' {
        Get-AUOutboxPath -Serial 'AB/12:34' -ComputerName 'PC1' -Root 'C:\Windows' | Should -BeExactly 'C:\Windows\AppUsage_AB_12_34_outbox'
        Get-AUOutboxPath -Serial 'SN123' -ComputerName 'PC1' | Should -BeExactly ([IO.Path]::Combine($env:SystemRoot, 'AppUsage_SN123_outbox'))
    }

    It 'falls back to the computer name for a blank serial' {
        Get-AUOutboxPath -Serial '' -ComputerName 'PC1' -Root 'C:\Windows' | Should -BeExactly 'C:\Windows\AppUsage_PC1_outbox'
        Get-AUOutboxPath -Serial '   ' -ComputerName 'PC1' -Root 'C:\Windows' | Should -BeExactly 'C:\Windows\AppUsage_PC1_outbox'
    }
}

Describe 'New-AURunRows (D44)' {
    It 'sends a normal-sized device as one row, 1 of 1, with both blobs complete' {
        $Rows = New-AURunRows -MainColumns (New-TestMain) -InstalledAppsJson $script:Normal.Apps -ExeUsageJson $script:Normal.Exes -LogAPIMode 'LogIngestionAPI' -RunId $script:RunA
        $Rows.GetType() | Should -Be ([object[]])
        $Rows.Count | Should -Be 1
        $Rows[0].RunId_g | Should -BeExactly $script:RunA
        $Rows[0].RowIndex_d | Should -Be 1
        $Rows[0].RowCount_d | Should -Be 1
        $Row = ConvertFrom-TestBody (ConvertTo-AURowBody -Row $Rows[0] -LogAPIMode 'LogIngestionAPI')
        Join-TestBlob @($Row) 'InstalledApps' | Should -BeExactly $script:Normal.Apps
        Join-TestBlob @($Row) 'ExeUsage' | Should -BeExactly $script:Normal.Exes
        $Names = @($Rows[0].PSObject.Properties.Name)
        $Main = New-TestMain
        $Names[0..($Main.Count - 1)] | Should -Be @($Main.Keys)
        $Names[$Main.Count..($Main.Count + 2)] | Should -Be @('RunId_g', 'RowIndex_d', 'RowCount_d')
    }

    It 'splits the large devices into rows within the limits, tied by RunId_g' {
        foreach ($Device in $script:Mixed, $script:ManyApps)
        {
            $Rows = New-AURunRows -MainColumns (New-TestMain) -InstalledAppsJson $Device.Apps -ExeUsageJson $Device.Exes -LogAPIMode 'LogIngestionAPI' -RunId $script:RunA
            $Rows.Count | Should -BeGreaterThan 1
            $Main = New-TestMain
            for ($i = 0; $i -lt $Rows.Count; $i++)
            {
                # The body exactly as the upload serializes it, measured independently.
                $Bytes = [Text.Encoding]::UTF8.GetByteCount('[' + ($Rows[$i] | ConvertTo-Json -Compress) + ']')
                $Bytes | Should -BeLessOrEqual $script:AUMaxRowBytes
                (ConvertTo-AURowBody -Row $Rows[$i] -LogAPIMode 'LogIngestionAPI').Length | Should -Be $Bytes
                foreach ($Property in $Rows[$i].PSObject.Properties) { "$($Property.Value)".Length | Should -BeLessOrEqual 64512 }
                $Rows[$i].RunId_g | Should -BeExactly $script:RunA
                $Rows[$i].RowIndex_d | Should -Be ($i + 1)
                $Rows[$i].RowCount_d | Should -Be $Rows.Count
                $Names = @($Rows[$i].PSObject.Properties.Name)
                if ($i -eq 0) { foreach ($Key in $Main.Keys) { $Names | Should -Contain $Key } }
                else
                {
                    $Names[0..4] | Should -Be @('ComputerName_s', 'ManagedDeviceID_g', 'RunId_g', 'RowIndex_d', 'RowCount_d')
                    @($Names | Select-Object -Skip 5 | Where-Object { $_ -notmatch '^(InstalledApps|ExeUsage)\d+_s$' }) | Should -BeNullOrEmpty
                    $Rows[$i].ComputerName_s | Should -BeExactly 'PC-0001'
                }
            }
        }
    }

    It 'needs more than 10 pieces for the 4,000-app InstalledApps alone, and for the 3,000-exe ExeUsage' {
        (ConvertTo-AUChunks -Json $script:ManyApps.Apps -ChunkSize 64512).Count | Should -BeGreaterThan 10
        (ConvertTo-AUChunks -Json $script:Mixed.Exes -ChunkSize 64512).Count | Should -BeGreaterThan 10
    }

    It 'never numbers a piece above 10, and starts every row at 1 (F49)' {
        foreach ($Device in $script:Normal, $script:Mixed, $script:ManyApps)
        {
            $Rows = New-AURunRows -MainColumns (New-TestMain) -InstalledAppsJson $Device.Apps -ExeUsageJson $Device.Exes -LogAPIMode 'LogIngestionAPI' -RunId $script:RunA
            foreach ($Row in $Rows)
            {
                foreach ($Blob in 'InstalledApps', 'ExeUsage')
                {
                    $Numbers = Get-TestPieceNumbers $Row $Blob
                    if ($Numbers.Count -eq 0) { continue }
                    $Numbers[-1] | Should -BeLessOrEqual 10
                    $Numbers | Should -Be @(1..$Numbers.Count)
                }
            }
        }
    }

    It 'fills InstalledApps first, then ExeUsage' {
        $Rows = New-AURunRows -MainColumns (New-TestMain) -InstalledAppsJson $script:ManyApps.Apps -ExeUsageJson $script:ManyApps.Exes -LogAPIMode 'LogIngestionAPI' -RunId $script:RunA
        $SeenExe = $false
        foreach ($Row in $Rows)
        {
            foreach ($Name in $Row.PSObject.Properties.Name)
            {
                if ($Name -like 'ExeUsage*') { $SeenExe = $true }
                if ($Name -like 'InstalledApps*') { $SeenExe | Should -BeFalse -Because "$Name comes before every ExeUsage piece" }
            }
        }
        $SeenExe | Should -BeTrue
    }

    It 'splits a run of about 950,000 bytes, under 1,000,000, into two rows (F48)' {
        $Rng = New-Object Random 7
        $Apps = '["' + (Get-TestHex $Rng 300000) + '"]'
        $Exes = '["' + (Get-TestHex $Rng 325000) + '"]'
        $AppPieces = ConvertTo-AUChunks -Json $Apps -ChunkSize 64512
        $ExePieces = ConvertTo-AUChunks -Json $Exes -ChunkSize 64512
        $AppPieces.Count | Should -BeLessOrEqual 10
        $ExePieces.Count | Should -BeLessOrEqual 10
        # The run as one row, the way it would be sent with no size limit.
        $One = New-TestMain
        $One['RunId_g'] = $script:RunA; $One['RowIndex_d'] = 1; $One['RowCount_d'] = 1
        for ($i = 0; $i -lt $AppPieces.Count; $i++) { $One["InstalledApps$($i + 1)_s"] = $AppPieces[$i] }
        for ($i = 0; $i -lt $ExePieces.Count; $i++) { $One["ExeUsage$($i + 1)_s"] = $ExePieces[$i] }
        $OneBytes = (ConvertTo-AURowBody -Row $One -LogAPIMode 'LogIngestionAPI').Length
        $OneBytes | Should -BeGreaterThan 940000
        $OneBytes | Should -BeLessThan 960000

        $Rows = New-AURunRows -MainColumns (New-TestMain) -InstalledAppsJson $Apps -ExeUsageJson $Exes -LogAPIMode 'LogIngestionAPI' -RunId $script:RunA
        $Rows.Count | Should -Be 2
        Join-TestBlob $Rows 'InstalledApps' | Should -BeExactly $Apps
        Join-TestBlob $Rows 'ExeUsage' | Should -BeExactly $Exes
    }

    It 'grows RowCount_d past one digit without passing the limit' {
        $Rng = New-Object Random 8
        $Apps = '["' + (Get-TestHex $Rng 400000) + '"]'
        $Rows = New-AURunRows -MainColumns (New-TestMain) -InstalledAppsJson $Apps -ExeUsageJson '' -LogAPIMode 'LogIngestionAPI' -MaxRowBytes 70000 -RunId $script:RunA
        $Rows.Count | Should -BeGreaterThan 9
        foreach ($Row in $Rows)
        {
            $Row.RowCount_d | Should -Be $Rows.Count
            (ConvertTo-AURowBody -Row $Row -LogAPIMode 'LogIngestionAPI').Length | Should -BeLessOrEqual 70000
        }
        Join-TestBlob $Rows 'InstalledApps' | Should -BeExactly $Apps
    }

    It 'handles empty blobs: no pieces for an empty list, one for []' {
        $Rows = New-AURunRows -MainColumns (New-TestMain) -InstalledAppsJson '' -ExeUsageJson $null -LogAPIMode 'LogIngestionAPI' -RunId $script:RunA
        $Rows.Count | Should -Be 1
        @($Rows[0].PSObject.Properties.Name | Where-Object { $_ -match '^(InstalledApps|ExeUsage)\d' }) | Should -BeNullOrEmpty
        $Rows[0].RowCount_d | Should -Be 1

        $Rows = New-AURunRows -MainColumns (New-TestMain) -InstalledAppsJson '[]' -ExeUsageJson '' -LogAPIMode 'LogIngestionAPI' -RunId $script:RunA
        @($Rows[0].PSObject.Properties.Name | Where-Object { $_ -match '^(InstalledApps|ExeUsage)\d' }) | Should -Be @('InstalledApps1_s')
        Join-TestBlob $Rows 'InstalledApps' | Should -BeExactly '[]'
    }

    It 'gives byte-identical rows for the same input, from an ordered dictionary or a PSObject (F54)' {
        $First = Get-TestRunBodies (New-AURunRows -MainColumns (New-TestMain) -InstalledAppsJson $script:Mixed.Apps -ExeUsageJson $script:Mixed.Exes -LogAPIMode 'LogIngestionAPI' -RunId $script:RunA)
        $Second = Get-TestRunBodies (New-AURunRows -MainColumns (New-TestMain) -InstalledAppsJson $script:Mixed.Apps -ExeUsageJson $script:Mixed.Exes -LogAPIMode 'LogIngestionAPI' -RunId $script:RunA)
        # The inventory's $MainApp is built with New-Object PSObject and Add-Member.
        $MainApp = New-Object -TypeName PSObject
        foreach ($Entry in (New-TestMain).GetEnumerator()) { $MainApp | Add-Member -MemberType NoteProperty -Name $Entry.Key -Value $Entry.Value -Force }
        $Third = Get-TestRunBodies (New-AURunRows -MainColumns $MainApp -InstalledAppsJson $script:Mixed.Apps -ExeUsageJson $script:Mixed.Exes -LogAPIMode 'LogIngestionAPI' -RunId $script:RunA)
        $First.Count | Should -BeGreaterThan 1
        $Second.Count | Should -Be $First.Count
        $Third.Count | Should -Be $First.Count
        for ($i = 0; $i -lt $First.Count; $i++)
        {
            Test-TestBytesEqual $First[$i] $Second[$i] | Should -BeTrue
            Test-TestBytesEqual $First[$i] $Third[$i] | Should -BeTrue
        }
    }

    It 'uses the classic names, piece size, and body for the classic API' {
        $Rows = New-AURunRows -MainColumns (New-TestMain -Mode 'ClientSecret') -InstalledAppsJson $script:Mixed.Apps -ExeUsageJson $script:Mixed.Exes -LogAPIMode 'ClientSecret' -RunId $script:RunA
        $Rows.Count | Should -BeGreaterThan 1
        foreach ($Row in $Rows)
        {
            $Body = ConvertTo-AURowBody -Row $Row -LogAPIMode 'ClientSecret'
            $Body.Length | Should -BeLessOrEqual $script:AUMaxRowBytes
            [Text.Encoding]::UTF8.GetString($Body) | Should -BeExactly ($Row | ConvertTo-Json)
            $Row.RunId | Should -BeExactly $script:RunA
            foreach ($Name in $Row.PSObject.Properties.Name) { $Name | Should -Not -Match '_[sgdbt]$' }
            foreach ($Property in $Row.PSObject.Properties) { "$($Property.Value)".Length | Should -BeLessOrEqual 31744 }
        }
        @($Rows[1].PSObject.Properties.Name)[0..4] | Should -Be @('ComputerName', 'ManagedDeviceID', 'RunId', 'RowIndex', 'RowCount')
        $Parsed = @($Rows | ForEach-Object { ConvertFrom-TestBody (ConvertTo-AURowBody -Row $_ -LogAPIMode 'ClientSecret') -Mode 'ClientSecret' })
        Join-TestBlob $Parsed 'InstalledApps' -Mode 'ClientSecret' | Should -BeExactly $script:Mixed.Apps
        Join-TestBlob $Parsed 'ExeUsage' -Mode 'ClientSecret' | Should -BeExactly $script:Mixed.Exes
    }

    It 'refuses input that would break the rows' {
        { New-AURunRows -MainColumns @{ ComputerName_s = 'PC'; ManagedDeviceID_g = 'x' } -LogAPIMode 'LogIngestionAPI' } | Should -Throw '*ordered*'
        { New-AURunRows -MainColumns (New-TestMain) -LogAPIMode 'LogIngestionAPI' -RunId 'not-a-guid' } | Should -Throw '*GUID*'
        $Main = New-TestMain; $Main['RunId_g'] = $script:RunA
        { New-AURunRows -MainColumns $Main -LogAPIMode 'LogIngestionAPI' } | Should -Throw '*RunId_g*'
        $Main = New-TestMain; $Main['InstalledApps1_s'] = 'x'
        { New-AURunRows -MainColumns $Main -LogAPIMode 'LogIngestionAPI' } | Should -Throw '*InstalledApps1_s*'
        $Main = New-TestMain; $Main.Remove('ManagedDeviceID_g')
        { New-AURunRows -MainColumns $Main -LogAPIMode 'LogIngestionAPI' } | Should -Throw '*ManagedDeviceID_g*'
        $Main = New-TestMain; $Main['AppUsageCollectionStatus_s'] = 'x' * 2000
        { New-AURunRows -MainColumns $Main -LogAPIMode 'LogIngestionAPI' -MaxRowBytes 1000 } | Should -Throw '*over the 1000-byte*'
    }

    It 'gives each run its own GUID by default' {
        $A = New-AURunRows -MainColumns (New-TestMain) -LogAPIMode 'LogIngestionAPI'
        $B = New-AURunRows -MainColumns (New-TestMain) -LogAPIMode 'LogIngestionAPI'
        [guid]::Parse($A[0].RunId_g) | Should -Not -Be ([guid]::Parse($B[0].RunId_g))
    }
}

Describe 'Send-AURunRows and Send-AUOutbox (D44, F50 to F53)' {
    BeforeEach {
        $script:Outbox = Join-Path $TestDrive ("AppUsage_SN{0}_outbox" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    }

    It 'sends every row of a run, each in its own call, and makes no outbox' {
        $Rows = New-AURunRows -MainColumns (New-TestMain) -InstalledAppsJson $script:Mixed.Apps -ExeUsageJson $script:Mixed.Exes -LogAPIMode 'LogIngestionAPI' -RunId $script:RunA
        $Sender = New-TestSender
        $Budget = 1
        $Result = Send-AURunRows -Rows $Rows -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Sender.Block
        $Result.Sent | Should -Be $Rows.Count
        $Result.Pending | Should -Be 0
        $Result.SentBytes | Should -Be (($Sender.State.Bodies | Measure-Object -Property Length -Sum).Sum)
        $Sender.State.Calls | Should -Be $Rows.Count
        Test-Path -LiteralPath $script:Outbox | Should -BeFalse
        $Budget | Should -Be 1

        # Reassembled from the bodies actually sent, each blob equals its input.
        $Received = @($Sender.State.Bodies | ForEach-Object { ConvertFrom-TestBody $_ })
        $Received.Count | Should -Be $Rows.Count
        Join-TestBlob $Received 'InstalledApps' | Should -BeExactly $script:Mixed.Apps
        Join-TestBlob $Received 'ExeUsage' | Should -BeExactly $script:Mixed.Exes
        foreach ($Body in $Sender.State.Bodies) { $Body.Length | Should -BeLessOrEqual $script:AUMaxRowBytes }
    }

    It 'reassembles both blobs exactly from the bodies of every generated device' {
        foreach ($Device in $script:Normal, $script:Mixed, $script:ManyApps)
        {
            $Rows = New-AURunRows -MainColumns (New-TestMain) -InstalledAppsJson $Device.Apps -ExeUsageJson $Device.Exes -LogAPIMode 'LogIngestionAPI'
            $Sender = New-TestSender
            $Budget = 1
            [void](Send-AURunRows -Rows $Rows -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Sender.Block)
            # Arrival order isn't guaranteed; shuffle before the RowIndex_d sort.
            $Received = @($Sender.State.Bodies | ForEach-Object { ConvertFrom-TestBody $_ }) | Sort-Object { [guid]::NewGuid() }
            Join-TestBlob @($Received) 'InstalledApps' | Should -BeExactly $Device.Apps
            Join-TestBlob @($Received) 'ExeUsage' | Should -BeExactly $Device.Exes
        }
    }

    It 'saves the failed row and every row after it, sends them first and unchanged next run, and reports PendingRows until the outbox is empty' {
        $Rows = New-AURunRows -MainColumns (New-TestMain) -InstalledAppsJson ('["' + (Get-TestHex (New-Object Random 9) 400000) + '"]') -ExeUsageJson '' -LogAPIMode 'LogIngestionAPI' -MaxRowBytes 200000 -RunId $script:RunA
        $Rows.Count | Should -Be 4
        $Bodies = Get-TestRunBodies $Rows
        $Sender = New-TestSender -Fail 3
        $Budget = 1
        $Result = Send-AURunRows -Rows $Rows -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Sender.Block -MaxRowBytes 200000
        $Sender.State.Calls | Should -Be 3
        $Result.Sent | Should -Be 2
        $Result.Pending | Should -Be 2
        $Result.Saved | Should -Be 2
        $Budget | Should -Be 0
        Get-TestOutboxNames $script:Outbox | Should -Be @("$($script:RunA)-3.json", "$($script:RunA)-4.json")
        Test-TestBytesEqual ([IO.File]::ReadAllBytes((Join-Path $script:Outbox "$($script:RunA)-3.json"))) $Bodies[2] | Should -BeTrue

        # Next run, still failing: PendingRows on its row 1, and its own rows wait too.
        $Sender2 = New-TestSender -AlwaysFail
        $Budget = 1
        $Flush = Send-AUOutbox -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Sender2.Block -MaxRowBytes 200000
        $Flush.PendingRows | Should -BeTrue
        $Flush.Remaining | Should -Be 2
        Test-TestBytesEqual $Sender2.State.Bodies[0] $Bodies[2] | Should -BeTrue

        # The run after: the outbox goes first, unchanged, then the run's own rows.
        $Sender3 = New-TestSender
        $Budget = 1
        $Flush = Send-AUOutbox -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Sender3.Block -MaxRowBytes 200000
        $Flush.Sent | Should -Be 2
        $Flush.Remaining | Should -Be 0
        $Flush.PendingRows | Should -BeFalse
        $Next = New-AURunRows -MainColumns (New-TestMain) -InstalledAppsJson $script:Normal.Apps -ExeUsageJson '' -LogAPIMode 'LogIngestionAPI'
        [void](Send-AURunRows -Rows $Next -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Sender3.Block)
        $Sender3.State.Calls | Should -Be 3
        Test-TestBytesEqual $Sender3.State.Bodies[0] $Bodies[2] | Should -BeTrue
        Test-TestBytesEqual $Sender3.State.Bodies[1] $Bodies[3] | Should -BeTrue
        (ConvertFrom-TestBody $Sender3.State.Bodies[2]).RunId_g | Should -BeExactly $Next[0].RunId_g
        Get-TestOutboxNames $script:Outbox | Should -BeNullOrEmpty
    }

    It 'leaves exactly the failed row when the budget allows another send' {
        $Rows = New-AURunRows -MainColumns (New-TestMain) -InstalledAppsJson ('["' + (Get-TestHex (New-Object Random 9) 400000) + '"]') -ExeUsageJson '' -LogAPIMode 'LogIngestionAPI' -MaxRowBytes 200000 -RunId $script:RunA
        $Sender = New-TestSender -Fail 3
        $Budget = 2
        $Result = Send-AURunRows -Rows $Rows -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Sender.Block -MaxRowBytes 200000
        $Sender.State.Calls | Should -Be 4
        $Result.Sent | Should -Be 3
        Get-TestOutboxNames $script:Outbox | Should -Be @("$($script:RunA)-3.json")
    }

    It 'sends the older run first, then the newer, then the current run (F53)' {
        $Old = '22222222-2222-4222-8222-222222222222'
        $Newer = '33333333-3333-4333-8333-333333333333'
        $Failing = New-TestSender -AlwaysFail
        # The newer run is saved first, so only the write times order them, not the save order or the names.
        foreach ($RunId in $Newer, $Old)
        {
            $Rows = New-AURunRows -MainColumns (New-TestMain) -InstalledAppsJson ('["' + (Get-TestHex (New-Object Random 10) 150000) + '"]') -ExeUsageJson '' -LogAPIMode 'LogIngestionAPI' -MaxRowBytes 200000 -RunId $RunId
            $Rows.Count | Should -Be 2
            $Budget = 1
            [void](Send-AURunRows -Rows $Rows -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Failing.Block -MaxRowBytes 200000)
        }
        foreach ($Name in Get-TestOutboxNames $script:Outbox)
        {
            $Time = if ($Name -like "$Old*") { [datetime]'2026-11-01T00:00:00Z' } else { [datetime]'2026-11-02T00:00:00Z' }
            [IO.File]::SetLastWriteTimeUtc((Join-Path $script:Outbox $Name), $Time.ToUniversalTime())
        }

        $Sender = New-TestSender
        $Budget = 1
        $Flush = Send-AUOutbox -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Sender.Block -MaxRowBytes 200000
        $Flush.Sent | Should -Be 4
        $Current = New-AURunRows -MainColumns (New-TestMain) -InstalledAppsJson $script:Normal.Apps -ExeUsageJson '' -LogAPIMode 'LogIngestionAPI' -RunId $script:RunA
        [void](Send-AURunRows -Rows $Current -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Sender.Block)
        $Order = @($Sender.State.Bodies | ForEach-Object { $Row = ConvertFrom-TestBody $_; "$($Row.RunId_g)/$($Row.RowIndex_d)" })
        $Order | Should -Be @("$Old/1", "$Old/2", "$Newer/1", "$Newer/2", "$($script:RunA)/1")
    }

    It 'spends one retry cycle in total when every send fails (F51)' {
        $Failing = New-TestSender -AlwaysFail
        $Old = '44444444-4444-4444-8444-444444444444'
        $Rows = New-AURunRows -MainColumns (New-TestMain) -InstalledAppsJson ('["' + (Get-TestHex (New-Object Random 11) 150000) + '"]') -ExeUsageJson '' -LogAPIMode 'LogIngestionAPI' -MaxRowBytes 200000 -RunId $Old
        $Budget = 1
        [void](Send-AURunRows -Rows $Rows -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Failing.Block -MaxRowBytes 200000)
        # The test sets up the outbox with no send at all.
        @(Get-TestOutboxNames $script:Outbox).Count | Should -Be 2

        $Sender = New-TestSender -AlwaysFail
        $Budget = 1
        $Flush = Send-AUOutbox -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Sender.Block -MaxRowBytes 200000
        $Current = New-AURunRows -MainColumns (New-TestMain) -InstalledAppsJson ('["' + (Get-TestHex (New-Object Random 12) 400000) + '"]') -ExeUsageJson '' -LogAPIMode 'LogIngestionAPI' -MaxRowBytes 200000 -RunId $script:RunA
        $Current.Count | Should -Be 4
        $Result = Send-AURunRows -Rows $Current -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Sender.Block -MaxRowBytes 200000
        $Sender.State.Calls | Should -Be 1
        $Flush.PendingRows | Should -BeTrue
        $Result.Sent | Should -Be 0
        $Result.Saved | Should -Be 4
        @(Get-TestOutboxNames $script:Outbox).Count | Should -Be 6
    }

    It 'counts a sender that throws as a failed send' {
        $Rows = New-AURunRows -MainColumns (New-TestMain) -InstalledAppsJson $script:Normal.Apps -ExeUsageJson '' -LogAPIMode 'LogIngestionAPI' -RunId $script:RunA
        $Budget = 1
        $Result = Send-AURunRows -Rows $Rows -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender { throw 'Upload payload is too big' }
        $Result.Sent | Should -Be 0
        $Result.Saved | Should -Be 1
        $Budget | Should -Be 0
    }

    It 'deletes older runs once a newer run is sent in full (D44)' {
        $Failing = New-TestSender -AlwaysFail
        foreach ($RunId in '55555555-5555-4555-8555-555555555555', '66666666-6666-4666-8666-666666666666')
        {
            $Rows = New-AURunRows -MainColumns (New-TestMain) -InstalledAppsJson $script:Normal.Apps -ExeUsageJson '' -LogAPIMode 'LogIngestionAPI' -RunId $RunId
            $Budget = 1
            [void](Send-AURunRows -Rows $Rows -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Failing.Block)
        }
        @(Get-TestOutboxNames $script:Outbox).Count | Should -Be 2

        $Sender = New-TestSender
        $Budget = 1
        $Rows = New-AURunRows -MainColumns (New-TestMain) -InstalledAppsJson $script:Mixed.Apps -ExeUsageJson $script:Mixed.Exes -LogAPIMode 'LogIngestionAPI' -RunId $script:RunA
        $Result = Send-AURunRows -Rows $Rows -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Sender.Block
        $Result.Pending | Should -Be 0
        Get-TestOutboxNames $script:Outbox | Should -BeNullOrEmpty
    }

    It 'keeps older runs when the newer run is only partly sent' {
        $Failing = New-TestSender -AlwaysFail
        $Old = '77777777-7777-4777-8777-777777777777'
        $Budget = 1
        [void](Send-AURunRows -Rows (New-AURunRows -MainColumns (New-TestMain) -InstalledAppsJson $script:Normal.Apps -ExeUsageJson '' -LogAPIMode 'LogIngestionAPI' -RunId $Old) -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Failing.Block)
        $Rows = New-AURunRows -MainColumns (New-TestMain) -InstalledAppsJson $script:Mixed.Apps -ExeUsageJson $script:Mixed.Exes -LogAPIMode 'LogIngestionAPI' -RunId $script:RunA
        $Sender = New-TestSender -Fail 2
        $Budget = 1
        [void](Send-AURunRows -Rows $Rows -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Sender.Block)
        Get-TestOutboxNames $script:Outbox | Should -Contain "$Old-1.json"
    }

    It 'gives no PendingRows when the outbox empties during the flush (F52)' {
        $Failing = New-TestSender -AlwaysFail
        $Budget = 1
        [void](Send-AURunRows -Rows (New-AURunRows -MainColumns (New-TestMain) -InstalledAppsJson $script:Normal.Apps -ExeUsageJson '' -LogAPIMode 'LogIngestionAPI' -RunId $script:RunA) -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Failing.Block)
        $Sender = New-TestSender
        $Budget = 1
        $Flush = Send-AUOutbox -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Sender.Block
        $Flush.Sent | Should -Be 1
        $Flush.Remaining | Should -Be 0
        $Flush.PendingRows | Should -BeFalse
        $Flush.OutboxSkipped | Should -BeFalse

        $Budget = 1
        $Flush = Send-AUOutbox -OutboxDir (Join-Path $TestDrive 'no-such-outbox') -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Sender.Block
        $Flush.PendingRows | Should -BeFalse
        $Flush.OutboxSkipped | Should -BeFalse
    }

    It 'never holds more than 5 runs' {
        $Failing = New-TestSender -AlwaysFail
        $RunIds = @(1..7 | ForEach-Object { '{0:D8}-0000-4000-8000-000000000000' -f $_ })
        $Day = 0
        foreach ($RunId in $RunIds)
        {
            $Rows = New-AURunRows -MainColumns (New-TestMain) -InstalledAppsJson ('["' + (Get-TestHex (New-Object Random 13) 150000) + '"]') -ExeUsageJson '' -LogAPIMode 'LogIngestionAPI' -MaxRowBytes 200000 -RunId $RunId
            $Budget = 1
            [void](Send-AURunRows -Rows $Rows -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Failing.Block -MaxRowBytes 200000)
            $Day++
            foreach ($Name in Get-TestOutboxNames $script:Outbox | Where-Object { $_ -like "$RunId*" }) { [IO.File]::SetLastWriteTimeUtc((Join-Path $script:Outbox $Name), ([datetime]'2026-11-01').AddDays($Day)) }
            $Runs = @(Get-TestOutboxNames $script:Outbox | ForEach-Object { $_.Substring(0, 36) } | Sort-Object -Unique)
            $Runs.Count | Should -BeLessOrEqual 5
        }
        @(Get-TestOutboxNames $script:Outbox | ForEach-Object { $_.Substring(0, 36) } | Sort-Object -Unique) | Should -Be @($RunIds[2..6])
    }

    It 'creates the outbox with the protected DACL, and its files are owned by Administrators' {
        $Failing = New-TestSender -AlwaysFail
        $Budget = 1
        [void](Send-AURunRows -Rows (New-AURunRows -MainColumns (New-TestMain) -LogAPIMode 'LogIngestionAPI' -RunId $script:RunA) -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Failing.Block)
        Test-AUTrustedFolder -Path $script:Outbox | Should -BeTrue
        $Acl = [IO.Directory]::GetAccessControl($script:Outbox)
        $Acl.AreAccessRulesProtected | Should -BeTrue
        @($Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique) | Should -Be @('S-1-5-18', 'S-1-5-32-544')
        $File = Join-Path $script:Outbox "$($script:RunA)-1.json"
        $FileAcl = [IO.File]::GetAccessControl($File)
        $FileAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value | Should -Be 'S-1-5-32-544'
        $FileAcl.AreAccessRulesProtected | Should -BeTrue
        @($FileAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique) | Should -Be @('S-1-5-18', 'S-1-5-32-544')
        @(Get-ChildItem -LiteralPath $script:Outbox -Filter '*.tmp') | Should -BeNullOrEmpty
    }

    Context 'an outbox that is not trusted' {
        BeforeEach {
            # Planted with the right file names, but in a folder that inherits the test drive's DACL.
            New-Item -ItemType Directory -Path $script:Outbox | Out-Null
            $script:Planted = Join-Path $script:Outbox "$($script:RunA)-1.json"
            $Body = ConvertTo-AURowBody -Row (New-AURunRows -MainColumns (New-TestMain) -LogAPIMode 'LogIngestionAPI' -RunId $script:RunA)[0] -LogAPIMode 'LogIngestionAPI'
            [IO.File]::WriteAllBytes($script:Planted, $Body)
        }

        It 'is never read, sent, or deleted from' {
            $Sender = New-TestSender
            $Budget = 1
            $Flush = Send-AUOutbox -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Sender.Block
            $Flush.OutboxSkipped | Should -BeTrue
            $Flush.Sent | Should -Be 0
            $Sender.State.Calls | Should -Be 0

            # A newer run sent in full doesn't delete from it either.
            $Rows = New-AURunRows -MainColumns (New-TestMain) -LogAPIMode 'LogIngestionAPI'
            [void](Send-AURunRows -Rows $Rows -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Sender.Block)
            Test-Path -LiteralPath $script:Planted | Should -BeTrue
        }

        It 'is never written to' {
            $Failing = New-TestSender -AlwaysFail
            $Budget = 1
            $Rows = New-AURunRows -MainColumns (New-TestMain) -LogAPIMode 'LogIngestionAPI'
            $Result = Send-AURunRows -Rows $Rows -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Failing.Block
            $Result.OutboxSkipped | Should -BeTrue
            $Result.Saved | Should -Be 0
            $Result.Pending | Should -Be 1
            Get-TestOutboxNames $script:Outbox | Should -Be @("$($script:RunA)-1.json")
        }
    }

    It 'treats a junction at the outbox path as untrusted' {
        $Target = Join-Path $TestDrive ('target-' + [guid]::NewGuid().ToString('N'))
        New-AUProtectedFolder -Path $Target
        $Budget = 1
        $Failing = New-TestSender -AlwaysFail
        [void](Send-AURunRows -Rows (New-AURunRows -MainColumns (New-TestMain) -LogAPIMode 'LogIngestionAPI' -RunId $script:RunA) -OutboxDir $Target -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Failing.Block)
        $Out = & cmd.exe /c mklink /J "$script:Outbox" "$Target" 2>&1
        $LASTEXITCODE | Should -Be 0 -Because "$Out"
        Get-AUOutboxState -OutboxDir $script:Outbox | Should -Be 'Untrusted'
        $Sender = New-TestSender
        $Budget = 1
        $Flush = Send-AUOutbox -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Sender.Block
        $Flush.OutboxSkipped | Should -BeTrue
        $Sender.State.Calls | Should -Be 0
        Get-TestOutboxNames $Target | Should -Be @("$($script:RunA)-1.json")
    }

    Context 'files in a trusted outbox' {
        BeforeEach {
            $Failing = New-TestSender -AlwaysFail
            $Budget = 1
            [void](Send-AURunRows -Rows (New-AURunRows -MainColumns (New-TestMain) -LogAPIMode 'LogIngestionAPI' -RunId $script:RunA) -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Failing.Block)
            $script:Saved = Join-Path $script:Outbox "$($script:RunA)-1.json"
        }

        It 'never sends or deletes a file that SYSTEM or Administrators does not own' {
            $Acl = [IO.File]::GetAccessControl($script:Saved)
            $Acl.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User)
            [IO.File]::SetAccessControl($script:Saved, $Acl)
            $Sender = New-TestSender
            $Budget = 1
            $Flush = Send-AUOutbox -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Sender.Block
            $Sender.State.Calls | Should -Be 0
            $Flush.Remaining | Should -Be 0
            Test-Path -LiteralPath $script:Saved | Should -BeTrue
        }

        It 'never follows a link in the outbox' {
            $Elsewhere = Join-Path $TestDrive ('elsewhere-' + [guid]::NewGuid().ToString('N') + '.json')
            Copy-Item -LiteralPath $script:Saved -Destination $Elsewhere
            Remove-Item -LiteralPath $script:Saved
            $Link = Join-Path $script:Outbox "$($script:RunA)-2.json"
            $Out = & cmd.exe /c mklink "$Link" "$Elsewhere" 2>&1
            if ($LASTEXITCODE -ne 0) { Set-ItResult -Skipped -Because "a file symbolic link needs elevation or Developer Mode: $Out"; return }
            $Sender = New-TestSender
            $Budget = 1
            [void](Send-AUOutbox -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Sender.Block)
            $Sender.State.Calls | Should -Be 0
            Test-Path -LiteralPath $Link | Should -BeTrue
            Test-Path -LiteralPath $Elsewhere | Should -BeTrue
        }

        It 'deletes a saved row that is not valid, unsent' {
            [IO.File]::WriteAllText($script:Saved, '[{"RunId_g":"truncated')
            $Sender = New-TestSender
            $Budget = 1
            $Flush = Send-AUOutbox -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Sender.Block
            $Sender.State.Calls | Should -Be 0
            $Flush.Remaining | Should -Be 0
            $Budget | Should -Be 1
            Test-Path -LiteralPath $script:Saved | Should -BeFalse
        }

        It 'deletes a saved row whose run columns do not match its name, or that the other API mode wrote' {
            # Saved by the script under another run's name, so it's trusted but its columns don't match.
            Save-AUOutboxRow -OutboxDir $script:Outbox -RunId '88888888-8888-4888-8888-888888888888' -RowIndex 1 -Body ([IO.File]::ReadAllBytes($script:Saved)) | Should -BeTrue
            $Sender = New-TestSender
            $Budget = 1
            $Flush = Send-AUOutbox -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'ClientSecret' -Sender $Sender.Block
            $Sender.State.Calls | Should -Be 0
            Get-TestOutboxNames $script:Outbox | Should -BeNullOrEmpty
        }
    }

    It 'returns only its result, so nothing reaches the console (D40)' {
        $Rows = New-AURunRows -MainColumns (New-TestMain) -InstalledAppsJson $script:Mixed.Apps -ExeUsageJson $script:Mixed.Exes -LogAPIMode 'LogIngestionAPI' -MaxRowBytes 200000 -RunId $script:RunA
        @(New-AURunRows -MainColumns (New-TestMain) -LogAPIMode 'LogIngestionAPI').Count | Should -Be 1
        $Failing = New-TestSender -AlwaysFail
        $Budget = 1
        $Output = @(Send-AURunRows -Rows $Rows -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Failing.Block -MaxRowBytes 200000 -MaxRuns 1)
        $Output.Count | Should -Be 1
        $Output[0].Saved | Should -Be $Rows.Count
        $Budget = 1
        $Output = @(Send-AUOutbox -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender (New-TestSender).Block -MaxRowBytes 200000)
        $Output.Count | Should -Be 1
        $Output[0].Sent | Should -Be $Rows.Count
    }

    It 'refuses rows wrapped in another array' {
        $Rows = New-AURunRows -MainColumns (New-TestMain) -LogAPIMode 'LogIngestionAPI'
        $Budget = 1
        { Send-AURunRows -Rows @(, $Rows) -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender { $true } } | Should -Throw '*RunId_g*'
    }
    It 'needs a sender, and has no default that reads the connection settings' {
        $Rows = New-AURunRows -MainColumns (New-TestMain) -LogAPIMode 'LogIngestionAPI'
        $Budget = 1
        { Send-AURunRows -Rows $Rows -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' } | Should -Throw '*-Sender*'
        { Send-AUOutbox -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' } | Should -Throw '*-Sender*'
        foreach ($Name in 'Send-AUOutbox', 'Send-AURunRows')
        {
            $Parameter = (Get-Command $Name).Parameters['Sender']
            $Parameter.ParameterType | Should -Be ([scriptblock])
            (Get-Command $Name).ScriptBlock.Ast.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Sender' } | ForEach-Object { $_.DefaultValue | Should -BeNullOrEmpty }
        }
        $Region = [regex]::Match([IO.File]::ReadAllText((Resolve-Path (Join-Path $PSScriptRoot '..\..\Intune_Windows_Inventory.ps1')).Path), '(?ms)^#region APPUSAGE\r?\n(.*?)^#endregion APPUSAGE').Groups[1].Value
        $Region | Should -Not -Match '\$(TenantId|ClientId|ClientSecret|DceURI|DcrImmutableId|customerId|sharedKey)\b'
    }

    Context 'leftover temp files' {
        BeforeEach {
            # A trusted outbox with one saved row, as Save-AUOutboxRow leaves it.
            $Failing = New-TestSender -AlwaysFail
            $Budget = 1
            [void](Send-AURunRows -Rows (New-AURunRows -MainColumns (New-TestMain) -LogAPIMode 'LogIngestionAPI' -RunId $script:RunA) -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Failing.Block)
            Test-AUTrustedFolder -Path $script:Outbox | Should -BeTrue

            # A temp file created the way Save-AUOutboxRow creates one: protected DACL, owned by Administrators.
            function New-TestTemp([string]$Name, [datetime]$WriteTimeUtc)
            {
                $Path = Join-Path $script:Outbox $Name
                $Security = New-AUProtectedSecurity
                $Security.SetOwner((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'))
                $Stream = New-Object IO.FileStream($Path, [IO.FileMode]::CreateNew, [Security.AccessControl.FileSystemRights]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::None, $Security)
                $Stream.Dispose()
                [IO.File]::SetLastWriteTimeUtc($Path, $WriteTimeUtc)
                return $Path
            }
        }

        It 'deletes trusted temp files older than 24 hours when the outbox is sent, and keeps newer ones' {
            $Old = New-TestTemp "$($script:RunA)-2.json.tmp" ([datetime]::UtcNow.AddHours(-25))
            $Fresh = New-TestTemp "$($script:RunA)-3.json.tmp" ([datetime]::UtcNow.AddHours(-23))
            $Sender = New-TestSender
            $Budget = 1
            $Flush = Send-AUOutbox -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Sender.Block
            Test-Path -LiteralPath $Old | Should -BeFalse
            Test-Path -LiteralPath $Fresh | Should -BeTrue
            $Flush.Sent | Should -Be 1
            $Flush.Remaining | Should -Be 0
        }

        It 'counts what it deletes, and leaves other owners, folders, links, and saved rows alone' {
            $Old = New-TestTemp 'a.json.tmp' ([datetime]::UtcNow.AddHours(-48))
            $Foreign = New-TestTemp 'b.json.tmp' ([datetime]::UtcNow.AddHours(-48))
            $Acl = [IO.File]::GetAccessControl($Foreign)
            $Acl.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User)
            [IO.File]::SetAccessControl($Foreign, $Acl)
            $Folder = Join-Path $script:Outbox 'c.json.tmp'
            [void][IO.Directory]::CreateDirectory($Folder)
            $Target = New-TestTemp 'target.dat' ([datetime]::UtcNow.AddHours(-48))
            $Link = Join-Path $script:Outbox 'd.json.tmp'
            $Out = & cmd.exe /c mklink "$Link" "$Target" 2>&1
            $LinkMade = ($LASTEXITCODE -eq 0)

            # MaxAgeHours 0 makes every entry old enough, the link and folder included.
            Remove-AUStaleOutboxTemp -OutboxDir $script:Outbox -MaxAgeHours 0 | Should -Be 1
            Test-Path -LiteralPath $Old | Should -BeFalse
            Test-Path -LiteralPath $Foreign | Should -BeTrue
            Test-Path -LiteralPath $Folder | Should -BeTrue
            Test-Path -LiteralPath $Target | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $script:Outbox "$($script:RunA)-1.json") | Should -BeTrue
            if ($LinkMade) { Test-Path -LiteralPath $Link | Should -BeTrue }
            else { Set-ItResult -Skipped -Because "a file symbolic link needs elevation or Developer Mode: $Out" }
        }

        It 'never touches temp files in an untrusted outbox' {
            $Untrusted = Join-Path $TestDrive ('untrusted-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $Untrusted | Out-Null
            $Planted = Join-Path $Untrusted 'x.json.tmp'
            [IO.File]::WriteAllText($Planted, 'x')
            [IO.File]::SetLastWriteTimeUtc($Planted, [datetime]::UtcNow.AddDays(-3))
            $Budget = 1
            $Flush = Send-AUOutbox -OutboxDir $Untrusted -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender (New-TestSender).Block
            $Flush.OutboxSkipped | Should -BeTrue
            Test-Path -LiteralPath $Planted | Should -BeTrue
        }
    }
}

Describe 'The sender contract: Ok and Permanent (Task 17 follow-ups)' {
    BeforeAll {
        $script:RunB = '22222222-2222-4222-8222-222222222222'

        # A sender in the inventory's contract: each call's outcome comes from $Outcomes in turn
        # ('Ok', 'Fail', or 'Permanent'), then 'Ok'.
        function New-TestContractSender([string[]]$Outcomes = @())
        {
            $State = [pscustomobject]@{ Bodies = (New-Object Collections.Generic.List[byte[]]); Calls = 0; Outcomes = $Outcomes }
            $Block = {
                param([byte[]]$Body, [string]$LogAPIMode, [string]$LogType)
                $State.Calls++
                $State.Bodies.Add($Body)
                $Outcome = 'Ok'
                if ($State.Calls -le $State.Outcomes.Count) { $Outcome = $State.Outcomes[$State.Calls - 1] }
                [pscustomobject]@{ Ok = ($Outcome -eq 'Ok'); Permanent = ($Outcome -eq 'Permanent') }
            }.GetNewClosure()
            return [pscustomobject]@{ State = $State; Block = $Block }
        }

        # Two runs waiting in the outbox, one row each: RunA first (older), then RunB.
        function Save-TestTwoRuns
        {
            $Failing = New-TestSender -AlwaysFail
            $Budget = 1
            [void](Send-AURunRows -Rows (New-AURunRows -MainColumns (New-TestMain) -LogAPIMode 'LogIngestionAPI' -RunId $script:RunA) -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Failing.Block)
            $First = Join-Path $script:Outbox "$($script:RunA)-1.json"
            [IO.File]::SetLastWriteTimeUtc($First, [datetime]::UtcNow.AddMinutes(-10))
            $Budget = 1
            [void](Send-AURunRows -Rows (New-AURunRows -MainColumns (New-TestMain) -LogAPIMode 'LogIngestionAPI' -RunId $script:RunB) -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Failing.Block)
            return [pscustomobject]@{ First = $First; Second = (Join-Path $script:Outbox "$($script:RunB)-1.json") }
        }
    }

    BeforeEach {
        $script:Outbox = Join-Path $TestDrive ("AppUsage_SN{0}_outbox" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    }

    It 'reads the sender''s last output: <Case>' -ForEach @(
        @{ Case = 'true'; Output = { $true }; Ok = $true; Permanent = $false }
        @{ Case = 'false'; Output = { $false }; Ok = $false; Permanent = $false }
        @{ Case = 'Ok'; Output = { [pscustomobject]@{ Ok = $true; Permanent = $false } }; Ok = $true; Permanent = $false }
        @{ Case = 'transient failure'; Output = { [pscustomobject]@{ Ok = $false; Permanent = $false } }; Ok = $false; Permanent = $false }
        @{ Case = 'permanent rejection'; Output = { 'log line'; [pscustomobject]@{ Ok = $false; Permanent = $true } }; Ok = $false; Permanent = $true }
        @{ Case = 'Ok wins over Permanent'; Output = { [pscustomobject]@{ Ok = $true; Permanent = $true } }; Ok = $true; Permanent = $false }
        @{ Case = 'text'; Output = { '204 : Upload payload size is 1Kb' }; Ok = $false; Permanent = $false }
        @{ Case = 'nothing'; Output = { }; Ok = $false; Permanent = $false }
        @{ Case = 'a throw'; Output = { throw 'token request failed' }; Ok = $false; Permanent = $false }
    ) {
        $Send = Invoke-AUSend -Sender $Output -Body ([byte[]](1, 2)) -LogAPIMode 'LogIngestionAPI' -LogType 'PowerStacksAppInventory_CL'
        $Send.Ok | Should -Be $Ok
        $Send.Permanent | Should -Be $Permanent
    }

    It 'treats only a 4xx other than 408 and 429 as permanent' {
        foreach ($Code in 400, 401, 403, 404, 413, 422) { Test-AUPermanentStatus $Code | Should -BeTrue -Because "$Code" }
        foreach ($Code in 200, 204, 408, 429, 500, 502, 503, $null, '', 'x') { Test-AUPermanentStatus $Code | Should -BeFalse -Because "'$Code'" }
    }

    It 'discards an outbox row the service rejects permanently, without spending the retry budget' {
        $Files = Save-TestTwoRuns
        $Contract = New-TestContractSender @('Permanent')
        $Budget = 1
        $Flush = Send-AUOutbox -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Contract.Block
        $Contract.State.Calls | Should -Be 2
        $Flush.Discarded | Should -Be 1
        $Flush.Sent | Should -Be 1
        $Flush.Remaining | Should -Be 0
        $Flush.PendingRows | Should -BeFalse
        $Budget | Should -Be 1
        Test-Path -LiteralPath $Files.First | Should -BeFalse
        Test-Path -LiteralPath $Files.Second | Should -BeFalse
    }

    It 'still spends the budget, and keeps the row, on a transient failure' {
        $Files = Save-TestTwoRuns
        $Contract = New-TestContractSender @('Fail')
        $Budget = 1
        $Flush = Send-AUOutbox -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Contract.Block
        $Contract.State.Calls | Should -Be 1
        $Budget | Should -Be 0
        $Flush.Discarded | Should -Be 0
        $Flush.Remaining | Should -Be 2
        $Flush.PendingRows | Should -BeTrue
        Test-Path -LiteralPath $Files.First | Should -BeTrue
    }

    It 'saves this run''s permanently rejected row, so the next run tries it once more' {
        $Contract = New-TestContractSender @('Permanent')
        $Budget = 1
        $Result = Send-AURunRows -Rows (New-AURunRows -MainColumns (New-TestMain) -LogAPIMode 'LogIngestionAPI' -RunId $script:RunA) -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Contract.Block
        $Result.Saved | Should -Be 1
        $Budget | Should -Be 0
    }

    It 'deletes a sent row that is read-only' {
        $Files = Save-TestTwoRuns
        [IO.File]::SetAttributes($Files.First, [IO.FileAttributes]::ReadOnly)
        $Contract = New-TestContractSender
        $Budget = 1
        $Flush = Send-AUOutbox -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Contract.Block
        $Flush.Remaining | Should -Be 0
        Test-Path -LiteralPath $Files.First | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:Outbox -Force) | Should -BeNullOrEmpty
    }

    Context 'a sent row that cannot be deleted' {
        BeforeEach {
            $script:Files = Save-TestTwoRuns
            $script:Blocked = $script:Files.First
            Mock Remove-AUFileItem { if ($Path -eq $script:Blocked) { throw 'The process cannot access the file.' } else { [IO.File]::Delete($Path) } }
        }

        It 'is renamed to *.sent, is not pending, and is never sent again' {
            $Contract = New-TestContractSender
            $Budget = 1
            $Flush = Send-AUOutbox -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Contract.Block
            $Flush.Sent | Should -Be 2
            $Flush.Remaining | Should -Be 0
            $Flush.PendingRows | Should -BeFalse
            Test-Path -LiteralPath $script:Files.First | Should -BeFalse
            Test-Path -LiteralPath "$($script:Files.First).sent" | Should -BeTrue
            @(Get-AUOutboxFiles -OutboxDir $script:Outbox) | Should -BeNullOrEmpty

            $Again = New-TestContractSender
            $Budget = 1
            $Next = Send-AUOutbox -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Again.Block
            $Again.State.Calls | Should -Be 0
            $Next.PendingRows | Should -BeFalse
        }

        It 'is swept with the leftover temp files, whatever its age' {
            $Contract = New-TestContractSender
            $Budget = 1
            [void](Send-AUOutbox -OutboxDir $script:Outbox -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Contract.Block)
            $script:Blocked = $null
            Remove-AUStaleOutboxTemp -OutboxDir $script:Outbox | Should -Be 1
            @(Get-ChildItem -LiteralPath $script:Outbox -Force) | Should -BeNullOrEmpty
        }

        It 'stays and counts as pending when it was not sent' {
            Remove-AUOutboxFile -Path $script:Files.First | Should -BeFalse
            Test-Path -LiteralPath $script:Files.First | Should -BeTrue
            Test-Path -LiteralPath "$($script:Files.First).sent" | Should -BeFalse
        }
    }

    It 'sends nothing and saves nothing without an outbox folder' {
        $Contract = New-TestContractSender @('Fail')
        $Budget = 1
        $Flush = Send-AUOutbox -OutboxDir '' -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Contract.Block
        $Flush.PendingRows | Should -BeFalse
        $Flush.OutboxSkipped | Should -BeFalse
        $Contract.State.Calls | Should -Be 0
        $Result = Send-AURunRows -Rows (New-AURunRows -MainColumns (New-TestMain) -LogAPIMode 'LogIngestionAPI' -RunId $script:RunA) -OutboxDir '' -RetryBudget ([ref]$Budget) -LogAPIMode 'LogIngestionAPI' -Sender $Contract.Block
        $Result.Pending | Should -Be 1
        $Result.Saved | Should -Be 0
        $Result.OutboxSkipped | Should -BeTrue
    }
}
