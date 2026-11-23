BeforeAll {
    . "$PSScriptRoot\_Import.ps1"

    $script:ShadowRoot = '\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy9'
    $script:ShadowId = '{11111111-2222-3333-4444-555555555555}'
    $script:SignedOutSid = 'S-1-5-21-1-2-3-1001'

    # Owned by SYSTEM or Administrators; protected (inheritance off); exactly SYSTEM and Administrators,
    # full control, Allow.
    function Assert-ProtectedFolderAcl([string]$Path)
    {
        $Acl = Get-Acl -LiteralPath $Path
        $Acl.GetOwner([Security.Principal.SecurityIdentifier]).Value | Should -BeIn @('S-1-5-18', 'S-1-5-32-544')
        $Acl.AreAccessRulesProtected | Should -BeTrue
        $Rules = @($Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        $Rules.Count | Should -Be 2
        @($Rules | ForEach-Object { $_.IdentityReference.Value } | Sort-Object) | Should -Be @('S-1-5-18', 'S-1-5-32-544')
        foreach ($Rule in $Rules)
        {
            $Rule.AccessControlType | Should -Be 'Allow'
            $Rule.FileSystemRights | Should -Be ([Security.AccessControl.FileSystemRights]::FullControl)
            $Rule.IsInherited | Should -BeFalse
        }
    }

    function New-TestWorkDir
    {
        return New-AUWorkDir -RunId ([guid]::NewGuid().ToString('N')) -Root (Join-Path $TestDrive 'PowerStacksAppUsage')
    }
}

Describe 'New-AUWorkDir (F28, D18)' {
    It 'creates the run folder with a protected DACL for SYSTEM and Administrators only, on the root too' {
        $Root = Join-Path $TestDrive 'PowerStacksAppUsage'
        $Output = @(New-AUWorkDir -RunId 'run-1' -Root $Root)
        $Output.Count | Should -Be 1
        $Path = $Output[0]
        $Path | Should -Be (Join-Path $Root 'run-1')
        Test-Path -LiteralPath $Path -PathType Container | Should -BeTrue
        Assert-ProtectedFolderAcl $Root
        Assert-ProtectedFolderAcl $Path
    }

    It 'gives copies made in the run folder only the SYSTEM and Administrators entries' {
        $Path = New-TestWorkDir
        $File = Join-Path $Path 'copy.dat'
        [IO.File]::WriteAllText($File, 'x')
        $Rules = @((Get-Acl -LiteralPath $File).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        @($Rules | ForEach-Object { $_.IdentityReference.Value } | Sort-Object) | Should -Be @('S-1-5-18', 'S-1-5-32-544')
    }

    It 'defaults to C:\Windows\PowerStacksAppUsage, next to the ledger, where standard users cannot create items' {
        $script:AUWorkRoot | Should -Be (Join-Path $env:SystemRoot 'PowerStacksAppUsage')
        (Get-Command New-AUWorkDir).Parameters['Root'] | Should -Not -BeNullOrEmpty
    }

    Context 'an existing root it does not trust' {
        BeforeEach {
            $script:Me = [Security.Principal.WindowsIdentity]::GetCurrent().User
            $script:Admins = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'
            $script:Root = Join-Path $TestDrive "Untrusted-$([guid]::NewGuid().ToString('N'))"
            $script:Target = Join-Path $TestDrive "Target-$([guid]::NewGuid().ToString('N'))"
            $null = New-Item -ItemType Directory -Path $script:Target
            [IO.File]::WriteAllText((Join-Path $script:Target 'keep.txt'), 'keep')
            $script:TargetSddl = (Get-Acl -LiteralPath $script:Target).Sddl
            Mock Remove-AUFolderTree { }
            Mock Clear-AUStaleRuns { }
            Mock New-AUProtectedFolder { }
        }

        It 'skips with SrumReadFailed:WorkDirUntrusted and leaves a <Kind> exactly as it was' -ForEach @(
            @{ Kind = 'file' }
            @{ Kind = 'junction' }
            @{ Kind = 'folder a standard user owns' }
            @{ Kind = 'administrator-owned folder with an inherited DACL' }
            @{ Kind = 'protected folder that also lets Users in' }
        ) {
            switch ($Kind)
            {
                'file' { [IO.File]::WriteAllText($script:Root, 'planted') }
                'junction' { $null = & cmd.exe /d /c mklink /j "$($script:Root)" "$($script:Target)" }
                'folder a standard user owns'
                {
                    $null = New-Item -ItemType Directory -Path $script:Root
                    $Acl = Get-Acl -LiteralPath $script:Root
                    $Acl.SetOwner($script:Me)
                    Set-Acl -LiteralPath $script:Root -AclObject $Acl
                }
                'administrator-owned folder with an inherited DACL'
                {
                    $null = New-Item -ItemType Directory -Path $script:Root
                    $Acl = Get-Acl -LiteralPath $script:Root
                    $Acl.SetOwner($script:Admins)
                    Set-Acl -LiteralPath $script:Root -AclObject $Acl
                }
                'protected folder that also lets Users in'
                {
                    $Security = New-AUProtectedSecurity -Folder
                    $Security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-545'), 'Modify', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
                    [void][IO.Directory]::CreateDirectory($script:Root, $Security)
                }
            }
            if ($Kind -ne 'file' -and $Kind -ne 'junction') { [IO.File]::WriteAllText((Join-Path $script:Root 'planted.txt'), 'planted') }
            $Attributes = [IO.File]::GetAttributes($script:Root)
            $Sddl = $(if ($Kind -ne 'junction') { (Get-Acl -LiteralPath $script:Root).Sddl })
            Test-AUTrustedFolder -Path $script:Root | Should -BeFalse

            { New-AUWorkDir -RunId 'run-x' -Root $script:Root } | Should -Throw -ExpectedMessage 'SrumReadFailed:WorkDirUntrusted*'

            [IO.File]::GetAttributes($script:Root) | Should -Be $Attributes
            if ($Kind -ne 'junction') { (Get-Acl -LiteralPath $script:Root).Sddl | Should -Be $Sddl }
            if ($Kind -ne 'file' -and $Kind -ne 'junction')
            {
                Test-Path -LiteralPath (Join-Path $script:Root 'planted.txt') | Should -BeTrue
                Test-Path -LiteralPath (Join-Path $script:Root 'run-x') | Should -BeFalse
            }
            @(Get-Item -Path "$($script:Root).*" -Force -ErrorAction SilentlyContinue).Count | Should -Be 0
            (Get-Acl -LiteralPath $script:Target).Sddl | Should -Be $script:TargetSddl
            Test-Path -LiteralPath (Join-Path $script:Target 'keep.txt') | Should -BeTrue
            Should -Invoke Remove-AUFolderTree -Times 0
            Should -Invoke Clear-AUStaleRuns -Times 0
            Should -Invoke New-AUProtectedFolder -Times 0
        }

    }

    It 'skips when the trust check fails for any other reason' {
        $Root = Join-Path $TestDrive 'MockedTrust'
        $null = New-AUWorkDir -RunId 'first' -Root $Root
        Mock Test-AUTrustedFolder { $false }
        Mock Clear-AUStaleRuns { }
        { New-AUWorkDir -RunId 'second' -Root $Root } | Should -Throw -ExpectedMessage 'SrumReadFailed:WorkDirUntrusted*'
        Test-Path -LiteralPath (Join-Path $Root 'second') | Should -BeFalse
        Should -Invoke Clear-AUStaleRuns -Times 0
    }

    It 'skips when the run folder already exists, and never changes it' {
        $Root = Join-Path $TestDrive 'ExistingRun'
        $null = New-AUWorkDir -RunId 'first' -Root $Root
        $null = New-Item -ItemType Directory -Path (Join-Path $Root 'taken')
        $Sddl = (Get-Acl -LiteralPath (Join-Path $Root 'taken')).Sddl
        { New-AUWorkDir -RunId 'taken' -Root $Root } | Should -Throw -ExpectedMessage 'SrumReadFailed:WorkDirUntrusted*'
        (Get-Acl -LiteralPath (Join-Path $Root 'taken')).Sddl | Should -Be $Sddl
    }

    It 'rejects a RunId that is not a plain folder name' {
        { New-AUWorkDir -RunId '..\escape' -Root (Join-Path $TestDrive 'R') } | Should -Throw
        { New-AUWorkDir -RunId '' -Root (Join-Path $TestDrive 'R') } | Should -Throw
    }
}

Describe 'Test-AUTrustedFolder and Test-AUItemPresent' {
    It 'trusts only a protected folder it created' {
        $Root = Join-Path $TestDrive 'Trusted'
        New-AUProtectedFolder -Path $Root
        Test-AUTrustedFolder -Path $Root | Should -BeTrue
        Test-AUTrustedFolder -Path (Join-Path $TestDrive 'missing') | Should -BeFalse
        Test-AUTrustedFolder -Path $TestDrive | Should -BeFalse
    }

    It 'tells a missing path from a file, a folder, and a broken link' {
        Test-AUItemPresent -Path (Join-Path $TestDrive 'missing') | Should -BeFalse
        Test-AUItemPresent -Path (Join-Path $TestDrive 'missing\deeper') | Should -BeFalse
        [IO.File]::WriteAllText((Join-Path $TestDrive 'a-file'), 'x')
        Test-AUItemPresent -Path (Join-Path $TestDrive 'a-file') | Should -BeTrue
        $Gone = Join-Path $TestDrive 'gone-target'
        $null = New-Item -ItemType Directory -Path $Gone
        $Link = Join-Path $TestDrive 'broken-link'
        $null = & cmd.exe /d /c mklink /j "$Link" "$Gone"
        Remove-Item -LiteralPath $Gone
        Test-AUItemPresent -Path $Link | Should -BeTrue
    }
}

Describe 'Stale run cleanup (F28)' {
    BeforeAll {
        function New-StaleRun([string]$Root, [string]$Name, [double]$HoursAgo)
        {
            $Path = Join-Path $Root $Name
            New-AUProtectedFolder -Path $Path
            $null = New-Item -ItemType Directory -Path (Join-Path $Path 'sru')
            [IO.File]::WriteAllText((Join-Path $Path 'sru\SRUDB.dat'), 'copy')
            [IO.Directory]::SetCreationTimeUtc($Path, [datetime]::UtcNow.AddHours(-$HoursAgo))
            return $Path
        }
    }

    BeforeEach {
        $script:Root = Join-Path $TestDrive "Sweep-$([guid]::NewGuid().ToString('N'))"
        $null = New-AUWorkDir -RunId 'setup' -Root $script:Root
        $script:Id = '{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}'
        # The shadow copy exists and was made 2 hours ago, unless a test says otherwise.
        $script:InstallDate = (Get-Date).AddHours(-2)
        Mock Get-CimInstance { [pscustomobject]@{ ID = $script:Id; InstallDate = $script:InstallDate } } -ParameterFilter { $ClassName -eq 'Win32_ShadowCopy' }
        Mock Remove-AUShadowCopy { $true }
    }

    It 'skips the sweep on a root this call created' {
        Mock Clear-AUStaleRuns { }
        $Fresh = Join-Path $TestDrive "Fresh-$([guid]::NewGuid().ToString('N'))"
        $null = New-AUWorkDir -RunId 'one' -Root $Fresh
        Should -Invoke Clear-AUStaleRuns -Times 0 -Exactly
        $null = New-AUWorkDir -RunId 'two' -Root $Fresh
        Should -Invoke Clear-AUStaleRuns -Times 1 -Exactly
    }

    It 'removes a protected run folder more than 24 hours old, and the shadow copy its marker names when that run made it' {
        $Old = New-StaleRun $script:Root 'old-run' 25
        Write-AUShadowMarker -Folder $Old -ShadowId $script:Id
        $Recent = New-StaleRun $script:Root 'recent-run' 23
        $null = New-AUWorkDir -RunId 'current' -Root $script:Root
        Test-Path -LiteralPath $Old | Should -BeFalse
        Test-Path -LiteralPath $Recent | Should -BeTrue
        Should -Invoke Remove-AUShadowCopy -Times 1 -Exactly -ParameterFilter { $ShadowId -eq $script:Id }
    }

    It 'never deletes a shadow copy made outside the run folder''s lifetime, or one that does not exist' {
        $Old = New-StaleRun $script:Root 'old-run' 25
        Write-AUShadowMarker -Folder $Old -ShadowId $script:Id
        $script:InstallDate = (Get-Date).AddHours(-30)
        $null = New-AUWorkDir -RunId 'current' -Root $script:Root
        Test-Path -LiteralPath $Old | Should -BeFalse
        Should -Invoke Remove-AUShadowCopy -Times 0

        $Old2 = New-StaleRun $script:Root 'old-run-2' 25
        Write-AUShadowMarker -Folder $Old2 -ShadowId $script:Id
        Mock Get-CimInstance { } -ParameterFilter { $ClassName -eq 'Win32_ShadowCopy' }
        $null = New-AUWorkDir -RunId 'current-2' -Root $script:Root
        Should -Invoke Remove-AUShadowCopy -Times 0
    }

    It 'never acts on a marker that a standard user owns' {
        $Old = New-StaleRun $script:Root 'old-run' 25
        $Marker = Join-Path $Old 'shadow.id'
        [IO.File]::WriteAllText($Marker, $script:Id)
        $Acl = Get-Acl -LiteralPath $Marker
        $Acl.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User)
        Set-Acl -LiteralPath $Marker -AclObject $Acl
        Read-AUShadowMarker -Folder $Old | Should -BeNullOrEmpty
        $null = New-AUWorkDir -RunId 'current' -Root $script:Root
        Should -Invoke Remove-AUShadowCopy -Times 0
    }

    It 'never deletes a backdated run folder that is not protected or that a standard user owns' {
        Mock Remove-AUFolderTree { }
        $Planted = Join-Path $script:Root 'planted-run'
        $null = New-Item -ItemType Directory -Path $Planted
        [IO.File]::WriteAllText((Join-Path $Planted 'planted.txt'), 'planted')
        $Acl = Get-Acl -LiteralPath $Planted
        $Acl.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User)
        Set-Acl -LiteralPath $Planted -AclObject $Acl
        [IO.Directory]::SetCreationTimeUtc($Planted, [datetime]::UtcNow.AddHours(-48))
        $Inherited = Join-Path $script:Root 'inherited-run'
        $null = New-Item -ItemType Directory -Path $Inherited
        [IO.Directory]::SetCreationTimeUtc($Inherited, [datetime]::UtcNow.AddHours(-48))

        $null = New-AUWorkDir -RunId 'current' -Root $script:Root
        Test-Path -LiteralPath (Join-Path $Planted 'planted.txt') | Should -BeTrue
        Test-Path -LiteralPath $Inherited | Should -BeTrue
        Should -Invoke Remove-AUFolderTree -Times 0
        Should -Invoke Remove-AUShadowCopy -Times 0
    }

    It 'never follows or removes a link in the work root' {
        $Target = Join-Path $TestDrive "sweep-target-$([guid]::NewGuid().ToString('N'))"
        $null = New-Item -ItemType Directory -Path $Target
        [IO.File]::WriteAllText((Join-Path $Target 'keep.txt'), 'keep')
        [IO.Directory]::SetCreationTimeUtc($Target, [datetime]::UtcNow.AddHours(-48))
        $Link = Join-Path $script:Root 'link'
        $null = & cmd.exe /d /c mklink /j "$Link" "$Target"

        $null = New-AUWorkDir -RunId 'current' -Root $script:Root
        Test-Path -LiteralPath $Link | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $Target 'keep.txt') | Should -BeTrue
    }

    It 'lists nothing when the root has become a link' {
        Mock Test-AUReparsePoint { $true } -ParameterFilter { $Path -eq $script:Root }
        Mock Remove-AUFolderTree { }
        $null = New-StaleRun $script:Root 'old-run' 25
        Clear-AUStaleRuns -Root $script:Root -Except 'current' -MaxAgeHours 24
        Should -Invoke Remove-AUFolderTree -Times 0
    }
}

