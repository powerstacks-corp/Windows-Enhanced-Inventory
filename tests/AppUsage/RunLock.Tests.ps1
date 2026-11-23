BeforeAll {
    . "$PSScriptRoot\_Import.ps1"

    # These tests use the real global mutex name, so every child process is bounded: it holds the
    # mutex only until a stop file appears or a hard limit passes, and AfterEach kills it anyway.
    $script:LockName = 'Global\PowerStacksAppUsage'
    $script:ChildLimitSeconds = 30
    $script:ReadyTimeoutSeconds = 20
    $script:PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script:Children = New-Object System.Collections.Generic.List[System.Diagnostics.Process]

    $ChildScript = @'
param([string]$Name, [string]$Mode, [string]$ReadyFile, [string]$StopFile, [string]$ResultFile, [int]$LimitSeconds)
$Mutex = New-Object System.Threading.Mutex($false, $Name)
try { $Got = $Mutex.WaitOne(2000) } catch [System.Threading.AbandonedMutexException] { $Got = $true }
if ($Mode -eq 'Probe')
{
    [IO.File]::WriteAllText($ResultFile, [string]$Got)
    if ($Got) { $Mutex.ReleaseMutex() }
    $Mutex.Dispose()
    exit 0
}
if (-not $Got) { [IO.File]::WriteAllText($ReadyFile, 'NotAcquired'); exit 1 }
[IO.File]::WriteAllText($ReadyFile, 'Acquired')
if ($Mode -eq 'Abandon') { [Environment]::Exit(0) }
$Deadline = [DateTime]::UtcNow.AddSeconds($LimitSeconds)
while (-not [IO.File]::Exists($StopFile) -and [DateTime]::UtcNow -lt $Deadline) { Start-Sleep -Milliseconds 50 }
$Mutex.ReleaseMutex()
$Mutex.Dispose()
exit 0
'@
    $script:ChildScriptPath = Join-Path $TestDrive 'LockChild.ps1'
    [IO.File]::WriteAllText($script:ChildScriptPath, $ChildScript)

    function Start-LockChild([string]$Mode)
    {
        $Id = [guid]::NewGuid().ToString('N')
        $Files = [pscustomobject]@{
            Ready  = Join-Path $TestDrive "$Id.ready"
            Stop   = Join-Path $TestDrive "$Id.stop"
            Result = Join-Path $TestDrive "$Id.result"
        }
        $Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script:ChildScriptPath`" -Name `"$script:LockName`" -Mode $Mode -ReadyFile `"$($Files.Ready)`" -StopFile `"$($Files.Stop)`" -ResultFile `"$($Files.Result)`" -LimitSeconds $script:ChildLimitSeconds"
        $Process = Start-Process -FilePath $script:PowerShellExe -ArgumentList $Arguments -WindowStyle Hidden -PassThru
        $script:Children.Add($Process)
        return [pscustomobject]@{ Process = $Process; Files = $Files }
    }

    function Wait-LockChildFile([pscustomobject]$Child, [string]$Path)
    {
        $Deadline = [DateTime]::UtcNow.AddSeconds($script:ReadyTimeoutSeconds)
        while (-not [IO.File]::Exists($Path))
        {
            if ([DateTime]::UtcNow -ge $Deadline) { throw "The child process didn't write $Path within $script:ReadyTimeoutSeconds seconds." }
            if ($Child.Process.HasExited -and -not [IO.File]::Exists($Path)) { throw "The child process exited ($($Child.Process.ExitCode)) without writing $Path." }
            Start-Sleep -Milliseconds 50
        }
        return [IO.File]::ReadAllText($Path)
    }

    # Another process can take the lock right now, so the last holder released it.
    function Test-LockFreeForOthers
    {
        $Probe = Start-LockChild -Mode 'Probe'
        $Answer = Wait-LockChildFile -Child $Probe -Path $Probe.Files.Result
        return ($Answer -eq 'True')
    }

    # Kills any child still running, so a failed test can't leave a process holding the lock.
    function Stop-LockChildren
    {
        foreach ($Process in $script:Children)
        {
            try
            {
                if (-not $Process.HasExited) { $Process.Kill(); [void]$Process.WaitForExit(10000) }
            }
            catch { }
            $Process.Dispose()
        }
        $script:Children.Clear()
    }
}

