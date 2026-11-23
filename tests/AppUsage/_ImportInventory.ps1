# Dot-source this file from a Pester BeforeAll block, after _Import.ps1. It makes the inline App
# Inventory section of the inventory script testable (F39): Invoke-TestAppInventory extracts the
# "# region APPINVENTORY" to "# end region APPINVENTORY" block from a script (this branch's, or
# version 19's from git) and runs it with stubbed reads and uploads, then returns what it built and
# what it would have sent. Nothing is read from or sent to the real device or service.
#
# The block runs in Invoke-TestAppInventory's own scope, so the stubs below shadow the real
# commands for it and for every function it calls. Region functions (Invoke-AppUsage and the rest)
# come from _Import.ps1 and aren't redefined here, so Pester mocks of them still apply.

$script:AUInventoryScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\..\Intune_Windows_Inventory.ps1')).Path

function Get-TestScriptText([string]$Path = $script:AUInventoryScriptPath)
{
    return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
}

# The App Inventory block, without its region markers.
function Get-TestAppInventoryBlock([string]$ScriptText)
{
    $Match = [regex]::Match($ScriptText, '(?ms)^# region APPINVENTORY\r?\n(.*?)^# end region APPINVENTORY')
    if (-not $Match.Success) { throw 'The App Inventory region was not found.' }
    return $Match.Groups[1].Value
}

# The final status report: from "# Report back status" to the end of the script region.
function Get-TestSummaryBlock([string]$ScriptText)
{
    $Match = [regex]::Match($ScriptText, '(?ms)^# Report back status\r?\n(.*?)^#endregion script')
    if (-not $Match.Success) { throw 'The status report was not found.' }
    return $Match.Groups[1].Value
}

# Version 19 (commit 094a084), read from git into memory. The worktree is never checked out.
function Get-TestV19ScriptText
{
    $Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $Text = & git -C $Root show '094a084:Intune_Windows_Inventory.ps1' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $Text) { throw 'Version 19 (094a084) is not in this clone.' }
    return (@($Text) -join "`r`n")
}

