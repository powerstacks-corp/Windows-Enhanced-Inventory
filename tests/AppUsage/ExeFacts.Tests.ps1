BeforeAll {
    . "$PSScriptRoot\_Import.ps1"
    # A silent logger with the real one's parameters, so tests can check what was logged with a ParameterFilter.
    function Write-CMTraceLog { param ([string]$Message, [string]$Component, [int]$Type) }

    $script:TestSid = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
    $script:Epoch = New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
    $script:OldBuild = New-Object DateTime 2025, 3, 4, 5, 6, 7, ([DateTimeKind]::Utc)
    $script:NewBuild = New-Object DateTime 2026, 10, 11, 12, 13, 14, ([DateTimeKind]::Utc)
    # The Task 5 facts shape (F13), in order.
    $script:FactNames = @('ExeName', 'RunPath', 'LocationClass', 'FileDescription', 'FileProductName', 'FileCompanyName', 'FileVersion', 'ProductVersion',
        'FactsVerified', 'Subsystem', 'MsiProductCode', 'PackageFamily', 'IsServiceBinary', 'UserSid', 'PathEvidence')
    $script:Notepad = Join-Path $env:SystemRoot 'System32\notepad.exe'
    $script:Where = Join-Path $env:SystemRoot 'System32\where.exe'
    # A second in-box exe whose ProductName differs from notepad.exe's.
    $script:Ngen = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\ngen.exe'

    # A synthetic PE header (F38): MZ stub, e_lfanew, PE\0\0, TimeDateStamp, and the optional header's
    # Magic, CheckSum, and Subsystem. No code, no version resource.
    function New-TestPe([string]$Path, [datetime]$LinkTimeUtc, [uint32]$CheckSum, [uint16]$Subsystem = 2, [uint16]$Magic = 0x10B, [int]$Length = 512)
    {
        $Bytes = New-Object byte[] $Length
        $Bytes[0] = 0x4D; $Bytes[1] = 0x5A
        [BitConverter]::GetBytes([int]0x80).CopyTo($Bytes, 0x3C)
        $Bytes[0x80] = 0x50; $Bytes[0x81] = 0x45
        $Stamp = [uint32]($LinkTimeUtc - $script:Epoch).TotalSeconds
        [BitConverter]::GetBytes($Stamp).CopyTo($Bytes, 0x88)
        [BitConverter]::GetBytes([uint16]0xF0).CopyTo($Bytes, 0x94)
        if ($Length -ge 0x98 + 70)
        {
            [BitConverter]::GetBytes($Magic).CopyTo($Bytes, 0x98)
            [BitConverter]::GetBytes($CheckSum).CopyTo($Bytes, 0x98 + 64)
            [BitConverter]::GetBytes($Subsystem).CopyTo($Bytes, 0x98 + 68)
        }
        [void](New-Item -ItemType Directory -Force -Path (Split-Path $Path))
        [IO.File]::WriteAllBytes($Path, $Bytes)
    }

    # An ExeInfo from the real parser, so its types are the ones SRUM rows give.
    function New-TestExeInfo([string]$Name, [datetime]$LinkTimeUtc, [uint32]$CheckSum)
    {
        $Text = '!!{0}!{1}!{2}!' -f $Name, $LinkTimeUtc.ToString('yyyy/MM/dd:HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture), $CheckSum.ToString('x')
        return ConvertFrom-AUExeInfo $Text
    }

    # The ExeInfo of a file on disk, from its own header.
    function Get-TestExeInfoOf([string]$Path, [string]$Name)
    {
        $Fingerprint = Get-AUPeFingerprint $Path
        return New-TestExeInfo $Name $Fingerprint.LinkTimeUtc $Fingerprint.CheckSum
    }

    function Get-TestVersionInfo([string]$Path) { [Diagnostics.FileVersionInfo]::GetVersionInfo($Path) }
}

Describe 'Get-AUPeFingerprint' {
    It 'reads the TimeDateStamp as a Utc LinkTimeUtc and the CheckSum as a [uint32], equal to the parsed ExeInfo' {
        $path = Join-Path $TestDrive 'a\tool.exe'
        New-TestPe $path $script:OldBuild 0x1A2B3C
        $fp = Get-AUPeFingerprint $path
        $info = New-TestExeInfo 'tool.exe' $script:OldBuild 0x1A2B3C

        $fp.LinkTimeUtc | Should -Be $script:OldBuild
        $fp.LinkTimeUtc.Kind | Should -Be ([DateTimeKind]::Utc)
        $fp.CheckSum | Should -BeOfType [uint32]
        $fp.CheckSum | Should -Be ([uint32]0x1A2B3C)
        $fp.LinkTimeUtc.Ticks | Should -Be $info.LinkTimeUtc.Ticks
        $fp.CheckSum -eq $info.CheckSum | Should -BeTrue
    }

    It 'reads a PE32+ header at the same offsets' {
        $path = Join-Path $TestDrive 'b\tool64.exe'
        New-TestPe $path $script:NewBuild ([uint32]4294967280) -Magic 0x20B
        $fp = Get-AUPeFingerprint $path
        $fp.LinkTimeUtc | Should -Be $script:NewBuild
        $fp.CheckSum | Should -Be ([uint32]4294967280)
    }

    It 'reports the subsystem as GUI, Console, or Other' {
        $gui = Join-Path $TestDrive 'c\gui.exe'; New-TestPe $gui $script:OldBuild 1 -Subsystem 2
        $cui = Join-Path $TestDrive 'c\cui.exe'; New-TestPe $cui $script:OldBuild 1 -Subsystem 3
        $native = Join-Path $TestDrive 'c\native.exe'; New-TestPe $native $script:OldBuild 1 -Subsystem 1
        (Get-AUPeFingerprint $gui).Subsystem | Should -BeExactly 'GUI'
        (Get-AUPeFingerprint $cui).Subsystem | Should -BeExactly 'Console'
        (Get-AUPeFingerprint $native).Subsystem | Should -BeExactly 'Other'
    }

    It 'reads the subsystem of in-box exes: notepad.exe is GUI and where.exe is Console' {
        (Get-AUPeFingerprint $script:Notepad).Subsystem | Should -BeExactly 'GUI'
        (Get-AUPeFingerprint $script:Where).Subsystem | Should -BeExactly 'Console'
    }

    It 'returns $null for a missing file, a folder, a non-PE file, a truncated header, or an e_lfanew past the end' {
        $text = Join-Path $TestDrive 'd\notes.exe'
        [void](New-Item -ItemType Directory -Force -Path (Split-Path $text))
        [IO.File]::WriteAllText($text, 'MZ but not a PE file at all, just text that is long enough to have an e_lfanew field.')
        $short = Join-Path $TestDrive 'd\short.exe'; New-TestPe $short $script:OldBuild 1 -Length 0xA0
        $far = Join-Path $TestDrive 'd\far.exe'
        New-TestPe $far $script:OldBuild 1
        $bytes = [IO.File]::ReadAllBytes($far); [BitConverter]::GetBytes([int]0x7FFFFFF0).CopyTo($bytes, 0x3C); [IO.File]::WriteAllBytes($far, $bytes)

        Get-AUPeFingerprint (Join-Path $TestDrive 'd\missing.exe') | Should -BeNullOrEmpty
        Get-AUPeFingerprint (Join-Path $TestDrive 'd') | Should -BeNullOrEmpty
        Get-AUPeFingerprint $text | Should -BeNullOrEmpty
        Get-AUPeFingerprint $short | Should -BeNullOrEmpty
        Get-AUPeFingerprint $far | Should -BeNullOrEmpty
        Get-AUPeFingerprint '' | Should -BeNullOrEmpty
    }

    It 'reads a file another process holds open for writing and deleting' {
        $path = Join-Path $TestDrive 'e\busy.exe'
        New-TestPe $path $script:OldBuild 7
        $holder = New-Object IO.FileStream ($path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try { (Get-AUPeFingerprint $path).CheckSum | Should -Be ([uint32]7) }
        finally { $holder.Dispose() }
    }
}

Describe 'Resolve-AUKernelPath' {
    BeforeAll {
        $script:RootC = Join-Path (Get-AULongPath $TestDrive) 'VolC'
        $script:RootE = Join-Path (Get-AULongPath $TestDrive) 'VolE'
        [void](New-Item -ItemType Directory -Force -Path $script:RootC, $script:RootE)
        $script:Rest = 'Program Files\Contoso\tool.exe'
        $script:Kernel = '\Device\HarddiskVolume3\' + $script:Rest
        $script:Info = New-TestExeInfo 'tool.exe' $script:OldBuild 0x5150
    }
    BeforeEach {
        Remove-Item -Recurse -Force -Path (Join-Path $script:RootC '*'), (Join-Path $script:RootE '*') -ErrorAction SilentlyContinue
        Mock Get-AUFixedDrives { @($script:RootC, $script:RootE) }
    }

    It 'returns the drive path whose fingerprint matches and caches the volume' {
        New-TestPe (Join-Path $script:RootE $script:Rest) $script:OldBuild 0x5150
        $cache = @{}
        $path = Resolve-AUKernelPath $script:Kernel $script:Info $cache
        $path | Should -BeExactly (Join-Path $script:RootE $script:Rest)
        $path | Should -Not -Match '^\\\\\?\\|\\Device\\'
        $cache['harddiskvolume3'] | Should -BeExactly $script:RootE
    }

    It 'rejects a single candidate whose fingerprint does not match, and caches nothing' {
        New-TestPe (Join-Path $script:RootC $script:Rest) $script:NewBuild 0x5150
        $cache = @{}
        Resolve-AUKernelPath $script:Kernel $script:Info $cache | Should -BeNullOrEmpty
        $cache.Count | Should -Be 0
    }

    It 'rejects a candidate with the right link time and the wrong CheckSum' {
        New-TestPe (Join-Path $script:RootC $script:Rest) $script:OldBuild 0x5151
        Resolve-AUKernelPath $script:Kernel $script:Info @{} | Should -BeNullOrEmpty
    }

    It 'returns $null when the same build verifies under two drives (ambiguous), and caches nothing' {
        New-TestPe (Join-Path $script:RootC $script:Rest) $script:OldBuild 0x5150
        New-TestPe (Join-Path $script:RootE $script:Rest) $script:OldBuild 0x5150
        $cache = @{}
        Resolve-AUKernelPath $script:Kernel $script:Info $cache | Should -BeNullOrEmpty
        $cache.Count | Should -Be 0
    }

    It 'picks the one drive that verifies when the file is on two drives with different builds' {
        New-TestPe (Join-Path $script:RootC $script:Rest) $script:NewBuild 0x9999
        New-TestPe (Join-Path $script:RootE $script:Rest) $script:OldBuild 0x5150
        Resolve-AUKernelPath $script:Kernel $script:Info @{} | Should -BeExactly (Join-Path $script:RootE $script:Rest)
    }

    It 'returns $null when the file is on no drive' {
        Resolve-AUKernelPath $script:Kernel $script:Info @{} | Should -BeNullOrEmpty
    }

    It 'tries only the cached drive for a cached volume' {
        New-TestPe (Join-Path $script:RootC $script:Rest) $script:OldBuild 0x5150
        $cache = @{ 'harddiskvolume3' = $script:RootE }
        Resolve-AUKernelPath $script:Kernel $script:Info $cache | Should -BeNullOrEmpty
        Should -Invoke Get-AUFixedDrives -Times 0
        New-TestPe (Join-Path $script:RootE $script:Rest) $script:OldBuild 0x5150
        Resolve-AUKernelPath $script:Kernel $script:Info $cache | Should -BeExactly (Join-Path $script:RootE $script:Rest)
    }

    It 'does not probe a drive another volume is cached to' {
        New-TestPe (Join-Path $script:RootC $script:Rest) $script:OldBuild 0x5150
        $cache = @{ 'harddiskvolume1' = $script:RootC }
        Resolve-AUKernelPath '\Device\HarddiskVolume7\Program Files\Contoso\tool.exe' $script:Info $cache | Should -BeNullOrEmpty
        $cache.ContainsKey('harddiskvolume7') | Should -BeFalse
    }

    It 'works without a cache' {
        New-TestPe (Join-Path $script:RootC $script:Rest) $script:OldBuild 0x5150
        Resolve-AUKernelPath $script:Kernel $script:Info $null | Should -BeExactly (Join-Path $script:RootC $script:Rest)
    }

    It 'never probes for a Package or Other entry, or a Win32 entry without a fingerprint' {
        New-TestPe (Join-Path $script:RootC $script:Rest) $script:OldBuild 0x5150
        foreach ($text in @('Microsoft.WindowsCalculator_11.2405.2.0_x64__8wekyb3d8bbwe', 'C:\Program Files\Contoso\tool.exe', '!!tool.exe!not a date!zz!'))
        {
            Resolve-AUKernelPath $script:Kernel (ConvertFrom-AUExeInfo $text) @{} | Should -BeNullOrEmpty
        }
        Resolve-AUKernelPath $script:Kernel $null @{} | Should -BeNullOrEmpty
        Should -Invoke Get-AUFixedDrives -Times 0
    }

    It 'rejects a path that is not a HarddiskVolume kernel path, or that holds . or .. segments or a stream name' {
        New-TestPe (Join-Path $script:RootC $script:Rest) $script:OldBuild 0x5150
        foreach ($kernel in @('', 'C:\Program Files\Contoso\tool.exe', '\Device\Mup\server\share\tool.exe', '\Device\HarddiskVolume3\',
                '\Device\HarddiskVolume3\Program Files\..\Program Files\Contoso\tool.exe', '\Device\HarddiskVolume3\Program Files\.\Contoso\tool.exe',
                '\Device\HarddiskVolume3\Program Files\Contoso\\tool.exe', '\Device\HarddiskVolume3\Program Files\Contoso\tool.exe:evil'))
        {
            Resolve-AUKernelPath $kernel $script:Info @{} | Should -BeNullOrEmpty
        }
    }

    It 'rejects a file whose name is not the entry''s exe name, even when the fingerprint matches' {
        New-TestPe (Join-Path $script:RootC 'Program Files\Contoso\other.exe') $script:OldBuild 0x5150
        Resolve-AUKernelPath '\Device\HarddiskVolume3\Program Files\Contoso\other.exe' $script:Info @{} | Should -BeNullOrEmpty
    }

    It 'matches the volume name and the drive path ignoring case' {
        New-TestPe (Join-Path $script:RootC $script:Rest) $script:OldBuild 0x5150
        $cache = @{}
        Resolve-AUKernelPath '\device\HARDDISKVOLUME3\program files\contoso\TOOL.EXE' $script:Info $cache | Should -Not -BeNullOrEmpty
        $cache['harddiskvolume3'] | Should -BeExactly $script:RootC
    }
}

Describe 'Get-AUFixedDrives and probing on this machine' {
    It 'returns each fixed drive root as its own string, including the system drive' {
        $roots = @(Get-AUFixedDrives)
        $roots | ForEach-Object { $_ | Should -BeOfType [string]; $_ | Should -Match '^[A-Z]:$' }
        $roots | Should -Contain $env:SystemDrive.ToUpperInvariant()
        @(Get-AUFixedDrives | Where-Object { $_ -eq $env:SystemDrive.ToUpperInvariant() }).Count | Should -Be 1
    }

    It 'translates a kernel path to a file on the system drive with the real drive list' {
        $path = Join-Path (Get-AULongPath $TestDrive) 'Real\tool.exe'
        if ($path -notmatch '^[A-Za-z]:\\') { Set-ItResult -Skipped -Because 'TestDrive is not on a drive letter'; return }
        if ($path.Substring(0, 2).ToUpperInvariant() -notin @(Get-AUFixedDrives)) { Set-ItResult -Skipped -Because 'TestDrive is not on a fixed drive'; return }
        New-TestPe $path $script:OldBuild 0x77
        $cache = @{}
        Resolve-AUKernelPath ('\Device\HarddiskVolume42\' + $path.Substring(3)) (New-TestExeInfo 'tool.exe' $script:OldBuild 0x77) $cache | Should -BeExactly $path
        $cache['harddiskvolume42'] | Should -BeExactly $path.Substring(0, 2).ToUpperInvariant()
    }
}
Describe 'Get-AULongPath' {
    It 'returns a path with no short-name segment unchanged' {
        Get-AULongPath 'C:\Program Files\Contoso\tool.exe' | Should -BeExactly 'C:\Program Files\Contoso\tool.exe'
    }

    It 'expands an 8.3 short folder name to its long name' {
        $long = Join-Path (Get-AULongPath $TestDrive) 'A Folder With A Long Name'
        [void](New-Item -ItemType Directory -Force -Path $long)
        New-TestPe (Join-Path $long 'tool.exe') $script:OldBuild 1
        $short = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($long).ShortPath
        if ($short -notmatch '~') { Set-ItResult -Skipped -Because 'this volume does not create 8.3 names'; return }
        Get-AULongPath ($short + '\tool.exe') | Should -BeExactly ($long + '\tool.exe')
    }

    It 'returns the path unchanged when a short segment is not found' {
        Get-AULongPath 'C:\NOSUCH~1\tool.exe' | Should -BeExactly 'C:\NOSUCH~1\tool.exe'
    }
}

Describe 'Find-AUExePath' {
    BeforeAll {
        $script:Root = Join-Path (Get-AULongPath $TestDrive) 'Vol'
        $script:Sys32 = Join-Path $script:Root 'Windows\System32\tool.exe'
        $script:Wow64 = Join-Path $script:Root 'Windows\SysWOW64\tool.exe'
        $script:Kernels = @('\Device\HarddiskVolume3\Windows\System32\tool.exe', '\Device\HarddiskVolume3\Windows\SysWOW64\tool.exe')
    }
    BeforeEach {
        Remove-Item -Recurse -Force -Path $script:Root -ErrorAction SilentlyContinue
        Mock Get-AUFixedDrives { @($script:Root) }
    }

    It 'chooses the System32 or SysWOW64 candidate whose fingerprint matches, Verified $true (F37)' {
        New-TestPe $script:Sys32 $script:NewBuild 0x64
        New-TestPe $script:Wow64 $script:OldBuild 0x32
        $found = Find-AUExePath $script:Kernels (New-TestExeInfo 'tool.exe' $script:OldBuild 0x32) @{}
        $found.Path | Should -BeExactly $script:Wow64
        $found.Verified | Should -BeTrue
        @($found.PSObject.Properties.Name) | Should -Be @('Path', 'Verified')
        (Find-AUExePath $script:Kernels (New-TestExeInfo 'tool.exe' $script:NewBuild 0x64) @{}).Path | Should -BeExactly $script:Sys32
    }

    It 'returns $null when both candidates match (D24)' {
        Mock Write-CMTraceLog { }
        New-TestPe $script:Sys32 $script:OldBuild 0x32
        New-TestPe $script:Wow64 $script:OldBuild 0x32
        Find-AUExePath $script:Kernels (New-TestExeInfo 'tool.exe' $script:OldBuild 0x32) @{} | Should -BeNullOrEmpty
        Should -Invoke Write-CMTraceLog -ParameterFilter { $Message -match '2 paths verify' }
    }

    It 'returns the one existing path with Verified $false when none verifies (updated in place)' {
        New-TestPe $script:Sys32 $script:NewBuild 0x64
        $cache = @{}
        $found = Find-AUExePath $script:Kernels (New-TestExeInfo 'tool.exe' $script:OldBuild 0x32) $cache
        $found.Path | Should -BeExactly $script:Sys32
        $found.Verified | Should -BeFalse
        # Only a verified path caches the volume.
        $cache.Count | Should -Be 0
    }

    It 'returns $null when two distinct paths exist and none verifies' {
        Mock Write-CMTraceLog { }
        New-TestPe $script:Sys32 $script:NewBuild 0x64
        New-TestPe $script:Wow64 $script:NewBuild 0x65
        Find-AUExePath $script:Kernels (New-TestExeInfo 'tool.exe' $script:OldBuild 0x32) @{} | Should -BeNullOrEmpty
        Should -Invoke Write-CMTraceLog -ParameterFilter { $Message -match '2 paths exist' }
    }

    It 'prefers the one verified path over another existing path that does not verify' {
        New-TestPe $script:Sys32 $script:NewBuild 0x64
        New-TestPe $script:Wow64 $script:OldBuild 0x32
        $found = Find-AUExePath $script:Kernels (New-TestExeInfo 'tool.exe' $script:OldBuild 0x32) @{}
        $found.Path | Should -BeExactly $script:Wow64
        $found.Verified | Should -BeTrue
    }

    It 'returns $null when one kernel path exists under two drives and neither verifies' {
        $other = Join-Path (Get-AULongPath $TestDrive) 'Vol2'
        Mock Get-AUFixedDrives { @($script:Root, (Join-Path (Get-AULongPath $TestDrive) 'Vol2')) }
        New-TestPe $script:Sys32 $script:NewBuild 0x64
        New-TestPe (Join-Path $other 'Windows\System32\tool.exe') $script:NewBuild 0x64
        Find-AUExePath @($script:Kernels[0]) (New-TestExeInfo 'tool.exe' $script:OldBuild 0x32) @{} | Should -BeNullOrEmpty
    }

    It 'counts a kernel path given twice once' {
        New-TestPe $script:Sys32 $script:OldBuild 0x32
        (Find-AUExePath @($script:Kernels[0], $script:Kernels[0].ToUpperInvariant()) (New-TestExeInfo 'tool.exe' $script:OldBuild 0x32) @{}).Path | Should -BeExactly $script:Sys32
    }

    It 'returns $null for no candidates, blank candidates, or a Package entry' {
        Find-AUExePath @() (New-TestExeInfo 'tool.exe' $script:OldBuild 0x32) @{} | Should -BeNullOrEmpty
        Find-AUExePath @('', $null) (New-TestExeInfo 'tool.exe' $script:OldBuild 0x32) @{} | Should -BeNullOrEmpty
        Find-AUExePath $script:Kernels (ConvertFrom-AUExeInfo 'Contoso.Notes_8wekyb3d8bbwe!App') @{} | Should -BeNullOrEmpty
    }

    It 'end to end, updated in place: the older build at its only path gives RunPath, unverified facts, and current-file evidence (D30)' -Skip:(-not (Test-Path (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\ngen.exe'))) {
        $path = Join-Path $script:Root 'Program Files\Contoso\app.exe'
        [void](New-Item -ItemType Directory -Force -Path (Split-Path $path))
        Copy-Item $script:Notepad $path -Force
        $old = Get-AUPeFingerprint $path
        $text = '!!app.exe!{0}!{1}!' -f $old.LinkTimeUtc.ToString('yyyy/MM/dd:HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture), $old.CheckSum.ToString('x')
        $info = ConvertFrom-AUExeInfo $text
        # The app is updated in place: a different build now sits at the only path SRUM recorded.
        Copy-Item $script:Ngen $path -Force
        $current = Get-TestVersionInfo $path

        $found = Find-AUExePath @('\Device\HarddiskVolume3\Program Files\Contoso\app.exe') $info @{}
        $found.Path | Should -BeExactly $path
        $found.Verified | Should -BeFalse

        $facts = Get-AUExeFacts $found.Path $info @{} @{} $script:TestSid -ExeInfoText $text
        $facts.RunPath | Should -BeExactly $path
        $facts.FactsVerified | Should -BeFalse
        $facts.FileVersion | Should -BeNullOrEmpty
        $facts.ProductVersion | Should -BeNullOrEmpty
        $facts.FileCompanyName | Should -BeNullOrEmpty
        $facts.FileProductName | Should -BeNullOrEmpty
        $facts.Subsystem | Should -BeNullOrEmpty
        $facts.PathEvidence.CompanyName | Should -BeExactly $current.CompanyName.Trim()
        $facts.PathEvidence.ProductName | Should -BeExactly $current.ProductName.Trim()

        # The per-executable output labels it as current-file evidence (sample 11).
        $entry = New-AULedgerEntry $script:TestSid $text
        $entry.Facts = $facts
        $entry | Add-Member -NotePropertyMembers @{ Target = [pscustomobject]@{ MatchSection = 'None'; CandidateTargets = $null }; Classification = $null; Role = 'Unmatched'; UserType = 'Local'; InstallStatus = 'Unmatched' }
        $usage = @(ConvertTo-AUExeUsage @($entry))
        $usage.Count | Should -Be 1
        $usage[0].RunPath | Should -BeExactly $path
        $usage[0].FactsVerified | Should -BeFalse
        $usage[0].FileVersion | Should -BeNullOrEmpty
        $usage[0].EvidenceSource | Should -BeExactly 'CurrentFileAtPath'
        $usage[0].EvidenceCompanyName | Should -BeExactly $current.CompanyName.Trim()
        $usage[0].EvidenceProductName | Should -BeExactly $current.ProductName.Trim()
    }

    Context 'With nothing on disk' {
        It 'gives $null, facts with only the exe name, and matching falls back to name and publisher' {
            $info = New-TestExeInfo 'tool.exe' $script:OldBuild 0x32
            $found = Find-AUExePath $script:Kernels $info @{}
            $found | Should -BeNullOrEmpty

            $facts = Get-AUExeFacts $null $info @{} @{} $script:TestSid
            $facts.ExeName | Should -BeExactly 'tool.exe'
            $facts.RunPath | Should -BeNullOrEmpty
            $facts.LocationClass | Should -BeNullOrEmpty
            $facts.FactsVerified | Should -BeFalse
            $facts.PathEvidence | Should -BeNullOrEmpty

            # With no run path, the D47 path step has nothing to use; the publisher step decides.
            $apps = @(
                [pscustomobject]@{ DisplayName = 'Contoso Tool'; Publisher = 'Contoso'; InstallLocation = 'C:\Program Files\Contoso'; DisplayIcon = $null; UninstallString = $null }
                [pscustomobject]@{ DisplayName = 'Fabrikam Tool'; Publisher = 'Fabrikam'; InstallLocation = 'C:\Program Files\Fabrikam'; DisplayIcon = $null; UninstallString = $null }
            )
            $evidence = [pscustomobject]@{ Kind = 'CurrentFileAtPath'; Publisher = 'Contoso'; ProductName = $null; FileDescription = $null; Versions = @() }
            $narrowed = Select-AUCandidate $facts $evidence $apps
            $narrowed.Step | Should -BeExactly 'publisher'
            $narrowed.Candidates[0].DisplayName | Should -BeExactly 'Contoso Tool'
        }
    }
}

Describe 'Timed reads outside the allowlisted system folders' {
    BeforeAll {
        $script:SlowScript = 'Start-Sleep -Seconds 30'
    }
    BeforeEach {
        $script:Path = Join-Path (Get-AULongPath $TestDrive) 'Users\alice\AppData\Local\Contoso\app.exe'
        New-TestPe $script:Path $script:OldBuild 0x10
        $script:Info = New-TestExeInfo 'app.exe' $script:OldBuild 0x10
        Mock Write-CMTraceLog { }
    }

    It 'finds the allowlisted system folders and their user-writable subfolders from the machine' {
        $roots = Get-AUDirectReadRoots
        $pf = [Environment]::GetFolderPath('ProgramFiles').TrimEnd('\')
        $win = [Environment]::GetFolderPath('Windows').TrimEnd('\')
        foreach ($folder in @($pf, [Environment]::GetFolderPath('ProgramFilesX86').TrimEnd('\'), "$pf\WindowsApps", "$win\System32", "$win\SysWOW64", "$win\WinSxS", "$win\Microsoft.NET", "$win\SystemApps", "$win\ImmersiveControlPanel"))
        {
            @($roots.Allowed | Where-Object { [string]::Equals($_, $folder, [StringComparison]::OrdinalIgnoreCase) }).Count | Should -Be 1 -Because $folder
        }
        @($roots.Allowed).Count | Should -Be 9
        foreach ($folder in @("$win\System32\Tasks", "$win\System32\spool\drivers\color", "$win\SysWOW64\Tasks", "$win\System32\com\dmp"))
        {
            @($roots.Excluded | Where-Object { [string]::Equals($_, $folder, [StringComparison]::OrdinalIgnoreCase) }).Count | Should -Be 1 -Because $folder
        }
        @($roots.Allowed + $roots.Excluded) | ForEach-Object { $_ | Should -Not -Match '%|\\$' }
        (New-AUReadBudget).DirectRoots.Allowed.Count | Should -Be 9
    }

    It 'reads directly only inside the allowlist; C:\Windows\Temp, System32\Tasks, and the rest of Windows are timed' {
        $pf = [Environment]::GetFolderPath('ProgramFiles').TrimEnd('\')
        $pf86 = [Environment]::GetFolderPath('ProgramFilesX86').TrimEnd('\')
        $win = [Environment]::GetFolderPath('Windows').TrimEnd('\')
        $roots = Get-AUDirectReadRoots
        foreach ($direct in @("$win\System32\notepad.exe", "$pf\Contoso\app.exe", "$pf86\Contoso\app.exe", "$pf\WindowsApps\Contoso.App_1.0.0.0_x64__abc\app.exe",
                "$win\SysWOW64\where.exe", "$win\WinSxS\amd64_x\tool.exe", "$win\Microsoft.NET\Framework64\v4.0.30319\ngen.exe", "$win\SystemApps\App\app.exe",
                "$win\ImmersiveControlPanel\SystemSettings.exe", "$($pf.ToUpperInvariant())\CONTOSO\APP.EXE", ($pf.Replace('\', '/') + '/Contoso/app.exe'), "\\?\$win\System32\notepad.exe",
                "$win\System32\drivers\..\notepad.exe"))
        {
            Test-AUDirectRead $direct $roots | Should -BeTrue -Because $direct
        }
        foreach ($timed in @("$win\Temp\setup.exe", "$win\Tasks\x.exe", "$win\Tracing\x.exe", "$win\explorer.exe", "$win\IMECache\x\setup.exe", "$win\ccmcache\1\setup.exe",
                "$win\System32\Tasks\evil.exe", "$win\System32\Tasks\Microsoft\x.exe", "$win\System32\spool\drivers\color\x.exe", "$win\System32\spool\PRINTERS\x.exe",
                "$win\System32\Microsoft\Crypto\RSA\MachineKeys\x.exe", "$win\SysWOW64\Tasks\x.exe", "$win\SysWOW64\com\dmp\x.exe",
                'C:\Users\alice\AppData\Local\Contoso\app.exe', 'C:\Users\alice\Downloads\setup.exe', 'C:\ProgramData\Contoso\agent.exe', 'E:\probe\ProbeOnE.exe',
                "$pf\..\Users\alice\x.exe", "${pf}X\app.exe", "$win\System32Evil\x.exe", "$win\System32", 'Contoso\app.exe', '', $null))
        {
            Test-AUDirectRead $timed $roots | Should -BeFalse -Because "$timed"
        }
        # Without roots, it reads them itself.
        Test-AUDirectRead "$win\System32\notepad.exe" | Should -BeTrue
        Test-AUDirectRead "$win\System32\Tasks\evil.exe" | Should -BeFalse
    }

    It 'lets an excluded folder win over the allowed folder that holds it' {
        $roots = [pscustomobject]@{ Allowed = @('D:\Apps'); Excluded = @('D:\Apps\Drop') }
        Test-AUDirectRead 'D:\Apps\tool.exe' $roots | Should -BeTrue
        Test-AUDirectRead 'D:\Apps\Drop\tool.exe' $roots | Should -BeFalse
        Test-AUDirectRead 'D:\AppsX\tool.exe' $roots | Should -BeFalse
    }

    It 'routes reads by the allowlist: a System32 file is read directly, C:\Windows\Temp and System32\Tasks are timed' {
        $win = [Environment]::GetFolderPath('Windows').TrimEnd('\')
        # A spent budget: a timed read is skipped without opening the file; a direct read still happens.
        $budget = New-AUReadBudget -TotalSeconds 0
        $direct = Read-AUFile "$win\System32\notepad.exe" -ReadBudget $budget
        $direct.Status | Should -BeExactly 'OK'
        $direct.Before.Subsystem | Should -BeExactly 'GUI'
        (Read-AUFile "$win\Temp\au-test-$([guid]::NewGuid().ToString('N')).exe" -ReadBudget $budget).Status | Should -BeExactly 'Skipped'
        (Read-AUFile "$win\System32\Tasks\au-test-$([guid]::NewGuid().ToString('N')).exe" -ReadBudget $budget).Status | Should -BeExactly 'Skipped'
        $budget.Skipped | Should -Be 2
        $budget.Runspace | Should -BeNullOrEmpty
    }
    It 'defaults to a 5-second timeout per file and a 120-second total' {
        $budget = New-AUReadBudget
        $budget.TimeoutMs | Should -Be 5000
        $budget.RemainingMs | Should -Be 120000
    }

    It 'reads a user-writable file in a runspace, reuses the runspace, and verifies the build' {
        Test-AUDirectRead $script:Path | Should -BeFalse
        $budget = New-AUReadBudget
        try
        {
            $facts = Get-AUExeFacts $script:Path $script:Info @{} @{} $script:TestSid -ReadBudget $budget
            $facts.FactsVerified | Should -BeTrue
            $facts.Subsystem | Should -BeExactly 'GUI'
            $runspace = $budget.Runspace
            $runspace | Should -Not -BeNullOrEmpty
            (Get-AUExeFacts $script:Path $script:Info @{} @{} $script:TestSid -ReadBudget $budget).FactsVerified | Should -BeTrue
            [object]::ReferenceEquals($budget.Runspace, $runspace) | Should -BeTrue
            $budget.Reads | Should -Be 2
            $budget.RemainingMs | Should -BeLessThan 120000
        }
        finally { Close-AUReadBudget $budget }
        $budget.Runspace | Should -BeNullOrEmpty
    }

    It 'gives up on a slow read after the per-file timeout: unverified, no evidence, logged, runspace let go' {
        Mock Get-AUFileReadScript { $script:SlowScript }
        $budget = New-AUReadBudget -FileTimeoutSeconds 0.5
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $facts = Get-AUExeFacts $script:Path $script:Info @{} @{} $script:TestSid -ReadBudget $budget
        $timer.Stop()
        $timer.ElapsedMilliseconds | Should -BeLessThan 3000
        $facts.FactsVerified | Should -BeFalse
        $facts.PathEvidence | Should -BeNullOrEmpty
        $facts.RunPath | Should -BeExactly $script:Path
        $budget.TimedOut | Should -Be 1
        $budget.Runspace | Should -BeNullOrEmpty
        Should -Invoke Write-CMTraceLog -ParameterFilter { $Message -match 'took longer than 500 ms' -and $Type -eq 2 }

        # Closing doesn't wait on the stuck read either.
        $timer.Restart()
        Close-AUReadBudget $budget
        $timer.ElapsedMilliseconds | Should -BeLessThan 500
    }

    It 'stops reading user-writable files once the run budget is spent, without waiting' {
        Mock Get-AUFileReadScript { $script:SlowScript }
        $budget = New-AUReadBudget -TotalSeconds 1 -FileTimeoutSeconds 0.4
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $results = @(for ($i = 0; $i -lt 6; $i++) { Get-AUExeFacts $script:Path $script:Info @{} @{} $script:TestSid -ReadBudget $budget })
        $timer.Stop()
        # At most the budget plus the runspace start-ups; never six timeouts.
        $timer.ElapsedMilliseconds | Should -BeLessThan 4000
        $budget.RemainingMs | Should -BeLessOrEqual 0
        $budget.Skipped | Should -BeGreaterThan 0
        ($budget.TimedOut + $budget.Skipped) | Should -Be 6
        $results | ForEach-Object { $_.FactsVerified | Should -BeFalse; $_.PathEvidence | Should -BeNullOrEmpty }
        Should -Invoke Write-CMTraceLog -Times 1 -Exactly -ParameterFilter { $Message -match 'budget is spent' }

        # Once spent, a read returns at once.
        $timer.Restart()
        (Get-AUExeFacts $script:Path $script:Info @{} @{} $script:TestSid -ReadBudget $budget).FactsVerified | Should -BeFalse
        $timer.ElapsedMilliseconds | Should -BeLessThan 300
        Close-AUReadBudget $budget
    }

    It 'leaves a kernel path untranslated when its fingerprint read times out, and keeps it as the observed path' {
        Mock Get-AUFileReadScript { $script:SlowScript }
        Mock Get-AUFixedDrives { @((Get-AULongPath $TestDrive)) }
        $budget = New-AUReadBudget -FileTimeoutSeconds 0.4
        $kernel = '\Device\HarddiskVolume3\Users\alice\AppData\Local\Contoso\app.exe'
        $timer = [Diagnostics.Stopwatch]::StartNew()
        Resolve-AUKernelPath $kernel $script:Info @{} $budget | Should -BeNullOrEmpty
        $found = Find-AUExePath @($kernel) $script:Info @{} $budget
        $timer.ElapsedMilliseconds | Should -BeLessThan 4000
        $found.Path | Should -BeExactly $script:Path
        $found.Verified | Should -BeFalse
        $budget.TimedOut | Should -Be 2
        Close-AUReadBudget $budget
    }

    It 'reads allowlisted paths directly even when the budget is spent' {
        Mock Test-AUDirectRead { $true }
        $budget = New-AUReadBudget -TotalSeconds 0
        (Get-AUExeFacts $script:Path $script:Info @{} @{} $script:TestSid -ReadBudget $budget).FactsVerified | Should -BeTrue
        $budget.Skipped | Should -Be 0
        $budget.Runspace | Should -BeNullOrEmpty
    }
}

Describe 'Get-AUExeFacts' {
    BeforeEach {
        $script:Path = Join-Path (Get-AULongPath $TestDrive) 'Program Files\Contoso\app.exe'
        Remove-Item -Force -Path $script:Path -ErrorAction SilentlyContinue
    }

    It 'returns exactly the Task 5 facts shape (F13)' {
        New-TestPe $script:Path $script:OldBuild 0x10
        $facts = Get-AUExeFacts $script:Path (New-TestExeInfo 'app.exe' $script:OldBuild 0x10) @{} @{} $script:TestSid
        @($facts.PSObject.Properties.Name) | Should -Be $script:FactNames
        $facts.UserSid | Should -BeExactly $script:TestSid
    }

    It 'gives FactsVerified $false and blank build facts for an older ExeInfo taken from a newer file at the same path (F38)' {
        New-TestPe $script:Path $script:OldBuild 0x10
        $old = Get-AUExeFacts $script:Path (New-TestExeInfo 'app.exe' $script:OldBuild 0x10) @{} @{} $script:TestSid
        $old.FactsVerified | Should -BeTrue
        $old.Subsystem | Should -BeExactly 'GUI'

        New-TestPe $script:Path $script:NewBuild 0x20 -Subsystem 3
        $facts = Get-AUExeFacts $script:Path (New-TestExeInfo 'app.exe' $script:OldBuild 0x10) @{} @{} $script:TestSid
        $facts.FactsVerified | Should -BeFalse
        $facts.FileVersion | Should -BeNullOrEmpty
        $facts.FileCompanyName | Should -BeNullOrEmpty
        $facts.FileProductName | Should -BeNullOrEmpty
        $facts.FileDescription | Should -BeNullOrEmpty
        $facts.ProductVersion | Should -BeNullOrEmpty
        $facts.Subsystem | Should -BeNullOrEmpty
        # Path-level facts stay.
        $facts.RunPath | Should -BeExactly $script:Path
        $facts.LocationClass | Should -BeExactly (Get-AULocationClass $script:Path)
        $facts.LocationClass | Should -Not -BeNullOrEmpty
    }

    It 'reads version info, subsystem, and the Installer owner from a verified in-box exe' {
        Copy-Item $script:Notepad $script:Path -Force
        # Read from the copy: a System32 file's version info can come from its MUI file.
        $expected = Get-TestVersionInfo $script:Path
        $msi = @{ $script:Path.ToLowerInvariant() = '{AAAAAAAA-0000-0000-0000-000000000001}' }
        $facts = Get-AUExeFacts $script:Path (Get-TestExeInfoOf $script:Path 'app.exe') $msi @{} $script:TestSid

        $facts.FactsVerified | Should -BeTrue
        $facts.ExeName | Should -BeExactly 'app.exe'
        $facts.FileCompanyName | Should -BeExactly $expected.CompanyName.Trim()
        $facts.FileProductName | Should -BeExactly $expected.ProductName.Trim()
        $facts.FileDescription | Should -BeExactly $expected.FileDescription.Trim()
        $facts.FileVersion | Should -BeExactly $expected.FileVersion.Trim()
        $facts.ProductVersion | Should -BeExactly $expected.ProductVersion.Trim()
        $facts.Subsystem | Should -BeExactly 'GUI'
        $facts.MsiProductCode | Should -BeExactly '{AAAAAAAA-0000-0000-0000-000000000001}'
        $facts.PathEvidence | Should -BeNullOrEmpty
    }

    It 'reads the Console subsystem from a verified where.exe' {
        Copy-Item $script:Where $script:Path -Force
        (Get-AUExeFacts $script:Path (Get-TestExeInfoOf $script:Path 'app.exe') @{} @{} $script:TestSid).Subsystem | Should -BeExactly 'Console'
    }

    It 'gives unverified facts with the second exe''s CompanyName and ProductName as PathEvidence when two in-box exes are copied in turn to one path (D30)' -Skip:(-not (Test-Path (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\ngen.exe'))) {
        Copy-Item $script:Notepad $script:Path -Force
        $first = Get-TestExeInfoOf $script:Path 'app.exe'
        $firstProduct = (Get-TestVersionInfo $script:Path).ProductName
        Copy-Item $script:Ngen $script:Path -Force
        $second = Get-TestVersionInfo $script:Path
        $second.ProductName | Should -Not -Be $firstProduct

        $msi = @{ $script:Path.ToLowerInvariant() = '{AAAAAAAA-0000-0000-0000-000000000001}' }
        $facts = Get-AUExeFacts $script:Path $first $msi @{} $script:TestSid
        $facts.FactsVerified | Should -BeFalse
        $facts.FileCompanyName | Should -BeNullOrEmpty
        $facts.FileProductName | Should -BeNullOrEmpty
        $facts.FileVersion | Should -BeNullOrEmpty
        $facts.Subsystem | Should -BeNullOrEmpty
        $facts.MsiProductCode | Should -BeNullOrEmpty
        $facts.PathEvidence.CompanyName | Should -BeExactly $second.CompanyName.Trim()
        $facts.PathEvidence.ProductName | Should -BeExactly $second.ProductName.Trim()
        @($facts.PathEvidence.PSObject.Properties.Name) | Should -Be @('CompanyName', 'ProductName')

        # The evidence is for identity only: Get-AUIdentityEvidence labels it and gives no versions.
        $evidence = Get-AUIdentityEvidence $facts
        $evidence.Kind | Should -BeExactly 'CurrentFileAtPath'
        @($evidence.Versions).Count | Should -Be 0
    }

    It 'gives no PathEvidence when the file at the path is gone or is not a PE file' {
        $info = New-TestExeInfo 'app.exe' $script:OldBuild 0x10
        (Get-AUExeFacts $script:Path $info @{} @{} $script:TestSid).PathEvidence | Should -BeNullOrEmpty
        [void](New-Item -ItemType Directory -Force -Path (Split-Path $script:Path))
        [IO.File]::WriteAllText($script:Path, 'not a PE file')
        $facts = Get-AUExeFacts $script:Path $info @{} @{} $script:TestSid
        $facts.PathEvidence | Should -BeNullOrEmpty
        $facts.FactsVerified | Should -BeFalse
        $facts.RunPath | Should -BeExactly $script:Path
    }

    It 'is unverified when the file changes while its version info is read' {
        # The direct read, so the mocked file reads below apply.
        Mock Test-AUDirectRead { $true }
        New-TestPe $script:Path $script:OldBuild 0x10
        $info = New-TestExeInfo 'app.exe' $script:OldBuild 0x10
        $script:Reads = 0
        Mock Get-AUPeFingerprint {
            $script:Reads++
            if ($script:Reads -eq 1) { return [pscustomobject]@{ LinkTimeUtc = $script:OldBuild; CheckSum = [uint32]0x10; Subsystem = 'GUI' } }
            return [pscustomobject]@{ LinkTimeUtc = $script:NewBuild; CheckSum = [uint32]0x20; Subsystem = 'GUI' }
        }
        $facts = Get-AUExeFacts $script:Path $info @{} @{} $script:TestSid
        $facts.FactsVerified | Should -BeFalse
        $facts.Subsystem | Should -BeNullOrEmpty
    }

    It 'sets IsServiceBinary from the service map by lowercased path, verified or not' {
        New-TestPe $script:Path $script:OldBuild 0x10
        $services = @{ $script:Path.ToLowerInvariant() = 'ContosoAgent' }
        (Get-AUExeFacts $script:Path (New-TestExeInfo 'app.exe' $script:OldBuild 0x10) @{} $services $script:TestSid).IsServiceBinary | Should -BeTrue
        (Get-AUExeFacts $script:Path (New-TestExeInfo 'app.exe' $script:NewBuild 0x99) @{} $services $script:TestSid).IsServiceBinary | Should -BeTrue
        (Get-AUExeFacts $script:Path (New-TestExeInfo 'app.exe' $script:OldBuild 0x10) @{} @{} $script:TestSid).IsServiceBinary | Should -BeFalse
        (Get-AUExeFacts $script:Path (New-TestExeInfo 'app.exe' $script:OldBuild 0x10) $null $null $script:TestSid).IsServiceBinary | Should -BeFalse
    }

    It 'classifies the run path location' {
        $facts = Get-AUExeFacts 'C:\Users\alice\AppData\Local\Temp\setup.exe' (New-TestExeInfo 'setup.exe' $script:OldBuild 1) @{} @{} $script:TestSid
        $facts.LocationClass | Should -BeExactly 'Temp'
        $facts.FactsVerified | Should -BeFalse
    }

    It 'gives a Package entry its package family and reads no file' {
        Mock Get-AUPeFingerprint { throw 'must not be called' }
        $text = 'Contoso.Notes_1.2.3.0_x64__8wekyb3d8bbwe'
        $facts = Get-AUExeFacts $script:Path (ConvertFrom-AUExeInfo $text) @{} @{} $script:TestSid -ExeInfoText $text
        $facts.ExeName | Should -BeNullOrEmpty
        $facts.RunPath | Should -BeNullOrEmpty
        $facts.PackageFamily | Should -BeExactly 'Contoso.Notes_8wekyb3d8bbwe'
        $facts.FactsVerified | Should -BeFalse
        Should -Invoke Get-AUPeFingerprint -Times 0
    }

    It 'never throws: a failing version read leaves the build unverified and is logged' {
        # The direct read, so the mocked file reads below apply.
        Mock Test-AUDirectRead { $true }
        Mock Write-CMTraceLog { }
        New-TestPe $script:Path $script:OldBuild 0x10
        Mock Get-AUVersionInfo { throw 'boom' }
        $facts = Get-AUExeFacts $script:Path (New-TestExeInfo 'app.exe' $script:OldBuild 0x10) @{} @{} $script:TestSid
        $facts.FactsVerified | Should -BeFalse
        $facts.RunPath | Should -BeExactly $script:Path
        Should -Invoke Write-CMTraceLog -ParameterFilter { $Message -match 'boom' -and $Type -eq 2 }
    }
}

Describe 'ConvertTo-AUPackageFamily' {
    It 'derives the family name from a package full name or a family name with an app ID' {
        ConvertTo-AUPackageFamily 'Microsoft.WindowsCalculator_11.2405.2.0_x64__8wekyb3d8bbwe' | Should -BeExactly 'Microsoft.WindowsCalculator_8wekyb3d8bbwe'
        ConvertTo-AUPackageFamily 'Microsoft.WindowsCalculator_11.2405.2.0_neutral_split.scale-100_8wekyb3d8bbwe' | Should -BeExactly 'Microsoft.WindowsCalculator_8wekyb3d8bbwe'
        ConvertTo-AUPackageFamily 'Microsoft.WindowsCalculator_8wekyb3d8bbwe!App' | Should -BeExactly 'Microsoft.WindowsCalculator_8wekyb3d8bbwe'
    }

    It 'returns $null for a Win32 or Other value' {
        ConvertTo-AUPackageFamily '!!tool.exe!2025/03/04:05:06:07!5150!' | Should -BeNullOrEmpty
        ConvertTo-AUPackageFamily 'C:\Program Files\Contoso\tool.exe' | Should -BeNullOrEmpty
        ConvertTo-AUPackageFamily '' | Should -BeNullOrEmpty
    }
}

Describe 'Get-AUServiceBinaries' {
    BeforeEach {
        Mock Get-AUServiceRecords {
            @(
                [pscustomobject]@{ Name = 'ContosoAgent'; PathName = '"C:\Program Files\Contoso\agent.exe" -k run' }
                [pscustomobject]@{ Name = 'ContosoVpn'; PathName = 'C:\Contoso\vpn.exe /svc' }
                [pscustomobject]@{ Name = 'Netsvc'; PathName = 'C:\WINDOWS\system32\svchost.exe -k netsvcs -p' }
                [pscustomobject]@{ Name = 'NoDll'; PathName = '%SystemRoot%\System32\svchost.exe -k LocalService' }
                [pscustomobject]@{ Name = 'Kernel'; PathName = '\??\C:\Fabrikam\driverhost.exe' }
                [pscustomobject]@{ Name = 'Blank'; PathName = '' }
                [pscustomobject]@{ Name = 'Relative'; PathName = 'agent.exe' }
                [pscustomobject]@{ Name = 'AContosoAgentCopy'; PathName = 'C:\Program Files\Contoso\agent.exe' }
            )
        }
        Mock Get-AUServiceDll { if ($ServiceName -eq 'Netsvc') { 'C:\WINDOWS\System32\NetSvc.dll' } }
    }

    It 'maps quoted and unquoted service paths with arguments stripped, lowercased (F36)' {
        $map = Get-AUServiceBinaries
        $map['c:\contoso\vpn.exe'] | Should -BeExactly 'ContosoVpn'
        @($map.Keys) -ccontains 'c:\program files\contoso\agent.exe' | Should -BeTrue
        @($map.Keys) -ccontains 'c:\contoso\vpn.exe' | Should -BeTrue
    }

    It 'maps an svchost.exe service to its ServiceDll and leaves out one without' {
        $map = Get-AUServiceBinaries
        $map['c:\windows\system32\netsvc.dll'] | Should -BeExactly 'Netsvc'
        $map.ContainsKey('c:\windows\system32\svchost.exe') | Should -BeFalse
        @($map.Values) -contains 'NoDll' | Should -BeFalse
        Should -Invoke Get-AUServiceDll -ParameterFilter { $ServiceName -eq 'NoDll' } -Times 1
    }

    It 'strips the \??\ prefix and skips blank and relative paths' {
        $map = Get-AUServiceBinaries
        $map['c:\fabrikam\driverhost.exe'] | Should -BeExactly 'Kernel'
        @($map.Values) -contains 'Blank' | Should -BeFalse
        @($map.Values) -contains 'Relative' | Should -BeFalse
    }

    It 'keeps the first service by name when two run the same file' {
        (Get-AUServiceBinaries)['c:\program files\contoso\agent.exe'] | Should -BeExactly 'AContosoAgentCopy'
    }

    It 'returns an empty map and logs when the service list cannot be read' {
        Mock Write-CMTraceLog { }
        Mock Get-AUServiceRecords { throw 'WMI is broken' }
        $map = Get-AUServiceBinaries
        $map.Count | Should -Be 0
        Should -Invoke Write-CMTraceLog -ParameterFilter { $Message -match 'WMI is broken' -and $Type -eq 2 }
    }

    It 'leaves out an svchost.exe service whose ServiceDll read fails' {
        Mock Get-AUServiceDll { throw 'denied' }
        $map = Get-AUServiceBinaries
        @($map.Values) -contains 'Netsvc' | Should -BeFalse
        $map['c:\contoso\vpn.exe'] | Should -BeExactly 'ContosoVpn'
    }
}

Describe 'Get-AUServiceDll' {
    It 'reads this machine''s Parameters\ServiceDll for an svchost.exe service, expanded' {
        $dll = Get-AUServiceDll 'Schedule'
        $dll | Should -Match '^[A-Za-z]:\\.+\.dll$'
        $dll | Should -Not -Match '%'
    }

    It 'returns $null for a service with no ServiceDll or a name with a backslash' {
        Get-AUServiceDll "NoSuchService_$([guid]::NewGuid().ToString('N'))" | Should -BeNullOrEmpty
        Get-AUServiceDll 'Schedule\..\Schedule' | Should -BeNullOrEmpty
    }
}