Describe 'Invoke-AUWithLock' {
    AfterEach { Stop-LockChildren }

    It 'Gives Acquired false and never runs the body while another process holds the lock' {
        $Holder = Start-LockChild -Mode 'Hold'
        Wait-LockChildFile -Child $Holder -Path $Holder.Files.Ready | Should -Be 'Acquired'
        $script:BodyRan = $false

        $Result = Invoke-AUWithLock -Body { $script:BodyRan = $true; 'ran' } -TimeoutSeconds 2

        $Result.Acquired | Should -BeFalse
        $Result.Abandoned | Should -BeFalse
        $Result.Result | Should -BeNullOrEmpty
        $script:BodyRan | Should -BeFalse
        [IO.File]::WriteAllText($Holder.Files.Stop, 'stop')
        $Holder.Process.WaitForExit(10000) | Should -BeTrue
    }

    It 'Acquires on two sequential calls, returns the body output, and releases each time' {
        $First = Invoke-AUWithLock -Body { 'one' } -TimeoutSeconds 2
        $Second = Invoke-AUWithLock -Body { 2; 3 } -TimeoutSeconds 2

        $First.Acquired | Should -BeTrue
        $First.Abandoned | Should -BeFalse
        $First.Result | Should -Be 'one'
        $Second.Acquired | Should -BeTrue
        @($Second.Result) | Should -Be @(2, 3)
        Test-LockFreeForOthers | Should -BeTrue
    }

    It 'Releases the lock when the body throws, and never throws itself' {
        $First = Invoke-AUWithLock -Body { 'first' } -TimeoutSeconds 2
        { $script:Thrown = Invoke-AUWithLock -Body { throw 'body failed' } -TimeoutSeconds 2 } | Should -Not -Throw
        $Third = Invoke-AUWithLock -Body { 'third' } -TimeoutSeconds 2

        $First.Acquired | Should -BeTrue
        $script:Thrown.Acquired | Should -BeTrue
        $script:Thrown.Error | Should -Match 'body failed'
        $Third.Acquired | Should -BeTrue
        $Third.Result | Should -Be 'third'
        $Third.Error | Should -BeNullOrEmpty
        Test-LockFreeForOthers | Should -BeTrue
    }

    It 'Counts an abandoned lock as acquired, reports it, and runs the body' {
        # Keep a handle open so the mutex object outlives the child that abandons it.
        $Keeper = New-Object System.Threading.Mutex($false, $script:LockName)
        try
        {
            $Abandoner = Start-LockChild -Mode 'Abandon'
            Wait-LockChildFile -Child $Abandoner -Path $Abandoner.Files.Ready | Should -Be 'Acquired'
            $Abandoner.Process.WaitForExit(10000) | Should -BeTrue
            $script:BodyRan = $false

            $Result = Invoke-AUWithLock -Body { $script:BodyRan = $true; 'ran' } -TimeoutSeconds 2

            $Result.Acquired | Should -BeTrue
            $Result.Abandoned | Should -BeTrue
            $Result.Result | Should -Be 'ran'
            $script:BodyRan | Should -BeTrue
        }
        finally { $Keeper.Dispose() }
        Test-LockFreeForOthers | Should -BeTrue
    }

    It 'Gives Acquired false without throwing when opening the lock is denied' {
        Mock Open-AULockMutex { throw (New-Object System.UnauthorizedAccessException 'Access to the path is denied.') }
        $script:BodyRan = $false

        { $script:Denied = Invoke-AUWithLock -Body { $script:BodyRan = $true } -TimeoutSeconds 2 } | Should -Not -Throw

        $script:Denied.Acquired | Should -BeFalse
        $script:Denied.Abandoned | Should -BeFalse
        $script:BodyRan | Should -BeFalse
        Should -Invoke Open-AULockMutex -Times 1 -Exactly
    }

    It 'Gives Acquired false without throwing when the wait is denied' {
        $script:Denying = [pscustomobject]@{ Disposed = $false }
        $script:Denying | Add-Member -MemberType ScriptMethod -Name WaitOne -Value { param($Timeout) throw (New-Object System.UnauthorizedAccessException 'Access is denied.') }
        $script:Denying | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Disposed = $true }
        Mock Open-AULockMutex { $script:Denying }
        $script:BodyRan = $false

        { $script:Denied = Invoke-AUWithLock -Body { $script:BodyRan = $true } -TimeoutSeconds 2 } | Should -Not -Throw

        $script:Denied.Acquired | Should -BeFalse
        $script:BodyRan | Should -BeFalse
        $script:Denying.Disposed | Should -BeTrue
    }
}

Describe 'Open-AULockMutex' {
    AfterEach { Stop-LockChildren }

    It 'Grants SYSTEM and Administrators full control by well-known SID' {
        $Mutex = Open-AULockMutex -Name $script:LockName
        try
        {
            $Rules = @($Mutex.GetAccessControl().GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]))
            foreach ($Sid in 'S-1-5-18', 'S-1-5-32-544')
            {
                $Rule = @($Rules | Where-Object { $_.IdentityReference.Value -eq $Sid -and $_.AccessControlType -eq 'Allow' })
                $Rule.Count | Should -BeGreaterThan 0 -Because "$Sid needs an allow rule"
                ($Rule[0].MutexRights -band [System.Security.AccessControl.MutexRights]::FullControl) | Should -Be ([System.Security.AccessControl.MutexRights]::FullControl)
            }
        }
        finally { $Mutex.Dispose() }
    }
}

Describe 'Invoke-AUWithLock -Name' {
    It 'takes the run lock by default, and the outbox lock when named' {
        $script:Opened = New-Object System.Collections.Generic.List[string]
        Mock Open-AULockMutex { $script:Opened.Add($Name); New-Object System.Threading.Mutex($false) }
        (Invoke-AUWithLock -Body { 'default' } -TimeoutSeconds 1).Result | Should -BeExactly 'default'
        (Invoke-AUWithLock -Name $script:AUOutboxLockName -Body { 'outbox' } -TimeoutSeconds 1).Result | Should -BeExactly 'outbox'
        $script:Opened.ToArray() | Should -Be @('Global\PowerStacksAppUsage', 'Global\PowerStacksAppUsageOutbox')
    }
}
