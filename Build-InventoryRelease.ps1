<#
.SYNOPSIS
    Builds the published Intune_Windows_Inventory.ps1: validates and embeds our mapping rules and
    strips comments from the function regions. PowerStacks runs it; customers never do.

.DESCRIPTION
    Steps, in order. The build stops at the first failure, and a failed build leaves nothing in the
    output folder: the script is written to a temporary file there and moved into place only after
    every check passes.
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
      4. Checks the output: it parses; apart from comments, blank lines, and the embedded value, its
         tokens equal the source's one for one (kind, flags, and text), so stripping can't change
         what the script does; it keeps its regions, markers, and the text before #region
         functions; its App Usage region loads and Get-AUMappings reads the embedded rules; and it
         is within the 524,288-byte limit Intune puts on a remediation script (Task 0.3).
      5. Moves the output into place as UTF-8 without a BOM, with the source's line endings, then
         copies the rest of the release artifact set next to it: Test-AppUsageMappings.ps1 and
         customer-mappings.example.json, from the source script's folder.

    It prints our rules version and the output size against the limit. The published file is
    signed after the build, and the signature block adds to the size, so measure the signed file
    too.

    It never reads a customer mappings file: the only mappings it reads is the file named
    powerstacks-mappings.json, and a PowerStacks file can't hold a customer section.

    Relative paths are relative to the current PowerShell location.

    Exit codes:
      0  Built.
      1  The mappings file has errors, or the output is over the size limit.
      2  A file is missing or unusable (the source script, its regions or markers, the mappings
         file, or an artifact), or a check of the output failed.

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
$EmptyAssignment = "`$script:AppUsageMappingsEmbedded = ''"
$Companions = @('Test-AppUsageMappings.ps1', 'customer-mappings.example.json')
$StrictUtf8 = New-Object Text.UTF8Encoding($false, $true)
$RegionPattern = '(?ms)^#region APPUSAGE\r?\n(.*?)^#endregion APPUSAGE'
$script:TempFile = $null
# The output folders this build created, deepest first, and the release files it wrote.
$script:CreatedDirs = New-Object 'System.Collections.Generic.List[string]'
$script:WrittenFiles = New-Object 'System.Collections.Generic.List[string]'

# Ends the build. A failed build removes its temporary file, the release files it wrote (the script
# and any companion, even a partial copy), and the output folders it made once they're empty, so
# nothing that looks like a release is left.
function Stop-Build([int]$Code, [string]$Message)
{
    if ($Code -ne 0)
    {
        foreach ($File in @($script:TempFile) + @($script:WrittenFiles))
        {
            try { if ($File -and (Test-Path -LiteralPath $File)) { [IO.File]::Delete($File) } } catch { Write-Output "Couldn't remove ${File}: $($_.Exception.Message)" }
        }
        foreach ($Dir in $script:CreatedDirs)
        {
            try { if ((Test-Path -LiteralPath $Dir) -and -not (Get-ChildItem -LiteralPath $Dir -Force)) { [IO.Directory]::Delete($Dir) } } catch { Write-Output "Couldn't remove ${Dir}: $($_.Exception.Message)" }
        }
    }
    if ($Message) { Write-Output $Message }
    exit $Code
}

# Compares two script texts with comments, blank lines, and the embedded value left out. Returns
# $null when every other token matches in kind, flags, and text, or else the first difference.
function Compare-BuildTokens([string]$Before, [string]$After)
{
    $Lists = foreach ($Text in @($Before, $After))
    {
        $Tokens = $null
        $Errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$Tokens, [ref]$Errors)
        $Kept = New-Object 'System.Collections.Generic.List[object]'
        foreach ($Token in $Tokens)
        {
            if ($Token.Kind -eq [System.Management.Automation.Language.TokenKind]::Comment) { continue }
            if ($Token.Kind -eq [System.Management.Automation.Language.TokenKind]::NewLine -and $Kept.Count -gt 0 -and
                $Kept[$Kept.Count - 1].Kind -eq [System.Management.Automation.Language.TokenKind]::NewLine) { continue }
            $Kept.Add($Token)
        }
        , $Kept
    }
    $Count = [Math]::Max($Lists[0].Count, $Lists[1].Count)
    for ($i = 0; $i -lt $Count; $i++)
    {
        if ($i -ge $Lists[0].Count -or $i -ge $Lists[1].Count) { return "the token count differs ($($Lists[0].Count) and $($Lists[1].Count))" }
        $A = $Lists[0][$i]
        $B = $Lists[1][$i]
        if ($A.Kind -ne $B.Kind -or $A.TokenFlags -ne $B.TokenFlags -or $A.Text -cne $B.Text)
        {
            return "source line $($A.Extent.StartLineNumber) ($($A.Kind) '$($A.Text)') became output line $($B.Extent.StartLineNumber) ($($B.Kind) '$($B.Text)')"
        }
    }
    return $null
}