Describe 'New-AUSnapshot' {
    BeforeEach {
        $script:WorkDir = New-TestWorkDir
        $script:Copied = New-Object System.Collections.Generic.List[string]
        Mock Get-AUMachineDomainSid { 'S-1-5-21-1-2-3' }
        Mock Get-AUProfileList {
            [pscustomobject]@{ Sid = 'S-1-5-21-1-2-3-500'; ProfilePath = "$env:SystemDrive\Users\signedin" }
            [pscustomobject]@{ Sid = $script:SignedOutSid; ProfilePath = "$env:SystemDrive\Users\signedout" }
            [pscustomobject]@{ Sid = 'S-1-12-1-9-9-9-9'; ProfilePath = 'D:\Users\otherdrive' }
        }
        Mock Test-AUHiveLoaded { $Sid -eq 'S-1-5-21-1-2-3-500' }
        # Stands in for mklink: a plain folder where the link would be.
        Mock Mount-AUShadow { [void][IO.Directory]::CreateDirectory($LinkPath); $true }
        # Stands in for the copy: records the source and writes the destination file.
        Mock Copy-AUShadowFile {
            $script:Copied.Add($Source)
            if ($Source.EndsWith('\*')) { $File = Join-Path $Destination 'SRUDB.dat' } else { $File = $Destination }
            [IO.File]::WriteAllText($File, 'copy')
            return $true
        }
        # Records how many copies were made when the shadow copy was released.
        $script:CopiesAtRelease = $null
        Mock Remove-AUShadowCopy { $script:CopiesAtRelease = $script:Copied.Count; $true }
        # Plenty of free space, unless a test says otherwise.
        Mock Get-AUFreeSpace { [long]100GB }
    }

    It 'gives ShadowCopyFailed, a null SrumDbPath, and no copies when the shadow copy fails' {
        Mock Invoke-CimMethod { [pscustomobject]@{ ReturnValue = 5; ShadowID = $null } }
        $S = New-AUSnapshot -WorkDir $script:WorkDir
        $S.Status | Should -Be 'ShadowCopyFailed'
        $S.SrumDbPath | Should -BeNullOrEmpty
        $S.ShadowId | Should -BeNullOrEmpty
        $S.WorkDir | Should -Be $script:WorkDir
        $S.MachineDomainSid | Should -Be 'S-1-5-21-1-2-3'
        $S.HiveCopies.ContainsKey($script:SignedOutSid) | Should -BeTrue
        $S.HiveCopies[$script:SignedOutSid] | Should -BeNullOrEmpty
        Should -Invoke Copy-AUShadowFile -Times 0
        Should -Invoke Remove-AUShadowCopy -Times 0
    }

    It 'counts a profile off the system drive in the log without naming its SID or folder (D18)' {
        Mock Invoke-CimMethod { [pscustomobject]@{ ReturnValue = 0; ShadowID = $script:ShadowId } }
        Mock Get-CimInstance { [pscustomobject]@{ ID = $script:ShadowId; DeviceObject = $script:ShadowRoot } } -ParameterFilter { $ClassName -eq 'Win32_ShadowCopy' }
        # A logger with the real one's parameters, so the filter can read the message.
        function Write-CMTraceLog { param ([string]$Message, [string]$Component, [int]$Type) }
        Mock Write-CMTraceLog { }
        $null = New-AUSnapshot -WorkDir $script:WorkDir
        Should -Invoke Write-CMTraceLog -Times 1 -Exactly -ParameterFilter { $Message -like "App Usage: 1 signed-out profiles aren't on *" }
        Should -Invoke Write-CMTraceLog -Times 0 -ParameterFilter { $Message -match 'S-1-12-1-9-9-9-9|otherdrive|signedout|S-1-5-21-1-2-3-1001' }
    }

    It 'copies SRUM and signed-out hives only from the shadow root, into the work folder' {
        Mock Invoke-CimMethod { [pscustomobject]@{ ReturnValue = 0; ShadowID = $script:ShadowId } }
        Mock Get-CimInstance { [pscustomobject]@{ ID = $script:ShadowId; DeviceObject = $script:ShadowRoot } } -ParameterFilter { $ClassName -eq 'Win32_ShadowCopy' }
        $Output = @(New-AUSnapshot -WorkDir $script:WorkDir)
        $Output.Count | Should -Be 1
        $S = $Output[0]
        $S.Status | Should -Be 'OK'
        $S.ShadowRoot | Should -Be $script:ShadowRoot
        $S.SrumDbPath | Should -Be (Join-Path $script:WorkDir 'sru\SRUDB.dat')
        $S.HiveCopies[$script:SignedOutSid] | Should -Be (Join-Path $script:WorkDir "hives\$($script:SignedOutSid)\NTUSER.DAT")
        $S.HiveCopies.ContainsKey('S-1-5-21-1-2-3-500') | Should -BeFalse
        # A profile off the shadowed volume can't be copied, so it's a failed copy, never a live read.
        $S.HiveCopies.ContainsKey('S-1-12-1-9-9-9-9') | Should -BeTrue
        $S.HiveCopies['S-1-12-1-9-9-9-9'] | Should -BeNullOrEmpty
        # Every copy comes through the shadow link, and the link is gone afterwards.
        $Link = Join-Path $script:WorkDir 'shadow'
        Should -Invoke Mount-AUShadow -Times 1 -ParameterFilter { $ShadowRoot -eq $script:ShadowRoot -and $LinkPath -eq $Link }
        $script:Copied.Count | Should -BeGreaterThan 0
        foreach ($Source in $script:Copied) { $Source.StartsWith("$Link\", [StringComparison]::OrdinalIgnoreCase) | Should -BeTrue }
        $script:Copied | Should -Contain "$Link\Windows\System32\sru\*"
        $script:Copied | Should -Contain "$Link\Users\signedout\NTUSER.DAT"
        Test-Path -LiteralPath $Link | Should -BeFalse
        # The shadow copy is released once, after every copy, and its marker goes with it.
        Should -Invoke Remove-AUShadowCopy -Times 1 -Exactly -ParameterFilter { $ShadowId -eq $script:ShadowId }
        $script:CopiesAtRelease | Should -Be $script:Copied.Count
        $S.ShadowId | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $script:WorkDir 'shadow.id') | Should -BeFalse
    }

    It 'gives ShadowCopyFailed when the shadow copy cannot be linked, and still releases it' {
        Mock Invoke-CimMethod { [pscustomobject]@{ ReturnValue = 0; ShadowID = $script:ShadowId } }
        Mock Get-CimInstance { [pscustomobject]@{ ID = $script:ShadowId; DeviceObject = $script:ShadowRoot } } -ParameterFilter { $ClassName -eq 'Win32_ShadowCopy' }
        Mock Mount-AUShadow { $false }
        $S = New-AUSnapshot -WorkDir $script:WorkDir
        $S.Status | Should -Be 'ShadowCopyFailed'
        $S.SrumDbPath | Should -BeNullOrEmpty
        $S.ShadowId | Should -BeNullOrEmpty
        Should -Invoke Copy-AUShadowFile -Times 0
        Should -Invoke Remove-AUShadowCopy -Times 1 -Exactly -ParameterFilter { $ShadowId -eq $script:ShadowId }
    }

    It 'keeps ShadowId and the shadow.id marker for later cleanup when the release fails' {
        Mock Invoke-CimMethod { [pscustomobject]@{ ReturnValue = 0; ShadowID = $script:ShadowId } }
        Mock Get-CimInstance { [pscustomobject]@{ ID = $script:ShadowId; DeviceObject = $script:ShadowRoot } } -ParameterFilter { $ClassName -eq 'Win32_ShadowCopy' }
        Mock Remove-AUShadowCopy { $false }
        $S = New-AUSnapshot -WorkDir $script:WorkDir
        $S.Status | Should -Be 'OK'
        $S.ShadowId | Should -Be $script:ShadowId
        [IO.File]::ReadAllText((Join-Path $script:WorkDir 'shadow.id')) | Should -Be $script:ShadowId
    }

    It 'skips with LowDiskSpace, copying nothing, when the work folder''s drive has <Free> free and the copies need <Needed>' -ForEach @(
        @{ Free = '1.5 GB'; FreeBytes = [long]1.5GB; Needed = '10 MB'; NeededBytes = [long]10MB }
        @{ Free = '5 GB'; FreeBytes = [long]5GB; Needed = '2 GB'; NeededBytes = [long]2GB }
        @{ Free = 'an unknown amount'; FreeBytes = $null; Needed = '10 MB'; NeededBytes = [long]10MB }
    ) {
        Mock Invoke-CimMethod { [pscustomobject]@{ ReturnValue = 0; ShadowID = $script:ShadowId } }
        Mock Get-CimInstance { [pscustomobject]@{ ID = $script:ShadowId; DeviceObject = $script:ShadowRoot } } -ParameterFilter { $ClassName -eq 'Win32_ShadowCopy' }
        $script:FreeBytes = $FreeBytes
        $script:NeededBytes = $NeededBytes
        Mock Get-AUFreeSpace { $script:FreeBytes }
        Mock Get-AUCopyBytes { $script:NeededBytes }
        $S = New-AUSnapshot -WorkDir $script:WorkDir
        $S.Status | Should -BeExactly 'LowDiskSpace'
        $S.SrumDbPath | Should -BeNullOrEmpty
        $S.HiveCopies[$script:SignedOutSid] | Should -BeNullOrEmpty
        Should -Invoke Copy-AUShadowFile -Times 0
        Should -Invoke Get-AUFreeSpace -Times 1 -Exactly -ParameterFilter { $Path -eq $script:WorkDir }
        # The shadow copy and its link are still released.
        Should -Invoke Remove-AUShadowCopy -Times 1 -Exactly -ParameterFilter { $ShadowId -eq $script:ShadowId }
        Test-Path -LiteralPath (Join-Path $script:WorkDir 'shadow') | Should -BeFalse
        $S.ShadowId | Should -BeNullOrEmpty
    }

    It 'copies when the drive has at least 2 GB and three times the copies free: <Free> free for <Needed>' -ForEach @(
        @{ Free = '2.5 GB'; FreeBytes = [long]2.5GB; Needed = '100 MB'; NeededBytes = [long]100MB }
        @{ Free = '7 GB'; FreeBytes = [long]7GB; Needed = '2 GB'; NeededBytes = [long]2GB }
    ) {
        Mock Invoke-CimMethod { [pscustomobject]@{ ReturnValue = 0; ShadowID = $script:ShadowId } }
        Mock Get-CimInstance { [pscustomobject]@{ ID = $script:ShadowId; DeviceObject = $script:ShadowRoot } } -ParameterFilter { $ClassName -eq 'Win32_ShadowCopy' }
        $script:FreeBytes = $FreeBytes
        $script:NeededBytes = $NeededBytes
        Mock Get-AUFreeSpace { $script:FreeBytes }
        Mock Get-AUCopyBytes { $script:NeededBytes }
        $S = New-AUSnapshot -WorkDir $script:WorkDir
        $S.Status | Should -BeExactly 'OK'
        $S.SrumDbPath | Should -Not -BeNullOrEmpty
        $script:Copied | Should -Contain "$(Join-Path $script:WorkDir 'shadow')\Windows\System32\sru\*"
    }

    It 'sizes the SRUM folder and each signed-out hive, with its logs, from the shadow link' {
        Mock Invoke-CimMethod { [pscustomobject]@{ ReturnValue = 0; ShadowID = $script:ShadowId } }
        Mock Get-CimInstance { [pscustomobject]@{ ID = $script:ShadowId; DeviceObject = $script:ShadowRoot } } -ParameterFilter { $ClassName -eq 'Win32_ShadowCopy' }
        Mock Get-AUCopyBytes { [long]0 }
        $null = New-AUSnapshot -WorkDir $script:WorkDir
        $Link = Join-Path $script:WorkDir 'shadow'
        Should -Invoke Get-AUCopyBytes -Times 1 -Exactly -ParameterFilter { $SruFolder -eq "$Link\Windows\System32\sru" -and @($HiveFolders) -contains "$Link\Users\signedout" -and @($HiveFolders).Count -eq 1 }
    }

    It 'records a hive that does not copy as $null and a SRUM copy failure in Status' {
        Mock Invoke-CimMethod { [pscustomobject]@{ ReturnValue = 0; ShadowID = $script:ShadowId } }
        Mock Get-CimInstance { [pscustomobject]@{ ID = $script:ShadowId; DeviceObject = $script:ShadowRoot } } -ParameterFilter { $ClassName -eq 'Win32_ShadowCopy' }
        Mock Copy-AUShadowFile { $false }
        $S = New-AUSnapshot -WorkDir $script:WorkDir
        $S.Status | Should -Be 'SrumReadFailed:CopyFailed'
        $S.SrumDbPath | Should -BeNullOrEmpty
        $S.ShadowId | Should -BeNullOrEmpty
        $S.HiveCopies[$script:SignedOutSid] | Should -BeNullOrEmpty
    }
}

Describe 'Get-AUCopyBytes and Get-AUFreeSpace (I4)' {
    It 'adds up the SRUM folder''s files and each hive folder''s NTUSER.DAT, .LOG1, and .LOG2' {
        $Sru = Join-Path $TestDrive "sru-$([guid]::NewGuid().ToString('N'))"
        $null = New-Item -ItemType Directory -Path $Sru
        [IO.File]::WriteAllBytes((Join-Path $Sru 'SRUDB.dat'), (New-Object byte[] 100))
        [IO.File]::WriteAllBytes((Join-Path $Sru 'SRU.log'), (New-Object byte[] 200))
        $Hive = Join-Path $TestDrive "hive-$([guid]::NewGuid().ToString('N'))"
        $null = New-Item -ItemType Directory -Path $Hive
        [IO.File]::WriteAllBytes((Join-Path $Hive 'NTUSER.DAT'), (New-Object byte[] 300))
        [IO.File]::WriteAllBytes((Join-Path $Hive 'NTUSER.DAT.LOG1'), (New-Object byte[] 50))
        [IO.File]::WriteAllBytes((Join-Path $Hive 'ntuser.ini'), (New-Object byte[] 999))
        Get-AUCopyBytes -SruFolder $Sru -HiveFolders @($Hive, (Join-Path $TestDrive 'missing')) | Should -Be 650
        Get-AUCopyBytes -SruFolder (Join-Path $TestDrive 'missing') -HiveFolders @() | Should -Be 0
    }

    It 'reads the free space of the drive that holds a path, and gives $null when it can''t' {
        Get-AUFreeSpace -Path $TestDrive | Should -BeGreaterThan 0
        Get-AUFreeSpace -Path 'Contoso\relative' | Should -BeNullOrEmpty
        Get-AUFreeSpace -Path '' | Should -BeNullOrEmpty
    }
}

Describe 'WMI time limits (review minor 2)' {
    It 'gives every CIM call in the region a time limit, and uses no Get-WmiObject, which has none' {
        $Ast = [Management.Automation.Language.Parser]::ParseInput($AURegionText, [ref]$null, [ref]$null)
        $Calls = @($Ast.FindAll({ param ($Node) $Node -is [Management.Automation.Language.CommandAst] -and @('Get-CimInstance', 'Invoke-CimMethod', 'Remove-CimInstance', 'Get-WmiObject', 'gwmi') -contains $Node.GetCommandName() }, $true))
        $Calls.Count | Should -BeGreaterThan 5
        foreach ($Call in $Calls)
        {
            $Call.GetCommandName() | Should -Not -BeIn @('Get-WmiObject', 'gwmi') -Because $Call.Extent.Text
            @($Call.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'OperationTimeoutSec' }).Count | Should -Be 1 -Because $Call.Extent.Text
        }
    }

    It 'limits the shadow copy lookups and removal to 30 seconds' {
        Mock Get-CimInstance { [pscustomobject]@{ ID = $script:ShadowId; InstallDate = (Get-Date) } }
        Mock Remove-CimInstance { } -RemoveParameterType 'InputObject'
        Remove-AUShadowCopy -ShadowId $script:ShadowId | Should -BeTrue
        Test-AUShadowFromRun -ShadowId $script:ShadowId -SinceUtc ([datetime]::UtcNow.AddHours(-1)) | Should -Not -BeNullOrEmpty
        Should -Invoke Get-CimInstance -Times 2 -Exactly -ParameterFilter { $ClassName -eq 'Win32_ShadowCopy' -and $OperationTimeoutSec -eq 30 }
        Should -Invoke Remove-CimInstance -Times 1 -Exactly -ParameterFilter { $OperationTimeoutSec -eq 30 }
    }

    It 'limits the account, BIOS, and shadow copy queries to 30 seconds, and the shadow copy creation to 120' {
        Mock Get-CimInstance { @() }
        $null = Get-AUMachineDomainSid
        $null = Get-AUSerial
        Should -Invoke Get-CimInstance -Times 1 -Exactly -ParameterFilter { $ClassName -eq 'Win32_UserAccount' -and $OperationTimeoutSec -eq 30 }
        Should -Invoke Get-CimInstance -Times 1 -Exactly -ParameterFilter { $ClassName -eq 'Win32_BIOS' -and $OperationTimeoutSec -eq 30 }

        $WorkDir = New-TestWorkDir
        Mock Get-AUProfileList { }
        Mock Invoke-CimMethod { [pscustomobject]@{ ReturnValue = 0; ShadowID = $script:ShadowId } }
        Mock Get-CimInstance { [pscustomobject]@{ ID = $script:ShadowId; DeviceObject = $null } } -ParameterFilter { $ClassName -eq 'Win32_ShadowCopy' }
        Mock Remove-AUShadowCopy { $true }
        $null = New-AUSnapshot -WorkDir $WorkDir
        Should -Invoke Invoke-CimMethod -Times 1 -Exactly -ParameterFilter { $MethodName -eq 'Create' -and $OperationTimeoutSec -eq 120 }
        Should -Invoke Get-CimInstance -Times 1 -Exactly -ParameterFilter { $ClassName -eq 'Win32_ShadowCopy' -and $OperationTimeoutSec -eq 30 }
    }
}

