BeforeAll {
    . "$PSScriptRoot\_Import.ps1"
    $Fixtures = Join-Path $PSScriptRoot 'fixtures'
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $ReservedIds = @('ps-resolve-path', 'ps-resolve-msi', 'ps-resolve-publisher', 'ps-resolve-product', 'ps-resolve-version', 'ps-resolve-arch', 'ps-resolve-scope')

    function Read-TestText([string]$Name) { [IO.File]::ReadAllText((Join-Path $Fixtures $Name)) }
    function Read-TestJson([string]$Name) { Read-TestText $Name | ConvertFrom-Json }

    # Base64 of GZip-compressed UTF-8 JSON, the embedded form the release build writes.
    function ConvertTo-TestEmbedded([string]$Json)
    {
        $Bytes = [Text.Encoding]::UTF8.GetBytes($Json)
        $Out = New-Object IO.MemoryStream
        $Zip = New-Object IO.Compression.GZipStream($Out, [IO.Compression.CompressionMode]::Compress)
        $Zip.Write($Bytes, 0, $Bytes.Length)
        $Zip.Dispose()
        return [Convert]::ToBase64String($Out.ToArray())
    }

    function Get-TestFileState([string]$Path)
    {
        $Item = Get-Item -LiteralPath $Path
        return [pscustomobject]@{
            Hash     = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
            Written  = $Item.LastWriteTimeUtc
            Created  = $Item.CreationTimeUtc
        }
    }

    function New-TestDir([string]$Name)
    {
        $Dir = Join-Path 'TestDrive:\' $Name
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        return (Resolve-Path $Dir).ProviderPath
    }

    function Copy-TestFixture([string]$Name, [string]$Dir, [string]$As)
    {
        $Target = Join-Path $Dir $As
        Copy-Item -LiteralPath (Join-Path $Fixtures $Name) -Destination $Target
        return $Target
    }
}