# Inputs, relative to the current PowerShell location.
$Resolve = { param ([string]$Path) $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) }
try
{
    $SourcePath = & $Resolve $SourceScript
    $MappingsFull = & $Resolve $MappingsPath
    $OutPath = & $Resolve $OutFile
}
catch { Stop-Build 2 "A path couldn't be resolved: $($_.Exception.Message)" }
if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) { Stop-Build 2 "The source script wasn't found: $SourcePath" }
if (-not (Test-Path -LiteralPath $MappingsFull -PathType Leaf)) { Stop-Build 2 "The mappings file wasn't found: $MappingsFull" }
if ([IO.Path]::GetFileName($MappingsFull) -ne 'powerstacks-mappings.json')
{
    Stop-Build 2 "The mappings file must be powerstacks-mappings.json; the build never reads any other mappings file: $MappingsFull"
}
$SourcePath = [IO.Path]::GetFullPath($SourcePath)
$OutPath = [IO.Path]::GetFullPath($OutPath)
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
$Region = [regex]::Match($Source, $RegionPattern)
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
    Stop-Build 1
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

# Line by line. A removed comment becomes a space, so code on both sides stays apart. When the last
# removal on a line reaches its end, the spaces before it go too, unless that would leave a
# backtick at the end of the line (a new line continuation). A line a removal leaves blank goes
# with its line break, except after a line that ends in a backtick: there the line break ends the
# continued command, so the line stays as a blank line. The token comparison in step 4 checks all
# of this.
$Lines = New-Object Text.StringBuilder($Source.Length)
$Next = 0
$LineStart = 0
$PreviousContent = ''
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
        $PreviousContent = $Source.Substring($LineStart, $ContentEnd - $LineStart)
    }
    else
    {
        $Kept = New-Object Text.StringBuilder
        $At = $LineStart
        $k = $Next
        $ReachesEnd = $false
        while ($k -lt $Removals.Count -and $Removals[$k].StartOffset -lt $ContentEnd)
        {
            $From = [Math]::Max($Removals[$k].StartOffset, $LineStart)
            if ($From -gt $At) { [void]$Kept.Append($Source, $At, $From - $At) }
            if ($Removals[$k].EndOffset -ge $ContentEnd)
            {
                $ReachesEnd = $true
                $At = $ContentEnd
                break
            }
            [void]$Kept.Append(' ')
            $At = $Removals[$k].EndOffset
            $k++
        }
        if ($At -lt $ContentEnd) { [void]$Kept.Append($Source, $At, $ContentEnd - $At) }
        $Text = $Kept.ToString()
        if ($ReachesEnd)
        {
            $Trimmed = $Text.TrimEnd()
            if ($Trimmed.EndsWith('`')) { $Trimmed += ' ' }
            $Text = $Trimmed
        }
        if ($Text.Trim() -ne '')
        {
            [void]$Lines.Append($Text).Append($Source, $ContentEnd, $LineEnd - $ContentEnd)
            $PreviousContent = $Text
        }
        elseif ($PreviousContent.EndsWith('`'))
        {
            [void]$Lines.Append($Source, $ContentEnd, $LineEnd - $ContentEnd)
            $PreviousContent = ''
        }
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
if ($Assignment.Value -cne $EmptyAssignment) { Stop-Build 2 "The line between the APPUSAGE MAPPINGS markers must be $EmptyAssignment in the source." }
$Output = $Stripped.Substring(0, $Assignment.Index) + "`$script:AppUsageMappingsEmbedded = '$Embedded'" + $Stripped.Substring($Assignment.Index + $Assignment.Length)

# 4. Check the output.
$OutTokens = $null
$OutErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($Output, [ref]$OutTokens, [ref]$OutErrors)
if ($OutErrors.Count -gt 0) { Stop-Build 2 "The built script doesn't parse: $($OutErrors[0].Message) (line $($OutErrors[0].Extent.StartLineNumber))" }
# The written text with the embedded value put back to empty, against the source.
$EmbeddedLine = "`$script:AppUsageMappingsEmbedded = '$Embedded'"
$Difference = Compare-BuildTokens $Source $Output.Remove($Assignment.Index, $EmbeddedLine.Length).Insert($Assignment.Index, $EmptyAssignment)
if ($Difference) { Stop-Build 2 "Stripping comments would change the script, so nothing was built: $Difference" }
$RegionLines = { param ([string]$Text) @([regex]::Matches($Text, '(?m)^#(end)?region\b.*?\r?$') | ForEach-Object { $_.Value.TrimEnd("`r") }) }
if (((& $RegionLines $Source) -join "`n") -cne ((& $RegionLines $Output) -join "`n")) { Stop-Build 2 'The built script lost a #region or #endregion line.' }
$Head = $Source.Substring(0, $Spans[0][0])
if (-not $Output.StartsWith($Head, [StringComparison]::Ordinal)) { Stop-Build 2 'The built script changed text before #region functions.' }

foreach ($Name in $Companions)
{
    if (-not (Test-Path -LiteralPath (Join-Path $SourceDir $Name) -PathType Leaf)) { Stop-Build 2 "The release artifact $Name wasn't found next to the source script." }
}
if (-not (Test-Path -LiteralPath $OutDir -PathType Container))
{
    # Every level that isn't there yet, deepest first, so a failed build can remove them all.
    $Missing = $OutDir
    while ($Missing -and -not (Test-Path -LiteralPath $Missing))
    {
        $script:CreatedDirs.Add($Missing)
        $Missing = Split-Path -Path $Missing -Parent
    }
    try { [void](New-Item -ItemType Directory -Path $OutDir -Force) }
    catch { Stop-Build 2 "The output folder couldn't be created: $($_.Exception.Message)" }
}
if (Test-Path -LiteralPath (Join-Path $OutDir 'customer-mappings.json')) { Stop-Build 2 "The output folder holds a customer-mappings.json. A release never ships one; use an empty folder: $OutDir" }

$OutBytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Output)
$script:TempFile = Join-Path $OutDir ('.build-' + [guid]::NewGuid().ToString('N') + '.tmp')
try { [IO.File]::WriteAllBytes($script:TempFile, $OutBytes) }
catch { Stop-Build 2 "The release couldn't be written, so nothing was left: $($_.Exception.Message)" }

