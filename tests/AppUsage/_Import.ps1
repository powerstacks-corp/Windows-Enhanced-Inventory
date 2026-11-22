# Dot-source this file from a Pester BeforeAll block. It loads only the APPUSAGE region of the
# inventory script (function definitions and $script: constants) into the caller's scope, so the
# tests never run the inventory itself.
$AUScriptPath = Join-Path $PSScriptRoot '..\..\Intune_Windows_Inventory.ps1'
$AUScriptText = [IO.File]::ReadAllText((Resolve-Path $AUScriptPath).Path, [Text.Encoding]::UTF8)
$AURegionMatch = [regex]::Match($AUScriptText, '(?ms)^#region APPUSAGE\r?\n(.*?)^#endregion APPUSAGE')
if (-not $AURegionMatch.Success) { throw "APPUSAGE region not found in $AUScriptPath" }
$AURegionText = $AURegionMatch.Groups[1].Value
. ([scriptblock]::Create($AURegionText))