Describe 'Test-AUMappings' {
    It 'returns no errors for a valid PowerStacks file' {
        $e = Test-AUMappings (Read-TestJson 'mappings-powerstacks-valid.json') -Kind PowerStacks
        $e.Count | Should -Be 0
    }

    It 'returns no errors for a valid customer file' {
        $e = Test-AUMappings (Read-TestJson 'mappings-customer-valid.json') -Kind Customer
        $e.Count | Should -Be 0
    }

    It 'returns no errors for the shipped powerstacks-mappings.json' {
        $m = [IO.File]::ReadAllText((Join-Path $RepoRoot 'powerstacks-mappings.json')) | ConvertFrom-Json
        $e = Test-AUMappings $m -Kind PowerStacks
        $e | Should -BeNullOrEmpty
        $e.Count | Should -Be 0
    }

    It 'returns no errors for customer-mappings.example.json' {
        $m = [IO.File]::ReadAllText((Join-Path $RepoRoot 'customer-mappings.example.json')) | ConvertFrom-Json
        $e = Test-AUMappings $m -Kind Customer
        $e | Should -BeNullOrEmpty
        $e.Count | Should -Be 0
    }

    It 'returns an error naming the rule when an identity rule has no publisher' {
        $e = Test-AUMappings (Read-TestJson 'mappings-customer-invalid-rule.json') -Kind Customer
        $e.Count | Should -Be 1
        $e[0] | Should -Match "c-no-publisher"
        $e[0] | Should -Match 'publisher'
    }

    It 'accepts an empty publisher' {
        $m = Read-TestJson 'mappings-customer-valid.json'
        $m.customer.identityRules[0].when.publisher | Should -Be ''
        $e = Test-AUMappings $m -Kind Customer
        $e.Count | Should -Be 0
    }

    It 'rejects a null publisher' {
        $m = Read-TestJson 'mappings-customer-valid.json'
        $m.customer.identityRules[0].when.publisher = $null
        $e = Test-AUMappings $m -Kind Customer
        $e.Count | Should -Be 1
        $e[0] | Should -Match 'c-timesheets-1'
    }

    It 'returns the duplicate-specific error naming an ID used twice in one file' {
        $m = Read-TestJson 'mappings-customer-valid.json'
        $m.customer.classificationRules[1].id = 'c-class-updater'
        $e = Test-AUMappings $m -Kind Customer
        $e.Count | Should -Be 1
        $e[0] | Should -Match "duplicate rule ID 'c-class-updater'"
    }

    It 'treats IDs that differ only in case as duplicates' {
        $m = Read-TestJson 'mappings-powerstacks-valid.json'
        $m.powerStacks.classificationRules[1].id = 'ps-OWN-msi'
        $e = Test-AUMappings $m -Kind PowerStacks
        @($e | Where-Object { $_ -match 'duplicate rule ID' }).Count | Should -Be 1
    }

    It 'rejects a customer rule ID without the c- prefix' {
        $m = Read-TestJson 'mappings-customer-valid.json'
        $m.customer.identityRules[0].id = 'timesheets-1'
        $e = Test-AUMappings $m -Kind Customer
        $e.Count | Should -Be 1
        $e[0] | Should -Match "'timesheets-1'.*c-"
    }

    It 'rejects a PowerStacks rule ID without the ps- prefix' {
        $m = Read-TestJson 'mappings-powerstacks-valid.json'
        $m.powerStacks.identityRules[1].id = 'c-7zip-1'
        $e = Test-AUMappings $m -Kind PowerStacks
        $e.Count | Should -Be 1
        $e[0] | Should -Match "'c-7zip-1'.*ps-"
    }

    It 'rejects a reserved ps-resolve- ID in a PowerStacks file' {
        $m = Read-TestJson 'mappings-powerstacks-valid.json'
        $m.powerStacks.identityRules[1].id = 'ps-resolve-path'
        $e = Test-AUMappings $m -Kind PowerStacks
        $e.Count | Should -Be 1
        $e[0] | Should -Match "'ps-resolve-path'.*reserved"
    }

    It 'rejects a reserved ps-resolve- ID in a customer file' {
        $m = Read-TestJson 'mappings-customer-valid.json'
        $m.customer.identityRules[0].id = 'ps-resolve-custom'
        $e = Test-AUMappings $m -Kind Customer
        @($e | Where-Object { $_ -match "'ps-resolve-custom'.*reserved" }).Count | Should -Be 1
    }

    It 'rejects a customer section in a PowerStacks file' {
        $m = Read-TestJson 'mappings-powerstacks-valid.json'
        $m | Add-Member -NotePropertyName customer -NotePropertyValue ([pscustomobject]@{ identityRules = @(); classificationRules = @() })
        $e = Test-AUMappings $m -Kind PowerStacks
        $e.Count | Should -Be 1
        $e[0] | Should -Match "'customer'"
    }

    It 'rejects a powerStacks section in a customer file' {
        $m = Read-TestJson 'mappings-customer-valid.json'
        $m | Add-Member -NotePropertyName powerStacks -NotePropertyValue ([pscustomobject]@{ version = '1'; identityRules = @(); classificationRules = @() })
        $e = Test-AUMappings $m -Kind Customer
        $e.Count | Should -Be 1
        $e[0] | Should -Match "'powerStacks'"
    }

    It 'rejects a file with no section for its kind' {
        $m = '{ "schemaVersion": 1 }' | ConvertFrom-Json
        (Test-AUMappings $m -Kind Customer).Count | Should -Be 1
        (Test-AUMappings $m -Kind PowerStacks).Count | Should -Be 1
    }

    It 'rejects a classification rule placed in identityRules' {
        $m = Read-TestJson 'mappings-customer-valid.json'
        $m.customer.identityRules += $m.customer.classificationRules[0]
        $m.customer.classificationRules = @($m.customer.classificationRules[1])
        $e = Test-AUMappings $m -Kind Customer
        $e.Count | Should -Be 1
        $e[0] | Should -Match "'c-class-updater'.*classificationRules"
    }

    It 'rejects an identity rule placed in classificationRules' {
        $m = Read-TestJson 'mappings-powerstacks-valid.json'
        $m.powerStacks.classificationRules += $m.powerStacks.identityRules[2]
        $m.powerStacks.identityRules = @($m.powerStacks.identityRules[0], $m.powerStacks.identityRules[1])
        $e = Test-AUMappings $m -Kind PowerStacks
        $e.Count | Should -Be 1
        $e[0] | Should -Match "'ps-arp-compare'.*identityRules"
    }

    It 'rejects schemaVersion other than 1' {
        $m = Read-TestJson 'mappings-customer-valid.json'
        $m.schemaVersion = 2
        (Test-AUMappings $m -Kind Customer).Count | Should -Be 1
    }

    It 'requires the PowerStacks version' {
        $m = Read-TestJson 'mappings-powerstacks-valid.json'
        $m.powerStacks.version = ''
        $e = Test-AUMappings $m -Kind PowerStacks
        $e.Count | Should -Be 1
        $e[0] | Should -Match 'version'
    }

    It 'rejects an unknown rule type' {
        $m = Read-TestJson 'mappings-customer-valid.json'
        $m.customer.identityRules[0].type = 'regex'
        $e = Test-AUMappings $m -Kind Customer
        $e.Count | Should -Be 1
        $e[0] | Should -Match 'c-timesheets-1'
    }

    It 'rejects an ownership source other than msi or store' {
        $m = Read-TestJson 'mappings-powerstacks-valid.json'
        $m.powerStacks.identityRules[0].source = 'arp'
        $e = Test-AUMappings $m -Kind PowerStacks
        $e.Count | Should -Be 1
        $e[0] | Should -Match 'ps-own-msi'
    }

    It 'rejects extra fields on an arpCompare rule' {
        $m = Read-TestJson 'mappings-powerstacks-valid.json'
        $m.powerStacks.identityRules[2] | Add-Member -NotePropertyName source -NotePropertyValue 'msi'
        $e = Test-AUMappings $m -Kind PowerStacks
        $e.Count | Should -Be 1
        $e[0] | Should -Match "'ps-arp-compare'.*'source'"
    }

    It 'rejects a misspelled condition key, which would otherwise widen the rule' {
        $m = Read-TestJson 'mappings-customer-valid.json'
        $m.customer.classificationRules[1].when | Add-Member -NotePropertyName exeNmae -NotePropertyValue 'x.exe'
        $e = Test-AUMappings $m -Kind Customer
        $e.Count | Should -Be 1
        $e[0] | Should -Match "'c-ignore-kiosk'.*'exeNmae'"
    }

    It 'rejects a classification rule with no condition' {
        $m = Read-TestJson 'mappings-customer-valid.json'
        $m.customer.classificationRules[1].when = [pscustomobject]@{}
        $e = Test-AUMappings $m -Kind Customer
        $e.Count | Should -Be 1
        $e[0] | Should -Match 'c-ignore-kiosk'
    }

    It 'rejects an unknown role and an unknown location class' {
        $m = Read-TestJson 'mappings-customer-valid.json'
        $m.customer.classificationRules[0].role = 'System'
        $m.customer.classificationRules[1].when.locationClass = 'ProgramFile'
        $e = Test-AUMappings $m -Kind Customer
        $e.Count | Should -Be 2
        $e[0] | Should -Match "c-class-updater.*'System'"
        $e[1] | Should -Match "c-ignore-kiosk.*'ProgramFile'"
    }

    It 'rejects a role on an ignore rule' {
        $m = Read-TestJson 'mappings-customer-valid.json'
        $m.customer.classificationRules[1] | Add-Member -NotePropertyName role -NotePropertyValue 'Helper'
        (Test-AUMappings $m -Kind Customer).Count | Should -Be 1
    }

    It 'rejects a pattern that is not a valid wildcard' {
        $m = Read-TestJson 'mappings-customer-valid.json'
        $m.customer.identityRules[0].target.displayName = 'Contoso [Time'
        $e = Test-AUMappings $m -Kind Customer
        $e.Count | Should -Be 1
        $e[0] | Should -Match 'c-timesheets-1'
    }

    It 'rejects a version that is not numeric and a range whose minimum is above its maximum' {
        $m = Read-TestJson 'mappings-customer-valid.json'
        $m.customer.identityRules[0].when.versionMin = 'two'
        (Test-AUMappings $m -Kind Customer).Count | Should -Be 1
        $m.customer.identityRules[0].when.versionMin = '3.0'
        $e = Test-AUMappings $m -Kind Customer
        $e.Count | Should -Be 1
        $e[0] | Should -Match 'versionMin'
    }

    It 'rejects a non-string condition value' {
        $m = Read-TestJson 'mappings-customer-valid.json'
        $m.customer.identityRules[0].when.exeName = 5
        (Test-AUMappings $m -Kind Customer).Count | Should -Be 1
    }

    It 'names the position of a rule that has no ID' {
        $m = Read-TestJson 'mappings-customer-valid.json'
        $m.customer.classificationRules[0].PSObject.Properties.Remove('id')
        $e = Test-AUMappings $m -Kind Customer
        $e.Count | Should -Be 1
        $e[0] | Should -Match 'classificationRules\[0\]'
    }

    It 'returns an error, not a throw, for input that is not a mappings object' {
        { Test-AUMappings $null -Kind Customer } | Should -Not -Throw
        (Test-AUMappings $null -Kind Customer).Count | Should -Be 1
        (Test-AUMappings 'text' -Kind Customer).Count | Should -Be 1
        $m = '{ "schemaVersion": 1, "customer": { "identityRules": "x", "classificationRules": [ 5 ] } }' | ConvertFrom-Json
        (Test-AUMappings $m -Kind Customer).Count | Should -Be 2
    }

    It 'validates the merged form with both sections' {
        $Dir = New-TestDir 'merged'
        Copy-TestFixture 'mappings-powerstacks-valid.json' $Dir 'powerstacks-mappings.json' | Out-Null
        $Cust = Copy-TestFixture 'mappings-customer-valid.json' $Dir 'customer-mappings.json'
        $r = Get-AUMappings -Embedded '' -BesideDir $Dir -CustomerPath $Cust
        (Test-AUMappings $r.Mappings -Kind Merged).Count | Should -Be 0
        $r.Mappings.customer.identityRules[0].id = 'ps-7zip-1'
        @(Test-AUMappings $r.Mappings -Kind Merged | Where-Object { $_ -match 'duplicate' }).Count | Should -Be 1
    }
}

