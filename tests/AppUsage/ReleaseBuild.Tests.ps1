BeforeAll {
    . "$PSScriptRoot\_Import.ps1"
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $Builder = Join-Path $RepoRoot 'Build-InventoryRelease.ps1'
    $SourceScript = Join-Path $RepoRoot 'Intune_Windows_Inventory.ps1'
    $ShippedMappings = Join-Path $RepoRoot 'powerstacks-mappings.json'
    $Fixtures = Join-Path $PSScriptRoot 'fixtures'
    $RegionPattern = '(?ms)^#region APPUSAGE\r?\n(.*?)^#endregion APPUSAGE'

    function New-TestDir([string]$Name)
    {
        $Dir = Join-Path 'TestDrive:\' $Name
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        return (Resolve-Path $Dir).ProviderPath
    }

    function Invoke-TestScript([string]$Path, [string[]]$Arguments)
    {
        $Output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Path @Arguments 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($Output | Out-String) }
    }

    function Invoke-TestBuild([string]$Source, [string]$Mappings, [string]$OutFile)
    {
        return Invoke-TestScript $Builder @('-SourceScript', $Source, '-MappingsPath', $Mappings, '-OutFile', $OutFile)
    }

    function Get-TestFileState([string]$Path)
    {
        $Item = Get-Item -LiteralPath $Path
        return [pscustomobject]@{
            Hash    = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
            Written = $Item.LastWriteTimeUtc
            Created = $Item.CreationTimeUtc
        }
    }

    function Get-TestTokens([string]$Text)
    {
        $Tokens = $null
        $Errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$Tokens, [ref]$Errors)
        return [pscustomobject]@{ Tokens = $Tokens; Errors = $Errors }
    }

    # The offsets inside #region <Name>, between its line and its #endregion line.
    function Get-TestRegionSpan([string]$Text, [string]$Name)
    {
        $Start = [regex]::Match($Text, "(?m)^#region $Name\r?$")
        $End = [regex]::Match($Text, "(?m)^#endregion $Name\r?$")
        return @(($Start.Index + $Start.Length), $End.Index)
    }

    function Get-TestRegionLines([string]$Text)
    {
        return @([regex]::Matches($Text, '(?m)^#(end)?region\b.*?\r?$') | ForEach-Object { $_.Value.TrimEnd("`r") })
    }

    function Get-TestEmbedded([string]$Text)
    {
        $Match = [regex]::Match($Text, "(?m)^# BEGIN APPUSAGE MAPPINGS\r?\n\`$script:AppUsageMappingsEmbedded = '([^']*)'\r?\n# END APPUSAGE MAPPINGS\r?$")
        if (-not $Match.Success) { return $null }
        return $Match.Groups[1].Value
    }
}

