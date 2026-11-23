BeforeAll { . "$PSScriptRoot\_Import.ps1" }

Describe 'ConvertTo-AUChunks' {
    BeforeAll {
        # Version 19's inline InstalledApps sequence, copied as the reference (F32): GZip with the
        # default level, a default StreamWriter (UTF-8, no BOM), Base64, then the regex split with the
        # empty strings between captures dropped, as the column loop did.
        # Untyped, as in version 19, so a null list reaches $sw.Write($null) as it did there.
        function Invoke-V19Chunks($InstalledAppJson, [int]$ChunkSize)
        {
            $ms = New-Object System.IO.MemoryStream
            $cs = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Compress)
            $sw = New-Object System.IO.StreamWriter($cs)
            $sw.Write($InstalledAppJson)
            $sw.Close()
            $InstalledAppJson = [System.Convert]::ToBase64String($ms.ToArray())
            $InstalledAppJsonArr = $InstalledAppJson -split "(.{$ChunkSize})"
            $Pieces = New-Object System.Collections.Generic.List[string]
            foreach ($InstalledApp in $InstalledAppJsonArr)
            {
                if ($InstalledApp.Length -gt 0) { $Pieces.Add($InstalledApp) }
            }
            return , $Pieces.ToArray()
        }

        # The decoder the round trips use: Base64, then GUnzip, then UTF-8 (F47).
        function Expand-TestBlob([string[]]$Pieces)
        {
            $Bytes = [Convert]::FromBase64String(($Pieces -join ''))
            $In = New-Object System.IO.MemoryStream(, $Bytes)
            $Gz = New-Object System.IO.Compression.GZipStream($In, [System.IO.Compression.CompressionMode]::Decompress)
            $Reader = New-Object System.IO.StreamReader($Gz, [Text.Encoding]::UTF8)
            try { return $Reader.ReadToEnd() } finally { $Reader.Dispose() }
        }

        # Text that GZip can barely shrink: Base64 of seeded random bytes, inside a JSON string.
        function New-TestJson([int]$Bytes, [int]$Seed)
        {
            $Buffer = New-Object byte[] $Bytes
            (New-Object System.Random($Seed)).NextBytes($Buffer)
            return '[{"Blob":"' + [Convert]::ToBase64String($Buffer) + '"}]'
        }

        # Finds an input whose v19 Base64 is exactly $Target characters. GZip of this text is about as
        # long as the random bytes, so each step moves the byte count by 3/4 of the gap.
        function Find-TestJsonForBase64Length([int]$Target, [int]$Seed)
        {
            $Bytes = [int]($Target * 0.75)
            for ($Try = 0; $Try -lt 200; $Try++)
            {
                $Json = New-TestJson $Bytes $Seed
                $Length = (Invoke-V19Chunks $Json 1000000000)[0].Length
                if ($Length -eq $Target) { return $Json }
                $Step = [int][Math]::Truncate(($Target - $Length) * 0.75)
                if ($Step -eq 0) { $Step = [Math]::Sign($Target - $Length) }
                $Bytes += $Step
            }
            throw "No input found whose Base64 is $Target characters."
        }

        $script:Sizes = @(64512, 31744)
        $NonAscii = 'caf' + [char]0x00E9 + ' ' + [char]0x65E5 + [char]0x672C + ' ' + [char]0xD83D + [char]0xDE00
        $script:Inputs = [ordered]@{
            'empty'           = ''
            'empty array'     = '[]'
            'small'           = '[{"AppName":"7-Zip 24.08 (x64)","AppVersion":"24.08","AppPublisher":"Igor Pavlov"}]'
            'non-ASCII'       = '[{"AppName":"' + $NonAscii + '"}]'
            'exactly 64512'   = Find-TestJsonForBase64Length 64512 11
            'exactly 2x31744' = Find-TestJsonForBase64Length (2 * 31744) 12
            'multi-piece'     = New-TestJson 200000 13
            '3 MB'            = New-TestJson 2359296 14
        }
    }

    It 'gives version 19''s pieces for every input, in both sizes (F32)' {
        foreach ($Name in $script:Inputs.Keys)
        {
            foreach ($Size in $script:Sizes)
            {
                $Expected = Invoke-V19Chunks $script:Inputs[$Name] $Size
                $Actual = ConvertTo-AUChunks -Json $script:Inputs[$Name] -ChunkSize $Size
                $Because = "input '$Name' at $Size"
                $Actual.GetType() | Should -Be ([string[]]) -Because $Because
                $Actual.Count | Should -Be $Expected.Count -Because $Because
                for ($i = 0; $i -lt $Expected.Count; $i++)
                {
                    $Actual[$i] -ceq $Expected[$i] | Should -BeTrue -Because "$Because, piece $($i + 1)"
                }
            }
        }
    }

    It 'treats a null Json as version 19 treated an empty app list' {
        $Expected = Invoke-V19Chunks $null 64512
        $Actual = ConvertTo-AUChunks -Json $null -ChunkSize 64512
        # .NET Framework's GZipStream writes no bytes when nothing was written to it, so version 19
        # had no InstalledApps piece at all for an empty list; the function matches that.
        $Actual.GetType() | Should -Be ([string[]])
        $Actual.Count | Should -Be $Expected.Count
        for ($i = 0; $i -lt $Expected.Count; $i++) { $Actual[$i] | Should -BeExactly $Expected[$i] }
        Expand-TestBlob $Actual | Should -BeExactly ''
    }

    It 'returns a string array even when there is one piece' {
        $Pieces = ConvertTo-AUChunks -Json $script:Inputs['small'] -ChunkSize 64512
        $Pieces.GetType() | Should -Be ([string[]])
        $Pieces.Count | Should -Be 1
    }

    It 'fills the boundary inputs exactly' {
        $One = ConvertTo-AUChunks -Json $script:Inputs['exactly 64512'] -ChunkSize 64512
        $One.Count | Should -Be 1
        $One[0].Length | Should -Be 64512
        $Classic = ConvertTo-AUChunks -Json $script:Inputs['exactly 64512'] -ChunkSize 31744
        @($Classic | ForEach-Object Length) | Should -Be @(31744, 31744, 1024)
        $Two = ConvertTo-AUChunks -Json $script:Inputs['exactly 2x31744'] -ChunkSize 31744
        @($Two | ForEach-Object Length) | Should -Be @(31744, 31744)
    }

    It 'round-trips every input to the original JSON (F47)' {
        foreach ($Name in $script:Inputs.Keys)
        {
            foreach ($Size in $script:Sizes)
            {
                $Pieces = ConvertTo-AUChunks -Json $script:Inputs[$Name] -ChunkSize $Size
                Expand-TestBlob $Pieces | Should -BeExactly $script:Inputs[$Name] -Because "input '$Name' at $Size"
            }
        }
    }

    It 'returns a 3 MB input in ordered pieces of at most ChunkSize, with no cap' {
        $Json = $script:Inputs['3 MB']
        $Json.Length | Should -BeGreaterThan 3000000
        foreach ($Size in $script:Sizes)
        {
            $Pieces = ConvertTo-AUChunks -Json $Json -ChunkSize $Size
            $Pieces.Count | Should -BeGreaterThan 10
            for ($i = 0; $i -lt $Pieces.Count - 1; $i++) { $Pieces[$i].Length | Should -Be $Size }
            $Pieces[-1].Length | Should -BeGreaterThan 0
            $Pieces[-1].Length | Should -Not -BeGreaterThan $Size
            Expand-TestBlob $Pieces | Should -BeExactly $Json
        }
    }

    It 'rejects a chunk size below 1' {
        { ConvertTo-AUChunks -Json '[]' -ChunkSize 0 } | Should -Throw
    }

    It 'throws a compression failure to its caller, as version 19 did' {
        $Lone = '[{"AppName":"' + [char]0xD800 + '"}]'
        { Invoke-V19Chunks $Lone 64512 } | Should -Throw
        { ConvertTo-AUChunks -Json $Lone -ChunkSize 64512 } | Should -Throw
    }
}

