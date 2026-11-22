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