Describe 'Build-InventoryRelease.ps1' {
    BeforeAll {
        $OutDir = New-TestDir 'release'
        $OutFile = Join-Path $OutDir 'Intune_Windows_Inventory.ps1'
        $Build = Invoke-TestBuild $SourceScript $ShippedMappings $OutFile
        $Source = [IO.File]::ReadAllText($SourceScript, [Text.Encoding]::UTF8)
        $Built = [IO.File]::ReadAllText($OutFile, [Text.Encoding]::UTF8)
        $Ours = [IO.File]::ReadAllText($ShippedMappings) | ConvertFrom-Json
        $Absent = Join-Path (New-TestDir 'nocustomer') 'customer-mappings.json'

        # A copy of the source in its own TestDrive folder, with the mappings and companions beside
        # it. Head goes right after the #region APPUSAGE line; Tail goes just before #endregion APPUSAGE.
        function New-TestSource([string]$Name, [string]$Head = '', [string]$Tail = '')
        {
            $Dir = New-TestDir $Name
            foreach ($File in @('Test-AppUsageMappings.ps1', 'customer-mappings.example.json', 'powerstacks-mappings.json'))
            {
                Copy-Item -LiteralPath (Join-Path $RepoRoot $File) -Destination (Join-Path $Dir $File)
            }
            $Marker = "#region APPUSAGE`r`n"
            $Text = $Source.Insert($Source.IndexOf($Marker) + $Marker.Length, $Head)
            if ($Tail) { $Text = $Text.Insert($Text.IndexOf('#endregion APPUSAGE'), $Tail) }
            $Path = Join-Path $Dir 'Intune_Windows_Inventory.ps1'
            [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
            return $Path
        }

        # Loads a script text's APPUSAGE region in a fresh runspace and returns what Expression gives.
        function Invoke-TestRegion([string]$Text, [string]$Expression)
        {
            $Shell = [powershell]::Create()
            try
            {
                [void]$Shell.AddScript("function Write-CMTraceLog { }`r`n" + [regex]::Match($Text, $RegionPattern).Groups[1].Value + "`r`n" + $Expression)
                $Result = @($Shell.Invoke())
                if ($Shell.Streams.Error.Count -gt 0) { throw "The region didn't load: $($Shell.Streams.Error[0])" }
                return $Result
            }
            finally { $Shell.Dispose() }
        }
    }

    It 'builds, printing our rules version and the size against the 524,288-byte limit' {
        $Build.ExitCode | Should -Be 0 -Because $Build.Output
        $Build.Output | Should -Match ([regex]::Escape("PowerStacks mappings version $($Ours.powerStacks.version)"))
        $Build.Output | Should -Match "Output: $((Get-Item $OutFile).Length) bytes of the 524288-byte limit"
    }

    It 'writes UTF-8 without a BOM, with CRLF line endings' {
        $Bytes = [IO.File]::ReadAllBytes($OutFile)
        ($Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB) | Should -BeFalse
        $Built | Should -Not -Match '[^\r]\n'
    }

    It 'the output parses' {
        (Get-TestTokens $Built).Errors.Count | Should -Be 0
    }

    It 'keeps everything before #region functions unchanged: the header help, the LEGAL DISCLAIMER, and #region initialize with its settings comments' {
        $Head = $Source.Substring(0, (Get-TestRegionSpan $Source 'functions')[0])
        $Built.StartsWith($Head, [StringComparison]::Ordinal) | Should -BeTrue
        $Head | Should -Match '(?m)^\.SYNOPSIS'
        $Head | Should -Match '########### LEGAL DISCLAIMER ###########'
        $Head | Should -Match '(?ms)^#region initialize.*\$CollectAppMetering = \$false # Set to true to collect App Usage.*^#endregion initialize'
    }

    It 'keeps every #region and #endregion line, in order' {
        $Lines = Get-TestRegionLines $Built
        $Lines | Should -Be (Get-TestRegionLines $Source)
        $Lines | Should -Contain '#region APPUSAGE'
        $Lines | Should -Contain '#endregion functions'
    }

    It 'keeps the BEGIN and END markers, with the embedded value between them' {
        Get-TestEmbedded $Built | Should -Not -BeNullOrEmpty
        Get-TestEmbedded $Source | Should -Be ''
    }

    It 'removes every other comment inside #region functions and #region APPUSAGE, and no comment outside them' {
        $Parsed = (Get-TestTokens $Built).Tokens
        $Spans = @((Get-TestRegionSpan $Built 'functions'), (Get-TestRegionSpan $Built 'APPUSAGE'))
        $Inside = @($Parsed | Where-Object {
                $Token = $_
                $Token.Kind -eq 'Comment' -and @($Spans | Where-Object { $Token.Extent.StartOffset -ge $_[0] -and $Token.Extent.EndOffset -le $_[1] }).Count -gt 0
            } | ForEach-Object { $_.Text })
        $Inside | Should -Be @('# BEGIN APPUSAGE MAPPINGS', '# END APPUSAGE MAPPINGS')

        # Outside the two regions, the comments are the source's, one for one.
        $Outside = {
            param ([string]$Text)
            $All = (Get-TestTokens $Text).Tokens
            $Ranges = @((Get-TestRegionSpan $Text 'functions'), (Get-TestRegionSpan $Text 'APPUSAGE'))
            @($All | Where-Object {
                    $Token = $_
                    $Token.Kind -eq 'Comment' -and @($Ranges | Where-Object { $Token.Extent.StartOffset -ge $_[0] -and $Token.Extent.EndOffset -le $_[1] }).Count -eq 0
                } | ForEach-Object { $_.Text })
        }
        (& $Outside $Built) | Should -Be (& $Outside $Source)
    }

    It 'loads its APPUSAGE region with the region regex _Import.ps1 and the validator use (F55)' {
        $Match = [regex]::Match($Built, $RegionPattern)
        $Match.Success | Should -BeTrue
        # A fresh runspace, so only the built region can define the functions.
        $Shell = [powershell]::Create()
        try
        {
            [void]$Shell.AddScript("function Write-CMTraceLog { }`r`n" + $Match.Groups[1].Value + "`r`n@(Get-Command Get-AUMappings, Test-AUMappings, Read-AUCustomerMappingsFile, Invoke-AppUsage -CommandType Function).Count")
            $Result = $Shell.Invoke()
            $Shell.Streams.Error | Should -BeNullOrEmpty
            $Result | Should -Be 4
        }
        finally { $Shell.Dispose() }
    }

    It 'the embedded value round-trips through Get-AUMappings' {
        . ([scriptblock]::Create([regex]::Match($Built, $RegionPattern).Groups[1].Value))
        $r = Get-AUMappings -Embedded (Get-TestEmbedded $Built) -BesideDir '' -CustomerPath $Absent
        $r.Source | Should -Be 'Embedded'
        $r.Errors.Count | Should -Be 0
        $r.PowerStacksVersion | Should -Be $Ours.powerStacks.version
        @($r.Mappings.powerStacks.identityRules | ForEach-Object { $_.id }) | Should -Be @($Ours.powerStacks.identityRules | ForEach-Object { $_.id })
        @($r.Mappings.powerStacks.classificationRules | ForEach-Object { $_.id }) | Should -Be @($Ours.powerStacks.classificationRules | ForEach-Object { $_.id })
        ($r.Mappings.powerStacks | ConvertTo-Json -Depth 10 -Compress) | Should -Be ($Ours.powerStacks | ConvertTo-Json -Depth 10 -Compress)
    }

    It 'produces exactly the release artifact set, with no customer-mappings.json in it or in git (F57)' {
        @(Get-ChildItem -LiteralPath $OutDir -Force | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @('customer-mappings.example.json', 'Intune_Windows_Inventory.ps1', 'Test-AppUsageMappings.ps1')
        $Tracked = @(& git -C $RepoRoot ls-files)
        $LASTEXITCODE | Should -Be 0
        $Tracked | Should -Contain 'customer-mappings.example.json'
        @($Tracked | Where-Object { ($_ -split '/')[-1] -eq 'customer-mappings.json' }) | Should -BeNullOrEmpty
    }

    It 'Get-AUMappings, loaded from the built output, leaves a customer file unchanged (F57)' {
        . ([scriptblock]::Create([regex]::Match($Built, $RegionPattern).Groups[1].Value))
        $Customer = Join-Path (New-TestDir 'customer') 'customer-mappings.json'
        Copy-Item -LiteralPath (Join-Path $Fixtures 'mappings-customer-valid.json') -Destination $Customer
        $Before = Get-TestFileState $Customer
        $r = Get-AUMappings -Embedded (Get-TestEmbedded $Built) -BesideDir '' -CustomerPath $Customer
        $r.CustomerSource | Should -Be 'File'
        $r.CustomerHash | Should -Be $Before.Hash
        $After = Get-TestFileState $Customer
        $After.Hash | Should -Be $Before.Hash
        $After.Written | Should -Be $Before.Written
        $After.Created | Should -Be $Before.Created
    }

    It 'Test-AppUsageMappings.ps1 from the artifact set validates a good customer file against the built output (F56)' {
        $Customer = Join-Path (New-TestDir 'validate') 'customer-mappings.json'
        Copy-Item -LiteralPath (Join-Path $Fixtures 'mappings-customer-valid.json') -Destination $Customer
        $r = Invoke-TestScript (Join-Path $OutDir 'Test-AppUsageMappings.ps1') @('-Path', $Customer)
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match 'is valid'
    }

    It 'an invalid rule stops the build, naming its ID, and nothing is written' {
        $Dir = New-TestDir 'bad-role'
        $Bad = [IO.File]::ReadAllText($ShippedMappings).Replace('"id": "ps-class-cli-node", "type": "classification", "description": "Language runtime or build tool: CLI wherever it runs.", "when": { "exeName": "node.exe" }, "role": "CLI"', '"id": "ps-class-cli-node", "type": "classification", "description": "Language runtime or build tool: CLI wherever it runs.", "when": { "exeName": "node.exe" }, "role": "Tool"')
        $Bad | Should -Not -Be ([IO.File]::ReadAllText($ShippedMappings))
        [IO.File]::WriteAllText((Join-Path $Dir 'powerstacks-mappings.json'), $Bad)
        $Out = Join-Path $Dir 'out\Intune_Windows_Inventory.ps1'
        $r = Invoke-TestBuild $SourceScript (Join-Path $Dir 'powerstacks-mappings.json') $Out
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match "Rule 'ps-class-cli-node'"
        Test-Path (Split-Path $Out) | Should -BeFalse
    }

    It 'a reserved ps-resolve- ID stops the build (F11)' {
        $Dir = New-TestDir 'bad-reserved'
        $Bad = [IO.File]::ReadAllText($ShippedMappings).Replace('"id": "ps-class-cli-node"', '"id": "ps-resolve-path"')
        $Bad | Should -Not -Be ([IO.File]::ReadAllText($ShippedMappings))
        [IO.File]::WriteAllText((Join-Path $Dir 'powerstacks-mappings.json'), $Bad)
        $Out = Join-Path $Dir 'out\Intune_Windows_Inventory.ps1'
        $r = Invoke-TestBuild $SourceScript (Join-Path $Dir 'powerstacks-mappings.json') $Out
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match "Rule 'ps-resolve-path': IDs starting ps-resolve- are reserved"
        Test-Path $Out | Should -BeFalse
    }

    It 'never reads a customer file: it takes only a file named powerstacks-mappings.json' {
        $Dir = New-TestDir 'customer-in'
        $Customer = Join-Path $Dir 'customer-mappings.json'
        Copy-Item -LiteralPath (Join-Path $Fixtures 'mappings-customer-valid.json') -Destination $Customer
        $Out = Join-Path $Dir 'out\Intune_Windows_Inventory.ps1'
        $r = Invoke-TestBuild $SourceScript $Customer $Out
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'must be powerstacks-mappings\.json'
        Test-Path $Out | Should -BeFalse
    }

    It 'has only the SourceScript, MappingsPath, and OutFile parameters' {
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Builder, [ref]$null, [ref]$null)
        @($Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) | Should -Be @('SourceScript', 'MappingsPath', 'OutFile')
    }

    It 'an over-limit build leaves nothing that looks like a release' {
        # Comments outside the stripped regions are kept, so 300 KB of them push the output over.
        $Padding = (1..3000 | ForEach-Object { '# ' + ('x' * 97) }) -join "`r`n"
        $Big = New-TestSource 'oversize'
        [IO.File]::AppendAllText($Big, "`r`n" + $Padding + "`r`n", (New-Object Text.UTF8Encoding($false)))
        $Dir = Split-Path $Big
        $r = Invoke-TestBuild $Big (Join-Path $Dir 'powerstacks-mappings.json') (Join-Path $Dir 'out\Intune_Windows_Inventory.ps1')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'bytes over the 524288-byte limit'
        Test-Path (Join-Path $Dir 'out') | Should -BeFalse

        # An output folder that was already there stays empty: no script, no companions, no temporary file.
        $Existing = New-TestDir 'oversize\existing'
        $r = Invoke-TestBuild $Big (Join-Path $Dir 'powerstacks-mappings.json') (Join-Path $Existing 'Intune_Windows_Inventory.ps1')
        $r.ExitCode | Should -Be 1
        @(Get-ChildItem -LiteralPath $Existing -Force) | Should -BeNullOrEmpty
    }

    It 'refuses to build over the source script' {
        $r = Invoke-TestBuild $SourceScript $ShippedMappings $SourceScript
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match "can't be the source script"
    }

    It 'resolves relative paths against the current PowerShell location, not the process folder' {
        $Copy = New-TestSource 'relative'
        $Work = Split-Path $Copy
        $Launch = New-TestDir 'relative-launch'
        $Command = "Set-Location -LiteralPath '$Work'; & '$Builder' -SourceScript .\Intune_Windows_Inventory.ps1 -MappingsPath .\powerstacks-mappings.json -OutFile .\rel\Intune_Windows_Inventory.ps1; exit `$LASTEXITCODE"
        Push-Location -LiteralPath $Launch
        try { $Output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $Command 2>&1 }
        finally { Pop-Location }
        $LASTEXITCODE | Should -Be 0 -Because ($Output | Out-String)
        Test-Path (Join-Path $Work 'rel\Intune_Windows_Inventory.ps1') | Should -BeTrue
        Test-Path (Join-Path $Launch 'rel') | Should -BeFalse
    }

    It 'keeps a command ended by a comment line after a line continuation, and the spaces in a multi-line string' {
        $Repro = @(
            'function Get-AUTestContinuation'
            '{'
            '    $out = @(Write-Output 1 `'
            '# dangling comment'
            'Write-Output 2)'
            '    return $out.Count'
            '}'
            'function Get-AUTestStringLength'
            '{'
            '    <#c#> $s = "abc   '
            'def"'
            '    return $s.Length'
            '}'
            ''
        ) -join "`r`n"
        $Fixture = New-TestSource 'repro' -Head $Repro
        $Dir = Split-Path $Fixture
        $Out = Join-Path $Dir 'out\Intune_Windows_Inventory.ps1'
        $r = Invoke-TestBuild $Fixture (Join-Path $Dir 'powerstacks-mappings.json') $Out
        $r.ExitCode | Should -Be 0 -Because $r.Output
        foreach ($Path in @($Fixture, $Out))
        {
            Invoke-TestRegion ([IO.File]::ReadAllText($Path)) 'Get-AUTestContinuation; Get-AUTestStringLength' | Should -Be @(2, 11) -Because $Path
        }
    }

    It 'fails closed when the built script''s Get-AUMappings doesn''t read the embedded rules' {
        $Broken = New-TestSource 'selfload' -Tail "function Get-AUMappings { param (`$Embedded, `$BesideDir, `$CustomerPath) return [pscustomobject]@{ Source = 'None'; Errors = @('broken') } }`r`n"
        $Dir = Split-Path $Broken
        $r = Invoke-TestBuild $Broken (Join-Path $Dir 'powerstacks-mappings.json') (Join-Path $Dir 'out\Intune_Windows_Inventory.ps1')
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match "didn't read the embedded rules"
        Test-Path (Join-Path $Dir 'out') | Should -BeFalse
    }
}

Describe 'The build''s token check (Compare-BuildTokens)' {
    BeforeAll {
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Builder, [ref]$null, [ref]$null)
        $Function = $Ast.Find({ param ($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'Compare-BuildTokens' }, $true)
        . ([scriptblock]::Create($Function.Extent.Text))
    }

    It 'accepts removed comments and blank lines' {
        Compare-BuildTokens "`$a = 1 # note`r`n# line`r`n`r`n<# block #>`r`n`$b = 2`r`n" "`$a = 1`r`n`$b = 2`r`n" | Should -BeNullOrEmpty
        Compare-BuildTokens "`$a<#c#>+1" "`$a +1" | Should -BeNullOrEmpty
    }

    It 'catches a command merged across a line continuation' {
        Compare-BuildTokens "`$o = @(Write-Output 1 ```r`n# c`r`nWrite-Output 2)" "`$o = @(Write-Output 1 ```r`nWrite-Output 2)" | Should -Match 'became'
    }

    It 'catches a changed string' {
        Compare-BuildTokens "<#c#> `$s = `"abc   `r`ndef`"" " `$s = `"abc`r`ndef`"" | Should -Match 'became'
    }

    It 'catches a changed or missing token' {
        Compare-BuildTokens "`$a = 1`r`n" "`$b = 1`r`n" | Should -Match 'became'
        Compare-BuildTokens "`$a = 1; `$b = 2`r`n" "`$a = 1`r`n" | Should -Not -BeNullOrEmpty
    }
}

Describe 'Seed rules in powerstacks-mappings.json' {
    BeforeAll {
        function Write-CMTraceLog { param ([string]$Message, [string]$Component, [int]$Type) }
        $Absent = Join-Path (New-TestDir 'seed-nocustomer') 'customer-mappings.json'
        $Shipped = Get-AUMappings -Embedded '' -BesideDir $RepoRoot -CustomerPath $Absent
        $SeedClassificationIds = @('ps-class-windows-msftcorp', 'ps-class-windows-msmpeng', 'ps-class-windows-msmpeng-platform', 'ps-class-windows-nissrv', 'ps-class-windows-nissrv-platform', 'ps-class-windows-mpcmdrun', 'ps-class-windows-mpcmdrun-platform', 'ps-class-windows-mpdefendercoreservice', 'ps-class-windows-mpdefendercoreservice-platform', 'ps-class-windows-defenderaiplatformhost-platform', 'ps-class-windows-tabtip', 'ps-class-helper-edgeupdate')

        # Verified facts in the Task 14 shape, with the values seen on lab and test devices.
        function New-TestFacts([string]$Exe, [string]$RunPath, [string]$Company, [string]$Product, [string]$Description)
        {
            return [pscustomobject][ordered]@{
                ExeName         = $Exe
                RunPath         = $RunPath
                LocationClass   = (Get-AULocationClass $RunPath)
                FileDescription = $Description
                FileProductName = $Product
                FileCompanyName = $Company
                FileVersion     = '1.0.0.0'
                ProductVersion  = '1.0.0.0'
                FactsVerified   = $true
                Subsystem       = 'GUI'
                MsiProductCode  = $null
                PackageFamily   = $null
                IsServiceBinary = $false
                UserSid         = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
                PathEvidence    = $null
            }
        }

        function New-TestApp([string]$Name, [string]$Publisher)
        {
            return [pscustomobject][ordered]@{
                DisplayName = $Name; Publisher = $Publisher; DisplayVersion = $null; ProductCode = $null; PackageFamily = $null
                InstallLocation = $null; DisplayIcon = $null; UninstallString = $null; Architecture = $null; Scope = 'Machine'; ProfilePath = $null
            }
        }

        # Installed apps on a typical device, so each rule has to pick its own app out of several.
        $Apps = @(
            (New-TestApp 'Microsoft 365 Apps for enterprise - en-us' 'Microsoft Corporation')
            (New-TestApp 'Microsoft OneDrive' 'Microsoft Corporation')
            (New-TestApp 'Microsoft Edge' 'Microsoft Corporation')
            (New-TestApp 'Microsoft Visual Studio Code (User)' 'Microsoft Corporation')
            (New-TestApp 'Adobe Creative Cloud' 'Adobe Inc.')
            (New-TestApp 'Adobe Acrobat (64-bit)' 'Adobe Inc.')
        )
    }

    BeforeDiscovery {
        $IdentityCases = @(
            @{ Id = 'ps-onedrive-1'; Exe = 'OneDrive.Sync.Service.exe'; Path = 'C:\Users\a\AppData\Local\Microsoft\OneDrive\26.212.1029.0006\OneDrive.Sync.Service.exe'; Company = 'Microsoft Corporation'; Product = 'Microsoft OneDrive Sync Service'; Description = 'Microsoft OneDrive Sync Service'; App = 'Microsoft OneDrive' }
            @{ Id = 'ps-m365apps-1'; Exe = 'WINWORD.EXE'; Path = 'C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE'; Company = 'Microsoft Corporation'; Product = 'Microsoft Office'; Description = 'Microsoft Word'; App = 'Microsoft 365 Apps for enterprise - en-us' }
            @{ Id = 'ps-m365apps-2'; Exe = 'EXCEL.EXE'; Path = 'C:\Program Files\Microsoft Office\root\Office16\EXCEL.EXE'; Company = 'Microsoft Corporation'; Product = 'Microsoft Office'; Description = 'Microsoft Excel'; App = 'Microsoft 365 Apps for enterprise - en-us' }
            @{ Id = 'ps-m365apps-3'; Exe = 'POWERPNT.EXE'; Path = 'C:\Program Files\Microsoft Office\root\Office16\POWERPNT.EXE'; Company = 'Microsoft Corporation'; Product = 'Microsoft Office'; Description = 'Microsoft PowerPoint'; App = 'Microsoft 365 Apps for enterprise - en-us' }
            @{ Id = 'ps-m365apps-4'; Exe = 'OUTLOOK.EXE'; Path = 'C:\Program Files\Microsoft Office\root\Office16\OUTLOOK.EXE'; Company = 'Microsoft Corporation'; Product = 'Microsoft Outlook'; Description = 'Microsoft Outlook'; App = 'Microsoft 365 Apps for enterprise - en-us' }
            @{ Id = 'ps-m365apps-5'; Exe = 'ONENOTE.EXE'; Path = 'C:\Program Files\Microsoft Office\root\Office16\ONENOTE.EXE'; Company = 'Microsoft Corporation'; Product = 'Microsoft OneNote'; Description = 'Microsoft OneNote'; App = 'Microsoft 365 Apps for enterprise - en-us' }
            @{ Id = 'ps-m365apps-6'; Exe = 'MSACCESS.EXE'; Path = 'C:\Program Files\Microsoft Office\root\Office16\MSACCESS.EXE'; Company = 'Microsoft Corporation'; Product = 'Microsoft Office'; Description = 'Microsoft Access'; App = 'Microsoft 365 Apps for enterprise - en-us' }
            @{ Id = 'ps-vscode-1'; Exe = 'Code.exe'; Path = 'C:\Users\a\AppData\Local\Programs\Microsoft VS Code\Code.exe'; Company = 'Microsoft Corporation'; Product = 'Visual Studio Code'; Description = 'Visual Studio Code'; App = 'Microsoft Visual Studio Code (User)' }
            @{ Id = 'ps-adobecc-1'; Exe = 'Creative Cloud.exe'; Path = 'C:\Program Files\Adobe\Adobe Creative Cloud\ACC\Creative Cloud.exe'; Company = 'Adobe Inc.'; Product = 'Creative Cloud'; Description = 'Creative Cloud'; App = 'Adobe Creative Cloud' }
            @{ Id = 'ps-adobecc-2'; Exe = 'Creative Cloud Helper.exe'; Path = 'C:\Program Files\Common Files\Adobe\Adobe Desktop Common\ADS\Creative Cloud Helper.exe'; Company = 'Adobe Inc.'; Product = 'Creative Cloud Helper'; Description = 'Creative Cloud Helper'; App = 'Adobe Creative Cloud' }
            @{ Id = 'ps-adobecc-3'; Exe = 'Creative Cloud UI Helper.exe'; Path = 'C:\Program Files\Adobe\Adobe Creative Cloud\ACC\Creative Cloud UI Helper.exe'; Company = 'Adobe Inc.'; Product = 'Creative Cloud UI Helper'; Description = 'Creative Cloud UI Helper'; App = 'Adobe Creative Cloud' }
            @{ Id = 'ps-adobecc-4'; Exe = 'Adobe Desktop Service.exe'; Path = 'C:\Program Files (x86)\Common Files\Adobe\Adobe Desktop Common\ADS\Adobe Desktop Service.exe'; Company = 'Adobe Inc.'; Product = 'Adobe Desktop Service'; Description = 'Adobe Desktop Service'; App = 'Adobe Creative Cloud' }
            @{ Id = 'ps-adobecc-5'; Exe = 'CoreSync.exe'; Path = 'C:\Program Files (x86)\Adobe\Adobe Sync\CoreSync\CoreSync.exe'; Company = 'Adobe Inc.'; Product = 'Core Sync'; Description = 'Core Sync'; App = 'Adobe Creative Cloud' }
        )
        $ClassificationCases = @(
            @{ Id = 'ps-class-windows-msftcorp'; Exe = 'Defrag.exe'; Path = 'C:\Windows\System32\Defrag.exe'; Company = 'Microsoft Corp.'; Role = 'Windows' }
            @{ Id = 'ps-class-windows-msmpeng'; Exe = 'MsMpEng.exe'; Path = 'C:\Program Files\Windows Defender\MsMpEng.exe'; Company = 'Microsoft Corporation'; Role = 'Windows' }
            @{ Id = 'ps-class-windows-msmpeng-platform'; Exe = 'MsMpEng.exe'; Path = 'C:\ProgramData\Microsoft\Windows Defender\Platform\4.18.26100.4-0\MsMpEng.exe'; Company = 'Microsoft Corporation'; Role = 'Windows' }
            @{ Id = 'ps-class-windows-nissrv'; Exe = 'NisSrv.exe'; Path = 'C:\Program Files\Windows Defender\NisSrv.exe'; Company = 'Microsoft Corporation'; Role = 'Windows' }
            @{ Id = 'ps-class-windows-nissrv-platform'; Exe = 'NisSrv.exe'; Path = 'C:\ProgramData\Microsoft\Windows Defender\Platform\4.18.26100.4-0\NisSrv.exe'; Company = 'Microsoft Corporation'; Role = 'Windows' }
            @{ Id = 'ps-class-windows-mpcmdrun'; Exe = 'MpCmdRun.exe'; Path = 'C:\Program Files\Windows Defender\MpCmdRun.exe'; Company = 'Microsoft Corporation'; Role = 'Windows' }
            @{ Id = 'ps-class-windows-mpcmdrun-platform'; Exe = 'MpCmdRun.exe'; Path = 'C:\ProgramData\Microsoft\Windows Defender\Platform\4.18.26100.4-0\MpCmdRun.exe'; Company = 'Microsoft Corporation'; Role = 'Windows' }
            @{ Id = 'ps-class-windows-mpdefendercoreservice'; Exe = 'MpDefenderCoreService.exe'; Path = 'C:\Program Files\Windows Defender\MpDefenderCoreService.exe'; Company = 'Microsoft Corporation'; Role = 'Windows' }
            @{ Id = 'ps-class-windows-mpdefendercoreservice-platform'; Exe = 'MpDefenderCoreService.exe'; Path = 'C:\ProgramData\Microsoft\Windows Defender\Platform\4.18.26100.4-0\MpDefenderCoreService.exe'; Company = 'Microsoft Corporation'; Role = 'Windows' }
            @{ Id = 'ps-class-windows-defenderaiplatformhost-platform'; Exe = 'DefenderAiPlatformHost.exe'; Path = 'C:\ProgramData\Microsoft\Windows Defender\Platform\4.18.26100.4-0\DefenderAiPlatformHost.exe'; Company = 'Microsoft Corporation'; Role = 'Windows' }
            @{ Id = 'ps-class-windows-tabtip'; Exe = 'TabTip.exe'; Path = 'C:\Program Files\Common Files\microsoft shared\ink\TabTip.exe'; Company = 'Microsoft Corporation'; Role = 'Windows' }
            @{ Id = 'ps-class-helper-edgeupdate'; Exe = 'MicrosoftEdgeUpdate.exe'; Path = 'C:\Program Files (x86)\Microsoft\EdgeUpdate\MicrosoftEdgeUpdate.exe'; Company = 'Microsoft Corporation'; Role = 'Helper' }
        )
    }

    It 'the shipped file loads with no errors' {
        $Shipped.Errors | Should -BeNullOrEmpty
        $Shipped.Source | Should -Be 'Beside'
    }

    It 'every identity rule of type identity has a test case' -ForEach @{ Cases = $IdentityCases } {
        @($Shipped.Mappings.powerStacks.identityRules | Where-Object { $_.type -ceq 'identity' } | ForEach-Object { $_.id }) | Should -Be @($Cases | ForEach-Object { $_.Id })
    }

    It 'every seed classification rule has a test case' -ForEach @{ Cases = $ClassificationCases } {
        @($Cases | ForEach-Object { $_.Id }) | Should -Be $SeedClassificationIds
        foreach ($Id in $SeedClassificationIds) { @($Shipped.Mappings.powerStacks.classificationRules | ForEach-Object { $_.id }) | Should -Contain $Id }
    }

    It '<Id> maps <Exe> to <App>' -ForEach $IdentityCases {
        $r = Resolve-AUIdentity (New-TestFacts $Exe $Path $Company $Product $Description) $Shipped $Apps
        $r.MatchSection | Should -Be 'PowerStacks'
        $r.MatchRuleId | Should -Be $Id
        $r.ResolvedAppName | Should -Be $App
        $r.EvidenceUsed | Should -Be 'Verified'
    }

    It '<Id> matches the current file at the path for an unverified <Exe> build (D30)' -ForEach $IdentityCases {
        $Facts = New-TestFacts $Exe $Path $null $null $null
        $Facts.FactsVerified = $false
        $Facts.PathEvidence = [pscustomobject]@{ CompanyName = $Company; ProductName = $Product }
        $r = Resolve-AUIdentity $Facts $Shipped $Apps
        $r.MatchRuleId | Should -Be $Id
        $r.EvidenceUsed | Should -Be 'CurrentFileAtPath'
    }

    It '<Id> leaves <Exe> from another publisher unmatched' -ForEach $IdentityCases {
        $r = Resolve-AUIdentity (New-TestFacts $Exe $Path 'Contoso Ltd.' $Product $Description) $Shipped $Apps
        $r.MatchSection | Should -Be 'None'
        $r.MatchRuleId | Should -BeNullOrEmpty
    }

    It '<Id> gives <Exe> the <Role> role' -ForEach $ClassificationCases {
        $c = Get-AUClassification (New-TestFacts $Exe $Path $Company $null $null) $Shipped 'None'
        $c.ClassificationRuleId | Should -Be $Id
        $c.RuleRole | Should -Be $Role
    }

    It '<Id> leaves <Exe> from another publisher alone' -ForEach $ClassificationCases {
        $c = Get-AUClassification (New-TestFacts $Exe $Path 'Contoso Ltd.' $null $null) $Shipped 'None'
        $c.ClassificationRuleId | Should -BeNullOrEmpty
    }

    It '<Id> leaves a <Exe> in a user folder alone, whatever its publisher says' -ForEach $ClassificationCases {
        $c = Get-AUClassification (New-TestFacts $Exe ('C:\Users\a\AppData\Local\Fake\' + $Exe) $Company $null $null) $Shipped 'None'
        $c.ClassificationRuleId | Should -BeNullOrEmpty
    }

    It '<Id> needs verified facts for its publisher condition (D30)' -ForEach $ClassificationCases {
        $Facts = New-TestFacts $Exe $Path $null $null $null
        $Facts.FactsVerified = $false
        $Facts.PathEvidence = [pscustomobject]@{ CompanyName = $Company; ProductName = $null }
        (Get-AUClassification $Facts $Shipped 'None').ClassificationRuleId | Should -BeNullOrEmpty
    }
}