Describe 'Copy-AUShadowFile' {
    It 'copies hidden files too, and the copies get only the work folder entries' {
        $Source = Join-Path $TestDrive 'source-folder'
        $null = New-Item -ItemType Directory -Path $Source
        [IO.File]::WriteAllText((Join-Path $Source 'NTUSER.DAT'), 'hive')
        [IO.File]::WriteAllText((Join-Path $Source 'SRU.log'), 'log')
        [IO.File]::SetAttributes((Join-Path $Source 'NTUSER.DAT'), [IO.FileAttributes]'Hidden, System')
        $WorkDir = New-TestWorkDir

        Copy-AUShadowFile -Source "$Source\NTUSER.DAT" -Destination (Join-Path $WorkDir 'NTUSER.DAT') | Should -BeTrue
        $Folder = Join-Path $WorkDir 'all'
        $null = New-Item -ItemType Directory -Path $Folder
        Copy-AUShadowFile -Source "$Source\*" -Destination $Folder | Should -BeTrue
        @(Get-ChildItem -LiteralPath $Folder -Force | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @('NTUSER.DAT', 'SRU.log')
        $Rules = @((Get-Acl -LiteralPath (Join-Path $WorkDir 'NTUSER.DAT')).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        @($Rules | ForEach-Object { $_.IdentityReference.Value } | Sort-Object) | Should -Be @('S-1-5-18', 'S-1-5-32-544')
    }

    It 'returns false and never throws for a file that is not there' {
        Copy-AUShadowFile -Source (Join-Path $TestDrive 'none\NTUSER.DAT') -Destination (Join-Path $TestDrive 'x.dat') | Should -BeFalse
        Copy-AUShadowFile -Source (Join-Path $TestDrive 'none\*') -Destination $TestDrive | Should -BeFalse
    }
}

Describe 'Remove-AUSnapshot' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive 'PowerStacksAppUsage'
        $script:WorkDir = New-TestWorkDir
        $null = New-Item -ItemType Directory -Path (Join-Path $script:WorkDir 'sru')
        [IO.File]::WriteAllText((Join-Path $script:WorkDir 'sru\SRUDB.dat'), 'copy')
        Set-ItemProperty -LiteralPath (Join-Path $script:WorkDir 'sru\SRUDB.dat') -Name IsReadOnly -Value $true
        $script:Snapshot = [pscustomobject]@{ WorkDir = $script:WorkDir; ShadowId = $script:ShadowId; ShadowRoot = $script:ShadowRoot }
    }

    It 'removes the shadow copy and the whole run folder' {
        # A client-only CimInstance, so it binds to Remove-CimInstance like the real one.
        Mock Get-CimInstance { New-CimInstance -ClassName Win32_ShadowCopy -Namespace 'root/cimv2' -ClientOnly -Property @{ ID = $script:ShadowId } } -ParameterFilter { $ClassName -eq 'Win32_ShadowCopy' }
        Mock Remove-CimInstance { }
        @(Remove-AUSnapshot -Snapshot $script:Snapshot -Root $script:Root).Count | Should -Be 0
        Should -Invoke Remove-CimInstance -Times 1
        Test-Path -LiteralPath $script:WorkDir | Should -BeFalse
    }

    It 'never throws, and still removes the run folder, when the shadow copy cannot be removed' {
        Mock Get-CimInstance { throw 'WMI is broken' } -ParameterFilter { $ClassName -eq 'Win32_ShadowCopy' }
        { Remove-AUSnapshot -Snapshot $script:Snapshot -Root $script:Root } | Should -Not -Throw
        Test-Path -LiteralPath $script:WorkDir | Should -BeFalse
    }

    It 'does nothing and never throws for a null snapshot' {
        { Remove-AUSnapshot -Snapshot $null -Root $script:Root } | Should -Not -Throw
    }

    It 'leaves a WorkDir alone that is not directly inside the work root' {
        Mock Remove-AUFolderTree { }
        $Elsewhere = Join-Path $TestDrive 'elsewhere-run'
        $null = New-Item -ItemType Directory -Path $Elsewhere
        $Nested = Join-Path $script:WorkDir 'nested'
        $null = New-Item -ItemType Directory -Path $Nested
        foreach ($Path in @($Elsewhere, $Nested, $script:Root))
        {
            { Remove-AUSnapshot -Snapshot ([pscustomobject]@{ WorkDir = $Path; ShadowId = $null }) -Root $script:Root } | Should -Not -Throw
            Test-Path -LiteralPath $Path | Should -BeTrue
        }
        Should -Invoke Remove-AUFolderTree -Times 0
    }

    It 'leaves a WorkDir alone that is a link, and its target' {
        $Target = Join-Path $TestDrive 'link-target'
        $null = New-Item -ItemType Directory -Path $Target
        [IO.File]::WriteAllText((Join-Path $Target 'keep.txt'), 'keep')
        $Link = Join-Path $script:Root 'linked-run'
        $null = & cmd.exe /d /c mklink /j "$Link" "$Target"
        Remove-AUSnapshot -Snapshot ([pscustomobject]@{ WorkDir = $Link; ShadowId = $null }) -Root $script:Root
        Test-Path -LiteralPath $Link | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $Target 'keep.txt') | Should -BeTrue
    }

    It 'matches the work root case-insensitively' {
        Remove-AUSnapshot -Snapshot ([pscustomobject]@{ WorkDir = $script:WorkDir.ToUpperInvariant(); ShadowId = $null }) -Root $script:Root.ToLowerInvariant()
        Test-Path -LiteralPath $script:WorkDir | Should -BeFalse
    }
}

