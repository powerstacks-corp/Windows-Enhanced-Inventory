<#
.SYNOPSIS
    Builds the published Intune_Windows_Inventory.ps1: validates and embeds our mapping rules and
    strips comments from the function regions. PowerStacks runs it; customers never do.

.DESCRIPTION
    Steps, in order. The build stops at the first failure and writes nothing, except that an output
    over the size limit is kept so it can be measured.
      1. Validates the PowerStacks mappings file with the inventory script's own Test-AUMappings
         -Kind PowerStacks, so the build checks exactly what devices check. Each error is printed
         with its rule ID.
      2. Removes comments from #region functions and #region APPUSAGE, using the PowerShell
         tokenizer: only Comment tokens, so nothing inside a string changes. It keeps every
         #region and #endregion line and the BEGIN and END APPUSAGE MAPPINGS markers. Everything
         outside those two regions, including the header help (version history and LEGAL
         DISCLAIMER) and #region initialize with the customer settings guidance, is unchanged.
      3. Writes $script:AppUsageMappingsEmbedded (Base64 of the GZip-compressed mappings file)
         between the BEGIN and END APPUSAGE MAPPINGS markers.
      4. Checks that the output parses and keeps its regions and markers, then writes it as UTF-8
         without a BOM, with the source's line endings.
      5. Copies the rest of the release artifact set next to the output: Test-AppUsageMappings.ps1
         and customer-mappings.example.json, from the source script's folder.

    It prints our rules version and the output size against the 524,288-byte limit Intune puts on
    a remediation script (Task 0.3). The published file is signed after the build, and the signature
    block adds to the size, so measure the signed file too.

    It never reads a customer mappings file: the only mappings it reads is the file named
    powerstacks-mappings.json, and a PowerStacks file can't hold a customer section.

    Exit codes:
      0  Built.
      1  The mappings file has errors, or the output is over the size limit (the output is kept so
         it can be measured).
      2  A file is missing or unusable: the source script, its regions or markers, the mappings
         file, or an artifact.

.PARAMETER SourceScript
    The source Intune_Windows_Inventory.ps1, with an empty embedded value between the markers.

.PARAMETER MappingsPath
    Our mappings file. It must be named powerstacks-mappings.json.

.PARAMETER OutFile
    Where to write the built script, for example .\release\Intune_Windows_Inventory.ps1. It can't be
    the source script.

.EXAMPLE
    .\Build-InventoryRelease.ps1 -SourceScript .\Intune_Windows_Inventory.ps1 -MappingsPath .\powerstacks-mappings.json -OutFile .\release\Intune_Windows_Inventory.ps1
#>
param (
    [Parameter(Mandatory = $true)]
    [string]$SourceScript,

    [Parameter(Mandatory = $true)]
    [string]$MappingsPath,

    [Parameter(Mandatory = $true)]
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
$SizeLimit = 524288
$StripRegions = @('functions', 'APPUSAGE')
$BeginMarker = '# BEGIN APPUSAGE MAPPINGS'
$EndMarker = '# END APPUSAGE MAPPINGS'
$Companions = @('Test-AppUsageMappings.ps1', 'customer-mappings.example.json')
$StrictUtf8 = New-Object Text.UTF8Encoding($false, $true)

function Stop-Build([int]$Code, [string]$Message)
{
    Write-Output $Message
    exit $Code
}

# Inputs.
if (-not (Test-Path -LiteralPath $SourceScript -PathType Leaf)) { Stop-Build 2 "The source script wasn't found: $SourceScript" }
if (-not (Test-Path -LiteralPath $MappingsPath -PathType Leaf)) { Stop-Build 2 "The mappings file wasn't found: $MappingsPath" }
$SourcePath = (Resolve-Path -LiteralPath $SourceScript).ProviderPath
$MappingsFull = (Resolve-Path -LiteralPath $MappingsPath).ProviderPath
if ([IO.Path]::GetFileName($MappingsFull) -ne 'powerstacks-mappings.json')
{
    Stop-Build 2 "The mappings file must be powerstacks-mappings.json; the build never reads any other mappings file: $MappingsFull"
}
$OutPath = [IO.Path]::GetFullPath($OutFile)
if ([string]::Equals($OutPath, $SourcePath, [StringComparison]::OrdinalIgnoreCase)) { Stop-Build 2 "The output can't be the source script: $OutPath" }
$SourceDir = Split-Path -Parent $SourcePath
$OutDir = Split-Path -Parent $OutPath

try
{
    $SourceBytes = [IO.File]::ReadAllBytes($SourcePath)
    $Skip = 0
    if ($SourceBytes.Length -ge 3 -and $SourceBytes[0] -eq 0xEF -and $SourceBytes[1] -eq 0xBB -and $SourceBytes[2] -eq 0xBF) { $Skip = 3 }
    $Source = $StrictUtf8.GetString($SourceBytes, $Skip, $SourceBytes.Length - $Skip)
    $MappingsText = [IO.File]::ReadAllText($MappingsFull, $StrictUtf8)
    if ($MappingsText.Length -gt 0 -and $MappingsText[0] -eq [char]0xFEFF) { $MappingsText = $MappingsText.Substring(1) }
}
catch { Stop-Build 2 "A file couldn't be read as UTF-8: $($_.Exception.Message)" }

# The validator comes from the source script's App Usage region, loaded the way the tests and
# Test-AppUsageMappings.ps1 load it. Nothing in the inventory itself runs.
$Region = [regex]::Match($Source, '(?ms)^#region APPUSAGE\r?\n(.*?)^#endregion APPUSAGE')
if (-not $Region.Success) { Stop-Build 2 "$SourcePath has no #region APPUSAGE." }
if (-not (Get-Command Write-CMTraceLog -ErrorAction SilentlyContinue))
{
    function Write-CMTraceLog { }
}
. ([scriptblock]::Create($Region.Groups[1].Value))
if (-not (Get-Command Test-AUMappings -ErrorAction SilentlyContinue)) { Stop-Build 2 "$SourcePath has no Test-AUMappings." }

# 1. Validate our rules.
try { $Mappings = $MappingsText | ConvertFrom-Json }
catch { Stop-Build 1 "$MappingsFull isn't valid JSON: $(Format-AUErrorText $_.Exception.Message)" }
$Problems = Test-AUMappings $Mappings -Kind PowerStacks
if ($Problems.Count -gt 0)
{
    Write-Output "$MappingsFull has errors, so nothing was built:"
    foreach ($Problem in $Problems) { Write-Output "  $Problem" }
    exit 1
}
$Identity = @($Mappings.powerStacks.identityRules | Where-Object { $null -ne $_ }).Count
$Classification = @($Mappings.powerStacks.classificationRules | Where-Object { $null -ne $_ }).Count
Write-Output "PowerStacks mappings version $($Mappings.powerStacks.version): $Identity identity rules and $Classification classification rules."

# 2. Strip comments in the function regions.
$Tokens = $null
$ParseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$Tokens, [ref]$ParseErrors)
if ($ParseErrors.Count -gt 0) { Stop-Build 2 "$SourcePath doesn't parse: $($ParseErrors[0].Message) (line $($ParseErrors[0].Extent.StartLineNumber))" }