# The synthetic device's apps, in the shape of version 19's Get-InstalledApplications output (the
# registry values Get-ItemProperty returns, with PSPath). Deterministic: the same Seed and Filler
# give the same apps. No real device data: names, publishers, and paths are made up.
function New-TestInventoryApps([int]$Filler = 0, [int]$Seed = 19)
{
    $Base = 'Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    $Base32 = 'Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    $Apps = New-Object 'System.Collections.Generic.List[object]'
    $Add = {
        param ($Name, $Version, $Publisher, $InstallDate, $Uninstall, $Path)
        $App = [ordered]@{}
        if ($null -ne $Name) { $App['DisplayName'] = $Name }
        if ($null -ne $Version) { $App['DisplayVersion'] = $Version }
        if ($null -ne $Publisher) { $App['Publisher'] = $Publisher }
        if ($null -ne $InstallDate) { $App['InstallDate'] = $InstallDate }
        if ($null -ne $Uninstall) { $App['UninstallString'] = $Uninstall }
        if ($null -ne $Path) { $App['PSPath'] = $Path }
        $Apps.Add([pscustomobject]$App)
    }
    & $Add 'Contoso Alpha' '2.4.1' 'Contoso Ltd.' '20260901' 'MsiExec.exe /X{11111111-2222-3333-4444-555555555555}' "$Base\{11111111-2222-3333-4444-555555555555}"
    & $Add 'Contoso Beta' '1.0' 'Contoso Ltd.' '20250115' '"C:\Program Files\Contoso\Beta\uninst.exe"' "$Base\ContosoBeta"
    & $Add 'Contoso Beta' '1.10.2' 'Contoso Ltd.' '20260310' '"C:\Program Files (x86)\Contoso\Beta\uninst.exe" /S' "$Base32\ContosoBeta"
    & $Add 'Fabrikam Tool' '10.0.19041.1' 'Fabrikam, Inc.' $null 'C:\Program Files\Fabrikam\Tool\remove.exe' "$Base\FabrikamTool"
    & $Add 'Fabrikam Viewer' $null 'Fabrikam, Inc.' '20240229' $null "$Base32\FabrikamViewer"
    & $Add ('Northwind Caf' + [char]0x00E9 + ' Suite') '3.1' 'Northwind Traders' '20260704' 'MsiExec.exe /I{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}' "$Base\{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}"
    & $Add 'Adventure Works "Quoted" App' '7.0.0.0' $null '' 'cmd /c "echo \ backslash"' "$Base\AdventureWorks"
    & $Add 'Wide World Importers' '1.0' 'Wide World Importers' '20230101' 'C:\ProgramData\WWI\setup.exe /uninstall' "$Base\WWI"
    & $Add 'Wide World Importers' '1.0' 'Wide World Importers' '20230102' 'C:\ProgramData\WWI\setup.exe /uninstall /x86' "$Base32\WWI"
    & $Add 'Tailspin Toys' '2026.11.1' 'Tailspin' '20261101' 'C:\Users\Public\Tailspin\unins000.exe' 'Microsoft.PowerShell.Core\Registry::HKEY_USERS\S-1-5-21-1000000000-2000000000-3000000000-1001\Software\Microsoft\Windows\CurrentVersion\Uninstall\Tailspin'
    $Rng = New-Object Random $Seed
    for ($i = 0; $i -lt $Filler; $i++)
    {
        $Bytes = New-Object byte[] 24
        $Rng.NextBytes($Bytes)
        $Hex = [BitConverter]::ToString($Bytes).Replace('-', '')
        & $Add "Generated App $i $($Hex.Substring(0, 8))" "$($Rng.Next(1, 30)).$($Rng.Next(0, 10)).$($Rng.Next(0, 9999))" "Vendor $($Rng.Next(1, 400))" "2026$('{0:D2}' -f $Rng.Next(1, 13))$('{0:D2}' -f $Rng.Next(1, 29))" "MsiExec.exe /X{$Hex}" "$Base\{$Hex}"
    }
    return , $Apps.ToArray()
}

# Store apps in the shape of version 19's Get-AppxInstalledApplications output.
function New-TestInventoryAppx
{
    return , @(
        [pscustomobject]@{ DisplayName = 'Contoso.Notes'; DisplayVersion = '1.2.3.0'; Publisher = 'CN=Contoso'; AppType = 'UWP' }
        [pscustomobject]@{ DisplayName = 'Fabrikam.Paint'; DisplayVersion = '11.2405.1.0'; Publisher = 'CN=Fabrikam'; AppType = 'UWP' }
    )
}

# Copies, so the block's Add-Member never changes the caller's objects.
function Copy-TestObjects([object[]]$Objects)
{
    $Copies = New-Object 'System.Collections.Generic.List[object]'
    foreach ($Object in @($Objects))
    {
        if ($null -eq $Object) { continue }
        $Copy = [ordered]@{}
        foreach ($Property in $Object.PSObject.Properties) { $Copy[$Property.Name] = $Property.Value }
        $Copies.Add([pscustomobject]$Copy)
    }
    return , $Copies.ToArray()
}

# Decodes pieces as Power BI does: joined, Base64, GUnzip, UTF-8.
function Expand-TestInventoryPieces([string[]]$Pieces)
{
    if (@($Pieces).Count -eq 0) { return $null }
    $Bytes = [Convert]::FromBase64String(-join $Pieces)
    $Gzip = New-Object IO.Compression.GZipStream((New-Object IO.MemoryStream(, $Bytes)), [IO.Compression.CompressionMode]::Decompress)
    $Reader = New-Object IO.StreamReader($Gzip, (New-Object Text.UTF8Encoding $false))
    try { return $Reader.ReadToEnd() } finally { $Reader.Dispose() }
}

# A row's pieces of one blob, in column order.
function Get-TestRowPieces($Row, [string]$Blob)
{
    $Names = @($Row.PSObject.Properties.Name | Where-Object { $_ -match "^$Blob(\d+)(_s)?$" } | Sort-Object { [int]($_ -replace "^$Blob(\d+)(_s)?$", '$1') })
    return , @($Names | ForEach-Object { [string]$Row.$_ })
}

