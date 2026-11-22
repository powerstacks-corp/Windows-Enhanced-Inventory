BeforeAll { . "$PSScriptRoot\_Import.ps1" }

# Should -Be on datetimes compares ticks only, so every test also asserts Kind (F61).

Describe 'ConvertFrom-AUFileTime' {
    It 'converts a FILETIME to a Utc date' {
        $ft = ConvertFrom-AUFileTime ([datetime]::new(2026, 11, 1, 6, 30, 0, [DateTimeKind]::Utc).ToFileTimeUtc())
        $ft.ToString('o') | Should -Be '2026-11-01T06:30:00.0000000Z'
        $ft.Kind | Should -Be 'Utc'
    }

    It 'returns null for 0 without throwing' {
        { ConvertFrom-AUFileTime 0 } | Should -Not -Throw
        ConvertFrom-AUFileTime 0 | Should -BeNullOrEmpty
    }

    It 'returns null for a negative value' {
        ConvertFrom-AUFileTime -1 | Should -BeNullOrEmpty
    }

    It 'returns null for a value past the last representable date' {
        { ConvertFrom-AUFileTime ([long]::MaxValue) } | Should -Not -Throw
        ConvertFrom-AUFileTime ([long]::MaxValue) | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-AUOleDate' {
    It 'treats the OLE date as UTC' {
        $d = ConvertFrom-AUOleDate 46327.25
        $d.ToString('o') | Should -Be '2026-11-01T06:00:00.0000000Z'
        $d.Kind | Should -Be 'Utc'
    }

    It 'returns null for 0 without throwing' {
        { ConvertFrom-AUOleDate 0 } | Should -Not -Throw
        ConvertFrom-AUOleDate 0 | Should -BeNullOrEmpty
    }

    It 'returns null for an out-of-range or non-finite value' {
        ConvertFrom-AUOleDate 1e10 | Should -BeNullOrEmpty
        ConvertFrom-AUOleDate ([double]::NaN) | Should -BeNullOrEmpty
        ConvertFrom-AUOleDate ([double]::PositiveInfinity) | Should -BeNullOrEmpty
    }
}

Describe 'Format-AUDate' {
    It 'formats a Utc date as yyyy-MM-ddTHH:mm:ss.fffffffZ' {
        Format-AUDate ([datetime]::new(2026, 11, 1, 6, 30, 0, [DateTimeKind]::Utc)) | Should -Be '2026-11-01T06:30:00.0000000Z'
    }

    It 'keeps all seven fraction digits' {
        $d = [datetime]::new(2026, 11, 1, 6, 30, 0, [DateTimeKind]::Utc).AddTicks(1234567)
        Format-AUDate $d | Should -Be '2026-11-01T06:30:00.1234567Z'
    }

    It 'formats the same under a culture with other separators and calendar' {
        $saved = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::new('th-TH')
            Format-AUDate ([datetime]::new(2026, 11, 1, 6, 30, 0, [DateTimeKind]::Utc)) | Should -Be '2026-11-01T06:30:00.0000000Z'
        }
        finally {
            [Threading.Thread]::CurrentThread.CurrentCulture = $saved
        }
    }

    It 'throws on a Local date' {
        { Format-AUDate ([datetime]::new(2026, 11, 1, 6, 30, 0, [DateTimeKind]::Local)) } | Should -Throw
    }

    It 'throws on an Unspecified date' {
        { Format-AUDate ([datetime]::new(2026, 11, 1, 6, 30, 0, [DateTimeKind]::Unspecified)) } | Should -Throw
    }

    It 'round-trips a converted FILETIME' {
        $ft = [datetime]::new(2026, 11, 1, 6, 30, 0, [DateTimeKind]::Utc).ToFileTimeUtc()
        Format-AUDate (ConvertFrom-AUFileTime $ft) | Should -Be '2026-11-01T06:30:00.0000000Z'
    }
}