$Spans = @()
foreach ($Name in $StripRegions)
{
    $Starts = [regex]::Matches($Source, "(?m)^#region $Name\r?$")
    $Ends = [regex]::Matches($Source, "(?m)^#endregion $Name\r?$")
    if ($Starts.Count -ne 1 -or $Ends.Count -ne 1 -or $Ends[0].Index -lt $Starts[0].Index)
    {
        Stop-Build 2 "$SourcePath needs exactly one #region $Name followed by one #endregion $Name."
    }
    $Spans += , @(($Starts[0].Index + $Starts[0].Length), $Ends[0].Index)
}

$Removals = New-Object 'System.Collections.Generic.List[object]'
foreach ($Token in $Tokens)
{
    if ($Token.Kind -ne [System.Management.Automation.Language.TokenKind]::Comment) { continue }
    $Start = $Token.Extent.StartOffset
    $InSpan = $false
    foreach ($Span in $Spans) { if ($Start -ge $Span[0] -and $Token.Extent.EndOffset -le $Span[1]) { $InSpan = $true } }
    if (-not $InSpan) { continue }
    $Text = $Token.Text
    if ($Text -match '^#(end)?region\b' -or $Text -ceq $BeginMarker -or $Text -ceq $EndMarker) { continue }
    $Removals.Add($Token.Extent)
}

# Line by line: a removed comment becomes a space, so code on both sides stays apart. A line that a
# removal leaves blank goes, with its line break; any other line loses its trailing spaces.
$Lines = New-Object Text.StringBuilder($Source.Length)
$Next = 0
$LineStart = 0
while ($LineStart -lt $Source.Length)
{
    $Break = $Source.IndexOf("`n", $LineStart)
    $LineEnd = if ($Break -ge 0) { $Break + 1 } else { $Source.Length }
    $ContentEnd = $LineEnd
    if ($Break -ge 0) { $ContentEnd = $Break; if ($ContentEnd -gt $LineStart -and $Source[$ContentEnd - 1] -eq "`r") { $ContentEnd-- } }
    while ($Next -lt $Removals.Count -and $Removals[$Next].EndOffset -le $LineStart) { $Next++ }
    if ($Next -ge $Removals.Count -or $Removals[$Next].StartOffset -ge $ContentEnd)
    {
        [void]$Lines.Append($Source, $LineStart, $LineEnd - $LineStart)
    }
    else
    {
        $Kept = New-Object Text.StringBuilder
        $At = $LineStart
        $k = $Next
        while ($k -lt $Removals.Count -and $Removals[$k].StartOffset -lt $ContentEnd)
        {
            $From = [Math]::Max($Removals[$k].StartOffset, $LineStart)
            if ($From -gt $At) { [void]$Kept.Append($Source, $At, $From - $At) }
            [void]$Kept.Append(' ')
            $At = [Math]::Min([Math]::Max($Removals[$k].EndOffset, $At), $ContentEnd)
            if ($Removals[$k].EndOffset -gt $ContentEnd) { break }
            $k++
        }
        if ($At -lt $ContentEnd) { [void]$Kept.Append($Source, $At, $ContentEnd - $At) }
        $Text = $Kept.ToString().TrimEnd()
        if ($Text.Trim() -ne '') { [void]$Lines.Append($Text).Append($Source, $ContentEnd, $LineEnd - $ContentEnd) }
    }
    $LineStart = $LineEnd
}
$Stripped = $Lines.ToString()

