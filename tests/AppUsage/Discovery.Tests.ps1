BeforeAll {
    . "$PSScriptRoot\_Import.ps1"
    # A silent logger with the real one's parameters (version 19's Get-InstalledApplications uses the switches).
    function Write-CMTraceLog { param ([string]$Message, [string]$Path, [string]$Component, [int]$Type, [switch]$WarningMsg, [switch]$ErrorMsg) }

    $script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $script:FixtureKey = "Software\AUDiscoveryTest_$([guid]::NewGuid().ToString('N'))"
    $script:LoadedSid = 'S-1-5-21-1000-1000-1000-1001'
    $script:CopiedSid = 'S-1-5-21-1000-1000-1000-1002'
    $script:AlicePath = 'C:\Users\alice'
    $script:BobPath = 'C:\Users\bob'
    $script:Uninstall = 'Software\Microsoft\Windows\CurrentVersion\Uninstall'
    $script:UninstallWow = 'Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    $script:Components = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Components'
    # {12345678-90AB-CDEF-1234-567890ABCDEF} and {ABCDEF01-2345-6789-ABCD-EF0123456789}, packed by hand.
    $script:DeltaCode = '{12345678-90AB-CDEF-1234-567890ABCDEF}'
    $script:DeltaPacked = '87654321BA09FEDC2143658709BADCFE'
    $script:EpsilonCode = '{ABCDEF01-2345-6789-ABCD-EF0123456789}'
    $script:EpsilonPacked = '10FEDCBA54329876BADCFE1032547698'

    # Creates HKCU\<FixtureKey>\<Path> with String or DWord values, and ExpandString values.
    function Set-FixtureKey([string]$Path, [hashtable]$Values = @{}, [hashtable]$Expand = @{})
    {
        $Key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("$script:FixtureKey\$Path")
        try
        {
            foreach ($Name in $Values.Keys) { $Key.SetValue($Name, $Values[$Name]) }
            foreach ($Name in $Expand.Keys) { $Key.SetValue($Name, $Expand[$Name], [Microsoft.Win32.RegistryValueKind]::ExpandString) }
        }
        finally { $Key.Close() }
    }

    function Invoke-TestReg([string]$Arguments)
    {
        $Result = Invoke-AUProcess -FilePath $script:AURegPath -Arguments $Arguments -WorkingDirectory (Split-Path $script:AURegPath) -TimeoutSeconds 60
        if ($Result.ExitCode -ne 0) { throw "reg $Arguments failed: $($Result.Output)" }
    }

    function New-TestUser([string]$Sid, [string]$State, [string]$ProfilePath, [string]$UserType = 'Local')
    {
        return [pscustomobject]@{ Sid = $Sid; UserType = $UserType; ProfilePath = $ProfilePath; ProfileState = $State }
    }

    function New-TestSnapshot([hashtable]$Copies = @{})
    {
        $HiveCopies = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
        foreach ($Sid in $Copies.Keys) { $HiveCopies[$Sid] = $Copies[$Sid] }
        return [pscustomobject]@{ WorkDir = $TestDrive; HiveCopies = $HiveCopies; MachineDomainSid = 'S-1-5-21-1000-1000-1000'; Status = 'OK' }
    }

    # Machine (HKLM stand-in): ARP in both views, and Windows Installer UserData.
    Set-FixtureKey "M\$script:Uninstall\Alpha" @{ DisplayName = 'Contoso Alpha'; DisplayVersion = '1.0.0'; Publisher = 'Contoso Ltd'; InstallDate = '20240115' } @{
        UninstallString = '"%ProgramFiles%\Contoso\Alpha\uninst.exe" /S'; InstallLocation = '%ProgramFiles%\Contoso\Alpha'; DisplayIcon = '%USERPROFILE%\alpha.ico'
    }
    Set-FixtureKey "M\$script:Uninstall\$script:DeltaCode" @{ DisplayName = 'Contoso Delta'; DisplayVersion = '4.0'; Publisher = 'Contoso Ltd'; InstallDate = '2024-01-15'; UninstallString = "MsiExec.exe /X$script:DeltaCode"; WindowsInstaller = 1 }
    Set-FixtureKey "M\$script:Uninstall\NoName" @{ DisplayVersion = '9.9' }
    Set-FixtureKey "M\$script:Uninstall\EmptyName" @{ DisplayName = ''; DisplayVersion = '9.9' }
    Set-FixtureKey "M\$script:Uninstall\Fabrikam" @{ DisplayName = 'Fabrikam Shared'; DisplayVersion = '2.0'; Publisher = 'Fabrikam'; InstallDate = 20230102 }
    Set-FixtureKey "M\$script:UninstallWow\Alpha32" @{ DisplayName = 'Contoso Alpha'; DisplayVersion = '1.0.0'; Publisher = 'Contoso Ltd'; InstallDate = '20231201'; UninstallString = 'C:\Program Files (x86)\Contoso\Alpha\uninst.exe' }
    Set-FixtureKey "M\$script:UninstallWow\Beta" @{ DisplayName = 'Contoso Beta'; DisplayVersion = '2.0'; Publisher = 'Contoso Ltd'; InstallDate = '' }
    Set-FixtureKey "M\$script:Components\C1" @{ $script:DeltaPacked = 'C:\Program Files\Contoso\Delta\Delta.exe'; ('0' * 32) = 'C:\Program Files\Contoso\Delta\zero.exe' }
    Set-FixtureKey "M\$script:Components\C2" @{ $script:DeltaPacked = 'C?\Program Files\Contoso\Delta\helper.exe' }
    Set-FixtureKey "M\$script:Components\C3" @{ $script:EpsilonPacked = 'C:\Program Files\Contoso\Epsilon\epsilon.exe' }
    Set-FixtureKey "M\$script:Components\C4" @{ $script:DeltaPacked = '02:\SOFTWARE\Contoso\Delta.exe' }
    Set-FixtureKey "M\$script:Components\C5" @{ ('A' * 32) = 'C:\Program Files\Shared\common.exe' }
    Set-FixtureKey "M\$($script:Components.Replace('S-1-5-18', $script:LoadedSid))\C6" @{ ('B' * 32) = 'C:\Program Files\Shared\common.exe' }
    Set-FixtureKey "M\$script:Components\C7" @{ ('A' * 32) = 'C:\Program Files\Contoso\Delta\readme.txt' }
    Set-FixtureKey "M\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\$script:EpsilonPacked\InstallProperties" @{ DisplayName = 'Contoso Epsilon'; DisplayVersion = '1.0' }
    # SYSTEM's hive stand-in.
    Set-FixtureKey "SYS\$script:Uninstall\SysTool" @{ DisplayName = 'Contoso System Tool'; DisplayVersion = '1.0'; Publisher = 'Contoso Ltd' }
    # LocalService's and NetworkService's hive stand-ins.
    Set-FixtureKey "SVC19\$script:Uninstall\SvcTool" @{ DisplayName = 'Contoso LocalService Tool'; DisplayVersion = '1.0'; Publisher = 'Contoso Ltd' }
    Set-FixtureKey "SVC20\$script:UninstallWow\NetTool" @{ DisplayName = 'Contoso NetworkService Tool'; DisplayVersion = '1.0'; Publisher = 'Contoso Ltd' }
    # Alice, signed in.
    Set-FixtureKey "U1\$script:Uninstall\Gamma" @{ DisplayName = 'Contoso Gamma'; DisplayVersion = '3.1'; Publisher = 'Contoso Ltd'; InstallDate = '20250301'; UninstallString = '"C:\Users\alice\AppData\Local\Programs\Gamma\uninst.exe"' } @{
        InstallLocation = '%LOCALAPPDATA%\Programs\Gamma'; DisplayIcon = '%APPDATA%\Gamma\gamma.exe'
    }
    Set-FixtureKey "U1\$script:Uninstall\Beta" @{ DisplayName = 'Contoso Beta'; DisplayVersion = '2.5'; Publisher = 'Contoso Ltd' }
    Set-FixtureKey "U1\$script:Uninstall\Omega" @{ DisplayName = 'Contoso Omega'; DisplayVersion = '1.2'; Publisher = 'Contoso Ltd' }
    Set-FixtureKey "U1\$script:UninstallWow\Old32" @{ DisplayName = 'Contoso Old32'; DisplayVersion = '0.1'; Publisher = 'Contoso Ltd' }
    # Bob, signed out: read from a hive copy.
    Set-FixtureKey "U2\$script:Uninstall\Omega" @{ DisplayName = 'Contoso Omega'; DisplayVersion = '1.5'; Publisher = 'Contoso Ltd' }
    Set-FixtureKey "U2\$script:Uninstall\Zeta" @{ DisplayName = 'Contoso Zeta'; DisplayVersion = '0.9'; Publisher = 'Contoso Ltd' } @{ InstallLocation = '%LOCALAPPDATA%\Zeta' }

    $script:HiveFolder = Join-Path $TestDrive 'hives'
    $null = New-Item -ItemType Directory -Path $script:HiveFolder
    $script:AliceHive = Join-Path $script:HiveFolder 'alice.dat'
    $script:BobCopy = Join-Path $script:HiveFolder 'NTUSER.DAT'
    $script:BadCopy = Join-Path $script:HiveFolder 'bad.dat'
    [IO.File]::WriteAllText($script:BadCopy, 'not a registry hive')
    if ($script:IsAdmin)
    {
        Invoke-TestReg "save `"HKCU\$script:FixtureKey\U1`" `"$script:AliceHive`" /y"
        Invoke-TestReg "save `"HKCU\$script:FixtureKey\U2`" `"$script:BobCopy`" /y"
        Invoke-TestReg "load `"HKU\$script:LoadedSid`" `"$script:AliceHive`""
    }

    # Version 19's Get-InstalledApplications, from the script itself, for the parity test.
    $Ast = [Management.Automation.Language.Parser]::ParseInput($AUScriptText, [ref]$null, [ref]$null)
    $Definition = $Ast.Find({ param ($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'Get-InstalledApplications' }, $true)
    . ([scriptblock]::Create($Definition.Extent.Text))
    # The cmdlet itself, so the parity test's mock can call it.
    $script:RealGetItemProperty = $ExecutionContext.InvokeCommand.GetCmdlet('Microsoft.PowerShell.Management\Get-ItemProperty')

    # The machine and SYSTEM reads go to the fixture; every other HKEY_USERS read is real.
    function Use-FixtureMachine
    {
        Mock Open-AURegistryBase -ParameterFilter { $Hive -eq 'Machine' } { [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$script:FixtureKey\M") }
        Mock Open-AURegistryBase -ParameterFilter { $Hive -eq 'Users' -and $Name -eq 'S-1-5-18' } { [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$script:FixtureKey\SYS") }
        Mock Open-AURegistryBase -ParameterFilter { $Hive -eq 'Users' -and $Name -eq 'S-1-5-19' } { [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$script:FixtureKey\SVC19") }
        Mock Open-AURegistryBase -ParameterFilter { $Hive -eq 'Users' -and $Name -eq 'S-1-5-20' } { [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$script:FixtureKey\SVC20") }
    }

    function Get-TestApp([object[]]$Apps, [string]$Name, [string]$Scope)
    {
        return @($Apps | Where-Object { $_.DisplayName -eq $Name -and (-not $Scope -or $_.Scope -eq $Scope) })
    }
}

AfterAll {
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    if ($script:IsAdmin -and (Test-AUHiveLoaded -Sid $script:LoadedSid)) { Invoke-TestReg "unload `"HKU\$script:LoadedSid`"" }
    foreach ($Name in @((Get-AUHiveMountName $script:CopiedSid), (Get-AUHiveMountName $script:LoadedSid)))
    {
        if (Test-AUHiveLoaded -Sid $Name) { [void](Dismount-AUHive -MountName $Name) }
    }
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($script:FixtureKey, $false)
}

BeforeDiscovery {
    # reg save and reg load need an elevated session (the Windows runner is elevated).
    $script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

Describe 'Get-AUUsers' {
    BeforeAll {
        $script:Present = Join-Path $TestDrive 'present'
        $null = New-Item -ItemType Directory -Path $script:Present -Force
        $script:CopyFile = Join-Path $TestDrive 'copy.dat'
        [IO.File]::WriteAllText($script:CopyFile, 'x')
        Mock Get-AUProfileList {
            @(
                [pscustomobject]@{ Sid = 'S-1-5-18'; ProfilePath = $script:Present }
                [pscustomobject]@{ Sid = 'S-1-5-21-1000-1000-1000-1001'; ProfilePath = $script:Present }
                [pscustomobject]@{ Sid = 'S-1-12-1-1-2-3-4'; ProfilePath = $script:Present }
                [pscustomobject]@{ Sid = 'S-1-5-21-9-9-9-1001'; ProfilePath = $script:Present }
                [pscustomobject]@{ Sid = 'S-1-5-21-9-9-9-1002'; ProfilePath = $script:Present }
                [pscustomobject]@{ Sid = 'S-1-5-21-9-9-9-1003'; ProfilePath = (Join-Path $TestDrive 'gone') }
                [pscustomobject]@{ Sid = 'S-1-5-21-9-9-9-1004'; ProfilePath = $script:Present }
                [pscustomobject]@{ Sid = 'S-1-5-21-9-9-9-1005'; ProfilePath = (Join-Path $TestDrive 'gone') }
            )
        }
        Mock Test-AUHiveLoaded { $Sid -in @('S-1-5-18', 'S-1-5-21-1000-1000-1000-1001') }
    }

    It 'gives each ProfileList user Loaded, Copied, CopyFailed, or Missing, with its UserType' {
        $Snapshot = New-TestSnapshot @{
            'S-1-12-1-1-2-3-4'    = $script:CopyFile
            'S-1-5-21-9-9-9-1001' = $null
            'S-1-5-21-9-9-9-1002' = (Join-Path $TestDrive 'deleted-by-hand.dat')
            'S-1-5-21-9-9-9-1003' = $null
        }
        $Users = @(Get-AUUsers -Snapshot $Snapshot)
        $Users.Count | Should -Be 8
        $State = @{}
        foreach ($User in $Users) { $State[$User.Sid] = "$($User.ProfileState)/$($User.UserType)" }
        $State['S-1-5-18'] | Should -Be 'Loaded/System'
        $State['S-1-5-21-1000-1000-1000-1001'] | Should -Be 'Loaded/Local'
        $State['S-1-12-1-1-2-3-4'] | Should -Be 'Copied/CloudOnly'
        $State['S-1-5-21-9-9-9-1001'] | Should -Be 'CopyFailed/Domain'
        # A hive copy deleted by hand.
        $State['S-1-5-21-9-9-9-1002'] | Should -Be 'CopyFailed/Domain'
        # Signed out, and the profile folder isn't on the device.
        $State['S-1-5-21-9-9-9-1003'] | Should -Be 'Missing/Domain'
        # Signed out after the snapshot: no copy.
        $State['S-1-5-21-9-9-9-1004'] | Should -Be 'CopyFailed/Domain'
        $State['S-1-5-21-9-9-9-1005'] | Should -Be 'Missing/Domain'
        $Users[0].ProfilePath | Should -Be $script:Present
    }

    It 'with no snapshot, reads the machine domain SID itself and has no Copied user' {
        Mock Get-AUMachineDomainSid { 'S-1-5-21-9-9-9' }
        $Users = @(Get-AUUsers -Snapshot $null)
        @($Users | Where-Object { $_.ProfileState -eq 'Copied' }).Count | Should -Be 0
        ($Users | Where-Object Sid -eq 'S-1-5-21-9-9-9-1001').UserType | Should -Be 'Local'
        ($Users | Where-Object Sid -eq 'S-1-5-21-9-9-9-1001').ProfileState | Should -Be 'CopyFailed'
        Should -Invoke Get-AUMachineDomainSid -Times 1 -Exactly
    }

    It 'returns nothing, and does not throw, when ProfileList cannot be read' {
        Mock Get-AUProfileList { throw 'denied' }
        @(Get-AUUsers -Snapshot (New-TestSnapshot)).Count | Should -Be 0
    }
}

Describe 'Expand-AUEnvironmentText' {
    It 'expands machine variables from the environment' {
        Expand-AUEnvironmentText -Text '%ProgramFiles%\A;%ProgramFiles(x86)%\B;%SystemRoot%;%windir%;%ProgramData%' -ProfilePath '' |
            Should -BeExactly "$env:ProgramFiles\A;${env:ProgramFiles(x86)}\B;$env:SystemRoot;$env:windir;$env:ProgramData"
    }

    It 'never uses SYSTEM or the current user for a per-user variable' {
        Expand-AUEnvironmentText -Text '%USERPROFILE%\x;%LOCALAPPDATA%\y;%APPDATA%\z;%TEMP%' -ProfilePath '' | Should -BeExactly '%USERPROFILE%\x;%LOCALAPPDATA%\y;%APPDATA%\z;%TEMP%'
    }

    It 'expands USERPROFILE and LOCALAPPDATA from the owning profile, and leaves APPDATA, which can be redirected' {
        Expand-AUEnvironmentText -Text '%userprofile%\x;%LocalAppData%\y;%APPDATA%\z' -ProfilePath 'C:\Users\alice\' | Should -BeExactly 'C:\Users\alice\x;C:\Users\alice\AppData\Local\y;%APPDATA%\z'
    }

    It 'leaves an undefined variable and text without variables as they are' {
        Expand-AUEnvironmentText -Text '%AU_NOT_DEFINED_42%\x' -ProfilePath '' | Should -BeExactly '%AU_NOT_DEFINED_42%\x'
        Expand-AUEnvironmentText -Text 'C:\100% done' -ProfilePath '' | Should -BeExactly 'C:\100% done'
    }
}

Describe 'ConvertFrom-AUPackedGuid' {
    It 'unpacks a Windows Installer packed GUID' {
        ConvertFrom-AUPackedGuid '00002109030000000000000000F01FEC' | Should -BeExactly '{90120000-0030-0000-0000-0000000FF1CE}'
        ConvertFrom-AUPackedGuid $script:DeltaPacked | Should -BeExactly $script:DeltaCode
        ConvertFrom-AUPackedGuid 'not packed' | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-AUAppArray (F32, the v19 de-duplication moved into the region)' {
    It 'keeps one entry per DisplayName, the newest version, with the seven inventory fields' {
        $Apps = @(
            [pscustomobject]@{ DisplayName = 'B'; DisplayVersion = '1.10'; Publisher = 'P'; UninstallString = 'u1'; InstallDate = '01-02-2024'; PSPath = 'Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\Software\X\B1'; AppType = 'Win32' }
            [pscustomobject]@{ DisplayName = 'B'; DisplayVersion = '1.9'; Publisher = 'P'; UninstallString = 'u2'; InstallDate = $null; PSPath = 'Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\Software\X\B2'; AppType = 'Win32' }
            [pscustomobject]@{ DisplayName = 'A'; DisplayVersion = $null; Publisher = $null }
        )
        $Result = @(ConvertTo-AUAppArray -Apps $Apps)
        $Result.Count | Should -Be 2
        $Result[0].AppName | Should -Be 'A'
        $Result[0].AppVersion | Should -Be ''
        $Result[0].AppType | Should -Be 'Unknown'
        $Result[0].AppInstallDate | Should -BeNullOrEmpty
        $Result[0].AppUninstallRegPath | Should -BeNullOrEmpty
        $Result[1].AppVersion | Should -Be '1.10'
        $Result[1].AppUninstallString | Should -Be 'u1'
        $Result[1].AppInstallDate | Should -Be '01-02-2024'
        $Result[1].AppUninstallRegPath | Should -Be 'HKEY_LOCAL_MACHINE\Software\X\B1'
        @($Result[1].PSObject.Properties.Name) | Should -Be @('AppName', 'AppVersion', 'AppPublisher', 'AppType', 'AppInstallDate', 'AppUninstallString', 'AppUninstallRegPath')
    }

    It 'through ConvertTo-AUInventoryApps, keeps the newest parsable version and writes no error record for one that will not parse' {
        $Apps = @(
            [pscustomobject]@{ DisplayName = 'C'; DisplayVersion = '1.0 beta'; Publisher = 'P'; AppType = 'Win32'; RegPath = 'HKEY_LOCAL_MACHINE\Software\X\C1' }
            [pscustomobject]@{ DisplayName = 'C'; DisplayVersion = '2.0'; Publisher = 'P'; AppType = 'Win32'; RegPath = 'HKEY_LOCAL_MACHINE\Software\X\C2' }
        )
        $Output = @(ConvertTo-AUInventoryApps -Apps $Apps 2>&1)
        @($Output | Where-Object { $_ -is [Management.Automation.ErrorRecord] }).Count | Should -Be 0
        $Output.Count | Should -Be 1
        $Output[0].AppVersion | Should -Be '2.0'
        $Output[0].AppUninstallRegPath | Should -Be 'HKEY_LOCAL_MACHINE\Software\X\C2'
    }

    It 'returns nothing for no apps' {
        @(ConvertTo-AUAppArray -Apps $null).Count | Should -Be 0
    }

    It 'is the only copy: the inline App Inventory section calls it' {
        ([regex]::Matches($AUScriptText, 'Group-Object Displayname')).Count | Should -Be 2
        ([regex]::Matches($AURegionText, 'Group-Object Displayname')).Count | Should -Be 2
        $Inline = [regex]::Match($AUScriptText, '(?ms)^# region APPINVENTORY\r?\n(.*?)^# end region APPINVENTORY').Groups[1].Value
        $Inline | Should -Match ([regex]::Escape('$AppArray = @(ConvertTo-AUAppArray -Apps $MyApps)'))
        $Inline | Should -Not -Match 'Group-Object'
    }
}

Describe 'Get-AUInstalledApps' -Skip:(-not $script:IsAdmin) {
    BeforeAll { Use-FixtureMachine }

    It 'matches version 19 exactly for HKLM and the signed-in user (parity, F31)' {
        # Version 19 reads HKLM:\ and HKU:\ through Get-ItemProperty; send those to the same fixture.
        Mock New-PSDrive { }
        Mock Remove-PSDrive { }
        Mock Get-ItemProperty {
            $Mapped = foreach ($Item in $Path) { $Item -replace '^HKLM:\\', "Registry::HKEY_CURRENT_USER\$script:FixtureKey\M\" -replace '^HKU:\\', 'Registry::HKEY_USERS\' }
            & $script:RealGetItemProperty -Path $Mapped -Name $Name -ErrorAction SilentlyContinue | ForEach-Object {
                $_.PSPath = $_.PSPath.Replace("HKEY_CURRENT_USER\$script:FixtureKey\M", 'HKEY_LOCAL_MACHINE')
                $_
            }
        }
        $V19Apps = Get-InstalledApplications -UserSid $script:LoadedSid
        $V19Apps | ForEach-Object { $_ | Add-Member -NotePropertyName AppType -NotePropertyValue 'Win32' -Force }
        $Expected = @(ConvertTo-AUAppArray -Apps $V19Apps)

        $Result = Get-AUInstalledApps -Users @(New-TestUser $script:LoadedSid 'Loaded' $script:AlicePath)
        $Actual = @(ConvertTo-AUInventoryApps -Apps $Result.Apps)

        $Expected.Count | Should -Be 7
        ($Actual | ConvertTo-Json -Depth 3) | Should -BeExactly ($Expected | ConvertTo-Json -Depth 3)
        $Alpha = $Actual | Where-Object AppName -eq 'Contoso Alpha'
        $Alpha.AppInstallDate | Should -Match '^\d\d-\d\d-\d{4}$'
        ($Actual | Where-Object AppName -eq 'Contoso Delta').AppUninstallRegPath | Should -BeExactly "HKEY_LOCAL_MACHINE\$script:Uninstall\$script:DeltaCode"
        ($Actual | Where-Object AppName -eq 'Contoso Delta').AppInstallDate | Should -BeNullOrEmpty
        ($Actual | Where-Object AppName -eq 'Fabrikam Shared').AppInstallDate | Should -Be '02-01-2023'
        ($Actual | Where-Object AppName -eq 'Contoso Beta').AppVersion | Should -Be '2.5'
        ($Actual | Where-Object AppName -eq 'Contoso Gamma').AppUninstallRegPath | Should -BeExactly "HKEY_USERS\$script:LoadedSid\$script:Uninstall\Gamma"
        @($Actual | Where-Object { $_.PSObject.Properties.Name -contains 'Scope' }).Count | Should -Be 0
    }

    It 'gives each entry Task 5 fields, its scope, and an architecture from the registry view' {
        $Result = Get-AUInstalledApps -Users @(New-TestUser $script:LoadedSid 'Loaded' $script:AlicePath)
        $Apps = $Result.Apps
        $Alpha = @(Get-TestApp $Apps 'Contoso Alpha')
        $Alpha.Count | Should -Be 2
        $Alpha[0].Architecture | Should -Be 64
        $Alpha[0].Scope | Should -Be 'Machine'
        $Alpha[0].ProfilePath | Should -BeNullOrEmpty
        $Alpha[0].InstallLocation | Should -BeExactly "$env:ProgramFiles\Contoso\Alpha"
        $Alpha[0].UninstallString | Should -BeExactly "`"$env:ProgramFiles\Contoso\Alpha\uninst.exe`" /S"
        # A machine entry never takes SYSTEM's or anyone's per-user values.
        $Alpha[0].DisplayIcon | Should -BeExactly '%USERPROFILE%\alpha.ico'
        $Alpha[0].InstallDate | Should -Be '15-01-2024'
        $Alpha[0].RegPath | Should -BeExactly "HKEY_LOCAL_MACHINE\$script:Uninstall\Alpha"
        $Alpha[1].Architecture | Should -Be 32
        $Alpha[1].RegPath | Should -BeExactly "HKEY_LOCAL_MACHINE\$script:UninstallWow\Alpha32"
        (Get-TestApp $Apps 'Contoso Delta').ProductCode | Should -Be $script:DeltaCode
        (Get-TestApp $Apps 'Contoso Alpha')[0].ProductCode | Should -BeNullOrEmpty
        (Get-TestApp $Apps 'Contoso Delta').AppType | Should -Be 'Win32'
        $Gamma = Get-TestApp $Apps 'Contoso Gamma'
        $Gamma.Scope | Should -Be $script:LoadedSid
        $Gamma.ProfilePath | Should -Be $script:AlicePath
        $Gamma.InstallLocation | Should -BeExactly 'C:\Users\alice\AppData\Local\Programs\Gamma'
        $Gamma.DisplayIcon | Should -BeExactly '%APPDATA%\Gamma\gamma.exe'
        # HKEY_CURRENT_USER\Software is shared by 32-bit and 64-bit programs.
        $Gamma.Architecture | Should -BeNullOrEmpty
        (Get-TestApp $Apps 'Contoso Old32').Architecture | Should -Be 32
        foreach ($Field in @('DisplayName', 'Publisher', 'DisplayVersion', 'ProductCode', 'PackageFamily', 'InstallLocation', 'DisplayIcon', 'UninstallString', 'Architecture', 'Scope', 'ProfilePath', 'InstallDate', 'AppType', 'RegPath'))
        {
            $Gamma.PSObject.Properties.Name | Should -Contain $Field
        }
        @($Apps | Where-Object { $_.RegPath -match '\\(NoName|EmptyName)$' -or -not $_.DisplayName }).Count | Should -Be 0
        $Result.ScopeRead['Machine'] | Should -Be 'Read'
        $Result.ScopeRead[$script:LoadedSid] | Should -Be 'Read'
        $Result.ProfilesFound | Should -Be 1
        $Result.ProfilesRead | Should -Be 1
    }

    It 'reads a signed-out user from the hive copy: RegPath under HKEY_USERS\<SID>, a ProfilePath, and the mount unloaded (F13, F31, F34)' {
        $Bob = New-TestUser $script:CopiedSid 'Copied' $script:BobPath
        $Result = Get-AUInstalledApps -Users @($Bob) -Snapshot (New-TestSnapshot @{ $script:CopiedSid = $script:BobCopy })
        $Zeta = @(Get-TestApp $Result.Apps 'Contoso Zeta')
        $Zeta.Count | Should -Be 1
        $Zeta[0].RegPath | Should -BeExactly "HKEY_USERS\$script:CopiedSid\$script:Uninstall\Zeta"
        $Zeta[0].ProfilePath | Should -Be $script:BobPath
        $Zeta[0].Scope | Should -Be $script:CopiedSid
        $Zeta[0].InstallLocation | Should -BeExactly 'C:\Users\bob\AppData\Local\Zeta'
        @($Result.Apps | Where-Object { $_.RegPath -match 'AU_' }).Count | Should -Be 0
        $Result.ScopeRead[$script:CopiedSid] | Should -Be 'Read'
        $Bob.ProfileState | Should -Be 'Copied'
        Test-AUHiveLoaded -Sid (Get-AUHiveMountName $script:CopiedSid) | Should -BeFalse
    }

    It 'unloads a mount an earlier run left behind, then reads the copy' {
        $Stale = Join-Path $script:HiveFolder 'stale.dat'
        Copy-Item -LiteralPath $script:BobCopy -Destination $Stale
        $Mount = Get-AUHiveMountName $script:CopiedSid
        Invoke-TestReg "load `"HKU\$Mount`" `"$Stale`""
        $Result = Get-AUInstalledApps -Users @(New-TestUser $script:CopiedSid 'Copied' $script:BobPath) -Snapshot (New-TestSnapshot @{ $script:CopiedSid = $script:BobCopy })
        $Result.ScopeRead[$script:CopiedSid] | Should -Be 'Read'
        Test-AUHiveLoaded -Sid $Mount | Should -BeFalse
    }

    It 'gives CopyFailed and Unread when a hive copy will not load' {
        $Bob = New-TestUser $script:CopiedSid 'Copied' $script:BobPath
        $Result = Get-AUInstalledApps -Users @($Bob) -Snapshot (New-TestSnapshot @{ $script:CopiedSid = $script:BadCopy })
        $Bob.ProfileState | Should -Be 'CopyFailed'
        $Result.ScopeRead[$script:CopiedSid] | Should -Be 'Unread'
        $Result.ScopeRead['Machine'] | Should -Be 'Read'
        $Result.ProfilesRead | Should -Be 0
        @($Result.Apps | Where-Object Scope -eq $script:CopiedSid).Count | Should -Be 0
        Test-AUHiveLoaded -Sid (Get-AUHiveMountName $script:CopiedSid) | Should -BeFalse
    }

    It 'keeps one entry, the newer 1.5, for a per-user app at 1.2 signed in and 1.5 signed out (Review Focus 5)' {
        $Users = @((New-TestUser $script:LoadedSid 'Loaded' $script:AlicePath), (New-TestUser $script:CopiedSid 'Copied' $script:BobPath))
        $Result = Get-AUInstalledApps -Users $Users -Snapshot (New-TestSnapshot @{ $script:CopiedSid = $script:BobCopy })
        @(Get-TestApp $Result.Apps 'Contoso Omega').Count | Should -Be 2
        $Inventory = @(ConvertTo-AUInventoryApps -Apps $Result.Apps)
        $Omega = @($Inventory | Where-Object AppName -eq 'Contoso Omega')
        $Omega.Count | Should -Be 1
        $Omega[0].AppVersion | Should -Be '1.5'
        $Omega[0].AppUninstallRegPath | Should -BeExactly "HKEY_USERS\$script:CopiedSid\$script:Uninstall\Omega"
        # The signed-out user's other app is added; the list is otherwise version 19's.
        @($Inventory | Where-Object AppName -eq 'Contoso Zeta').Count | Should -Be 1
        $Inventory.Count | Should -Be 8
        $Result.ProfilesFound | Should -Be 2
        $Result.ProfilesRead | Should -Be 2
    }

    It 'maps executables Windows Installer records to their ProductCode, with no inventory entry from UserData alone (F33)' {
        $Result = Get-AUInstalledApps -Users @()
        $Map = $Result.MsiFileMap
        $Map['c:\program files\contoso\epsilon\epsilon.exe'] | Should -BeExactly $script:EpsilonCode
        $Map['c:\program files\contoso\delta\delta.exe'] | Should -BeExactly $script:DeltaCode
        $Map['c:\program files\contoso\delta\helper.exe'] | Should -BeExactly $script:DeltaCode
        # Shared by two products, a component with no product, a registry key path, and a file that isn't an .exe.
        $Map.ContainsKey('c:\program files\shared\common.exe') | Should -BeFalse
        $Map.ContainsKey('c:\program files\contoso\delta\zero.exe') | Should -BeFalse
        $Map.Count | Should -Be 3
        @(Get-TestApp $Result.Apps 'Contoso Epsilon').Count | Should -Be 0
        @(ConvertTo-AUInventoryApps -Apps $Result.Apps | Where-Object AppName -eq 'Contoso Epsilon').Count | Should -Be 0
        @($Map.Keys | Where-Object { $_ -cne $_.ToLowerInvariant() }).Count | Should -Be 0
    }

    It 'reads SYSTEM''s hive as machine scope, and S-1-5-18 has the machine''s read state' {
        $Result = Get-AUInstalledApps -Users @(New-TestUser 'S-1-5-18' 'Loaded' 'C:\Windows\system32\config\systemprofile' 'System')
        $Tool = Get-TestApp $Result.Apps 'Contoso System Tool'
        $Tool.Scope | Should -Be 'Machine'
        $Tool.ProfilePath | Should -BeNullOrEmpty
        $Tool.RegPath | Should -BeExactly "HKEY_USERS\S-1-5-18\$script:Uninstall\SysTool"
        $Result.ScopeRead['Machine'] | Should -Be 'Read'
        $Result.ScopeRead['S-1-5-18'] | Should -Be 'Read'
        $Result.ProfilesRead | Should -Be 1
    }

    It 'returns one object and writes nothing else to the pipeline' {
        $Output = @(Get-AUInstalledApps -Users @(New-TestUser $script:LoadedSid 'Loaded' $script:AlicePath))
        $Output.Count | Should -Be 1
        $Output[0].PSObject.Properties.Name | Should -Be @('Apps', 'ScopeRead', 'MsiFileMap', 'ProfilesFound', 'ProfilesRead')
    }
}

Describe 'Get-AUInstalledApps without reading hives' {
    BeforeAll { Use-FixtureMachine }

    It 'marks a user Unread when the copy will not load, without throwing' {
        Mock Mount-AUHive { $false }
        $Bob = New-TestUser $script:CopiedSid 'Copied' $script:BobPath
        $Result = Get-AUInstalledApps -Users @($Bob) -Snapshot (New-TestSnapshot @{ $script:CopiedSid = $script:BobCopy })
        $Bob.ProfileState | Should -Be 'CopyFailed'
        $Result.ScopeRead[$script:CopiedSid] | Should -Be 'Unread'
        Should -Invoke Mount-AUHive -Times 1 -Exactly -ParameterFilter { $MountName -eq "AU_$script:CopiedSid" }
    }

    It 'leaves CopyFailed and Missing users Unread and counts them as found, not read' {
        $Users = @((New-TestUser 'S-1-5-21-9-9-9-1' 'CopyFailed' 'C:\Users\a'), (New-TestUser 'S-1-5-21-9-9-9-2' 'Missing' 'C:\Users\b'))
        $Result = Get-AUInstalledApps -Users $Users
        $Result.ScopeRead['S-1-5-21-9-9-9-1'] | Should -Be 'Unread'
        $Result.ScopeRead['S-1-5-21-9-9-9-2'] | Should -Be 'Unread'
        $Result.ProfilesFound | Should -Be 2
        $Result.ProfilesRead | Should -Be 0
    }

    It 'keeps SYSTEM''s per-user installs but not LocalService''s or NetworkService''s, whose scopes are still read' {
        $Users = @(
            (New-TestUser 'S-1-5-18' 'Loaded' 'C:\Windows\system32\config\systemprofile' 'System')
            (New-TestUser 'S-1-5-19' 'Loaded' 'C:\Windows\ServiceProfiles\LocalService' 'Service')
            (New-TestUser 'S-1-5-20' 'Loaded' 'C:\Windows\ServiceProfiles\NetworkService' 'Service')
        )
        $Result = Get-AUInstalledApps -Users $Users
        @(Get-TestApp $Result.Apps 'Contoso System Tool').Count | Should -Be 1
        @(Get-TestApp $Result.Apps 'Contoso LocalService Tool').Count | Should -Be 0
        @(Get-TestApp $Result.Apps 'Contoso NetworkService Tool').Count | Should -Be 0
        @($Result.Apps | Where-Object { $_.Scope -in @('S-1-5-19', 'S-1-5-20') -or $_.RegPath -match 'S-1-5-(19|20)\\' }).Count | Should -Be 0
        $Inventory = @(ConvertTo-AUInventoryApps -Apps $Result.Apps)
        @($Inventory | Where-Object { $_.AppName -in @('Contoso LocalService Tool', 'Contoso NetworkService Tool') }).Count | Should -Be 0
        @($Inventory | Where-Object AppName -eq 'Contoso System Tool').Count | Should -Be 1
        $Result.ScopeRead['S-1-5-19'] | Should -Be 'Read'
        $Result.ScopeRead['S-1-5-20'] | Should -Be 'Read'
        $Result.ProfilesFound | Should -Be 3
        $Result.ProfilesRead | Should -Be 3
        Should -Invoke Open-AURegistryBase -ParameterFilter { $Name -eq 'S-1-5-20' } -Times 1 -Exactly
    }

    It 'marks Machine Unread, and does not throw, when HKLM cannot be read' {
        Mock Open-AURegistryBase -ParameterFilter { $Hive -eq 'Machine' } { throw 'denied' }
        $Result = Get-AUInstalledApps -Users @()
        $Result.ScopeRead['Machine'] | Should -Be 'Unread'
        $Result.ScopeRead['S-1-5-18'] | Should -Be 'Unread'
        @($Result.Apps).Count | Should -Be 0
    }

    Context 'Store and MSIX packages (D46, F35)' {
        BeforeAll {
            Mock Get-AUAppxPackages {
                @(
                    [pscustomobject]@{
                        Name = 'Contoso.Notes'; Version = '5.0.1.0'; PackageFullName = 'Contoso.Notes_5.0.1.0_x64__abc'; PackageFamilyName = 'Contoso.Notes_abc'
                        InstallLocation = 'C:\Program Files\WindowsApps\Contoso.Notes_5.0.1.0_x64__abc'; Architecture = 'X64'
                        PackageUserInformation = @(
                            [pscustomobject]@{ UserSecurityId = [pscustomobject]@{ Sid = 'S-1-5-21-9-9-9-1' }; InstallState = 'Installed' }
                            [pscustomobject]@{ UserSecurityId = [pscustomobject]@{ Sid = 'S-1-5-18' }; InstallState = 'Installed' }
                            [pscustomobject]@{ UserSecurityId = [pscustomobject]@{ Sid = 'S-1-5-19' }; InstallState = 'Installed' }
                        )
                    }
                    [pscustomobject]@{
                        Name = 'Contoso.ServiceOnly'; Version = '2.0.0.0'; PackageFullName = 'Contoso.ServiceOnly_2.0.0.0_x64__abc'; PackageFamilyName = 'Contoso.ServiceOnly_abc'
                        InstallLocation = 'C:\Program Files\WindowsApps\Contoso.ServiceOnly'; Architecture = 'X64'
                        PackageUserInformation = @([pscustomobject]@{ UserSecurityId = [pscustomobject]@{ Sid = 'S-1-5-20' }; InstallState = 'Installed' })
                    }
                    [pscustomobject]@{
                        Name = 'Contoso.Staged'; Version = '1.0.0.0'; PackageFullName = 'Contoso.Staged_1.0.0.0_x86__abc'; PackageFamilyName = 'Contoso.Staged_abc'
                        InstallLocation = 'C:\Program Files\WindowsApps\Contoso.Staged'; Architecture = 'X86'
                        PackageUserInformation = @([pscustomobject]@{ UserSecurityId = [pscustomobject]@{ Sid = 'S-1-5-21-9-9-9-1' }; InstallState = 'Staged' })
                    }
                )
            }
            Mock Get-AUAppxPublisher { 'Contoso Ltd' }
            $script:StoreUsers = @(New-TestUser 'S-1-5-21-9-9-9-1' 'CopyFailed' 'C:\Users\carol')
        }

        It 'returns no Store or MSIX package without -IncludeStore' {
            $Result = Get-AUInstalledApps -Users $script:StoreUsers
            @($Result.Apps | Where-Object { $_.AppType -eq 'UWP' -or $_.PackageFamily }).Count | Should -Be 0
            Should -Invoke Get-AUAppxPackages -Times 0 -Exactly
        }

        It 'returns installed packages with -IncludeStore, one entry per user, and puts them in the inventory' {
            $Result = Get-AUInstalledApps -Users $script:StoreUsers -IncludeStore
            $Notes = @(Get-TestApp $Result.Apps 'Contoso.Notes')
            $Notes.Count | Should -Be 2
            $Carol = $Notes | Where-Object Scope -eq 'S-1-5-21-9-9-9-1'
            $Carol.PackageFamily | Should -Be 'Contoso.Notes_abc'
            $Carol.DisplayVersion | Should -Be '5.0.1.0'
            $Carol.Publisher | Should -Be 'Contoso Ltd'
            $Carol.AppType | Should -Be 'UWP'
            $Carol.Architecture | Should -Be 'X64'
            $Carol.ProfilePath | Should -Be 'C:\Users\carol'
            $Carol.InstallLocation | Should -Be 'C:\Program Files\WindowsApps\Contoso.Notes_5.0.1.0_x64__abc'
            ($Notes | Where-Object Scope -eq 'Machine').ProfilePath | Should -BeNullOrEmpty
            @(Get-TestApp $Result.Apps 'Contoso.Staged').Count | Should -Be 0
            # Installed for LocalService or NetworkService: not anyone's app.
            @($Notes | Where-Object { $_.Scope -in @('S-1-5-19', 'S-1-5-20') }).Count | Should -Be 0
            @(Get-TestApp $Result.Apps 'Contoso.ServiceOnly').Count | Should -Be 0
            $Inventory = @(ConvertTo-AUInventoryApps -Apps $Result.Apps | Where-Object AppName -eq 'Contoso.Notes')
            $Inventory.Count | Should -Be 1
            $Inventory[0].AppType | Should -Be 'UWP'
            $Inventory[0].AppPublisher | Should -Be 'Contoso Ltd'
            $Inventory[0].AppUninstallRegPath | Should -BeNullOrEmpty
        }

        It 'marks every user Unread when the packages cannot be read with -IncludeStore' {
            Mock Get-AUAppxPackages { throw 'Get-AppxPackage failed' }
            $Result = Get-AUInstalledApps -Users @(New-TestUser 'S-1-5-18' 'Loaded' 'C:\Windows\system32\config\systemprofile' 'System') -IncludeStore
            $Result.ScopeRead['Machine'] | Should -Be 'Read'
            $Result.ScopeRead['S-1-5-18'] | Should -Be 'Unread'
        }
    }

    It 'never creates or removes a PSDrive named HKU (F34)' {
        Mock New-PSDrive { }
        Mock Remove-PSDrive { }
        Mock Get-AUProfileList { @([pscustomobject]@{ Sid = 'S-1-5-21-9-9-9-1'; ProfilePath = 'C:\Users\a' }) }
        Mock Get-AUAppxPackages { @() }
        $Users = @(Get-AUUsers -Snapshot (New-TestSnapshot))
        $Result = Get-AUInstalledApps -Users $Users -Snapshot (New-TestSnapshot) -IncludeStore
        $null = ConvertTo-AUInventoryApps -Apps $Result.Apps
        Should -Invoke New-PSDrive -Times 0 -Exactly
        Should -Invoke Remove-PSDrive -Times 0 -Exactly
        $AURegionText | Should -Not -Match 'New-PSDrive|Remove-PSDrive|Get-PSDrive|HKU:'
    }
}