Describe 'Get-AUMappings' {
    BeforeAll {
        $Absent = Join-Path (New-TestDir 'nothing') 'customer-mappings.json'
    }

    It 'returns one object and nothing else on the pipeline' {
        $Dir = New-TestDir 'pipeline'
        Copy-TestFixture 'mappings-powerstacks-valid.json' $Dir 'powerstacks-mappings.json' | Out-Null
        $Cust = Copy-TestFixture 'mappings-customer-invalid-rule.json' $Dir 'customer-mappings.json'
        $Out = @(Get-AUMappings -Embedded '' -BesideDir $Dir -CustomerPath $Cust)
        $Out.Count | Should -Be 1
        $Out[0].Source | Should -Be 'Beside'
    }

    It 'always holds the 7 reserved ps-resolve IDs, even with Source None' {
        $r = Get-AUMappings -Embedded '' -BesideDir '' -CustomerPath $Absent
        $r.Source | Should -Be 'None'
        foreach ($Id in $ReservedIds) { $r.RuleIds.Contains($Id) | Should -BeTrue }
        $r.RuleIds.Count | Should -Be 7
    }

    It 'holds the reserved IDs plus every rule ID when both files are used' {
        $Dir = New-TestDir 'ids'
        Copy-TestFixture 'mappings-powerstacks-valid.json' $Dir 'powerstacks-mappings.json' | Out-Null
        $Cust = Copy-TestFixture 'mappings-customer-valid.json' $Dir 'customer-mappings.json'
        $r = Get-AUMappings -Embedded '' -BesideDir $Dir -CustomerPath $Cust
        foreach ($Id in $ReservedIds) { $r.RuleIds.Contains($Id) | Should -BeTrue }
        foreach ($Id in 'ps-own-msi', 'ps-7zip-1', 'ps-arp-compare', 'ps-class-windows', 'ps-ignore-noise', 'c-timesheets-1', 'c-class-updater', 'c-ignore-kiosk') { $r.RuleIds.Contains($Id) | Should -BeTrue }
        $r.RuleIds.Count | Should -Be 15
        $r.RuleIds.Contains('PS-OWN-MSI') | Should -BeTrue
    }

    It 'uses valid embedded text over a beside file' {
        $Dir = New-TestDir 'embedwins'
        Copy-TestFixture 'mappings-powerstacks-other.json' $Dir 'powerstacks-mappings.json' | Out-Null
        $r = Get-AUMappings -Embedded (ConvertTo-TestEmbedded (Read-TestText 'mappings-powerstacks-valid.json')) -BesideDir $Dir -CustomerPath $Absent
        $r.Source | Should -Be 'Embedded'
        $r.PowerStacksVersion | Should -Be '2026.11.22.1'
        $r.Mappings.powerStacks.identityRules.Count | Should -Be 3
        $r.Errors.Count | Should -Be 0
    }

    It 'uses the beside powerstacks-mappings.json when nothing is embedded' {
        $Dir = New-TestDir 'beside'
        Copy-TestFixture 'mappings-powerstacks-valid.json' $Dir 'powerstacks-mappings.json' | Out-Null
        $r = Get-AUMappings -Embedded '' -BesideDir $Dir -CustomerPath $Absent
        $r.Source | Should -Be 'Beside'
        $r.PowerStacksVersion | Should -Be '2026.11.22.1'
        $r.Mappings.powerStacks.identityRules[1].id | Should -Be 'ps-7zip-1'
        $r.Mappings.powerStacks.classificationRules.Count | Should -Be 2
    }

    It 'gives Source None with no embedded text and no beside file' {
        $r = Get-AUMappings -Embedded $null -BesideDir (New-TestDir 'empty') -CustomerPath $Absent
        $r.Source | Should -Be 'None'
        $r.PowerStacksVersion | Should -Be ''
        $r.Mappings.powerStacks.identityRules.Count | Should -Be 0
        $r.Mappings.powerStacks.classificationRules.Count | Should -Be 0
        $r.Errors.Count | Should -Be 0
    }

    It 'gives Source Embedded, errors, and empty rules for invalid embedded JSON, without throwing' {
        $Dir = New-TestDir 'badembed'
        Copy-TestFixture 'mappings-powerstacks-valid.json' $Dir 'powerstacks-mappings.json' | Out-Null
        foreach ($Embedded in @((ConvertTo-TestEmbedded '{ "schemaVersion": 1, "powerStacks": '), 'not base64 !!', (ConvertTo-TestEmbedded '{ "schemaVersion": 1, "powerStacks": { "version": "1", "identityRules": [ { "id": "ps-x", "type": "identity" } ] } }')))
        {
            { Get-AUMappings -Embedded $Embedded -BesideDir $Dir -CustomerPath $Absent } | Should -Not -Throw
            $r = Get-AUMappings -Embedded $Embedded -BesideDir $Dir -CustomerPath $Absent
            $r.Source | Should -Be 'Embedded'
            $r.Errors.Count | Should -BeGreaterThan 0
            $r.Mappings.powerStacks.identityRules.Count | Should -Be 0
            $r.Mappings.powerStacks.classificationRules.Count | Should -Be 0
            $r.PowerStacksVersion | Should -Be ''
            $r.RuleIds.Count | Should -Be 7
        }
    }

    Context 'customer file' {
        BeforeAll {
            $Ours = ConvertTo-TestEmbedded (Read-TestText 'mappings-powerstacks-valid.json')
        }

        It 'reports Absent, our rules only, and a blank hash when there is no file' {
            $r = Get-AUMappings -Embedded $Ours -BesideDir '' -CustomerPath $Absent
            $r.CustomerSource | Should -Be 'Absent'
            $r.CustomerHash | Should -Be ''
            $r.Mappings.powerStacks.identityRules.Count | Should -Be 3
            $r.Mappings.customer.identityRules.Count | Should -Be 0
            $r.Mappings.customer.classificationRules.Count | Should -Be 0
            $r.Errors.Count | Should -Be 0
        }

        It 'reports Absent for a blank path' {
            (Get-AUMappings -Embedded $Ours -BesideDir '' -CustomerPath '').CustomerSource | Should -Be 'Absent'
        }

        It 'uses a valid file whatever its permissions, and runs no permission check (D45)' {
            $Dir = New-TestDir 'acl'
            $Cust = Copy-TestFixture 'mappings-customer-valid.json' $Dir 'customer-mappings.json'
            $Users = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')
            $Acl = [IO.File]::GetAccessControl($Cust)
            $Acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($Users, 'Write', 'Allow')))
            [IO.File]::SetAccessControl($Cust, $Acl)
            $Granted = @([IO.File]::GetAccessControl($Cust).GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]) |
                Where-Object { $_.IdentityReference -eq $Users -and ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::WriteData) })
            $Granted.Count | Should -BeGreaterThan 0

            Mock Get-Acl { throw 'Get-Acl must not be called' }
            $r = Get-AUMappings -Embedded $Ours -BesideDir '' -CustomerPath $Cust
            $r.CustomerSource | Should -Be 'File'
            $r.Mappings.customer.identityRules[0].id | Should -Be 'c-timesheets-1'
            $r.Mappings.customer.classificationRules.Count | Should -Be 2
            Should -Invoke Get-Acl -Times 0 -Exactly
        }

        It 'sets CustomerHash to the SHA-256 of the file used' {
            $Dir = New-TestDir 'hash'
            $Cust = Copy-TestFixture 'mappings-customer-valid.json' $Dir 'customer-mappings.json'
            $r = Get-AUMappings -Embedded $Ours -BesideDir '' -CustomerPath $Cust
            $r.CustomerHash | Should -Be (Get-FileHash -LiteralPath $Cust -Algorithm SHA256).Hash
        }

        It 'ignores a file over 1 MB as TooLarge' {
            $Dir = New-TestDir 'large'
            $Cust = Join-Path $Dir 'customer-mappings.json'
            $Json = (Read-TestText 'mappings-customer-valid.json').TrimEnd()
            $Pad = 1153434 - [Text.Encoding]::UTF8.GetByteCount($Json)
            [IO.File]::WriteAllText($Cust, $Json + (' ' * $Pad), (New-Object Text.UTF8Encoding($false)))
            (Get-Item -LiteralPath $Cust).Length | Should -BeGreaterThan 1100000
            $r = Get-AUMappings -Embedded $Ours -BesideDir '' -CustomerPath $Cust
            $r.CustomerSource | Should -Be 'TooLarge'
            $r.CustomerHash | Should -Be ''
            $r.Mappings.customer.identityRules.Count | Should -Be 0
            $r.Mappings.powerStacks.identityRules.Count | Should -Be 3
            $r.RuleIds.Contains('c-timesheets-1') | Should -BeFalse
            $r.Errors.Count | Should -BeGreaterThan 0
        }

        It 'uses a valid file of exactly 1 MB' {
            $Dir = New-TestDir 'onemb'
            $Cust = Join-Path $Dir 'customer-mappings.json'
            $Json = (Read-TestText 'mappings-customer-valid.json').TrimEnd()
            $Pad = 1048576 - [Text.Encoding]::UTF8.GetByteCount($Json)
            [IO.File]::WriteAllText($Cust, $Json + (' ' * $Pad), (New-Object Text.UTF8Encoding($false)))
            (Get-Item -LiteralPath $Cust).Length | Should -Be 1048576
            (Get-AUMappings -Embedded $Ours -BesideDir '' -CustomerPath $Cust).CustomerSource | Should -Be 'File'
        }

        It 'ignores invalid JSON as Invalid, keeps our rules, and never throws' {
            $Dir = New-TestDir 'badjson'
            $Cust = Copy-TestFixture 'mappings-customer-bad-json.json' $Dir 'customer-mappings.json'
            { Get-AUMappings -Embedded $Ours -BesideDir '' -CustomerPath $Cust } | Should -Not -Throw
            $r = Get-AUMappings -Embedded $Ours -BesideDir '' -CustomerPath $Cust
            $r.CustomerSource | Should -Be 'Invalid'
            $r.CustomerHash | Should -Be ''
            $r.Mappings.customer.identityRules.Count | Should -Be 0
            $r.Mappings.powerStacks.identityRules.Count | Should -Be 3
            $r.Errors.Count | Should -BeGreaterThan 0
        }

        It 'ignores a file with an invalid rule as Invalid and names the rule in Errors' {
            $Dir = New-TestDir 'badrule'
            $Cust = Copy-TestFixture 'mappings-customer-invalid-rule.json' $Dir 'customer-mappings.json'
            $r = Get-AUMappings -Embedded $Ours -BesideDir '' -CustomerPath $Cust
            $r.CustomerSource | Should -Be 'Invalid'
            $r.CustomerHash | Should -Be ''
            $r.Mappings.customer.identityRules.Count | Should -Be 0
            $r.Mappings.powerStacks.identityRules.Count | Should -Be 3
            $r.RuleIds.Contains('c-no-publisher') | Should -BeFalse
            ($r.Errors -join "`n") | Should -Match 'c-no-publisher'
        }

        It 'reads a file saved as UTF-8 with a BOM or as UTF-16 (the Windows PowerShell Out-File default)' {
            $Dir = New-TestDir 'encodings'
            $Json = Read-TestText 'mappings-customer-valid.json'
            $Bom = Join-Path $Dir 'utf8bom.json'
            [IO.File]::WriteAllText($Bom, $Json, (New-Object Text.UTF8Encoding($true)))
            $Wide = Join-Path $Dir 'utf16.json'
            [IO.File]::WriteAllText($Wide, $Json, [Text.Encoding]::Unicode)
            (Get-AUMappings -Embedded $Ours -BesideDir '' -CustomerPath $Bom).CustomerSource | Should -Be 'File'
            $r = Get-AUMappings -Embedded $Ours -BesideDir '' -CustomerPath $Wide
            $r.CustomerSource | Should -Be 'File'
            $r.CustomerHash | Should -Be (Get-FileHash -LiteralPath $Wide -Algorithm SHA256).Hash
        }

        It 'never writes to the customer file or its folder' {
            $Dir = New-TestDir 'readonly'
            $Cust = Copy-TestFixture 'mappings-customer-valid.json' $Dir 'customer-mappings.json'
            $Bad = Copy-TestFixture 'mappings-customer-invalid-rule.json' $Dir 'customer-invalid.json'
            $Before = Get-TestFileState $Cust
            $BadBefore = Get-TestFileState $Bad
            $DirBefore = (Get-Item -LiteralPath $Dir).LastWriteTimeUtc
            $NamesBefore = (Get-ChildItem -LiteralPath $Dir -Force | Sort-Object Name | ForEach-Object Name) -join '|'
            Start-Sleep -Milliseconds 50

            Get-AUMappings -Embedded $Ours -BesideDir '' -CustomerPath $Cust | Out-Null
            Get-AUMappings -Embedded $Ours -BesideDir '' -CustomerPath $Bad | Out-Null

            $After = Get-TestFileState $Cust
            $After.Hash | Should -Be $Before.Hash
            $After.Written | Should -Be $Before.Written
            $After.Created | Should -Be $Before.Created
            $BadAfter = Get-TestFileState $Bad
            $BadAfter.Hash | Should -Be $BadBefore.Hash
            $BadAfter.Written | Should -Be $BadBefore.Written
            $BadAfter.Created | Should -Be $BadBefore.Created
            (Get-Item -LiteralPath $Dir).LastWriteTimeUtc | Should -Be $DirBefore
            ((Get-ChildItem -LiteralPath $Dir -Force | Sort-Object Name | ForEach-Object Name) -join '|') | Should -Be $NamesBefore
        }

        It 'keeps the same CustomerHash when only our rules change' {
            $Dir = New-TestDir 'stablehash'
            $Cust = Copy-TestFixture 'mappings-customer-valid.json' $Dir 'customer-mappings.json'
            $One = Get-AUMappings -Embedded $Ours -BesideDir '' -CustomerPath $Cust
            $Two = Get-AUMappings -Embedded (ConvertTo-TestEmbedded (Read-TestText 'mappings-powerstacks-other.json')) -BesideDir '' -CustomerPath $Cust
            $One.PowerStacksVersion | Should -Not -Be $Two.PowerStacksVersion
            $One.CustomerHash | Should -Not -BeNullOrEmpty
            $Two.CustomerHash | Should -Be $One.CustomerHash
        }

        It 'merges the customer rules alongside ours' {
            $Dir = New-TestDir 'merge'
            $Cust = Copy-TestFixture 'mappings-customer-valid.json' $Dir 'customer-mappings.json'
            $r = Get-AUMappings -Embedded $Ours -BesideDir '' -CustomerPath $Cust
            $r.Mappings.schemaVersion | Should -Be 1
            $r.Mappings.powerStacks.version | Should -Be '2026.11.22.1'
            $r.Mappings.powerStacks.identityRules.Count | Should -Be 3
            $r.Mappings.customer.identityRules.Count | Should -Be 1
            $r.Mappings.customer.classificationRules.Count | Should -Be 2
        }
    }
}

