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

    It 'replaces a root that is a junction, and leaves the junction target alone' {
        $Target = Join-Path $TestDrive 'elsewhere'
        $null = New-Item -ItemType Directory -Path $Target
        [IO.File]::WriteAllText((Join-Path $Target 'keep.txt'), 'keep')
        $Root = Join-Path $TestDrive 'JunctionRoot'
        $null = & cmd.exe /d /c mklink /j "$Root" "$Target"
        ([IO.File]::GetAttributes($Root) -band [IO.FileAttributes]::ReparsePoint) | Should -Not -Be 0

        $Path = New-AUWorkDir -RunId 'run-2' -Root $Root
        ([IO.File]::GetAttributes($Root) -band [IO.FileAttributes]::ReparsePoint) | Should -Be 0
        Assert-ProtectedFolderAcl $Root
        Test-Path -LiteralPath $Path | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $Target 'keep.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $Target 'run-2') | Should -BeFalse
    }

    It 'replaces a root that someone other than SYSTEM or Administrators owns, without following a junction inside it' {
        $Target = Join-Path $TestDrive 'outside'
        $null = New-Item -ItemType Directory -Path $Target
        [IO.File]::WriteAllText((Join-Path $Target 'keep.txt'), 'keep')
        $Root = Join-Path $TestDrive 'PlantedRoot'
        $null = New-Item -ItemType Directory -Path $Root
        [IO.File]::WriteAllText((Join-Path $Root 'planted.txt'), 'planted')
        $null = & cmd.exe /d /c mklink /j "$(Join-Path $Root 'link')" "$Target"
        $Acl = Get-Acl -LiteralPath $Root
        $Acl.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User)
        Set-Acl -LiteralPath $Root -AclObject $Acl
        (Get-Acl -LiteralPath $Root).GetOwner([Security.Principal.SecurityIdentifier]).Value | Should -Be ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)

        $null = New-AUWorkDir -RunId 'run-3' -Root $Root
        (Get-Acl -LiteralPath $Root).GetOwner([Security.Principal.SecurityIdentifier]).Value | Should -BeIn @('S-1-5-18', 'S-1-5-32-544')
        Test-Path -LiteralPath (Join-Path $Root 'planted.txt') | Should -BeFalse
        Assert-ProtectedFolderAcl $Root
        Test-Path -LiteralPath (Join-Path $Target 'keep.txt') | Should -BeTrue
    }

    It 'rejects a RunId that is not a plain folder name' {
        { New-AUWorkDir -RunId '..\escape' -Root (Join-Path $TestDrive 'R') } | Should -Throw
        { New-AUWorkDir -RunId '' -Root (Join-Path $TestDrive 'R') } | Should -Throw
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
    }

    It 'copies SRUM and signed-out hives only from the shadow root, into the work folder' {
        Mock Invoke-CimMethod { [pscustomobject]@{ ReturnValue = 0; ShadowID = $script:ShadowId } }
        Mock Get-CimInstance { [pscustomobject]@{ ID = $script:ShadowId; DeviceObject = $script:ShadowRoot } } -ParameterFilter { $ClassName -eq 'Win32_ShadowCopy' }
        $Output = @(New-AUSnapshot -WorkDir $script:WorkDir)
        $Output.Count | Should -Be 1
        $S = $Output[0]
        $S.Status | Should -Be 'OK'
        $S.ShadowId | Should -Be $script:ShadowId
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
    }

    It 'gives ShadowCopyFailed, keeping the ShadowId for cleanup, when the shadow copy cannot be linked' {
        Mock Invoke-CimMethod { [pscustomobject]@{ ReturnValue = 0; ShadowID = $script:ShadowId } }
        Mock Get-CimInstance { [pscustomobject]@{ ID = $script:ShadowId; DeviceObject = $script:ShadowRoot } } -ParameterFilter { $ClassName -eq 'Win32_ShadowCopy' }
        Mock Mount-AUShadow { $false }
        $S = New-AUSnapshot -WorkDir $script:WorkDir
        $S.Status | Should -Be 'ShadowCopyFailed'
        $S.ShadowId | Should -Be $script:ShadowId
        $S.SrumDbPath | Should -BeNullOrEmpty
        Should -Invoke Copy-AUShadowFile -Times 0
    }

    It 'records a hive that does not copy as $null and a SRUM copy failure in Status' {
        Mock Invoke-CimMethod { [pscustomobject]@{ ReturnValue = 0; ShadowID = $script:ShadowId } }
        Mock Get-CimInstance { [pscustomobject]@{ ID = $script:ShadowId; DeviceObject = $script:ShadowRoot } } -ParameterFilter { $ClassName -eq 'Win32_ShadowCopy' }
        Mock Copy-AUShadowFile { $false }
        $S = New-AUSnapshot -WorkDir $script:WorkDir
        $S.Status | Should -Be 'SrumReadFailed:CopyFailed'
        $S.SrumDbPath | Should -BeNullOrEmpty
        $S.ShadowId | Should -Be $script:ShadowId
        $S.HiveCopies[$script:SignedOutSid] | Should -BeNullOrEmpty
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
        @(Remove-AUSnapshot -Snapshot $script:Snapshot).Count | Should -Be 0
        Should -Invoke Remove-CimInstance -Times 1
        Test-Path -LiteralPath $script:WorkDir | Should -BeFalse
    }

    It 'never throws, and still removes the run folder, when the shadow copy cannot be removed' {
        Mock Get-CimInstance { throw 'WMI is broken' } -ParameterFilter { $ClassName -eq 'Win32_ShadowCopy' }
        { Remove-AUSnapshot -Snapshot $script:Snapshot } | Should -Not -Throw
        Test-Path -LiteralPath $script:WorkDir | Should -BeFalse
    }

    It 'does nothing and never throws for a null snapshot' {
        { Remove-AUSnapshot -Snapshot $null } | Should -Not -Throw
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