# The written file's App Usage region, loaded the way _Import.ps1 loads it, in a fresh runspace:
# Get-AUMappings must read the embedded rules.
$Written = [IO.File]::ReadAllText($script:TempFile, $StrictUtf8)
$BuiltRegion = [regex]::Match($Written, $RegionPattern)
if (-not $BuiltRegion.Success) { Stop-Build 2 'The built script has no #region APPUSAGE.' }
$Shell = [powershell]::Create()
try
{
    [void]$Shell.AddScript("function Write-CMTraceLog { }`r`n" + $BuiltRegion.Groups[1].Value + "`r`nGet-AUMappings -Embedded `$script:AppUsageMappingsEmbedded -BesideDir '' -CustomerPath ''")
    $Loaded = @($Shell.Invoke())
    $LoadErrors = @($Shell.Streams.Error)
}
catch { $Loaded = @(); $LoadErrors = @($_) }
finally { $Shell.Dispose() }
if ($LoadErrors.Count -gt 0) { Stop-Build 2 "The built script's App Usage region didn't load: $($LoadErrors[0])" }
$Check = $Loaded | Select-Object -Last 1
if ($null -eq $Check -or $Check.Source -ne 'Embedded' -or @($Check.Errors).Count -gt 0 -or $Check.PowerStacksVersion -cne [string]$Mappings.powerStacks.version -or
    @($Check.Mappings.powerStacks.identityRules).Count -ne $Identity -or @($Check.Mappings.powerStacks.classificationRules).Count -ne $Classification)
{
    Stop-Build 2 "The built script's Get-AUMappings didn't read the embedded rules: $(@($Check.Errors) -join ' | ')"
}

$Removed = $SourceBytes.Length - $Skip - (New-Object Text.UTF8Encoding($false)).GetByteCount($Stripped)
Write-Output "Removed $($Removals.Count) comments ($Removed bytes) from #region functions and #region APPUSAGE."
Write-Output "Embedded mappings: $($Embedded.Length) characters; the built script reads $Identity identity and $Classification classification rules."
$Left = $SizeLimit - $OutBytes.Length
if ($Left -lt 0) { Stop-Build 1 "Output: $($OutBytes.Length) bytes, $(-$Left) bytes over the $SizeLimit-byte limit (Task 0.3). Intune refuses it, so nothing was built." }

# 5. Move the output into place, then the rest of the release artifact set. Any failure here
# removes what this build wrote, so the script never ships without its companions.
try
{
    # A move in one folder is a rename, so a failed one leaves any earlier file there as it was.
    Move-Item -LiteralPath $script:TempFile -Destination $OutPath -Force
    $script:TempFile = $null
    $script:WrittenFiles.Add($OutPath)
    foreach ($Name in $Companions)
    {
        $From = Join-Path $SourceDir $Name
        $To = Join-Path $OutDir $Name
        if (-not [string]::Equals([IO.Path]::GetFullPath($From), [IO.Path]::GetFullPath($To), [StringComparison]::OrdinalIgnoreCase))
        {
            $script:WrittenFiles.Add($To)
            Copy-Item -LiteralPath $From -Destination $To -Force
        }
    }
}
catch { Stop-Build 2 "The release artifacts couldn't be written, so none were left: $($_.Exception.Message)" }
Write-Output "Release artifacts in ${OutDir}: $([IO.Path]::GetFileName($OutPath)), $($Companions -join ', ')."
Write-Output "Output: $($OutBytes.Length) bytes of the $SizeLimit-byte limit (Task 0.3), $Left bytes left for the signature block. Measure the signed file."
Stop-Build 0