Describe 'Test-AppUsageMappings.ps1' {
    BeforeAll {
        $Validator = Join-Path $RepoRoot 'Test-AppUsageMappings.ps1'
        function Invoke-Validator([string[]]$Arguments)
        {
            $Output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Validator @Arguments 2>&1
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($Output | Out-String) }
        }
    }

    It 'exits 0 for a valid file and leaves it unchanged' {
        $Dir = New-TestDir 'validator-ok'
        $Cust = Copy-TestFixture 'mappings-customer-valid.json' $Dir 'customer-mappings.json'
        $Before = Get-TestFileState $Cust
        $r = Invoke-Validator @('-Path', $Cust)
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match $Before.Hash
        $After = Get-TestFileState $Cust
        $After.Hash | Should -Be $Before.Hash
        $After.Written | Should -Be $Before.Written
        $After.Created | Should -Be $Before.Created
    }

    It 'exits 1 for an invalid file, prints the rule ID, and leaves it unchanged' {
        $Dir = New-TestDir 'validator-bad'
        $Cust = Copy-TestFixture 'mappings-customer-invalid-rule.json' $Dir 'customer-mappings.json'
        $Before = Get-TestFileState $Cust
        $r = Invoke-Validator @('-Path', $Cust)
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'c-no-publisher'
        $After = Get-TestFileState $Cust
        $After.Hash | Should -Be $Before.Hash
        $After.Written | Should -Be $Before.Written
        $After.Created | Should -Be $Before.Created
    }

    It 'exits 1 for a file that is not there' {
        $r = Invoke-Validator @('-Path', (Join-Path (New-TestDir 'validator-none') 'customer-mappings.json'))
        $r.ExitCode | Should -Be 1
    }

    It 'exits 2 with a clear message when the inventory script is missing' {
        $Dir = New-TestDir 'validator-noscript'
        $Cust = Copy-TestFixture 'mappings-customer-valid.json' $Dir 'customer-mappings.json'
        $r = Invoke-Validator @('-Path', $Cust, '-InventoryScriptPath', (Join-Path $Dir 'Intune_Windows_Inventory.ps1'))
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'Intune_Windows_Inventory\.ps1'
    }
}