Describe 'SRUM id map and row resolution (archive safety)' {
    BeforeEach {
        $script:Map = @{ Apps = @{}; Sids = @{}; KnownIds = @{}; BadSids = 0 }
    }

    It 'maps a user SID, an app identifier, and a known entry with no value' {
        Add-AUIdMapEntry -IdMap $script:Map -IdType 3 -IdIndex 4 -Blob ([byte[]](1, 1, 0, 0, 0, 0, 0, 5, 18, 0, 0, 0))
        Add-AUIdMapEntry -IdMap $script:Map -IdType 0 -IdIndex 7 -Blob ([Text.Encoding]::Unicode.GetBytes("!!a.exe!2026/01/01:00:00:00!0!`0"))
        Add-AUIdMapEntry -IdMap $script:Map -IdType 3 -IdIndex 2 -Blob $null
        $script:Map.Sids[4] | Should -Be 'S-1-5-18'
        $script:Map.Apps[7] | Should -Be '!!a.exe!2026/01/01:00:00:00!0!'
        $script:Map.KnownIds.ContainsKey(2) | Should -BeTrue
        $script:Map.Sids.ContainsKey(2) | Should -BeFalse
        $script:Map.BadSids | Should -Be 0
    }

    It 'drops a user id whose SID does not parse from the known ids, so its rows are unresolved' {
        Add-AUIdMapEntry -IdMap $script:Map -IdType 3 -IdIndex 9 -Blob ([byte[]](1, 9))
        Add-AUIdMapEntry -IdMap $script:Map -IdType 0 -IdIndex 7 -Blob ([Text.Encoding]::Unicode.GetBytes('x.exe'))
        $script:Map.KnownIds.ContainsKey(9) | Should -BeFalse
        $script:Map.Sids.ContainsKey(9) | Should -BeFalse
        $script:Map.BadSids | Should -Be 1
        Test-AUTimelineRowResolved -AppId 7 -UserId 9 -AutoIncId 100 -KnownIds $script:Map.KnownIds | Should -BeFalse
    }

    It 'counts a row as resolved only with an AutoIncId and known AppId and UserId' {
        $Known = @{ 2 = $true; 7 = $true }
        Test-AUTimelineRowResolved -AppId 7 -UserId 2 -AutoIncId 100 -KnownIds $Known | Should -BeTrue
        Test-AUTimelineRowResolved -AppId 7 -UserId 2 -AutoIncId $null -KnownIds $Known | Should -BeFalse
        Test-AUTimelineRowResolved -AppId $null -UserId 2 -AutoIncId 100 -KnownIds $Known | Should -BeFalse
        Test-AUTimelineRowResolved -AppId 7 -UserId $null -AutoIncId 100 -KnownIds $Known | Should -BeFalse
        Test-AUTimelineRowResolved -AppId 8 -UserId 2 -AutoIncId 100 -KnownIds $Known | Should -BeFalse
    }
}

