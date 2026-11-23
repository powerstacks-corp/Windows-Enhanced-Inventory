BeforeAll { . "$PSScriptRoot\_Import.ps1" }

Describe 'Get-AUUserType' {
    BeforeAll {
        $m = 'S-1-5-21-1111111111-2222222222-3333333333'
    }

    It 'classifies an Entra ID SID as CloudOnly' {
        Get-AUUserType 'S-1-12-1-1-2-3-4' $m | Should -Be 'CloudOnly'
    }

    It 'classifies a SID under the machine domain as Local' {
        Get-AUUserType "$m-1001" $m | Should -Be 'Local'
    }

    It 'classifies a SID under another account domain as Domain' {
        Get-AUUserType 'S-1-5-21-9-8-7-1105' $m | Should -Be 'Domain'
    }

    It 'compares the domain portion exactly, not by string prefix' {
        Get-AUUserType 'S-1-5-21-1111111111-2222222222-33333333330-1001' $m | Should -Be 'Domain'
    }

    It 'classifies LocalSystem as System' {
        Get-AUUserType 'S-1-5-18' $m | Should -Be 'System'
    }

    It 'classifies LocalService and NetworkService as Service' {
        Get-AUUserType 'S-1-5-19' $m | Should -Be 'Service'
        Get-AUUserType 'S-1-5-20' $m | Should -Be 'Service'
    }

    It 'classifies a virtual service account SID as Service' {
        Get-AUUserType 'S-1-5-80-123' $m | Should -Be 'Service'
    }

    It 'classifies an empty SID as Unknown' {
        Get-AUUserType '' $m | Should -Be 'Unknown'
    }

    It 'classifies an unparseable SID as Unknown' {
        Get-AUUserType 'not-a-sid' $m | Should -Be 'Unknown'
    }
}

Describe 'Test-AUInteractiveUserType' {
    It 'is false for System' {
        Test-AUInteractiveUserType 'System' | Should -BeFalse
    }

    It 'is true for Local' {
        Test-AUInteractiveUserType 'Local' | Should -BeTrue
    }

    It 'is true for CloudOnly and Domain' {
        Test-AUInteractiveUserType 'CloudOnly' | Should -BeTrue
        Test-AUInteractiveUserType 'Domain' | Should -BeTrue
    }

    It 'is false for Service and Unknown' {
        Test-AUInteractiveUserType 'Service' | Should -BeFalse
        Test-AUInteractiveUserType 'Unknown' | Should -BeFalse
    }
}

Describe 'Add-AUDeletedScopes (F29, Task 21)' {
    BeforeAll {
        $script:Profiles = @([pscustomobject]@{ Sid = 'S-1-5-21-1111111111-2222222222-3333333333-1001' })
    }

    It 'marks an interactive SID that isn''t in ProfileList Deleted: <Sid>' -ForEach @(
        @{ Sid = 'S-1-12-1-9999-9999-9999-9999' }
        @{ Sid = 'S-1-5-21-1111111111-2222222222-3333333333-1002' }
        @{ Sid = 'S-1-5-21-4444444444-5555555555-6666666666-1001' }
    ) {
        $Scopes = @{ Machine = 'Read' }
        Add-AUDeletedScopes -ScopeRead $Scopes -Users $script:Profiles -Sids @($Sid) | Should -Be 1
        $Scopes[$Sid] | Should -BeExactly 'Deleted'
    }

    It 'leaves a service, virtual, or system account that never has a profile alone: <Sid>' -ForEach @(
        @{ Sid = 'S-1-5-90-0-1' }
        @{ Sid = 'S-1-5-96-0-1' }
        @{ Sid = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464' }
        @{ Sid = 'S-1-5-82-3006700770-424185619-1745488364-794895919-4004696415' }
        @{ Sid = 'S-1-5-83-1-1111111111-2222222222-3333333333-4444444444' }
        @{ Sid = 'S-1-5-18' }
        @{ Sid = 'S-1-5-19' }
        @{ Sid = 'S-1-5-20' }
        @{ Sid = 'S-1-5-32-544' }
    ) {
        $Scopes = @{ Machine = 'Read' }
        Add-AUDeletedScopes -ScopeRead $Scopes -Users $script:Profiles -Sids @($Sid) | Should -Be 0
        $Scopes.ContainsKey($Sid) | Should -BeFalse
    }

    It 'counts only the interactive SIDs it marks' {
        $Scopes = @{ Machine = 'Read' }
        $Sids = @('S-1-5-90-0-1', 'S-1-5-90-0-2', 'S-1-5-96-0-1', 'S-1-12-1-9999-9999-9999-9999', 'S-1-5-21-1111111111-2222222222-3333333333-1001')
        Add-AUDeletedScopes -ScopeRead $Scopes -Users $script:Profiles -Sids $Sids | Should -Be 1
        @($Scopes.Keys | Where-Object { $Scopes[$_] -eq 'Deleted' }) | Should -Be @('S-1-12-1-9999-9999-9999-9999')
    }
}