Describe 'InstalledApps upload with metering off (F32)' {
    BeforeAll {
        # The script's own InstalledApps sequence, from compression to the upload JSON, taken from the
        # script text as written and run with a recording logger.
        $Text = [IO.File]::ReadAllText((Resolve-Path "$PSScriptRoot\..\..\Intune_Windows_Inventory.ps1").Path)
        $Start = $Text.IndexOf('    Write-CMTraceLog "Compressing app inventory JSON with GZip')
        $End = -1
        if ($Start -ge 0) { $End = $Text.IndexOf('    # Submit the data to the API endpoint', $Start) }
        if ($Start -lt 0 -or $End -lt 0) { throw 'InstalledApps sequence not found in the script.' }
        $script:ScriptSequence = $Text.Substring($Start, $End - $Start)

        # Version 19's sequence, copied verbatim from 457bc6f (Intune_Windows_Inventory.ps1:8578-8636).
        $script:V19Sequence = @'
    Write-CMTraceLog "Compressing app inventory JSON with GZip..."
    try
    {
        $ms = New-Object System.IO.MemoryStream
        $cs = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Compress)
        $sw = New-Object System.IO.StreamWriter($cs)
        $sw.Write($InstalledAppJson)
        $sw.Close()
        $InstalledAppJson = [System.Convert]::ToBase64String($ms.ToArray())
        Write-CMTraceLog "App inventory compressed successfully, Base64 size: $($InstalledAppJson.Length) characters"
    }
    catch
    {
        Write-CMTraceLog "Error compressing app inventory: $($_.Exception.Message)" -ErrorMsg
        throw
    }

    Write-CMTraceLog "Building main app upload object..."
    $MainApp = New-Object -TypeName PSObject
    $MainApp | Add-Member -MemberType NoteProperty -Name "ComputerName$(if($LogAPIMode -eq "LogIngestionAPI"){"_s"})" -Value "$ComputerName" -Force
    $MainApp | Add-Member -MemberType NoteProperty -Name "ManagedDeviceID$(if($LogAPIMode -eq "LogIngestionAPI"){"_g"})" -Value "$ManagedDeviceID" -Force

    Write-CMTraceLog "Splitting app inventory into chunks..."
    $InstalledAppJsonArr = $InstalledAppJson -split "(.{$(if($LogAPIMode -eq 'LogIngestionAPI'){64512}else{31744})})"
    $i = 0
    foreach ($InstalledApp in $InstalledAppJsonArr)
    {
        if ($InstalledApp.Length -gt 0 )
        {
            $i++
            $MainApp | Add-Member -MemberType NoteProperty -Name ("InstalledApps" + $i.ToString() + "$(if($LogAPIMode -eq "LogIngestionAPI"){"_s"})") -Value $InstalledApp -Force
        }
    }
    Write-CMTraceLog "App inventory split into $i chunk(s)"

    if ($InstalledAppJson.Length -gt $(if ($LogAPIMode -eq "LogIngestionAPI")
            {
                10 * 63 * 1024
            }
            else
            {
                10 * 31 * 1024
            }))
    {
        $errorMsg = "InstallApp is too big and exceed the $(if($LogAPIMode -eq 'LogIngestionAPI'){64}else{32})Kb limit per column for a single upload. Please increase number of columns (#10). Current payload size is: " + ($InstalledAppJson.Length / 1024).ToString("#.#") + "Kb"
        Write-CMTraceLog $errorMsg -ErrorMsg
        throw($errorMsg)
    }

    Write-CMTraceLog "Converting main app object to JSON for upload..."
    $AppJson = if ($LogAPIMode -eq "LogIngestionAPI")
    {
        "[$($MainApp | ConvertTo-Json -Compress)]"
    }
    else
    {
        $MainApp | ConvertTo-Json
    }
    Write-CMTraceLog "Final app JSON payload size: $($AppJson.Length) characters"

'@

        # Runs a sequence in its own scope with a recording logger. Returns the upload JSON, the
        # column names, the Base64-size and too-big log lines, and the error message, if any.
        function Invoke-Sequence([string]$Sequence, $InstalledAppJson, [string]$LogAPIMode)
        {
            $Prologue = @'
param ($InstalledAppJson, $LogAPIMode)
$Log = New-Object System.Collections.Generic.List[string]
function Write-CMTraceLog { param ([string]$Message, [switch]$ErrorMsg) $Log.Add($Message) }
$ComputerName = 'PC-0001'
$ManagedDeviceID = '0b6c1a2e-3f4d-4e5f-8a9b-0c1d2e3f4a5b'
$AppJson = $null
$MainApp = $null
$Failure = $null
try
{

'@
            $Epilogue = @'

}
catch { $Failure = $_.Exception.Message }
[pscustomobject]@{
    AppJson = $AppJson
    Columns = @(if ($MainApp) { $MainApp.PSObject.Properties | ForEach-Object Name })
    Log     = @($Log | Where-Object { $_ -match 'Base64 size|too big' })
    Error   = $Failure
}
'@
            $Block = [scriptblock]::Create($Prologue + $Sequence + $Epilogue)
            return & $Block $InstalledAppJson $LogAPIMode
        }

        function New-SequenceJson([int]$Bytes, [int]$Seed)
        {
            $Buffer = New-Object byte[] $Bytes
            (New-Object System.Random($Seed)).NextBytes($Buffer)
            return '[{"Blob":"' + [Convert]::ToBase64String($Buffer) + '"}]'
        }

        $script:SequenceInputs = [ordered]@{
            'no apps' = (@() | ConvertTo-Json)
            'empty'   = ''
            '[]'      = '[]'
            'small'   = '[{"AppName":"7-Zip 24.08 (x64)","AppVersion":"24.08","AppPublisher":"Igor Pavlov"}]'
            '100 KB'  = New-SequenceJson 100000 21
            '700 KB'  = New-SequenceJson 700000 22
        }
    }

    It 'calls ConvertTo-AUChunks, the one copy' {
        $script:ScriptSequence | Should -Match 'ConvertTo-AUChunks -Json \$InstalledAppJson'
        $script:ScriptSequence | Should -Not -Match 'GZipStream|-split'
    }

    It 'builds version 19''s upload, columns, Base64 size, and too-big throw, in both modes' {
        foreach ($Mode in 'LogIngestionAPI', 'ClientSecret')
        {
            foreach ($Name in $script:SequenceInputs.Keys)
            {
                $Because = "input '$Name' in $Mode"
                $V19 = Invoke-Sequence $script:V19Sequence $script:SequenceInputs[$Name] $Mode
                $Now = Invoke-Sequence $script:ScriptSequence $script:SequenceInputs[$Name] $Mode
                $Now.Error | Should -BeExactly $V19.Error -Because $Because
                $Now.Log -join "`n" | Should -BeExactly ($V19.Log -join "`n") -Because $Because
                $Now.Columns -join ',' | Should -BeExactly ($V19.Columns -join ',') -Because $Because
                $Now.AppJson -ceq $V19.AppJson | Should -BeTrue -Because $Because
            }
        }
    }

    It 'covers one-piece, multi-piece, and too-big uploads' {
        $Small = Invoke-Sequence $script:ScriptSequence $script:SequenceInputs['small'] 'LogIngestionAPI'
        @($Small.Columns -match '^InstalledApps').Count | Should -Be 1
        $Small.AppJson | Should -Match '"InstalledApps1_s":"H4sI'
        $Mid = Invoke-Sequence $script:ScriptSequence $script:SequenceInputs['100 KB'] 'LogIngestionAPI'
        @($Mid.Columns -match '^InstalledApps\d+_s$').Count | Should -Be 3
        $Classic = Invoke-Sequence $script:ScriptSequence $script:SequenceInputs['100 KB'] 'ClientSecret'
        @($Classic.Columns -match '^InstalledApps\d+$').Count | Should -Be 5
        foreach ($Mode in 'LogIngestionAPI', 'ClientSecret')
        {
            $Big = Invoke-Sequence $script:ScriptSequence $script:SequenceInputs['700 KB'] $Mode
            $Big.Error | Should -Match '^InstallApp is too big' -Because $Mode
            $Big.AppJson | Should -BeNullOrEmpty -Because $Mode
        }
    }
}