Describe 'Read-AUSrum' {
    BeforeEach {
        $script:Folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:Folder
        $script:Db = Join-Path $script:Folder 'SRUDB.dat'
        [IO.File]::WriteAllText($script:Db, 'db')
        $script:Calls = New-Object System.Collections.Generic.List[object]
        $script:DirtyUntil = 'p'
    }

    It 'gives SrumReadFailed:EsentMissing and empty lists when the assembly is missing (F42)' {
        Mock Initialize-AUEsent { $false }
        Mock Invoke-AUProcess { }
        $R = Read-AUSrum -DbPath $script:Db
        $R.Status | Should -Be 'SrumReadFailed:EsentMissing'
        @($R.Timeline).Count | Should -Be 0
        @($R.Resource).Count | Should -Be 0
        $R.Epoch | Should -BeNullOrEmpty
        Should -Invoke Invoke-AUProcess -Times 0
    }

    It 'reports an assembly path that does not exist as not loaded' {
        Initialize-AUEsent -Path (Join-Path $TestDrive 'missing\Microsoft.Isam.Esent.Interop.dll') | Should -BeFalse
    }

    It 'gives SrumReadFailed:NoDatabase when the copy is missing' {
        Mock Initialize-AUEsent { $true }
        $R = Read-AUSrum -DbPath (Join-Path $TestDrive 'nothing\SRUDB.dat')
        $R.Status | Should -Be 'SrumReadFailed:NoDatabase'
    }

    It 'never opens the live SRUM database' {
        Mock Initialize-AUEsent { $true }
        Mock Invoke-AUProcess { }
        Mock Read-AUSrumTables { }
        $R = Read-AUSrum -DbPath (Join-Path $env:SystemRoot 'System32\sru\SRUDB.dat')
        $R.Status | Should -Be 'SrumReadFailed:LiveDatabase'
        Should -Invoke Invoke-AUProcess -Times 0
        Should -Invoke Read-AUSrumTables -Times 0
    }

    Context 'a dirty copy' {
        BeforeEach {
            Mock Initialize-AUEsent { $true }
            # esentutl stand-in: the header stays dirty until the step named in DirtyUntil has run.
            Mock Invoke-AUProcess {
                $script:Calls.Add([pscustomobject]@{ FilePath = $FilePath; Arguments = $Arguments; WorkingDirectory = $WorkingDirectory })
                $Switch = $Arguments.Split(' ')[0]
                if ($Switch -eq '/r' -and $script:DirtyUntil -eq 'r') { $script:DirtyUntil = '' }
                if ($Switch -eq '/p' -and $script:DirtyUntil -eq 'p') { $script:DirtyUntil = '' }
                if ($Switch -eq '/mh')
                {
                    if ($script:DirtyUntil) { $State = 'Dirty Shutdown' } else { $State = 'Clean Shutdown' }
                    return [pscustomobject]@{ ExitCode = 0; TimedOut = $false; Output = "     DB Signature: Create time:11/20/2026 00:39:49.478 Rand:1288208395 Computer:`r`n            State: $State`r`n" }
                }
                return [pscustomobject]@{ ExitCode = 0; TimedOut = $false; Output = '' }
            }
            Mock Read-AUSrumTables {
                [pscustomobject]@{
                    Timeline = @([pscustomobject]@{ UserSid = 'S-1-5-21-1-2-3-1001'; ExeInfo = '!!a.exe!2026/01/01:00:00:00!0!'; AutoIncId = 7; EndTimeUtc = [datetime]::SpecifyKind([datetime]'2026-11-20', 'Utc'); FocusSeconds = 5; InputSeconds = 1 })
                    Resource = @()
                    Complete = $true
                    Failure  = $null
                }
            }
        }

        It 'recovers, then repairs the copy, keeps esentutl inside the copy folder, and reports Repaired' {
            $R = Read-AUSrum -DbPath $script:Db
            $R.Status | Should -Be 'OK'
            $R.Repaired | Should -BeTrue
            $R.Complete | Should -BeTrue
            $R.Epoch | Should -Be 'Create time:11/20/2026 00:39:49.478 Rand:1288208395 Computer:'
            @($R.Timeline).Count | Should -Be 1
            $Switches = @($script:Calls | ForEach-Object { $_.Arguments.Split(' ')[0] })
            $Switches | Should -Be @('/mh', '/r', '/mh', '/p', '/mh')
            foreach ($Call in $script:Calls)
            {
                $Call.FilePath | Should -Be (Join-Path $env:SystemRoot 'System32\esentutl.exe')
                $Call.WorkingDirectory | Should -Be $script:Folder
            }
            $Recovery = $script:Calls[1].Arguments
            $Recovery | Should -BeLike "*/l `"$($script:Folder)`"*"
            $Recovery | Should -BeLike "*/s `"$($script:Folder)`"*"
            $script:Calls[3].Arguments | Should -BeLike "*/t `"$($script:Folder)\*`"*"
        }

        It 'stops after recovery when recovery cleans the copy' {
            $script:DirtyUntil = 'r'
            $R = Read-AUSrum -DbPath $script:Db
            $R.Status | Should -Be 'OK'
            $R.Repaired | Should -BeFalse
            @($script:Calls | ForEach-Object { $_.Arguments.Split(' ')[0] }) | Should -Be @('/mh', '/r', '/mh')
        }

        It 'gives SrumReadFailed:RepairFailed and empty lists when repair leaves the copy dirty' {
            $script:DirtyUntil = 'never'
            $R = Read-AUSrum -DbPath $script:Db
            $R.Status | Should -Be 'SrumReadFailed:RepairFailed'
            @($R.Timeline).Count | Should -Be 0
            Should -Invoke Read-AUSrumTables -Times 0
        }

        It 'reports a table read failure as SrumReadFailed with its reason and empty lists' {
            $script:DirtyUntil = ''
            Mock Read-AUSrumTables { [pscustomobject]@{ Timeline = @(1, 2); Resource = @(); Complete = $false; Failure = 'TimelineFailed' } }
            $R = Read-AUSrum -DbPath $script:Db
            $R.Status | Should -Be 'SrumReadFailed:TimelineFailed'
            @($R.Timeline).Count | Should -Be 0
            $R.Complete | Should -BeFalse
        }
    }
}

# The Task 0.1 sandbox database (tests/srum-semantics/results/2026-11-20-run1). It is committed only
# with John's OK, so CI skips this block when it's absent (F71).
Describe 'Read-AUSrum on the Task 0.1 sandbox database (F71)' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot 'fixtures\srum\SRUDB.dat'))) {
    BeforeAll {
        # Read a copy, never the fixture itself: recovery or repair would change it.
        $Folder = Join-Path $TestDrive 'fixture-sru'
        $null = New-Item -ItemType Directory -Path $Folder
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\srum\SRUDB.dat') -Destination $Folder
        $script:FixtureOutput = @(Read-AUSrum -DbPath (Join-Path $Folder 'SRUDB.dat'))
        $script:Fixture = $script:FixtureOutput[0]
        # ProbeFocusInput's own log: activated 15:09:20.89Z, deactivated 15:14:22.02Z.
        $script:LoggedFocusSeconds = 301
    }

    It 'reads every timeline row, completely, with its epoch' {
        # One object and nothing else: App Usage code never leaks pipeline output (D40).
        $script:FixtureOutput.Count | Should -Be 1
        $script:Fixture.Status | Should -Be 'OK'
        $script:Fixture.Complete | Should -BeTrue
        $script:Fixture.Repaired | Should -BeFalse
        $script:Fixture.Epoch | Should -Be 'Create time:11/20/2026 00:39:49.478 Rand:1288208395 Computer:'
        @($script:Fixture.Timeline).Count | Should -Be 258
        @($script:Fixture.Timeline | ForEach-Object { $_.AutoIncId } | Sort-Object -Unique).Count | Should -Be 258
    }

    It 'gives every timeline end time as a Utc date' {
        foreach ($Row in $script:Fixture.Timeline)
        {
            $Row.EndTimeUtc | Should -BeOfType [datetime]
            $Row.EndTimeUtc.Kind | Should -Be 'Utc'
        }
    }

    It 'reads ProbeFocusInput focus within 10% of its logged focus time' {
        $Rows = @($script:Fixture.Timeline | Where-Object { $_.ExeInfo -like '!!ProbeFocusInput.exe!*' })
        $Rows.Count | Should -BeGreaterThan 0
        $Focus = ($Rows | Measure-Object -Property FocusSeconds -Sum).Sum
        [math]::Abs($Focus - $script:LoggedFocusSeconds) / $script:LoggedFocusSeconds | Should -BeLessOrEqual 0.1
    }

    It 'reads ProbeBackground focus as 0' {
        $Rows = @($script:Fixture.Timeline | Where-Object { $_.ExeInfo -like '!!ProbeBackground.exe!*' })
        $Rows.Count | Should -BeGreaterThan 0
        ($Rows | Measure-Object -Property FocusSeconds -Sum).Sum | Should -Be 0
    }

    It 'reads kernel paths from the resource table with lowercase exe names and Utc times' {
        @($script:Fixture.Resource).Count | Should -BeGreaterThan 0
        foreach ($Row in $script:Fixture.Resource)
        {
            $Row.KernelPath | Should -BeLike '\*'
            $Row.ExeName | Should -BeExactly ($Row.KernelPath.Split('\')[-1].ToLowerInvariant())
            $Row.TimeStampUtc.Kind | Should -Be 'Utc'
        }
        @($script:Fixture.Resource | Where-Object { $_.KernelPath -like '*\ProbeBackground.exe' }).Count | Should -BeGreaterThan 0
    }
}
