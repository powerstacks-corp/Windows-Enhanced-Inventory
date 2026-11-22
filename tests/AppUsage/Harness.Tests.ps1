BeforeAll {
    $ScriptText = [IO.File]::ReadAllText((Resolve-Path (Join-Path $PSScriptRoot '..\..\Intune_Windows_Inventory.ps1')).Path, [Text.Encoding]::UTF8)
}

Describe 'APPUSAGE region harness' {
    It 'has each region marker exactly once' {
        ([regex]::Matches($ScriptText, '(?m)^#region APPUSAGE\r?$')).Count | Should -Be 1
        ([regex]::Matches($ScriptText, '(?m)^#endregion APPUSAGE\r?$')).Count | Should -Be 1
    }

    It 'places the region before the script body' {
        $ScriptText.IndexOf('#endregion APPUSAGE') | Should -BeLessThan $ScriptText.IndexOf('#region script')
    }

    It 'loads the region without defining the settings' {
        Remove-Variable CollectAppMetering -ErrorAction SilentlyContinue
        . "$PSScriptRoot\_Import.ps1"
        Get-Variable CollectAppMetering -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'keeps the region ASCII so Windows PowerShell 5.1 reads it the same with or without a BOM' {
        . "$PSScriptRoot\_Import.ps1"
        $bad = @($AURegionText.ToCharArray() | Where-Object { [int]$_ -gt 127 })
        $bad.Count | Should -Be 0
    }

    It 'parses as a whole script with no syntax errors' {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($ScriptText, [ref]$null, [ref]$errors)
        @($errors).Count | Should -Be 0
    }

    It 'defaults App Usage off with the spec settings' {
        $ScriptText | Should -Match '(?m)^\$CollectAppMetering = \$false\b'
        $ScriptText | Should -Match '(?m)^\$MinFocusSecondsForUse = 1\b'
        $ScriptText | Should -Match "(?m)^\`$AppUsageCustomerMappingsPath = 'C:\\ProgramData\\PowerStacks\\AppUsage\\customer-mappings\.json'"
    }
}