<#
Runs the App Inventory block of ScriptText and returns:
  MainApp       the $MainApp it built
  AppArray      the $AppArray it built
  Response      $ResponseAppInventory
  Sends         every upload call: Mode, LogType, Body (byte[]), Text (the body as UTF-8)
  Output        the console output of the status report (with -Summary)
  Errors        error records the block wrote
  Calls         how many times Get-InstalledApplications and Get-AppxInstalledApplications ran
Settings sets the script variables the block reads (CollectAppMetering, CollectUWPInventory,
LogAPIMode, and so on). SendResponse is a scriptblock given (Mode, Body) that returns the upload
response; by default every upload succeeds (204, or 200 for the classic API).
#>
function Invoke-TestAppInventory
{
    param (
        [string]$ScriptText = (Get-TestScriptText),
        [hashtable]$Settings = @{},
        [object[]]$Apps = (New-TestInventoryApps),
        [object[]]$AppxApps = (New-TestInventoryAppx),
        [scriptblock]$SendResponse,
        [switch]$Summary
    )

    # The script settings and common data the block reads.
    $CollectAppInventory = $true
    $CollectDeviceInventory = $false
    $CollectDriverInventory = $false
    $CollectUWPInventory = $false
    $CollectAppMetering = $false
    $LogAPIMode = 'LogIngestionAPI'
    $TenantId = 'tenant-test'
    $ClientId = 'client-test'
    $ClientSecret = 'secret-test'
    $DceURI = 'https://dce.test.invalid'
    $DcrImmutableId = 'dcr-test'
    $CustomerId = 'workspace-test'
    $SharedKey = 'key-test'
    $ComputerName = 'TESTPC-0001'
    $ManagedDeviceID = '6f2c1d1e-2b3a-4c5d-8e9f-0a1b2c3d4e5f'
    $ScriptVersion = '20 - test'
    $InventoryDateFormat = 'MM-dd HH:mm'
    $Transcribe = $false
    foreach ($Key in $Settings.Keys) { Set-Variable -Name $Key -Value $Settings[$Key] }

    # The stubs find this by dynamic scope from deep inside region functions, so its name must not
    # be one any of them uses (Send-AUInventoryRun has its own $State).
    $AUTestInventoryState = [pscustomobject]@{
        Sends    = New-Object 'System.Collections.Generic.List[object]'
        Apps     = $Apps
        AppxApps = $AppxApps
        Calls    = @{ InstalledApplications = 0; AppxInstalledApplications = 0 }
        Log      = New-Object "System.Collections.Generic.List[string]"
        Respond  = $SendResponse
    }

    # The stubs.
    function Write-CMTraceLog { param ([Parameter(Position = 0)]$Message, [Parameter(ValueFromRemainingArguments = $true)]$Rest) $AUTestInventoryState.Log.Add([string]$Message) }
    function Get-WmiObject { [pscustomobject]@{ UserName = 'TESTDOMAIN\testuser' } }
    function Get-CimInstance { }
    function Invoke-CimMethod { }
    function Get-InstalledApplications { param ($UserSid) $AUTestInventoryState.Calls.InstalledApplications++; Copy-TestObjects $AUTestInventoryState.Apps }
    function Get-AppxInstalledApplications { $AUTestInventoryState.Calls.AppxInstalledApplications++; Copy-TestObjects $AUTestInventoryState.AppxApps }
    function Send-TestUpload([string]$Mode, [string]$LogType, [byte[]]$Body)
    {
        $AUTestInventoryState.Sends.Add([pscustomobject]@{ Mode = $Mode; LogType = $LogType; Body = $Body; Text = [Text.Encoding]::UTF8.GetString($Body) })
        if ($null -ne $AUTestInventoryState.Respond) { return (& $AUTestInventoryState.Respond $Mode $Body) }
        $Code = if ($Mode -eq 'LogIngestionAPI') { 204 } else { 200 }
        $script:LastSubmissionStatusCode = $Code
        return "$Code : Upload payload size is $(($Body.Length / 1024).ToString('#.#'))Kb "
    }
    function Send-LogIngestionAPI { param ($tenantId, $clientId, $clientSecret, $body, $dceURI, $dcrImmutableId, $logType) Send-TestUpload 'LogIngestionAPI' $logType $body }
    function Send-DataCollectorAPI { param ($customerId, $sharedKey, $body, $logType) Send-TestUpload 'DataCollectorAPI' $logType $body }

    $Block = [scriptblock]::Create((Get-TestAppInventoryBlock $ScriptText))
    $Output = $null
    $Errors = @()
    $BlockOutput = @(. $Block 2>&1)
    $Errors += @($BlockOutput | Where-Object { $_ -is [Management.Automation.ErrorRecord] })
    if ($Summary)
    {
        $SummaryBlock = [scriptblock]::Create((Get-TestSummaryBlock $ScriptText))
        $All = @(. $SummaryBlock 2>&1)
        $Errors += @($All | Where-Object { $_ -is [Management.Automation.ErrorRecord] })
        $Output = @($All | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] })
    }

    return [pscustomobject]@{
        MainApp     = $MainApp
        AppArray    = $AppArray
        Response    = $ResponseAppInventory
        Sends       = $AUTestInventoryState.Sends.ToArray()
        Output      = $Output
        Message     = $OutputMessage
        BlockOutput = @($BlockOutput | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] })
        Errors      = $Errors
        Calls       = $AUTestInventoryState.Calls
        Log         = $AUTestInventoryState.Log.ToArray()
    }
}