# 3. Embed our rules.
$Bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($MappingsText)
$Compressed = New-Object IO.MemoryStream
$Zip = New-Object IO.Compression.GZipStream($Compressed, [IO.Compression.CompressionMode]::Compress)
$Zip.Write($Bytes, 0, $Bytes.Length)
$Zip.Dispose()
$Embedded = [Convert]::ToBase64String($Compressed.ToArray())
$Block = [regex]::Matches($Stripped, "(?m)^$([regex]::Escape($BeginMarker))\r?\n(?<line>[^\r\n]*)\r?\n$([regex]::Escape($EndMarker))\r?$")
if ($Block.Count -ne 1) { Stop-Build 2 "$SourcePath needs exactly one $BeginMarker line, then the assignment line, then one $EndMarker line." }
$Assignment = $Block[0].Groups['line']
if ($Assignment.Value -notmatch "^\`$script:AppUsageMappingsEmbedded = '[A-Za-z0-9+/=]*'$")
{
    Stop-Build 2 "The line between the APPUSAGE MAPPINGS markers isn't the `$script:AppUsageMappingsEmbedded assignment."
}
$Output = $Stripped.Substring(0, $Assignment.Index) + "`$script:AppUsageMappingsEmbedded = '$Embedded'" + $Stripped.Substring($Assignment.Index + $Assignment.Length)

# 4. Check the output before writing it.
$OutTokens = $null
$OutErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($Output, [ref]$OutTokens, [ref]$OutErrors)
if ($OutErrors.Count -gt 0) { Stop-Build 2 "The built script doesn't parse: $($OutErrors[0].Message) (line $($OutErrors[0].Extent.StartLineNumber))" }
$RegionLines = { param ([string]$Text) @([regex]::Matches($Text, '(?m)^#(end)?region\b.*?\r?$') | ForEach-Object { $_.Value.TrimEnd("`r") }) }
if (((& $RegionLines $Source) -join "`n") -cne ((& $RegionLines $Output) -join "`n")) { Stop-Build 2 'The built script lost a #region or #endregion line.' }
$Head = $Source.Substring(0, $Spans[0][0])
if (-not $Output.StartsWith($Head, [StringComparison]::Ordinal)) { Stop-Build 2 'The built script changed text before #region functions.' }

$OutBytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Output)
foreach ($Name in $Companions)
{
    if (-not (Test-Path -LiteralPath (Join-Path $SourceDir $Name) -PathType Leaf)) { Stop-Build 2 "The release artifact $Name wasn't found next to the source script." }
}
if (-not [string]::IsNullOrEmpty($OutDir) -and -not (Test-Path -LiteralPath $OutDir -PathType Container)) { [void](New-Item -ItemType Directory -Path $OutDir -Force) }
if (Test-Path -LiteralPath (Join-Path $OutDir 'customer-mappings.json')) { Stop-Build 2 "The output folder holds a customer-mappings.json. A release never ships one; use an empty folder: $OutDir" }
[IO.File]::WriteAllBytes($OutPath, $OutBytes)

# 5. The rest of the release artifact set.
foreach ($Name in $Companions)
{
    $From = Join-Path $SourceDir $Name
    $To = Join-Path $OutDir $Name
    if (-not [string]::Equals([IO.Path]::GetFullPath($From), [IO.Path]::GetFullPath($To), [StringComparison]::OrdinalIgnoreCase)) { Copy-Item -LiteralPath $From -Destination $To -Force }
}

$Removed = $SourceBytes.Length - $Skip - (New-Object Text.UTF8Encoding($false)).GetByteCount($Stripped)
Write-Output "Removed $($Removals.Count) comments ($Removed bytes) from #region functions and #region APPUSAGE."
Write-Output "Embedded mappings: $($Embedded.Length) characters."
Write-Output "Release artifacts in ${OutDir}: $([IO.Path]::GetFileName($OutPath)), $($Companions -join ', ')."
$Left = $SizeLimit - $OutBytes.Length
if ($Left -lt 0)
{
    Write-Output "Output: $($OutBytes.Length) bytes, $(-$Left) bytes over the $SizeLimit-byte limit (Task 0.3). Intune refuses it."
    exit 1
}
Write-Output "Output: $($OutBytes.Length) bytes of the $SizeLimit-byte limit (Task 0.3), $Left bytes left for the signature block. Measure the signed file."
exit 0
