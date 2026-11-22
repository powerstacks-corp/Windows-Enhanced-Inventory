BeforeAll { . "$PSScriptRoot\_Import.ps1" }

Describe 'ConvertFrom-AUExeInfo' {
    Context 'Win32 fingerprint' {
        BeforeAll {
            $r = ConvertFrom-AUExeInfo '!!schtasks.exe!2094/07/13:03:16:52!4a9a3!'
        }

        It 'is Kind Win32' {
            $r.Kind | Should -Be 'Win32'
        }

        It 'returns the exe name' {
            $r.ExeName | Should -Be 'schtasks.exe'
        }

        It 'returns the PE link time as a Utc date' {
            $r.LinkTimeUtc | Should -Be ([datetime]::new(2094, 7, 13, 3, 16, 52, [DateTimeKind]::Utc))
            # Should -Be on datetimes compares ticks only, so assert Kind separately (F61).
            $r.LinkTimeUtc.Kind | Should -Be 'Utc'
        }

        It 'returns the PE CheckSum as a uint32' {
            $r.CheckSum | Should -Be 0x4a9a3
            $r.CheckSum | Should -BeOfType [uint32]
        }
    }

    It 'lowercases the exe name' {
        (ConvertFrom-AUExeInfo '!!ProbeOnE.exe!2026/11/20:01:08:02!0!').ExeName | Should -Be 'probeone.exe'
    }

    It 'keeps a zero CheckSum as 0, not null' {
        $r = ConvertFrom-AUExeInfo '!!ProbeOnE.exe!2026/11/20:01:08:02!0!'
        $r.CheckSum | Should -Be 0
        $r.CheckSum | Should -BeOfType [uint32]
        $r.LinkTimeUtc | Should -Be ([datetime]::new(2026, 11, 20, 1, 8, 2, [DateTimeKind]::Utc))
        $r.LinkTimeUtc.Kind | Should -Be 'Utc'
    }

    It 'reads the largest CheckSum without overflow' {
        (ConvertFrom-AUExeInfo '!!a.exe!2026/11/20:01:08:02!FFFFFFFF!').CheckSum | Should -Be ([uint32]::MaxValue)
    }

    It 'returns null link time and CheckSum when those fields do not parse' {
        $r = ConvertFrom-AUExeInfo '!!a.exe!2026/13/40:99:00:00!xyz!'
        $r.Kind | Should -Be 'Win32'
        $r.ExeName | Should -Be 'a.exe'
        $r.LinkTimeUtc | Should -BeNullOrEmpty
        $r.CheckSum | Should -BeNullOrEmpty
    }

    It 'classifies a package full name as Package' {
        (ConvertFrom-AUExeInfo 'Microsoft.WindowsCalculator_11.2405.2.0_x64__8wekyb3d8bbwe').Kind | Should -Be 'Package'
    }

    It 'classifies a package family name with an app ID as Package' {
        (ConvertFrom-AUExeInfo 'Microsoft.WindowsCalculator_8wekyb3d8bbwe!App').Kind | Should -Be 'Package'
    }

    It 'gives a Package no exe name, link time, or CheckSum' {
        $r = ConvertFrom-AUExeInfo 'Microsoft.WindowsCalculator_11.2405.2.0_x64__8wekyb3d8bbwe'
        $r.ExeName | Should -BeNullOrEmpty
        $r.LinkTimeUtc | Should -BeNullOrEmpty
        $r.CheckSum | Should -BeNullOrEmpty
    }

    It 'classifies an empty value as Other with no exe name' {
        $r = ConvertFrom-AUExeInfo ''
        $r.Kind | Should -Be 'Other'
        $r.ExeName | Should -BeNullOrEmpty
    }

    It 'classifies a null value as Other' {
        (ConvertFrom-AUExeInfo $null).Kind | Should -Be 'Other'
    }

    It 'classifies a kernel path as Other and takes the lowercase file name' {
        $r = ConvertFrom-AUExeInfo '\Device\HarddiskVolume3\Windows\System32\SvcHost.exe'
        $r.Kind | Should -Be 'Other'
        $r.ExeName | Should -Be 'svchost.exe'
        $r.LinkTimeUtc | Should -BeNullOrEmpty
        $r.CheckSum | Should -BeNullOrEmpty
    }

    It 'classifies a plain name as Other and lowercases it' {
        (ConvertFrom-AUExeInfo 'System').ExeName | Should -Be 'system'
    }
}