# What the fixture keeps of a run: the upload body, $MainApp's properties in order, and the
# decoded InstalledApps payload, all as text, so a comparison is byte for byte.
function ConvertTo-TestInventoryCapture($Run)
{
    $Names = @($Run.MainApp.PSObject.Properties.Name)
    $Values = [ordered]@{}
    foreach ($Name in $Names) { $Values[$Name] = [string]$Run.MainApp.$Name }
    $Sends = @($Run.Sends)
    $Body = $null
    if ($Sends.Count -gt 0) { $Body = $Sends[-1].Text }
    return [ordered]@{
        SendCount      = $Sends.Count
        LogType        = $(if ($Sends.Count -gt 0) { $Sends[-1].LogType } else { $null })
        Body           = $Body
        MainAppNames   = $Names
        MainAppValues  = $Values
        DecodedPayload = (Expand-TestInventoryPieces (Get-TestRowPieces $Run.MainApp 'InstalledApps'))
        Response       = [string]$Run.Response
    }
}

# The fixture cases: metering off, for each API mode, with and without Store inventory, and a
# device large enough for two InstalledApps pieces.
function Get-TestInventoryCases
{
    return @(
        [ordered]@{ Name = 'LogIngestionAPI'; Settings = @{ LogAPIMode = 'LogIngestionAPI' }; Filler = 0 }
        [ordered]@{ Name = 'LogIngestionAPI with Store inventory'; Settings = @{ LogAPIMode = 'LogIngestionAPI'; CollectUWPInventory = $true }; Filler = 0 }
        [ordered]@{ Name = 'DataCollectorAPI'; Settings = @{ LogAPIMode = 'DataCollectorAPI' }; Filler = 0 }
        [ordered]@{ Name = 'LogIngestionAPI, two pieces'; Settings = @{ LogAPIMode = 'LogIngestionAPI' }; Filler = 900 }
        [ordered]@{ Name = 'DataCollectorAPI, several pieces'; Settings = @{ LogAPIMode = 'DataCollectorAPI'; CollectUWPInventory = $true }; Filler = 900 }
    )
}

function Get-TestSha256([string]$Text)
{
    if ($null -eq $Text) { return $null }
    $Sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($Sha.ComputeHash((New-Object Text.UTF8Encoding $false).GetBytes($Text))).Replace('-', '').ToLowerInvariant()) }
    finally { $Sha.Dispose() }
}

