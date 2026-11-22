<#
.SYNOPSIS
    Checks a customer App Usage mappings file before you deploy it.

.DESCRIPTION
    Reads the file the same way Intune_Windows_Inventory.ps1 does on a device (at most 1 MB, parsed
    as JSON data, never run) and validates it with the inventory script's own rules, so the result
    matches what devices will do. It only reads; it never changes the file.

    The validation code isn't copied into this script. It loads the App Usage section of the
    inventory script, so use the inventory script version you deploy.

    Exit codes:
      0  The file is valid. Its SHA-256 is printed; devices report the same value in
         CustomerMappingsHash_s.
      1  The file is missing, larger than 1 MB, isn't valid JSON, or has rule errors. Each error
         is printed with its rule ID.
      2  The inventory script wasn't found, or it has no App Usage section.

.PARAMETER Path
    The customer mappings file to check, for example customer-mappings.json.

.PARAMETER InventoryScriptPath
    The inventory script to take the validation rules from. Defaults to Intune_Windows_Inventory.ps1
    in the same folder as this script.

.EXAMPLE
    .\Test-AppUsageMappings.ps1 -Path .\customer-mappings.json
#>
param (
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [string]$InventoryScriptPath
)

if ([string]::IsNullOrWhiteSpace($InventoryScriptPath))
{
    $InventoryScriptPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'Intune_Windows_Inventory.ps1'
}

if (-not (Test-Path -LiteralPath $InventoryScriptPath -PathType Leaf))
{
    Write-Output "The inventory script wasn't found: $InventoryScriptPath. Put Test-AppUsageMappings.ps1 next to Intune_Windows_Inventory.ps1, or pass -InventoryScriptPath."
    exit 2
}

# Load only the App Usage section (functions and constants), the same way the tests do. Nothing in
# the inventory itself runs.
$ScriptText = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $InventoryScriptPath).ProviderPath, [Text.Encoding]::UTF8)
$Region = [regex]::Match($ScriptText, '(?ms)^#region APPUSAGE\r?\n(.*?)^#endregion APPUSAGE')
if (-not $Region.Success)
{
    Write-Output "$InventoryScriptPath has no App Usage section. Use Intune_Windows_Inventory.ps1 version 20 or later."
    exit 2
}
if (-not (Get-Command Write-CMTraceLog -ErrorAction SilentlyContinue))
{
    function Write-CMTraceLog { }
}
. ([scriptblock]::Create($Region.Groups[1].Value))
if (-not (Get-Command Test-AUMappings -ErrorAction SilentlyContinue) -or -not (Get-Command Read-AUCustomerMappingsFile -ErrorAction SilentlyContinue))
{
    Write-Output "$InventoryScriptPath has no mappings validator. Use Intune_Windows_Inventory.ps1 version 20 or later."
    exit 2
}

$FullPath = $Path
if (Test-Path -LiteralPath $Path) { $FullPath = (Resolve-Path -LiteralPath $Path).ProviderPath }
$File = Read-AUCustomerMappingsFile -Path $FullPath
switch ($File.State)
{
    'Absent'
    {
        Write-Output "File not found: $FullPath"
        exit 1
    }
    'Parsed'
    {
        $Problems = Test-AUMappings $File.Data -Kind Customer
    }
    default
    {
        $Problems = $File.Errors
    }
}

if ($Problems.Count -gt 0)
{
    Write-Output "$FullPath is not valid. Devices ignore the whole file until it's fixed:"
    foreach ($Problem in $Problems) { Write-Output "  $Problem" }
    exit 1
}

$Identity = @($File.Data.customer.identityRules | Where-Object { $null -ne $_ }).Count
$Classification = @($File.Data.customer.classificationRules | Where-Object { $null -ne $_ }).Count
Write-Output "$FullPath is valid: $Identity identity rules and $Classification classification rules."
Write-Output "SHA-256: $($File.Hash)"
exit 0