# The comparable form of a capture: hashes and lengths of the body, $MainApp's values, and the
# decoded payload, plus the full text of small cases, so a difference is readable there.
function ConvertTo-TestInventorySummary($Capture, [switch]$WithText)
{
    $Summary = [ordered]@{
        SendCount     = $Capture.SendCount
        LogType       = $Capture.LogType
        MainAppNames  = @($Capture.MainAppNames)
        BodyLength    = $(if ($null -ne $Capture.Body) { $Capture.Body.Length } else { 0 })
        BodySha256    = (Get-TestSha256 $Capture.Body)
        MainAppSha256 = (Get-TestSha256 (($Capture.MainAppValues.Keys | ForEach-Object { "$_=$($Capture.MainAppValues[$_])" }) -join "`n"))
        DecodedLength = $(if ($null -ne $Capture.DecodedPayload) { $Capture.DecodedPayload.Length } else { 0 })
        DecodedSha256 = (Get-TestSha256 $Capture.DecodedPayload)
        Response      = $Capture.Response
    }
    if ($WithText)
    {
        $Summary['Body'] = $Capture.Body
        $Summary['DecodedPayload'] = $Capture.DecodedPayload
    }
    return $Summary
}

# Captures tests\AppUsage\fixtures\v19-appinventory.json from version 19 (094a084) with this loader.
# Run it again only when the synthetic device data changes.
function Export-TestV19Fixture([string]$Path = (Join-Path $PSScriptRoot 'fixtures\v19-appinventory.json'))
{
    $V19 = Get-TestV19ScriptText
    $Cases = New-Object 'System.Collections.Generic.List[object]'
    foreach ($Case in Get-TestInventoryCases)
    {
        $Run = Invoke-TestAppInventory -ScriptText $V19 -Settings $Case.Settings -Apps (New-TestInventoryApps -Filler $Case.Filler)
        if (@($Run.Errors).Count -gt 0) { throw "Version 19 wrote errors for case $($Case.Name): $($Run.Errors[0])" }
        $Summary = ConvertTo-TestInventorySummary (ConvertTo-TestInventoryCapture $Run) -WithText:($Case.Filler -eq 0)
        $Cases.Add([ordered]@{ Name = $Case.Name; Result = $Summary })
    }
    $Fixture = [ordered]@{
        Source       = 'Intune_Windows_Inventory.ps1 at 094a084 (version 19), App Inventory region'
        CapturedWith = 'tests/AppUsage/_ImportInventory.ps1 Export-TestV19Fixture'
        Note         = 'Synthetic device data from New-TestInventoryApps and New-TestInventoryAppx; Get-Date output is not part of it.'
        Cases        = $Cases.ToArray()
    }
    $Json = ConvertTo-Json -InputObject $Fixture -Depth 6
    [IO.File]::WriteAllText($Path, ($Json -replace "`r?`n", "`r`n") + "`r`n", (New-Object Text.UTF8Encoding $false))
}

# A copy of the whole script for a child powershell.exe: settings changed, logs in LogDir, and the
# given functions defined just before the script region, so they replace the real ones.
function New-TestInventoryCopy([string]$Path, [hashtable]$Settings = @{}, [string]$Stubs = '', [string]$LogDir)
{
    $Text = Get-TestScriptText
    foreach ($Name in $Settings.Keys)
    {
        $Pattern = '(?m)^\$' + [regex]::Escape($Name) + ' = [^\r\n#]*'
        if (-not [regex]::IsMatch($Text, $Pattern)) { throw "Setting $Name not found." }
        $Text = [regex]::Replace($Text, $Pattern, ('$' + $Name + ' = ' + $Settings[$Name]).Replace('$', '$$'), 1)
    }
    $Text = $Text.Replace('C:\Windows\Logs', $LogDir)
    $Anchor = "`r`n#region script`r`n"
    if (-not $Text.Contains($Anchor)) { throw 'The script region was not found.' }
    $Text = $Text.Replace($Anchor, "`r`n" + $Stubs.Replace("`r`n", "`n").Replace("`n", "`r`n") + "`r`n#region script`r`n")
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $false))
}
