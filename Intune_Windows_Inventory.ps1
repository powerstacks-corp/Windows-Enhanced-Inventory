<#
.SYNOPSIS
    Comprehensive inventory and warranty collection script for Intune-managed Windows 10/11 devices.
    Gathers hardware, software, driver, monitor, disk, battery, Microsoft 365, and warranty data,
    then uploads results to Azure Log Analytics for centralized reporting.

.DESCRIPTION
    This script is designed for deployment via Intune to Windows 10/11 endpoints. It collects detailed inventory data including:
      - Hardware specs (CPU, RAM, disks, chassis)
      - Battery health
      - Monitor (LCD) information including serial numbers and date of manufacture
      - Installed Win32 and UWP applications
      - Installed and available drivers
      - Microsoft 365 update channel and compliance
      - Device warranty status for Dell, HP, Lenovo, and Getac (via vendor APIs)
    Warranty lookups are cached locally to minimize API calls and can be forced to refresh as needed.
    All collected data is compressed, base64-encoded, and securely uploaded to Azure Log Analytics.
    The script is modular, allowing granular control over which inventory types are collected via variables.

.APIKEYS
    To enable warranty lookups, you must obtain API credentials from each vendor:
      - Dell: Register for a Dell TechDirect account (https://techdirect.dell.com/), request API access, and generate a Client ID and Secret for the Warranty API.
      - Lenovo: Request access to the Lenovo Warranty API at https://supportapi.lenovo.com or through your Lenovo rep. You will receive a Client ID for authentication.
      - HP: Apply for HP’s Warranty API access at https://developer.hp.com/ or through your HP rep. After approval, create an application to obtain a Client ID and Secret.
      - Getac: Contact Getac support or your Getac account representative to request API access and credentials for warranty lookups.


.PARAMETER WarrantyMaxCacheAgeDays
    [int] Maximum number of days before cached warranty data is considered stale. Default: 180.

.PARAMETER WarrantyForceRefresh
    [switch] When set to $true, ignores cached warranty data and forces a fresh API lookup.

.PARAMETER $CollectDeviceInventory
    [bool] Set to $true to collect device hardware inventory. Default: $true.

.PARAMETER $CollectAppInventory
    [bool] Set to $true to collect installed application inventory. Default: $true.

.PARAMETER $CollectDriverInventory
    [bool] Set to $true to collect installed and available driver inventory. Default: $true.

.PARAMETER $CollectUWPInventory
    [bool] Set to $true to collect UWP (AppX) application inventory. Default: $false.

.PARAMETER $CollectMicrosoft365
    [bool] Set to $true to collect Microsoft 365 update and compliance data. Default: $true.

.PARAMETER $CollectWarranty
    [bool] Set to $true to collect device warranty information. Default: $false.

.PARAMETER $RemoveBuiltInMonitors
    [bool] Set to $true to exclude built-in monitors from monitor inventory. Default: $false.

.PARAMETER $InventoryDateFormat
    [string] Date format string for inventory timestamps. Default: "MM-dd HH:mm".

.PARAMETER $CustomerId
    [string] Azure Log Analytics Workspace ID.

.PARAMETER $SharedKey
    [string] Azure Log Analytics Primary Key.

.PARAMETER $WarrantyDellClientID, $WarrantyDellClientSecret
    [string] Dell API credentials for warranty lookup.

.PARAMETER $WarrantyLenovoClientID
    [string] Lenovo API credential for warranty lookup.

.PARAMETER $WarrantyHPClientID, $WarrantyHPClientSecret
    [string] HP API credentials for warranty lookup.

.PARAMETER $TimeStampField
    [string] Optional. Specifies the timestamp field for Log Analytics ingestion. Leave blank unless required.

.NOTES
    Author: John Marcum (PJM)
    Date: August 10, 2026
    Contact: https://x.com/MEM_MVP

.VERSION HISTORY
12 - November 5, 2025
- Fixed bug in driver matching process

12 - June 9, 2025
- Added HP warranty support and warranty caching
- Changed warranty date fields to datetime
- Added $CollectUWPInventory toggle
- Fixed driver inventory bug with Get-Package provider
- Added OS install date

13 - January 6, 2026
- Modified to work with new log ingestion API

14 - January 20, 2026
- Added missing Send-LogIngestionAPI function

15 - January 21, 2026
- Added SCCM style logging

17 - July 13, 2026
- Added secretless ingestion support using the PowerStacks Entra Token Broker. When $BrokerUrl is set,
  the device authenticates to the broker with its Entra Join certificate (mutual TLS) and posts to the
  DCR using a broker-minted token - no secret on the device and no relay hop. Added the $BrokerUrl and
  $BrokerClientId settings. This replaces the earlier non-functional in-tenant Function relay.
- The legacy Data Collector API path and the classic client-secret DCR/DCE path are unchanged.
- Hardened user-SID resolution: when the logged-on account can't be translated to a SID
  (IdentityNotMappedException), fall back to the user profile list and, failing that, continue without
  a user SID (machine-scope app inventory only) instead of throwing.
- Use HTTPS instead of HTTP for the Lenovo warranty API endpoint.

18 - July 23, 2026
- HP warranty: refresh the access token on a 401 and cap the batch job at 12 minutes. HP's API can take
  5 to 10 minutes to return when it is busy, which is longer than a token stays valid, so a long job no
  longer fails on an expired token or hangs. Each status and results call requests a new token and retries
  once if the current one is rejected, and the poll loop is bounded by a 12-minute deadline.

19 - August 10, 2026

Bugfix in HP warranty

20 - unreleased
- Added App Usage (software metering), off by default ($CollectAppMetering).

########### LEGAL DISCLAIMER ###########
    This script is provided "as is" without warranty of any kind, either express or implied.
    Use at your own risk. Test thoroughly before deploying in production environments.
#>


#region initialize
# Enable TLS 1.2 support
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Current script version. ALWAYS UPDATE MANUALLY!
$ScriptVersion = '19 - August 10, 2026'


# Current date/time
$Now = Get-Date -Format "yyyy-MM-dd_HHmmss"

# Enable/Disable Script Transciption
$Transcribe = $False
$logPath = "C:\Windows\Logs\Inventory_Script_$Now.log"

# Path for SCCM Style Log
$CMLog = "C:\Windows\Logs\Enhanced_Intune_Inventory_$Now.log"

# "LogIngestionAPI" (Latest) or "DataCollectorAPI" (Legacy)
$LogAPIMode = "LogIngestionAPI"

########## Use for LogIngestionAPI #############

# Replace with your Tenant ID in which the Data Collection Endpoint resides
$TenantId = "<ENTER YOUR TENANT ID HERE>"

# Replace with your Client ID created and granted permissions
$ClientId = "<ENTER YOUR CLIENT ID HERE>"

# Replace with your Secret created for the above Client
$ClientSecret = "<ENTER YOUR CLIENT SECRET HERE>"

# Replace with your Data Collection Endpoint - Log Ingestion URL
$DceURI = "<ENTER YOUR DATA COLLECTION ENDPOINT - LOG INGESTION URL HERE>"

# Replace with your Data Collection Rule - Immutable ID
$DcrImmutableId = "<ENTER YOUR DATA COLLECTION RULE - IMMUTABLE ID HERE>"

##### OPTIONAL ####
#secretless ingestion via the PowerStacks Entra Token Broker. When $BrokerUrl is set to a
# real URL, the device authenticates to the broker with its Entra Join certificate (mutual TLS),
# receives a short-lived signed assertion, and posts straight to the DCR using a broker-minted token -
# no secret on the device and no relay hop. This replaces the client secret on the DCR upload path;
# leave the placeholder to keep using the classic client-secret upload. Requires SYSTEM/elevated (the
# device cert key is TPM-bound). $BrokerClientId is the broker's inventory user-assigned managed
# identity client id (deploy output 'inventoryIdentityClientId').
$BrokerUrl = "<Enter Your Broker URL>"
$BrokerClientId = "<Enter Your Broker Inventory Identity Client ID>"

# Submission retry: on a rejected upload, wait, retry, and double the wait each time,
# capping the wait at $SubmissionMaxWaitSeconds, up to $SubmissionMaxRetries before
# giving up for this run. The defaults give waits of 60, 120, 240, 360, 360 seconds
# (~19 minutes total). Keep that worst-case total within your Intune remediation timeout.
$SubmissionMaxRetries = 5
$SubmissionInitialWaitSeconds = 60
$SubmissionMaxWaitSeconds = 360

#################################################

########## Use for DataCollectorAPI #############

# Replace with your Log Analytics Workspace ID
$CustomerId = "<Enter Your Log Analytics Workspace ID>"

# Replace with your Primary Key
$SharedKey = "<Enter Your Log Analytics Workspace Primary Key>"

#################################################

#Control if you want to collect Device, Win32 App, UWP App, and Driver Inventory. (True = Collect)
$CollectDeviceInventory = $true
$CollectAppInventory = $true
$CollectDriverInventory = $true
$MatchDrivers = $true # One customer reported that matching the drives was taking hours on a subset of devices. Set to false to skip the matching process and just report the raw driver data from Get-Package.

#Sub-Control under Device Inventory
$CollectMicrosoft365 = $true
$CollectWarranty = $false # Set to true to collect warranty data

#Sub-Control under App Inventory
$CollectUWPInventory = $false # Set to true to collect UWP (modern app) inventory.
$CollectAppMetering = $false # Set to true to collect App Usage (software metering): which installed apps are used, from SRUM. Windows 11 25H2 and later. Store app usage follows $CollectUWPInventory.
$MinFocusSecondsForUse = 1 # App Usage: seconds of focus that count as a use.
$AppUsageCustomerMappingsPath = 'C:\ProgramData\PowerStacks\AppUsage\customer-mappings.json' # App Usage: your own mapping rules, if you deliver this file. Your rules win over ours.

#Warranty keys
$WarrantyDellClientID = "<ENTER YOUR DELL WARRANTY CLIENT ID HERE>"
$WarrantyDellClientSecret = "<ENTER YOUR DELL WARRANTY CLIENT SECRET HERE>"
$WarrantyLenovoClientID = "<ENTER YOUR LENOVO WARRANTY CLIENT ID HERE>"
$WarrantyHPClientID = "<ENTER YOUR HP WARRANTY CLIENT ID HERE>"
$WarrantyHPClientSecret = "<ENTER YOUR HP WARRANTY CLIENT SECRET HERE>"  # Expires September 6, 2026

# Warranty cache settings
[int]$WarrantyMaxCacheAgeDays = 352 # The max age of the .json file which caches warranty data.
[switch]$WarrantyForceRefresh = $false # Set to true to ignore the json and pull data from the API.

# You can use an optional field to specify the timestamp from the data. If the time field is not specified, Azure Monitor assumes the time is the message ingestion time
# DO NOT DELETE THIS VARIABLE. Recommended keep this blank.
$TimeStampField = ""

#Control if you want to remove BuiltIn Monitors (true = Remove)
$RemoveBuiltInMonitors = $false

#Inventory Date Format (sample: "MM-dd HH:mm", "dd-MM HH:mm")
$InventoryDateFormat = "MM-dd HH:mm"

#endregion initialize

# Start transcribing:
if ($Transcribe)
{
    Start-Transcript -Path $logPath | Out-Null
}


#region functions

# Function to write SCCM style logs
function Write-CMTraceLog
{
    <#
    .SYNOPSIS
      Write a CMTrace / SCCM-style log entry.

    .DESCRIPTION
      - Defaults to Info severity.
      - Use -WarningMsg or -ErrorMsg to raise severity.
      - Writes to the log file only, never the console.
      - Defaults to writing to $script:CMLog.

    .PARAMETER Message
      Log message text.

    .PARAMETER Path
      Log file path. Defaults to $script:CMLog.

    .PARAMETER Component
      Component name displayed in CMTrace.

    .PARAMETER Type
      1 = Info, 2 = Warning, 3 = Error

    .PARAMETER WarningMsg
      Sets severity to Warning (2).

    .PARAMETER ErrorMsg
      Sets severity to Error (3).
    #>

    [CmdletBinding(DefaultParameterSetName = 'ByType')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Message,

        [Parameter(Position = 1)]
        [string] $Path = $script:CMLog,

        [string] $Component = $(if ($PSCommandPath)
            {
                [IO.Path]::GetFileName($PSCommandPath)
            }
            else
            {
                'PowerShell'
            }),

        [Parameter(ParameterSetName = 'ByType')]
        [ValidateSet(1, 2, 3)]
        [int] $Type = 1,

        [Parameter(ParameterSetName = 'BySwitch')]
        [switch] $WarningMsg,

        [Parameter(ParameterSetName = 'BySwitch')]
        [switch] $ErrorMsg,

        # Kept for compatibility. Messages are no longer written to the console.
        [switch] $EmitErrorRecord
    )

    # Resolve severity from switches
    if ($PSCmdlet.ParameterSetName -eq 'BySwitch')
    {
        if ($ErrorMsg)
        {
            $Type = 3
        }
        elseif ($WarningMsg)
        {
            $Type = 2
        }
        else
        {
            $Type = 1
        }
    }

    # ----- Console -----
    # Nothing is written to the console here. The script's only output is the one-line
    # upload summary at the end, which Intune shows in the detection output column.
    # Everything else goes to the log file.

    # ----- Write to CMTrace log -----
    try
    {
        if ([string]::IsNullOrWhiteSpace($Path))
        {
            throw "Log path is empty. `$CMLog must be set before logging."
        }

        $dir = Split-Path -Path $Path -Parent
        if ($dir -and -not (Test-Path -LiteralPath $dir))
        {
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
        }

        $now = Get-Date
        $time = $now.ToString('HH:mm:ss.fff')
        $date = $now.ToString('MM-dd-yyyy')

        $offsetMinutes = [int][TimeZoneInfo]::Local.GetUtcOffset($now).TotalMinutes
        $bias = if ($offsetMinutes -ge 0)
        {
            "+$offsetMinutes"
        }
        else
        {
            "$offsetMinutes"
        }

        $context = try
        {
            [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        }
        catch
        {
            ''
        }
        $thread = [System.Diagnostics.Process]::GetCurrentProcess().Id

        $safeMessage = $Message `
            -replace '&', '&amp;' `
            -replace '<', '&lt;' `
            -replace '>', '&gt;'

        $line = "<![LOG[$safeMessage]LOG]!><time=""$time$bias"" date=""$date"" component=""$Component"" context=""$context"" type=""$Type"" thread=""$thread"" file="""">"

        Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
    }
    catch
    {
        # If logging itself fails, *then* emit a real error record
        Write-Error "Write-CMTraceLog failed: $($_.Exception.Message)"
    }
}


# Function to get all Installed Application
function Get-InstalledApplications()
{
    <#
.SYNOPSIS
    Retrieves installed Win32 applications for a specified user.
.DESCRIPTION
    Scans registry locations for installed Win32 applications, including 32-bit and 64-bit entries, and returns details such as name, version, publisher, and install date.
.PARAMETER UserSid
    The SID of the user whose HKU registry hive should be scanned for per-user applications.
.OUTPUTS
    PSCustomObject[] representing installed applications.
#>
    param(
        [string]$UserSid
    )

    Write-CMTraceLog "Get-InstalledApplications: Starting for UserSid: $UserSid"

    try
    {
        Write-CMTraceLog "Get-InstalledApplications: Mounting HKU registry hive..."
        New-PSDrive -PSProvider Registry -Name "HKU" -Root HKEY_USERS -ErrorAction Stop | Out-Null
        Write-CMTraceLog "Get-InstalledApplications: HKU registry hive mounted successfully"
    }
    catch
    {
        Write-CMTraceLog "Get-InstalledApplications: Error mounting HKU registry: $($_.Exception.Message)" -ErrorMsg
    }

    $regpath = @("HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*")
    $regpath += "HKU:\$UserSid\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
    if (-not ([IntPtr]::Size -eq 4))
    {
        $regpath += "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        $regpath += "HKU:\$UserSid\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        Write-CMTraceLog "Get-InstalledApplications: 64-bit system detected, including Wow6432Node paths"
    }

    Write-CMTraceLog "Get-InstalledApplications: Scanning $($regpath.Count) registry paths for installed applications..."
    $propertyNames = 'DisplayName', 'DisplayVersion', 'Publisher', 'UninstallString', 'InstallDate'

    try
    {
        $Apps = Get-ItemProperty $regpath -Name $propertyNames -ErrorAction SilentlyContinue | . { process
            {
                if ($_.DisplayName)
                {
                    $_
                }
            } } | Select-Object DisplayName, DisplayVersion, Publisher, UninstallString, InstallDate, PSPath | Sort-Object DisplayName
        Write-CMTraceLog "Get-InstalledApplications: Found $($Apps.Count) installed applications"
    }
    catch
    {
        Write-CMTraceLog "Get-InstalledApplications: Error retrieving applications from registry: $($_.Exception.Message)" -ErrorMsg
        $Apps = @()
    }

    # Convert InstallDate string to DateTime and format as DD/MM/YYYY, handling empty InstallDate
    Write-CMTraceLog "Get-InstalledApplications: Processing install dates..."
    $dateProcessCount = 0
    foreach ($app in $Apps)
    {
        if (![string]::IsNullOrWhiteSpace($app.InstallDate))
        {
            $parsedDate = [DateTime]::MinValue
            if ([DateTime]::TryParseExact($app.InstallDate, 'yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsedDate))
            {
                $app.InstallDate = $parsedDate.ToString('dd-MM-yyyy')
                $dateProcessCount++
            }
            else
            {
                # Date parsing failed, handle accordingly (e.g., set to null or a default value)
                $app.InstallDate = $null
            }
        }
        else
        {
            # Empty InstallDate string, handle accordingly (e.g., set to null or a default value)
            $app.InstallDate = $null
        }
    }
    Write-CMTraceLog "Get-InstalledApplications: Processed $dateProcessCount install dates"

    try
    {
        Write-CMTraceLog "Get-InstalledApplications: Unmounting HKU registry hive..."
        Remove-PSDrive -Name "HKU" -ErrorAction Stop | Out-Null
        Write-CMTraceLog "Get-InstalledApplications: HKU registry hive unmounted successfully"
    }
    catch
    {
        Write-CMTraceLog "Get-InstalledApplications: Error unmounting HKU registry: $($_.Exception.Message)" -WarningMsg
    }

    Write-CMTraceLog "Get-InstalledApplications: Completed, returning $($Apps.Count) applications"
    return $Apps
}

# Function to get deduplicated Appx Installed Applications (UWP)
function Get-AppxInstalledApplications()
{
    <#
.SYNOPSIS
    Retrieves deduplicated list of installed UWP (AppX) applications for all users.
.DESCRIPTION
    Handles known issues with Get-AppxPackage on Windows 11 24H2, loads required assemblies, and returns UWP app details including name, version, and publisher.
.OUTPUTS
    PSCustomObject[] representing installed UWP applications.
#>

    Write-CMTraceLog "Get-AppxInstalledApplications: Starting UWP application inventory..."

    # Fix for issue which breaks Get-AppxPackage in Win11 24H2
    # This is a known bug in 24H2.
    # Remove the fix once MS fixes the issue. Until this UWP app inventory may or may not work in 24H2
    Write-CMTraceLog "Get-AppxInstalledApplications: Applying Win11 24H2 compatibility fix..."
    try
    {
        Add-Type -AssemblyName "System.EnterpriseServices"
        $publish = [System.EnterpriseServices.Internal.Publish]::new()
        Write-CMTraceLog "Get-AppxInstalledApplications: EnterpriseServices assembly loaded"
    }
    catch
    {
        Write-CMTraceLog "Get-AppxInstalledApplications: Error loading EnterpriseServices: $($_.Exception.Message)" -WarningMsg
    }

    $dlls = @(
        'System.Memory.dll',
        'System.Numerics.Vectors.dll',
        'System.Runtime.CompilerServices.Unsafe.dll',
        'System.Security.Principal.Windows.dll'
    )

    Write-CMTraceLog "Get-AppxInstalledApplications: Checking GAC for required DLLs..."
    foreach ($dll in $dlls)
    {
        $dllPath = "$env:SystemRoot\\System32\\WindowsPowerShell\\v1.0\\$dll"
        $fileName = [System.IO.Path]::GetFileNameWithoutExtension($dll)

        $gacPath = "$env:windir\\Microsoft.NET\\assembly"
        $existsInGAC = Get-ChildItem -Recurse -Path $gacPath -Filter "$fileName.dll" -ErrorAction SilentlyContinue | Where-Object {
            $_.FullName -match [regex]::Escape($fileName)
        }

        if (-not $existsInGAC)
        {
            Write-CMTraceLog "Get-AppxInstalledApplications: $dll not found in GAC. Installing..."
            try
            {
                $publish.GacInstall($dllPath)
                Write-CMTraceLog "Get-AppxInstalledApplications: $dll installed successfully"
            }
            catch
            {
                Write-CMTraceLog "Get-AppxInstalledApplications: Error installing $dll - $($_.Exception.Message)" -WarningMsg
            }
        }
        else
        {
            Write-CMTraceLog "Get-AppxInstalledApplications: $dll already exists in GAC"
        }
    }
    # End the fix


    # Get the apps
    Write-CMTraceLog "Get-AppxInstalledApplications: Retrieving AppX packages for all users..."
    try
    {
        $ErrorActionPreference = 'Stop'
        $appPackages = Get-AppxPackage -AllUsers
        Write-CMTraceLog "Get-AppxInstalledApplications: Retrieved $($appPackages.Count) AppX packages"
    }
    catch
    {
        Write-CMTraceLog "Get-AppxInstalledApplications: Failed to retrieve Appx packages: $($_.Exception.Message)" -WarningMsg
        $appPackages = @() # or $null if you prefer
    }
    finally
    {
        $ErrorActionPreference = 'Continue' # Reset to default if needed
    }

    $uwpAppList = @()

    # Process only the installed apps
    Write-CMTraceLog "Get-AppxInstalledApplications: Processing AppX packages..."
    $processedCount = 0
    foreach ($pkg in $appPackages)
    {
        if ($pkg.PackageUserInformation | Where-Object { $_.InstallState -eq 'Installed' })
        {
            $processedCount++
            $publisher = $null
            try
            {
                $manifest = Get-AppxPackageManifest -Package $pkg.PackageFullName
                $publisher = $manifest.Package.Properties.PublisherDisplayName
            }
            catch
            {
                Write-CMTraceLog "Get-AppxInstalledApplications: Error getting manifest for $($pkg.Name): $($_.Exception.Message)" -WarningMsg
            }

            $uwpApp = New-Object -TypeName PSObject
            $uwpApp | Add-Member -MemberType NoteProperty -Name "DisplayName" -Value $pkg.Name -Force
            $uwpApp | Add-Member -MemberType NoteProperty -Name "DisplayVersion" -Value $pkg.Version.ToString() -Force
            $uwpApp | Add-Member -MemberType NoteProperty -Name "Publisher" -Value $publisher -Force
            $uwpApp | Add-Member -MemberType NoteProperty -Name "AppType" -Value "UWP" -Force
            $uwpAppList += $uwpApp
        }
    }
    Write-CMTraceLog "Get-AppxInstalledApplications: Processed $processedCount installed packages"

    Write-CMTraceLog "Get-AppxInstalledApplications: Deduplicating UWP apps..."
    $dedupedUwpApps = $uwpAppList | Sort-Object DisplayName, DisplayVersion -Unique
    Write-CMTraceLog "Get-AppxInstalledApplications: Completed, returning $($dedupedUwpApps.Count) deduplicated apps"
    return $dedupedUwpApps
}



# Function to get Office update infomation
function Get-Microsoft365
{
    <#
.SYNOPSIS
    Retrieves Microsoft 365 (Office Click-to-Run) update and compliance information.
.DESCRIPTION
    Determines installed Office version, update channel, latest release, end of support, and other compliance details by querying registry and Microsoft APIs.
.OUTPUTS
    PSCustomObject with Office version, channel, release, and support information.
#>
    $IsC2R = Test-Path 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun'
    if (-not $IsC2R)
    {
        Write-CMTraceLog "Not Click-to-Run Office"; return $null
    }

    try
    {
        $ConfigPath = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
        $OfficeVersion = [version](Get-ItemProperty -Path $ConfigPath -ErrorAction Stop | Select-Object -ExpandProperty VersionToReport)
        $OfficeProductIds = (Get-ItemProperty -Path $ConfigPath -ErrorAction Stop | Select-Object -ExpandProperty ProductReleaseIds)
        $OfficeVersionString = $OfficeVersion.ToString()
        Write-CMTraceLog "Installed Version: $OfficeVersionString"
    }
    catch
    {
        Write-CMTraceLog "Failed to read Office configuration: $_"
        return $null
    }

    $IsM365 = ($OfficeProductIds -like '*O365*') -or ($OfficeProductIds -like '*M365*')

    $Channels = @(
        @{ GUID = '492350f6-3a01-4f97-b9c0-c7c6ddf67d60'; Name = 'Monthly'; GPO = 'Current' }
        @{ GUID = '64256afe-f5d9-4f86-8936-8840a6a4f5be'; Name = 'Monthly (Preview)'; GPO = 'FirstReleaseCurrent' }
        @{ GUID = '55336b82-a18d-4dd6-b5f6-9e5095c314a6'; Name = 'Monthly Enterprise'; GPO = 'MonthlyEnterprise' }
        @{ GUID = '7ffbc6bf-bc32-4f92-8982-f9dd17fd3114'; Name = 'Semi-Annual'; GPO = 'Deferred' }
        @{ GUID = 'b8f9b850-328d-4355-9145-c59439a0c4cf'; Name = 'Semi-Annual (Preview)'; GPO = 'FirstReleaseDeferred' }
        @{ GUID = '5440fd1f-7ecb-4221-8110-145efaa6372f'; Name = 'Beta'; GPO = 'InsiderFast' }
    )

    $OfficeChannel = @{ Name = $null }
    $UpdateBranch = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\OfficeUpdate' -ErrorAction SilentlyContinue).UpdateBranch
    if ($UpdateBranch)
    {
        $OfficeChannel = $Channels | Where-Object { $_.GPO -eq $UpdateBranch }
        Write-CMTraceLog "Update channel from GPO: $($UpdateBranch): $($OfficeChannel.Name)"
    }
    else
    {
        $CDNBaseUrl = (Get-ItemProperty -Path $ConfigPath -ErrorAction SilentlyContinue).CDNBaseUrl
        if ($CDNBaseUrl)
        {
            try
            {
                $Uri = [System.Uri]$CDNBaseUrl
                $Guid = $Uri.Segments[2].TrimEnd('/')
                $OfficeChannel = $Channels | Where-Object { $_.GUID -eq $Guid }
                Write-CMTraceLog "Update channel from CDN GUID: $Guid → $($OfficeChannel.Name)"
            }
            catch
            {
                Write-CMTraceLog "Failed to parse CDNBaseUrl for channel"
            }
        }
    }

    $ChannelPathMap = @{
        'Monthly'               = 'Monthly'
        'Monthly (Preview)'     = 'MonthlyPreview'
        'Monthly Enterprise'    = 'MonthlyEnterpriseChannel'
        'Semi-Annual'           = 'SAC'
        'Semi-Annual (Preview)' = 'SACT'
        'Beta'                  = 'Beta'
    }

    if ($OfficeProductIds -like '*2019Volume*')
    {
        $CDNChannel = 'LTSB'
        Write-CMTraceLog "Legacy Office 2019 detected"
    }
    elseif ($OfficeProductIds -like '*2021Volume*')
    {
        $CDNChannel = 'LTSB2021'
        Write-CMTraceLog "Legacy Office 2021 detected"
    }
    else
    {
        if ($OfficeChannel -and $OfficeChannel.Name)
        {
            $CDNChannel = $ChannelPathMap[$OfficeChannel.Name]
        }
        else
        {
            $CDNChannel = $null
            Write-CMTraceLog "Could not determine the Office update channel (no matching GPO/CDN channel); leaving it blank." -WarningMsg
        }
    }

    Write-CMTraceLog "CDN channel path: $CDNChannel"


    ### Defaults
    $LatestReleaseType = $null
    $LatestReleaseVersion = $null
    $EndOfSupportDate = $null
    $ReleaseDate = $null
    $ReleaseID = $null

    Write-CMTraceLog "Get-Microsoft365: Querying C2R release data API..."
    try
    {
        $C2RData = Invoke-RestMethod -Uri 'https://mrodevicemgr.officeapps.live.com/mrodevicemgrsvc/api/v2/C2RReleaseData' -Method GET -ErrorAction Stop
        Write-CMTraceLog "Get-Microsoft365: C2R API returned $($C2RData.Count) release entries"
        $ReleaseMatch = $C2RData | Where-Object { $_.availableBuild -eq $OfficeVersionString }


        if (-not $ReleaseMatch)
        {
            $ReleaseMatch = $C2RData |
                Where-Object { $_.availableBuild -like "$($OfficeVersion.Major).$($OfficeVersion.Minor).*" } |
                Sort-Object availableBuild -Descending |
                Select-Object -First 1
            Write-CMTraceLog "Fuzzy match used for release data"
        }

        # If ReleaseMatch is an array, pick the first match
        if ($ReleaseMatch -is [array])
        {
            Write-CMTraceLog "`n=== Raw C2R Match Array ==="
            $jsonOutput = $ReleaseMatch | ConvertTo-Json -Depth 5
            Write-CMTraceLog $jsonOutput
            Write-CMTraceLog "=== End Raw C2R Match Array ===`n"

            if ($ReleaseMatch.Count -gt 0)
            {
                Write-CMTraceLog "Multiple matches found. Using first: $($ReleaseMatch[0].availableBuild)"
                $ReleaseMatch = $ReleaseMatch[0]
            }
            else
            {
                Write-CMTraceLog "ReleaseMatch was empty array"
                $ReleaseMatch = $null
            }
        }

        if ($ReleaseMatch)
        {
            Write-CMTraceLog "`n=== Raw Single C2R Match ==="
            $jsonOutput = $ReleaseMatch | ConvertTo-Json -Depth 5
            Write-CMTraceLog $jsonOutput
            Write-CMTraceLog "=== End Raw C2R Match ===`n"
            Write-CMTraceLog "C2R Match found: $($ReleaseMatch.availableBuild)"

            $LatestReleaseVersion = "$($ReleaseMatch.availableBuild)"
            $LatestReleaseType = "$($ReleaseMatch.type)"
            $ReleaseDate = "$($ReleaseMatch.updatedTimeUtc)"
            $ReleaseID = ($ReleaseMatch.forkName -split '-')[0]

            if ($ReleaseMatch.endOfSupportDate -and $ReleaseMatch.endOfSupportDate -ne '0001-01-01T00:00:00Z')
            {
                $EndOfSupportDate = "$($ReleaseMatch.endOfSupportDate)"
            }
            else
            {
                Write-CMTraceLog "EndOfSupportDate not found in C2R fallback needed"
            }
        }
        else
        {
            Write-CMTraceLog "No C2R match found"
        }
    }
    catch
    {
        Write-CMTraceLog "C2R API failed: $_" -WarningMsg
    }


    if ($CDNChannel)
    {
        Write-CMTraceLog "Get-Microsoft365: Querying Office releases API for channel $CDNChannel..."
        try
        {
            # The per-channel endpoint (releases/v1.0/LatestRelease/<channel>) was retired by Microsoft.
            # OfficeReleases returns every channel in one array; select ours and read the newest build.
            $CDNUrl = "https://clients.config.office.net/releases/v1.0/OfficeReleases"
            Write-CMTraceLog "Get-Microsoft365: Calling $CDNUrl"
            $CDNResp = Invoke-RestMethod -Uri $CDNUrl -Method GET -ErrorAction Stop

            $CDNChan = $CDNResp | Where-Object {
                $_.channelId -eq $CDNChannel -or $_.channel -eq $CDNChannel -or ($_.alternateNames -contains $CDNChannel)
            } | Select-Object -First 1
            $CDNRel = $CDNChan.officeVersions | Select-Object -First 1

            if ($CDNChan)
            {
                if (-not $EndOfSupportDate -and $CDNRel.endOfSupportDate -and $CDNRel.endOfSupportDate -ne '0001-01-01T00:00:00Z')
                {
                    $EndOfSupportDate = $CDNRel.endOfSupportDate
                    Write-CMTraceLog "EndOfSupportDate pulled from CDN: $EndOfSupportDate"
                }
                if (-not $ReleaseDate -and $CDNRel.availabilityDate)
                {
                    $ReleaseDate = $CDNRel.availabilityDate
                    Write-CMTraceLog "ReleaseDate pulled from CDN"
                }
                if (-not $LatestReleaseVersion -and $CDNChan.latestVersion)
                {
                    $LatestReleaseVersion = $CDNChan.latestVersion
                    Write-CMTraceLog "ReleaseVersion pulled from CDN"
                }
                if (-not $ReleaseID -and $CDNRel.releaseVersion)
                {
                    $ReleaseID = $CDNRel.releaseVersion
                    Write-CMTraceLog "ReleaseID pulled from CDN"
                }
            }
            else
            {
                Write-CMTraceLog "Get-Microsoft365: No matching channel '$CDNChannel' in OfficeReleases response" -WarningMsg
            }
        }
        catch
        {
            Write-CMTraceLog "Get-Microsoft365: CDN API failed: $_" -WarningMsg
        }
    }
    else
    {
        Write-CMTraceLog "Get-Microsoft365: CDN channel is null or empty, skipping CDN API call"
    }

    Write-CMTraceLog "Get-Microsoft365: FINAL: Installed=$OfficeVersionString | Channel=$($OfficeChannel.Name) | Release=$LatestReleaseVersion | Type=$LatestReleaseType | EoS=$EndOfSupportDate"

    return [pscustomobject]@{
        InstalledVersion     = $OfficeVersionString
        UpdateChannel        = $OfficeChannel.Name
        LatestReleaseType    = $LatestReleaseType
        LatestReleaseVersion = $LatestReleaseVersion
        EndOfSupportDate     = $EndOfSupportDate
        ReleaseDate          = $ReleaseDate
        ReleaseID            = $ReleaseID
    }
}

# Function to get Installed Drivers
<#
Feel free to edit the query collect more or less drivers. - PJM
#>
# Function to get Installed Drivers
function Get-InstalledDrivers()
{
    Write-CMTraceLog "Get-InstalledDrivers: Starting driver inventory collection..."

    # Get PnP signed drivers
    Write-CMTraceLog "Get-InstalledDrivers: Retrieving PnP signed drivers from WMI..."
    try
    {
        $PNPSigned_Drivers = Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop | Where-Object {
            ($_.Manufacturer -ne "Microsoft") -and
            ($_.DriverProviderName -ne "Microsoft") -and
            ($_.DeviceName -ne $null)
        } | Select-Object DeviceName, DriverVersion, DriverDate, DeviceClass, DeviceID, HardwareID, Manufacturer, InfName, Location, Description, DriverProviderName
        Write-CMTraceLog "Get-InstalledDrivers: Retrieved $($PNPSigned_Drivers.Count) PnP signed drivers (non-Microsoft)"
    }
    catch
    {
        Write-CMTraceLog "Get-InstalledDrivers: Error retrieving PnP signed drivers: $($_.Exception.Message)" -ErrorMsg
        $PNPSigned_Drivers = @()
    }

    if ($MatchDrivers)
    {
        # Get installed MSU packages
        Write-CMTraceLog "Get-InstalledDrivers: Retrieving installed MSU driver packages..."
        try
        {
            $InstalledDrivers = Get-Package -ProviderName msu -ErrorAction Stop | Where-Object {
                $_.Metadata.Item("SupportUrl") -match "target=hub"
            }
            Write-CMTraceLog "Get-InstalledDrivers: Retrieved $($InstalledDrivers.Count) installed MSU driver packages"
        }
        catch
        {
            Write-CMTraceLog "Get-InstalledDrivers: Error retrieving MSU packages: $($_.Exception.Message)" -WarningMsg
            $InstalledDrivers = @()
        }

        # Get optional updates
        Write-CMTraceLog "Get-InstalledDrivers: Searching for optional driver updates via Windows Update..."
        try
        {
            $updateSession = New-Object -ComObject Microsoft.Update.Session
            $updateSearcher = $updateSession.CreateUpdateSearcher()
            Write-CMTraceLog "Get-InstalledDrivers: Windows Update session created, searching for uninstalled drivers..."
            $searchResult = $updateSearcher.Search("IsInstalled=0 AND Type='Driver'")
            Write-CMTraceLog "Get-InstalledDrivers: Windows Update search completed, found $($searchResult.Updates.Count) optional drivers"
        }
        catch
        {
            Write-CMTraceLog "Get-InstalledDrivers: Error searching Windows Update for optional drivers: $($_.Exception.Message)" -WarningMsg
            $searchResult = $null
        }
        $OptionalWUList = @()
        if ($searchResult -and $searchResult.Updates.Count -gt 0)
        {
            Write-CMTraceLog "Get-InstalledDrivers: Processing $($searchResult.Updates.Count) optional driver updates..."
            for ($i = 0; $i -lt $searchResult.Updates.Count; $i++)
            {
                $update = $searchResult.Updates.Item($i)
                $OptionalWUList += [PSCustomObject]@{
                    WUName             = $update.Title
                    DriverName         = $update.DriverModel
                    DriverVersion      = $null
                    DriverReleaseDate  = if ($update.DriverVerDate)
                    {
                        $update.DriverVerDate.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
                    }
                    else
                    {
                        $null
                    }
                    DriverClass        = $update.DriverClass.ToUpper()
                    DriverID           = $null
                    DriverHardwareID   = $update.DriverHardwareID
                    DriverManufacturer = $update.DriverManufacturer
                    DriverInfName      = $null
                    DriverLocation     = $null
                    DriverDescription  = $update.Description
                    DriverProvider     = $update.DriverProvider
                    DriverPublishedOn  = $update.LastDeploymentChangeTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
                    DriverStatus       = "Optional"
                }
            }
            Write-CMTraceLog "Get-InstalledDrivers: Created $($OptionalWUList.Count) optional driver entries"
        }
        else
        {
            Write-CMTraceLog "Get-InstalledDrivers: No optional driver updates found"
        }

        # Link installed drivers
        Write-CMTraceLog "Get-InstalledDrivers: Linking installed MSU packages with PnP drivers..."
        $LinkedDrivers = foreach ($installedDriver in $InstalledDrivers)
        {
            $versionFromName = $installedDriver.Name.Split()[-1]
            $matchingDriver = $PNPSigned_Drivers | Where-Object {
                $_.DriverVersion -eq $versionFromName
            } | Select-Object -First 1

            if ($matchingDriver)
            {
                [PSCustomObject]@{
                    WUName             = $installedDriver.Name
                    DriverName         = $matchingDriver.DeviceName
                    DriverVersion      = $matchingDriver.DriverVersion
                    DriverReleaseDate  = if ($matchingDriver.DriverDate)
                    {
                        $matchingDriver.DriverDate.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
                    }
                    else
                    {
                        $null
                    }
                    DriverClass        = $matchingDriver.DeviceClass
                    DriverID           = $matchingDriver.DeviceID
                    DriverHardwareID   = $matchingDriver.HardwareID
                    DriverManufacturer = $matchingDriver.Manufacturer
                    DriverInfName      = $matchingDriver.InfName
                    DriverLocation     = $matchingDriver.Location
                    DriverDescription  = $matchingDriver.Description
                    DriverProvider     = $matchingDriver.DriverProviderName
                    DriverPublishedOn  = $null
                    DriverStatus       = "Installed"
                }
            }
        }
        Write-CMTraceLog "Get-InstalledDrivers: Linked $($LinkedDrivers.Count) MSU packages to PnP drivers"
    }

    # Add unmatched installed drivers
    Write-CMTraceLog "Get-InstalledDrivers: Finding unmatched PnP drivers..."
    $matchedVersions = $LinkedDrivers | Where-Object { $_.DriverVersion } | Select-Object -ExpandProperty DriverVersion
    $unmatchedDrivers = $PNPSigned_Drivers | Where-Object { $matchedVersions -notcontains $_.DriverVersion }
    Write-CMTraceLog "Get-InstalledDrivers: Found $($unmatchedDrivers.Count) unmatched PnP drivers"

    # Combine both sets of drivers using the same foreach pattern
    Write-CMTraceLog "Get-InstalledDrivers: Combining linked and unmatched drivers..."
    $LinkedDrivers = @(
        $LinkedDrivers  # Include existing linked drivers
        foreach ($driver in $unmatchedDrivers)
        {
            [PSCustomObject]@{
                WUName             = $null
                DriverName         = $driver.DeviceName
                DriverVersion      = $driver.DriverVersion
                DriverReleaseDate  = if ($driver.DriverDate)
                {
                    $driver.DriverDate.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
                }
                else
                {
                    $null
                }
                DriverClass        = $driver.DeviceClass
                DriverID           = $driver.DeviceID
                DriverHardwareID   = $driver.HardwareID
                DriverManufacturer = $driver.Manufacturer
                DriverInfName      = $driver.InfName
                DriverLocation     = $driver.Location
                DriverDescription  = $driver.Description
                DriverProvider     = $driver.DriverProviderName
                DriverPublishedOn  = $null
                DriverStatus       = "Installed"
            }
        }
    )
    Write-CMTraceLog "Get-InstalledDrivers: Combined driver list now contains $($LinkedDrivers.Count) entries"

    # Add optional updates to the list
    Write-CMTraceLog "Get-InstalledDrivers: Adding optional driver updates to final list..."
    foreach ($optionalDriver in $OptionalWUList)
    {
        $LinkedDrivers += [PSCustomObject]@{
            WUName             = $optionalDriver.WUName
            DriverName         = $optionalDriver.DriverName
            DriverVersion      = $optionalDriver.DriverVersion
            DriverReleaseDate  = $optionalDriver.DriverDate
            DriverClass        = $optionalDriver.DeviceClass
            DriverID           = $optionalDriver.DeviceID
            DriverHardwareID   = $optionalDriver.DriverHardwareID
            DriverManufacturer = $optionalDriver.Manufacturer
            DriverInfName      = $optionalDriver.InfName
            DriverLocation     = $optionalDriver.Location
            DriverDescription  = $optionalDriver.Description
            DriverProvider     = $optionalDriver.DriverProvider
            DriverPublishedOn  = $optionalDriver.DriverChangeTime
            DriverStatus       = $optionalDriver.DriverStatus
        }
    }

    Write-CMTraceLog "Get-InstalledDrivers: Completed, returning $($LinkedDrivers.Count) total driver entries"
    return $LinkedDrivers
}


# Function to get Dell Warranty
function Get-DellWarranty(
    <#
.SYNOPSIS
    Retrieves Dell warranty information using the Dell Warranty API.
.DESCRIPTION
    Authenticates with Dell’s API using provided credentials, retrieves warranty details for the specified device, and returns warranty information as a custom object.
.PARAMETER SourceDevice
    The Dell service tag (serial number) of the device.
.OUTPUTS
    PSCustomObject with Dell warranty details.
#>
    [Parameter(Mandatory = $true)]$SourceDevice)
{
    $AuthURI = "https://apigtwb2c.us.dell.com/auth/oauth/v2/token"

    try
    {
        Write-CMTraceLog "[$SourceDevice] Checking Dell OAuth token validity..."
        if ($Global:TokenAge -lt (Get-Date).AddMinutes(-55))
        {
            Write-CMTraceLog "[$SourceDevice] Token expired or missing. Clearing existing token..."
            $global:Token = $null
        }

        if ($null -eq $global:Token)
        {
            Write-CMTraceLog "[$SourceDevice] Requesting new Dell OAuth token..."
            $OAuth = "$WarrantyDellClientID`:$WarrantyDellClientSecret"
            $Bytes = [System.Text.Encoding]::ASCII.GetBytes($OAuth)
            $EncodedOAuth = [Convert]::ToBase64String($Bytes)
            $headersAuth = @{ "authorization" = "Basic $EncodedOAuth" }
            $Authbody = 'grant_type=client_credentials'

            try
            {
                $AuthResult = Invoke-RestMethod -Method Post -Uri $AuthURI -Body $AuthBody -Headers $HeadersAuth -ErrorAction Stop
                $global:token = $AuthResult.access_token
                $Global:TokenAge = Get-Date
                Write-CMTraceLog "[$SourceDevice] Dell token acquired successfully."
            }
            catch
            {
                Write-CMTraceLog "[$SourceDevice] Error acquiring Dell OAuth token: $($_.Exception.Message)" -ErrorMsg
                throw
            }
        }

        Write-CMTraceLog "[$SourceDevice] Submitting Dell warranty request..."
        $headersReq = @{ "Authorization" = "Bearer $global:Token" }
        $ReqBody = @{ servicetags = $SourceDevice }

        try
        {
            $WarReq = Invoke-RestMethod -Uri "https://apigtwb2c.us.dell.com/PROD/sbil/eapi/v5/asset-entitlements" -Headers $headersReq -Body $ReqBody -Method Get -ContentType "application/json" -ErrorAction Stop
        }
        catch
        {
            Write-CMTraceLog "[$SourceDevice] Error calling Dell warranty API: $($_.Exception.Message)" -ErrorMsg
            throw
        }

        if ($WarReq.entitlements.serviceleveldescription)
        {
            Write-CMTraceLog "[$SourceDevice] Warranty data received from Dell."

            $WarObj = [PSCustomObject]@{
                'ServiceProvider'         = 'Dell'
                'ServiceModel'            = $WarReq.productLineDescription
                'ServiceTag'              = $SourceDevice
                'ServiceLevelDescription' = $WarReq.entitlements.serviceleveldescription -join "`n"
                'WarrantyStartDate'       = ($WarReq.entitlements.startdate | Sort-Object -Descending | Select-Object -Last 1)
                'WarrantyEndDate'         = ($WarReq.entitlements.enddate | Sort-Object | Select-Object -Last 1)
            }
        }
        else
        {
            Write-CMTraceLog "[$SourceDevice] No service level description returned by Dell."
            $WarObj = [PSCustomObject]@{
                'ServiceProvider'         = 'Dell'
                'ServiceModel'            = $null
                'ServiceTag'              = $SourceDevice
                'ServiceLevelDescription' = 'Could not get warranty information'
                'WarrantyStartDate'       = $null
                'WarrantyEndDate'         = $null
            }
        }
    }
    catch
    {
        Write-CMTraceLog "[$SourceDevice] ERROR during Dell warranty lookup: $($_.Exception.Message)"
        $WarObj = [PSCustomObject]@{
            'ServiceProvider'         = 'Dell'
            'ServiceModel'            = $null
            'ServiceTag'              = $SourceDevice
            'ServiceLevelDescription' = 'Could not get warranty information'
            'WarrantyStartDate'       = $null
            'WarrantyEndDate'         = $null
        }
    }

    return $WarObj
}



# Function to get Lenovo Warranty
function Get-LenovoWarranty(
    <#
.SYNOPSIS
    Retrieves Lenovo warranty information using the Lenovo Warranty API.
.DESCRIPTION
    Queries Lenovo’s API using the provided client ID and device serial number, returning warranty details as a custom object.
.PARAMETER SourceDevice
    The Lenovo serial number of the device.
.OUTPUTS
    PSCustomObject with Lenovo warranty details.
#>
    [Parameter(Mandatory = $true)]$SourceDevice)
{
    $headersReq = @{ "ClientID" = $WarrantyLenovoClientID }
    $WarReq = Invoke-RestMethod -Uri "https://supportapi.lenovo.com/V2.5/Warranty?Serial=$SourceDevice" -Headers $headersReq -Method Get -ContentType "application/json"

    try
    {
        $Warlist = $WarReq.Warranty | Where-Object { ($_.ID -eq "36Y") -or ($_.ID -eq "3EZ") -or ($_.ID -eq "12B") -or ($_.ID -eq "1EZ") }
        $WarObj = [PSCustomObject]@{
            'ServiceProvider'         = 'Lenovo'
            'ServiceModel'            = $WarReq.Product
            'ServiceTag'              = $SourceDevice
            'ServiceLevelDescription' = $Warlist.Name -join "`n"
            'WarrantyStartDate'       = ($Warlist.Start | Sort-Object -Descending | Select-Object -Last 1)
            'WarrantyEndDate'         = ($Warlist.End | Sort-Object | Select-Object -Last 1)
        }

    }
    catch
    {
        $WarObj = [PSCustomObject]@{
            'ServiceProvider'         = 'Lenovo'
            'ServiceModel'            = $null
            'ServiceTag'              = $SourceDevice
            'ServiceLevelDescription' = 'Could not get warranty information'
            'WarrantyStartDate'       = $null
            'WarrantyEndDate'         = $null
        }
    }
    return $WarObj
}

# Function to get Getac Warranty
function Get-GetacWarranty(
    <#
.SYNOPSIS
    Retrieves Getac warranty information using the Getac API.
.DESCRIPTION
    Queries Getac’s API with the device serial number and returns warranty details as a custom object.
.PARAMETER SourceDevice
    The Getac serial number of the device.
.OUTPUTS
    PSCustomObject with Getac warranty details.
#>
    [Parameter(Mandatory = $true)]$SourceDevice)
{
    $WarReq = Invoke-RestMethod -Uri https://api.getac.us/rma-manager/rma/verify-serial?serial=$SerialNumber -Method Get -ContentType "application/json"
    try
    {
        $WarObj = [PSCustomObject]@{
            'ServiceProvider'         = 'Getac'
            'ServiceModel'            = $WarReq.model
            'ServiceTag'              = $SourceDevice
            'ServiceLevelDescription' = $WarReq.warrantyType
            'WarrantyStartDate'       = $null
            'WarrantyEndDate'         = ($warreq.endDeviceWarranty | Sort-Object | Select-Object -Last 1)
        }
    }
    catch
    {
        $WarObj = [PSCustomObject]@{
            'ServiceProvider'         = 'Getac'
            'ServiceModel'            = $null
            'ServiceTag'              = $SourceDevice
            'ServiceLevelDescription' = 'Could not get warranty information'
            'WarrantyStartDate'       = $null
            'WarrantyEndDate'         = $null
        }
    }
    return $WarObj
}

# Function to acquire an HP Warranty API access token
function Get-HPWarrantyToken
{
    <#
.SYNOPSIS
    Acquires an OAuth (client-credentials) access token for the HP Warranty API.
.DESCRIPTION
    Returns a fresh bearer token. Called for the initial request and again
    whenever a long-running batch job outlives the current token and the API
    rejects it with HTTP 401.
.OUTPUTS
    String access token.
#>
    $b64EncodedCred = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$WarrantyHPClientID`:$WarrantyHPClientSecret"))
    $tokenHeaders = @{
        accept        = "application/json"
        authorization = "Basic $b64EncodedCred"
    }
    $authResponse = Invoke-WebRequest -UseBasicParsing -Method POST -Uri "https://warranty.api.hp.com/oauth/v1/token" -Headers $tokenHeaders -Body "grant_type=client_credentials" -ContentType "application/x-www-form-urlencoded"
    return ($authResponse | ConvertFrom-Json).access_token
}

# Function to GET an HP Warranty API endpoint with automatic token refresh
function Invoke-HPWarrantyGet
{
    <#
.SYNOPSIS
    Performs a GET against the HP Warranty API, refreshing the token on a 401.
.DESCRIPTION
    HP batch jobs can run longer than an access token stays valid. If the token
    is rejected (HTTP 401) this requests a new one, updates the caller's token
    (passed by [ref]) in place, and retries the request once.
.PARAMETER Uri
    The HP Warranty API URL to GET.
.PARAMETER AccessToken
    A [ref] to the caller's current access-token string, replaced in place when
    the token is refreshed so the caller keeps using the new one.
.PARAMETER SourceDevice
    The serial number, for log context.
.OUTPUTS
    The Invoke-WebRequest response.
#>
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][ref]$AccessToken,
        [Parameter(Mandatory = $true)][string]$SourceDevice
    )

    $headers = @{ accept = "application/json"; authorization = "Bearer $($AccessToken.Value)" }
    try
    {
        return Invoke-WebRequest -UseBasicParsing -Method GET -Uri $Uri -Headers $headers
    }
    catch
    {
        $statusCode = $null
        if ($_.Exception.Response)
        {
            try
            {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            catch
            {
            }
        }

        if ($statusCode -eq 401)
        {
            Write-CMTraceLog "[$SourceDevice] HP token expired or invalid (401). Requesting a new token and retrying..."
            $AccessToken.Value = Get-HPWarrantyToken
            $headers = @{ accept = "application/json"; authorization = "Bearer $($AccessToken.Value)" }
            return Invoke-WebRequest -UseBasicParsing -Method GET -Uri $Uri -Headers $headers
        }
        throw
    }
}

# Function to get HP Warranty
function Get-HPWarranty(
    <#
.SYNOPSIS
    Retrieves HP warranty information using the HP Warranty API.
.DESCRIPTION
    Authenticates with HP’s API using provided credentials, submits a batch job for the device serial number, and returns warranty details as a custom object.
.PARAMETER SourceDevice
    The HP serial number of the device.
.OUTPUTS
    PSCustomObject with HP warranty details.
#>
    [Parameter(Mandatory = $true)]$SourceDevice)
{

    try
    {
        Write-CMTraceLog "[$SourceDevice] Requesting HP warranty token..."
        $accessToken = Get-HPWarrantyToken
        Write-CMTraceLog "[$SourceDevice] Successfully obtained access token."

        Write-CMTraceLog "[$SourceDevice] Submitting HP batch job..."
        $queryBody = "[{""sn"":""$SourceDevice""}]"
        $queryURI = "https://warranty.api.hp.com/productwarranty/v2/jobs"
        $submitHeaders = @{
            accept        = "application/json"
            authorization = "Bearer $accessToken"
        }

        $jobResponse = Invoke-WebRequest -UseBasicParsing -Method POST -Uri $queryURI -Headers $submitHeaders -Body $queryBody -ContentType "application/json"
        $jobData = $jobResponse | ConvertFrom-Json
        $jobId = $jobData.jobId
        $estimatedTime = $jobData.estimatedTime
        Write-CMTraceLog "[$SourceDevice] Batch job created. Job ID: $jobId. Estimated time: $estimatedTime seconds."

        $JobStatusURI = "$queryURI/$jobId"
        $JobResultsURI = "$queryURI/$jobId/results"

        # HP's API can take 5-10 minutes to finish when it is busy, longer than an
        # access token stays valid. Cap the whole job at 12 minutes, and let
        # Invoke-HPWarrantyGet request a fresh token and retry if the current one
        # is rejected (HTTP 401) partway through polling.
        $deadline = (Get-Date).AddMinutes(12)

        # Wait the estimate before the first poll, but cap the initial nap so we
        # start checking (and can refresh the token) on a sane cadence.
        $initialWait = [Math]::Min([int]$estimatedTime, 60)
        if ($initialWait -gt 0)
        {
            Start-Sleep -Seconds $initialWait
        }

        Write-CMTraceLog "[$SourceDevice] Polling job status..."

        $status = "unknown"
        do
        {
            if ((Get-Date) -gt $deadline)
            {
                throw "HP warranty job $jobId did not complete within 12 minutes (last status: $status)."
            }

            $JobStatus = Invoke-HPWarrantyGet -Uri $JobStatusURI -AccessToken ([ref]$accessToken) -SourceDevice $SourceDevice | ConvertFrom-Json
            $status = $JobStatus.status
            Write-CMTraceLog "[$SourceDevice] Job status: $status"

            if ($status -eq "error" -or $status -eq "failed")
            {
                throw "HP warranty job $jobId returned status '$status'."
            }
            if ($status -ne "completed")
            {
                Start-Sleep -Seconds 15
            }
        } while ($status -ne "completed")

        Write-CMTraceLog "[$SourceDevice] Job completed. Retrieving results..."

        $rawResults = (Invoke-HPWarrantyGet -Uri $JobResultsURI -AccessToken ([ref]$accessToken) -SourceDevice $SourceDevice).Content

        # Diagnostic copy of the raw HP payload. Out-File consumes the pipeline, so this
        # does not leak into the function's return value the way a bare expression would.
        $rawResults | Out-File -FilePath "C:\Windows\Temp\HPWarranty_Raw_$SourceDevice.json" -Encoding UTF8

        # Force an array. PowerShell 5.1 ConvertFrom-Json unrolls a JSON root array,
        # so a single-serial job returns a bare PSCustomObject and $result[0] is null.
        $result = @($rawResults | ConvertFrom-Json)

        if ($result.Count -eq 0)
        {
            Write-CMTraceLog "[$SourceDevice] No data returned in results array."
            throw "Empty results"
        }

        $deviceData = $result[0]

        # HP returns an error node per serial rather than failing the job. Surface it.
        if ($deviceData.error)
        {
            Write-CMTraceLog "[$SourceDevice] HP returned an error for this serial: $($deviceData.error | ConvertTo-Json -Compress)"
        }
        $product = $deviceData.product
        $offers = $deviceData.offers

        if ($offers)
        {
            Write-CMTraceLog "[$SourceDevice] Warranty data retrieved successfully."

            $serviceDescriptions = $offers | ForEach-Object {
                "$($_.offerDescription) ($($_.serviceObligationLineItemStartDate) to $($_.serviceObligationLineItemEndDate))"
            }

            $startDate = ($offers.serviceObligationLineItemStartDate | Sort-Object -Descending | Select-Object -First 1)
            $endDate = ($offers.serviceObligationLineItemEndDate | Sort-Object | Select-Object -Last 1)

            $WarObj = [PSCustomObject]@{
                'ServiceProvider'         = 'HP'
                'ServiceModel'            = $product.productDescription
                'ServiceTag'              = $SourceDevice
                'ServiceLevelDescription' = $serviceDescriptions -join "`n"
                'WarrantyStartDate'       = $startDate
                'WarrantyEndDate'         = $endDate
            }
        }
        else
        {
            Write-CMTraceLog "[$SourceDevice] No offers found in response."
            $WarObj = [PSCustomObject]@{
                'ServiceProvider'         = 'HP'
                'ServiceModel'            = $product.productDescription
                'ServiceTag'              = $SourceDevice
                'ServiceLevelDescription' = 'No warranty offers returned'
                'WarrantyStartDate'       = $null
                'WarrantyEndDate'         = $null
            }
        }
    }
    catch
    {
        Write-CMTraceLog "[$SourceDevice] ERROR during HP warranty lookup: $($_.Exception.Message)"
        $WarObj = [PSCustomObject]@{
            'ServiceProvider'         = 'HP'
            'ServiceModel'            = $null
            'ServiceTag'              = $SourceDevice
            'ServiceLevelDescription' = 'Could not get warranty information'
            'WarrantyStartDate'       = $null
            'WarrantyEndDate'         = $null
        }
    }

    return $WarObj
}


# Unified Warranty Retriever
function Get-Warranty
{
    <#
.SYNOPSIS
    Retrieves and caches warranty information for a device from the appropriate vendor API.
.DESCRIPTION
    Determines manufacturer, checks for cached warranty data, and if necessary, queries the correct API for warranty details. Supports Dell, Lenovo, HP, and Getac.
.PARAMETER SerialNumber
    The device serial number.
.PARAMETER Manufacturer
    The device manufacturer.
.OUTPUTS
    PSCustomObject with warranty details.
#>
    param(
        [Parameter(Mandatory = $true)][string]$SerialNumber,
        [Parameter(Mandatory = $true)][string]$Manufacturer
    )
    $CachePath = "C:\Windows\Warranty_$SerialNumber.json"
    try
    {
        if (-not $WarrantyForceRefresh -and (Test-Path $CachePath))
        {
            $fileAge = (Get-Date) - (Get-Item $CachePath).LastWriteTime
            if ($fileAge.TotalDays -le $WarrantyMaxCacheAgeDays)
            {
                Write-CMTraceLog "[$SerialNumber] Using cached warranty data from $CachePath"
                Write-CMTraceLog "[$SerialNumber] Skipping API call, using saved JSON."
                $cached = Get-Content $CachePath -Raw | ConvertFrom-Json
                $cached.WarrantyStartDate = [datetime]$cached.WarrantyStartDate
                $cached.WarrantyEndDate = [datetime]$cached.WarrantyEndDate
                return $cached
            }
            else
            {
                Write-CMTraceLog "[$SerialNumber] Cache expired ($([math]::Round($fileAge.TotalDays,1)) days old). Refreshing..."
            }
        }
    }
    catch
    {
        Write-CMTraceLog "[$SerialNumber] Exception during cache read: $($_.Exception.Message)"
    }
    $normalizedMake = ($Manufacturer -replace '\s+', ' ').Trim().ToUpper()
    Write-CMTraceLog "Entering warranty switch block with: [$normalizedMake]"
    $WarrantyData = $null
    switch -Regex ($normalizedMake)
    {
        "^DELL"
        {
            $WarrantyData = Get-DellWarranty -SourceDevice $SerialNumber; break
        }
        "^LENOVO|^IBM"
        {
            $WarrantyData = Get-LenovoWarranty -SourceDevice $SerialNumber; break
        }
        "^INSYDE"
        {
            $WarrantyData = Get-GetacWarranty -SourceDevice $SerialNumber; break
        }
        "^HP"
        {
            $WarrantyData = Get-HPWarranty -SourceDevice $SerialNumber; break
        }
        default
        {
            Write-CMTraceLog "[$SerialNumber] Manufacturer '$Manufacturer' not supported for warranty lookup."
        }
    }
    if ($WarrantyData)
    {
        $WarrantyData | ConvertTo-Json -Depth 5 | Out-File -FilePath $CachePath -Encoding UTF8
        Write-CMTraceLog "[$SerialNumber] Warranty data cached at $CachePath"
        return $WarrantyData
    }
    return $null
}


# Function to create the authorization signature
function New-Signature (
    # Function to create the authorization signature
    <#
.SYNOPSIS
    Creates an authorization signature for Azure Log Analytics API.
.DESCRIPTION
    Generates a SharedKey signature for authenticating requests to Azure Log Analytics.
.PARAMETER customerId
    The Log Analytics Workspace ID.
.PARAMETER sharedKey
    The Log Analytics Primary Key.
.PARAMETER date
    The RFC1123 date string.
.PARAMETER contentLength
    The length of the request body.
.PARAMETER method
    The HTTP method (e.g., POST).
.PARAMETER contentType
    The content type (e.g., application/json).
.PARAMETER resource
    The API resource path.
.OUTPUTS
    String containing the authorization header value.
#>
    $customerId, $sharedKey, $date, $contentLength, $method, $contentType, $resource)
{
    $xHeaders = "x-ms-date:" + $date
    $stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource

    $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
    $keyBytes = [Convert]::FromBase64String($sharedKey)

    $sha256 = New-Object System.Security.Cryptography.HMACSHA256
    $sha256.Key = $keyBytes
    $calculatedHash = $sha256.ComputeHash($bytesToHash)
    $encodedHash = [Convert]::ToBase64String($calculatedHash)
    $authorization = 'SharedKey {0}:{1}' -f $customerId, $encodedHash
    return $authorization
}

# Function to create and post the request
function Send-LogAnalyticsData(
    <#
    .SYNOPSIS
    Sends data to Azure Log Analytics.
    .DESCRIPTION
    Compresses and uploads JSON data to Azure Log Analytics using the provided credentials and log type.
    .PARAMETER customerId
    The Log Analytics Workspace ID.
    .PARAMETER sharedKey
    The Log Analytics Primary Key.
    .PARAMETER body
    The request body (JSON, as bytes).
    .PARAMETER logType
    The custom log type name.
    .OUTPUTS
    String with the HTTP status code and payload size.
    #>
    $customerId, $sharedKey, $body, $logType)
{
    $method = "POST"
    $contentType = "application/json"
    $resource = "/api/logs"
    $rfc1123date = [DateTime]::UtcNow.ToString("r")
    $contentLength = $body.Length
    $signature = New-Signature `
        -customerId $customerId `
        -sharedKey $sharedKey `
        -date $rfc1123date `
        -contentLength $contentLength `
        -method $method `
        -contentType $contentType `
        -resource $resource
    $uri = "https://" + $customerId + ".ods.opinsights.azure.com" + $resource + "?api-version=2016-04-01"

    #validate that payload data does not exceed limits
    if ($body.Length -gt (31.9 * 1024 * 1024))
    {
        throw("Upload payload is too big and exceed the 32Mb limit for a single upload. Please reduce the payload size. Current payload size is: " + ($body.Length / 1024 / 1024).ToString("#.#") + "Mb")
    }

    $payloadsize = ("Upload payload size is " + ($body.Length / 1024).ToString("#.#") + "Kb ")

    $headers = @{
        "Authorization"        = $signature;
        "Log-Type"             = $logType;
        "x-ms-date"            = $rfc1123date;
        "time-generated-field" = $TimeStampField;
    }

    $response = Invoke-WebRequest -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $body -UseBasicParsing
    $statusmessage = "$($response.StatusCode) : $($payloadsize)"
    return $statusmessage
}

# Function to create and post the request using DataCollectorAPI
function Send-DataCollectorAPI(
    <#
    .SYNOPSIS
    Sends data to Azure Log Analytics.
    .DESCRIPTION
    Compresses and uploads JSON data to Azure Log Analytics using the provided credentials and log type.
    .PARAMETER customerId
    The Log Analytics Workspace ID.
    .PARAMETER sharedKey
    The Log Analytics Primary Key.
    .PARAMETER body
    The request body (JSON, as bytes).
    .PARAMETER logType
    The custom log type name.
    .OUTPUTS
    String with the HTTP status code and payload size.
    #>
    $customerId, $sharedKey, $body, $logType)
{
    $method = "POST"
    $contentType = "application/json"
    $resource = "/api/logs"
    $rfc1123date = [DateTime]::UtcNow.ToString("r")
    $contentLength = $body.Length
    $signature = New-Signature `
        -customerId $customerId `
        -sharedKey $sharedKey `
        -date $rfc1123date `
        -contentLength $contentLength `
        -method $method `
        -contentType $contentType `
        -resource $resource
    $uri = "https://" + $customerId + ".ods.opinsights.azure.com" + $resource + "?api-version=2016-04-01"

    #validate that payload data does not exceed limits
    if ($body.Length -gt (31.9 * 1024 * 1024))
    {
        throw("Upload payload is too big and exceed the 32Mb limit for a single upload. Please reduce the payload size. Current payload size is: " + ($body.Length / 1024 / 1024).ToString("#.#") + "Mb")
    }

    $payloadsize = ("Upload payload size is " + ($body.Length / 1024).ToString("#.#") + "Kb ")

    $headers = @{
        "Authorization"        = $signature;
        "Log-Type"             = $logType;
        "x-ms-date"            = $rfc1123date;
        "time-generated-field" = $TimeStampField;
    }

    $response = Invoke-WebRequest -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $body -UseBasicParsing
    $statusmessage = "$($response.StatusCode) : $($payloadsize)"
    return $statusmessage
}
# Function to create the bearer token
function New-BearerToken(
    # Function to create the Bearer Token
    <#
.SYNOPSIS
    Creates a bearer token for Azure Log Ingestion API.
.DESCRIPTION
    Generates a bearer token for authenticating requests to Azure Log Analytics.
.PARAMETER tenantId
    The tenant ID in which the Data Collection Endpoint resides
.PARAMETER clientId
    The client ID created and granted permissions
.PARAMETER clientSecret
    The secret created for the above client
.OUTPUTS
    String containing the bearer token value.
#>
    $tenantId, $clientId, $clientSecret)
{
    $scope = [System.Web.HttpUtility]::UrlEncode("https://monitor.azure.com//.default")
    $body = "client_id=$clientId&scope=$scope&client_secret=$clientSecret&grant_type=client_credentials"
    $headers = @{"Content-Type" = "application/x-www-form-urlencoded" }
    $uri = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
    $bearerToken = (Invoke-RestMethod -Uri $uri -Method "Post" -Body $body -Headers $headers).access_token

    return $bearerToken
}

# Posts a submission with DCR-pool failover and exponential-backoff retry. $Uris is one
# or more equivalent targets (a pool of DCRs for the classic path, or the single Function
# URL). Each cycle tries every target once with no wait, so a single throttled or failing
# DCR fails over instantly to a sibling that has its own budget; only if the whole pool
# rejects the submission does it back off and cycle again, up to $SubmissionMaxRetries.
# Returns the response on success, or $null after exhausting retries, so a failed stream
# does not abort the run. $StartIndex spreads devices evenly across the pool.
function Invoke-LogSubmission([string[]]$Uris, $Body, [hashtable]$Headers = @{}, [int]$StartIndex = 0)
{
    # The last submission's HTTP status (the success code, or the last rejection's; $null without a
    # response), so the App Usage row sender can tell a permanent rejection from a transient one.
    $script:LastSubmissionStatusCode = $null
    $n = $Uris.Count
    if ($n -lt 1)
    {
        return $null
    }
    $lastCode = $null
    $lastMsg = ""
    $cycle = 0
    $wait = [Math]::Min($SubmissionInitialWaitSeconds, $SubmissionMaxWaitSeconds)
    while ($true)
    {
        for ($i = 0; $i -lt $n; $i++)
        {
            $uri = $Uris[($StartIndex + $cycle + $i) % $n]
            try
            {
                $submitted = Invoke-WebRequest -Uri $uri -Method "POST" -Headers $Headers -Body $Body -ContentType "application/json" -UseBasicParsing
                $script:LastSubmissionStatusCode = $submitted.StatusCode
                return $submitted
            }
            catch
            {
                $lastCode = $null
                if ($_.Exception.Response)
                {
                    try
                    {
                        $lastCode = [int]$_.Exception.Response.StatusCode
                    }
                    catch
                    {
                    }
                }
                $lastMsg = $_.Exception.Message
            }
        }
        $script:LastSubmissionStatusCode = $lastCode
        if ($cycle -ge $SubmissionMaxRetries)
        {
            Write-CMTraceLog "Submission failed after $cycle backoff cycle(s) across $n target(s) (last status: $lastCode): $lastMsg" -ErrorMsg
            return $null
        }
        $cycle++
        Write-CMTraceLog "All $n target(s) rejected the submission (last status: $lastCode). Retry $cycle of $SubmissionMaxRetries in $wait second(s)..." -WarningMsg
        Start-Sleep -Seconds $wait
        $wait = [Math]::Min($wait * 2, $SubmissionMaxWaitSeconds)
    }
}

# Function to create and post the request using LogIngestionAPI
function Send-LogIngestionAPI(
    <#
    .SYNOPSIS
    Sends data to Azure Log Analytics.
    .DESCRIPTION
    Compresses and uploads JSON data to Azure Log Analytics using the provided credentials and log type.
    .PARAMETER customerId
    The Log Analytics Workspace ID.
    .PARAMETER sharedKey
    The Log Analytics Primary Key.
    .PARAMETER body
    The request body (JSON, as bytes).
    .PARAMETER logType
    The custom log type name.
    .OUTPUTS
    String with the HTTP status code and payload size.
    #>
    $tenantId, $clientId, $clientSecret, $body, $dceURI, $dcrImmutableId, $logType)
{
    $method = "POST"
    $contentType = "application/json"

    #validate that payload data does not exceed limits (0.9 MB, the App Usage row limit; the same value
    #when the APPUSAGE region's constant isn't loaded)
    $maxBodyBytes = $script:AUMaxRowBytes
    if (-not $maxBodyBytes)
    {
        $maxBodyBytes = 943718
    }
    if ($body.Length -gt $maxBodyBytes)
    {
        throw("Upload payload is too big and exceed the 1Mb limit for a single upload. Please reduce the payload size. Current payload size is: " + ($body.Length / 1024 / 1024).ToString("#.#") + "Mb")
    }

    $payloadsize = ("Upload payload size is " + ($body.Length / 1024).ToString("#.#") + "Kb ")

    # Acquire the ingestion token. When $BrokerUrl is configured, this device authenticates to the
    # PowerStacks Entra Token Broker with its Entra Join certificate (mutual TLS) and exchanges the
    # returned assertion for the inventory managed identity's token - no secret on the device.
    # Otherwise fall back to the classic client-secret token (New-BearerToken, unchanged). The DCR
    # upload below is identical either way.
    if ($BrokerUrl -and $BrokerUrl -notmatch '^<Enter')
    {
        $cert = Get-ChildItem Cert:\LocalMachine\My |
            Where-Object { $_.Issuer -match 'CN=MS-Organization-Access' } |
            Sort-Object NotAfter -Descending | Select-Object -First 1
        if (-not $cert -or -not $cert.HasPrivateKey)
        {
            throw "Broker mode: no usable Entra Join certificate found (issuer CN=MS-Organization-Access). Run as SYSTEM/elevated on an Entra-joined device."
        }
        $assertion = (Invoke-RestMethod -Method "Post" -Uri ($BrokerUrl.TrimEnd('/') + "/token") -Certificate $cert -TimeoutSec 30).client_assertion
        if (-not $assertion)
        {
            throw "Broker did not return a client_assertion."
        }
        $tokScope = [System.Web.HttpUtility]::UrlEncode("https://monitor.azure.com//.default")
        $tokBody = "client_id=$BrokerClientId&scope=$tokScope&client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer&client_assertion=$assertion&grant_type=client_credentials"
        $tokUri = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
        $bearerToken = (Invoke-RestMethod -Uri $tokUri -Method "Post" -Body $tokBody -Headers @{ "Content-Type" = "application/x-www-form-urlencoded" }).access_token
    }
    else
    {
        $bearerToken = New-BearerToken -tenantId $tenantId -clientId $clientId -clientSecret $clientSecret
    }

    # Post straight to the DCR. Supports a pool of DCRs (scale-out): build one target URL per DCR id,
    # and spread devices across the pool with a stable per-device start index so each DCR carries a
    # roughly equal share.
    $uris = @(@($dcrImmutableId) | ForEach-Object { "$dceURI/dataCollectionRules/$_/streams/Custom-$logType" + "?api-version=2023-01-01" })
    $headers = @{ "Authorization" = "Bearer $bearerToken" }

    $startIndex = 0
    if ($ManagedDeviceID -and $uris.Count -gt 1)
    {
        $sum = 0
        foreach ($ch in $ManagedDeviceID.ToCharArray())
        {
            $sum += [int][char]$ch
        }
        $startIndex = $sum % $uris.Count
    }

    $response = Invoke-LogSubmission -Uris $uris -Body $body -Headers $headers -StartIndex $startIndex
    if ($null -eq $response)
    {
        return "DCR upload failed after retries : $payloadsize"
    }
    $statusmessage = "$($response.StatusCode) : $($payloadsize)"
    return $statusmessage
}
function Start-PowerShellSysNative
{
    <#
.SYNOPSIS
    Launches a 64-bit PowerShell process from a 32-bit process.
.DESCRIPTION
    Ensures that scripts requiring 64-bit PowerShell can be executed from a 32-bit context, passing any specified arguments.
.PARAMETER Arguments
    Optional arguments to pass to the new PowerShell process.
#>
    param (
        [parameter(Mandatory = $false, HelpMessage = "Specify arguments that will be passed to the sysnative PowerShell process.")]
        [ValidateNotNull()]
        [string]$Arguments
    )

    # Get the sysnative path for powershell.exe
    $SysNativePowerShell = Join-Path -Path ($PSHOME.ToLower().Replace("syswow64", "sysnative")) -ChildPath "powershell.exe"

    # Construct new ProcessStartInfo object to run scriptblock in fresh process
    $ProcessStartInfo = New-Object -TypeName System.Diagnostics.ProcessStartInfo
    $ProcessStartInfo.FileName = $SysNativePowerShell
    $ProcessStartInfo.Arguments = $Arguments
    $ProcessStartInfo.RedirectStandardOutput = $true
    $ProcessStartInfo.RedirectStandardError = $true
    $ProcessStartInfo.UseShellExecute = $false
    $ProcessStartInfo.WindowStyle = "Hidden"
    $ProcessStartInfo.CreateNoWindow = $true

    # Instatiate the new 64-bit process
    $Process = [System.Diagnostics.Process]::Start($ProcessStartInfo)

    # Read standard error output to determine if the 64-bit script process somehow failed
    $ErrorOutput = $Process.StandardError.ReadToEnd()
    if ($ErrorOutput)
    {
        Write-Error -Message $ErrorOutput
    }
}#endfunction
#endregion functions

#region APPUSAGE
# App Usage (software metering). Function definitions and $script: constants only, so tests can load
# this region without running the inventory. Keep this region ASCII.

function Get-AUUserType
{
    <#
.SYNOPSIS
    Classifies a user SID as CloudOnly, Domain, Local, System, Service, or Unknown.
.DESCRIPTION
    S-1-12-1-* is an Entra ID (CloudOnly) account. An S-1-5-21-* SID whose domain portion (every
    part but the final RID) equals the machine account-domain SID is Local; any other S-1-5-21-*
    SID is Domain. The domain portion is compared whole, never as a string prefix.
.PARAMETER Sid
    The user SID in S-1-... string form.
.PARAMETER MachineDomainSid
    The local machine account-domain SID (S-1-5-21-x-y-z).
#>
    param (
        [string]$Sid,
        [string]$MachineDomainSid
    )

    if ([string]::IsNullOrWhiteSpace($Sid)) { return 'Unknown' }
    $Value = $Sid.Trim().ToUpperInvariant()
    if ($Value -notmatch '^S-1-\d+(-\d+)+$') { return 'Unknown' }

    if ($Value -eq 'S-1-5-18') { return 'System' }
    if ($Value -match '^S-1-12-1-') { return 'CloudOnly' }
    if ($Value -match '^S-1-5-21-')
    {
        $DomainPortion = $Value.Substring(0, $Value.LastIndexOf('-'))
        $MachineDomain = ''
        if ($MachineDomainSid) { $MachineDomain = $MachineDomainSid.Trim().ToUpperInvariant() }
        if ($DomainPortion -eq $MachineDomain) { return 'Local' }
        return 'Domain'
    }
    # LocalService, NetworkService, and the service, IIS app pool, virtual machine, Window Manager,
    # and font driver host account SIDs.
    if ($Value -match '^S-1-5-(19|20)$' -or $Value -match '^S-1-5-(80|82|83|90|96)-') { return 'Service' }
    return 'Unknown'
}#endfunction

function Test-AUInteractiveUserType
{
    <#
.SYNOPSIS
    Returns true only for the interactive user types CloudOnly, Domain, and Local.
.PARAMETER UserType
    A value returned by Get-AUUserType.
#>
    param (
        [string]$UserType
    )

    return ($UserType -in @('CloudOnly', 'Domain', 'Local'))
}#endfunction

function ConvertFrom-AUExeInfo
{
    <#
.SYNOPSIS
    Parses a SRUM ExeInfo value into its exe name, PE link time, PE CheckSum, and kind.
.DESCRIPTION
    A Win32 value is a build fingerprint, !!<exe>!<yyyy/MM/dd:HH:mm:ss>!<hex>!: the exe name, the
    PE header TimeDateStamp in UTC, and the PE optional-header CheckSum. It returns Kind Win32, the
    lowercase ExeName, LinkTimeUtc (Utc kind), and CheckSum ([uint32]). A link time or CheckSum
    that doesn't parse is $null; the value is still Win32.
    A package full name, or a package family name with an optional !AppId, is Kind Package, with
    ExeName, LinkTimeUtc, and CheckSum all $null.
    Anything else (a path, a plain name, or an empty value) is Kind Other, with ExeName the
    lowercase final path element ($null when empty) and no link time or CheckSum.
.PARAMETER ExeInfo
    The SRUM ExeInfo string.
#>
    param (
        [string]$ExeInfo
    )

    $Result = [pscustomobject]@{
        ExeName     = $null
        LinkTimeUtc = $null
        CheckSum    = $null
        Kind        = 'Other'
    }
    if ([string]::IsNullOrWhiteSpace($ExeInfo)) { return $Result }
    $Value = $ExeInfo.Trim()

    $Win32 = [regex]::Match($Value, '^!!(?<Name>[^!]+)!(?<Time>[^!]*)!(?<Sum>[^!]*)!')
    if ($Win32.Success)
    {
        $Result.Kind = 'Win32'
        $Result.ExeName = $Win32.Groups['Name'].Value.Trim().ToLowerInvariant()

        $LinkTime = [datetime]::MinValue
        $Styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
        if ([datetime]::TryParseExact($Win32.Groups['Time'].Value, 'yyyy/MM/dd:HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, $Styles, [ref]$LinkTime))
        {
            $Result.LinkTimeUtc = [datetime]::SpecifyKind($LinkTime, [DateTimeKind]::Utc)
        }

        $Sum = [uint32]0
        if ([uint32]::TryParse($Win32.Groups['Sum'].Value, [Globalization.NumberStyles]::AllowHexSpecifier, [Globalization.CultureInfo]::InvariantCulture, [ref]$Sum))
        {
            $Result.CheckSum = $Sum
        }
        return $Result
    }

    # Package full name: Name_Version_Architecture_ResourceId_PublisherId. Package family name:
    # Name_PublisherId. The publisher ID is 13 base32 characters. Either may carry an !AppId.
    $PackageFullName = '^[A-Za-z0-9.\-]+_\d+\.\d+\.\d+\.\d+_(x86|x64|arm|arm64|neutral)_[A-Za-z0-9.\-~]*_[a-hj-km-np-tv-z0-9]{13}(![A-Za-z0-9.\-_]+)?$'
    $PackageFamilyName = '^[A-Za-z0-9.\-]+_[a-hj-km-np-tv-z0-9]{13}(![A-Za-z0-9.\-_]+)?$'
    if ($Value -match $PackageFullName -or $Value -match $PackageFamilyName)
    {
        $Result.Kind = 'Package'
        return $Result
    }

    $Leaf = ($Value -split '[\\/]')[-1].Trim()
    if ($Leaf) { $Result.ExeName = $Leaf.ToLowerInvariant() }
    return $Result
}#endfunction

function ConvertFrom-AUFileTime
{
    <#
.SYNOPSIS
    Converts a Windows FILETIME (100-ns intervals since 1601-01-01 UTC) to a Utc-kind date.
.DESCRIPTION
    Returns $null for 0 (SRUM's unset value), a negative value, or a value past the last
    representable date. It never throws.
.PARAMETER FileTime
    The FILETIME as a 64-bit integer.
#>
    param (
        [long]$FileTime
    )

    if ($FileTime -le 0) { return $null }
    try { return [datetime]::FromFileTimeUtc($FileTime) }
    catch { return $null }
}#endfunction

function ConvertFrom-AUOleDate
{
    <#
.SYNOPSIS
    Converts an OLE Automation date (days since 1899-12-30) to a date, treating the value as UTC.
.DESCRIPTION
    SRUM stores its TimeStamp column as an OLE date in UTC. The result is Utc kind; no local time
    conversion is applied. Returns $null for 0 or less (unset), a non-finite value, or a value out
    of the OLE date range. It never throws.
.PARAMETER OleDate
    The OLE Automation date.
#>
    param (
        [double]$OleDate
    )

    if ([double]::IsNaN($OleDate) -or [double]::IsInfinity($OleDate) -or $OleDate -le 0) { return $null }
    try { return [datetime]::SpecifyKind([datetime]::FromOADate($OleDate), [DateTimeKind]::Utc) }
    catch { return $null }
}#endfunction

# The one UTC date format (AppLastUsedDate and every other App Usage date).
$script:AUUtcDateFormat = "yyyy'-'MM'-'dd'T'HH':'mm':'ss'.'fffffff'Z'"

function Format-AUDate
{
    <#
.SYNOPSIS
    Formats a Utc-kind date as yyyy-MM-ddTHH:mm:ss.fffffffZ, independent of the current culture.
.DESCRIPTION
    Throws when the date is Local or Unspecified kind, so a local time is never written with a Z.
.PARAMETER Utc
    The date to format. It must be Utc kind.
#>
    param (
        [datetime]$Utc
    )

    if ($Utc.Kind -ne [DateTimeKind]::Utc) { throw "Format-AUDate needs a Utc date; got Kind $($Utc.Kind)." }
    return $Utc.ToString($script:AUUtcDateFormat, [Globalization.CultureInfo]::InvariantCulture)
}#endfunction

# Mapping rules (D3, D38, D41, D45). The rule IDs a D47 candidate step records; no file may define them.
$script:AUReservedRuleIds = @('ps-resolve-path', 'ps-resolve-msi', 'ps-resolve-publisher', 'ps-resolve-product', 'ps-resolve-version', 'ps-resolve-arch', 'ps-resolve-scope')
$script:AUMaxCustomerMappingsBytes = 1048576
$script:AUMaxMappingErrors = 50
$script:AULocationClasses = @('Windows', 'ProgramFiles', 'UserProfile', 'Temp', 'Download', 'ManagementCache', 'Other')
$script:AURuleRoles = @('Windows', 'Installer', 'Helper', 'Service', 'CLI')

function ConvertTo-AUVersion
{
    <#
.SYNOPSIS
    Converts a dotted numeric version of one to four parts to a [version] padded with zeros.
.DESCRIPTION
    Returns $null when the text isn't one to four dot-separated numbers that each fit an Int32.
.PARAMETER Text
    The version text, for example 24.08 or 1.2.3.4.
#>
    param (
        [string]$Text
    )

    if ($null -eq $Text -or $Text -notmatch '^\d+(\.\d+){0,3}$') { return $null }
    $Parts = New-Object 'int[]' 4
    $Pieces = $Text.Split('.')
    for ($i = 0; $i -lt $Pieces.Count; $i++)
    {
        $Part = 0
        if (-not [int]::TryParse($Pieces[$i], [ref]$Part)) { return $null }
        $Parts[$i] = $Part
    }
    return New-Object version($Parts[0], $Parts[1], $Parts[2], $Parts[3])
}#endfunction

function Format-AUErrorText
{
    <#
.SYNOPSIS
    Shortens an exception message for an Errors entry or a log line.
.DESCRIPTION
    Windows PowerShell's ConvertFrom-Json appends the whole input after a position marker, as in
    "Invalid object passed in, ':' or '}' expected. (147): {...", so one broken 1 MB file would put
    1 MB in every message. This keeps the text up to and including the marker's position number,
    makes it one line, and caps it at MaxLength characters.
.PARAMETER Message
    The exception message.
.PARAMETER MaxLength
    The most characters to keep before "..." is added.
#>
    param (
        [string]$Message,
        [int]$MaxLength = 300
    )

    if ([string]::IsNullOrEmpty($Message)) { return '' }
    $Text = $Message
    $Marker = [regex]::Match($Text, '\(\d+\):')
    if ($Marker.Success) { $Text = $Text.Substring(0, $Marker.Index + $Marker.Length - 1) }
    $Cut = $Text.Length -gt $MaxLength
    if ($Cut) { $Text = $Text.Substring(0, $MaxLength) }
    $Text = ($Text -replace '\s+', ' ').Trim()
    if ($Cut) { $Text += '...' }
    return $Text
}#endfunction

function Test-AUMappings
{
    <#
.SYNOPSIS
    Validates parsed mapping rules and returns one error string per problem (none when valid).
.DESCRIPTION
    Kind PowerStacks needs a powerStacks section (with a version) and no customer section; Kind
    Customer needs a customer section and no powerStacks section; Kind Merged needs both. Each
    section holds identityRules (identity, ownership, arpCompare) and classificationRules
    (classification, ignore). Customer rule IDs start with c-, PowerStacks rule IDs with ps-, and
    ps-resolve-* IDs are reserved (F11). IDs are unique across the sections, ignoring case. Unknown
    keys are rejected, so a misspelled condition can't silently widen a rule. Patterns must be valid
    -like wildcards. It never throws.
.PARAMETER Mappings
    The object ConvertFrom-Json returned for the file (or the Merged object from Get-AUMappings).
.PARAMETER Kind
    PowerStacks, Customer, or Merged.
#>
    param (
        [object]$Mappings,
        [ValidateSet('PowerStacks', 'Customer', 'Merged')][string]$Kind
    )

    $Errors = New-Object 'System.Collections.Generic.List[string]'
    try
    {
        if ($Mappings -isnot [System.Management.Automation.PSCustomObject])
        {
            $Errors.Add('The mappings are not a JSON object.')
            return , $Errors.ToArray()
        }

        $Top = @{}
        foreach ($Property in $Mappings.PSObject.Properties) { $Top[$Property.Name] = $Property.Value }
        foreach ($Name in $Top.Keys)
        {
            if ($Name -notin @('schemaVersion', 'powerStacks', 'customer')) { $Errors.Add("Unknown top-level key '$Name'.") }
        }
        $Version = $Top['schemaVersion']
        if (-not (($Version -is [int] -or $Version -is [long]) -and $Version -eq 1)) { $Errors.Add("schemaVersion must be 1; got '$Version'.") }

        $Sections = @()
        if ($Kind -in @('PowerStacks', 'Merged')) { $Sections += , @('powerStacks', 'ps-') }
        if ($Kind -in @('Customer', 'Merged')) { $Sections += , @('customer', 'c-') }
        if ($Kind -eq 'PowerStacks' -and $Top.ContainsKey('customer')) { $Errors.Add("A PowerStacks file can't have a 'customer' section.") }
        if ($Kind -eq 'Customer' -and $Top.ContainsKey('powerStacks')) { $Errors.Add("A customer file can't have a 'powerStacks' section; put your rules in 'customer'.") }

        $SeenIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $IdentityTypes = @('identity', 'ownership', 'arpCompare')
        $ClassificationTypes = @('classification', 'ignore')
        $ClassificationKeys = @('locationClass', 'companyName', 'fileDescription', 'exeName')

        foreach ($Section in $Sections)
        {
            $SectionName = $Section[0]
            $Prefix = $Section[1]
            $Body = $Top[$SectionName]
            if ($Body -isnot [System.Management.Automation.PSCustomObject])
            {
                $Errors.Add("The '$SectionName' section is missing or isn't an object.")
                continue
            }
            $AllowedSectionKeys = @('identityRules', 'classificationRules')
            if ($SectionName -eq 'powerStacks')
            {
                $AllowedSectionKeys += 'version'
                $RulesVersion = $Body.PSObject.Properties['version']
                if ($Kind -eq 'PowerStacks' -and ($null -eq $RulesVersion -or $RulesVersion.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($RulesVersion.Value)))
                {
                    $Errors.Add("powerStacks.version must be a non-empty string.")
                }
            }
            foreach ($Property in $Body.PSObject.Properties)
            {
                if ($Property.Name -notin $AllowedSectionKeys) { $Errors.Add("Unknown key '$($Property.Name)' in the '$SectionName' section.") }
            }

            foreach ($Family in @('identityRules', 'classificationRules'))
            {
                $ListProperty = $Body.PSObject.Properties[$Family]
                if ($null -eq $ListProperty) { continue }
                if ($ListProperty.Value -isnot [array])
                {
                    $Errors.Add("$SectionName.$Family must be an array.")
                    continue
                }
                $FamilyTypes = if ($Family -eq 'identityRules') { $IdentityTypes } else { $ClassificationTypes }
                $OtherFamily = if ($Family -eq 'identityRules') { 'classificationRules' } else { 'identityRules' }
                $Index = -1
                foreach ($Rule in $ListProperty.Value)
                {
                    $Index++
                    $Where = "$SectionName.$Family[$Index]"
                    if ($Rule -isnot [System.Management.Automation.PSCustomObject])
                    {
                        $Errors.Add("${Where}: a rule must be a JSON object.")
                        continue
                    }
                    $R = @{}
                    foreach ($Property in $Rule.PSObject.Properties) { $R[$Property.Name] = $Property.Value }

                    # The rule ID: present, prefixed for its file, not reserved, unique.
                    $Id = $R['id']
                    if ($Id -isnot [string] -or [string]::IsNullOrWhiteSpace($Id))
                    {
                        $Errors.Add("${Where}: rule has no id.")
                    }
                    else
                    {
                        $Where = "Rule '$Id'"
                        if ($Id -like 'ps-resolve-*') { $Errors.Add("${Where}: IDs starting ps-resolve- are reserved.") }
                        elseif (-not $Id.StartsWith($Prefix, [StringComparison]::Ordinal)) { $Errors.Add("${Where}: IDs in the '$SectionName' section must start with '$Prefix'.") }
                        elseif ($Id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { $Errors.Add("${Where}: an ID may use only letters, digits, '.', '_', and '-'.") }
                        if (-not $SeenIds.Add($Id)) { $Errors.Add("${Where}: duplicate rule ID '$Id'.") }
                    }

                    # The rule type, in its own family (D24).
                    $Type = $R['type']
                    if ($Type -isnot [string] -or $Type -cnotin ($IdentityTypes + $ClassificationTypes))
                    {
                        $Errors.Add("${Where}: unknown type '$Type'; use identity, ownership, arpCompare, classification, or ignore.")
                        continue
                    }
                    if ($Type -cnotin $FamilyTypes)
                    {
                        $Errors.Add("${Where}: a '$Type' rule belongs in $OtherFamily, not $Family.")
                        continue
                    }

                    $Allowed = @('id', 'type', 'description')
                    switch -CaseSensitive ($Type)
                    {
                        'identity' { $Allowed += @('when', 'target') }
                        'ownership' { $Allowed += 'source' }
                        'classification' { $Allowed += @('when', 'role') }
                        'ignore' { $Allowed += 'when' }
                    }
                    foreach ($Name in $R.Keys)
                    {
                        if ($Name -notin $Allowed) { $Errors.Add("${Where}: '$Name' isn't a field of a '$Type' rule.") }
                    }
                    if ($R.ContainsKey('description') -and $R['description'] -isnot [string]) { $Errors.Add("${Where}: description must be a string.") }

                    # Checks one object of string patterns: required keys, optional keys, no others.
                    $CheckPatterns = {
                        param ($Object, [string]$Label, [string[]]$Required, [string[]]$Optional, [string[]]$MayBeEmpty)
                        if ($Object -isnot [System.Management.Automation.PSCustomObject])
                        {
                            $Errors.Add("${Where}: '$Label' must be an object.")
                            return
                        }
                        $Present = @{}
                        foreach ($Property in $Object.PSObject.Properties) { $Present[$Property.Name] = $Property.Value }
                        foreach ($Name in $Present.Keys)
                        {
                            if ($Name -notin ($Required + $Optional)) { $Errors.Add("${Where}: '$Label' has an unknown key '$Name'.") }
                        }
                        foreach ($Name in $Required)
                        {
                            if (-not $Present.ContainsKey($Name)) { $Errors.Add("${Where}: '$Label' needs '$Name'.") }
                        }
                        foreach ($Name in $Present.Keys)
                        {
                            if ($Name -notin ($Required + $Optional)) { continue }
                            $Value = $Present[$Name]
                            if ($Value -isnot [string]) { $Errors.Add("${Where}: '$Label.$Name' must be a string."); continue }
                            if ($Value -eq '')
                            {
                                if ($Name -notin $MayBeEmpty) { $Errors.Add("${Where}: '$Label.$Name' can't be empty.") }
                                continue
                            }
                            if ($Name -in @('versionMin', 'versionMax'))
                            {
                                if ($null -eq (ConvertTo-AUVersion $Value)) { $Errors.Add("${Where}: '$Label.$Name' must be a version such as 2.1 or 2.1.0.5; got '$Value'.") }
                                continue
                            }
                            if ($Name -eq 'locationClass')
                            {
                                if ($Value -notin $script:AULocationClasses) { $Errors.Add("${Where}: '$Label.locationClass' must be one of $($script:AULocationClasses -join ', '); got '$Value'.") }
                                continue
                            }
                            try { [void]([System.Management.Automation.WildcardPattern]::new($Value, 'IgnoreCase').IsMatch('')) }
                            catch { $Errors.Add("${Where}: '$Label.$Name' isn't a valid wildcard pattern: '$Value'.") }
                        }
                    }

                    switch -CaseSensitive ($Type)
                    {
                        'identity'
                        {
                            & $CheckPatterns $R['when'] 'when' @('exeName', 'publisher') @('productName', 'fileDescription', 'versionMin', 'versionMax') @('publisher')
                            & $CheckPatterns $R['target'] 'target' @('displayName', 'publisher') @() @('publisher')
                            $When = $R['when']
                            if ($When -is [System.Management.Automation.PSCustomObject])
                            {
                                $MinText = [string]$When.PSObject.Properties['versionMin'].Value
                                $MaxText = [string]$When.PSObject.Properties['versionMax'].Value
                                # A bound compares only as many parts as it gives, as in matching
                                # (Compare-AUVersionPrefix): versionMax 8 covers every 8.x, so 8.5 to 8 is a range.
                                if ((ConvertTo-AUVersion $MinText) -and (ConvertTo-AUVersion $MaxText) -and
                                    (Compare-AUVersionPrefix (ConvertTo-AUVersionParts $MinText) (ConvertTo-AUVersionParts $MaxText)) -gt 0)
                                {
                                    $Errors.Add("${Where}: when.versionMin is above when.versionMax.")
                                }
                            }
                        }
                        'ownership'
                        {
                            if ($R['source'] -cnotin @('msi', 'store')) { $Errors.Add("${Where}: source must be msi or store; got '$($R['source'])'.") }
                        }
                        { $_ -in @('classification', 'ignore') }
                        {
                            $When = $R['when']
                            & $CheckPatterns $When 'when' @() $ClassificationKeys @()
                            if ($When -is [System.Management.Automation.PSCustomObject] -and @($When.PSObject.Properties).Count -eq 0)
                            {
                                $Errors.Add("${Where}: 'when' needs at least one of $($ClassificationKeys -join ', ').")
                            }
                        }
                        'classification'
                        {
                            if ($R['role'] -isnot [string] -or $R['role'] -notin $script:AURuleRoles) { $Errors.Add("${Where}: role must be one of $($script:AURuleRoles -join ', '); got '$($R['role'])'.") }
                        }
                    }
                }
            }
        }
    }
    catch
    {
        $Errors.Add("The mappings couldn't be checked: $(Format-AUErrorText $_.Exception.Message)")
    }

    # Bounded output: an error can echo a value from the file, and a broken file can hold many rules.
    # Format-AUErrorText makes each one line, so text from the file can't add lines to the log.
    $Limited = New-Object 'System.Collections.Generic.List[string]'
    foreach ($Problem in $Errors)
    {
        if ($Limited.Count -ge $script:AUMaxMappingErrors) { break }
        $Limited.Add((Format-AUErrorText $Problem))
    }
    if ($Errors.Count -gt $Limited.Count) { $Limited.Add("... and $($Errors.Count - $Limited.Count) more errors.") }
    return , $Limited.ToArray()
}#endfunction

function Test-AUCustomerMappingsPath
{
    <#
.SYNOPSIS
    Checks the customer mappings file path before SYSTEM opens it: Use, Absent, UnsafePath, or ReparsePoint.
.DESCRIPTION
    UnsafePath: the path isn't a local drive path (UNC, device, NT, or relative), so nothing touches
    it. ReparsePoint: the file or a folder above it is a junction, a symbolic link, or another reparse
    point. The folders are checked from the drive root down, reading each one's own attributes, so no
    check passes through a link. Otherwise a standard user who can create a folder on the path, such
    as under C:\ProgramData, could point SYSTEM's open at any file or at a share. Absent: a folder or
    the file doesn't exist, or the path is a folder. A link swapped in between this check and the
    open isn't caught. Returns Verdict, Path (the full path, when Use), and Item (the reparse point,
    when ReparsePoint). Not a permission check, so D45 holds. Throws only on a malformed path.
.PARAMETER Path
    The customer mappings file path.
#>
    param (
        [string]$Path
    )

    $Result = [pscustomobject]@{ Verdict = 'UnsafePath'; Path = $null; Item = $null }
    # Only X:\ paths: a UNC or device path would have SYSTEM open a share or any NT object.
    if ($Path -notmatch '^[A-Za-z]:[\\/]') { return $Result }
    $Full = [IO.Path]::GetFullPath($Path)
    $Current = [IO.Path]::GetPathRoot($Full)
    $Attributes = [IO.FileAttributes]::Directory
    foreach ($Part in $Full.Substring($Current.Length).Split([char[]]@('\', '/'), [StringSplitOptions]::RemoveEmptyEntries))
    {
        $Current = [IO.Path]::Combine($Current, $Part)
        # GetAttributes reads the item's own attributes; it doesn't follow the item when it's a link.
        try { $Attributes = [IO.File]::GetAttributes($Current) }
        catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] { $Result.Verdict = 'Absent'; return $Result }
        if ($Attributes -band [IO.FileAttributes]::ReparsePoint)
        {
            $Result.Verdict = 'ReparsePoint'
            $Result.Item = $Current
            return $Result
        }
    }
    if ($Attributes -band [IO.FileAttributes]::Directory) { $Result.Verdict = 'Absent'; return $Result }
    $Result.Verdict = 'Use'
    $Result.Path = $Full
    return $Result
}#endfunction

function Read-AUCustomerMappingsFile
{
    <#
.SYNOPSIS
    Reads and parses the customer mappings file once, with a bounded read, without validating it.
.DESCRIPTION
    Returns State (Absent, TooLarge, Invalid, or Parsed), Data (the parsed JSON when Parsed), Hash
    (SHA-256 hex of the bytes read, when no more than the limit), Errors, and Detail (UnsafePath or
    ReparsePoint when the file is refused, else ''). The file is opened read-only and read through
    one FileStream of at most the limit plus one byte, so the hash and the parse use exactly the same
    bytes (F59). No owner or permission check (D45). Before the file is opened, the path must pass
    Test-AUCustomerMappingsPath; a path it refuses makes the file Invalid, never partly used, with
    Detail set to its verdict. It never throws.
.PARAMETER Path
    The customer mappings file path.
.PARAMETER AnyPath
    Skips Test-AUCustomerMappingsPath. Only Test-AppUsageMappings.ps1 sets it: it reads a file an
    administrator names, as that administrator, to check its content.
#>
    param (
        [string]$Path,
        [switch]$AnyPath
    )

    $Result = [pscustomobject]@{ State = 'Absent'; Data = $null; Hash = ''; Errors = @(); Detail = '' }
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Result }
    try
    {
        if ($AnyPath)
        {
            if (-not [IO.File]::Exists($Path)) { return $Result }
        }
        else
        {
            $Check = Test-AUCustomerMappingsPath $Path
            if ($Check.Verdict -eq 'Absent') { return $Result }
            if ($Check.Verdict -ne 'Use')
            {
                $Result.State = 'Invalid'
                $Result.Detail = $Check.Verdict
                if ($Check.Verdict -eq 'UnsafePath') { $Result.Errors = @("The customer mappings file path must be a local drive path, not a UNC, device, or relative path, so it's ignored: $(Format-AUErrorText $Path)") }
                else { $Result.Errors = @("The customer mappings file is ignored because it or a folder above it is a reparse point (a junction or a link): $(Format-AUErrorText $Check.Item)") }
                return $Result
            }
            $Path = $Check.Path
        }
        $Limit = $script:AUMaxCustomerMappingsBytes
        $Buffer = New-Object 'byte[]' ($Limit + 1)
        $Count = 0
        $Stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try
        {
            while ($Count -lt $Buffer.Length)
            {
                $Read = $Stream.Read($Buffer, $Count, $Buffer.Length - $Count)
                if ($Read -le 0) { break }
                $Count += $Read
            }
        }
        finally { $Stream.Dispose() }

        if ($Count -gt $Limit)
        {
            $Result.State = 'TooLarge'
            $Result.Errors = @("The customer mappings file is larger than $Limit bytes, so it's ignored: $Path")
            return $Result
        }

        $Sha = [Security.Cryptography.SHA256]::Create()
        try { $Digest = $Sha.ComputeHash($Buffer, 0, $Count) }
        finally { $Sha.Dispose() }
        $Result.Hash = ([BitConverter]::ToString($Digest)).Replace('-', '')

        # UTF-8 (with or without a BOM) or UTF-16 with a BOM, which Windows PowerShell's Out-File writes.
        if ($Count -ge 2 -and $Buffer[0] -eq 0xFF -and $Buffer[1] -eq 0xFE) { $Text = (New-Object Text.UnicodeEncoding($false, $true, $true)).GetString($Buffer, 2, $Count - 2) }
        elseif ($Count -ge 2 -and $Buffer[0] -eq 0xFE -and $Buffer[1] -eq 0xFF) { $Text = (New-Object Text.UnicodeEncoding($true, $true, $true)).GetString($Buffer, 2, $Count - 2) }
        else
        {
            $Skip = 0
            if ($Count -ge 3 -and $Buffer[0] -eq 0xEF -and $Buffer[1] -eq 0xBB -and $Buffer[2] -eq 0xBF) { $Skip = 3 }
            $Text = (New-Object Text.UTF8Encoding($false, $true)).GetString($Buffer, $Skip, $Count - $Skip)
        }
        $Result.Data = $Text | ConvertFrom-Json -ErrorAction Stop
        $Result.State = 'Parsed'
    }
    catch
    {
        $Result.State = 'Invalid'
        $Result.Data = $null
        $Result.Errors = @("The customer mappings file couldn't be read as JSON: $(Format-AUErrorText $_.Exception.Message)")
    }
    return $Result
}#endfunction

function Get-AUMappings
{
    <#
.SYNOPSIS
    Loads and validates our rules and the customer's rules, and returns one mappings object (F18).
.DESCRIPTION
    Our rules come from the embedded text (Base64 of GZip-compressed JSON) or, only when nothing is
    embedded, from powerstacks-mappings.json in BesideDir (D41). The customer's rules come only from
    CustomerPath, used when the file is at most 1 MB and valid, whoever owns it (D45); it's read as
    data, never run, and never written. Returns Source (Embedded, Beside, None), CustomerSource
    (File, Absent, Invalid, TooLarge), Mappings (schemaVersion, powerStacks, customer; a section
    that isn't used has empty rule arrays), Errors, PowerStacksVersion, CustomerHash (SHA-256 hex,
    blank unless CustomerSource is File), CustomerDetail (UnsafePath or ReparsePoint when the customer
    file is refused before it's read, so CustomerSource is Invalid; else ''), and RuleIds (every rule
    ID in use plus the reserved ps-resolve-* IDs, case-insensitive). It never throws.
.PARAMETER Embedded
    The embedded PowerStacks rules, or empty.
.PARAMETER BesideDir
    The folder to look in for powerstacks-mappings.json when nothing is embedded.
.PARAMETER CustomerPath
    The customer mappings file path.
#>
    param (
        [string]$Embedded,
        [string]$BesideDir,
        [string]$CustomerPath
    )

    $Errors = New-Object 'System.Collections.Generic.List[string]'
    $RuleIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($Id in $script:AUReservedRuleIds) { [void]$RuleIds.Add($Id) }
    $Source = 'None'
    $CustomerSource = 'Absent'
    $CustomerHash = ''
    $CustomerDetail = ''
    $Ours = [pscustomobject]@{ version = ''; identityRules = @(); classificationRules = @() }
    $Theirs = [pscustomobject]@{ identityRules = @(); classificationRules = @() }

    try
    {
        # Our rules.
        $OursText = $null
        try
        {
            if (-not [string]::IsNullOrWhiteSpace($Embedded))
            {
                $Source = 'Embedded'
                $Compressed = New-Object IO.MemoryStream(, [Convert]::FromBase64String($Embedded.Trim()))
                $Zip = New-Object IO.Compression.GZipStream($Compressed, [IO.Compression.CompressionMode]::Decompress)
                $Reader = New-Object IO.StreamReader($Zip, (New-Object Text.UTF8Encoding($false, $true)))
                try { $OursText = $Reader.ReadToEnd() }
                finally { $Reader.Dispose() }
            }
            elseif (-not [string]::IsNullOrWhiteSpace($BesideDir))
            {
                $BesidePath = Join-Path $BesideDir 'powerstacks-mappings.json'
                if ([IO.File]::Exists($BesidePath))
                {
                    $Source = 'Beside'
                    $OursText = [IO.File]::ReadAllText($BesidePath, (New-Object Text.UTF8Encoding($false, $true)))
                }
            }
            if ($Source -ne 'None')
            {
                $Parsed = $OursText | ConvertFrom-Json -ErrorAction Stop
                $Problems = Test-AUMappings $Parsed -Kind PowerStacks
                if ($Problems.Count -gt 0)
                {
                    foreach ($Problem in $Problems) { $Errors.Add("PowerStacks mappings ($Source): $Problem") }
                }
                else
                {
                    $Ours = [pscustomobject]@{
                        version             = $Parsed.powerStacks.version
                        identityRules       = @($Parsed.powerStacks.identityRules | Where-Object { $null -ne $_ })
                        classificationRules = @($Parsed.powerStacks.classificationRules | Where-Object { $null -ne $_ })
                    }
                }
            }
        }
        catch
        {
            $Errors.Add("PowerStacks mappings ($Source) couldn't be read: $(Format-AUErrorText $_.Exception.Message)")
        }

        # The customer's rules: all or nothing.
        $File = Read-AUCustomerMappingsFile -Path $CustomerPath
        foreach ($Problem in $File.Errors) { $Errors.Add($Problem) }
        $CustomerDetail = [string]$File.Detail
        switch ($File.State)
        {
            'Absent' { $CustomerSource = 'Absent' }
            'TooLarge' { $CustomerSource = 'TooLarge' }
            'Invalid' { $CustomerSource = 'Invalid' }
            'Parsed'
            {
                $Problems = Test-AUMappings $File.Data -Kind Customer
                if ($Problems.Count -gt 0)
                {
                    $CustomerSource = 'Invalid'
                    foreach ($Problem in $Problems) { $Errors.Add("Customer mappings: $Problem") }
                }
                else
                {
                    $CustomerSource = 'File'
                    $CustomerHash = $File.Hash
                    $Theirs = [pscustomobject]@{
                        identityRules       = @($File.Data.customer.identityRules | Where-Object { $null -ne $_ })
                        classificationRules = @($File.Data.customer.classificationRules | Where-Object { $null -ne $_ })
                    }
                }
            }
        }

        foreach ($Rule in @($Ours.identityRules) + @($Ours.classificationRules) + @($Theirs.identityRules) + @($Theirs.classificationRules))
        {
            [void]$RuleIds.Add($Rule.id)
        }
    }
    catch
    {
        $Errors.Add("Mappings couldn't be loaded: $(Format-AUErrorText $_.Exception.Message)")
    }

    Write-CMTraceLog -Message "App Usage mappings: ours $Source $($Ours.version), customer $CustomerSource, $($Errors.Count) errors." -Component 'AppUsage'
    foreach ($Problem in $Errors) { Write-CMTraceLog -Message "App Usage mappings: $Problem" -Component 'AppUsage' -Type 2 }

    return [pscustomobject]@{
        Source             = $Source
        CustomerSource     = $CustomerSource
        Mappings           = [pscustomobject]@{ schemaVersion = 1; powerStacks = $Ours; customer = $Theirs }
        Errors             = $Errors.ToArray()
        PowerStacksVersion = [string]$Ours.version
        CustomerHash       = $CustomerHash
        CustomerDetail     = $CustomerDetail
        RuleIds            = $RuleIds
    }
}#endfunction

# Identity resolution and classification (D24, D30, D38, D47). The D47 steps in order; each step that
# leaves one candidate records ps-resolve-<step> (reserved in $script:AUReservedRuleIds).
$script:AUResolveSteps = @('path', 'msi', 'publisher', 'product', 'version', 'arch', 'scope')
$script:AULegalSuffixes = @('inc', 'incorporated', 'corp', 'corporation', 'co', 'company', 'llc', 'llp', 'lp', 'ltd', 'limited', 'gmbh', 'ag', 'sa', 'sarl', 'srl', 'bv', 'nv', 'plc', 'pty', 'oy', 'ab', 'as', 'kk')
$script:AUArchTokens = @('x64', 'x86', 'x86_64', 'amd64', 'arm64', '64-bit', '32-bit', '64bit', '32bit', 'win64', 'win32')
# Normalized app names and publishers, so arpCompare doesn't repeat the work for every exe in a run.
# Constrained Language Mode refuses this type; App Usage skips in that mode (D37), and the check keeps
# the region loading there without an error record.
$script:AUNormalizedText = $null
if ($ExecutionContext.SessionState.LanguageMode -eq 'FullLanguage') { $script:AUNormalizedText = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal) }
# Get-AUTargetKeys results by target fields, for the same reason and with the same check.
$script:AUTargetKeysCache = $null
if ($ExecutionContext.SessionState.LanguageMode -eq 'FullLanguage') { $script:AUTargetKeysCache = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal) }

function Get-AULocationClass
{
    <#
.SYNOPSIS
    Classifies a run path as Windows, ProgramFiles, UserProfile, Temp, Download, ManagementCache, or Other.
.DESCRIPTION
    Checked in this order, so the more specific folder wins: ManagementCache (\Windows\IMECache\,
    \Windows\ccmcache\, and the Intune Management Extension Content folder), Temp (a \Temp\ or
    \SystemTemp\ folder), Download (a \Downloads\ folder), Windows (<drive>:\Windows\), ProgramFiles
    (<drive>:\Program Files\ or Program Files (x86)\), UserProfile (<drive>:\Users\<name>\), then Other.
    Case-insensitive. A blank path is Other.
.PARAMETER Path
    The executable's run path.
#>
    param (
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return 'Other' }
    $P = $Path.Trim().Replace('/', '\')
    if ($P.StartsWith('\\?\')) { $P = $P.Substring(4) }
    if ($P -match '\\Windows\\(IMECache|ccmcache)\\' -or $P -match '\\Microsoft Intune Management Extension\\Content\\') { return 'ManagementCache' }
    if ($P -match '\\(Temp|SystemTemp)\\') { return 'Temp' }
    if ($P -match '\\Downloads\\') { return 'Download' }
    if ($P -match '^[A-Za-z]:\\Windows\\') { return 'Windows' }
    if ($P -match '^[A-Za-z]:\\Program Files( \(x86\))?\\') { return 'ProgramFiles' }
    if ($P -match '^[A-Za-z]:\\Users\\[^\\]+\\') { return 'UserProfile' }
    return 'Other'
}#endfunction

function Test-AUTextPattern
{
    <#
.SYNOPSIS
    Tests one mapping pattern against a fact, treating an unknown ($null) fact as never matching.
.DESCRIPTION
    An empty pattern matches only a known, empty (or blank) value (F14). Any other pattern is a
    case-insensitive -like wildcard against the trimmed value.
.PARAMETER Value
    The fact, or $null when it isn't known.
.PARAMETER Pattern
    The rule's pattern.
#>
    param (
        [AllowNull()][object]$Value,
        [AllowNull()][object]$Pattern
    )

    if ($null -eq $Value -or $null -eq $Pattern) { return $false }
    # -like '' is true only for '', so an empty pattern needs no special case once the value is known.
    return (([string]$Value).Trim() -like [string]$Pattern)
}#endfunction

function ConvertTo-AUWildcardLiteral
{
    <#
.SYNOPSIS
    Returns a -like pattern that matches only the given text (ignoring case, as -like does).
.DESCRIPTION
    Every pattern built from file or registry text (a DisplayName, a Publisher, an exe file name)
    goes through this. It escapes the backtick first, then *, ?, [, and ]. Windows PowerShell 5.1's
    WildcardPattern.Escape doesn't escape the backtick, so a name holding `[ gives a pattern that
    matches other text or throws. WildcardPattern.Unescape reverses this. Returns '' for a null or
    empty text.
.PARAMETER Text
    The text to match literally.
#>
    param (
        [AllowNull()][string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return $Text.Replace('`', '``').Replace('*', '`*').Replace('?', '`?').Replace('[', '`[').Replace(']', '`]')
}#endfunction

function Get-AUPatternLiteral
{
    <#
.SYNOPSIS
    Returns the one text a -like pattern matches (ignoring case), or $null when it can match others.
.DESCRIPTION
    A pattern with no wildcard and no escape is its own text. The escapes ConvertTo-AUWildcardLiteral
    writes (a backtick before `, *, ?, [, or ]) are removed. Any other pattern gives $null: an
    unescaped *, ?, [, or ], a trailing backtick, or a backtick before any other character, whose
    -like meaning isn't a plain literal. The installed-app index looks up a literal by its text and
    checks every other pattern app by app.
.PARAMETER Pattern
    The -like pattern.
#>
    param (
        [AllowNull()][string]$Pattern
    )

    if ($null -eq $Pattern) { return $null }
    if ($Pattern.IndexOfAny($script:AUWildcardChars) -lt 0) { return $Pattern }
    $Text = [Text.StringBuilder]::new()
    for ($i = 0; $i -lt $Pattern.Length; $i++)
    {
        $Char = $Pattern[$i]
        if ($Char -eq [char]'`')
        {
            if ($i + 1 -ge $Pattern.Length -or [Array]::IndexOf($script:AUWildcardChars, $Pattern[$i + 1]) -lt 0) { return $null }
            $i++
            [void]$Text.Append($Pattern[$i])
            continue
        }
        if ([Array]::IndexOf($script:AUWildcardChars, $Char) -ge 0) { return $null }
        [void]$Text.Append($Char)
    }
    return $Text.ToString()
}#endfunction

function Get-AUNormalizedText
{
    <#
.SYNOPSIS
    Normalizes an app name or a publisher for comparison (arpCompare and the D47 steps).
.DESCRIPTION
    Name: lowercase, with bracketed tags such as (64-bit) or [x64], version tokens such as 24.08 or
    v2.1, and architecture tokens such as x64 removed; punctuation becomes spaces. So "7-Zip 24.08
    (x64)" and "7-Zip" both become "7 zip".
    Publisher: lowercase, dots removed, other punctuation becomes spaces, and trailing legal
    suffixes such as Inc., Corporation, LLC, and Co., Ltd. removed. So "Zoom Communications, Inc."
    becomes "zoom communications".
    Letters and digits in any script count (Unicode letter and decimal digit classes), so "Mueller"
    with an umlaut and "Moeller" with an umlaut stay distinct and a CJK name isn't blank.
    Returns '' for a blank value. Results are cached for the run.
.PARAMETER Text
    The name or publisher.
.PARAMETER Kind
    Name or Publisher.
#>
    param (
        [AllowNull()][string]$Text,
        [ValidateSet('Name', 'Publisher')][string]$Kind
    )

    $Key = $Kind + '|' + $Text
    $Cached = $null
    if ($script:AUNormalizedText.TryGetValue($Key, [ref]$Cached)) { return $Cached }

    $Value = $Text.ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($Value)) { $Value = '' }
    elseif ($Kind -eq 'Name')
    {
        $Value = [regex]::Replace($Value, '\([^)]*\)|\[[^\]]*\]', ' ')
        $Kept = [System.Collections.Generic.List[string]]::new()
        foreach ($Token in ($Value -split '\s+'))
        {
            $Token = $Token.Trim(',', ';', ':')
            if (-not $Token -or $Token -eq '-') { continue }
            if ($Token -match '^v?\d+([.,_]\d+)+[a-z]?$') { continue }
            if ($Token -in $script:AUArchTokens) { continue }
            $Kept.Add($Token)
        }
        $Value = [regex]::Replace(($Kept -join ' '), '[^\p{L}\p{Nd}+#]+', ' ').Trim()
    }
    else
    {
        $Value = [regex]::Replace($Value.Replace('.', ''), '[^\p{L}\p{Nd}]+', ' ').Trim()
        $Tokens = [System.Collections.Generic.List[string]]::new()
        foreach ($Token in ($Value -split ' ')) { if ($Token) { $Tokens.Add($Token) } }
        while ($Tokens.Count -gt 1 -and $Tokens[$Tokens.Count - 1] -in $script:AULegalSuffixes) { $Tokens.RemoveAt($Tokens.Count - 1) }
        $Value = $Tokens -join ' '
    }
    $script:AUNormalizedText[$Key] = $Value
    return $Value
}#endfunction

function ConvertTo-AUVersionParts
{
    <#
.SYNOPSIS
    Reads the leading numeric version from version-info text, as one to four integers.
.DESCRIPTION
    Accepts forms such as 24.08, 8.0.1.5, "8, 5, 0, 1", and "2.1.0 (build 5)". Returns $null when the
    text doesn't start with a number.
.PARAMETER Text
    The version text.
#>
    param (
        [AllowNull()][string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $Match = [regex]::Match($Text, '^\s*v?(\d+(?:\s*[.,]\s*\d+){0,3})')
    if (-not $Match.Success) { return $null }
    $Parts = [System.Collections.Generic.List[int]]::new()
    foreach ($Piece in ($Match.Groups[1].Value -split '[.,]'))
    {
        $Number = 0
        if (-not [int]::TryParse($Piece.Trim(), [ref]$Number)) { return $null }
        $Parts.Add($Number)
    }
    return , $Parts.ToArray()
}#endfunction

function Compare-AUVersionPrefix
{
    <#
.SYNOPSIS
    Compares a version with a bound on only as many parts as the bound gives: -1, 0, or 1.
.DESCRIPTION
    So a bound of 8.99 equals 8.99.1, and a bound of 8 equals 8.0.0. Missing version parts count as 0.
.PARAMETER Version
    The version parts.
.PARAMETER Bound
    The bound parts.
#>
    param (
        [int[]]$Version,
        [int[]]$Bound
    )

    for ($i = 0; $i -lt $Bound.Count; $i++)
    {
        $Part = 0
        if ($i -lt $Version.Count) { $Part = $Version[$i] }
        if ($Part -lt $Bound[$i]) { return -1 }
        if ($Part -gt $Bound[$i]) { return 1 }
    }
    return 0
}#endfunction

function Get-AUIdentityEvidence
{
    <#
.SYNOPSIS
    Returns the publisher, product name, description, and versions that identity rules may use.
.DESCRIPTION
    Verified facts always come first: when FactsVerified is true, PathEvidence is never used, and a
    missing CompanyName counts as known and empty. Otherwise the current file's CompanyName and
    ProductName at the same path (PathEvidence) are used, labelled CurrentFileAtPath, with no
    FileDescription and no versions (D30). With neither, everything is unknown ($null) and Kind is None.
.PARAMETER Facts
    The executable facts.
#>
    param (
        [pscustomobject]$Facts
    )

    if ($Facts.FactsVerified -eq $true)
    {
        return [pscustomobject]@{
            Kind            = 'Verified'
            Publisher       = [string]$Facts.FileCompanyName
            ProductName     = [string]$Facts.FileProductName
            FileDescription = [string]$Facts.FileDescription
            Versions        = @([string]$Facts.FileVersion, [string]$Facts.ProductVersion)
        }
    }
    if ($null -ne $Facts.PathEvidence)
    {
        return [pscustomobject]@{
            Kind            = 'CurrentFileAtPath'
            Publisher       = [string]$Facts.PathEvidence.CompanyName
            ProductName     = [string]$Facts.PathEvidence.ProductName
            FileDescription = $null
            Versions        = @()
        }
    }
    return [pscustomobject]@{ Kind = 'None'; Publisher = $null; ProductName = $null; FileDescription = $null; Versions = @() }
}#endfunction

function Test-AUIdentityWhen
{
    <#
.SYNOPSIS
    Tests an identity rule's when conditions against the executable and its evidence.
.DESCRIPTION
    exeName is a path-level fact. publisher, productName, and fileDescription use the evidence from
    Get-AUIdentityEvidence. A versionMin or versionMax condition needs verified facts (D30); it's met
    when the FileVersion or the ProductVersion is within the bounds, compared on as many parts as each
    bound gives.
.PARAMETER When
    The rule's when object.
.PARAMETER Facts
    The executable facts.
.PARAMETER Evidence
    The Get-AUIdentityEvidence result.
#>
    param (
        [pscustomobject]$When,
        [pscustomobject]$Facts,
        [pscustomobject]$Evidence
    )

    if ($null -eq $When) { return $false }
    if (-not (Test-AUTextPattern $Facts.ExeName $When.exeName)) { return $false }
    if (-not (Test-AUTextPattern $Evidence.Publisher $When.publisher)) { return $false }
    if ($null -ne $When.productName -and -not (Test-AUTextPattern $Evidence.ProductName $When.productName)) { return $false }
    if ($null -ne $When.fileDescription -and -not (Test-AUTextPattern $Evidence.FileDescription $When.fileDescription)) { return $false }

    $Min = ConvertTo-AUVersionParts ([string]$When.versionMin)
    $Max = ConvertTo-AUVersionParts ([string]$When.versionMax)
    if ($null -eq $Min -and $null -eq $Max) { return $true }
    if ($Evidence.Kind -ne 'Verified') { return $false }
    foreach ($Text in $Evidence.Versions)
    {
        $Parts = ConvertTo-AUVersionParts $Text
        if ($null -eq $Parts) { continue }
        if ($null -ne $Min -and (Compare-AUVersionPrefix $Parts $Min) -lt 0) { continue }
        if ($null -ne $Max -and (Compare-AUVersionPrefix $Parts $Max) -gt 0) { continue }
        return $true
    }
    return $false
}#endfunction

function Get-AUIdentityRuleHit
{
    <#
.SYNOPSIS
    Tests one identity rule and returns its candidate installed apps, or $null when it doesn't match.
.DESCRIPTION
    identity: matches on its when conditions alone, whether or not the app is installed; the
    candidates are the installed apps its target matches (none is fine). ownership msi: the build's
    MsiProductCode (verified builds only) equals an installed app's ProductCode. ownership store: the
    PackageFamily equals an installed app's. arpCompare: the evidence publisher and ProductName or
    FileDescription equal an installed app's Publisher and DisplayName after normalizing. The
    ownership and arpCompare rules match only when at least one installed app does.
.PARAMETER Rule
    The identity rule.
.PARAMETER Facts
    The executable facts.
.PARAMETER Evidence
    The Get-AUIdentityEvidence result.
.PARAMETER InstalledApps
    The installed-app entries.
.PARAMETER AppIndex
    New-AUAppIndex of InstalledApps, for the ownership and arpCompare lookups; built here when it
    isn't given.
#>
    param (
        [pscustomobject]$Rule,
        [pscustomobject]$Facts,
        [pscustomobject]$Evidence,
        [object[]]$InstalledApps,
        [pscustomobject]$AppIndex
    )

    $Candidates = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $AppIndex -and [string]$Rule.type -cne 'identity') { $AppIndex = New-AUAppIndex $InstalledApps }
    switch -CaseSensitive ([string]$Rule.type)
    {
        'identity'
        {
            if (-not (Test-AUIdentityWhen $Rule.when $Facts $Evidence)) { return $null }
            # The Test-AUTextPattern checks, inlined: this loop runs over every installed app.
            $NamePattern = $Rule.target.displayName
            $PublisherPattern = $Rule.target.publisher
            if ($null -ne $NamePattern -and $null -ne $PublisherPattern)
            {
                $NamePattern = [string]$NamePattern
                $PublisherPattern = [string]$PublisherPattern
                foreach ($App in $InstalledApps)
                {
                    if ($null -eq $App) { continue }
                    $AppName = [string]$App.DisplayName
                    if ([string]::IsNullOrWhiteSpace($AppName)) { continue }
                    if ($AppName.Trim() -like $NamePattern -and ([string]$App.Publisher).Trim() -like $PublisherPattern) { $Candidates.Add($App) }
                }
            }
            return [pscustomobject]@{ Candidates = $Candidates.ToArray(); TargetPattern = [string]$Rule.target.displayName; TargetPublisher = [string]$Rule.target.publisher }
        }
        'ownership'
        {
            if ($Rule.source -ceq 'msi')
            {
                # The Installer owner is a build-specific fact, attached only to a verified build (D24).
                $Code = ([string]$Facts.MsiProductCode).Trim()
                if ($Evidence.Kind -ne 'Verified' -or -not $Code) { return $null }
                foreach ($App in (Get-AUIndexedApps $AppIndex $AppIndex.ByCode $Code)) { $Candidates.Add($App) }
            }
            elseif ($Rule.source -ceq 'store')
            {
                $Family = ([string]$Facts.PackageFamily).Trim()
                if (-not $Family) { return $null }
                foreach ($App in (Get-AUIndexedApps $AppIndex $AppIndex.ByFamily $Family)) { $Candidates.Add($App) }
            }
        }
        'arpCompare'
        {
            # This runs for most exes, so it reads the Get-AUNormalizedText cache directly and calls the
            # function only on a miss.
            $Cache = $script:AUNormalizedText
            $Key = $null
            $Publisher = $null
            if (-not $Cache.TryGetValue('Publisher|' + [string]$Evidence.Publisher, [ref]$Publisher)) { $Publisher = Get-AUNormalizedText $Evidence.Publisher -Kind Publisher }
            if (-not $Publisher) { return $null }
            $Names = [Collections.Generic.List[string]]::new()
            foreach ($Text in @([string]$Evidence.ProductName, [string]$Evidence.FileDescription))
            {
                if (-not $Cache.TryGetValue('Name|' + $Text, [ref]$Key)) { $Key = Get-AUNormalizedText $Text -Kind Name }
                if ($Key) { $Names.Add($Key) }
            }
            if ($Names.Count -eq 0) { return $null }
            # Only the apps with this normalized publisher.
            foreach ($App in (Get-AUIndexedApps $AppIndex $AppIndex.ByPublisherKey $Publisher))
            {
                $AppName = [string]$App.DisplayName
                if (-not $Cache.TryGetValue('Name|' + $AppName, [ref]$Key)) { $Key = Get-AUNormalizedText $AppName -Kind Name }
                if ($Key -cin $Names) { $Candidates.Add($App) }
            }
        }
    }
    if ($Candidates.Count -eq 0) { return $null }
    return [pscustomobject]@{ Candidates = $Candidates.ToArray(); TargetPattern = $null; TargetPublisher = $null }
}#endfunction

function Get-AUCommandFile
{
    <#
.SYNOPSIS
    Returns the file named by a DisplayIcon or UninstallString value, or $null when it's blank.
.DESCRIPTION
    A quoted value gives the text inside the first pair of quotes. Otherwise it's the text up to the
    first .exe, .dll, .ico, .cmd, or .bat followed by a space, a comma, or the end, or else the whole
    value without a trailing icon index (,0). The path isn't checked or changed.
.PARAMETER Command
    The DisplayIcon or UninstallString value.
#>
    param (
        [string]$Command
    )

    if ([string]::IsNullOrWhiteSpace($Command)) { return $null }
    $Command = $Command.Trim()
    if ($Command.StartsWith('"'))
    {
        $End = $Command.IndexOf('"', 1)
        if ($End -gt 1) { return $Command.Substring(1, $End - 1) }
        return $null
    }
    $Match = [regex]::Match($Command, '^(.+?\.(exe|dll|ico|cmd|bat))(?=[\s,]|$)', 'IgnoreCase')
    if ($Match.Success) { return $Match.Groups[1].Value }
    return [regex]::Replace($Command, ',\s*-?\d+$', '')
}#endfunction

function Get-AUAppFolders
{
    <#
.SYNOPSIS
    Returns an installed app's install folders: InstallLocation and the folders of DisplayIcon and UninstallString.
.DESCRIPTION
    Only rooted paths count. A drive root never counts, and neither does a DisplayIcon or
    UninstallString folder in the Windows folder (MsiExec.exe, for example). Each folder ends with \.
.PARAMETER App
    The installed-app entry.
#>
    param (
        [pscustomobject]$App
    )

    $Folders = [System.Collections.Generic.List[string]]::new()
    $Add = {
        param ([string]$Folder, [bool]$FromFile)
        if ([string]::IsNullOrWhiteSpace($Folder)) { return }
        $Folder = $Folder.Trim().Trim('"').TrimEnd('\')
        if ($Folder -notmatch '^([A-Za-z]:|\\\\[^\\]+\\[^\\]+)\\[^\\]') { return }
        if ($FromFile -and (Get-AULocationClass ($Folder + '\x')) -eq 'Windows') { return }
        $Folders.Add($Folder + '\')
    }
    $FileFolder = {
        param ([string]$File)
        try { return [IO.Path]::GetDirectoryName($File) }
        catch { return $null }
    }

    & $Add ([string]$App.InstallLocation) $false
    foreach ($Command in @([string]$App.DisplayIcon, [string]$App.UninstallString))
    {
        $File = Get-AUCommandFile $Command
        if ($File) { & $Add (& $FileFolder $File) $true }
    }
    return , $Folders.ToArray()
}#endfunction

function Select-AUCandidate
{
    <#
.SYNOPSIS
    Narrows candidate installed apps with the D47 steps, in order.
.DESCRIPTION
    Steps: path (the run path is inside the candidate's install folder; the deepest folder wins),
    msi (Windows Installer owns the file; verified builds only), publisher (normalized CompanyName
    equals the Publisher), product (normalized ProductName or FileDescription equals the
    DisplayName), version (the FileVersion or ProductVersion shares the DisplayVersion's major and
    minor parts; verified builds only), arch (Program Files (x86) means a 32-bit entry, Program Files
    a 64-bit one), and scope (the user's own per-user install whose ProfilePath holds the run path).
    A step with no data, or that would remove every candidate, is skipped. Returns Candidates (those
    left) and Step (the step that left exactly one, else $null).
.PARAMETER Facts
    The executable facts.
.PARAMETER Evidence
    The Get-AUIdentityEvidence result.
.PARAMETER Candidates
    The candidate installed-app entries.
#>
    param (
        [pscustomobject]$Facts,
        [pscustomobject]$Evidence,
        [object[]]$Candidates
    )

    $Left = @($Candidates)
    $RunPath = ([string]$Facts.RunPath).Trim()
    $Verified = ($Evidence.Kind -eq 'Verified')
    foreach ($Step in $script:AUResolveSteps)
    {
        if ($Left.Count -le 1) { break }
        $Kept = @()
        switch ($Step)
        {
            'path'
            {
                if (-not $RunPath) { break }
                $Depths = [int[]]::new($Left.Count)
                for ($i = 0; $i -lt $Left.Count; $i++)
                {
                    foreach ($Folder in (Get-AUAppFolders $Left[$i]))
                    {
                        if ($RunPath.StartsWith($Folder, [StringComparison]::OrdinalIgnoreCase))
                        {
                            $Segments = $Folder.Split('\').Count
                            if ($Segments -gt $Depths[$i]) { $Depths[$i] = $Segments }
                        }
                    }
                }
                $Best = ($Depths | Measure-Object -Maximum).Maximum
                if ($Best -gt 0)
                {
                    $Kept = @(for ($i = 0; $i -lt $Left.Count; $i++) { if ($Depths[$i] -eq $Best) { $Left[$i] } })
                }
            }
            'msi'
            {
                $Code = ([string]$Facts.MsiProductCode).Trim()
                if (-not $Verified -or -not $Code) { break }
                $Kept = @($Left | Where-Object { [string]::Equals(([string]$_.ProductCode).Trim(), $Code, [StringComparison]::OrdinalIgnoreCase) })
            }
            'publisher'
            {
                $Publisher = Get-AUNormalizedText $Evidence.Publisher -Kind Publisher
                if (-not $Publisher) { break }
                $Kept = @($Left | Where-Object { (Get-AUNormalizedText ([string]$_.Publisher) -Kind Publisher) -ceq $Publisher })
            }
            'product'
            {
                $Names = @(foreach ($Name in @((Get-AUNormalizedText $Evidence.ProductName -Kind Name), (Get-AUNormalizedText $Evidence.FileDescription -Kind Name))) { if ($Name) { $Name } })
                if (-not $Names) { break }
                $Kept = @($Left | Where-Object { (Get-AUNormalizedText ([string]$_.DisplayName) -Kind Name) -cin $Names })
            }
            'version'
            {
                if (-not $Verified) { break }
                $Versions = [System.Collections.Generic.List[object]]::new()
                foreach ($Text in $Evidence.Versions)
                {
                    $Parts = ConvertTo-AUVersionParts $Text
                    if ($null -ne $Parts) { $Versions.Add($Parts) }
                }
                if ($Versions.Count -eq 0) { break }
                $Kept = @(foreach ($App in $Left)
                    {
                        $Shown = ConvertTo-AUVersionParts ([string]$App.DisplayVersion)
                        if ($null -eq $Shown) { continue }
                        # Equal, or the same major and minor parts: compare on the first two parts only.
                        $MajorMinor = [int[]]@(($Shown + @(0, 0))[0..1])
                        foreach ($Version in $Versions)
                        {
                            if ((Compare-AUVersionPrefix $Version $MajorMinor) -eq 0) { $App; break }
                        }
                    })
            }
            'arch'
            {
                $Want = 0
                if ($RunPath -match '^[A-Za-z]:\\Program Files \(x86\)\\') { $Want = 32 }
                elseif ($RunPath -match '^[A-Za-z]:\\Program Files\\') { $Want = 64 }
                if ($Want -eq 0) { break }
                $Kept = @($Left | Where-Object {
                        $Arch = [string]$_.Architecture
                        $Bits = 0
                        if ($Arch -match '32|x86') { $Bits = 32 } elseif ($Arch -match '64') { $Bits = 64 }
                        return ($Bits -eq $Want)
                    })
            }
            'scope'
            {
                $Sid = ([string]$Facts.UserSid).Trim()
                if (-not $RunPath -or -not $Sid) { break }
                $Kept = @($Left | Where-Object {
                        $ProfileRoot = ([string]$_.ProfilePath).Trim().TrimEnd('\')
                        return ($ProfileRoot -and [string]::Equals(([string]$_.Scope).Trim(), $Sid, [StringComparison]::OrdinalIgnoreCase) -and $RunPath.StartsWith($ProfileRoot + '\', [StringComparison]::OrdinalIgnoreCase))
                    })
            }
        }
        if ($Kept.Count -eq 0 -or $Kept.Count -eq $Left.Count) { continue }
        $Left = $Kept
        if ($Left.Count -eq 1) { return [pscustomobject]@{ Candidates = $Left; Step = $Step } }
    }
    return [pscustomobject]@{ Candidates = $Left; Step = $null }
}#endfunction

function Resolve-AUIdentity
{
    <#
.SYNOPSIS
    Decides which installed app (ARP entry) an executable belongs to, from the mapping rules.
.DESCRIPTION
    Identity rules run customer first, then PowerStacks, each in file order; the first rule that
    matches wins (D38, F12). Its candidates are the installed apps its target matches, or the
    ownership or arpCompare hits. With several candidates, the D47 steps narrow them; a step that
    leaves one records MatchRuleId ps-resolve-<step> for a PowerStacks match. A customer match keeps
    the customer rule's ID and logs the step, so its stored target goes when the customer deletes the
    rule (D38, D41; ps-resolve-* IDs always exist, F11). When candidates with two or more DisplayNames
    survive, the exe stays unresolved: MatchSection None, with CandidateTargets (F26). An identity
    rule with no installed candidate still matches: TargetPattern is set and ResolvedAppName is $null.
    Verified facts come first; an unverified build may match on the current file's CompanyName and
    ProductName (EvidenceUsed CurrentFileAtPath), never on a version condition (D30).
    Returns TargetPattern, TargetPublisher (wildcard patterns; escaped DisplayName and Publisher for
    ownership and arpCompare matches), ResolvedAppName, ProductCode, PackageFamily, MatchSection
    (Customer, PowerStacks, or None), MatchRuleId, RuleType, InstalledStateDependent (ownership and
    arpCompare), EvidenceUsed (Verified, CurrentFileAtPath, or None), and CandidateTargets.
.PARAMETER Facts
    The executable facts (Task 14 shape).
.PARAMETER Mappings
    The whole Get-AUMappings result (F18).
.PARAMETER InstalledApps
    The installed-app entries (Task 13 shape).
.PARAMETER AppIndex
    New-AUAppIndex of InstalledApps, built once per run; built here when it isn't given.
#>
    param (
        [pscustomobject]$Facts,
        [pscustomobject]$Mappings,
        [object[]]$InstalledApps,
        [pscustomobject]$AppIndex
    )

    $Result = [pscustomobject]@{
        TargetPattern           = $null
        TargetPublisher         = $null
        ResolvedAppName         = $null
        ProductCode             = $null
        PackageFamily           = $null
        MatchSection            = 'None'
        MatchRuleId             = $null
        RuleType                = $null
        InstalledStateDependent = $false
        EvidenceUsed            = 'None'
        CandidateTargets        = $null
    }
    # A $null entry never matches: it has no DisplayName, ProductCode, PackageFamily, or Publisher.
    $Apps = @($InstalledApps)
    if ($null -eq $AppIndex) { $AppIndex = New-AUAppIndex $Apps }
    $Evidence = Get-AUIdentityEvidence $Facts

    # An identity rule needs its exeName to match, so that check runs inline first: most rules fail it,
    # and the full check costs a few function calls per rule.
    $ExeText = $null
    if ($null -ne $Facts.ExeName) { $ExeText = ([string]$Facts.ExeName).Trim() }

    $Hit = $null
    $Rule = $null
    $Section = $null
    foreach ($Pair in @(@('Customer', $Mappings.Mappings.customer), @('PowerStacks', $Mappings.Mappings.powerStacks)))
    {
        foreach ($Candidate in @($Pair[1].identityRules))
        {
            if ($null -eq $Candidate) { continue }
            if ($Candidate.type -ceq 'identity')
            {
                $ExePattern = $Candidate.when.exeName
                if ($null -eq $ExeText -or $null -eq $ExePattern -or -not ($ExeText -like [string]$ExePattern)) { continue }
            }
            elseif ($Candidate.type -ceq 'ownership')
            {
                # Get-AUIdentityRuleHit's own first checks, inline for the same reason.
                if ($Candidate.source -ceq 'msi' -and ($Evidence.Kind -ne 'Verified' -or -not ([string]$Facts.MsiProductCode).Trim())) { continue }
                if ($Candidate.source -ceq 'store' -and -not ([string]$Facts.PackageFamily).Trim()) { continue }
            }
            $Hit = Get-AUIdentityRuleHit $Candidate $Facts $Evidence $Apps $AppIndex
            if ($Hit) { $Rule = $Candidate; $Section = $Pair[0]; break }
        }
        if ($Hit) { break }
    }
    if (-not $Hit) { return $Result }

    $RuleType = [string]$Rule.type
    # The package identity and the Installer owner of a verified build are both verified evidence.
    $EvidenceUsed = $Evidence.Kind
    if ($RuleType -ceq 'ownership') { $EvidenceUsed = 'Verified' }
    $Result.EvidenceUsed = $EvidenceUsed

    $RuleId = [string]$Rule.id
    $Candidates = @($Hit.Candidates)
    if ($Candidates.Count -gt 1)
    {
        $Narrowed = Select-AUCandidate $Facts $Evidence $Candidates
        $Candidates = @($Narrowed.Candidates)
        if ($Narrowed.Step)
        {
            # A customer match keeps the customer rule's ID, so the stored target goes when the rule
            # does (D38, D41); ps-resolve-* IDs always exist (F11) and are only for PowerStacks matches.
            if ($Section -eq 'Customer') { Write-CMTraceLog -Message "App Usage: resolved $RuleId by $($Narrowed.Step)." -Component 'AppUsage' }
            else { $RuleId = 'ps-resolve-' + $Narrowed.Step }
        }
        $Names = [System.Collections.Generic.List[string]]::new()
        $Seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($App in $Candidates) { if ($Seen.Add(([string]$App.DisplayName).Trim())) { $Names.Add(([string]$App.DisplayName).Trim()) } }
        if ($Names.Count -gt 1)
        {
            $Result.CandidateTargets = $Names.ToArray()
            $Exe = $Facts.ExeName
            if (-not $Exe) { $Exe = $Facts.PackageFamily }
            Write-CMTraceLog -Message "App Usage: rule $($Rule.id) left $($Names.Count) candidate apps for $Exe after the D47 steps; identity unresolved." -Component 'AppUsage'
            return $Result
        }
    }

    $Chosen = $null
    if ($Candidates.Count -gt 0) { $Chosen = $Candidates[0] }
    $Result.MatchSection = $Section
    $Result.MatchRuleId = $RuleId
    $Result.RuleType = $RuleType
    $Result.InstalledStateDependent = ($RuleType -cin @('ownership', 'arpCompare'))
    if ($RuleType -ceq 'identity')
    {
        $Result.TargetPattern = $Hit.TargetPattern
        $Result.TargetPublisher = $Hit.TargetPublisher
    }
    else
    {
        $Result.TargetPattern = ConvertTo-AUWildcardLiteral ([string]$Chosen.DisplayName).Trim()
        $Result.TargetPublisher = ConvertTo-AUWildcardLiteral ([string]$Chosen.Publisher).Trim()
    }
    if ($Chosen)
    {
        $Result.ResolvedAppName = ([string]$Chosen.DisplayName).Trim()
        if ($Chosen.ProductCode) { $Result.ProductCode = [string]$Chosen.ProductCode }
        if ($Chosen.PackageFamily) { $Result.PackageFamily = [string]$Chosen.PackageFamily }
    }
    return $Result
}#endfunction

# Get-AUClassificationCandidates plans, one per rules array, kept only as long as the array is.
$script:AUClassificationPlans = $null
if ($ExecutionContext.SessionState.LanguageMode -eq 'FullLanguage') { $script:AUClassificationPlans = New-Object 'System.Runtime.CompilerServices.ConditionalWeakTable[object,object]' }

function Get-AUClassificationCandidates
{
    <#
.SYNOPSIS
    Returns the classification and ignore rules that might match an executable, in file order.
.DESCRIPTION
    Most rules name one exe (an exeName condition with no wildcard, Get-AUPatternLiteral), and a
    rule like that can match only that exe. A plan built once per rules array keeps those rules by
    their exe name (lowercased invariant) and every other rule (no exeName, a wildcard or non-ASCII
    one, or a non-rule) in a list checked for every executable. Returns the rules of both that apply
    to ExeName, in file order; all of them when ExeName isn't ASCII. With no exe name, only the
    rules without a plain exe name. Get-AUClassification still checks every condition of each.
    Returns the rules as given when they aren't an array.
.PARAMETER Rules
    A section's classificationRules.
.PARAMETER ExeName
    The executable's ExeName fact, or $null.
#>
    param (
        [object]$Rules,
        [AllowNull()][object]$ExeName
    )

    if ($Rules -isnot [array] -or $null -eq $script:AUClassificationPlans) { return , @($Rules) }
    $Plan = $null
    if (-not $script:AUClassificationPlans.TryGetValue($Rules, [ref]$Plan))
    {
        $ByExe = [Collections.Generic.Dictionary[string,Collections.Generic.List[int]]]::new([StringComparer]::Ordinal)
        $Other = [Collections.Generic.List[int]]::new()
        for ($i = 0; $i -lt $Rules.Count; $i++)
        {
            $Literal = $null
            $When = $null
            if ($null -ne $Rules[$i]) { $When = $Rules[$i].when }
            if ($null -ne $When)
            {
                foreach ($Condition in $When.PSObject.Properties)
                {
                    if ($Condition.Name -cne 'exeName') { continue }
                    $Literal = Get-AUPatternLiteral ([string]$Condition.Value)
                    if ($null -ne $Literal -and $Literal -cmatch '[^\x00-\x7F]') { $Literal = $null }
                }
            }
            if ($null -eq $Literal) { $Other.Add($i); continue }
            $Key = $Literal.ToLowerInvariant()
            if (-not $ByExe.ContainsKey($Key)) { $ByExe[$Key] = [Collections.Generic.List[int]]::new() }
            $ByExe[$Key].Add($i)
        }
        $Plan = [pscustomobject]@{
            ByExe      = $ByExe
            Other      = $Other.ToArray()
            OtherRules = [object[]]@(foreach ($i in $Other) { $Rules[$i] })
            Results    = [Collections.Generic.Dictionary[string,object[]]]::new([StringComparer]::Ordinal)
        }
        $script:AUClassificationPlans.Add($Rules, $Plan)
    }

    # A rule's exeName never matches an unknown exe name (Test-AUTextPattern).
    if ($null -eq $ExeName) { return , $Plan.OtherRules }
    $Key = ([string]$ExeName).Trim()
    if ($Key -cmatch '[^\x00-\x7F]') { return , @($Rules) }
    $Key = $Key.ToLowerInvariant()
    $Found = $null
    if ($Plan.Results.TryGetValue($Key, [ref]$Found)) { return , $Found }
    $Positions = [Collections.Generic.SortedSet[int]]::new([int[]]$Plan.Other)
    $Named = $null
    if ($Plan.ByExe.TryGetValue($Key, [ref]$Named)) { $Positions.UnionWith($Named) }
    $Found = [object[]]@(foreach ($i in $Positions) { $Rules[$i] })
    $Plan.Results[$Key] = $Found
    return , $Found
}#endfunction

function Get-AUClassification
{
    <#
.SYNOPSIS
    Evaluates classification and ignore rules for an executable: RuleRole, ClassificationRuleId, Ignored, IgnoreRuleId.
.DESCRIPTION
    Runs for every executable, matched or not. Customer rules come first, then PowerStacks rules, each
    in file order; the first classification rule that matches sets RuleRole (in the AURuleRoles
    casing, so helper is reported as Helper), and the first ignore rule that matches sets Ignored.
    When MatchSection is Customer (including a retained customer target), PowerStacks rules are
    skipped (D38). Every condition a rule gives must match: exeName and locationClass are path-level
    facts; companyName and fileDescription use verified facts only, never PathEvidence (D30).
.PARAMETER Facts
    The executable facts.
.PARAMETER Mappings
    The whole Get-AUMappings result (F18).
.PARAMETER MatchSection
    The section that matched the executable's identity: Customer, PowerStacks, Retained, or None.
#>
    param (
        [pscustomobject]$Facts,
        [pscustomobject]$Mappings,
        [string]$MatchSection
    )

    $Result = [pscustomobject]@{ RuleRole = $null; ClassificationRuleId = $null; Ignored = $false; IgnoreRuleId = $null }
    $Verified = ($Facts.FactsVerified -eq $true)
    $Sections = @($Mappings.Mappings.customer)
    if ($MatchSection -ne 'Customer') { $Sections += $Mappings.Mappings.powerStacks }

    foreach ($Section in $Sections)
    {
        foreach ($Rule in (Get-AUClassificationCandidates $Section.classificationRules $Facts.ExeName))
        {
            if ($null -eq $Rule -or $null -eq $Rule.when) { continue }
            $IsIgnore = ($Rule.type -ceq 'ignore')
            if ($IsIgnore -and $Result.Ignored) { continue }
            if (-not $IsIgnore -and ($Rule.type -cne 'classification' -or $Result.ClassificationRuleId)) { continue }

            $Matched = $true
            foreach ($Condition in $Rule.when.PSObject.Properties)
            {
                $Pattern = [string]$Condition.Value
                switch -CaseSensitive ($Condition.Name)
                {
                    'exeName' { $Matched = Test-AUTextPattern $Facts.ExeName $Pattern }
                    'locationClass' { $Matched = [string]::Equals([string]$Facts.LocationClass, $Pattern, [StringComparison]::OrdinalIgnoreCase) }
                    'companyName' { $Matched = $Verified -and (Test-AUTextPattern ([string]$Facts.FileCompanyName) $Pattern) }
                    'fileDescription' { $Matched = $Verified -and (Test-AUTextPattern ([string]$Facts.FileDescription) $Pattern) }
                    default { $Matched = $false }
                }
                if (-not $Matched) { break }
            }
            if (-not $Matched) { continue }

            if ($IsIgnore)
            {
                $Result.Ignored = $true
                $Result.IgnoreRuleId = [string]$Rule.id
            }
            else
            {
                # The validator accepts any casing; report the role in its one canonical casing.
                $Role = [string]$Rule.role
                foreach ($Name in $script:AURuleRoles) { if ([string]::Equals($Role, $Name, [StringComparison]::OrdinalIgnoreCase)) { $Role = $Name } }
                $Result.RuleRole = $Role
                $Result.ClassificationRuleId = [string]$Rule.id
            }
        }
    }
    return $Result
}#endfunction

# Retained targets and install status (D7, D17, D30, D38). A stored target keeps an executable mapped
# after the evidence that matched it is gone, so NotInstalled stays possible.
$script:AUTargetSections = @('Customer', 'PowerStacks')

function Get-AUStoredTargetSection
{
    <#
.SYNOPSIS
    Returns the section (Customer or PowerStacks) of a stored target that still counts, else $null.
.DESCRIPTION
    A stored target counts when it has a section, a rule ID, and a target pattern, and its rule ID is
    in RuleIds, which always holds the reserved ps-resolve-* IDs (F11). When the customer's rules are
    unavailable this run (the file is Invalid or TooLarge), a stored customer target counts as it is,
    so a broken file doesn't move apps back to PowerStacks matches (D41, D45).
.PARAMETER StoredTarget
    The entry's stored target, or $null.
.PARAMETER Mappings
    The whole Get-AUMappings result (F18).
.PARAMETER CustomerRulesUnavailable
    True when the customer file is present but Invalid or TooLarge.
#>
    param (
        [pscustomobject]$StoredTarget,
        [pscustomobject]$Mappings,
        [bool]$CustomerRulesUnavailable
    )

    if ($null -eq $StoredTarget) { return $null }
    $Text = ([string]$StoredTarget.Section).Trim()
    $Section = $null
    foreach ($Name in $script:AUTargetSections) { if ([string]::Equals($Text, $Name, [StringComparison]::OrdinalIgnoreCase)) { $Section = $Name } }
    $RuleId = ([string]$StoredTarget.MatchRuleId).Trim()
    if (-not $Section -or -not $RuleId -or [string]::IsNullOrWhiteSpace([string]$StoredTarget.TargetPattern)) { return $null }
    if ($Section -eq 'Customer' -and $CustomerRulesUnavailable) { return $Section }
    if ($null -ne $Mappings -and $null -ne $Mappings.RuleIds -and $Mappings.RuleIds.Contains($RuleId)) { return $Section }
    return $null
}#endfunction

function Test-AUSameTarget
{
    <#
.SYNOPSIS
    Tests whether two targets name the same app: the same target pattern and publisher, ignoring case.
.PARAMETER First
    A target or stored target.
.PARAMETER Second
    A target or stored target.
#>
    param (
        [pscustomobject]$First,
        [pscustomobject]$Second
    )

    return ([string]::Equals(([string]$First.TargetPattern).Trim(), ([string]$Second.TargetPattern).Trim(), [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals(([string]$First.TargetPublisher).Trim(), ([string]$Second.TargetPublisher).Trim(), [StringComparison]::OrdinalIgnoreCase))
}#endfunction

function Test-AUSameApp
{
    <#
.SYNOPSIS
    Tests whether two targets resolved to the same installed app: the same ResolvedAppName,
    ProductCode, or PackageFamily, ignoring case. A blank value never matches.
.PARAMETER First
    A target or stored target.
.PARAMETER Second
    A target or stored target.
#>
    param (
        [pscustomobject]$First,
        [pscustomobject]$Second
    )

    foreach ($Name in @('ResolvedAppName', 'ProductCode', 'PackageFamily'))
    {
        $A = ([string]$First.$Name).Trim()
        $B = ([string]$Second.$Name).Trim()
        if ($A -and $B -and [string]::Equals($A, $B, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}#endfunction

function Resolve-AUTarget
{
    <#
.SYNOPSIS
    Decides an executable's final target: this run's identity match or the entry's stored target.
.DESCRIPTION
    Order (D38): a customer identity match, then a stored customer target, then a PowerStacks identity
    match, then a stored PowerStacks target, then None. A stored target counts only while its rule ID
    exists (Get-AUStoredTargetSection); it returns with MatchSection Retained and RetainedFrom
    (Customer or PowerStacks). A PowerStacks identity match replaces a stored PowerStacks target only
    when its evidence is Verified and, for a stored target a D47 step chose (ps-resolve-*), only when
    it resolved to the same app (Test-AUSameApp), so a match that lands on a sibling after the chosen
    app is removed keeps the chosen app; otherwise the stored target wins, and a conflict with a
    different target is logged (D17, D30, F11, F15). A customer identity match always wins, even on
    current-file evidence, and keeps that EvidenceUsed. When this run's match names the same app as the stored
    target but resolved to no installed app, the stored ResolvedAppName (the last concrete
    DisplayName), ProductCode, and PackageFamily fill the blanks. A None result keeps the identity's
    CandidateTargets. Returns Resolve-AUIdentity's fields plus RetainedFrom ($null unless Retained).
.PARAMETER Identity
    The Resolve-AUIdentity result.
.PARAMETER StoredTarget
    The entry's stored target (ConvertTo-AUStoredTarget shape), or $null.
.PARAMETER Mappings
    The whole Get-AUMappings result (F18).
.PARAMETER CustomerRulesUnavailable
    Set when the customer file is present but Invalid or TooLarge (D41, D45).
#>
    param (
        [pscustomobject]$Identity,
        [pscustomobject]$StoredTarget,
        [pscustomobject]$Mappings,
        [switch]$CustomerRulesUnavailable
    )

    $StoredSection = Get-AUStoredTargetSection $StoredTarget $Mappings $CustomerRulesUnavailable.IsPresent
    $IdentitySection = 'None'
    if ($null -ne $Identity -and $Identity.MatchSection -cin $script:AUTargetSections) { $IdentitySection = $Identity.MatchSection }

    $FromIdentity = {
        if ($null -eq $Identity)
        {
            return [pscustomobject]@{
                TargetPattern           = $null
                TargetPublisher         = $null
                ResolvedAppName         = $null
                ProductCode             = $null
                PackageFamily           = $null
                MatchSection            = 'None'
                MatchRuleId             = $null
                RuleType                = $null
                InstalledStateDependent = $false
                EvidenceUsed            = 'None'
                CandidateTargets        = $null
                RetainedFrom            = $null
            }
        }
        $Result = [pscustomobject]@{
            TargetPattern           = $Identity.TargetPattern
            TargetPublisher         = $Identity.TargetPublisher
            ResolvedAppName         = $Identity.ResolvedAppName
            ProductCode             = $Identity.ProductCode
            PackageFamily           = $Identity.PackageFamily
            MatchSection            = $IdentitySection
            MatchRuleId             = $Identity.MatchRuleId
            RuleType                = $Identity.RuleType
            InstalledStateDependent = $Identity.InstalledStateDependent
            EvidenceUsed            = $Identity.EvidenceUsed
            CandidateTargets        = $Identity.CandidateTargets
            RetainedFrom            = $null
        }
        if ($IdentitySection -ne 'None' -and $StoredSection -eq $IdentitySection -and [string]::IsNullOrWhiteSpace([string]$Result.ResolvedAppName) -and (Test-AUSameTarget $Result $StoredTarget))
        {
            foreach ($Name in @('ResolvedAppName', 'ProductCode', 'PackageFamily'))
            {
                if ([string]::IsNullOrWhiteSpace([string]$Result.$Name) -and -not [string]::IsNullOrWhiteSpace([string]$StoredTarget.$Name)) { $Result.$Name = [string]$StoredTarget.$Name }
            }
        }
        return $Result
    }
    $FromStored = {
        $RuleType = [string]$StoredTarget.RuleType
        $Evidence = [string]$StoredTarget.EvidenceUsed
        if (-not $Evidence) { $Evidence = 'None' }
        return [pscustomobject]@{
            TargetPattern           = [string]$StoredTarget.TargetPattern
            TargetPublisher         = [string]$StoredTarget.TargetPublisher
            ResolvedAppName         = $(if ($StoredTarget.ResolvedAppName) { [string]$StoredTarget.ResolvedAppName } else { $null })
            ProductCode             = $(if ($StoredTarget.ProductCode) { [string]$StoredTarget.ProductCode } else { $null })
            PackageFamily           = $(if ($StoredTarget.PackageFamily) { [string]$StoredTarget.PackageFamily } else { $null })
            MatchSection            = 'Retained'
            MatchRuleId             = ([string]$StoredTarget.MatchRuleId).Trim()
            RuleType                = $(if ($RuleType) { $RuleType } else { $null })
            InstalledStateDependent = ($RuleType -cin @('ownership', 'arpCompare'))
            EvidenceUsed            = $Evidence
            CandidateTargets        = $null
            RetainedFrom            = $StoredSection
        }
    }

    if ($IdentitySection -eq 'Customer') { return (& $FromIdentity) }
    if ($StoredSection -eq 'Customer') { return (& $FromStored) }
    if ($IdentitySection -eq 'PowerStacks')
    {
        if ($StoredSection -ne 'PowerStacks') { return (& $FromIdentity) }
        # A target a D47 step chose among siblings (ps-resolve-*) is replaced only by a match to the
        # same app. A match that lands on a sibling because the chosen app is gone keeps it (F11, D17).
        $ChosenAmongSiblings = (([string]$StoredTarget.MatchRuleId).Trim() -like 'ps-resolve-*')
        if ($Identity.EvidenceUsed -ceq 'Verified' -and (-not $ChosenAmongSiblings -or (Test-AUSameApp $Identity $StoredTarget))) { return (& $FromIdentity) }
        # Weaker evidence never replaces a stored PowerStacks target (D30, F15).
        $Same = Test-AUSameTarget $Identity $StoredTarget
        if ($Same -and $Identity.ResolvedAppName -and $StoredTarget.ResolvedAppName)
        {
            $Same = [string]::Equals(([string]$Identity.ResolvedAppName).Trim(), ([string]$StoredTarget.ResolvedAppName).Trim(), [StringComparison]::OrdinalIgnoreCase)
        }
        if (-not $Same)
        {
            Write-CMTraceLog -Message "App Usage: kept stored target $($StoredTarget.MatchRuleId) ($($StoredTarget.TargetPattern)) over $($Identity.EvidenceUsed) match $($Identity.MatchRuleId) ($($Identity.TargetPattern))." -Component 'AppUsage'
        }
        return (& $FromStored)
    }
    if ($StoredSection -eq 'PowerStacks') { return (& $FromStored) }
    return (& $FromIdentity)
}#endfunction

function ConvertTo-AUStoredTarget
{
    <#
.SYNOPSIS
    Returns the target to store in the ledger entry, or $null when it must not be written back (F16).
.DESCRIPTION
    Written back: a customer match; a PowerStacks match that is Verified, ownership, or arpCompare;
    and a Retained target, stored with its original section. Not written back: an unverified
    PowerStacks identity match (D30), and None. Section is Customer or PowerStacks, never Retained.
    Returns Section, MatchRuleId, RuleType, TargetPattern, TargetPublisher, ResolvedAppName,
    ProductCode, PackageFamily, and EvidenceUsed.
.PARAMETER Target
    The Resolve-AUTarget result.
#>
    param (
        [pscustomobject]$Target
    )

    if ($null -eq $Target) { return $null }
    $Section = $null
    switch -CaseSensitive ([string]$Target.MatchSection)
    {
        'Customer' { $Section = 'Customer' }
        'PowerStacks'
        {
            if ($Target.EvidenceUsed -ceq 'Verified' -or $Target.RuleType -cin @('ownership', 'arpCompare')) { $Section = 'PowerStacks' }
        }
        'Retained'
        {
            if ($Target.RetainedFrom -cin $script:AUTargetSections) { $Section = [string]$Target.RetainedFrom }
        }
    }
    if (-not $Section -or [string]::IsNullOrWhiteSpace([string]$Target.MatchRuleId) -or [string]::IsNullOrWhiteSpace([string]$Target.TargetPattern)) { return $null }

    return [pscustomobject][ordered]@{
        Section         = $Section
        MatchRuleId     = [string]$Target.MatchRuleId
        RuleType        = $Target.RuleType
        TargetPattern   = [string]$Target.TargetPattern
        TargetPublisher = $Target.TargetPublisher
        ResolvedAppName = $Target.ResolvedAppName
        ProductCode     = $Target.ProductCode
        PackageFamily   = $Target.PackageFamily
        EvidenceUsed    = $Target.EvidenceUsed
    }
}#endfunction

function Get-AUTargetKeys
{
    <#
.SYNOPSIS
    Returns the values Test-AUTargetApp compares an installed app with, computed once per target.
.DESCRIPTION
    ProductCode and PackageFamily (trimmed), the TargetPattern and TargetPublisher wildcard patterns,
    and, for an ownership or arpCompare target (whose patterns are escaped exact values), the
    normalized name and publisher keys (Get-AUNormalizedText) of its ResolvedAppName (or the unescaped
    TargetPattern) and TargetPublisher. The keys are blank for other targets.
    A target a D47 step chose among siblings (MatchRuleId ps-resolve-*) names one app, so its name
    pattern is its ResolvedAppName, matched literally, even when its rule's pattern is wider. It gets
    the normalized name key too (an identity rule's target keeps its publisher pattern, PublisherLike),
    plus TagKey, the architecture and bracketed tags of its name (Get-AUNameTags): siblings such as
    Contoso Tool and Contoso Tool (x86) normalize the same, so the normalized match also needs the
    same tags, which a renamed version update keeps (F11).
.PARAMETER Target
    The Resolve-AUTarget result.
#>
    param (
        [pscustomobject]$Target
    )

    # The keys depend only on these target fields, so each set is computed once per run (Task 21).
    # Callers only read the result.
    $Signature = @([string]$Target.ProductCode, [string]$Target.PackageFamily, [string]$Target.TargetPattern, [string]$Target.TargetPublisher,
        [string]($null -eq $Target.TargetPattern), [string]($null -eq $Target.TargetPublisher), [string]$Target.MatchRuleId, [string]$Target.ResolvedAppName,
        [string]($Target.InstalledStateDependent -eq $true), [string]$Target.RuleType) -join [string][char]31
    $Keys = $null
    if ($null -ne $script:AUTargetKeysCache -and $script:AUTargetKeysCache.TryGetValue($Signature, [ref]$Keys)) { return $Keys }

    $Keys = [pscustomobject]@{
        Code             = ([string]$Target.ProductCode).Trim()
        Family           = ([string]$Target.PackageFamily).Trim()
        NamePattern      = $Target.TargetPattern
        PublisherPattern = $Target.TargetPublisher
        NameKey          = ''
        PublisherKey     = ''
        PublisherLike    = $false
        TagKey           = $null
    }
    $RuleId = ([string]$Target.MatchRuleId).Trim()
    $Resolved = ([string]$Target.ResolvedAppName).Trim()
    $ChosenAmongSiblings = ($Resolved -and $RuleId -like 'ps-resolve-*')
    if ($ChosenAmongSiblings) { $Keys.NamePattern = ConvertTo-AUWildcardLiteral $Resolved }
    $ExactTarget = ($Target.InstalledStateDependent -eq $true -or $Target.RuleType -cin @('ownership', 'arpCompare'))
    if ($ExactTarget -or $ChosenAmongSiblings)
    {
        $Name = $Resolved
        if (-not $Name) { $Name = [Management.Automation.WildcardPattern]::Unescape([string]$Keys.NamePattern) }
        $Keys.NameKey = Get-AUNormalizedText $Name -Kind Name
        if ($ExactTarget) { $Keys.PublisherKey = Get-AUNormalizedText ([Management.Automation.WildcardPattern]::Unescape([string]$Keys.PublisherPattern)) -Kind Publisher }
        elseif ($null -ne $Keys.PublisherPattern) { $Keys.PublisherLike = $true }
        if ($ChosenAmongSiblings) { $Keys.TagKey = Get-AUNameTags $Resolved }
    }
    if ($null -ne $script:AUTargetKeysCache) { $script:AUTargetKeysCache[$Signature] = $Keys }
    return $Keys
}#endfunction

function Get-AUNameTags
{
    <#
.SYNOPSIS
    Returns the architecture and bracketed tags of an app name as one comparable string.
.DESCRIPTION
    The tags Get-AUNormalizedText drops: architecture tokens such as x86, x64, 32-bit, and arm64
    anywhere in the name, and the content of each (...) or [...] group, lowercased, with version
    tokens removed and punctuation as spaces. Sorted and joined, so Contoso Tool (x86) 1.0 and Contoso
    Tool (x86) 1.1 give the same tags, and Contoso Tool gives none. Results are cached for the run.
.PARAMETER Text
    The app name.
#>
    param (
        [AllowNull()][string]$Text
    )

    $Key = 'Tags|' + $Text
    $Cached = $null
    if ($script:AUNormalizedText.TryGetValue($Key, [ref]$Cached)) { return $Cached }

    $Value = ([string]$Text).ToLowerInvariant()
    $Tags = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach ($Token in ($Value -split '[\s()\[\],;:]+'))
    {
        if ($Token -and $Token -in $script:AUArchTokens) { [void]$Tags.Add('a:' + $Token) }
    }
    foreach ($Group in [regex]::Matches($Value, '\(([^)]*)\)|\[([^\]]*)\]'))
    {
        $Content = $Group.Groups[1].Value + $Group.Groups[2].Value
        $Kept = @($Content -split '\s+' | Where-Object { $_ -and $_ -notmatch '^v?\d+([.,_]\d+)+[a-z]?$' })
        $Content = [regex]::Replace(($Kept -join ' '), '[^\p{L}\p{Nd}+#]+', ' ').Trim()
        if ($Content) { [void]$Tags.Add('b:' + $Content) }
    }
    $Result = @($Tags) -join '|'
    $script:AUNormalizedText[$Key] = $Result
    return $Result
}#endfunction

function Test-AUTargetApp
{
    <#
.SYNOPSIS
    Tests whether an installed app is the target app, ignoring scope.
.DESCRIPTION
    True when its ProductCode or PackageFamily equals the target's, its DisplayName and Publisher
    match TargetPattern and TargetPublisher, or (ownership and arpCompare targets, and targets a D47
    step chose, which also need the same architecture and bracketed tags; see Get-AUTargetKeys) its
    normalized DisplayName and Publisher equal the target's keys, so an update that renames the
    entry, Contoso Alpha 1.0 to Contoso Alpha 1.1, still counts. The one definition for
    Get-AUInstallStatus and Test-AUMainExe.
.PARAMETER App
    The installed-app entry.
.PARAMETER Keys
    The Get-AUTargetKeys result.
#>
    param (
        [pscustomobject]$App,
        [pscustomobject]$Keys
    )

    if ($null -eq $App) { return $false }
    if ($Keys.Code -and [string]::Equals(([string]$App.ProductCode).Trim(), $Keys.Code, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($Keys.Family -and [string]::Equals(([string]$App.PackageFamily).Trim(), $Keys.Family, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $AppName = ([string]$App.DisplayName).Trim()
    if ($AppName -and $null -ne $Keys.NamePattern -and $null -ne $Keys.PublisherPattern)
    {
        $AppPublisher = ([string]$App.Publisher).Trim()
        # A stored pattern that won't parse (one escaped before ConvertTo-AUWildcardLiteral existed)
        # never throws: it's compared exactly with the text it was escaped from.
        try { $Hit = ($AppName -like [string]$Keys.NamePattern -and $AppPublisher -like [string]$Keys.PublisherPattern) }
        catch
        {
            $Hit = ([string]::Equals($AppName, [Management.Automation.WildcardPattern]::Unescape([string]$Keys.NamePattern), [StringComparison]::OrdinalIgnoreCase) -and
                [string]::Equals($AppPublisher, [Management.Automation.WildcardPattern]::Unescape([string]$Keys.PublisherPattern), [StringComparison]::OrdinalIgnoreCase))
        }
        if ($Hit) { return $true }
    }
    if (-not $Keys.NameKey) { return $false }
    if ($Keys.PublisherKey) { $SamePublisher = ((Get-AUNormalizedText ([string]$App.Publisher) -Kind Publisher) -ceq $Keys.PublisherKey) }
    elseif ($Keys.PublisherLike)
    {
        try { $SamePublisher = (([string]$App.Publisher).Trim() -like [string]$Keys.PublisherPattern) }
        catch { $SamePublisher = $false }
    }
    else { return $false }
    if (-not $SamePublisher -or (Get-AUNormalizedText ([string]$App.DisplayName) -Kind Name) -cne $Keys.NameKey) { return $false }
    # A target a D47 step chose among siblings also needs the same architecture and bracketed tags.
    if ($null -ne $Keys.TagKey -and (Get-AUNameTags ([string]$App.DisplayName)) -cne $Keys.TagKey) { return $false }
    return $true
}#endfunction

function Get-AUInstallStatus
{
    <#
.SYNOPSIS
    Returns an executable entry's install status: Installed, NotInstalled, Unknown, or Unmatched (D7, D17).
.DESCRIPTION
    Unmatched only when there's no target (MatchSection None). The target's scope is Machine plus the
    entry's user (F30). Installed when an installed app in that scope matches the target: its
    DisplayName and Publisher match TargetPattern and TargetPublisher, or its ProductCode or
    PackageFamily equals the target's, so an updated app still counts. An ownership or arpCompare
    target holds the exact DisplayName it was matched to, so for those an app also counts when its
    normalized DisplayName and Publisher (Get-AUNormalizedText, the arpCompare comparison) equal the
    target's ResolvedAppName and publisher: an update that renames the entry, Contoso Alpha 1.0 to
    Contoso Alpha 1.1, still counts. An app with no scope counts as in scope. Otherwise NotInstalled
    only when Machine was Read and the user's scope was Read or Deleted (the profile is gone from
    ProfileList); else Unknown. A blank UserSid leaves the user's scope unknown, so Unknown; a SID
    missing from ScopeRead counts as Unread (F29). A mapped executable whose target is absent stays
    mapped.
.PARAMETER Target
    The Resolve-AUTarget result.
.PARAMETER InstalledApps
    The installed-app entries, with their internal Scope (Machine or a SID).
.PARAMETER ScopeRead
    Machine or a SID to Read, Unread, or Deleted.
.PARAMETER UserSid
    The entry's user SID.
.PARAMETER AppIndex
    New-AUAppIndex of InstalledApps, built once per run; built here when it isn't given. Only the
    apps it gives for the target (Get-AUTargetAppCandidates) are checked.
#>
    param (
        [pscustomobject]$Target,
        [object[]]$InstalledApps,
        [hashtable]$ScopeRead,
        [string]$UserSid,
        [pscustomobject]$AppIndex
    )

    if ($null -eq $Target -or $Target.MatchSection -cnotin @('Customer', 'PowerStacks', 'Retained')) { return 'Unmatched' }
    $Sid = ([string]$UserSid).Trim()
    $Keys = Get-AUTargetKeys $Target
    if ($null -eq $AppIndex) { $AppIndex = New-AUAppIndex $InstalledApps }

    foreach ($App in (Get-AUTargetAppCandidates $AppIndex $Keys))
    {
        $Scope = ([string]$App.Scope).Trim()
        if ($Scope -and $Scope -ne 'Machine' -and -not ($Sid -and [string]::Equals($Scope, $Sid, [StringComparison]::OrdinalIgnoreCase))) { continue }
        if (Test-AUTargetApp $App $Keys) { return 'Installed' }
    }

    $StateOf = {
        param ([string]$Key)
        if ($null -eq $ScopeRead) { return 'Unread' }
        foreach ($Name in $ScopeRead.Keys)
        {
            if ([string]::Equals([string]$Name, $Key, [StringComparison]::OrdinalIgnoreCase)) { return [string]$ScopeRead[$Name] }
        }
        return 'Unread'
    }
    if ((& $StateOf 'Machine') -ne 'Read') { return 'Unknown' }
    # The target may be a per-user install, and with no SID that scope can't have been read.
    if (-not $Sid -or (& $StateOf $Sid) -notin @('Read', 'Deleted')) { return 'Unknown' }
    return 'NotInstalled'
}#endfunction

# Role (D32). There's no System role: SYSTEM is a user property, handled by credited use (F21).
$script:AUInstallerLocations = @('Temp', 'Download', 'ManagementCache')

function Test-AUMainExe
{
    <#
.SYNOPSIS
    Tests whether an executable is its target app's main executable (F19).
.DESCRIPTION
    True when the target came from an identity rule: the rule's exeName named this executable, and a
    retained target keeps its rule type. True for a Package-kind entry (a Store or MSIX package: no
    ExeName, a PackageFamily), whose package identity is the app. Otherwise true when the build is
    verified and its run path equals the DisplayIcon file of an installed app that is the target app
    (Test-AUTargetApp, the same test as Get-AUInstallStatus). The paths are compared ignoring case,
    quotes, and the icon index.
.PARAMETER Facts
    The executable facts.
.PARAMETER Target
    The Resolve-AUTarget result.
.PARAMETER InstalledApps
    The installed-app entries.
.PARAMETER AppIndex
    New-AUAppIndex of InstalledApps, built once per run; built here when it isn't given. Only the
    apps whose DisplayIcon file is the run path (its ByIconFile lookup) are checked.
#>
    param (
        [pscustomobject]$Facts,
        [pscustomobject]$Target,
        [object[]]$InstalledApps,
        [pscustomobject]$AppIndex
    )

    if ($Target.RuleType -ceq 'identity') { return $true }
    # A Package-kind entry (Store or MSIX) has no exe name, only its package identity, which is the
    # app itself, so it is its own main executable.
    if ([string]::IsNullOrWhiteSpace([string]$Facts.ExeName) -and -not [string]::IsNullOrWhiteSpace([string]$Facts.PackageFamily)) { return $true }
    if ($Facts.FactsVerified -ne $true) { return $false }
    $RunPath = ([string]$Facts.RunPath).Trim().Replace('/', '\')
    if ($RunPath.StartsWith('\\?\')) { $RunPath = $RunPath.Substring(4) }
    if (-not $RunPath) { return $false }
    $Leaf = $RunPath.Substring($RunPath.LastIndexOf('\') + 1)
    if (-not $Leaf) { return $false }
    if ($null -eq $AppIndex) { $AppIndex = New-AUAppIndex $InstalledApps }
    $Keys = $null

    # The index holds each app by its DisplayIcon file, normalized as RunPath is here.
    foreach ($App in (Get-AUIndexedApps $AppIndex $AppIndex.ByIconFile $RunPath))
    {
        if ($null -eq $Keys) { $Keys = Get-AUTargetKeys $Target }
        if (Test-AUTargetApp $App $Keys) { return $true }
    }
    return $false
}#endfunction

function Get-AURole
{
    <#
.SYNOPSIS
    Returns an executable's role: Installer, the classification role, Service, CLI, App, Helper, or Unmatched.
.DESCRIPTION
    The first that applies, in order: Installer when it ran from a Temp, Download, or ManagementCache
    location; the classification rule's role; Service for a service binary; CLI for the console
    subsystem; App for a matched executable that is its target's main executable (Test-AUMainExe,
    F19; a matched Store or MSIX package always is); Helper for any other matched executable; else Unmatched. Matched means the target's
    MatchSection is Customer, PowerStacks, or Retained, so a retained target is still App or Helper
    (D17, F20). A matched executable whose subsystem isn't known (a Store package, or a file that's
    gone) is treated as GUI, so it stays App or Helper. There's no System role, and the user type
    isn't an input (D32, F21).
.PARAMETER Facts
    The executable facts.
.PARAMETER Target
    The Resolve-AUTarget result.
.PARAMETER Classification
    The Get-AUClassification result.
.PARAMETER InstalledApps
    The installed-app entries, for the target app's DisplayIcon.
.PARAMETER AppIndex
    New-AUAppIndex of InstalledApps, passed to Test-AUMainExe.
#>
    param (
        [pscustomobject]$Facts,
        [pscustomobject]$Target,
        [pscustomobject]$Classification,
        [object[]]$InstalledApps,
        [pscustomobject]$AppIndex
    )

    if ([string]$Facts.LocationClass -in $script:AUInstallerLocations) { return 'Installer' }
    if ($null -ne $Classification -and -not [string]::IsNullOrWhiteSpace([string]$Classification.RuleRole)) { return [string]$Classification.RuleRole }
    if ($Facts.IsServiceBinary -eq $true) { return 'Service' }
    if ([string]::Equals([string]$Facts.Subsystem, 'Console', [StringComparison]::OrdinalIgnoreCase)) { return 'CLI' }
    if ($null -eq $Target -or $Target.MatchSection -cnotin @('Customer', 'PowerStacks', 'Retained')) { return 'Unmatched' }
    if (Test-AUMainExe $Facts $Target $InstalledApps $AppIndex) { return 'App' }
    return 'Helper'
}#endfunction

# Credited use (D23, D32): the one definition of "used". The ledger, the per-app summary, and the
# per-executable output all call these two functions, and nothing else decides use (F5).
function Test-AUFocusRecord
{
    <#
.SYNOPSIS
    Tests whether a usage record has credited focus or input.
.DESCRIPTION
    True when the user is interactive (Test-AUInteractiveUserType) and the record's focus or input
    seconds are at or above the floor. A record with no focus and no input is never credited, even
    when the floor is 0 or unset, so a missing setting can't turn background runs into use (F3).
    The ledger uses this to set LastFocusOrInputTime.
.PARAMETER UserType
    The record's user type, from Get-AUUserType.
.PARAMETER FocusSeconds
    The record's focus seconds (SRUM InFocusS).
.PARAMETER InputSeconds
    The record's input seconds (SRUM UserInputS).
.PARAMETER MinFocusSeconds
    The floor, passed by the caller from $MinFocusSecondsForUse. Never read from the global here.
#>
    param (
        [string]$UserType,
        [double]$FocusSeconds,
        [double]$InputSeconds,
        [double]$MinFocusSeconds
    )

    if (-not (Test-AUInteractiveUserType $UserType)) { return $false }
    $Seconds = [Math]::Max($FocusSeconds, $InputSeconds)
    return ($Seconds -gt 0 -and $Seconds -ge $MinFocusSeconds)
}#endfunction

function Get-AUDerivedUse
{
    <#
.SYNOPSIS
    Derives an entry's credited use from its stored dates.
.DESCRIPTION
    LastUsedTime is the entry's LastInteractiveRunTime when the role is CLI (a command-line tool's
    focus goes to the terminal, so any interactive run counts), otherwise its LastFocusOrInputTime.
    It's $null when the entry's current user type isn't interactive, so a corrected user type
    re-evaluates history (F6). Derived when results are produced, not when records are merged, so a
    role change re-evaluates history too (D13). The role is compared with -ceq because Get-AURole
    returns canonical casing.
.PARAMETER Entry
    The ledger entry, with LastFocusOrInputTime, LastInteractiveRunTime, and LastRanTime (UTC
    DateTimes or $null).
.PARAMETER Role
    The entry's role, from Get-AURole.
.PARAMETER UserType
    The entry's current user type, from Get-AUUserType.
.OUTPUTS
    An object with LastUsedTime, LastRanTime, and HasCreditedUse.
#>
    param (
        [pscustomobject]$Entry,
        [string]$Role,
        [string]$UserType
    )

    $LastUsedTime = $null
    $LastRanTime = $null
    if ($null -ne $Entry)
    {
        $LastRanTime = $Entry.LastRanTime
        if (Test-AUInteractiveUserType $UserType)
        {
            if ($Role -ceq 'CLI') { $LastUsedTime = $Entry.LastInteractiveRunTime }
            else { $LastUsedTime = $Entry.LastFocusOrInputTime }
        }
    }

    return [pscustomobject]@{
        LastUsedTime   = $LastUsedTime
        LastRanTime    = $LastRanTime
        HasCreditedUse = ($null -ne $LastUsedTime)
    }
}#endfunction

# Ledger (D13, D23, F6 to F10). C:\Windows\AppUsage_<Serial>.json keeps each user's usage of each exe
# build across runs, keyed UserSid|ExeInfo, because SRUM keeps only about 30 to 60 days. In memory,
# every date is a Utc DateTime or $null. The caller holds the run lock around read, merge, and write.
$script:AULedgerSchemaVersion = 1
$script:AULedgerDateFormat = "yyyy'-'MM'-'dd'T'HH':'mm':'ss'.'fffffffK"
$script:AULedgerLastTimeFields = @('LastFocusOrInputTime', 'LastInteractiveRunTime', 'LastRanTime')
# The ledger holds every user's activity, so only SYSTEM and Administrators may open it (D18).
$script:AULedgerAclSids = @('S-1-5-18', 'S-1-5-32-544')
$script:AUStoredTargetFields = @('Section', 'MatchRuleId', 'RuleType', 'TargetPattern', 'TargetPublisher', 'ResolvedAppName', 'ProductCode', 'PackageFamily', 'EvidenceUsed')

function New-AULedger
{
    <#
.SYNOPSIS
    Returns an empty ledger: no entries, no WatchingSince, no status, and writable.
.DESCRIPTION
    Entries is a hashtable keyed UserSid|ExeInfo, ignoring case. Status holds status tokens (Task 15's
    list), for example LedgerReset. Writable is false only when an unreadable ledger file couldn't be
    moved aside, so Write-AULedger never overwrites it.
#>
    return [pscustomobject]@{
        Entries       = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
        WatchingSince = $null
        Status        = [string[]]@()
        Writable      = $true
    }
}#endfunction

function New-AULedgerEntry
{
    <#
.SYNOPSIS
    Returns a new ledger entry for one user and exe build, with nothing counted yet.
.DESCRIPTION
    ExeName comes from ConvertFrom-AUExeInfo, so a Store or MSIX package entry has ExeName $null.
    Counted is keyed <epoch>|<AutoIncId> and holds @{ F = focus; I = input; T = end time }.
    FocusTotal is recalculated (Update-AULedgerEntryTotal); it isn't stored in the file.
.PARAMETER UserSid
    The user SID.
.PARAMETER ExeInfo
    The SRUM ExeInfo value.
.PARAMETER ExeName
    The exe name, when the caller already has it (a ledger record); ExeInfo isn't parsed then.
#>
    param (
        [string]$UserSid,
        [string]$ExeInfo,
        [AllowNull()][object]$ExeName
    )

    if (-not $PSBoundParameters.ContainsKey('ExeName')) { $ExeName = (ConvertFrom-AUExeInfo $ExeInfo).ExeName }
    return [pscustomobject]@{
        UserSid                = $UserSid
        ExeInfo                = $ExeInfo
        ExeName                = $ExeName
        FirstSeen              = $null
        Counted                = @{}
        ArchivedFocus          = [double]0
        ArchivedInput          = [double]0
        LastFocusOrInputTime   = $null
        LastInteractiveRunTime = $null
        LastRanTime            = $null
        Facts                  = $null
        FactsVerified          = $false
        StoredTarget           = $null
        FocusTotal             = [double]0
    }
}#endfunction

function Update-AULedgerEntryTotal
{
    <#
.SYNOPSIS
    Recalculates an entry's FocusTotal: ArchivedFocus plus the focus of every counted record.
.PARAMETER Entry
    The ledger entry.
#>
    param (
        [pscustomobject]$Entry
    )

    $Total = [double]$Entry.ArchivedFocus
    foreach ($Record in $Entry.Counted.Values) { $Total += [double]$Record.F }
    $Entry.FocusTotal = $Total
}#endfunction

function Get-AULaterDate
{
    <#
.SYNOPSIS
    Returns the later of two dates, ignoring $null; $null when both are $null.
.PARAMETER First
    A date or $null.
.PARAMETER Second
    A date or $null.
#>
    param (
        [object]$First,
        [object]$Second
    )

    if ($null -eq $First) { return $Second }
    if ($null -eq $Second) { return $First }
    if ($Second -gt $First) { return $Second }
    return $First
}#endfunction

function Get-AUEarlierDate
{
    <#
.SYNOPSIS
    Returns the earlier of two dates, ignoring $null; $null when both are $null.
.PARAMETER First
    A date or $null.
.PARAMETER Second
    A date or $null.
#>
    param (
        [object]$First,
        [object]$Second
    )

    if ($null -eq $First) { return $Second }
    if ($null -eq $Second) { return $First }
    if ($Second -lt $First) { return $Second }
    return $First
}#endfunction

function ConvertFrom-AULedgerDate
{
    <#
.SYNOPSIS
    Parses a date written by Format-AUDate back to a Utc date; $null for null or blank.
.DESCRIPTION
    Throws when the text isn't a ledger date or isn't UTC, so Read-AULedger treats the file as
    unreadable instead of guessing.
.PARAMETER Value
    The JSON value: a string or $null.
#>
    param (
        [object]$Value
    )

    if ($null -eq $Value) { return $null }
    $Text = ([string]$Value).Trim()
    if (-not $Text) { return $null }
    $Date = [datetime]::ParseExact($Text, $script:AULedgerDateFormat, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    if ($Date.Kind -ne [DateTimeKind]::Utc) { throw "Ledger date '$Text' isn't UTC." }
    return $Date
}#endfunction

function Format-AULedgerDate
{
    <#
.SYNOPSIS
    Formats a ledger date with Format-AUDate; $null stays $null, never an empty string.
.PARAMETER Value
    A Utc date or $null. Format-AUDate throws on any other kind.
#>
    param (
        [object]$Value
    )

    if ($null -eq $Value) { return $null }
    return (Format-AUDate $Value)
}#endfunction

function ConvertFrom-AULedgerRecord
{
    <#
.SYNOPSIS
    Rebuilds a ledger entry from its JSON record. Throws when the record is malformed.
.DESCRIPTION
    Counted is rebuilt from its array into a hashtable, and every date into a Utc date. The stored
    target keeps Task 7's shape (ConvertTo-AUStoredTarget). FocusTotal is recalculated.
.PARAMETER Record
    One element of the file's Entries array.
#>
    param (
        [object]$Record
    )

    if ($null -eq $Record -or $Record -isnot [pscustomobject]) { throw 'A ledger entry is not an object.' }
    $ExeInfo = ([string]$Record.ExeInfo).Trim()
    if (-not $ExeInfo) { throw 'A ledger entry has no ExeInfo.' }
    $UserSid = ([string]$Record.UserSid).Trim()
    $Entry = New-AULedgerEntry $UserSid $ExeInfo -ExeName $(if ([string]::IsNullOrWhiteSpace([string]$Record.ExeName)) { $null } else { [string]$Record.ExeName })
    # ConvertFrom-AULedgerDate runs for every date: a ledger date parses here directly (the same
    # format and kind check), and anything else goes to the function, which decides it (Task 21).
    $Invariant = [Globalization.CultureInfo]::InvariantCulture
    $Roundtrip = [Globalization.DateTimeStyles]::RoundtripKind
    $Date = [datetime]::MinValue
    $Entry.FirstSeen = ConvertFrom-AULedgerDate $Record.FirstSeen
    foreach ($Name in $script:AULedgerLastTimeFields)
    {
        $Value = $Record.$Name
        if ($Value -is [string] -and [datetime]::TryParseExact($Value, $script:AULedgerDateFormat, $Invariant, $Roundtrip, [ref]$Date) -and $Date.Kind -eq [DateTimeKind]::Utc) { $Entry.$Name = $Date }
        else { $Entry.$Name = ConvertFrom-AULedgerDate $Value }
    }
    $Entry.ArchivedFocus = [double]$Record.ArchivedFocus
    $Entry.ArchivedInput = [double]$Record.ArchivedInput
    foreach ($Item in @($Record.Counted))
    {
        if ($null -eq $Item) { continue }
        $Key = ([string]$Item.K).Trim()
        if (-not $Key) { throw "A counted record of $ExeInfo has no key." }
        if ($Entry.Counted.ContainsKey($Key)) { throw "Counted record $Key of $ExeInfo appears twice." }
        $Value = $Item.T
        if ($Value -is [string] -and [datetime]::TryParseExact($Value, $script:AULedgerDateFormat, $Invariant, $Roundtrip, [ref]$Date) -and $Date.Kind -eq [DateTimeKind]::Utc) { $Time = $Date }
        else { $Time = ConvertFrom-AULedgerDate $Value }
        $Entry.Counted[$Key] = @{ F = [double]$Item.F; I = [double]$Item.I; T = $Time }
    }
    $Entry.Facts = $Record.Facts
    $Entry.FactsVerified = ($Record.FactsVerified -eq $true)
    if ($null -ne $Record.StoredTarget)
    {
        $Target = [ordered]@{}
        foreach ($Name in $script:AUStoredTargetFields) { $Target[$Name] = $Record.StoredTarget.$Name }
        $Entry.StoredTarget = [pscustomobject]$Target
    }
    Update-AULedgerEntryTotal $Entry
    return $Entry
}#endfunction

function ConvertTo-AULedgerRecord
{
    <#
.SYNOPSIS
    Returns the JSON record for a ledger entry: its stored fields only, dates as Format-AUDate text.
.DESCRIPTION
    Counted becomes an array of { K, F, I, T }, because ConvertFrom-Json in Windows PowerShell 5.1
    rejects object keys that differ only in case. Fields recalculated each run (FocusTotal and the
    run's target, role, and status) aren't written (D13).
.PARAMETER Entry
    The ledger entry.
#>
    param (
        [pscustomobject]$Entry
    )

    $Keys = [string[]]@($Entry.Counted.Keys)
    [Array]::Sort($Keys, [StringComparer]::Ordinal)
    $Counted = [Collections.Generic.List[object]]::new()
    # Format-AULedgerDate runs for every date: a Utc date is formatted here directly (Format-AUDate's
    # format), and anything else goes to the function, which decides it (Task 21).
    $Invariant = [Globalization.CultureInfo]::InvariantCulture
    foreach ($Key in $Keys)
    {
        $Record = $Entry.Counted[$Key]
        $Time = $Record.T
        if ($Time -is [datetime] -and $Time.Kind -eq [DateTimeKind]::Utc) { $Time = $Time.ToString($script:AUUtcDateFormat, $Invariant) }
        else { $Time = Format-AULedgerDate $Time }
        $Counted.Add([ordered]@{ K = $Key; F = [double]$Record.F; I = [double]$Record.I; T = $Time })
    }
    $StoredTarget = $null
    if ($null -ne $Entry.StoredTarget)
    {
        $StoredTarget = [ordered]@{}
        foreach ($Name in $script:AUStoredTargetFields) { $StoredTarget[$Name] = $Entry.StoredTarget.$Name }
    }

    $Result = [ordered]@{
        UserSid       = $Entry.UserSid
        ExeInfo       = $Entry.ExeInfo
        ExeName       = $Entry.ExeName
        FirstSeen     = (Format-AULedgerDate $Entry.FirstSeen)
        Counted       = $Counted.ToArray()
        ArchivedFocus = [double]$Entry.ArchivedFocus
        ArchivedInput = [double]$Entry.ArchivedInput
    }
    foreach ($Name in $script:AULedgerLastTimeFields)
    {
        $Time = $Entry.$Name
        if ($Time -is [datetime] -and $Time.Kind -eq [DateTimeKind]::Utc) { $Result[$Name] = $Time.ToString($script:AUUtcDateFormat, $Invariant) }
        else { $Result[$Name] = Format-AULedgerDate $Time }
    }
    $Result['Facts'] = $Entry.Facts
    $Result['FactsVerified'] = ($Entry.FactsVerified -eq $true)
    $Result['StoredTarget'] = $StoredTarget
    return $Result
}#endfunction

function Set-AUProtectedAcl
{
    <#
.SYNOPSIS
    Gives a file a protected DACL: full control for SYSTEM and Administrators only, inheritance off.
.DESCRIPTION
    The ledger and its moved-aside copies hold every user's SIDs, executables, and usage times, so no
    standard user may read them (D18). Uses the well-known SIDs, never localized names
    (New-AUProtectedSecurity). Pass Stream to set it through an open handle (opened with
    ChangePermissions), so the file is never readable by others while it's written. Throws on
    failure; callers log it and carry on, so a failure to set the DACL never loses ledger data.
.PARAMETER Path
    The file, when Stream isn't given.
.PARAMETER Stream
    An open FileStream for the file.
#>
    param (
        [string]$Path,
        [IO.FileStream]$Stream
    )

    $Security = New-AUProtectedSecurity
    if ($null -ne $Stream) { $Stream.SetAccessControl($Security) }
    else { [IO.File]::SetAccessControl($Path, $Security) }
}#endfunction

function Move-AUFileAtomic
{
    <#
.SYNOPSIS
    Swaps a file over its target: [IO.File]::Replace when the target exists, [IO.File]::Move otherwise.
.DESCRIPTION
    The only swap path for the ledger, so a test can make it fail (F8). Both files must be on the
    same volume. Throws on failure.
.PARAMETER Source
    The file to move.
.PARAMETER Target
    The file to replace or create.
#>
    param (
        [string]$Source,
        [string]$Target
    )

    if ([IO.File]::Exists($Target)) { [IO.File]::Replace($Source, $Target, [NullString]::Value) }
    else { [IO.File]::Move($Source, $Target) }
}#endfunction

function Move-AUUnreadableLedger
{
    <#
.SYNOPSIS
    Moves an unreadable ledger aside to <name>.corrupt-<yyyyMMddHHmmss>.json, bytes intact.
.DESCRIPTION
    The time stamp is UTC. A name already taken gets a -<n> suffix, so an earlier copy is never
    overwritten. The copy gets the ledger's protected DACL (Set-AUProtectedAcl). Returns the new path,
    or $null when the file couldn't be moved. Never throws.
.PARAMETER Path
    The ledger path.
#>
    param (
        [string]$Path
    )

    try
    {
        $Folder = [IO.Path]::GetDirectoryName($Path)
        $Name = [IO.Path]::GetFileNameWithoutExtension($Path)
        $Stamp = [datetime]::UtcNow.ToString('yyyyMMddHHmmss', [Globalization.CultureInfo]::InvariantCulture)
        $Aside = [IO.Path]::Combine($Folder, "$Name.corrupt-$Stamp.json")
        $Number = 1
        while ([IO.File]::Exists($Aside))
        {
            $Aside = [IO.Path]::Combine($Folder, "$Name.corrupt-$Stamp-$Number.json")
            $Number++
        }
        [IO.File]::Move($Path, $Aside)
        Write-CMTraceLog -Message "App Usage: moved the unreadable ledger aside to $Aside." -Component 'AppUsage' -Type 2
        try { Set-AUProtectedAcl -Path $Aside }
        catch { Write-CMTraceLog -Message "App Usage: couldn't restrict access to $Aside`: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3 }
        return $Aside
    }
    catch
    {
        Write-CMTraceLog -Message "App Usage: couldn't move the unreadable ledger $Path aside, so it won't be written this run: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3
        return $null
    }
}#endfunction

function Read-AULedger
{
    <#
.SYNOPSIS
    Reads the ledger file into Entries (keyed UserSid|ExeInfo, ignoring case), WatchingSince, and Status.
.DESCRIPTION
    A missing file gives an empty ledger. A file that can't be read or parsed, or isn't a ledger of
    this schema, is moved aside (Move-AUUnreadableLedger) and never overwritten; the ledger starts
    empty, so it's rebuilt from SRUM, and Status holds LedgerReset. If the file can't be moved aside,
    Writable is false and Write-AULedger leaves it alone. Dates come back as Utc dates. Never throws.
.PARAMETER Path
    The ledger path, C:\Windows\AppUsage_<Serial>.json.
#>
    param (
        [string]$Path
    )

    $Ledger = New-AULedger
    if (-not [IO.File]::Exists($Path)) { return $Ledger }
    try
    {
        $Text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
        $Data = ConvertFrom-Json -InputObject $Text -ErrorAction Stop
        if ($null -eq $Data -or $Data -isnot [pscustomobject] -or $null -eq $Data.PSObject.Properties['Entries']) { throw 'The file is not a ledger.' }
        if ($Data.SchemaVersion -ne $script:AULedgerSchemaVersion) { throw "Ledger schema version '$($Data.SchemaVersion)' isn't $($script:AULedgerSchemaVersion)." }
        $Ledger.WatchingSince = ConvertFrom-AULedgerDate $Data.WatchingSince
        foreach ($Record in @($Data.Entries))
        {
            if ($null -eq $Record) { continue }
            $Entry = ConvertFrom-AULedgerRecord $Record
            $Key = "$($Entry.UserSid)|$($Entry.ExeInfo)"
            if ($Ledger.Entries.ContainsKey($Key)) { throw "Ledger entry $Key appears twice." }
            $Ledger.Entries[$Key] = $Entry
        }
        return $Ledger
    }
    catch
    {
        Write-CMTraceLog -Message "App Usage: the ledger $Path is unreadable, so it's rebuilt from SRUM: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3
        $Ledger = New-AULedger
        $Ledger.Status = [string[]]@('LedgerReset')
        if ($null -eq (Move-AUUnreadableLedger $Path)) { $Ledger.Writable = $false }
        return $Ledger
    }
}#endfunction

function Write-AULedger
{
    <#
.SYNOPSIS
    Writes the ledger: a temp file next to the target, then Move-AUFileAtomic swaps it over the target.
.DESCRIPTION
    The format is ConvertTo-Json -Depth 8 (Windows PowerShell 5.1 defaults to depth 2), UTF-8 without
    a BOM, dates as Format-AUDate strings, and Entries as an array (F7). The temp file is opened
    exclusively, given the protected DACL (Set-AUProtectedAcl) before any data is written, and flushed
    to disk before the swap, so a power loss can't leave a renamed but empty ledger. An existing
    ledger gets the protected DACL before the swap too, because [IO.File]::Replace keeps the
    target's DACL. A DACL failure is logged and the write goes on. On failure the temp file is
    removed and the error is rethrown; the file on disk is unchanged (F8). A ledger that isn't
    Writable (an unreadable file that couldn't be moved aside) isn't written.
.PARAMETER Ledger
    The ledger from Read-AULedger.
.PARAMETER Path
    The ledger path.
#>
    param (
        [pscustomobject]$Ledger,
        [string]$Path
    )

    if ($Ledger.Writable -eq $false)
    {
        Write-CMTraceLog -Message "App Usage: the ledger $Path wasn't written, because the unreadable file there couldn't be moved aside." -Component 'AppUsage' -Type 2
        return
    }

    $Temp = "$Path.tmp"
    try
    {
        $Keys = [string[]]@($Ledger.Entries.Keys)
        [Array]::Sort($Keys, [StringComparer]::Ordinal)
        $Records = New-Object Collections.Generic.List[object]
        foreach ($Key in $Keys) { $Records.Add((ConvertTo-AULedgerRecord $Ledger.Entries[$Key])) }
        $Data = [ordered]@{
            SchemaVersion = $script:AULedgerSchemaVersion
            WatchingSince = (Format-AULedgerDate $Ledger.WatchingSince)
            Entries       = $Records.ToArray()
        }
        $Json = ConvertTo-Json -InputObject $Data -Depth 8 -Compress
        $Bytes = (New-Object Text.UTF8Encoding $false).GetBytes($Json)

        $Rights = [Security.AccessControl.FileSystemRights]::Write -bor [Security.AccessControl.FileSystemRights]::ReadPermissions -bor [Security.AccessControl.FileSystemRights]::ChangePermissions
        $Stream = New-Object IO.FileStream($Temp, [IO.FileMode]::Create, $Rights, [IO.FileShare]::None, 65536, [IO.FileOptions]::None)
        try
        {
            try { Set-AUProtectedAcl -Stream $Stream }
            catch { Write-CMTraceLog -Message "App Usage: couldn't restrict access to $Temp`: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3 }
            $Stream.Write($Bytes, 0, $Bytes.Length)
            $Stream.Flush($true)
        }
        finally { $Stream.Dispose() }

        if ([IO.File]::Exists($Path))
        {
            try { Set-AUProtectedAcl -Path $Path }
            catch { Write-CMTraceLog -Message "App Usage: couldn't restrict access to $Path`: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3 }
        }
        Move-AUFileAtomic -Source $Temp -Target $Path
    }
    catch
    {
        $Failure = $_
        try { if ([IO.File]::Exists($Temp)) { [IO.File]::Delete($Temp) } } catch { }
        Write-CMTraceLog -Message "App Usage: couldn't write the ledger $Path; the file is unchanged: $(Get-AUSafeLogText $Failure.Exception.Message)" -Component 'AppUsage' -Type 3
        throw $Failure
    }
}#endfunction

function Merge-AUSrumRecords
{
    <#
.SYNOPSIS
    Folds one run's SRUM AppTimelineProvider rows into the ledger, by record key, not by time (D23).
.DESCRIPTION
    Each row is keyed <Epoch>|<AutoIncId> inside its entry (UserSid|ExeInfo). A key seen again replaces
    its counted values, so a duplicate adds nothing and an update adds only the difference. A new key
    counts, however old its end time. A counted key missing from this run's rows has aged out only
    when SRUM can no longer hold it: a key from an earlier epoch, or a key of this epoch whose
    AutoIncId is below the lowest AutoIncId in this run's rows (SRUM ages rows out from the low end,
    and new IDs only grow). Its values move into ArchivedFocus and ArchivedInput, and it leaves
    Counted. A missing key of this epoch at or above that lowest ID stays counted, untouched, because
    a lossy repair or a cut-short read can drop rows that a later clean read brings back, and an
    archived key would then count twice. FocusTotal (ArchivedFocus plus the counted focus) is
    unchanged by archiving.
    The last-time fields only move forward: LastRanTime for any user, LastInteractiveRunTime when
    Test-AUInteractiveUserType passes, and LastFocusOrInputTime when Test-AUFocusRecord does (F5, F6).
    FirstSeen is set once, to the earliest end time of the merge that first saw the entry, and
    WatchingSince on the first merge only, to the earliest end time in its rows (F9). With no rows or
    no epoch nothing changes, so a failed SRUM read never archives counted keys (F10; the caller also
    merges only after a successful, non-empty read). Rows without ExeInfo or AutoIncId are skipped.
.PARAMETER Ledger
    The ledger from Read-AULedger.
.PARAMETER Rows
    The Read-AUSrum Timeline rows: UserSid, ExeInfo, AutoIncId, EndTimeUtc, FocusSeconds, InputSeconds.
.PARAMETER Epoch
    The SRUM database epoch (its signature).
.PARAMETER UserTypes
    SID to user type (Get-AUUserType). A SID that's missing counts as Unknown, never interactive.
.PARAMETER MinFocusSeconds
    The focus floor, passed by the caller from $MinFocusSecondsForUse.
.PARAMETER NoArchive
    Archives nothing this run; every counted key stays in Counted. The caller sets it when the SRUM
    copy needed repair (esentutl /p) or the read was incomplete, because rows missing from such a
    read may still exist in SRUM.
.PARAMETER LowestAutoIncId
    The lowest AutoIncId of the whole SRUM read, when Rows is a subset of it (Invoke-AppUsage drops
    Store and MSIX rows when Store inventory is off, D46). The aging-out test then uses the read's
    real low end, not the subset's, so a filtered read archives exactly what an unfiltered one would.
    $null (the default) uses the lowest AutoIncId in Rows.
#>
    param (
        [pscustomobject]$Ledger,
        [object[]]$Rows,
        [string]$Epoch,
        [hashtable]$UserTypes,
        [double]$MinFocusSeconds,
        [switch]$NoArchive,
        [Nullable[long]]$LowestAutoIncId = $null
    )

    $Epoch = ([string]$Epoch).Trim()
    if (-not $Epoch)
    {
        Write-CMTraceLog -Message 'App Usage: no SRUM epoch, so the ledger is unchanged.' -Component 'AppUsage' -Type 2
        return
    }

    $Entries = $Ledger.Entries
    $Present = [Collections.Hashtable]::new([StringComparer]::OrdinalIgnoreCase)
    $OpenFirstSeen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $Interactive = [Collections.Hashtable]::new([StringComparer]::OrdinalIgnoreCase)
    $Earliest = $null
    $LowestId = $null
    $Merged = 0
    $Skipped = 0

    # Inline per-row work: this loop runs once per SRUM row, tens of thousands of times.
    foreach ($Row in @($Rows))
    {
        if ($null -eq $Row) { continue }
        $ExeInfo = ([string]$Row.ExeInfo).Trim()
        $Id = ([string]$Row.AutoIncId).Trim()
        if (-not $ExeInfo -or -not $Id) { $Skipped++; continue }
        $UserSid = ([string]$Row.UserSid).Trim()
        $Key = "$UserSid|$ExeInfo"
        $RecordKey = "$Epoch|$Id"
        $Number = $Id -as [long]
        if ($null -ne $Number -and ($null -eq $LowestId -or $Number -lt $LowestId)) { $LowestId = $Number }
        # SRUM times are UTC: an Unspecified date is marked Utc, and a Local one is converted.
        $Time = $Row.EndTimeUtc
        if ($Time -isnot [datetime]) { $Time = $null }
        elseif ($Time.Kind -eq [DateTimeKind]::Local) { $Time = $Time.ToUniversalTime() }
        elseif ($Time.Kind -ne [DateTimeKind]::Utc) { $Time = [datetime]::SpecifyKind($Time, [DateTimeKind]::Utc) }
        # SRUM's null means 0 seconds; a negative or non-numeric value counts as 0 too.
        $Focus = $Row.FocusSeconds -as [double]
        if (-not ($Focus -gt 0)) { $Focus = [double]0 }
        $InputSeconds = $Row.InputSeconds -as [double]
        if (-not ($InputSeconds -gt 0)) { $InputSeconds = [double]0 }

        $Entry = $Entries[$Key]
        if ($null -eq $Entry)
        {
            $Entry = New-AULedgerEntry $UserSid $ExeInfo
            $Entries[$Key] = $Entry
        }
        if (-not $Present.ContainsKey($Key))
        {
            $Present[$Key] = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            if ($null -eq $Entry.FirstSeen) { [void]$OpenFirstSeen.Add($Key) }
        }
        [void]$Present[$Key].Add($RecordKey)
        $Entry.Counted[$RecordKey] = @{ F = $Focus; I = $InputSeconds; T = $Time }
        $Merged++

        if ($null -eq $Time) { continue }
        if ($null -eq $Earliest -or $Time -lt $Earliest) { $Earliest = $Time }
        if ($OpenFirstSeen.Contains($Key) -and ($null -eq $Entry.FirstSeen -or $Time -lt $Entry.FirstSeen)) { $Entry.FirstSeen = $Time }
        if ($null -eq $Entry.LastRanTime -or $Time -gt $Entry.LastRanTime) { $Entry.LastRanTime = $Time }

        if (-not $Interactive.ContainsKey($UserSid))
        {
            $UserType = 'Unknown'
            if ($null -ne $UserTypes -and $null -ne $UserTypes[$UserSid]) { $UserType = [string]$UserTypes[$UserSid] }
            $Interactive[$UserSid] = @{ Type = $UserType; Interactive = (Test-AUInteractiveUserType $UserType); Credited = ([Collections.Generic.Dictionary[double,object]]::new()) }
        }
        $User = $Interactive[$UserSid]
        if (-not $User.Interactive) { continue }
        if ($null -eq $Entry.LastInteractiveRunTime -or $Time -gt $Entry.LastInteractiveRunTime) { $Entry.LastInteractiveRunTime = $Time }
        if ($null -eq $Entry.LastFocusOrInputTime -or $Time -gt $Entry.LastFocusOrInputTime)
        {
            # Test-AUFocusRecord decides; its answer is kept per user, focus, and input seconds (exact
            # double keys), because the same values recur across tens of thousands of rows.
            $ByFocus = $null
            if (-not $User.Credited.TryGetValue($Focus, [ref]$ByFocus))
            {
                $ByFocus = [Collections.Generic.Dictionary[double,bool]]::new()
                $User.Credited[$Focus] = $ByFocus
            }
            $Credited = $false
            if (-not $ByFocus.TryGetValue($InputSeconds, [ref]$Credited))
            {
                $Credited = [bool](Test-AUFocusRecord -UserType $User.Type -FocusSeconds $Focus -InputSeconds $InputSeconds -MinFocusSeconds $MinFocusSeconds)
                $ByFocus[$InputSeconds] = $Credited
            }
            if ($Credited) { $Entry.LastFocusOrInputTime = $Time }
        }
    }

    # Nothing merged (no rows, or none usable): archiving now would treat every counted key as aged
    # out, and those keys would count again when SRUM is read next time (F10).
    if ($Merged -eq 0)
    {
        Write-CMTraceLog -Message "App Usage: no usable SRUM rows to merge ($Skipped skipped); the ledger is unchanged." -Component 'AppUsage' -Type 2
        return
    }

    if ($null -ne $LowestAutoIncId -and ($null -eq $LowestId -or $LowestAutoIncId -lt $LowestId)) { $LowestId = [long]$LowestAutoIncId }
    $Archived = 0
    $EpochPrefix = "$Epoch|"
    foreach ($Key in @($Entries.Keys))
    {
        $Entry = $Entries[$Key]
        $Seen = $Present[$Key]
        foreach ($RecordKey in @($Entry.Counted.Keys))
        {
            if ($NoArchive -or ($null -ne $Seen -and $Seen.Contains($RecordKey))) { continue }
            if ($RecordKey.StartsWith($EpochPrefix, [StringComparison]::OrdinalIgnoreCase))
            {
                # This epoch: only a key below the lowest ID SRUM still holds has aged out.
                $Number = $RecordKey.Substring($EpochPrefix.Length) -as [long]
                if ($null -eq $Number -or $null -eq $LowestId -or $Number -ge $LowestId) { continue }
            }
            $Record = $Entry.Counted[$RecordKey]
            $Entry.ArchivedFocus = [double]$Entry.ArchivedFocus + [double]$Record.F
            $Entry.ArchivedInput = [double]$Entry.ArchivedInput + [double]$Record.I
            $Entry.Counted.Remove($RecordKey)
            $Archived++
        }
        Update-AULedgerEntryTotal $Entry
    }

    if ($null -eq $Ledger.WatchingSince -and $null -ne $Earliest) { $Ledger.WatchingSince = $Earliest }
    Write-CMTraceLog -Message "App Usage: merged $Merged SRUM rows ($Skipped skipped) into $($Entries.Count) ledger entries; $Archived aged-out records archived." -Component 'AppUsage'
}#endfunction

function Get-AUFoldIdentity
{
    <#
.SYNOPSIS
    Returns the identity two builds must share to fold, or $null when the build's identity is unknown.
.DESCRIPTION
    A build with a stored target is identified by its section, rule ID, and target pattern. A build
    without one is identified by its verified CompanyName and ProductName, and only when both are
    present. Otherwise its identity is unknown, and it never folds (D23).
.PARAMETER Entry
    The ledger entry.
#>
    param (
        [pscustomobject]$Entry
    )

    $Separator = [string][char]31
    $Target = $Entry.StoredTarget
    if ($null -ne $Target)
    {
        $Parts = @(([string]$Target.Section).Trim(), ([string]$Target.MatchRuleId).Trim(), ([string]$Target.TargetPattern).Trim())
        if ($Parts[0] -and $Parts[1] -and $Parts[2]) { return ('Target' + $Separator + ($Parts -join $Separator)) }
    }
    if ($Entry.FactsVerified -eq $true -and $null -ne $Entry.Facts)
    {
        $Company = ([string]$Entry.Facts.FileCompanyName).Trim()
        $Product = ([string]$Entry.Facts.FileProductName).Trim()
        if ($Company -and $Product) { return ('Facts' + $Separator + $Company + $Separator + $Product) }
    }
    return $null
}#endfunction

function Invoke-AULedgerFold
{
    <#
.SYNOPSIS
    Folds aged-out builds into a build of the same app, so the ledger doesn't grow with every update.
.DESCRIPTION
    Builds fold only with the same user SID, the same exe name, and the same known identity
    (Get-AUFoldIdentity): never unrelated apps that share an exe name (D23). Package entries have no
    exe name and never fold. Only a build whose SRUM rows have all aged out (an empty Counted) is
    folded away (F9). It folds into the group's survivor: a build that still has counted rows if there
    is one, then the one that ran last. The survivor keeps the earliest FirstSeen, the latest of each
    last-time field, and the summed archived totals.
.PARAMETER Ledger
    The ledger.
#>
    param (
        [pscustomobject]$Ledger
    )

    $Entries = $Ledger.Entries
    $Groups = [Collections.Hashtable]::new([StringComparer]::OrdinalIgnoreCase)
    $Keys = [string[]]@($Entries.Keys)
    [Array]::Sort($Keys, [StringComparer]::Ordinal)
    foreach ($Key in $Keys)
    {
        $Entry = $Entries[$Key]
        $ExeName = ([string]$Entry.ExeName).Trim()
        if (-not $ExeName) { continue }
        $Identity = Get-AUFoldIdentity $Entry
        if ($null -eq $Identity) { continue }
        $GroupKey = ([string]$Entry.UserSid).Trim() + [char]31 + $ExeName + [char]31 + $Identity
        if (-not $Groups.ContainsKey($GroupKey)) { $Groups[$GroupKey] = [Collections.Generic.List[string]]::new() }
        $Groups[$GroupKey].Add($Key)
    }

    $Folded = 0
    foreach ($Members in $Groups.Values)
    {
        if ($Members.Count -lt 2) { continue }
        $Survivor = $null
        foreach ($Key in $Members)
        {
            if ($null -eq $Survivor) { $Survivor = $Key; continue }
            $Candidate = $Entries[$Key]
            $Current = $Entries[$Survivor]
            $CandidateLive = $Candidate.Counted.Count -gt 0
            $CurrentLive = $Current.Counted.Count -gt 0
            if ($CandidateLive -ne $CurrentLive) { if ($CandidateLive) { $Survivor = $Key }; continue }
            if ($null -ne $Candidate.LastRanTime -and ($null -eq $Current.LastRanTime -or $Candidate.LastRanTime -gt $Current.LastRanTime)) { $Survivor = $Key }
        }

        $Kept = $Entries[$Survivor]
        foreach ($Key in $Members)
        {
            if ($Key -eq $Survivor) { continue }
            $Source = $Entries[$Key]
            if ($Source.Counted.Count -gt 0) { continue }
            $Kept.FirstSeen = Get-AUEarlierDate $Kept.FirstSeen $Source.FirstSeen
            foreach ($Name in $script:AULedgerLastTimeFields) { $Kept.$Name = Get-AULaterDate $Kept.$Name $Source.$Name }
            $Kept.ArchivedFocus = [double]$Kept.ArchivedFocus + [double]$Source.ArchivedFocus
            $Kept.ArchivedInput = [double]$Kept.ArchivedInput + [double]$Source.ArchivedInput
            $Entries.Remove($Key)
            $Folded++
        }
        Update-AULedgerEntryTotal $Kept
    }
    if ($Folded -gt 0) { Write-CMTraceLog -Message "App Usage: folded $Folded aged-out builds into newer builds of the same app." -Component 'AppUsage' }
}#endfunction

# Device-level aggregation (D19, D30, D31, D32). Users are combined: the per-app fields and the
# per-executable output carry counts, never a user SID, UPN, or scope. The entries these functions
# take are ledger entries with this run's results attached by Invoke-AppUsage: Target
# (Resolve-AUTarget), Classification (Get-AUClassification), Role (Get-AURole), UserType
# (Get-AUUserType), and InstallStatus (Get-AUInstallStatus for the entry's user). Use is decided only
# by Get-AUDerivedUse (F5).
$script:AUMatchedSections = @('Customer', 'PowerStacks', 'Retained')
# Facts copied into the per-executable output; for an unverified build only the path-level ones (D30).
$script:AUExeFactFields = @('RunPath', 'LocationClass', 'FileDescription', 'FileProductName', 'FileCompanyName', 'FileVersion', 'ProductVersion', 'Subsystem')
$script:AUPathFactFields = @('RunPath', 'LocationClass', 'Subsystem')
$script:AUWildcardChars = [char[]]@('*', '?', '[', ']', '`')

function ConvertTo-AUOutputDate
{
    <#
.SYNOPSIS
    Formats a date for the output with Format-AUDate; $null for $null or a date that isn't UTC.
.DESCRIPTION
    Format-AUDate throws on a Local or Unspecified date, so a local time is never written with a Z.
    Here that's contained: the date is left out and the problem logged, and the rest of the output
    is still produced.
.PARAMETER Value
    A Utc date or $null.
#>
    param (
        [object]$Value
    )

    if ($null -eq $Value) { return $null }
    # A Utc date, formatted as Format-AUDate does, without the call: this runs for every output date.
    if ($Value -is [datetime] -and $Value.Kind -eq [DateTimeKind]::Utc) { return $Value.ToString($script:AUUtcDateFormat, [Globalization.CultureInfo]::InvariantCulture) }
    try { return (Format-AUDate $Value) }
    catch
    {
        Write-CMTraceLog -Message "App Usage: left a date out of the output: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 2
        return $null
    }
}#endfunction

function Test-AUEntryMatched
{
    <#
.SYNOPSIS
    Tests whether an entry has a target: MatchSection Customer, PowerStacks, or Retained.
.PARAMETER Entry
    The entry, with its Target.
#>
    param (
        [pscustomobject]$Entry
    )

    return ($null -ne $Entry.Target -and [string]$Entry.Target.MatchSection -cin $script:AUMatchedSections)
}#endfunction

function Get-AUExeKey
{
    <#
.SYNOPSIS
    Returns the lowercase name an entry's executable is known by: its ExeName, or for a Store or
    MSIX package (no ExeName) its ExeInfo, the package identity.
.PARAMETER Entry
    The entry.
#>
    param (
        [pscustomobject]$Entry
    )

    $Name = ([string]$Entry.ExeName).Trim()
    if (-not $Name) { $Name = ([string]$Entry.ExeInfo).Trim() }
    return $Name.ToLowerInvariant()
}#endfunction

function New-AUAppIndex
{
    <#
.SYNOPSIS
    Returns the installed apps indexed once per run, so each target lookup reads a few entries
    instead of every app (Task 21: thousands of entries times hundreds of apps).
.DESCRIPTION
    Apps (the non-null entries, in order), Names (trimmed DisplayNames, ignoring case), Cache (the
    Get-AUTargetAppNames cache), and lookups from a key to the positions in Apps that hold it, in
    order: ByCode and ByFamily (trimmed ProductCode and PackageFamily, ignoring case), ByName and
    ByPublisher (trimmed DisplayName and Publisher, lowercased invariant), ByNameKey and
    ByPublisherKey (Get-AUNormalizedText of the DisplayName and Publisher, exact), and ByIconFile
    (the DisplayIcon file, Get-AUCommandFile, trimmed with / as \ and no \\?\ prefix, ignoring
    case; Test-AUMainExe). A DisplayName or Publisher with a character outside ASCII goes in
    OtherNames or OtherPublishers instead, because -like may match it to an ASCII pattern in ways
    invariant lowercasing doesn't (the Kelvin sign and k). Candidates caches
    Get-AUTargetAppCandidates. The index only narrows the apps to check; Test-AUTargetApp still
    decides.
.PARAMETER Apps
    The installed-app entries (Task 13 shape).
#>
    param (
        [object[]]$Apps
    )

    $NewMap = {
        param ([StringComparer]$Comparer)
        return , ([Collections.Generic.Dictionary[string,Collections.Generic.List[int]]]::new($Comparer))
    }
    $Index = [pscustomobject]@{
        Apps            = $null
        Names           = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
        Cache           = [Collections.Hashtable]::new([StringComparer]::OrdinalIgnoreCase)
        ByCode          = & $NewMap ([StringComparer]::OrdinalIgnoreCase)
        ByFamily        = & $NewMap ([StringComparer]::OrdinalIgnoreCase)
        ByName          = & $NewMap ([StringComparer]::Ordinal)
        ByPublisher     = & $NewMap ([StringComparer]::Ordinal)
        ByNameKey       = & $NewMap ([StringComparer]::Ordinal)
        ByPublisherKey  = & $NewMap ([StringComparer]::Ordinal)
        ByIconFile      = & $NewMap ([StringComparer]::OrdinalIgnoreCase)
        OtherNames      = [Collections.Generic.List[int]]::new()
        OtherPublishers = [Collections.Generic.List[int]]::new()
        Candidates      = [Collections.Generic.Dictionary[string,object[]]]::new([StringComparer]::Ordinal)
    }
    $Add = {
        param ($Map, [string]$Key, [int]$Position)
        $Positions = $null
        if (-not $Map.TryGetValue($Key, [ref]$Positions))
        {
            $Positions = [Collections.Generic.List[int]]::new()
            $Map[$Key] = $Positions
        }
        $Positions.Add($Position)
    }
    $List = [Collections.Generic.List[object]]::new()
    foreach ($App in @($Apps))
    {
        if ($null -eq $App) { continue }
        $Position = $List.Count
        $List.Add($App)
        $Name = ([string]$App.DisplayName).Trim()
        if ($Name -and -not $Index.Names.ContainsKey($Name)) { $Index.Names[$Name] = $Name }
        $Publisher = ([string]$App.Publisher).Trim()
        $Code = ([string]$App.ProductCode).Trim()
        $Family = ([string]$App.PackageFamily).Trim()
        if ($Code) { & $Add $Index.ByCode $Code $Position }
        if ($Family) { & $Add $Index.ByFamily $Family $Position }
        if ($Name)
        {
            # -cmatch: a case-insensitive match folds the Kelvin sign to k, inside the ASCII range.
            if ($Name -cmatch '[^\x00-\x7F]') { $Index.OtherNames.Add($Position) }
            else { & $Add $Index.ByName $Name.ToLowerInvariant() $Position }
        }
        if ($Publisher -cmatch '[^\x00-\x7F]') { $Index.OtherPublishers.Add($Position) }
        else { & $Add $Index.ByPublisher $Publisher.ToLowerInvariant() $Position }
        $NameKey = Get-AUNormalizedText ([string]$App.DisplayName) -Kind Name
        if ($NameKey) { & $Add $Index.ByNameKey $NameKey $Position }
        $PublisherKey = Get-AUNormalizedText ([string]$App.Publisher) -Kind Publisher
        if ($PublisherKey) { & $Add $Index.ByPublisherKey $PublisherKey $Position }
        $IconFile = Get-AUCommandFile ([string]$App.DisplayIcon)
        if ($IconFile)
        {
            $IconFile = $IconFile.Trim().Replace('/', '\')
            if ($IconFile.StartsWith('\\?\')) { $IconFile = $IconFile.Substring(4) }
            if ($IconFile) { & $Add $Index.ByIconFile $IconFile $Position }
        }
    }
    $Index.Apps = $List.ToArray()
    return $Index
}#endfunction

function Get-AUIndexedApps
{
    <#
.SYNOPSIS
    Returns the apps one index lookup holds for a key, in installed-app order; none for a missing key.
.PARAMETER Index
    The New-AUAppIndex result.
.PARAMETER Map
    One of its lookups, for example ByCode.
.PARAMETER Key
    The key.
#>
    param (
        [pscustomobject]$Index,
        [object]$Map,
        [string]$Key
    )

    $Positions = $null
    if (-not $Map.TryGetValue($Key, [ref]$Positions)) { return , ([object[]]@()) }
    return , ([object[]]@(foreach ($Position in $Positions) { $Index.Apps[$Position] }))
}#endfunction

function Get-AUTargetAppCandidates
{
    <#
.SYNOPSIS
    Returns the installed apps that might be the target app, in installed-app order: every app
    Test-AUTargetApp could accept, and few others.
.DESCRIPTION
    The apps with the target's ProductCode or PackageFamily; for its name and publisher patterns, the
    apps whose DisplayName is the name pattern's literal text (Get-AUPatternLiteral), or, for a name
    pattern with wildcards, the apps whose Publisher is the publisher pattern's literal text (each
    with the non-ASCII names or publishers, which -like may fold differently); and for a normalized
    target (Get-AUTargetKeys NameKey), the apps with that normalized name. When neither pattern is a
    plain ASCII literal, every app. The result is cached in the index per target keys.
.PARAMETER Index
    The New-AUAppIndex result.
.PARAMETER Keys
    The Get-AUTargetKeys result.
#>
    param (
        [pscustomobject]$Index,
        [pscustomobject]$Keys
    )

    $Signature = @([string]$Keys.Code, [string]$Keys.Family, [string]$Keys.NamePattern, [string]$Keys.PublisherPattern, [string]($null -eq $Keys.NamePattern),
        [string]($null -eq $Keys.PublisherPattern), [string]$Keys.NameKey, [string]$Keys.PublisherKey, [string]$Keys.PublisherLike) -join [string][char]31
    $Cached = $null
    if ($Index.Candidates.TryGetValue($Signature, [ref]$Cached)) { return , $Cached }

    $Found = [Collections.Generic.SortedSet[int]]::new()
    $Every = $false
    $AddKey = {
        param ($Map, [string]$Key)
        $Positions = $null
        if ($Map.TryGetValue($Key, [ref]$Positions)) { $Found.UnionWith($Positions) }
    }
    if ($Keys.Code) { & $AddKey $Index.ByCode ([string]$Keys.Code) }
    if ($Keys.Family) { & $AddKey $Index.ByFamily ([string]$Keys.Family) }
    if ($null -ne $Keys.NamePattern -and $null -ne $Keys.PublisherPattern)
    {
        $Name = Get-AUPatternLiteral ([string]$Keys.NamePattern)
        $Publisher = Get-AUPatternLiteral ([string]$Keys.PublisherPattern)
        if ($null -ne $Name -and $Name -cnotmatch '[^\x00-\x7F]')
        {
            & $AddKey $Index.ByName $Name.ToLowerInvariant()
            $Found.UnionWith($Index.OtherNames)
        }
        elseif ($null -ne $Publisher -and $Publisher -cnotmatch '[^\x00-\x7F]')
        {
            & $AddKey $Index.ByPublisher $Publisher.ToLowerInvariant()
            $Found.UnionWith($Index.OtherPublishers)
        }
        else { $Every = $true }
    }
    if ($Keys.NameKey -and ($Keys.PublisherKey -or $Keys.PublisherLike)) { & $AddKey $Index.ByNameKey ([string]$Keys.NameKey) }

    if ($Every) { $Result = [object[]]$Index.Apps }
    else { $Result = [object[]]@(foreach ($Position in $Found) { $Index.Apps[$Position] }) }
    $Index.Candidates[$Signature] = $Result
    return , $Result
}#endfunction

function Get-AUTargetAppNames
{
    <#
.SYNOPSIS
    Returns the trimmed DisplayNames of the installed apps a target belongs to; none when its app
    isn't installed.
.DESCRIPTION
    When the target's ResolvedAppName (the concrete DisplayName it was matched to) is installed, that
    app alone. Otherwise every installed app that is the target app (Test-AUTargetApp, the test
    Get-AUInstallStatus uses), so an update that renamed the entry is still credited. The result is
    cached per target in the index.
.PARAMETER Target
    The Resolve-AUTarget result.
.PARAMETER Index
    The New-AUAppIndex result.
#>
    param (
        [pscustomobject]$Target,
        [pscustomobject]$Index
    )

    $Separator = [string][char]31
    $Signature = @([string]$Target.ResolvedAppName, [string]$Target.TargetPattern, [string]$Target.TargetPublisher, [string]$Target.ProductCode,
        [string]$Target.PackageFamily, [string]$Target.RuleType, [string]$Target.InstalledStateDependent, [string]$Target.MatchRuleId) -join $Separator
    $Names = $Index.Cache[$Signature]
    if ($null -ne $Names) { return $Names }

    $Found = [Collections.Generic.List[string]]::new()
    $Resolved = ([string]$Target.ResolvedAppName).Trim()
    if ($Resolved -and $Index.Names.ContainsKey($Resolved)) { $Found.Add($Index.Names[$Resolved]) }
    else
    {
        $Keys = Get-AUTargetKeys $Target
        foreach ($App in (Get-AUTargetAppCandidates $Index $Keys))
        {
            $Name = ([string]$App.DisplayName).Trim()
            if (-not $Name -or $Found.Contains($Name)) { continue }
            if (Test-AUTargetApp $App $Keys) { $Found.Add($Name) }
        }
    }
    $Names = [string[]]$Found.ToArray()
    $Index.Cache[$Signature] = $Names
    return $Names
}#endfunction

function Get-AUKnownExes
{
    <#
.SYNOPSIS
    Returns each installed app's known executables: DisplayName (ignoring case) to a set of lowercase exe name patterns (F23).
.DESCRIPTION
    An app's executables are known from three sources: the .exe files Windows Installer lists as
    components of the app's ProductCode; the exeName of each identity rule (customer and PowerStacks)
    whose target matches the app, as written in the rule, wildcards included; and the executables of
    entries matched to the app (Get-AUTargetAppNames). A Store or MSIX package entry is known by its
    ExeInfo. Ignored entries don't count (F22), and an unresolved entry belongs to no app. An app with
    no known executable is absent, so Get-AUAppUsage reports it NotCovered.
    Every value is a -like pattern: a rule's exeName as written (the validator checked it), and every
    other name escaped with ConvertTo-AUWildcardLiteral, because a file name may hold `, [, or ] and
    must match only itself.
.PARAMETER Apps
    The installed-app entries (Task 13 shape), with ProductCode.
.PARAMETER MsiFileMap
    Lowercased full file path to the ProductCode of the Windows Installer product that owns it.
.PARAMETER Mappings
    The whole Get-AUMappings result (F18), or $null.
.PARAMETER Entries
    The entries, with this run's Target and Classification.
#>
    param (
        [object[]]$Apps,
        [hashtable]$MsiFileMap,
        [pscustomobject]$Mappings,
        [object[]]$Entries
    )

    $Known = [Collections.Hashtable]::new([StringComparer]::OrdinalIgnoreCase)
    $Add = {
        param ([string]$Name, [string]$Exe, [bool]$IsPattern)
        $Set = $Known[$Name]
        if ($null -eq $Set)
        {
            $Set = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $Known[$Name] = $Set
        }
        $Exe = $Exe.ToLowerInvariant()
        if (-not $IsPattern) { $Exe = ConvertTo-AUWildcardLiteral $Exe }
        [void]$Set.Add($Exe)
    }
    $Index = New-AUAppIndex $Apps
    $AppsByName = [Collections.Hashtable]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($App in $Index.Apps)
    {
        $Name = ([string]$App.DisplayName).Trim()
        if (-not $Name) { continue }
        if (-not $AppsByName.ContainsKey($Name)) { $AppsByName[$Name] = [Collections.Generic.List[object]]::new() }
        $AppsByName[$Name].Add($App)
    }
    $AllNames = [string[]]@($AppsByName.Keys)

    # Windows Installer components of each app's product.
    $ByCode = [Collections.Hashtable]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($App in $Index.Apps)
    {
        $Code = ([string]$App.ProductCode).Trim()
        $Name = ([string]$App.DisplayName).Trim()
        if (-not $Code -or -not $Name) { continue }
        if (-not $ByCode.ContainsKey($Code)) { $ByCode[$Code] = [Collections.Generic.List[string]]::new() }
        if (-not $ByCode[$Code].Contains($Name)) { $ByCode[$Code].Add($Name) }
    }
    if ($null -ne $MsiFileMap -and $ByCode.Count -gt 0)
    {
        foreach ($Path in $MsiFileMap.Keys)
        {
            $Owners = $ByCode[([string]$MsiFileMap[$Path]).Trim()]
            if ($null -eq $Owners) { continue }
            $File = ([string]$Path).Trim()
            if (-not $File.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) { continue }
            $Leaf = $File.Substring($File.LastIndexOfAny([char[]]@('\', '/')) + 1)
            if (-not $Leaf) { continue }
            foreach ($Name in $Owners) { & $Add $Name $Leaf $false }
        }
    }

    # Identity rules: the exe a rule names belongs to every installed app its target matches.
    if ($null -ne $Mappings -and $null -ne $Mappings.Mappings)
    {
        foreach ($Section in @($Mappings.Mappings.customer, $Mappings.Mappings.powerStacks))
        {
            if ($null -eq $Section) { continue }
            foreach ($Rule in @($Section.identityRules))
            {
                if ($null -eq $Rule -or $Rule.type -cne 'identity' -or $null -eq $Rule.when -or $null -eq $Rule.target) { continue }
                $Exe = ([string]$Rule.when.exeName).Trim()
                $NamePattern = $Rule.target.displayName
                if (-not $Exe -or $null -eq $NamePattern -or $null -eq $Rule.target.publisher) { continue }
                $Keys = Get-AUTargetKeys ([pscustomobject]@{ TargetPattern = [string]$NamePattern; TargetPublisher = [string]$Rule.target.publisher; RuleType = 'identity'; InstalledStateDependent = $false })
                # A rule target has no ProductCode or PackageFamily, so its DisplayName pattern has to
                # match: one -like over every name narrows the apps, then the target-app test decides.
                foreach ($Name in @($AllNames -like [string]$NamePattern))
                {
                    foreach ($App in $AppsByName[$Name])
                    {
                        if (Test-AUTargetApp $App $Keys) { & $Add $Name $Exe $true; break }
                    }
                }
            }
        }
    }

    # Executables seen and matched to the app.
    foreach ($Entry in @($Entries))
    {
        if ($null -eq $Entry -or -not (Test-AUEntryMatched $Entry)) { continue }
        if ($null -ne $Entry.Classification -and $Entry.Classification.Ignored -eq $true) { continue }
        $Exe = Get-AUExeKey $Entry
        if (-not $Exe) { continue }
        foreach ($Name in @(Get-AUTargetAppNames $Entry.Target $Index)) { & $Add $Name $Exe $false }
    }
    return $Known
}#endfunction

function Get-AUAppUsage
{
    <#
.SYNOPSIS
    Returns the usage fields for each installed-app entry, keyed by DisplayName ignoring case (F24).
.DESCRIPTION
    One value per de-duplicated inventory entry (its AppName), combined across every user on the
    device (D19). Each value holds AppLastUsedDate (the latest credited use by any user),
    AppUsageStatus, AppLastRanDate (the latest run of any kind), AppInFocusSeconds (total focus, whole
    seconds, interactive users only), AppUsersWithUse (how many users had credited use), AppMatchedExeCount (how many of the
    app's executables were seen), and AppRunsAsService (a matched executable is a service binary or
    has the Service role). Dates are UTC text from Format-AUDate. No user identity (D31).
    An entry belongs to the apps Get-AUTargetAppNames gives for its target. Use comes only from
    Get-AUDerivedUse (F5), so SYSTEM and service accounts never give credited use. Ignored entries
    are left out (F22).
    AppUsageStatus, first that applies (D32): Used (a matched exe has credited use since
    WatchingSince), RanNotUsed (a matched exe ran since then), Ambiguous (an unresolved exe with this
    app among its CandidateTargets ran since then, or an unmatched exe whose name is one of the app's
    known or matched exes ran since then, a wildcard known exe compared with -like, D30), NotUsed (the
    app has known exes, or matched exes, and none ran, matched or not), NotCovered (none known). An exe
    matched to another app never makes this app Ambiguous. It's blank ($null) unless CollectionOk is true,
    WatchingSince is known, and every scope holding the app in Apps (a blank Scope is Machine) is Read
    in ScopeRead, so missing coverage is never NotUsed. When CollectionOk is false, every field is
    blank.
.PARAMETER Entries
    The entries, with this run's Target, Classification, Role, and UserType.
.PARAMETER InventoryApps
    The de-duplicated inventory entries (ConvertTo-AUInventoryApps), with AppName.
.PARAMETER KnownExesByApp
    The Get-AUKnownExes result.
.PARAMETER WatchingSince
    The ledger's WatchingSince (Utc), or $null.
.PARAMETER ScopeRead
    Machine or a SID to Read, Unread, or Deleted. A scope that's missing counts as Unread.
.PARAMETER Apps
    The installed-app entries (Task 13 shape), with their internal Scope.
.PARAMETER CollectionOk
    True when App Usage collected usage successfully this run.
#>
    param (
        [object[]]$Entries,
        [object[]]$InventoryApps,
        [hashtable]$KnownExesByApp,
        [Nullable[datetime]]$WatchingSince,
        [hashtable]$ScopeRead,
        [object[]]$Apps,
        [bool]$CollectionOk
    )

    $Result = [Collections.Hashtable]::new([StringComparer]::OrdinalIgnoreCase)
    $Inventory = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($App in @($InventoryApps))
    {
        if ($null -eq $App) { continue }
        $Name = [string]$App.AppName
        if ([string]::IsNullOrWhiteSpace($Name) -or $Result.ContainsKey($Name)) { continue }
        $Result[$Name] = $null
        $Inventory[$Name] = $Name.Trim()
    }

    if (-not $CollectionOk)
    {
        foreach ($Name in @($Result.Keys))
        {
            $Result[$Name] = [pscustomobject][ordered]@{ AppLastUsedDate = $null; AppUsageStatus = $null; AppLastRanDate = $null; AppInFocusSeconds = $null; AppUsersWithUse = $null; AppMatchedExeCount = $null; AppRunsAsService = $null }
        }
        return $Result
    }

    $Index = New-AUAppIndex $Apps
    $States = [Collections.Hashtable]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($Trimmed in $Inventory.Values)
    {
        if ($States.ContainsKey($Trimmed)) { continue }
        $States[$Trimmed] = @{
            LastUsed  = $null
            LastRan   = $null
            Focus     = [double]0
            Users     = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            Exes      = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            Service   = $false
            Credited  = $false
            Ran       = $false
            Ambiguous = $false
        }
    }

    # Exe names (ExeName, or ExeInfo for a package) of unmatched entries that ran since WatchingSince.
    # An app whose known exe ran unmatched (an unverified build, say) is Ambiguous, never NotUsed (D30).
    $UnmatchedRan = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    # Inline per-entry work: this loop runs once per ledger entry, thousands of times.
    foreach ($Entry in @($Entries))
    {
        if ($null -eq $Entry) { continue }
        if ($null -ne $Entry.Classification -and $Entry.Classification.Ignored -eq $true) { continue }
        $Use = Get-AUDerivedUse $Entry ([string]$Entry.Role) ([string]$Entry.UserType)
        $LastRan = $Use.LastRanTime
        $LastUsed = $Use.LastUsedTime
        $RanSince = ($null -ne $LastRan -and ($null -eq $WatchingSince -or $LastRan -ge $WatchingSince))
        $UsedSince = ($null -ne $LastUsed -and ($null -eq $WatchingSince -or $LastUsed -ge $WatchingSince))
        $Target = $Entry.Target

        if ($null -eq $Target -or [string]$Target.MatchSection -cnotin $script:AUMatchedSections)
        {
            # Unresolved (D30, D47): each surviving candidate that is installed may be Ambiguous.
            if (-not $RanSince) { continue }
            $Exe = ([string]$Entry.ExeName).Trim()
            if (-not $Exe) { $Exe = ([string]$Entry.ExeInfo).Trim() }
            if ($Exe) { [void]$UnmatchedRan.Add($Exe) }
            if ($null -eq $Target) { continue }
            $Candidates = [Collections.Generic.List[string]]::new()
            foreach ($Candidate in @($Target.CandidateTargets)) { if (-not [string]::IsNullOrWhiteSpace([string]$Candidate)) { $Candidates.Add(([string]$Candidate).Trim()) } }
            if ($Candidates.Count -lt 2) { continue }
            foreach ($Name in $Candidates) { if ($States.ContainsKey($Name)) { $States[$Name].Ambiguous = $true } }
            continue
        }

        $Exe = ([string]$Entry.ExeName).Trim()
        if (-not $Exe) { $Exe = ([string]$Entry.ExeInfo).Trim() }
        $IsService = ([string]$Entry.Role -ceq 'Service' -or ($null -ne $Entry.Facts -and $Entry.Facts.IsServiceBinary -eq $true))
        # Focus counts only for interactive users, as credited use does.
        $Focus = [double]0
        if (Test-AUInteractiveUserType ([string]$Entry.UserType)) { $Focus = [double]$Entry.FocusTotal }
        $UserSid = ([string]$Entry.UserSid).Trim()
        foreach ($Name in @(Get-AUTargetAppNames $Target $Index))
        {
            $State = $States[$Name]
            if ($null -eq $State) { continue }
            if ($null -ne $LastUsed -and ($null -eq $State.LastUsed -or $LastUsed -gt $State.LastUsed)) { $State.LastUsed = $LastUsed }
            if ($null -ne $LastRan -and ($null -eq $State.LastRan -or $LastRan -gt $State.LastRan)) { $State.LastRan = $LastRan }
            $State.Focus += $Focus
            if ($Exe) { [void]$State.Exes.Add($Exe) }
            if ($IsService) { $State.Service = $true }
            if ($RanSince) { $State.Ran = $true }
            if ($UsedSince) { $State.Credited = $true }
            if ($Use.HasCreditedUse -and $UserSid) { [void]$State.Users.Add($UserSid) }
        }
    }
    $UnmatchedNames = [string[]]@($UnmatchedRan)

    # Coverage (D32): every scope holding the app must have been read this run.
    $ReadState = [Collections.Hashtable]::new([StringComparer]::OrdinalIgnoreCase)
    if ($null -ne $ScopeRead) { foreach ($Key in $ScopeRead.Keys) { $ReadState[([string]$Key).Trim()] = [string]$ScopeRead[$Key] } }
    $Covered = [Collections.Hashtable]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($App in $Index.Apps)
    {
        $Name = ([string]$App.DisplayName).Trim()
        if (-not $Name) { continue }
        $Scope = ([string]$App.Scope).Trim()
        if (-not $Scope) { $Scope = 'Machine' }
        $IsRead = ($ReadState[$Scope] -ceq 'Read')
        if ($Covered.ContainsKey($Name)) { $Covered[$Name] = ($Covered[$Name] -and $IsRead) }
        else { $Covered[$Name] = $IsRead }
    }

    foreach ($Name in @($Result.Keys))
    {
        $Trimmed = $Inventory[$Name]
        $State = $States[$Trimmed]
        $Status = $null
        if ($null -ne $WatchingSince -and $Covered[$Trimmed] -eq $true)
        {
            $KnownExes = $null
            if ($null -ne $KnownExesByApp) { $KnownExes = $KnownExesByApp[$Trimmed] }
            if ($State.Credited) { $Status = 'Used' }
            elseif ($State.Ran) { $Status = 'RanNotUsed' }
            elseif ($State.Ambiguous) { $Status = 'Ambiguous' }
            elseif ($State.Exes.Count -gt 0 -or ($null -ne $KnownExes -and @($KnownExes).Count -gt 0))
            {
                $Status = 'NotUsed'
                if ($UnmatchedNames.Count -gt 0)
                {
                    # Matched exe names are literal: exact match only.
                    foreach ($Exe in $State.Exes) { if ($UnmatchedRan.Contains($Exe)) { $Status = 'Ambiguous'; break } }
                    # Known exes are -like patterns (Get-AUKnownExes). A plain name is an exact match; a
                    # pattern that won't parse never stops the run and falls back to an exact match.
                    if ($Status -ceq 'NotUsed' -and $null -ne $KnownExes)
                    {
                        foreach ($Exe in $KnownExes)
                        {
                            $Pattern = [string]$Exe
                            if (-not $Pattern) { continue }
                            $Hit = $UnmatchedRan.Contains($Pattern)
                            if (-not $Hit -and $Pattern.IndexOfAny($script:AUWildcardChars) -ge 0)
                            {
                                try { $Hit = (@($UnmatchedNames -like $Pattern).Count -gt 0) }
                                catch { Write-CMTraceLog -Message "App Usage: known exe pattern '$Pattern' for $Trimmed isn't valid; compared exactly." -Component 'AppUsage' -Type 2 }
                            }
                            if ($Hit) { $Status = 'Ambiguous'; break }
                        }
                    }
                }
            }
            else { $Status = 'NotCovered' }
        }
        $Result[$Name] = [pscustomobject][ordered]@{
            AppLastUsedDate    = ConvertTo-AUOutputDate $State.LastUsed
            AppUsageStatus     = $Status
            AppLastRanDate     = ConvertTo-AUOutputDate $State.LastRan
            AppInFocusSeconds  = [long][Math]::Round($State.Focus)
            AppUsersWithUse    = $State.Users.Count
            AppMatchedExeCount = $State.Exes.Count
            AppRunsAsService   = $State.Service
        }
    }
    return $Result
}#endfunction

function Get-AUExeGroups
{
    <#
.SYNOPSIS
    Groups entries by exe build and target, combining users (D31), in a stable order.
.DESCRIPTION
    The key is the ExeInfo plus the target: MatchSection, MatchRuleId, TargetPattern, TargetPublisher,
    and ResolvedAppName for a matched entry, or None plus the CandidateTargets for an unmatched one.
    Each group's Representative supplies the facts, role, and classification: an entry with verified
    facts first, then one with facts, then the one that ran last, then the lowest user SID, so the
    choice doesn't depend on the order of the entries. Returns Entries, Representative, and Matched
    per group, ordered by key.
.PARAMETER Entries
    The entries, with this run's Target.
#>
    param (
        [object[]]$Entries
    )

    $Separator = [string][char]31
    $Groups = [Collections.Hashtable]::new([StringComparer]::OrdinalIgnoreCase)
    # Inline per-entry work: this loop runs once per ledger entry, thousands of times.
    foreach ($Entry in @($Entries))
    {
        if ($null -eq $Entry) { continue }
        $Target = $Entry.Target
        $Matched = ($null -ne $Target -and [string]$Target.MatchSection -cin $script:AUMatchedSections)
        $Key = ([string]$Entry.ExeInfo).Trim()
        if ($Matched)
        {
            foreach ($Part in @($Target.MatchSection, $Target.MatchRuleId, $Target.TargetPattern, $Target.TargetPublisher, $Target.ResolvedAppName)) { $Key += $Separator + ([string]$Part).Trim() }
        }
        else
        {
            $Key += $Separator + 'None'
            if ($null -ne $Target) { foreach ($Part in @($Target.CandidateTargets)) { if (-not [string]::IsNullOrWhiteSpace([string]$Part)) { $Key += $Separator + ([string]$Part).Trim() } } }
        }
        $Group = $Groups[$Key]
        if ($null -eq $Group)
        {
            $Group = [pscustomobject]@{ Key = $Key; Entries = [Collections.Generic.List[object]]::new(); Representative = $null; Matched = $Matched }
            $Groups[$Key] = $Group
        }
        $Group.Entries.Add($Entry)
    }

    $Keys = [string[]]@($Groups.Keys)
    [Array]::Sort($Keys, [StringComparer]::Ordinal)
    foreach ($Key in $Keys)
    {
        $Group = $Groups[$Key]
        $Best = $null
        $BestRank = 0
        foreach ($Entry in $Group.Entries)
        {
            # Rank: 2 for verified facts, 1 for facts, 0 for none.
            $EntryRank = 0
            if ($null -ne $Entry.Facts) { $EntryRank = 1; if ($Entry.Facts.FactsVerified -eq $true) { $EntryRank = 2 } }
            if ($null -eq $Best) { $Best = $Entry; $BestRank = $EntryRank; continue }
            if ($EntryRank -ne $BestRank) { if ($EntryRank -gt $BestRank) { $Best = $Entry; $BestRank = $EntryRank }; continue }
            $EntryRan = $Entry.LastRanTime
            $BestRan = $Best.LastRanTime
            if ($null -ne $EntryRan -and ($null -eq $BestRan -or $EntryRan -gt $BestRan)) { $Best = $Entry; $BestRank = $EntryRank; continue }
            if ($null -ne $BestRan -and ($null -eq $EntryRan -or $BestRan -gt $EntryRan)) { continue }
            if ([string]::CompareOrdinal([string]$Entry.UserSid, [string]$Best.UserSid) -lt 0) { $Best = $Entry; $BestRank = $EntryRank }
        }
        $Group.Representative = $Best
        $Group
    }
}#endfunction

function ConvertTo-AUExeUsage
{
    <#
.SYNOPSIS
    Returns the per-executable output: one entry per exe build and target, users combined (D31).
.DESCRIPTION
    Every entry is kept: matched or unmatched, Retained, NotInstalled, and ignored (with the ignore
    rule's ID in ClassificationRuleId, F22). Fields, in order: ExeInfo, ExeName, RunPath,
    LocationClass, FileDescription, FileProductName, FileCompanyName, FileVersion, ProductVersion
    (verified facts only; blank otherwise), FactsVerified, EvidenceCompanyName, EvidenceProductName,
    EvidenceSource (CurrentFileAtPath; present only for an unverified build with current-file
    evidence, D30), Subsystem, Role, ClassificationRuleId, ResolvedAppName, TargetPattern, Publisher
    (the target's publisher pattern), ProductCode (or the package family), MatchSection, MatchRuleId,
    InstallStatus, FirstSeen, LastUsedTime, LastRanTime, InFocusSeconds, UsersWithUse,
    RanAsSystemOnly, and last CandidateTargets (only when two or more candidates survived D47, F26).
    Across users (F25), InstallStatus is Unmatched when there's no target, else Installed if any
    user's is, else Unknown if any is (or is missing), else NotInstalled. FirstSeen is the earliest,
    LastUsedTime (Get-AUDerivedUse, F5) and LastRanTime the latest, InFocusSeconds the interactive
    users' total in whole seconds, UsersWithUse the users (non-blank SIDs) with credited use, and
    RanAsSystemOnly true when it ran and every run was by SYSTEM or a service account. The facts, role, and classification come from the group's
    representative (Get-AUExeGroups). No user identity (D31).
.PARAMETER Entries
    The entries, with this run's Target, Classification, Role, UserType, and InstallStatus.
#>
    param (
        [object[]]$Entries
    )

    $Output = [Collections.Generic.List[object]]::new()
    foreach ($Group in @(Get-AUExeGroups $Entries))
    {
        $Rep = $Group.Representative
        $Facts = $Rep.Facts
        $Target = $Rep.Target
        $Verified = ($null -ne $Facts -and $Facts.FactsVerified -eq $true)
        # The facts, blank as $null; the build-specific ones only for a verified build.
        $FactValues = @{}
        foreach ($Name in $script:AUExeFactFields)
        {
            $Value = $null
            if ($null -ne $Facts -and ($Verified -or $Name -cin $script:AUPathFactFields)) { $Value = [string]$Facts.$Name }
            if ([string]::IsNullOrWhiteSpace($Value)) { $Value = $null }
            $FactValues[$Name] = $Value
        }

        $Evidence = $null
        if (-not $Verified -and $null -ne $Facts -and $null -ne $Facts.PathEvidence) { $Evidence = $Facts.PathEvidence }
        $RuleId = $null
        if ($null -ne $Rep.Classification)
        {
            if ($Rep.Classification.Ignored -eq $true) { $RuleId = [string]$Rep.Classification.IgnoreRuleId }
            else { $RuleId = [string]$Rep.Classification.ClassificationRuleId }
            if (-not $RuleId) { $RuleId = $null }
        }

        $Status = 'Unmatched'
        $Candidates = $null
        if ($Group.Matched)
        {
            $Status = 'NotInstalled'
            foreach ($Entry in $Group.Entries)
            {
                $UserStatus = [string]$Entry.InstallStatus
                if ($UserStatus -ceq 'Installed') { $Status = 'Installed'; break }
                if ($UserStatus -cne 'NotInstalled') { $Status = 'Unknown' }
            }
        }
        elseif ($null -ne $Target)
        {
            $Names = [Collections.Generic.List[string]]::new()
            foreach ($Name in @($Target.CandidateTargets)) { if (-not [string]::IsNullOrWhiteSpace([string]$Name)) { $Names.Add(([string]$Name).Trim()) } }
            if ($Names.Count -gt 1) { $Candidates = $Names.ToArray() }
        }

        $FirstSeen = $null
        $LastUsed = $null
        $LastRan = $null
        $Focus = [double]0
        $Users = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $OtherRun = $false
        foreach ($Entry in $Group.Entries)
        {
            $Use = Get-AUDerivedUse $Entry ([string]$Entry.Role) ([string]$Entry.UserType)
            if ($null -ne $Entry.FirstSeen -and ($null -eq $FirstSeen -or $Entry.FirstSeen -lt $FirstSeen)) { $FirstSeen = $Entry.FirstSeen }
            if ($null -ne $Use.LastUsedTime -and ($null -eq $LastUsed -or $Use.LastUsedTime -gt $LastUsed)) { $LastUsed = $Use.LastUsedTime }
            if ($null -ne $Use.LastRanTime -and ($null -eq $LastRan -or $Use.LastRanTime -gt $LastRan)) { $LastRan = $Use.LastRanTime }
            $UserType = [string]$Entry.UserType
            if (Test-AUInteractiveUserType $UserType) { $Focus += [double]$Entry.FocusTotal }
            $UserSid = ([string]$Entry.UserSid).Trim()
            if ($Use.HasCreditedUse -and $UserSid) { [void]$Users.Add($UserSid) }
            # A run by anything but SYSTEM or a service account (a person, or an unknown type).
            if ($null -ne $Use.LastRanTime -and $UserType -cnotin @('System', 'Service')) { $OtherRun = $true }
        }

        $Matched = $Group.Matched
        $Out = [ordered]@{
            ExeInfo              = [string]$Rep.ExeInfo
            ExeName              = $(if ([string]::IsNullOrWhiteSpace([string]$Rep.ExeName)) { $null } else { [string]$Rep.ExeName })
            RunPath              = $FactValues['RunPath']
            LocationClass        = $FactValues['LocationClass']
            FileDescription      = $FactValues['FileDescription']
            FileProductName      = $FactValues['FileProductName']
            FileCompanyName      = $FactValues['FileCompanyName']
            FileVersion          = $FactValues['FileVersion']
            ProductVersion       = $FactValues['ProductVersion']
            FactsVerified        = $Verified
            EvidenceCompanyName  = $(if ($null -ne $Evidence -and $Evidence.CompanyName) { [string]$Evidence.CompanyName } else { $null })
            EvidenceProductName  = $(if ($null -ne $Evidence -and $Evidence.ProductName) { [string]$Evidence.ProductName } else { $null })
            EvidenceSource       = $(if ($null -ne $Evidence) { 'CurrentFileAtPath' } else { $null })
            Subsystem            = $FactValues['Subsystem']
            Role                 = $(if ([string]$Rep.Role) { [string]$Rep.Role } else { $null })
            ClassificationRuleId = $RuleId
            ResolvedAppName      = $(if ($Matched -and $Target.ResolvedAppName) { [string]$Target.ResolvedAppName } else { $null })
            TargetPattern        = $(if ($Matched -and $null -ne $Target.TargetPattern) { [string]$Target.TargetPattern } else { $null })
            Publisher            = $(if ($Matched -and $null -ne $Target.TargetPublisher) { [string]$Target.TargetPublisher } else { $null })
            ProductCode          = $(if ($Matched -and $Target.ProductCode) { [string]$Target.ProductCode } elseif ($Matched -and $Target.PackageFamily) { [string]$Target.PackageFamily } else { $null })
            MatchSection         = $(if ($Matched) { [string]$Target.MatchSection } else { 'None' })
            MatchRuleId          = $(if ($Matched -and $Target.MatchRuleId) { [string]$Target.MatchRuleId } else { $null })
            InstallStatus        = $Status
        }
        $Out['FirstSeen'] = ConvertTo-AUOutputDate $FirstSeen
        $Out['LastUsedTime'] = ConvertTo-AUOutputDate $LastUsed
        $Out['LastRanTime'] = ConvertTo-AUOutputDate $LastRan
        $Out['InFocusSeconds'] = [long][Math]::Round($Focus)
        $Out['UsersWithUse'] = $Users.Count
        $Out['RanAsSystemOnly'] = ($null -ne $LastRan -and -not $OtherRun)
        if ($null -ne $Candidates) { $Out['CandidateTargets'] = $Candidates }
        $Output.Add([pscustomobject]$Out)
    }
    return $Output.ToArray()
}#endfunction

function Get-AUUnmatchedExeCount
{
    <#
.SYNOPSIS
    Returns UnmatchedExeCount_d: how many per-executable entries have no target, leaving out ignored ones (F22).
.DESCRIPTION
    Counts at the ConvertTo-AUExeUsage grain (exe build and target, users combined), so it equals the
    number of Unmatched entries in that output whose representative isn't ignored.
.PARAMETER Entries
    The entries, with this run's Target and Classification.
#>
    param (
        [object[]]$Entries
    )

    $Count = 0
    foreach ($Group in @(Get-AUExeGroups $Entries))
    {
        if ($Group.Matched) { continue }
        $Classification = $Group.Representative.Classification
        if ($null -ne $Classification -and $Classification.Ignored -eq $true) { continue }
        $Count++
    }
    return $Count
}#endfunction

function ConvertTo-AUChunks
{
    <#
.SYNOPSIS
    GZips JSON, Base64-encodes it, and splits it into ordered pieces of at most ChunkSize characters (F46).
.DESCRIPTION
    The one copy of version 19's InstalledApps compression and split (F32): the InstalledApps upload
    calls it with metering off and on, and the ExeUsage blob uses it too. The GZip stream and the
    StreamWriter keep their defaults (default compression level, UTF-8 without a BOM), as version 19
    did, so the pieces equal version 19's for the same JSON. Version 19 split with
    -split "(.{N})" and dropped the empty strings; the Substring loop gives the same pieces (Base64
    has no line breaks) without the regex cost on a large blob. No cap: the caller decides how many
    pieces fit (D44). A failure (such as text UTF-8 can't encode) throws to the caller, as in version 19.
.PARAMETER Json
    The JSON text. $null is the empty string, as version 19 wrote an empty app list.
.PARAMETER ChunkSize
    The piece length: 64512 for the Log Ingestion API, 31744 for the classic API.
#>
    [OutputType([string[]])]
    param (
        [string]$Json,
        [ValidateRange(1, 2147483647)]
        [int]$ChunkSize
    )

    $Buffer = New-Object System.IO.MemoryStream
    $Writer = $null
    try
    {
        $Gzip = New-Object System.IO.Compression.GZipStream($Buffer, [System.IO.Compression.CompressionMode]::Compress)
        $Writer = New-Object System.IO.StreamWriter($Gzip)
        $Writer.Write($Json)
        $Writer.Close()
        $Base64 = [System.Convert]::ToBase64String($Buffer.ToArray())
    }
    finally
    {
        if ($null -ne $Writer) { $Writer.Dispose() }
        $Buffer.Dispose()
    }

    $Pieces = New-Object System.Collections.Generic.List[string]
    for ($Start = 0; $Start -lt $Base64.Length; $Start += $ChunkSize)
    {
        $Pieces.Add($Base64.Substring($Start, [Math]::Min($ChunkSize, $Base64.Length - $Start)))
    }
    return , $Pieces.ToArray()
}#endfunction

$script:AULockName = 'Global\PowerStacksAppUsage'
# The outbox lock: the App Inventory sends with metering on hold it, not the run lock, so a send that
# backs off for minutes (Invoke-LogSubmission) never makes an overlapping run's App Usage AppUsageBusy.
$script:AUOutboxLockName = 'Global\PowerStacksAppUsageOutbox'
# Well-known SIDs, never localized names: SYSTEM and Administrators (F27).
$script:AULockAclSids = @('S-1-5-18', 'S-1-5-32-544')

# The inventory log is readable by standard users (C:\Windows\Logs grants BUILTIN\Users read), so App
# Usage log lines name no other user (D18): no SIDs, no profile paths, and no paths under a profile.
# They log counts and exe names; text that could hold a user's path or SID, such as an exception
# message, goes through Get-AUSafeLogText.
$script:AUSidPattern = 'S-1-\d+(-\d+){3,}'
$script:AUProfileFolderPattern = '(?i)\\Users\\[^\\''"]+?(?=\\|''|"|:\s|$)'

function Get-AUSafeLogText
{
    <#
.SYNOPSIS
    Returns text for the log with user SIDs replaced by <SID> and the folder under \Users by <user> (D18).
.DESCRIPTION
    A SID with three or more subauthorities (an account, such as S-1-5-21-... or S-1-12-1-...) is
    replaced, so well-known SIDs such as S-1-5-18 and S-1-5-32-544 stay. In a path, the folder
    right under \Users (the profile folder, named for the user) becomes <user>; the rest of the
    path stays. Never throws.
.PARAMETER Text
    The text, such as an exception message or a hive copy's path.
#>
    param (
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    try
    {
        $Text = [regex]::Replace($Text, $script:AUSidPattern, '<SID>')
        return [regex]::Replace($Text, $script:AUProfileFolderPattern, '\Users\<user>')
    }
    catch { return '<text withheld>' }
}#endfunction

function Get-AUFileLeaf
{
    <#
.SYNOPSIS
    Returns the file name at the end of a path, for a log line that mustn't name the folder (D18). Never throws.
.PARAMETER Path
    A drive-letter or kernel path.
#>
    param (
        [string]$Path
    )

    if ([string]::IsNullOrEmpty($Path)) { return '' }
    $Text = $Path.TrimEnd([char[]]@('\', '/'))
    return $Text.Substring($Text.LastIndexOfAny([char[]]@('\', '/')) + 1)
}#endfunction

function Test-AUExceptionType
{
    <#
.SYNOPSIS
    Returns true when the exception, or any exception it wraps, is of the given type.
.DESCRIPTION
    PowerShell wraps a .NET method's exception in a MethodInvocationException, so the real cause is
    often an inner exception.
.PARAMETER Exception
    The exception to check.
.PARAMETER Type
    The exception type to look for.
#>
    param (
        [Exception]$Exception,
        [type]$Type
    )

    for ($Current = $Exception; $null -ne $Current; $Current = $Current.InnerException)
    {
        if ($Type.IsInstanceOfType($Current)) { return $true }
    }
    return $false
}#endfunction

function Open-AULockMutex
{
    <#
.SYNOPSIS
    Opens the named run lock mutex, creating it when no process has it open.
.DESCRIPTION
    A mutex it creates grants SYSTEM and Administrators full control (MutexSecurity, an in-box type),
    so an administrator's manual run can open a mutex the scheduled SYSTEM run created (F27). The
    mutex isn't owned on return; the caller waits on it. Throws on failure, for example an
    UnauthorizedAccessException when the caller lacks access to an existing mutex. The only open
    path for the lock, so a test can make it fail.
.PARAMETER Name
    The mutex name, Global\PowerStacksAppUsage.
#>
    param (
        [string]$Name
    )

    $Security = New-Object Security.AccessControl.MutexSecurity
    foreach ($Sid in $script:AULockAclSids)
    {
        $Identity = New-Object Security.Principal.SecurityIdentifier $Sid
        $Security.AddAccessRule((New-Object Security.AccessControl.MutexAccessRule($Identity, [Security.AccessControl.MutexRights]::FullControl, [Security.AccessControl.AccessControlType]::Allow)))
    }
    $CreatedNew = $false
    return [Threading.Mutex]::new($false, $Name, [ref]$CreatedNew, $Security)
}#endfunction

function Invoke-AUWithLock
{
    <#
.SYNOPSIS
    Runs Body while holding the App Usage run lock, so two overlapping inventory runs never both run App Usage.
.DESCRIPTION
    Waits up to TimeoutSeconds for the mutex Name (the run lock Global\PowerStacksAppUsage by
    default), runs Body on this thread, and releases the mutex in finally (a mutex must be released
    by the thread that took it, so Body is never moved to a job or runspace). Returns Acquired,
    Abandoned, Result (Body's output), and Error (the message when Body threw, else $null).
    A mutex left abandoned by a run that ended without releasing it counts as acquired, with
    Abandoned true. A timeout, an UnauthorizedAccessException, or any other failure to open or wait
    gives Acquired false and Body never runs; for the run lock the caller reports AppUsageBusy
    (Review Focus 1, F27). Never throws, even when Body throws.
.PARAMETER Body
    The work to run under the lock.
.PARAMETER TimeoutSeconds
    How long to wait for the lock.
.PARAMETER Name
    The mutex: $script:AULockName (the run lock) by default, or $script:AUOutboxLockName.
#>
    param (
        [scriptblock]$Body,
        [int]$TimeoutSeconds = 60,
        [string]$Name = $script:AULockName
    )

    $Outcome = [pscustomobject]@{ Acquired = $false; Abandoned = $false; Result = $null; Error = $null }
    $Mutex = $null
    try
    {
        try
        {
            $Mutex = Open-AULockMutex -Name $Name
            try { $Outcome.Acquired = [bool]$Mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds)) }
            catch
            {
                if (-not (Test-AUExceptionType $_.Exception ([Threading.AbandonedMutexException]))) { throw }
                $Outcome.Acquired = $true
                $Outcome.Abandoned = $true
                Write-CMTraceLog -Message "App Usage: an earlier run ended without releasing lock $Name; this run took it over." -Component 'AppUsage' -Type 2
            }
        }
        catch
        {
            $Outcome.Acquired = $false
            if (Test-AUExceptionType $_.Exception ([UnauthorizedAccessException])) { $Reason = 'access was denied' }
            else { $Reason = 'it could not be opened or waited on' }
            Write-CMTraceLog -Message "App Usage: skipped this run because $Reason on lock ${Name}: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 2
            return $Outcome
        }
        if (-not $Outcome.Acquired)
        {
            Write-CMTraceLog -Message "App Usage: skipped this run because another run held lock $Name for $TimeoutSeconds seconds." -Component 'AppUsage' -Type 2
            return $Outcome
        }
        try { $Outcome.Result = & $Body }
        catch
        {
            $Outcome.Error = $_.Exception.Message
            Write-CMTraceLog -Message "App Usage: the work under lock $Name failed: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3
        }
        finally
        {
            try { $Mutex.ReleaseMutex() }
            catch { Write-CMTraceLog -Message "App Usage: couldn't release lock ${Name}: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3 }
        }
        return $Outcome
    }
    finally
    {
        if ($null -ne $Mutex)
        {
            try { $Mutex.Dispose() }
            catch { Write-CMTraceLog -Message "App Usage: couldn't close lock ${Name}: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3 }
        }
    }
}#endfunction

# Snapshot and SRUM reader (Task 12). Copies come only from a shadow copy, into the protected work
# folder C:\Windows\PowerStacksAppUsage\<RunId> (D18, F28); the live SRUDB.dat and live hives are
# never opened.
# Next to the ledger: standard users can't create items in C:\Windows, so nobody else can make it first.
# Plain strings, not [IO.Path]::Combine, so the region loads without an error record in Constrained
# Language Mode, where App Usage skips (D37).
$script:AUWorkRoot = "$env:SystemRoot\PowerStacksAppUsage"
$script:AUEsentPath = "$env:SystemRoot\Microsoft.NET\assembly\GAC_MSIL\microsoft.isam.esent.interop\v4.0_10.0.0.0__31bf3856ad364e35\Microsoft.Isam.Esent.Interop.dll"
$script:AUEsentutlPath = "$env:SystemRoot\System32\esentutl.exe"
$script:AUCmdPath = "$env:SystemRoot\System32\cmd.exe"
$script:AULiveSrumPath = "$env:SystemRoot\System32\sru\SRUDB.dat"
$script:AUTimelineTable = '{5C8CF1C7-7257-4F13-B223-970EF5939312}'
$script:AUResourceTable = '{D10CA2FE-6FCF-4F6D-848E-B2E99266FA89}'
# Task 0.1: focus is InFocusS and input is UserInputS, in seconds; null means 0. DurationMS isn't focus.
$script:AUFocusColumn = 'InFocusS'
$script:AUInputColumn = 'UserInputS'
# Time budgets, in seconds, for each external step. A step that runs out is stopped and counts as failed.
$script:AUToolTimeoutSeconds = 60
$script:AURepairTimeoutSeconds = 900
# WMI queries; creating a shadow copy can take longer than a query.
$script:AUCimTimeoutSeconds = 30
$script:AUShadowCreateTimeoutSeconds = 120
# A killed run's folder and shadow copy are removed by the next run once they're this old (F28).
$script:AUStaleRunHours = 24
# The marker file in a run folder that names its shadow copy, so a later run can delete it.
$script:AUShadowMarker = 'shadow.id'
# The least free space the work folder's drive must keep before the snapshot copies are made (I4);
# the copies also need three times their own size free.
$script:AUMinFreeBytes = 2GB
# The status when the work root can't be made safe, so App Usage skips the run.
$script:AUWorkDirUntrustedStatus = 'SrumReadFailed:WorkDirUntrusted'

function New-AUProtectedSecurity
{
    <#
.SYNOPSIS
    Builds the protected DACL: full control for SYSTEM and Administrators only, inheritance off.
.DESCRIPTION
    Uses the well-known SIDs, never localized names. With Folder, returns a DirectorySecurity whose
    entries are inherited by everything created inside, so copies in a protected folder get the
    same two entries and nothing else, and whose owner is Administrators (an elevated
    administrator's token may make the user the default owner). Otherwise returns a FileSecurity.
.PARAMETER Folder
    Builds the folder form.
#>
    param (
        [switch]$Folder
    )

    if ($Folder)
    {
        $Security = New-Object Security.AccessControl.DirectorySecurity
        $Security.SetOwner((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'))
        $Inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    }
    else
    {
        $Security = New-Object Security.AccessControl.FileSecurity
        $Inheritance = [Security.AccessControl.InheritanceFlags]::None
    }
    $Security.SetAccessRuleProtection($true, $false)
    foreach ($Sid in $script:AULedgerAclSids)
    {
        $Identity = New-Object Security.Principal.SecurityIdentifier $Sid
        $Security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($Identity, [Security.AccessControl.FileSystemRights]::FullControl, $Inheritance, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)))
    }
    return $Security
}#endfunction

function Remove-AUFolderTree
{
    <#
.SYNOPSIS
    Deletes a folder SYSTEM created under the protected work root, and everything in it, never following a link.
.DESCRIPTION
    Only for trees no standard user can write to (a run folder inside the protected root that
    Test-AUTrustedFolder trusts): a folder someone else controls could be swapped for a junction
    mid-delete, so an untrusted folder is never passed here. A link is deleted itself, never
    its target. [IO.Directory]::Delete with recursion can't be used: on .NET Framework it fails on
    a junction inside the tree. Read-only files are made writable first. Throws on failure.
.PARAMETER Path
    The folder.
#>
    param (
        [string]$Path
    )

    $Folder = New-Object IO.DirectoryInfo $Path
    if (-not $Folder.Exists) { return }
    if (($Folder.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)
    {
        foreach ($Item in $Folder.GetFileSystemInfos())
        {
            if ($Item -is [IO.DirectoryInfo]) { Remove-AUFolderTree -Path $Item.FullName; continue }
            if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and ($Item.Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0) { $Item.Attributes = [IO.FileAttributes]::Normal }
            $Item.Delete()
        }
    }
    $Folder.Delete()
}#endfunction

function Test-AUItemPresent
{
    <#
.SYNOPSIS
    Returns true when anything (a file, folder, or link, even a broken one) is at Path.
.DESCRIPTION
    Reads the entry's own attributes, without following a link. Fails closed: any error but "not
    found" counts as present, so the caller treats it as untrusted. Never throws.
.PARAMETER Path
    The path.
#>
    param (
        [string]$Path
    )

    try
    {
        [void][IO.File]::GetAttributes($Path)
        return $true
    }
    catch
    {
        if ((Test-AUExceptionType $_.Exception ([IO.FileNotFoundException])) -or (Test-AUExceptionType $_.Exception ([IO.DirectoryNotFoundException]))) { return $false }
        return $true
    }
}#endfunction

function Test-AUReparsePoint
{
    <#
.SYNOPSIS
    Returns true when Path is a link (a reparse point), or when its attributes can't be read.
.DESCRIPTION
    GetAttributes reads the entry itself and doesn't follow a link. Fails closed: an error counts as
    a link. Never throws.
.PARAMETER Path
    The file or folder.
#>
    param (
        [string]$Path
    )

    try { return (([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) -ne 0) }
    catch { return $true }
}#endfunction

function Test-AUTrustedOwner
{
    <#
.SYNOPSIS
    Returns true when a security descriptor's owner is SYSTEM or Administrators.
.PARAMETER Security
    A FileSecurity or DirectorySecurity.
#>
    param (
        $Security
    )

    return ($script:AULedgerAclSids -contains $Security.GetOwner([Security.Principal.SecurityIdentifier]).Value)
}#endfunction

function Test-AUTrustedFolder
{
    <#
.SYNOPSIS
    Returns true when Path is a real folder that only SYSTEM or an administrator could have made the way it is.
.DESCRIPTION
    True only for a folder that isn't a link, is owned by SYSTEM or Administrators, and has a
    protected DACL whose every entry is SYSTEM or Administrators. Its contents were then written by
    SYSTEM or an administrator only.
    In-box .NET can't read a folder's attributes and security from one handle that doesn't follow
    links, and GetAccessControl opens the path and follows one. So the attributes are read right
    before and right after the security, and the folder fails when either read shows a link or the
    two differ. Fails closed on any error. Never throws.
.PARAMETER Path
    The folder.
#>
    param (
        [string]$Path
    )

    try
    {
        $Before = [IO.File]::GetAttributes($Path)
        $Acl = [IO.Directory]::GetAccessControl($Path, [Security.AccessControl.AccessControlSections]'Owner, Access')
        $After = [IO.File]::GetAttributes($Path)
        if ($Before -ne $After) { return $false }
        if (($Before -band [IO.FileAttributes]::Directory) -eq 0 -or ($Before -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        if (-not (Test-AUTrustedOwner -Security $Acl)) { return $false }
        if (-not $Acl.AreAccessRulesProtected) { return $false }
        $Rules = @($Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        if ($Rules.Count -eq 0) { return $false }
        foreach ($Rule in $Rules)
        {
            if ($script:AULedgerAclSids -notcontains $Rule.IdentityReference.Value) { return $false }
        }
        return $true
    }
    catch { return $false }
}#endfunction

function New-AUProtectedFolder
{
    <#
.SYNOPSIS
    Creates a new folder with the protected DACL, owned by Administrators, and checks the result.
.DESCRIPTION
    Only ever creates: the DACL is set at creation (CreateDirectory with a DirectorySecurity), never
    on an existing item. CreateDirectory accepts a folder that already exists without applying the
    DACL, so the result must pass Test-AUTrustedFolder. Throws, with a message starting
    $script:AUWorkDirUntrustedStatus, when it doesn't.
.PARAMETER Path
    The folder to create; nothing may exist at it.
#>
    param (
        [string]$Path
    )

    [void][IO.Directory]::CreateDirectory($Path, (New-AUProtectedSecurity -Folder))
    if (-not (Test-AUTrustedFolder -Path $Path)) { throw "$($script:AUWorkDirUntrustedStatus): $Path isn't the protected folder just created." }
}#endfunction

function Remove-AUShadowCopy
{
    <#
.SYNOPSIS
    Deletes a shadow copy by ID. Returns true when it's gone (or was already gone). Never throws.
.PARAMETER ShadowId
    The shadow copy ID, a GUID in braces.
#>
    param (
        [string]$ShadowId
    )

    try
    {
        if ($ShadowId -notmatch '^\{[0-9A-Fa-f-]+\}$') { throw "'$ShadowId' isn't a shadow copy ID." }
        $Shadow = Get-CimInstance -ClassName Win32_ShadowCopy -Filter "ID='$ShadowId'" -OperationTimeoutSec $script:AUCimTimeoutSeconds -ErrorAction Stop
        if ($Shadow) { $Shadow | Remove-CimInstance -OperationTimeoutSec $script:AUCimTimeoutSeconds -ErrorAction Stop }
        return $true
    }
    catch
    {
        Write-CMTraceLog -Message "App Usage: couldn't remove shadow copy $ShadowId`: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3
        return $false
    }
}#endfunction

function Get-AUShadowOrigin
{
    <#
.SYNOPSIS
    Returns Run when the shadow copy exists and was made while the run folder existed, Other when it
    doesn't or wasn't, and Unknown when Win32_ShadowCopy couldn't be read.
.DESCRIPTION
    A stale run's marker names the shadow copy it made. It's deleted only when Win32_ShadowCopy has
    it and its InstallDate falls between the run folder's creation and now (Run), so a marker can
    never point the sweep at another shadow copy. A shadow copy that isn't there, or a marker that
    isn't a shadow copy ID, is Other. When the query fails, it's Unknown, and the sweep keeps the
    folder and its marker for the next run, so a passing WMI error never leaves the shadow copy
    with nothing that names it. Never throws.
.PARAMETER ShadowId
    The shadow copy ID from the marker, a GUID in braces.
.PARAMETER SinceUtc
    The run folder's creation time.
#>
    param (
        [string]$ShadowId,
        [datetime]$SinceUtc
    )

    if ($ShadowId -notmatch '^\{[0-9A-Fa-f-]+\}$') { return 'Other' }
    try { $Shadow = Get-CimInstance -ClassName Win32_ShadowCopy -Filter "ID='$ShadowId'" -OperationTimeoutSec $script:AUCimTimeoutSeconds -ErrorAction Stop | Select-Object -First 1 }
    catch { return 'Unknown' }
    try
    {
        if (-not $Shadow -or $Shadow.InstallDate -isnot [datetime]) { return 'Other' }
        $Installed = $Shadow.InstallDate.ToUniversalTime()
        if ($Installed -ge $SinceUtc.ToUniversalTime() -and $Installed -le [datetime]::UtcNow) { return 'Run' }
        return 'Other'
    }
    catch { return 'Other' }
}#endfunction

function Read-AUShadowMarker
{
    <#
.SYNOPSIS
    Returns the shadow copy ID in a run folder's marker, or $null when there's no trusted marker.
.DESCRIPTION
    The marker counts only when it isn't a link and SYSTEM or Administrators owns it (New-AUSnapshot
    creates it with that owner). Never throws.
.PARAMETER Folder
    The run folder.
#>
    param (
        [string]$Folder
    )

    try
    {
        $Marker = [IO.Path]::Combine($Folder, $script:AUShadowMarker)
        if (-not [IO.File]::Exists($Marker) -or (Test-AUReparsePoint -Path $Marker)) { return $null }
        if (-not (Test-AUTrustedOwner -Security ([IO.File]::GetAccessControl($Marker, [Security.AccessControl.AccessControlSections]::Owner)))) { return $null }
        if (Test-AUReparsePoint -Path $Marker) { return $null }
        $ShadowId = ([IO.File]::ReadAllText($Marker)).Trim()
        if ($ShadowId -notmatch '^\{[0-9A-Fa-f-]+\}$') { return $null }
        return $ShadowId
    }
    catch { return $null }
}#endfunction

function Clear-AUStaleRuns
{
    <#
.SYNOPSIS
    Removes run folders, and the shadow copies their markers name, that a killed run left in the work root.
.DESCRIPTION
    Only call it on a root Test-AUTrustedFolder trusts that this call didn't just create. The root's
    link flag is checked again right before it's listed. A child is considered only when it's a real
    folder that Test-AUTrustedFolder trusts, it isn't the current run, and it was created more than
    MaxAgeHours ago. Its marker's shadow copy is deleted only when the marker is trusted
    (Read-AUShadowMarker) and the shadow copy was made during the folder's lifetime
    (Get-AUShadowOrigin is Run); then the folder is removed (Remove-AUFolderTree). When the shadow
    copy couldn't be checked (Unknown), the folder and its marker stay for the next run. Anything
    else is left alone. Never throws.
.PARAMETER Root
    The protected work root.
.PARAMETER Except
    The current RunId.
.PARAMETER MaxAgeHours
    How old a run folder must be to count as stale.
#>
    param (
        [string]$Root,
        [string]$Except,
        [int]$MaxAgeHours = 24
    )

    try
    {
        if (Test-AUReparsePoint -Path $Root)
        {
            Write-CMTraceLog -Message "App Usage: $Root became a link, so no stale runs were checked." -Component 'AppUsage' -Type 3
            return
        }
        $Cutoff = [datetime]::UtcNow.AddHours(-$MaxAgeHours)
        foreach ($Folder in (New-Object IO.DirectoryInfo $Root).GetDirectories())
        {
            try
            {
                if ([string]::Equals($Folder.Name, $Except, [StringComparison]::OrdinalIgnoreCase)) { continue }
                if (($Folder.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or -not (Test-AUTrustedFolder -Path $Folder.FullName))
                {
                    Write-CMTraceLog -Message "App Usage: left $($Folder.FullName) alone, because it isn't a protected run folder." -Component 'AppUsage' -Type 2
                    continue
                }
                $CreatedUtc = $Folder.CreationTimeUtc
                if ($CreatedUtc -gt $Cutoff) { continue }
                $ShadowId = Read-AUShadowMarker -Folder $Folder.FullName
                if ($ShadowId)
                {
                    $Origin = Get-AUShadowOrigin -ShadowId $ShadowId -SinceUtc $CreatedUtc
                    if ($Origin -eq 'Unknown')
                    {
                        Write-CMTraceLog -Message "App Usage: couldn't check shadow copy $ShadowId, so the stale run folder $($Folder.FullName) and its marker stay for the next run." -Component 'AppUsage' -Type 2
                        continue
                    }
                    if ($Origin -eq 'Run') { [void](Remove-AUShadowCopy -ShadowId $ShadowId) }
                    else { Write-CMTraceLog -Message "App Usage: left shadow copy $ShadowId alone; it isn't one that $($Folder.FullName) made." -Component 'AppUsage' -Type 2 }
                }
                Remove-AUFolderTree -Path $Folder.FullName
                Write-CMTraceLog -Message "App Usage: removed the stale run folder $($Folder.FullName), created $($CreatedUtc.ToString('o'))." -Component 'AppUsage' -Type 2
            }
            catch { Write-CMTraceLog -Message "App Usage: couldn't remove the stale run folder $($Folder.FullName): $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3 }
        }
    }
    catch { Write-CMTraceLog -Message "App Usage: couldn't check $Root for stale run folders: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3 }
}#endfunction

function New-AUWorkDir
{
    <#
.SYNOPSIS
    Creates this run's protected work folder, <Root>\<RunId>, and returns its path (F28).
.DESCRIPTION
    The root is C:\Windows\PowerStacksAppUsage, next to the ledger: standard users can't create
    items in C:\Windows, so nobody else can make the root first. A missing root is created with the
    protected DACL (SYSTEM and Administrators full control only, inheritance off, owner
    Administrators), and so is the run folder; copies made inside inherit it, so no standard user
    can read another user's hive copy or anyone's SRUM activity (D18).
    An existing root that Test-AUTrustedFolder doesn't trust (not a folder, a link, another owner, or
    another DACL) is never moved, changed, listed, or deleted: this throws, with a message starting
    $script:AUWorkDirUntrustedStatus, and App Usage skips the run with that status. The DACL is only
    ever set on a folder this call creates. On an existing trusted root, run folders a killed run
    left more than $script:AUStaleRunHours hours ago are removed, with their shadow copies
    (Clear-AUStaleRuns). Throws when RunId isn't a plain folder name or a folder can't be made.
.PARAMETER RunId
    This run's ID: letters, digits, '.', '_', and '-', starting with a letter or digit.
.PARAMETER Root
    The work root, C:\Windows\PowerStacksAppUsage by default. Tests pass a TestDrive path.
#>
    param (
        [string]$RunId,
        [string]$Root = $script:AUWorkRoot
    )

    if ($RunId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "New-AUWorkDir needs a plain folder name for RunId; got '$RunId'." }
    if (Test-AUItemPresent -Path $Root)
    {
        if (-not (Test-AUTrustedFolder -Path $Root)) { throw "$($script:AUWorkDirUntrustedStatus): $Root isn't a folder only SYSTEM and Administrators control, so it was left alone." }
        Clear-AUStaleRuns -Root $Root -Except $RunId -MaxAgeHours $script:AUStaleRunHours
    }
    else { New-AUProtectedFolder -Path $Root }

    $Path = [IO.Path]::Combine($Root, $RunId)
    if (Test-AUItemPresent -Path $Path) { throw "$($script:AUWorkDirUntrustedStatus): the run folder $Path already exists." }
    New-AUProtectedFolder -Path $Path
    return $Path
}#endfunction

function Invoke-AUProcess
{
    <#
.SYNOPSIS
    Runs an in-box program with no window and no input, within a time budget, and returns its output.
.DESCRIPTION
    Returns ExitCode ($null when it timed out), TimedOut, and Output (standard output and error).
    A program still running at the budget is stopped. The working directory is always given, so a
    program that writes files to its working directory (esentutl /p writes an .INTEG.RAW file) writes
    them inside the work folder. Throws when the program can't start.
.PARAMETER FilePath
    The program.
.PARAMETER Arguments
    The command line arguments.
.PARAMETER WorkingDirectory
    The working directory.
.PARAMETER TimeoutSeconds
    The time budget.
#>
    param (
        [string]$FilePath,
        [string]$Arguments,
        [string]$WorkingDirectory,
        [int]$TimeoutSeconds
    )

    $Info = New-Object Diagnostics.ProcessStartInfo
    $Info.FileName = $FilePath
    $Info.Arguments = $Arguments
    $Info.WorkingDirectory = $WorkingDirectory
    $Info.UseShellExecute = $false
    $Info.CreateNoWindow = $true
    $Info.RedirectStandardInput = $true
    $Info.RedirectStandardOutput = $true
    $Info.RedirectStandardError = $true
    $Process = [Diagnostics.Process]::Start($Info)
    try
    {
        $Process.StandardInput.Close()
        $Output = $Process.StandardOutput.ReadToEndAsync()
        $ErrorOutput = $Process.StandardError.ReadToEndAsync()
        if (-not $Process.WaitForExit($TimeoutSeconds * 1000))
        {
            try { $Process.Kill() } catch { }
            [void]$Process.WaitForExit(10000)
            return [pscustomobject]@{ ExitCode = $null; TimedOut = $true; Output = '' }
        }
        $Process.WaitForExit()
        return [pscustomobject]@{ ExitCode = $Process.ExitCode; TimedOut = $false; Output = "$($Output.Result)$($ErrorOutput.Result)" }
    }
    finally { $Process.Dispose() }
}#endfunction

function Mount-AUShadow
{
    <#
.SYNOPSIS
    Links a folder to the shadow copy's root, so ordinary file paths reach it. Returns true when linked.
.DESCRIPTION
    Windows PowerShell 5.1 can't use \\?\GLOBALROOT shadow paths (Copy-Item and System.IO reject them,
    robocopy rejects them, and cmd's copy skips hidden files such as NTUSER.DAT), so a directory
    symbolic link (cmd's mklink /d, as the prototype did) points at the shadow root. The link goes
    inside the protected work folder, which standard users can't open. Never throws.
.PARAMETER ShadowRoot
    The shadow copy's device path, \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy<n>.
.PARAMETER LinkPath
    The link to create; it must not exist.
#>
    param (
        [string]$ShadowRoot,
        [string]$LinkPath
    )

    try
    {
        $Result = Invoke-AUProcess -FilePath $script:AUCmdPath -Arguments "/d /c mklink /d `"$LinkPath`" `"$ShadowRoot\`"" -WorkingDirectory ([IO.Path]::GetDirectoryName($LinkPath)) -TimeoutSeconds $script:AUToolTimeoutSeconds
        if ($Result.ExitCode -eq 0 -and [IO.Directory]::Exists($LinkPath)) { return $true }
        Write-CMTraceLog -Message "App Usage: couldn't link $LinkPath to the shadow copy (exit $($Result.ExitCode), timed out $($Result.TimedOut)): $(([string]$Result.Output).Trim())" -Component 'AppUsage' -Type 3
    }
    catch { Write-CMTraceLog -Message "App Usage: couldn't link $LinkPath to the shadow copy: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3 }
    return $false
}#endfunction

function Copy-AUShadowFile
{
    <#
.SYNOPSIS
    Copies a file, or every file in a folder (Source ending in \*), out of the linked shadow copy.
.DESCRIPTION
    Source is under the shadow link (Mount-AUShadow), so .NET copies work, hidden files included. A
    copy is a new file, so it gets the destination folder's inherited DACL, never the source's.
    Returns true when every file copied; a file that fails is logged and the rest are still copied.
    Never throws.
.PARAMETER Source
    A file under the shadow link, or <folder>\* for every file in a folder.
.PARAMETER Destination
    The destination file, or the destination folder for <folder>\*.
#>
    param (
        [string]$Source,
        [string]$Destination
    )

    $Pairs = New-Object Collections.Generic.List[object]
    try
    {
        if ($Source.EndsWith('\*'))
        {
            foreach ($File in [IO.Directory]::GetFiles($Source.Substring(0, $Source.Length - 2)))
            {
                $Pairs.Add(@($File, [IO.Path]::Combine($Destination, [IO.Path]::GetFileName($File))))
            }
        }
        else { $Pairs.Add(@($Source, $Destination)) }
    }
    catch
    {
        Write-CMTraceLog -Message "App Usage: couldn't list $(Get-AUSafeLogText $Source) in the shadow copy: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 2
        return $false
    }
    $AllCopied = ($Pairs.Count -gt 0)
    foreach ($Pair in $Pairs)
    {
        try { [IO.File]::Copy($Pair[0], $Pair[1], $true) }
        catch
        {
            $AllCopied = $false
            Write-CMTraceLog -Message "App Usage: couldn't copy $(Get-AUSafeLogText $Pair[0]) from the shadow copy: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 2
        }
    }
    return $AllCopied
}#endfunction

function ConvertTo-AUShadowPath
{
    <#
.SYNOPSIS
    Maps a path on the system drive to the same path inside the shadow copy, or $null when it's on another drive.
.PARAMETER Path
    A full path, for example C:\Users\name.
.PARAMETER ShadowRoot
    The shadow copy's root as an ordinary path: the Mount-AUShadow link.
#>
    param (
        [string]$Path,
        [string]$ShadowRoot
    )

    $Drive = "$($env:SystemDrive)\"
    if ([string]::IsNullOrWhiteSpace($Path) -or -not $Path.StartsWith($Drive, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    return "$ShadowRoot\$($Path.Substring($Drive.Length).TrimEnd('\'))"
}#endfunction

function Get-AUMachineDomainSid
{
    <#
.SYNOPSIS
    Returns the machine account-domain SID (S-1-5-21-x-y-z), or '' when it can't be read.
.DESCRIPTION
    Takes the domain portion of a local account's SID (Win32_UserAccount, LocalAccount=TRUE). With
    '', Get-AUUserType counts every S-1-5-21 SID as Domain, which is still interactive. Never throws.
#>
    try
    {
        foreach ($Account in @(Get-CimInstance -ClassName Win32_UserAccount -Filter 'LocalAccount=TRUE' -OperationTimeoutSec $script:AUCimTimeoutSeconds -ErrorAction Stop))
        {
            $Sid = [string]$Account.SID
            if ($Sid -match '^S-1-5-21-\d+-\d+-\d+-\d+$') { return (New-Object Security.Principal.SecurityIdentifier $Sid).AccountDomainSid.Value }
        }
        Write-CMTraceLog -Message 'App Usage: no local account SID found, so the machine domain SID is blank.' -Component 'AppUsage' -Type 2
    }
    catch { Write-CMTraceLog -Message "App Usage: couldn't read the machine domain SID: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 2 }
    return ''
}#endfunction

function Get-AUProfileList
{
    <#
.SYNOPSIS
    Returns every profile in ProfileList: Sid and ProfilePath (environment variables expanded).
.DESCRIPTION
    ProfileList in HKLM lists every profile on the device, signed in or not. Keys that aren't a
    plain SID (for example a .bak copy) are skipped. Returns nothing when ProfileList can't be read.
    Never throws.
#>
    $Key = $null
    try
    {
        $Key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList')
        if ($null -eq $Key) { return }
        foreach ($Sid in $Key.GetSubKeyNames())
        {
            if ($Sid -notmatch '^S-1-\d+(-\d+)+$') { continue }
            $SubKey = $Key.OpenSubKey($Sid)
            if ($null -eq $SubKey) { continue }
            try { $ProfilePath = [string]$SubKey.GetValue('ProfileImagePath') }
            finally { $SubKey.Close() }
            [pscustomobject]@{ Sid = $Sid; ProfilePath = [Environment]::ExpandEnvironmentVariables($ProfilePath) }
        }
    }
    catch { Write-CMTraceLog -Message "App Usage: couldn't read ProfileList: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3 }
    finally { if ($null -ne $Key) { $Key.Close() } }
}#endfunction

function Test-AUHiveLoaded
{
    <#
.SYNOPSIS
    Returns true when the user's hive is loaded under HKEY_USERS (the user is signed in).
.PARAMETER Sid
    The user SID.
#>
    param (
        [string]$Sid
    )

    $Key = $null
    try
    {
        $Key = [Microsoft.Win32.Registry]::Users.OpenSubKey($Sid)
        return ($null -ne $Key)
    }
    catch { return $false }
    finally { if ($null -ne $Key) { $Key.Close() } }
}#endfunction

function Write-AUShadowMarker
{
    <#
.SYNOPSIS
    Creates <Folder>\shadow.id holding the shadow copy ID, owned by Administrators with the protected DACL.
.DESCRIPTION
    The owner is set at creation, so the stale-run sweep (Read-AUShadowMarker) trusts it even when an
    elevated administrator, whose token may make the user the default owner, ran the inventory.
    Throws on failure.
.PARAMETER Folder
    The run folder.
.PARAMETER ShadowId
    The shadow copy ID.
#>
    param (
        [string]$Folder,
        [string]$ShadowId
    )

    $Security = New-AUProtectedSecurity
    $Security.SetOwner((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'))
    $Stream = [IO.File]::Create([IO.Path]::Combine($Folder, $script:AUShadowMarker), 4096, [IO.FileOptions]::None, $Security)
    try
    {
        $Bytes = [Text.Encoding]::ASCII.GetBytes($ShadowId)
        $Stream.Write($Bytes, 0, $Bytes.Length)
    }
    finally { $Stream.Dispose() }
}#endfunction

function Get-AUCopyBytes
{
    <#
.SYNOPSIS
    Returns the total size, in bytes, of the files New-AUSnapshot copies: every file in the SRUM folder, and each hive folder's NTUSER.DAT, NTUSER.DAT.LOG1, and NTUSER.DAT.LOG2.
.DESCRIPTION
    Sizes are attribute reads; no file is opened. A folder or file that isn't there adds nothing.
    Never throws: a size that can't be read adds nothing, so the 2 GB floor still applies.
.PARAMETER SruFolder
    The SRUM folder under the shadow link.
.PARAMETER HiveFolders
    Each signed-out profile's folder under the shadow link.
#>
    param (
        [string]$SruFolder,
        [string[]]$HiveFolders
    )

    [long]$Total = 0
    try
    {
        if ($SruFolder -and [IO.Directory]::Exists($SruFolder))
        {
            foreach ($File in [IO.Directory]::GetFiles($SruFolder)) { $Total += (New-Object IO.FileInfo $File).Length }
        }
    }
    catch { Write-CMTraceLog -Message "App Usage: couldn't size the SRUM folder in the shadow copy: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 2 }
    foreach ($Folder in @($HiveFolders))
    {
        if (-not $Folder) { continue }
        foreach ($Name in @('NTUSER.DAT', 'NTUSER.DAT.LOG1', 'NTUSER.DAT.LOG2'))
        {
            try
            {
                $Info = New-Object IO.FileInfo ([IO.Path]::Combine($Folder, $Name))
                if ($Info.Exists) { $Total += $Info.Length }
            }
            catch { }
        }
    }
    return $Total
}#endfunction

function Get-AUFreeSpace
{
    <#
.SYNOPSIS
    Returns the free space, in bytes, available on the drive that holds Path, or $null when it can't be read. Never throws.
.PARAMETER Path
    A drive-letter path, such as the run's work folder.
#>
    param (
        [string]$Path
    )

    try
    {
        if ([string]::IsNullOrWhiteSpace($Path) -or $Path -notmatch '^[A-Za-z]:\\') { return $null }
        return [long](New-Object IO.DriveInfo ($Path.Substring(0, 1))).AvailableFreeSpace
    }
    catch { return $null }
}#endfunction

function Get-AUShadowList
{
    <#
.SYNOPSIS
    Returns the client-accessible shadow copies of the system drive, the kind New-AUSnapshot makes: ID and InstallDateUtc.
.DESCRIPTION
    The system drive's volume comes from Win32_Volume, and only Win32_ShadowCopy entries of that
    volume with ClientAccessible set are listed. InstallDateUtc is $null when the install time
    can't be read. Throws when the volume or the shadow copies can't be read, so a caller never
    mistakes a failed read for an empty list.
#>
    $Volume = @(Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='$($env:SystemDrive)'" -OperationTimeoutSec $script:AUCimTimeoutSeconds -ErrorAction Stop) | Select-Object -First 1
    if ($null -eq $Volume -or -not $Volume.DeviceID) { throw "the volume of $($env:SystemDrive) wasn't found." }
    $List = New-Object 'System.Collections.Generic.List[object]'
    foreach ($Shadow in @(Get-CimInstance -ClassName Win32_ShadowCopy -OperationTimeoutSec $script:AUCimTimeoutSeconds -ErrorAction Stop))
    {
        if ($null -eq $Shadow -or $Shadow.ClientAccessible -ne $true) { continue }
        if (-not [string]::Equals([string]$Shadow.VolumeName, [string]$Volume.DeviceID, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $Installed = $null
        if ($Shadow.InstallDate -is [datetime]) { $Installed = $Shadow.InstallDate.ToUniversalTime() }
        $List.Add([pscustomobject]@{ ID = [string]$Shadow.ID; InstallDateUtc = $Installed })
    }
    return $List.ToArray()
}#endfunction

function Remove-AUUnrecordedShadow
{
    <#
.SYNOPSIS
    After a shadow copy request failed or timed out, deletes the shadow copies it may still have made. Returns the ID of one it couldn't delete, or $null.
.DESCRIPTION
    VSS can finish a shadow copy after the request has timed out on the script's side, and nothing
    would record it. A shadow copy counts as this run's only when it's in the list now
    (Get-AUShadowList) but wasn't in the list taken right before the request, and was made at or
    after the run started, so another tool's shadow copies, made earlier, are never touched. Each
    one's ID goes into the run folder's marker before it's deleted, so a run killed meanwhile leaves
    it for the next run's sweep; the marker is removed once all are deleted, and holds the one that
    wasn't otherwise. The log gives counts, never other shadow copies' IDs. Never throws.
.PARAMETER KnownIds
    The shadow copy IDs listed right before the request.
.PARAMETER SinceUtc
    When the run started.
.PARAMETER WorkDir
    The run folder.
#>
    param (
        [string[]]$KnownIds,
        [datetime]$SinceUtc,
        [string]$WorkDir
    )

    try { $Now = @(Get-AUShadowList) }
    catch
    {
        Write-CMTraceLog -Message "App Usage: couldn't list the shadow copies after the request failed, so one it may have made can't be found: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3
        return $null
    }
    $New = @($Now | Where-Object { $null -ne $_ -and $KnownIds -notcontains $_.ID -and $null -ne $_.InstallDateUtc -and $_.InstallDateUtc -ge $SinceUtc })
    if ($New.Count -eq 0) { return $null }
    $Marker = [IO.Path]::Combine($WorkDir, $script:AUShadowMarker)
    $Removed = 0
    $Kept = $null
    foreach ($Shadow in $New)
    {
        try { Write-AUShadowMarker -Folder $WorkDir -ShadowId $Shadow.ID }
        catch { Write-CMTraceLog -Message "App Usage: couldn't write the shadow marker in $WorkDir`: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3 }
        if (Remove-AUShadowCopy -ShadowId $Shadow.ID) { $Removed++ }
        elseif ($null -eq $Kept) { $Kept = $Shadow.ID }
    }
    try
    {
        if ($null -ne $Kept) { Write-AUShadowMarker -Folder $WorkDir -ShadowId $Kept }
        elseif ([IO.File]::Exists($Marker)) { [IO.File]::Delete($Marker) }
    }
    catch { Write-CMTraceLog -Message "App Usage: couldn't update the shadow marker in $WorkDir`: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3 }
    Write-CMTraceLog -Message "App Usage: the shadow copy request failed; removed $Removed of $($New.Count) new shadow copies it made." -Component 'AppUsage' -Type 2
    return $Kept
}#endfunction

function New-AUSnapshot
{
    <#
.SYNOPSIS
    Takes a shadow copy of the system drive and copies SRUDB.dat and signed-out users' hives from it.
.DESCRIPTION
    Returns WorkDir, ShadowId, ShadowRoot, SrumDbPath, HiveCopies, MachineDomainSid, and Status.
    The sru folder (SRUDB.dat and its logs, so esentutl /r can replay them) goes to <WorkDir>\sru.
    Each signed-out user's NTUSER.DAT, with its .LOG1 and .LOG2 when present, goes to
    <WorkDir>\hives\<SID>. HiveCopies maps every ProfileList SID whose hive isn't loaded to its copy,
    or to $null when it couldn't be copied (no shadow copy, a profile off the system drive, or a
    failed copy). Signed-in users aren't in HiveCopies; their hives are read in place. Copies come
    only from the shadow copy, never from a live file, through a link at <WorkDir>\shadow
    (Mount-AUShadow) that's removed once the copies are made. ShadowRoot is the device path the
    copies came from; nothing after this function reads it.
    The shadow copy is released before this function returns, and ShadowId is then $null. While the
    shadow copy exists, its ID is in <WorkDir>\shadow.id, so a run killed mid-snapshot leaves it for
    the next run's New-AUWorkDir to delete. When the release fails, ShadowId and the marker stay,
    and Remove-AUSnapshot tries again. The shadow copies already there are listed before the
    request (Get-AUShadowList; no list, no request); when the request fails or times out, the ones
    it may still have made are deleted (Remove-AUUnrecordedShadow), and one that can't be is kept in
    ShadowId and the marker.
    Before anything is copied, the free space on the work folder's drive (Get-AUFreeSpace) must be
    at least 2 GB and at least three times the size of the copies (Get-AUCopyBytes), which leaves
    room for a repaired SRUM copy. Otherwise nothing is copied and Status is LowDiskSpace; free
    space that can't be read counts as too little.
    Status is OK, ShadowCopyFailed (no shadow copy, or it couldn't be linked; SrumDbPath and every
    hive copy $null), LowDiskSpace (the same, for too little free space), or
    SrumReadFailed:CopyFailed (the shadow copy worked but SRUDB.dat didn't copy). Never throws;
    call Remove-AUSnapshot in finally.
.PARAMETER WorkDir
    The run's work folder, from New-AUWorkDir.
#>
    param (
        [string]$WorkDir
    )

    $Snapshot = [pscustomobject]@{
        WorkDir          = $WorkDir
        ShadowId         = $null
        ShadowRoot       = $null
        SrumDbPath       = $null
        HiveCopies       = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
        MachineDomainSid = ''
        Status           = 'OK'
    }
    try
    {
        $Snapshot.MachineDomainSid = [string](Get-AUMachineDomainSid)
        $SignedOut = @(Get-AUProfileList | Where-Object { -not (Test-AUHiveLoaded -Sid $_.Sid) })
        foreach ($UserProfile in $SignedOut) { $Snapshot.HiveCopies[$UserProfile.Sid] = $null }

        try
        {
            # The shadow copies there already, and the run's start (to the second, the precision of
            # InstallDate), so a request that fails or times out while VSS still makes the shadow
            # copy can find and delete it (item 11). No list, no request.
            $RunStartUtc = [datetime]::UtcNow
            $RunStartUtc = $RunStartUtc.AddTicks( - ($RunStartUtc.Ticks % [TimeSpan]::TicksPerSecond))
            $KnownIds = @(Get-AUShadowList | ForEach-Object { [string]$_.ID })
            try
            {
                $Created = Invoke-CimMethod -ClassName Win32_ShadowCopy -MethodName Create -Arguments @{ Volume = "$($env:SystemDrive)\"; Context = 'ClientAccessible' } -OperationTimeoutSec $script:AUShadowCreateTimeoutSeconds -ErrorAction Stop
                if ($Created.ReturnValue -ne 0 -or -not $Created.ShadowID) { throw "Win32_ShadowCopy.Create returned $($Created.ReturnValue)." }
            }
            catch
            {
                $Snapshot.ShadowId = Remove-AUUnrecordedShadow -KnownIds $KnownIds -SinceUtc $RunStartUtc -WorkDir $WorkDir
                throw
            }
            $Snapshot.ShadowId = [string]$Created.ShadowID
            # A run killed from here on leaves this marker, so a later run deletes the shadow copy.
            try { Write-AUShadowMarker -Folder $WorkDir -ShadowId $Snapshot.ShadowId }
            catch { Write-CMTraceLog -Message "App Usage: couldn't write the shadow marker in $WorkDir`: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 2 }
            $Shadow = Get-CimInstance -ClassName Win32_ShadowCopy -Filter "ID='$($Snapshot.ShadowId)'" -OperationTimeoutSec $script:AUCimTimeoutSeconds -ErrorAction Stop
            if (-not $Shadow -or -not $Shadow.DeviceObject) { throw "shadow copy $($Snapshot.ShadowId) has no device path." }
            $Snapshot.ShadowRoot = ([string]$Shadow.DeviceObject).TrimEnd('\')
        }
        catch
        {
            $Snapshot.Status = 'ShadowCopyFailed'
            Write-CMTraceLog -Message "App Usage: couldn't take a shadow copy of $($env:SystemDrive): $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3
            return $Snapshot
        }

        $Mount = [IO.Path]::Combine($WorkDir, 'shadow')
        if (-not (Mount-AUShadow -ShadowRoot $Snapshot.ShadowRoot -LinkPath $Mount))
        {
            $Snapshot.Status = 'ShadowCopyFailed'
            return $Snapshot
        }
        try
        {
            $SruFolder = [IO.Path]::Combine($WorkDir, 'sru')
            [void][IO.Directory]::CreateDirectory($SruFolder)
            $SruSource = ConvertTo-AUShadowPath -Path ([IO.Path]::GetDirectoryName($script:AULiveSrumPath)) -ShadowRoot $Mount
            $SrumCopy = [IO.Path]::Combine($SruFolder, 'SRUDB.dat')

            # Free space first (I4): at least 2 GB, and three times what the copies need.
            $HiveFolders = New-Object 'System.Collections.Generic.List[string]'
            foreach ($UserProfile in $SignedOut)
            {
                $Source = ConvertTo-AUShadowPath -Path $UserProfile.ProfilePath -ShadowRoot $Mount
                if ($Source) { $HiveFolders.Add($Source) }
            }
            $Needed = [long](Get-AUCopyBytes -SruFolder $SruSource -HiveFolders $HiveFolders.ToArray())
            $Floor = [Math]::Max([long]$script:AUMinFreeBytes, 3 * $Needed)
            $Free = Get-AUFreeSpace -Path $WorkDir
            if ($null -eq $Free -or [long]$Free -lt $Floor)
            {
                $Snapshot.Status = 'LowDiskSpace'
                $FreeText = 'an unknown amount of'
                if ($null -ne $Free) { $FreeText = "$([Math]::Round([long]$Free / 1MB)) MB" }
                Write-CMTraceLog -Message "App Usage: skipped this run, because the work folder's drive has $FreeText free space, and the copies ($([Math]::Round($Needed / 1MB)) MB) need $([Math]::Round($Floor / 1MB)) MB free." -Component 'AppUsage' -Type 3
                return $Snapshot
            }

            # The logs and checkpoint let esentutl /r recover the copy; only SRUDB.dat is required.
            if ($SruSource) { [void](Copy-AUShadowFile -Source "$SruSource\*" -Destination $SruFolder) }
            if ([IO.File]::Exists($SrumCopy)) { $Snapshot.SrumDbPath = $SrumCopy }
            else
            {
                $Snapshot.Status = 'SrumReadFailed:CopyFailed'
                Write-CMTraceLog -Message 'App Usage: SRUDB.dat did not copy from the shadow copy.' -Component 'AppUsage' -Type 3
            }

            $OffDrive = 0
            foreach ($UserProfile in $SignedOut)
            {
                $Source = ConvertTo-AUShadowPath -Path $UserProfile.ProfilePath -ShadowRoot $Mount
                if (-not $Source)
                {
                    $OffDrive++
                    continue
                }
                $Folder = [IO.Path]::Combine($WorkDir, "hives\$($UserProfile.Sid)")
                [void][IO.Directory]::CreateDirectory($Folder)
                $Hive = [IO.Path]::Combine($Folder, 'NTUSER.DAT')
                if ((Copy-AUShadowFile -Source "$Source\NTUSER.DAT" -Destination $Hive) -and [IO.File]::Exists($Hive))
                {
                    foreach ($Log in @('NTUSER.DAT.LOG1', 'NTUSER.DAT.LOG2'))
                    {
                        if ([IO.File]::Exists("$Source\$Log")) { [void](Copy-AUShadowFile -Source "$Source\$Log" -Destination ([IO.Path]::Combine($Folder, $Log))) }
                    }
                    $Snapshot.HiveCopies[$UserProfile.Sid] = $Hive
                }
            }
            if ($OffDrive -gt 0) { Write-CMTraceLog -Message "App Usage: $OffDrive signed-out profiles aren't on $($env:SystemDrive), so their hives can't be copied." -Component 'AppUsage' -Type 2 }
        }
        finally
        {
            # The link only, never its target. Remove-AUSnapshot removes it too if this fails.
            try { if ([IO.Directory]::Exists($Mount)) { [IO.Directory]::Delete($Mount) } }
            catch { Write-CMTraceLog -Message "App Usage: couldn't remove the shadow link in $WorkDir`: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 2 }
        }
        $CopiedCount = @($Snapshot.HiveCopies.Values | Where-Object { $_ }).Count
        Write-CMTraceLog -Message "App Usage: shadow copy $($Snapshot.ShadowId) taken; SRUM copy $($Snapshot.Status); $CopiedCount of $($SignedOut.Count) signed-out hives copied." -Component 'AppUsage'
    }
    catch
    {
        if ($null -eq $Snapshot.ShadowRoot) { $Snapshot.Status = 'ShadowCopyFailed' }
        elseif ($null -eq $Snapshot.SrumDbPath) { $Snapshot.Status = 'SrumReadFailed:CopyFailed' }
        Write-CMTraceLog -Message "App Usage: the snapshot failed: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3
    }
    finally
    {
        # Every copy is made (or failed), and nothing later reads the shadow copy, so release it now.
        # When this fails, ShadowId and the marker stay for Remove-AUSnapshot and the next run.
        if ($Snapshot.ShadowId -and (Remove-AUShadowCopy -ShadowId $Snapshot.ShadowId))
        {
            $Snapshot.ShadowId = $null
            try { [IO.File]::Delete([IO.Path]::Combine($WorkDir, $script:AUShadowMarker)) }
            catch { Write-CMTraceLog -Message "App Usage: couldn't remove the shadow marker in $WorkDir`: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 2 }
        }
    }
    return $Snapshot
}#endfunction

function Remove-AUSnapshot
{
    <#
.SYNOPSIS
    Removes the snapshot's shadow copy and its whole run work folder. Never throws.
.DESCRIPTION
    Runs in Invoke-AppUsage's finally block, as the backstop: New-AUSnapshot normally releases the
    shadow copy itself. Each part is attempted whatever happens to the other, and every failure is
    logged. WorkDir is deleted only when it's a direct child of Root and not a link; otherwise it's
    logged and left alone. The folder delete (Remove-AUFolderTree) is retried briefly, because a hive
    or database handle can take a moment to close.
.PARAMETER Snapshot
    The object from New-AUSnapshot, or $null.
.PARAMETER Root
    The protected work root, C:\Windows\PowerStacksAppUsage by default. Tests pass a TestDrive path.
#>
    param (
        $Snapshot,
        [string]$Root = $script:AUWorkRoot
    )

    if ($null -eq $Snapshot) { return }
    try { $ShadowId = [string]$Snapshot.ShadowId; $WorkDir = [string]$Snapshot.WorkDir }
    catch { Write-CMTraceLog -Message "App Usage: the snapshot to remove isn't readable: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3; return }
    try
    {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
    catch { }

    if ($ShadowId) { [void](Remove-AUShadowCopy -ShadowId $ShadowId) }

    if ($WorkDir)
    {
        try
        {
            $Full = [IO.Path]::GetFullPath($WorkDir).TrimEnd('\')
            $Parent = [IO.Path]::GetDirectoryName($Full)
            $Inside = $Parent -and [string]::Equals($Parent.TrimEnd('\'), [IO.Path]::GetFullPath($Root).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
            $IsLink = [IO.Directory]::Exists($Full) -and ([IO.File]::GetAttributes($Full) -band [IO.FileAttributes]::ReparsePoint) -ne 0
        }
        catch
        {
            $Inside = $false
            $IsLink = $false
        }
        if (-not $Inside -or $IsLink)
        {
            Write-CMTraceLog -Message "App Usage: left $WorkDir alone, because it isn't a run folder directly inside $Root (or it's a link)." -Component 'AppUsage' -Type 3
            return
        }
        for ($Attempt = 1; $Attempt -le 3; $Attempt++)
        {
            try
            {
                Remove-AUFolderTree -Path $Full
                break
            }
            catch
            {
                if ($Attempt -eq 3) { Write-CMTraceLog -Message "App Usage: couldn't remove the work folder $WorkDir`: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3 }
                else { Start-Sleep -Milliseconds 500 }
            }
        }
    }
}#endfunction

function Initialize-AUEsent
{
    <#
.SYNOPSIS
    Loads the signed ManagedEsent assembly from the .NET Framework GAC. Returns true when it's loaded.
.DESCRIPTION
    A load, not a compile (D25). Returns false when the file is missing or won't load. Never throws.
.PARAMETER Path
    The assembly path, $script:AUEsentPath.
#>
    param (
        [string]$Path
    )

    if (-not [IO.File]::Exists($Path))
    {
        Write-CMTraceLog -Message "App Usage: ManagedEsent isn't at $Path." -Component 'AppUsage' -Type 3
        return $false
    }
    try
    {
        if (-not ('Microsoft.Isam.Esent.Interop.Api' -as [type])) { Add-Type -Path $Path }
        return $true
    }
    catch
    {
        Write-CMTraceLog -Message "App Usage: couldn't load ManagedEsent from $Path`: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3
        return $false
    }
}#endfunction

function Get-AUEseHeader
{
    <#
.SYNOPSIS
    Reads a database copy's header with esentutl /mh: State and Signature ($null when not found).
.PARAMETER DbPath
    The database copy.
#>
    param (
        [string]$DbPath
    )

    $Result = Invoke-AUProcess -FilePath $script:AUEsentutlPath -Arguments "/mh `"$DbPath`"" -WorkingDirectory ([IO.Path]::GetDirectoryName($DbPath)) -TimeoutSeconds $script:AUToolTimeoutSeconds
    $Header = [pscustomobject]@{ State = $null; Signature = $null }
    $Text = [string]$Result.Output
    $State = [regex]::Match($Text, '(?m)^\s*State:\s*(.+?)\s*$')
    if ($State.Success) { $Header.State = $State.Groups[1].Value }
    $Signature = [regex]::Match($Text, '(?m)^\s*DB Signature:\s*(.+?)\s*$')
    if ($Signature.Success) { $Header.Signature = $Signature.Groups[1].Value }
    return $Header
}#endfunction

function Add-AUIdMapEntry
{
    <#
.SYNOPSIS
    Adds one SruDbIdMapTable row to the id map: Apps, Sids, and KnownIds.
.DESCRIPTION
    IdType 3 is a binary user SID; 0 to 2 are UTF-16 app identifiers. An entry with an empty blob is
    still known: the kernel's System and IsrDpc rows use one for "no user". A SID blob that doesn't
    parse is removed from KnownIds and counted in BadSids, so its rows count as unresolved and the
    read as incomplete (Task 15 then archives nothing).
.PARAMETER IdMap
    A hashtable with Apps, Sids, and KnownIds (hashtables keyed by IdIndex) and BadSids (a count).
.PARAMETER IdType
    The row's IdType.
.PARAMETER IdIndex
    The row's IdIndex; a null one is skipped.
.PARAMETER Blob
    The row's IdBlob.
#>
    param (
        [hashtable]$IdMap,
        $IdType,
        $IdIndex,
        [byte[]]$Blob
    )

    if ($null -eq $IdIndex) { return }
    $Index = [int]$IdIndex
    $IdMap.KnownIds[$Index] = $true
    if ($null -eq $Blob -or $Blob.Length -eq 0) { return }
    if ($IdType -eq 3)
    {
        try { $IdMap.Sids[$Index] = (New-Object Security.Principal.SecurityIdentifier($Blob, 0)).Value }
        catch
        {
            $IdMap.KnownIds.Remove($Index)
            $IdMap.BadSids++
        }
        return
    }
    $Text = [Text.Encoding]::Unicode.GetString($Blob).TrimEnd([char]0)
    if ($Text) { $IdMap.Apps[$Index] = $Text }
}#endfunction

function Test-AUTimelineRowResolved
{
    <#
.SYNOPSIS
    Returns true when a timeline row has an AutoIncId and its AppId and UserId are known in the id map.
.DESCRIPTION
    A row that fails this can't be keyed reliably in the ledger, so the read counts as incomplete
    and Task 15 merges with -NoArchive.
.PARAMETER AppId
    The row's AppId.
.PARAMETER UserId
    The row's UserId.
.PARAMETER AutoIncId
    The row's AutoIncId.
.PARAMETER KnownIds
    The id map's KnownIds.
#>
    param (
        $AppId,
        $UserId,
        $AutoIncId,
        [hashtable]$KnownIds
    )

    if ($null -eq $AutoIncId -or $null -eq $AppId -or $null -eq $UserId) { return $false }
    return ($KnownIds.ContainsKey([int]$AppId) -and $KnownIds.ContainsKey([int]$UserId))
}#endfunction

function Read-AUSrumTables
{
    <#
.SYNOPSIS
    Reads the id map, every AppTimelineProvider row, and the AppResourceUseInfo kernel paths from a clean database copy.
.DESCRIPTION
    Opens the copy with ManagedEsent: recovery off, a read-only attach, and ESE's system, log, and
    temp paths in the copy's folder, so ESE writes nothing in the working directory (F28). Returns
    Timeline, Resource, Complete, and Failure ($null, or the reason the read stopped: OpenFailed,
    IdMapFailed, NoTimeline, or TimelineFailed).
    Timeline holds every row, unfiltered by time, because the ledger archives a missing key only by
    its AutoIncId (Task 9). A row whose AppId or UserId is null or isn't in the id map is still
    returned, with a $null ExeInfo or UserSid, and makes Complete false, as does a row with no
    AutoIncId or a user id whose SID doesn't parse (Test-AUTimelineRowResolved, Add-AUIdMapEntry).
    An id map entry with an empty value (the kernel's System and IsrDpc rows have no user) is known,
    so its $null UserSid doesn't. EndTimeUtc is the EndTime FILETIME, or the row's TimeStamp when EndTime is unset. Focus
    and input are seconds, with null read as 0.
    Resource holds one row per user and kernel path (identifiers containing a backslash), with the
    newest TimeStamp. A resource read failure is logged and leaves Resource empty; usage still counts.
.PARAMETER DbPath
    The clean database copy.
#>
    param (
        [string]$DbPath
    )

    $Result = [pscustomobject]@{ Timeline = @(); Resource = @(); Complete = $false; Failure = $null }
    $Api = [Microsoft.Isam.Esent.Interop.Api]
    $Nil = [Microsoft.Isam.Esent.Interop.JET_SESID]::Nil
    $Folder = [IO.Path]::GetDirectoryName($DbPath) + '\'
    $Instance = New-Object Microsoft.Isam.Esent.Interop.JET_INSTANCE
    $Session = New-Object Microsoft.Isam.Esent.Interop.JET_SESID
    $DbId = New-Object Microsoft.Isam.Esent.Interop.JET_DBID
    $Created = $false
    $Attached = $false
    $Opened = $false
    $InSession = $false
    $Stage = 'OpenFailed'
    try
    {
        [int]$PageSize = 0
        $Api::JetGetDatabaseFileInfo($DbPath, [ref]$PageSize, [Microsoft.Isam.Esent.Interop.JET_DbInfo]::PageSize)
        [void]$Api::JetSetSystemParameter($Instance, $Nil, [Microsoft.Isam.Esent.Interop.JET_param]::DatabasePageSize, $PageSize, $null)
        $Name = "PowerStacksAppUsage-$([guid]::NewGuid().ToString('N'))"
        [void]$Api::JetCreateInstance2([ref]$Instance, $Name, $Name, [Microsoft.Isam.Esent.Interop.CreateInstanceGrbit]::None)
        $Created = $true
        [void]$Api::JetSetSystemParameter($Instance, $Nil, [Microsoft.Isam.Esent.Interop.JET_param]::Recovery, 0, 'Off')
        [void]$Api::JetSetSystemParameter($Instance, $Nil, [Microsoft.Isam.Esent.Interop.JET_param]::SystemPath, 0, $Folder)
        [void]$Api::JetSetSystemParameter($Instance, $Nil, [Microsoft.Isam.Esent.Interop.JET_param]::LogFilePath, 0, $Folder)
        [void]$Api::JetSetSystemParameter($Instance, $Nil, [Microsoft.Isam.Esent.Interop.JET_param]::TempPath, 0, $Folder)
        [void]$Api::JetSetSystemParameter($Instance, $Nil, [Microsoft.Isam.Esent.Interop.JET_param]::NoInformationEvent, 1, $null)
        [void]$Api::JetInit2([ref]$Instance, [Microsoft.Isam.Esent.Interop.InitGrbit]::None)
        $Api::JetBeginSession($Instance, [ref]$Session, '', '')
        $InSession = $true
        [void]$Api::JetAttachDatabase($Session, $DbPath, [Microsoft.Isam.Esent.Interop.AttachDatabaseGrbit]::ReadOnly)
        $Attached = $true
        [void]$Api::JetOpenDatabase($Session, $DbPath, '', [ref]$DbId, [Microsoft.Isam.Esent.Interop.OpenDatabaseGrbit]::ReadOnly)
        $Opened = $true
        $Tables = @($Api::GetTableNames($Session, $DbId))

        $Stage = 'IdMapFailed'
        $IdMap = @{ Apps = @{}; Sids = @{}; KnownIds = @{}; BadSids = 0 }
        $Apps = $IdMap.Apps
        $Sids = $IdMap.Sids
        $KnownIds = $IdMap.KnownIds
        $Table = New-Object Microsoft.Isam.Esent.Interop.Table($Session, $DbId, 'SruDbIdMapTable', [Microsoft.Isam.Esent.Interop.OpenTableGrbit]::ReadOnly)
        try
        {
            $Columns = @{}
            foreach ($Column in $Api::GetTableColumns($Session, $Table.JetTableid)) { $Columns[$Column.Name] = $Column.Columnid }
            if ($Api::TryMoveFirst($Session, $Table.JetTableid))
            {
                do
                {
                    $IdType = $Api::RetrieveColumnAsByte($Session, $Table.JetTableid, $Columns['IdType'])
                    $IdIndex = $Api::RetrieveColumnAsInt32($Session, $Table.JetTableid, $Columns['IdIndex'])
                    $Blob = $Api::RetrieveColumn($Session, $Table.JetTableid, $Columns['IdBlob'])
                    Add-AUIdMapEntry -IdMap $IdMap -IdType $IdType -IdIndex $IdIndex -Blob $Blob
                } while ($Api::TryMoveNext($Session, $Table.JetTableid))
            }
        }
        finally { $Table.Dispose() }
        if ($IdMap.BadSids -gt 0) { Write-CMTraceLog -Message "App Usage: $($IdMap.BadSids) SRUM user ids hold a SID that doesn't parse, so their rows count as unresolved." -Component 'AppUsage' -Type 2 }

        $Stage = 'NoTimeline'
        if ($Tables -notcontains $script:AUTimelineTable) { throw "table $($script:AUTimelineTable) isn't in the database." }
        $Stage = 'TimelineFailed'
        $Timeline = New-Object Collections.Generic.List[object]
        $Unresolved = 0
        $Table = New-Object Microsoft.Isam.Esent.Interop.Table($Session, $DbId, $script:AUTimelineTable, [Microsoft.Isam.Esent.Interop.OpenTableGrbit]::ReadOnly)
        try
        {
            $Columns = @{}
            foreach ($Column in $Api::GetTableColumns($Session, $Table.JetTableid)) { $Columns[$Column.Name] = $Column.Columnid }
            foreach ($Required in @('AppId', 'UserId', 'AutoIncId', 'EndTime', 'TimeStamp', $script:AUFocusColumn, $script:AUInputColumn))
            {
                if (-not $Columns.ContainsKey($Required)) { throw "column $Required isn't in the timeline table." }
            }
            $Tid = $Table.JetTableid
            if ($Api::TryMoveFirst($Session, $Tid))
            {
                do
                {
                    $AppId = $Api::RetrieveColumnAsInt32($Session, $Tid, $Columns['AppId'])
                    $UserId = $Api::RetrieveColumnAsInt32($Session, $Tid, $Columns['UserId'])
                    $Focus = $Api::RetrieveColumnAsInt32($Session, $Tid, $Columns[$script:AUFocusColumn])
                    $InputSeconds = $Api::RetrieveColumnAsInt32($Session, $Tid, $Columns[$script:AUInputColumn])
                    $EndTime = $Api::RetrieveColumnAsInt64($Session, $Tid, $Columns['EndTime'])
                    $AutoIncId = $Api::RetrieveColumnAsInt32($Session, $Tid, $Columns['AutoIncId'])
                    $ExeInfo = $null
                    if ($null -ne $AppId) { $ExeInfo = $Apps[[int]$AppId] }
                    $UserSid = $null
                    if ($null -ne $UserId) { $UserSid = $Sids[[int]$UserId] }
                    if (-not (Test-AUTimelineRowResolved -AppId $AppId -UserId $UserId -AutoIncId $AutoIncId -KnownIds $KnownIds)) { $Unresolved++ }
                    $EndTimeUtc = $null
                    if ($null -ne $EndTime) { $EndTimeUtc = ConvertFrom-AUFileTime -FileTime $EndTime }
                    if ($null -eq $EndTimeUtc)
                    {
                        $Stamp = $Api::RetrieveColumnAsDouble($Session, $Tid, $Columns['TimeStamp'])
                        if ($null -ne $Stamp) { $EndTimeUtc = ConvertFrom-AUOleDate -OleDate $Stamp }
                    }
                    if ($null -eq $Focus) { $Focus = 0 }
                    if ($null -eq $InputSeconds) { $InputSeconds = 0 }
                    $Timeline.Add([pscustomobject]@{
                            UserSid      = $UserSid
                            ExeInfo      = $ExeInfo
                            AutoIncId    = $AutoIncId
                            EndTimeUtc   = $EndTimeUtc
                            FocusSeconds = [long]$Focus
                            InputSeconds = [long]$InputSeconds
                        })
                } while ($Api::TryMoveNext($Session, $Tid))
            }
        }
        finally { $Table.Dispose() }
        $Result.Timeline = $Timeline.ToArray()
        $Result.Complete = ($Unresolved -eq 0)
        if ($Unresolved -gt 0) { Write-CMTraceLog -Message "App Usage: $Unresolved SRUM timeline rows have no AutoIncId, or an AppId or UserId that isn't resolved in the id map, so this read counts as incomplete." -Component 'AppUsage' -Type 2 }

        $Stage = $null
        try
        {
            if ($Tables -notcontains $script:AUResourceTable) { throw "table $($script:AUResourceTable) isn't in the database." }
            $Newest = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
            $Table = New-Object Microsoft.Isam.Esent.Interop.Table($Session, $DbId, $script:AUResourceTable, [Microsoft.Isam.Esent.Interop.OpenTableGrbit]::ReadOnly)
            try
            {
                $Columns = @{}
                foreach ($Column in $Api::GetTableColumns($Session, $Table.JetTableid)) { $Columns[$Column.Name] = $Column.Columnid }
                $Tid = $Table.JetTableid
                if ($Api::TryMoveFirst($Session, $Tid))
                {
                    do
                    {
                        $AppId = $Api::RetrieveColumnAsInt32($Session, $Tid, $Columns['AppId'])
                        if ($null -eq $AppId) { continue }
                        $KernelPath = $Apps[[int]$AppId]
                        if (-not $KernelPath -or $KernelPath.IndexOf('\') -lt 0) { continue }
                        $UserId = $Api::RetrieveColumnAsInt32($Session, $Tid, $Columns['UserId'])
                        $UserSid = $null
                        if ($null -ne $UserId) { $UserSid = $Sids[[int]$UserId] }
                        $Stamp = $Api::RetrieveColumnAsDouble($Session, $Tid, $Columns['TimeStamp'])
                        $TimeStampUtc = $null
                        if ($null -ne $Stamp) { $TimeStampUtc = ConvertFrom-AUOleDate -OleDate $Stamp }
                        $Key = "$UserSid|$KernelPath"
                        $Known = $Newest[$Key]
                        if ($null -eq $Known)
                        {
                            $Newest[$Key] = [pscustomobject]@{
                                UserSid      = $UserSid
                                ExeName      = $KernelPath.Split('\')[-1].ToLowerInvariant()
                                KernelPath   = $KernelPath
                                TimeStampUtc = $TimeStampUtc
                            }
                        }
                        elseif ($null -ne $TimeStampUtc -and ($null -eq $Known.TimeStampUtc -or $TimeStampUtc -gt $Known.TimeStampUtc)) { $Known.TimeStampUtc = $TimeStampUtc }
                    } while ($Api::TryMoveNext($Session, $Tid))
                }
            }
            finally { $Table.Dispose() }
            $Result.Resource = @($Newest.Values)
        }
        catch { Write-CMTraceLog -Message "App Usage: couldn't read the SRUM resource table, so no run paths this run: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 2 }
    }
    catch
    {
        $Result.Failure = $Stage
        $Result.Complete = $false
        Write-CMTraceLog -Message "App Usage: the SRUM read stopped ($Stage): $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3
    }
    finally
    {
        # Each step on its own, so one failure doesn't skip the rest; an instance that won't stop
        # cleanly is stopped abruptly, so the copy's handle is released before cleanup.
        if ($Opened)
        {
            try { [void]$Api::JetCloseDatabase($Session, $DbId, [Microsoft.Isam.Esent.Interop.CloseDatabaseGrbit]::None) }
            catch { Write-CMTraceLog -Message "App Usage: couldn't close the SRUM database: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 2 }
        }
        if ($Attached)
        {
            try { [void]$Api::JetDetachDatabase($Session, $DbPath) }
            catch { Write-CMTraceLog -Message "App Usage: couldn't detach the SRUM database: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 2 }
        }
        if ($InSession)
        {
            try { [void]$Api::JetEndSession($Session, [Microsoft.Isam.Esent.Interop.EndSessionGrbit]::None) }
            catch { Write-CMTraceLog -Message "App Usage: couldn't end the ESE session: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 2 }
        }
        if ($Created)
        {
            try { [void]$Api::JetTerm($Instance) }
            catch
            {
                Write-CMTraceLog -Message "App Usage: couldn't stop the ESE instance, so stopping it abruptly: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 2
                try { [void]$Api::JetTerm2($Instance, [Microsoft.Isam.Esent.Interop.TermGrbit]::Abrupt) }
                catch { Write-CMTraceLog -Message "App Usage: couldn't stop the ESE instance abruptly: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3 }
            }
        }
    }
    return $Result
}#endfunction

function Read-AUSrum
{
    <#
.SYNOPSIS
    Reads SRUM usage and run paths from a SRUDB.dat copy: Epoch, Timeline, Resource, Status, Repaired, and Complete.
.DESCRIPTION
    Epoch is the database signature from esentutl /mh (the ledger's record-key epoch), read before
    any repair. Timeline is every AppTimelineProvider row, unfiltered by time: UserSid, ExeInfo,
    AutoIncId, EndTimeUtc (Utc or $null), FocusSeconds, and InputSeconds. Resource is UserSid,
    ExeName, KernelPath, and TimeStampUtc (see Read-AUSrumTables).
    A copy not in a clean shutdown state is recovered with esentutl /r (its copied logs), then, if
    still not clean, repaired with esentutl /p; both run on the copy only, with their log, system,
    and temp paths and their working directory in the copy's folder (F28). The live SRUDB.dat is
    refused.
    Status is OK or SrumReadFailed:<reason> (F42): EsentMissing, NoDatabase, LiveDatabase,
    HeaderFailed, RepairFailed, OpenFailed, IdMapFailed, NoTimeline, TimelineFailed, or ReadFailed.
    Any status but OK gives empty Timeline and Resource.
    Repaired is true when esentutl /p ran on the copy. Complete is true only when every timeline
    row was read with its AppId and UserId resolved. When Repaired is true or Complete is false,
    Task 15 merges with -NoArchive, because rows missing from such a read may still be in SRUM.
    Never throws.
.PARAMETER DbPath
    The SRUDB.dat copy in the work folder (New-AUSnapshot's SrumDbPath).
#>
    param (
        [string]$DbPath
    )

    $Read = [pscustomobject]@{ Epoch = $null; Timeline = @(); Resource = @(); Status = 'OK'; Repaired = $false; Complete = $false }
    $Reason = 'ReadFailed'
    try
    {
        if (-not (Initialize-AUEsent -Path $script:AUEsentPath)) { $Reason = 'EsentMissing'; throw 'ManagedEsent is not available.' }
        if ([string]::IsNullOrWhiteSpace($DbPath)) { $Reason = 'NoDatabase'; throw 'no database copy was given.' }
        $DbPath = [IO.Path]::GetFullPath($DbPath)
        if ([string]::Equals($DbPath, [IO.Path]::GetFullPath($script:AULiveSrumPath), [StringComparison]::OrdinalIgnoreCase)) { $Reason = 'LiveDatabase'; throw 'refusing to open the live SRUM database.' }
        if (-not [IO.File]::Exists($DbPath)) { $Reason = 'NoDatabase'; throw "no database copy at '$DbPath'." }
        $Folder = [IO.Path]::GetDirectoryName($DbPath)
        [IO.File]::SetAttributes($DbPath, [IO.FileAttributes]::Normal)

        $Header = Get-AUEseHeader -DbPath $DbPath
        if (-not $Header.Signature) { $Reason = 'HeaderFailed'; throw 'esentutl /mh gave no database signature.' }
        $Read.Epoch = $Header.Signature
        if ($Header.State -ne 'Clean Shutdown')
        {
            Write-CMTraceLog -Message "App Usage: the SRUM copy is '$($Header.State)'; recovering it with its copied logs." -Component 'AppUsage'
            $Recovery = Invoke-AUProcess -FilePath $script:AUEsentutlPath -Arguments "/r SRU /l `"$Folder`" /s `"$Folder`" /d `"$Folder`" /o" -WorkingDirectory $Folder -TimeoutSeconds $script:AURepairTimeoutSeconds
            $Header = Get-AUEseHeader -DbPath $DbPath
            if ($Header.State -ne 'Clean Shutdown')
            {
                Write-CMTraceLog -Message "App Usage: recovery left the SRUM copy '$($Header.State)' (exit $($Recovery.ExitCode)); repairing the copy." -Component 'AppUsage' -Type 2
                $Read.Repaired = $true
                $Repair = Invoke-AUProcess -FilePath $script:AUEsentutlPath -Arguments "/p `"$DbPath`" /o /t `"$Folder\repair.edb`"" -WorkingDirectory $Folder -TimeoutSeconds $script:AURepairTimeoutSeconds
                $Header = Get-AUEseHeader -DbPath $DbPath
                if ($Header.State -ne 'Clean Shutdown') { $Reason = 'RepairFailed'; throw "repair left the copy '$($Header.State)' (exit $($Repair.ExitCode), timed out $($Repair.TimedOut))." }
            }
            if ($Header.Signature -and $Header.Signature -ne $Read.Epoch) { Write-CMTraceLog -Message "App Usage: the SRUM signature changed during recovery; keeping the original, $($Read.Epoch)." -Component 'AppUsage' -Type 2 }
        }

        $Tables = Read-AUSrumTables -DbPath $DbPath
        if ($Tables.Failure) { $Reason = $Tables.Failure; throw "the table read stopped ($($Tables.Failure))." }
        $Read.Timeline = @($Tables.Timeline)
        $Read.Resource = @($Tables.Resource)
        $Read.Complete = [bool]$Tables.Complete
        Write-CMTraceLog -Message "App Usage: read $($Read.Timeline.Count) SRUM timeline rows and $($Read.Resource.Count) run paths (epoch $($Read.Epoch); repaired $($Read.Repaired); complete $($Read.Complete))." -Component 'AppUsage'
    }
    catch
    {
        $Read.Status = "SrumReadFailed:$Reason"
        $Read.Timeline = @()
        $Read.Resource = @()
        $Read.Complete = $false
        Write-CMTraceLog -Message "App Usage: SRUM read failed ($Reason): $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3
    }
    return $Read
}#endfunction

# Executable facts (Task 14; D24, D30, F13, F36 to F38). SRUM gives kernel paths and a build
# fingerprint. A kernel path is translated by suffix probing under each fixed drive (QueryDosDevice
# needs compiling, D25), and a file's facts are read only when its PE TimeDateStamp and CheckSum
# equal the build's (D24). Files are only ever opened to read their headers and version info, and every
# file is read in a timed runspace, so a lock on it can't stall the run.
$script:AUFileShare = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
$script:AUUnixEpoch = New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
# The PE header bytes read at e_lfanew: the signature (4), the file header (20), and the optional
# header through Subsystem (70). CheckSum and Subsystem sit at the same offsets in PE32 and PE32+.
$script:AUPeHeaderBytes = 94
$script:AUServicesKey = 'SYSTEM\CurrentControlSet\Services'
$script:AUServiceQueryTimeoutSeconds = 30

function Get-AUFixedDrives
{
    <#
.SYNOPSIS
    Returns the roots of the ready fixed drives, such as C: and E:, for kernel path probing.
.DESCRIPTION
    A separate function so tests can point probing at TestDrive folders. Returns nothing when the
    drives can't be listed; callers wrap the call in @(). Never throws.
#>
    $Roots = New-Object 'System.Collections.Generic.List[string]'
    try
    {
        foreach ($Drive in [IO.DriveInfo]::GetDrives())
        {
            if ($Drive.DriveType -ne [IO.DriveType]::Fixed) { continue }
            $Ready = $false
            try { $Ready = $Drive.IsReady } catch { $Ready = $false }
            if ($Ready) { $Roots.Add($Drive.Name.Substring(0, 2).ToUpperInvariant()) }
        }
    }
    catch { Write-CMTraceLog -Message "App Usage: couldn't list the fixed drives: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 2 }
    # Unrolled, so a pipeline gets one root at a time.
    return $Roots.ToArray()
}#endfunction

function ConvertTo-AUIoPath
{
    <#
.SYNOPSIS
    Returns the form of a drive-letter path to open: with the \\?\ prefix when it's 260 characters or longer.
.DESCRIPTION
    Only for opening the file. Facts and run paths never carry the prefix.
.PARAMETER Path
    The drive-letter path.
#>
    param (
        [string]$Path
    )

    if ($Path.Length -ge 260 -and $Path -match '^[A-Za-z]:\\') { return '\\?\' + $Path }
    return $Path
}#endfunction

function Get-AULongPath
{
    <#
.SYNOPSIS
    Expands any 8.3 short name in a drive-letter path to its long name.
.DESCRIPTION
    Only a segment holding ~ is looked up, by listing its parent folder with the segment as the
    pattern; it's replaced when exactly one entry answers to it. A segment that isn't found, or a
    failure, leaves the path as given. Never throws.
.PARAMETER Path
    The drive-letter path.
#>
    param (
        [string]$Path
    )

    if ([string]::IsNullOrEmpty($Path) -or $Path.IndexOf('~') -lt 0) { return $Path }
    try
    {
        $Parts = $Path.Split('\')
        $Current = $Parts[0]
        for ($i = 1; $i -lt $Parts.Count; $i++)
        {
            $Segment = $Parts[$i]
            if ($Segment.IndexOf('~') -ge 0 -and $Segment.IndexOfAny([char[]]@('*', '?')) -lt 0)
            {
                $Parent = New-Object IO.DirectoryInfo ((ConvertTo-AUIoPath $Current) + '\')
                $Found = @($Parent.GetFileSystemInfos($Segment))
                if ($Found.Count -eq 1) { $Segment = $Found[0].Name }
            }
            $Current = $Current + '\' + $Segment
        }
        return $Current
    }
    catch { return $Path }
}#endfunction

function Get-AUPeFingerprint
{
    <#
.SYNOPSIS
    Reads a file's PE build fingerprint: LinkTimeUtc (Utc kind), CheckSum ([uint32]), and Subsystem.
.DESCRIPTION
    Reads only the DOS header and the PE headers, with a FileStream opened for reading that lets
    others read, write, and delete the file; no compiling. LinkTimeUtc is the file header's
    TimeDateStamp and CheckSum the optional header's, the same types ConvertFrom-AUExeInfo gives, so
    the comparison is exact. Subsystem is GUI (2), Console (3), or Other for any other value (Native,
    EFI, and so on). Returns $null for a missing file, a folder, or a file that isn't a PE image.
    Never throws.
.PARAMETER Path
    The drive-letter path.
#>
    param (
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $Stream = $null
    try
    {
        $IoPath = ConvertTo-AUIoPath $Path
        if (-not [IO.File]::Exists($IoPath)) { return $null }
        $Stream = New-Object IO.FileStream ($IoPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, $script:AUFileShare)
        $ReadAll = {
            param ([byte[]]$Buffer)
            $Total = 0
            while ($Total -lt $Buffer.Length)
            {
                $Count = $Stream.Read($Buffer, $Total, $Buffer.Length - $Total)
                if ($Count -le 0) { break }
                $Total += $Count
            }
            return ($Total -eq $Buffer.Length)
        }

        $Dos = New-Object byte[] 64
        if (-not (& $ReadAll $Dos) -or $Dos[0] -ne 0x4D -or $Dos[1] -ne 0x5A) { return $null }
        $Offset = [BitConverter]::ToInt32($Dos, 0x3C)
        if ($Offset -lt 64 -or [long]$Offset + $script:AUPeHeaderBytes -gt $Stream.Length) { return $null }
        $Stream.Position = $Offset
        $Header = New-Object byte[] $script:AUPeHeaderBytes
        if (-not (& $ReadAll $Header)) { return $null }
        if ([BitConverter]::ToUInt32($Header, 0) -ne 0x00004550) { return $null }
        if ([BitConverter]::ToUInt16($Header, 20) -lt 70) { return $null }
        $Magic = [BitConverter]::ToUInt16($Header, 24)
        if ($Magic -ne 0x10B -and $Magic -ne 0x20B) { return $null }

        $Subsystem = 'Other'
        switch ([BitConverter]::ToUInt16($Header, 24 + 68))
        {
            2 { $Subsystem = 'GUI' }
            3 { $Subsystem = 'Console' }
        }
        return [pscustomobject]@{
            LinkTimeUtc = $script:AUUnixEpoch.AddSeconds([double][BitConverter]::ToUInt32($Header, 8))
            CheckSum    = [BitConverter]::ToUInt32($Header, 24 + 64)
            Subsystem   = $Subsystem
        }
    }
    catch { return $null }
    finally { if ($null -ne $Stream) { $Stream.Dispose() } }
}#endfunction

function Test-AUFingerprintMatch
{
    <#
.SYNOPSIS
    Tests whether a file's fingerprint is the build an ExeInfo names: equal LinkTimeUtc and CheckSum.
.DESCRIPTION
    False when either is missing, or the ExeInfo isn't a Win32 fingerprint with both values.
.PARAMETER Fingerprint
    The Get-AUPeFingerprint result.
.PARAMETER ExeInfo
    The ConvertFrom-AUExeInfo result.
#>
    param (
        [pscustomobject]$Fingerprint,
        [pscustomobject]$ExeInfo
    )

    if ($null -eq $Fingerprint -or $null -eq $ExeInfo -or $ExeInfo.Kind -ne 'Win32') { return $false }
    if ($null -eq $ExeInfo.LinkTimeUtc -or $null -eq $ExeInfo.CheckSum) { return $false }
    return ($Fingerprint.LinkTimeUtc.Ticks -eq ([datetime]$ExeInfo.LinkTimeUtc).Ticks -and [uint32]$Fingerprint.CheckSum -eq [uint32]$ExeInfo.CheckSum)
}#endfunction

function Get-AUVersionInfo
{
    <#
.SYNOPSIS
    Returns a file's version info ([Diagnostics.FileVersionInfo]). A separate function so tests can make it fail.
.PARAMETER Path
    The drive-letter path.
#>
    param (
        [string]$Path
    )

    return [Diagnostics.FileVersionInfo]::GetVersionInfo((ConvertTo-AUIoPath $Path))
}#endfunction

# Folders under the protected roots that standard users can write to on stock Windows: under
# %SystemRoot% itself, and under System32 and SysWOW64. A file there gets the owner check.
$script:AUUserWritableWindowsFolders = @('Temp', 'Tasks', 'Tracing', 'Registration\CRMLog', 'debug\WIA')
$script:AUUserWritableSystemFolders = @('Tasks', 'Tasks_Migrated', 'spool\drivers\color', 'spool\PRINTERS', 'spool\SERVERS', 'Microsoft\Crypto\RSA\MachineKeys', 'com\dmp', 'FxsTmp')
# The owners whose files outside the protected roots give verified facts, besides the entry's own
# user: SYSTEM, Administrators, and TrustedInstaller.
$script:AUTrustedFileOwnerSids = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')

function Get-AUProtectedRoots
{
    <#
.SYNOPSIS
    Returns the folders standard users can't write to (Allowed) and the user-writable folders inside them (Excluded).
.DESCRIPTION
    Allowed: %SystemRoot%, %ProgramFiles%, %ProgramFiles(x86)%, and %ProgramFiles%\WindowsApps.
    Excluded: the folders in AUUserWritableWindowsFolders under %SystemRoot%, such as
    C:\Windows\Temp, and those in AUUserWritableSystemFolders under System32 and SysWOW64, such as
    System32\Tasks. The locations come from the machine's registry (ProgramFilesDir,
    ProgramFilesDir (x86), and SystemRoot), never from user variables, with the known-folder API as
    the fallback. No trailing backslash. A location that can't be found is left out, so its files
    get the owner check. Never throws.
#>
    $Read = {
        param ([string]$KeyPath, [string]$Name)
        $Base = $null
        $Key = $null
        try
        {
            $Base = Open-AURegistryBase -Hive Machine
            $Key = $Base.OpenSubKey($KeyPath)
            if ($null -eq $Key) { return $null }
            return [string]$Key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        }
        catch { return $null }
        finally
        {
            if ($null -ne $Key) { $Key.Close() }
            if ($null -ne $Base) { $Base.Close() }
        }
    }
    $Clean = {
        param ([string]$Folder, [string]$Fallback)
        if ([string]::IsNullOrWhiteSpace($Folder) -or $Folder.IndexOf('%') -ge 0) { $Folder = $Fallback }
        if ([string]::IsNullOrWhiteSpace($Folder)) { return $null }
        $Folder = $Folder.Trim().TrimEnd('\')
        if ($Folder -notmatch '^[A-Za-z]:\\[^\\]') { return $null }
        return $Folder
    }

    $Allowed = New-Object 'System.Collections.Generic.List[string]'
    $Excluded = New-Object 'System.Collections.Generic.List[string]'
    try
    {
        $ProgramFiles = & $Clean (& $Read 'SOFTWARE\Microsoft\Windows\CurrentVersion' 'ProgramFilesDir') ([Environment]::GetFolderPath('ProgramFiles'))
        $ProgramFilesX86 = & $Clean (& $Read 'SOFTWARE\Microsoft\Windows\CurrentVersion' 'ProgramFilesDir (x86)') ([Environment]::GetFolderPath('ProgramFilesX86'))
        $SystemRoot = & $Clean (& $Read 'SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'SystemRoot') ([Environment]::GetFolderPath('Windows'))
        if ($ProgramFiles) { $Allowed.Add($ProgramFiles); $Allowed.Add($ProgramFiles + '\WindowsApps') }
        if ($ProgramFilesX86) { $Allowed.Add($ProgramFilesX86) }
        if ($SystemRoot)
        {
            $Allowed.Add($SystemRoot)
            foreach ($Folder in $script:AUUserWritableWindowsFolders) { $Excluded.Add($SystemRoot + '\' + $Folder) }
            foreach ($System in @('System32', 'SysWOW64'))
            {
                foreach ($Folder in $script:AUUserWritableSystemFolders) { $Excluded.Add($SystemRoot + '\' + $System + '\' + $Folder) }
            }
        }
    }
    catch { Write-CMTraceLog -Message "App Usage: couldn't find the system folders; every file gets the owner check: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 2 }
    return [pscustomobject]@{ Allowed = $Allowed.ToArray(); Excluded = $Excluded.ToArray() }
}#endfunction

function Test-AUProtectedPath
{
    <#
.SYNOPSIS
    Tests whether a file is inside a protected root that standard users can't write to (Get-AUProtectedRoots).
.DESCRIPTION
    The path is normalized with GetFullPath (forward slashes, a \\?\ prefix, . and .. segments, and
    existing 8.3 short names resolved) and compared ignoring case with each folder plus a trailing
    backslash: Excluded first, then Allowed. Anything else (a user profile, C:\Windows\Temp,
    System32\Tasks, ProgramData, another drive's \Program Files) is a place another user could
    have created the file, so Get-AUExeFacts checks its owner. A path that doesn't normalize is false.
.PARAMETER Path
    The drive-letter path.
.PARAMETER Roots
    The Get-AUProtectedRoots result (a read budget's ProtectedRoots), or $null to read it now.
#>
    param (
        [string]$Path,
        [pscustomobject]$Roots
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $Full = $Path.Trim().Replace('/', '\')
    if ($Full.StartsWith('\\?\')) { $Full = $Full.Substring(4) }
    if ($Full -notmatch '^[A-Za-z]:\\') { return $false }
    try { $Full = [IO.Path]::GetFullPath($Full) }
    catch { return $false }
    if ($null -eq $Roots) { $Roots = Get-AUProtectedRoots }
    foreach ($Folder in @($Roots.Excluded)) { if ($Folder -and $Full.StartsWith($Folder + '\', [StringComparison]::OrdinalIgnoreCase)) { return $false } }
    foreach ($Folder in @($Roots.Allowed)) { if ($Folder -and $Full.StartsWith($Folder + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    return $false
}#endfunction

function Test-AUTrustedFileOwner
{
    <#
.SYNOPSIS
    Tests whether a file's owner is one whose file may give an entry verified facts: SYSTEM, Administrators, TrustedInstaller, or the entry's own user.
.PARAMETER Owner
    The owner's SID (Get-AUFileOwner), or $null when it couldn't be read.
.PARAMETER UserSid
    The entry's user SID.
#>
    param (
        [string]$Owner,
        [string]$UserSid
    )

    if ([string]::IsNullOrWhiteSpace($Owner)) { return $false }
    $Owner = $Owner.Trim()
    if ($script:AUTrustedFileOwnerSids -contains $Owner) { return $true }
    return (-not [string]::IsNullOrWhiteSpace($UserSid) -and [string]::Equals($Owner, $UserSid.Trim(), [StringComparison]::OrdinalIgnoreCase))
}#endfunction

function Get-AUFileOwner
{
    <#
.SYNOPSIS
    Returns a file's owner SID, or $null when the file, or any folder above it, is a link (a reparse point), or the owner can't be read.
.DESCRIPTION
    In-box .NET can't read a file's owner from a handle that doesn't follow links, and
    GetAccessControl opens the path and follows one. So the attributes of the file and of every
    folder above it are read right before and right after the owner, and the result is $null when
    any of them is a link, the file is a folder, or the two reads differ. Fails closed: any error
    gives $null. Reading the owner asks only for READ_CONTROL. Read-AUFile runs this in its timed
    runspace. Never throws.
.PARAMETER Path
    The drive-letter path.
#>
    param (
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -notmatch '^[A-Za-z]:\\[^\\]') { return $null }
    try
    {
        # The file, then each folder above it, without the drive root.
        $Chain = New-Object 'System.Collections.Generic.List[string]'
        $Current = $Path.TrimEnd('\')
        while ($Current.Length -gt 2)
        {
            $Chain.Add((ConvertTo-AUIoPath $Current))
            $Current = $Current.Substring(0, $Current.LastIndexOf('\'))
        }
        $Before = New-Object 'System.Collections.Generic.List[int]'
        foreach ($Item in $Chain) { $Before.Add([int][IO.File]::GetAttributes($Item)) }
        foreach ($Value in $Before) { if (($Value -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) { return $null } }
        if (($Before[0] -band [int][IO.FileAttributes]::Directory) -ne 0) { return $null }
        $Owner = [IO.File]::GetAccessControl($Chain[0], [Security.AccessControl.AccessControlSections]::Owner).GetOwner([Security.Principal.SecurityIdentifier])
        for ($i = 0; $i -lt $Chain.Count; $i++)
        {
            if ([int][IO.File]::GetAttributes($Chain[$i]) -ne $Before[$i]) { return $null }
        }
        if ($null -eq $Owner) { return $null }
        return [string]$Owner.Value
    }
    catch { return $null }
}#endfunction

function Read-AUFileFacts
{
    <#
.SYNOPSIS
    Reads a file's PE fingerprint and, optionally, its version info and fingerprint again, and its owner: Status, Before, Info, After, Error, Owner.
.DESCRIPTION
    The version info is read only when the file is a PE image, and the fingerprint is read again
    after it, so a file replaced mid-read shows a different After. Error holds a version-read
    failure's message. With WithOwner, the owner (Get-AUFileOwner) is read before and after the
    rest, and Owner is set only when both reads give the same SID, so a file swapped during the
    read has no owner. Status is OK. Read-AUFile runs this in its timed runspace. Never throws.
.PARAMETER Path
    The drive-letter path.
.PARAMETER WithVersion
    Also read the version info and the fingerprint after it.
.PARAMETER WithOwner
    Also read the owner.
#>
    param (
        [string]$Path,
        [switch]$WithVersion,
        [switch]$WithOwner
    )

    $Result = [pscustomobject]@{ Status = 'OK'; Before = $null; Info = $null; After = $null; Error = $null; Owner = $null }
    $OwnerBefore = $null
    if ($WithOwner) { $OwnerBefore = Get-AUFileOwner $Path }
    $Result.Before = Get-AUPeFingerprint $Path
    if ($WithVersion -and $null -ne $Result.Before)
    {
        try { $Result.Info = Get-AUVersionInfo $Path }
        catch { $Result.Error = $_.Exception.Message }
        $Result.After = Get-AUPeFingerprint $Path
    }
    if ($WithOwner -and $OwnerBefore)
    {
        $OwnerAfter = Get-AUFileOwner $Path
        if ([string]::Equals($OwnerBefore, $OwnerAfter, [StringComparison]::OrdinalIgnoreCase)) { $Result.Owner = $OwnerBefore }
    }
    return $Result
}#endfunction

function Get-AUFileReadScript
{
    <#
.SYNOPSIS
    Returns the script Read-AUFile runs in its runspace: the file-read functions and constants, then Read-AUFileFacts on $args.
.DESCRIPTION
    Built from this region's own function definitions, so the runspace runs the same code the tests
    call directly. A separate function so tests can substitute a slow read.
#>
    $Builder = New-Object Text.StringBuilder
    [void]$Builder.AppendLine("`$script:AUFileShare = [IO.FileShare]$([int]$script:AUFileShare)")
    [void]$Builder.AppendLine("`$script:AUPeHeaderBytes = $script:AUPeHeaderBytes")
    [void]$Builder.AppendLine("`$script:AUUnixEpoch = New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)")
    foreach ($Name in @('ConvertTo-AUIoPath', 'Get-AUPeFingerprint', 'Get-AUVersionInfo', 'Get-AUFileOwner', 'Read-AUFileFacts'))
    {
        $Body = (Get-Command -Name $Name -CommandType Function).ScriptBlock.ToString()
        [void]$Builder.AppendLine("function $Name {").AppendLine($Body).AppendLine('}')
    }
    [void]$Builder.AppendLine('Read-AUFileFacts -Path $args[0] -WithVersion:$args[1] -WithOwner:$args[2]')
    return $Builder.ToString()
}#endfunction

function New-AUReadBudget
{
    <#
.SYNOPSIS
    Returns a run's budget for timed file reads: a per-file timeout and a total for the run.
.DESCRIPTION
    Task 15 creates one read budget per run, passes it to Find-AUExePath and Get-AUExeFacts, and
    closes it with Close-AUReadBudget in a finally block. RemainingMs falls by the time every read
    takes; once it's spent, the remaining files are skipped (unverified, no facts). Reads,
    TimedOut, and Skipped count what happened, and UntrustedOwner the files outside the protected
    roots that gave no facts because of their owner (Get-AUExeFacts). ProtectedRoots is read once
    (Get-AUProtectedRoots). The runspace is created on the first read.
.PARAMETER TotalSeconds
    The run's total for timed reads.
.PARAMETER FileTimeoutSeconds
    The longest wait for one file.
#>
    param (
        [double]$TotalSeconds = 120,
        [double]$FileTimeoutSeconds = 5
    )

    return [pscustomobject]@{
        TimeoutMs      = [int][Math]::Max(1, [Math]::Round($FileTimeoutSeconds * 1000))
        RemainingMs    = [double]([Math]::Max(0, $TotalSeconds * 1000))
        Runspace       = $null
        ScriptText     = $null
        Reads          = 0
        TimedOut       = 0
        Skipped        = 0
        UntrustedOwner = 0
        ProtectedRoots = (Get-AUProtectedRoots)
    }
}#endfunction

function Close-AUReadBudget
{
    <#
.SYNOPSIS
    Closes a read budget's runspace, if it has one. Never waits on a read: a timed-out runspace was already let go. Never throws.
.PARAMETER ReadBudget
    The New-AUReadBudget result.
#>
    param (
        [pscustomobject]$ReadBudget
    )

    if ($null -eq $ReadBudget -or $null -eq $ReadBudget.Runspace) { return }
    $Runspace = $ReadBudget.Runspace
    $ReadBudget.Runspace = $null
    try { $Runspace.Dispose() } catch { Write-CMTraceLog -Message "App Usage: couldn't close the file-read runspace: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 2 }
}#endfunction

function Read-AUFile
{
    <#
.SYNOPSIS
    Reads a file with Read-AUFileFacts in a timed runspace.
.DESCRIPTION
    Every file, a system file included, is read in a background runspace that is waited on for at
    most the budget's per-file timeout, or what's left of its total: a standard user can hold an
    opportunistic lock on any file they can open for reading, which would make SYSTEM's open wait
    indefinitely. On a timeout the read is logged and let go: the pipeline is told to stop and
    the runspace to close, neither waited on, and the next read gets a new runspace. A timed-out
    read gives Status TimedOut, and a spent budget Status Skipped without reading. Either way the
    caller treats the file as unverified with no facts. Status Failed when the runspace fails.
    Never throws.
.PARAMETER Path
    The drive-letter path.
.PARAMETER WithVersion
    Also read the version info and the fingerprint after it.
.PARAMETER WithOwner
    Also read the file's owner (Read-AUFileFacts).
.PARAMETER ReadBudget
    The run's New-AUReadBudget result (Task 15 creates one per run and closes it in a finally
    block). With none, a budget for this one read is made and closed.
#>
    param (
        [string]$Path,
        [switch]$WithVersion,
        [switch]$WithOwner,
        [pscustomobject]$ReadBudget
    )

    $Own = $null
    if ($null -eq $ReadBudget) { $Own = New-AUReadBudget; $ReadBudget = $Own }
    $Result = [pscustomobject]@{ Status = 'Failed'; Before = $null; Info = $null; After = $null; Error = $null; Owner = $null }
    $Shell = $null
    $Started = $false
    $Finished = $false
    $Timer = [Diagnostics.Stopwatch]::StartNew()
    try
    {
        if ($ReadBudget.RemainingMs -le 0)
        {
            if ($ReadBudget.Skipped -eq 0) { Write-CMTraceLog -Message 'App Usage: the file-read time budget is spent; the remaining files are now treated as unverified.' -Component 'AppUsage' -Type 2 }
            $ReadBudget.Skipped++
            $Result.Status = 'Skipped'
            return $Result
        }
        $Wait = [int][Math]::Max(1, [Math]::Min([double]$ReadBudget.TimeoutMs, $ReadBudget.RemainingMs))
        $ReadBudget.Reads++
        if ($null -eq $ReadBudget.ScriptText) { $ReadBudget.ScriptText = Get-AUFileReadScript }
        if ($null -eq $ReadBudget.Runspace)
        {
            $Runspace = [runspacefactory]::CreateRunspace()
            $Runspace.Open()
            $ReadBudget.Runspace = $Runspace
        }
        $Shell = [PowerShell]::Create()
        $Shell.Runspace = $ReadBudget.Runspace
        [void]$Shell.AddScript($ReadBudget.ScriptText).AddArgument($Path).AddArgument([bool]$WithVersion).AddArgument([bool]$WithOwner)
        $Async = $Shell.BeginInvoke()
        $Started = $true
        if ($Async.AsyncWaitHandle.WaitOne($Wait))
        {
            $Finished = $true
            $Output = @($Shell.EndInvoke($Async))
            if ($Output.Count -gt 0 -and $null -ne $Output[-1] -and $Output[-1].Status -eq 'OK') { $Result = $Output[-1] }
            return $Result
        }

        # Let the stuck read go without waiting on it: its thread stays blocked until the lock is
        # released or the process exits. Each timeout costs the budget at least min(5 s, what's left),
        # so a run abandons at most about 24 runspaces (120 s / 5 s), plus one for a last short wait.
        $ReadBudget.TimedOut++
        Write-CMTraceLog -Message "App Usage: reading $(Get-AUFileLeaf $Path) took longer than $Wait ms; it's treated as unverified." -Component 'AppUsage' -Type 2
        try { [void]$Shell.BeginStop($null, $null) } catch { }
        $Abandoned = $ReadBudget.Runspace
        $ReadBudget.Runspace = $null
        try { $Abandoned.CloseAsync() } catch { }
        $Result.Status = 'TimedOut'
        return $Result
    }
    catch
    {
        Write-CMTraceLog -Message "App Usage: couldn't read $(Get-AUFileLeaf $Path): $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 2
        # A runspace that failed isn't used again; the next read gets a new one. CloseAsync doesn't wait.
        $Broken = $ReadBudget.Runspace
        $ReadBudget.Runspace = $null
        if ($null -ne $Broken) { try { $Broken.CloseAsync() } catch { } }
        return $Result
    }
    finally
    {
        if ($Result.Status -ne 'Skipped') { $ReadBudget.RemainingMs -= $Timer.Elapsed.TotalMilliseconds }
        # Disposing a shell that never started, or whose read finished, doesn't wait; a timed-out one would.
        if ($null -ne $Shell -and ($Finished -or -not $Started)) { try { $Shell.Dispose() } catch { } }
        if ($null -ne $Own) { Close-AUReadBudget $Own }
    }
}#endfunction

function Get-AUKernelProbe
{
    <#
.SYNOPSIS
    Probes one kernel path under the fixed drives: the existing candidate files, each with whether its fingerprint verifies.
.DESCRIPTION
    Returns Volume (lowercase), CachedRoot, and Candidates (Root, Path, Verified) for every drive
    where the file exists and is named the ExeInfo exe name, with 8.3 names expanded. A cached
    volume's drive (CachedRoot, else $null) is tried first; when no file there verifies, every
    fixed drive is probed, so a wrong cache entry never hides a file. Returns $null for a refused
    path: not \Device\HarddiskVolumeN\, an empty, . or .. segment, a stream name, wildcards, or
    invalid characters; or a Package, Other, or fingerprint-less entry. The fingerprints are read
    with Read-AUFile.
.PARAMETER KernelPath
    The Resource row's KernelPath.
.PARAMETER ExeInfo
    The ConvertFrom-AUExeInfo result for the entry.
.PARAMETER VolumeCache
    The run's volume-to-drive map, or $null.
.PARAMETER ReadBudget
    The run's New-AUReadBudget result, or $null.
#>
    param (
        [string]$KernelPath,
        [pscustomobject]$ExeInfo,
        [hashtable]$VolumeCache,
        [pscustomobject]$ReadBudget
    )

    if ($null -eq $ExeInfo -or $ExeInfo.Kind -ne 'Win32' -or $null -eq $ExeInfo.LinkTimeUtc -or $null -eq $ExeInfo.CheckSum) { return $null }
    if ([string]::IsNullOrWhiteSpace($KernelPath)) { return $null }
    $Match = [regex]::Match($KernelPath.Trim(), '^\\Device\\(?<Volume>HarddiskVolume\d+)\\(?<Rest>.+)$', 'IgnoreCase')
    if (-not $Match.Success) { return $null }
    $Volume = $Match.Groups['Volume'].Value.ToLowerInvariant()
    $Rest = $Match.Groups['Rest'].Value
    if ($Rest.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0 -or $Rest.IndexOfAny([char[]]@(':', '*', '?')) -ge 0) { return $null }
    foreach ($Segment in $Rest.Split('\'))
    {
        if ($Segment.Trim() -eq '' -or $Segment -eq '.' -or $Segment -eq '..') { return $null }
    }

    $Cached = $null
    if ($null -ne $VolumeCache) { $Cached = [string]$VolumeCache[$Volume] }
    if (-not $Cached) { $Cached = $null }

    $Candidates = New-Object 'System.Collections.Generic.List[object]'
    $Probe = {
        param ([string]$Root)
        $Candidate = $Root.TrimEnd('\') + '\' + $Rest
        # An attribute query, not an open, so it can't be held up by a lock on the file.
        if (-not [IO.File]::Exists((ConvertTo-AUIoPath $Candidate))) { return }
        $Path = Get-AULongPath $Candidate
        $Leaf = $Path.Substring($Path.LastIndexOf('\') + 1)
        if ($ExeInfo.ExeName -and -not [string]::Equals($Leaf, [string]$ExeInfo.ExeName, [StringComparison]::OrdinalIgnoreCase)) { return }
        $Read = Read-AUFile $Path -ReadBudget $ReadBudget
        $Verified = ($Read.Status -eq 'OK' -and (Test-AUFingerprintMatch $Read.Before $ExeInfo))
        $Candidates.Add([pscustomobject]@{ Root = [string]$Root; Path = $Path; Verified = $Verified })
    }
    if ($Cached) { & $Probe $Cached }
    if (-not $Cached -or -not @($Candidates | Where-Object { $_.Verified }).Count)
    {
        foreach ($Root in @(Get-AUFixedDrives))
        {
            if (-not $Root -or ($Cached -and [string]::Equals([string]$Root, $Cached, [StringComparison]::OrdinalIgnoreCase))) { continue }
            & $Probe ([string]$Root)
        }
    }
    return [pscustomobject]@{ Volume = $Volume; CachedRoot = $Cached; Candidates = $Candidates.ToArray() }
}#endfunction

function Select-AUVerifiedPath
{
    <#
.SYNOPSIS
    Returns a probe's one verified path, caching its volume's drive, or $null when none or two or more verify.
.DESCRIPTION
    Only a single, unambiguous verified hit sets the cache, and it replaces a cached drive that
    turned out wrong.
.PARAMETER Probe
    The Get-AUKernelProbe result.
.PARAMETER KernelPath
    The probed kernel path, for the log.
.PARAMETER VolumeCache
    The run's volume-to-drive map, or $null.
#>
    param (
        [pscustomobject]$Probe,
        [string]$KernelPath,
        [hashtable]$VolumeCache
    )

    if ($null -eq $Probe) { return $null }
    $Verified = @($Probe.Candidates | Where-Object { $_.Verified })
    if ($Verified.Count -eq 0) { return $null }
    if ($Verified.Count -gt 1)
    {
        Write-CMTraceLog -Message "App Usage: $(Get-AUFileLeaf $KernelPath) verifies under $($Verified.Count) drives; the path stays untranslated." -Component 'AppUsage'
        return $null
    }
    if ($null -ne $VolumeCache -and -not [string]::Equals([string]$Probe.CachedRoot, $Verified[0].Root, [StringComparison]::OrdinalIgnoreCase)) { $VolumeCache[$Probe.Volume] = $Verified[0].Root }
    return $Verified[0].Path
}#endfunction

function Resolve-AUKernelPath
{
    <#
.SYNOPSIS
    Translates a SRUM kernel path (\Device\HarddiskVolumeN\...) to the drive-letter path of the same build, or $null.
.DESCRIPTION
    Strips the volume prefix and tries the rest under each fixed drive (Get-AUKernelProbe). A
    candidate counts only when its PE TimeDateStamp and CheckSum equal the ExeInfo fingerprint and
    its file name is the ExeInfo exe name (D24). Exactly one verified candidate is returned, with
    any 8.3 short names expanded; none, or two or more (ambiguous), gives $null. A verified path
    caches the volume's drive: a cached volume tries that drive first, and every drive when nothing
    there verifies. A Package or Other entry, or a Win32 entry without a fingerprint, is never
    probed. Never throws.
.PARAMETER KernelPath
    The Resource row's KernelPath.
.PARAMETER ExeInfo
    The ConvertFrom-AUExeInfo result for the entry.
.PARAMETER VolumeCache
    The run's volume-to-drive map (lowercase volume name to drive root), or $null.
.PARAMETER ReadBudget
    The run's New-AUReadBudget result, or $null.
#>
    param (
        [string]$KernelPath,
        [pscustomobject]$ExeInfo,
        [hashtable]$VolumeCache,
        [pscustomobject]$ReadBudget
    )

    try { return (Select-AUVerifiedPath (Get-AUKernelProbe $KernelPath $ExeInfo $VolumeCache $ReadBudget) $KernelPath $VolumeCache) }
    catch
    {
        Write-CMTraceLog -Message "App Usage: couldn't translate the path of $(Get-AUFileLeaf $KernelPath): $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 2
        return $null
    }
}#endfunction

function Find-AUExePath
{
    <#
.SYNOPSIS
    Returns an entry's run path from its candidate kernel paths, as Path and Verified, or $null (F37, D24, D30).
.DESCRIPTION
    The candidates are the Resource rows with the entry's user and exe name; each distinct kernel
    path (ignoring case) is probed with Get-AUKernelProbe.
    - Exactly one distinct path verifies: that path, Verified $true.
    - Two or more distinct paths verify (System32 and SysWOW64 copies of one build, say): $null.
    - None verifies, but exactly one distinct path exists: that path, Verified $false. The app was
      updated in place, so Get-AUExeFacts gives unverified facts with the current file's evidence.
    - None verifies and none, or two or more distinct paths, exist: $null.
    Never throws.
.PARAMETER KernelPaths
    The candidate kernel paths.
.PARAMETER ExeInfo
    The ConvertFrom-AUExeInfo result for the entry.
.PARAMETER VolumeCache
    The run's volume-to-drive map, shared across entries.
.PARAMETER ReadBudget
    The run's New-AUReadBudget result (Task 15 creates one per run and closes it in a finally
    block), or $null for a budget for this call only.
#>
    param (
        [string[]]$KernelPaths,
        [pscustomobject]$ExeInfo,
        [hashtable]$VolumeCache,
        [pscustomobject]$ReadBudget
    )

    if ($null -eq $ExeInfo -or $ExeInfo.Kind -ne 'Win32') { return $null }
    $Own = $null
    if ($null -eq $ReadBudget) { $Own = New-AUReadBudget; $ReadBudget = $Own }
    try
    {
        $Seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $Verified = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $Existing = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($Kernel in @($KernelPaths))
        {
            if ([string]::IsNullOrWhiteSpace($Kernel) -or -not $Seen.Add($Kernel.Trim())) { continue }
            try
            {
                $Probe = Get-AUKernelProbe $Kernel $ExeInfo $VolumeCache $ReadBudget
                if ($null -eq $Probe) { continue }
                # Every verified candidate counts, so a kernel path that verifies on two drives keeps
                # the entry ambiguous (D24); Select-AUVerifiedPath only caches the volume.
                foreach ($Candidate in $Probe.Candidates)
                {
                    [void]$Existing.Add($Candidate.Path)
                    if ($Candidate.Verified) { [void]$Verified.Add($Candidate.Path) }
                }
                [void](Select-AUVerifiedPath $Probe $Kernel $VolumeCache)
            }
            catch { Write-CMTraceLog -Message "App Usage: couldn't translate the path of $(Get-AUFileLeaf $Kernel): $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 2 }
        }
        if ($Verified.Count -eq 1) { return [pscustomobject]@{ Path = @($Verified)[0]; Verified = $true } }
        if ($Verified.Count -gt 1)
        {
            Write-CMTraceLog -Message "App Usage: $($Verified.Count) paths verify for $($ExeInfo.ExeName); its path stays unknown (D24)." -Component 'AppUsage'
            return $null
        }
        if ($Existing.Count -eq 1) { return [pscustomobject]@{ Path = @($Existing)[0]; Verified = $false } }
        if ($Existing.Count -gt 1) { Write-CMTraceLog -Message "App Usage: $($Existing.Count) paths exist for $($ExeInfo.ExeName) and none is this build; its path stays unknown." -Component 'AppUsage' }
        return $null
    }
    finally { if ($null -ne $Own) { Close-AUReadBudget $Own } }
}#endfunction

function ConvertTo-AUPackageFamily
{
    <#
.SYNOPSIS
    Returns the package family name (Name_PublisherId) of a Package-kind ExeInfo, or $null.
.DESCRIPTION
    A package full name (Name_Version_Architecture_ResourceId_PublisherId) keeps its first and last
    parts; a family name is kept as it is. An !AppId is dropped. Anything ConvertFrom-AUExeInfo
    doesn't call Package gives $null.
.PARAMETER ExeInfo
    The SRUM ExeInfo string.
#>
    param (
        [string]$ExeInfo
    )

    if ((ConvertFrom-AUExeInfo $ExeInfo).Kind -ne 'Package') { return $null }
    $Value = $ExeInfo.Trim()
    $Bang = $Value.IndexOf('!')
    if ($Bang -ge 0) { $Value = $Value.Substring(0, $Bang) }
    $Parts = $Value.Split('_')
    if ($Parts.Count -eq 5) { return $Parts[0] + '_' + $Parts[4] }
    if ($Parts.Count -eq 2) { return $Value }
    return $null
}#endfunction

function Get-AUExeFacts
{
    <#
.SYNOPSIS
    Returns an executable's facts, in exactly Task 5's shape (F13), reading build facts only from a verified file (D24).
.DESCRIPTION
    Fields: ExeName, RunPath, LocationClass, FileDescription, FileProductName, FileCompanyName,
    FileVersion, ProductVersion, FactsVerified, Subsystem, MsiProductCode, PackageFamily,
    IsServiceBinary, UserSid, and PathEvidence.
    Path-level facts come from the path: RunPath, LocationClass ($null with no path), and
    IsServiceBinary (the service map). The file is read once with Read-AUFile (a timed read).
    Build facts (version info, Subsystem, and the Windows Installer owner) are filled in only when
    the file's PE TimeDateStamp and CheckSum equal the ExeInfo's both before and after the version
    info is read; FactsVerified says so. When the build is unverified and the file at the path is a
    PE image, PathEvidence holds that current file's CompanyName and ProductName: identity evidence
    only, never the build's facts (D30). A read that timed out or was skipped for a spent budget
    gives no facts and no PathEvidence.
    A file outside the protected roots (Test-AUProtectedPath) could have been created by another
    user, for example under a second drive's \Program Files, so its owner is read too: unless it's
    SYSTEM, Administrators, TrustedInstaller, or the entry's own user (Test-AUTrustedFileOwner), or
    when it can't be read or the path holds a link, the file gives no facts and no PathEvidence.
    Such a file is counted in the budget's UntrustedOwner, never logged by path.
    A Package entry reads no file: it gets its PackageFamily from the ExeInfo text, and no path.
    Never throws.
.PARAMETER Path
    The Find-AUExePath path (verified, or the one observed path of an updated build), or $null.
.PARAMETER ExeInfo
    The ConvertFrom-AUExeInfo result for the entry.
.PARAMETER MsiFileMap
    Lowercased full path to the ProductCode of the Windows Installer product that owns it.
.PARAMETER ServiceBinaries
    Lowercased path to service name (Get-AUServiceBinaries).
.PARAMETER UserSid
    The entry's user SID (from the ledger key).
.PARAMETER ExeInfoText
    The SRUM ExeInfo string, for a Package entry's PackageFamily.
.PARAMETER ReadBudget
    The run's New-AUReadBudget result (Task 15 creates one per run and closes it in a finally
    block), or $null for a budget for this call only.
#>
    param (
        [string]$Path,
        [pscustomobject]$ExeInfo,
        [hashtable]$MsiFileMap,
        [hashtable]$ServiceBinaries,
        [string]$UserSid,
        [string]$ExeInfoText,
        [pscustomobject]$ReadBudget
    )

    $Kind = $null
    $ExeName = $null
    if ($null -ne $ExeInfo) { $Kind = [string]$ExeInfo.Kind; $ExeName = $ExeInfo.ExeName }
    $RunPath = $null
    if ($Kind -ne 'Package' -and -not [string]::IsNullOrWhiteSpace($Path)) { $RunPath = $Path.Trim() }

    $Facts = [pscustomobject][ordered]@{
        ExeName         = $ExeName
        RunPath         = $RunPath
        LocationClass   = $null
        FileDescription = $null
        FileProductName = $null
        FileCompanyName = $null
        FileVersion     = $null
        ProductVersion  = $null
        FactsVerified   = $false
        Subsystem       = $null
        MsiProductCode  = $null
        PackageFamily   = $null
        IsServiceBinary = $false
        UserSid         = $UserSid
        PathEvidence    = $null
    }
    if ($Kind -eq 'Package')
    {
        try { $Facts.PackageFamily = ConvertTo-AUPackageFamily $ExeInfoText } catch { $Facts.PackageFamily = $null }
        return $Facts
    }
    if (-not $RunPath) { return $Facts }

    $Text = { param ($Value) if ($null -eq $Value) { return $null }; return ([string]$Value).Trim() }
    $Key = $RunPath.ToLowerInvariant()
    $Facts.LocationClass = Get-AULocationClass $RunPath
    if ($null -ne $ServiceBinaries -and $ServiceBinaries.ContainsKey($Key)) { $Facts.IsServiceBinary = $true }

    $Roots = $null
    if ($null -ne $ReadBudget) { $Roots = $ReadBudget.ProtectedRoots }
    $CheckOwner = -not (Test-AUProtectedPath $RunPath $Roots)
    $Read = Read-AUFile $RunPath -WithVersion -WithOwner:$CheckOwner -ReadBudget $ReadBudget
    if ($Read.Status -ne 'OK' -or $null -eq $Read.Before) { return $Facts }
    if ($CheckOwner -and -not (Test-AUTrustedFileOwner -Owner $Read.Owner -UserSid $UserSid))
    {
        # Another user could have planted it: no facts and no evidence (I2).
        if ($null -ne $ReadBudget) { $ReadBudget.UntrustedOwner++ }
        else { Write-CMTraceLog -Message "App Usage: an executable file outside the protected folders has an owner that isn't trusted for its entry, so it's treated as unverified." -Component 'AppUsage' -Type 2 }
        return $Facts
    }
    if ($Read.Error) { Write-CMTraceLog -Message "App Usage: couldn't read the version info of $(Get-AUFileLeaf $RunPath): $(Get-AUSafeLogText $Read.Error)" -Component 'AppUsage' -Type 2 }
    $Info = $Read.Info
    if ($null -eq $Info) { return $Facts }

    # The file could be replaced while it's read; the facts count only if the build is there before and after.
    if ((Test-AUFingerprintMatch $Read.Before $ExeInfo) -and (Test-AUFingerprintMatch $Read.After $ExeInfo))
    {
        $Facts.FileDescription = & $Text $Info.FileDescription
        $Facts.FileProductName = & $Text $Info.ProductName
        $Facts.FileCompanyName = & $Text $Info.CompanyName
        $Facts.FileVersion = & $Text $Info.FileVersion
        $Facts.ProductVersion = & $Text $Info.ProductVersion
        $Facts.Subsystem = $Read.Before.Subsystem
        if ($null -ne $MsiFileMap -and $MsiFileMap.ContainsKey($Key)) { $Facts.MsiProductCode = [string]$MsiFileMap[$Key] }
        $Facts.FactsVerified = $true
        return $Facts
    }

    # Unverified: the current file at this path gives identity evidence only (D30).
    $Facts.PathEvidence = [pscustomobject][ordered]@{ CompanyName = & $Text $Info.CompanyName; ProductName = & $Text $Info.ProductName }
    return $Facts
}#endfunction

function Get-AUServiceRecords
{
    <#
.SYNOPSIS
    Returns every Win32 service's Name and PathName. A separate function so tests can mock the WMI read.
.DESCRIPTION
    The query gives up after AUServiceQueryTimeoutSeconds (30) and throws, so a stuck WMI service
    can't hang the run; Get-AUServiceBinaries then logs it and returns an empty map.
#>
    return @(Get-CimInstance -ClassName Win32_Service -Property Name, PathName -OperationTimeoutSec $script:AUServiceQueryTimeoutSeconds -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Name; PathName = [string]$_.PathName } })
}#endfunction

function Get-AUServiceDll
{
    <#
.SYNOPSIS
    Returns a service's Parameters\ServiceDll value, expanded, or $null. A separate function so tests can mock the registry read.
.PARAMETER ServiceName
    The service name.
#>
    param (
        [string]$ServiceName
    )

    if ([string]::IsNullOrWhiteSpace($ServiceName) -or $ServiceName.IndexOfAny([char[]]@('\', '/')) -ge 0) { return $null }
    $Base = Open-AURegistryBase -Hive Machine
    $Key = $null
    try
    {
        $Key = $Base.OpenSubKey("$script:AUServicesKey\$ServiceName\Parameters")
        if ($null -eq $Key) { return $null }
        $Value = Get-AURegistryValue -Key $Key -Name 'ServiceDll' -ProfilePath ''
        if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) { return $null }
        return $Value
    }
    finally
    {
        if ($null -ne $Key) { $Key.Close() }
        $Base.Close()
    }
}#endfunction

function ConvertTo-AUServiceFile
{
    <#
.SYNOPSIS
    Returns the file a service's PathName or ServiceDll names, as a drive-letter path, or $null.
.DESCRIPTION
    Machine environment variables are expanded; a quoted path is taken whole, an unquoted one up to
    its .exe or .dll, so arguments are dropped (Get-AUCommandFile). A \??\ prefix is removed and
    \SystemRoot\ becomes the Windows folder. Anything that isn't then a drive-letter path gives $null.
.PARAMETER Command
    The PathName or ServiceDll value.
#>
    param (
        [string]$Command
    )

    if ([string]::IsNullOrWhiteSpace($Command)) { return $null }
    $File = Get-AUCommandFile (Expand-AUEnvironmentText -Text $Command.Trim() -ProfilePath '')
    if (-not $File) { return $null }
    $File = $File.Trim()
    if ($File.StartsWith('\??\')) { $File = $File.Substring(4) }
    if ($File -match '^\\SystemRoot\\') { $File = [Environment]::GetEnvironmentVariable('SystemRoot') + $File.Substring(11) }
    if ($File -notmatch '^[A-Za-z]:\\') { return $null }
    return $File
}#endfunction

function Get-AUServiceBinaries
{
    <#
.SYNOPSIS
    Returns the files Windows services run: lowercased path to service name (F36).
.DESCRIPTION
    From each Win32_Service PathName, quoted or unquoted, with its arguments dropped. A service
    hosted by svchost.exe maps through its Parameters\ServiceDll value instead, or is left out when
    it has none. When two services run the same file, the first by name keeps it. Read once per run;
    Task 15 passes the result to Get-AUExeFacts. An unreadable service list gives an empty map and is
    logged. Never throws.
#>
    $Map = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
    try { $Services = @(Get-AUServiceRecords) }
    catch
    {
        Write-CMTraceLog -Message "App Usage: couldn't list the services; no executable counts as a service binary: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 2
        return $Map
    }

    $Order = @($Services | Where-Object { $null -ne $_ } | Sort-Object -Property @{ Expression = { [string]$_.Name } })
    $Hosted = 0
    foreach ($Service in $Order)
    {
        $Name = ([string]$Service.Name).Trim()
        if (-not $Name) { continue }
        $File = $null
        try
        {
            $File = ConvertTo-AUServiceFile ([string]$Service.PathName)
            if ($File -and [string]::Equals([IO.Path]::GetFileName($File), 'svchost.exe', [StringComparison]::OrdinalIgnoreCase))
            {
                $File = ConvertTo-AUServiceFile (Get-AUServiceDll $Name)
                if ($File) { $Hosted++ }
            }
        }
        catch { $File = $null }
        if (-not $File) { continue }
        $Key = $File.ToLowerInvariant()
        if (-not $Map.ContainsKey($Key)) { $Map[$Key] = $Name }
    }
    Write-CMTraceLog -Message "App Usage: $($Map.Count) service binaries from $($Order.Count) services ($Hosted hosted by svchost.exe)." -Component 'AppUsage'
    return $Map
}#endfunction

# All-profile discovery and the inventory list (Task 13). App Usage reads HKEY_USERS through .NET
# registry keys and its own AU_<SID> mount names, never a PSDrive named HKU (F34): the D36 fallback,
# Get-InstalledApplications, mounts and removes that drive.
$script:AURegPath = "$env:SystemRoot\System32\reg.exe"
$script:AUSystemSid = 'S-1-5-18'
# LocalService and NetworkService: their per-user installs are discovered with their own SID as
# Scope (install status needs them), but they aren't anyone's profile, so ConvertTo-AUInventoryApps
# leaves them out of the inventory. SYSTEM's own per-user installs are in it.
$script:AUExcludedProfileSids = @('S-1-5-19', 'S-1-5-20')
# The two Uninstall views, written as version 19's Get-InstalledApplications writes them, so RegPath
# matches its AppUninstallRegPath exactly (F31).
$script:AUUninstallNative = 'Software\Microsoft\Windows\CurrentVersion\Uninstall'
$script:AUUninstallWow = 'Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
$script:AUInstallerUserData = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData'
# Variables whose value belongs to one user. SYSTEM's own values for them are never used.
$script:AUPerUserVariables = @('USERPROFILE', 'LOCALAPPDATA', 'APPDATA', 'HOMEDRIVE', 'HOMEPATH', 'HOMESHARE', 'USERNAME', 'USERDOMAIN', 'USERDNSDOMAIN',
    'USERDOMAIN_ROAMINGPROFILE', 'LOGONSERVER', 'TEMP', 'TMP', 'OneDrive', 'OneDriveCommercial', 'OneDriveConsumer', 'SESSIONNAME', 'CLIENTNAME')

function Get-AUUsers
{
    <#
.SYNOPSIS
    Returns every profile in ProfileList with Sid, UserType, ProfilePath, and ProfileState.
.DESCRIPTION
    ProfileState is Loaded (the hive is loaded, so it's read in place), Copied (the snapshot holds a
    copy of the signed-out user's hive), CopyFailed (signed out, and there's no copy: the copy failed,
    the profile is off the system drive, or the copy file is gone), or Missing (signed out, and the
    profile folder isn't on the device, for example a profile container that isn't attached). A user
    signed out at the snapshot is read from the copy even when signed in now. ProfileList can't show a
    deleted profile; Invoke-AppUsage marks those Deleted (F29). UserType comes from Get-AUUserType
    with the snapshot's MachineDomainSid. Never throws; returns nothing when ProfileList can't be read.
.PARAMETER Snapshot
    The New-AUSnapshot result, or $null (no copies: every signed-out user is CopyFailed or Missing).
#>
    param (
        $Snapshot
    )

    try
    {
        $Copies = $null
        if ($null -ne $Snapshot)
        {
            $DomainSid = [string]$Snapshot.MachineDomainSid
            $Copies = $Snapshot.HiveCopies
        }
        else { $DomainSid = [string](Get-AUMachineDomainSid) }

        $Users = New-Object 'System.Collections.Generic.List[object]'
        foreach ($Entry in @(Get-AUProfileList))
        {
            if ($null -eq $Entry -or -not $Entry.Sid) { continue }
            $Sid = [string]$Entry.Sid
            $ProfilePath = [string]$Entry.ProfilePath
            $FolderMissing = (-not $ProfilePath -or -not [IO.Directory]::Exists($ProfilePath))
            if ($null -ne $Copies -and $Copies.ContainsKey($Sid))
            {
                $Copy = [string]$Copies[$Sid]
                if ($Copy -and [IO.File]::Exists($Copy)) { $State = 'Copied' }
                elseif ($FolderMissing) { $State = 'Missing' }
                else { $State = 'CopyFailed' }
            }
            elseif (Test-AUHiveLoaded -Sid $Sid) { $State = 'Loaded' }
            elseif ($FolderMissing) { $State = 'Missing' }
            else { $State = 'CopyFailed' }
            $Users.Add([pscustomobject]@{
                    Sid          = $Sid
                    UserType     = Get-AUUserType -Sid $Sid -MachineDomainSid $DomainSid
                    ProfilePath  = $ProfilePath
                    ProfileState = $State
                })
        }
        $Counts = @($Users | Group-Object ProfileState | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ', '
        Write-CMTraceLog -Message "App Usage: $($Users.Count) profiles in ProfileList ($Counts)." -Component 'AppUsage'
        return $Users.ToArray()
    }
    catch { Write-CMTraceLog -Message "App Usage: couldn't list the users: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3 }
}#endfunction

function Expand-AUEnvironmentText
{
    <#
.SYNOPSIS
    Expands the %VARIABLE% references in a REG_EXPAND_SZ value without using SYSTEM's per-user values.
.DESCRIPTION
    Machine variables (ProgramFiles, ProgramFiles(x86), SystemRoot, windir, ProgramData,
    CommonProgramFiles, and the rest) expand from the environment, as Windows does. Per-user variables
    never take SYSTEM's values: for a per-user entry, USERPROFILE is the user's ProfilePath and
    LOCALAPPDATA its AppData\Local; every other per-user variable (APPDATA, which can be redirected,
    TEMP, USERNAME, and so on) stays unexpanded, as does any variable that isn't defined.
.PARAMETER Text
    The raw value.
.PARAMETER ProfilePath
    The owning user's profile folder, or blank for a machine entry.
#>
    param (
        [string]$Text,
        [string]$ProfilePath
    )

    if ([string]::IsNullOrEmpty($Text) -or $Text.IndexOf('%') -lt 0) { return $Text }
    $UserRoot = ([string]$ProfilePath).Trim().TrimEnd('\')
    $Builder = New-Object Text.StringBuilder
    $Last = 0
    foreach ($Match in [regex]::Matches($Text, '%([^%\r\n]+)%'))
    {
        [void]$Builder.Append($Text, $Last, $Match.Index - $Last)
        $Last = $Match.Index + $Match.Length
        $Name = $Match.Groups[1].Value
        $Value = $null
        if ($script:AUPerUserVariables -contains $Name)
        {
            if ($UserRoot -and $Name -eq 'USERPROFILE') { $Value = $UserRoot }
            elseif ($UserRoot -and $Name -eq 'LOCALAPPDATA') { $Value = $UserRoot + '\AppData\Local' }
        }
        else { $Value = [Environment]::GetEnvironmentVariable($Name) }
        if ($null -eq $Value) { $Value = $Match.Value }
        [void]$Builder.Append($Value)
    }
    [void]$Builder.Append($Text, $Last, $Text.Length - $Last)
    return $Builder.ToString()
}#endfunction

function Get-AURegistryValue
{
    <#
.SYNOPSIS
    Returns a registry value as stored, with a REG_EXPAND_SZ value expanded by Expand-AUEnvironmentText.
.DESCRIPTION
    Other types come back as Get-ItemProperty gives them (a string array for REG_MULTI_SZ, a number for
    a DWORD), so the inventory fields match version 19. $null when the value is absent.
.PARAMETER Key
    The open registry key.
.PARAMETER Name
    The value name.
.PARAMETER ProfilePath
    The owning user's profile folder, or blank for a machine entry.
#>
    param (
        [Microsoft.Win32.RegistryKey]$Key,
        [string]$Name,
        [string]$ProfilePath
    )

    $Value = $Key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    if ($Value -is [string] -and $Key.GetValueKind($Name) -eq [Microsoft.Win32.RegistryValueKind]::ExpandString)
    {
        $Value = Expand-AUEnvironmentText -Text $Value -ProfilePath $ProfilePath
    }
    # The comma keeps a REG_MULTI_SZ array whole.
    return , $Value
}#endfunction

function ConvertTo-AUInstallDate
{
    <#
.SYNOPSIS
    Converts an ARP InstallDate exactly as version 19 does: yyyyMMdd becomes dd-MM-yyyy, anything else $null.
.PARAMETER Value
    The raw InstallDate value.
#>
    param (
        $Value
    )

    if (![string]::IsNullOrWhiteSpace($Value))
    {
        $parsedDate = [DateTime]::MinValue
        if ([DateTime]::TryParseExact($Value, 'yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsedDate))
        {
            return $parsedDate.ToString('dd-MM-yyyy')
        }
    }
    return $null
}#endfunction

function Open-AURegistryBase
{
    <#
.SYNOPSIS
    Opens HKEY_LOCAL_MACHINE (64-bit view) or one key directly under HKEY_USERS. The caller closes it.
.DESCRIPTION
    Returns $null when the HKEY_USERS key isn't there (the hive isn't loaded). Throws on other
    failures. A separate function so tests can point it at a fixture key.
.PARAMETER Hive
    Machine or Users.
.PARAMETER Name
    For Users, the key name: a SID, or an AU_ mount name.
#>
    param (
        [ValidateSet('Machine', 'Users')][string]$Hive,
        [string]$Name
    )

    if ($Hive -eq 'Machine') { return [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64) }
    $UsersKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::Users, [Microsoft.Win32.RegistryView]::Registry64)
    try { return $UsersKey.OpenSubKey($Name) }
    finally { $UsersKey.Close() }
}#endfunction

function Get-AUHiveMountName
{
    <#
.SYNOPSIS
    Returns the HKEY_USERS name App Usage loads a user's hive copy under: AU_ and the SID, with any
    character other than a letter, digit, or hyphen replaced by _.
.PARAMETER Sid
    The user SID.
#>
    param (
        [string]$Sid
    )

    return 'AU_' + [regex]::Replace([string]$Sid, '[^A-Za-z0-9-]', '_')
}#endfunction

function Dismount-AUHive
{
    <#
.SYNOPSIS
    Unloads HKEY_USERS\<MountName> with reg unload, after a garbage collection releases any open key
    handles. Tries three times. Returns true when it's unloaded. Never throws.
.PARAMETER MountName
    The AU_ mount name.
#>
    param (
        [string]$MountName
    )

    for ($Attempt = 1; $Attempt -le 3; $Attempt++)
    {
        try
        {
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            $Result = Invoke-AUProcess -FilePath $script:AURegPath -Arguments "unload `"HKU\$MountName`"" -WorkingDirectory ([IO.Path]::GetDirectoryName($script:AURegPath)) -TimeoutSeconds $script:AUToolTimeoutSeconds
            if ($Result.ExitCode -eq 0 -or -not (Test-AUHiveLoaded -Sid $MountName)) { return $true }
            $Detail = "exit $($Result.ExitCode), timed out $($Result.TimedOut): $(([string]$Result.Output).Trim())"
        }
        catch { $Detail = $_.Exception.Message }
        if ($Attempt -lt 3) { Start-Sleep -Milliseconds 500 }
    }
    Write-CMTraceLog -Message "App Usage: couldn't unload $(Get-AUSafeLogText "HKU\$MountName ($Detail)")." -Component 'AppUsage' -Type 3
    return $false
}#endfunction

function Mount-AUHive
{
    <#
.SYNOPSIS
    Loads a hive copy at HKEY_USERS\<MountName> with reg load. Returns true when it's loaded. Never throws.
.DESCRIPTION
    Only ever given a copy in the run work folder, never a user's live NTUSER.DAT. A mount of the same
    name left by a killed run is unloaded first.
.PARAMETER MountName
    The AU_ mount name (Get-AUHiveMountName).
.PARAMETER Path
    The hive copy.
#>
    param (
        [string]$MountName,
        [string]$Path
    )

    try
    {
        if (-not $Path -or -not [IO.File]::Exists($Path))
        {
            Write-CMTraceLog -Message "App Usage: the hive copy '$(Get-AUSafeLogText $Path)' isn't there, so $(Get-AUSafeLogText "HKU\$MountName") wasn't loaded." -Component 'AppUsage' -Type 2
            return $false
        }
        if (Test-AUHiveLoaded -Sid $MountName)
        {
            Write-CMTraceLog -Message "App Usage: $(Get-AUSafeLogText "HKU\$MountName") was still loaded (an earlier run stopped), so it's unloaded first." -Component 'AppUsage' -Type 2
            [void](Dismount-AUHive -MountName $MountName)
        }
        $Result = Invoke-AUProcess -FilePath $script:AURegPath -Arguments "load `"HKU\$MountName`" `"$Path`"" -WorkingDirectory ([IO.Path]::GetDirectoryName($Path)) -TimeoutSeconds $script:AUToolTimeoutSeconds
        if ($Result.ExitCode -eq 0) { return $true }
        Write-CMTraceLog -Message "App Usage: couldn't load the hive copy '$(Get-AUSafeLogText $Path)' at $(Get-AUSafeLogText "HKU\$MountName") (exit $($Result.ExitCode), timed out $($Result.TimedOut)): $(Get-AUSafeLogText ([string]$Result.Output).Trim())" -Component 'AppUsage' -Type 3
        # A load that timed out may still finish.
        if ($Result.TimedOut) { [void](Dismount-AUHive -MountName $MountName) }
    }
    catch { Write-CMTraceLog -Message "App Usage: couldn't load the hive copy '$(Get-AUSafeLogText $Path)' at $(Get-AUSafeLogText "HKU\$MountName")`: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3 }
    return $false
}#endfunction

function Read-AUArpEntries
{
    <#
.SYNOPSIS
    Adds an entry for each ARP Uninstall subkey with a DisplayName to a list. Returns true when the
    whole key was read (a key that doesn't exist counts as read, with no entries).
.DESCRIPTION
    Each entry has Task 5's fields (DisplayName, Publisher, DisplayVersion, ProductCode, PackageFamily,
    InstallLocation, DisplayIcon, UninstallString, Architecture, Scope, ProfilePath) and version 19's
    inventory fields (InstallDate converted as version 19 does, AppType Win32, and RegPath, the key's
    full path under ShownBase). ProductCode is the key name when it's a {GUID}. DisplayName, Publisher,
    and DisplayVersion are kept as stored; only REG_EXPAND_SZ values are expanded
    (Expand-AUEnvironmentText). An entry needs a DisplayName that's true in PowerShell, as in version 19.
.PARAMETER Base
    The open hive root: HKEY_LOCAL_MACHINE, or a user's hive.
.PARAMETER ShownBase
    The root as RegPath shows it: HKEY_LOCAL_MACHINE or HKEY_USERS\<SID>, never the AU_ mount name.
.PARAMETER SubPath
    The Uninstall key path under Base.
.PARAMETER Scope
    Machine, or the owning user's SID.
.PARAMETER ProfilePath
    The profile folder used to expand per-user variables, or blank.
.PARAMETER EntryProfilePath
    The ProfilePath put on each entry: the user's folder for per-user entries, else blank.
.PARAMETER Architecture
    32 or 64, from the registry view, or $null when the view doesn't say.
.PARAMETER Into
    The list the entries are added to.
#>
    param (
        [Microsoft.Win32.RegistryKey]$Base,
        [string]$ShownBase,
        [string]$SubPath,
        [string]$Scope,
        [string]$ProfilePath,
        [string]$EntryProfilePath,
        $Architecture,
        [System.Collections.Generic.List[object]]$Into
    )

    $Complete = $true
    $Key = $null
    try
    {
        $Key = $Base.OpenSubKey($SubPath)
        if ($null -eq $Key) { return $true }
        foreach ($Name in $Key.GetSubKeyNames())
        {
            $Sub = $null
            try
            {
                $Sub = $Key.OpenSubKey($Name)
                if ($null -eq $Sub) { continue }
                $DisplayName = Get-AURegistryValue -Key $Sub -Name 'DisplayName' -ProfilePath $ProfilePath
                if (-not $DisplayName) { continue }
                $ProductCode = $null
                if ($Name -match '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$') { $ProductCode = $Name }
                $EntryPath = $null
                if ($EntryProfilePath) { $EntryPath = $EntryProfilePath }
                $Into.Add([pscustomobject]@{
                        DisplayName     = $DisplayName
                        DisplayVersion  = Get-AURegistryValue -Key $Sub -Name 'DisplayVersion' -ProfilePath $ProfilePath
                        Publisher       = Get-AURegistryValue -Key $Sub -Name 'Publisher' -ProfilePath $ProfilePath
                        ProductCode     = $ProductCode
                        PackageFamily   = $null
                        InstallLocation = Get-AURegistryValue -Key $Sub -Name 'InstallLocation' -ProfilePath $ProfilePath
                        DisplayIcon     = Get-AURegistryValue -Key $Sub -Name 'DisplayIcon' -ProfilePath $ProfilePath
                        UninstallString = Get-AURegistryValue -Key $Sub -Name 'UninstallString' -ProfilePath $ProfilePath
                        Architecture    = $Architecture
                        Scope           = $Scope
                        ProfilePath     = $EntryPath
                        InstallDate     = ConvertTo-AUInstallDate (Get-AURegistryValue -Key $Sub -Name 'InstallDate' -ProfilePath $ProfilePath)
                        AppType         = 'Win32'
                        RegPath         = "$ShownBase\$SubPath\$Name"
                    })
            }
            catch
            {
                $Complete = $false
                Write-CMTraceLog -Message "App Usage: couldn't read an uninstall entry under $(Get-AUSafeLogText "$ShownBase\$SubPath")`: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 2
            }
            finally { if ($null -ne $Sub) { $Sub.Close() } }
        }
    }
    catch
    {
        $Complete = $false
        Write-CMTraceLog -Message "App Usage: couldn't read $(Get-AUSafeLogText "$ShownBase\$SubPath")`: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3
    }
    finally { if ($null -ne $Key) { $Key.Close() } }
    return $Complete
}#endfunction

function ConvertFrom-AUPackedGuid
{
    <#
.SYNOPSIS
    Converts a Windows Installer packed GUID (32 hex digits) to {XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}, or $null.
.DESCRIPTION
    The packed form reverses the first three groups and swaps each pair of digits in the last two.
.PARAMETER Packed
    The packed GUID.
#>
    param (
        [string]$Packed
    )

    if ($Packed -notmatch '^[0-9A-Fa-f]{32}$') { return $null }
    $Reverse = { param ([string]$Text) $Chars = $Text.ToCharArray(); [Array]::Reverse($Chars); -join $Chars }
    $Swap = {
        param ([string]$Text)
        -join @(for ($i = 0; $i -lt $Text.Length; $i += 2) { $Text[$i + 1]; $Text[$i] })
    }
    $Guid = '{0}-{1}-{2}-{3}-{4}' -f (& $Reverse $Packed.Substring(0, 8)), (& $Reverse $Packed.Substring(8, 4)), (& $Reverse $Packed.Substring(12, 4)),
    (& $Swap $Packed.Substring(16, 4)), (& $Swap $Packed.Substring(20, 12))
    return '{' + $Guid.ToUpperInvariant() + '}'
}#endfunction

function Read-AUMsiFileMap
{
    <#
.SYNOPSIS
    Fills a map of each executable Windows Installer records as a component key path to its product's
    ProductCode, from Installer\UserData for every SID. Returns true when it was read. Never throws.
.DESCRIPTION
    Only .exe files on a drive letter are kept: Task 14 looks up executables, and Get-AUKnownExes uses
    only .exe names. A path two products both record is left out, because neither owns it alone.
    Registry key paths, and components with no product (the all-zero value), are skipped. UserData
    feeds this map and ProductCode ownership only, never inventory entries (F33).
    A machine registration (UserData\S-1-5-18) claims any file. A per-user one (UserData\<SID>, which
    a standard user can create by installing a per-user package) claims only files under that SID's
    profile folder, so it can never claim, or make shared, a machine file for every user; with no
    profile folder known for the SID, it claims nothing. Ignored claims are counted in the log.
.PARAMETER Base
    The open HKEY_LOCAL_MACHINE root.
.PARAMETER Into
    The map: lowercased full path to ProductCode.
.PARAMETER ProfilePaths
    SID to profile folder (the Get-AUUsers ProfilePath of each user).
#>
    param (
        [Microsoft.Win32.RegistryKey]$Base,
        [hashtable]$Into,
        [hashtable]$ProfilePaths
    )

    $Shared = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $UserData = $null
    $Ignored = 0
    try
    {
        $UserData = $Base.OpenSubKey($script:AUInstallerUserData)
        if ($null -eq $UserData) { return $true }
        foreach ($Sid in $UserData.GetSubKeyNames())
        {
            # A per-user registration claims only files in its own profile folder (I3).
            $Prefix = $null
            if (-not [string]::Equals($Sid, $script:AUSystemSid, [StringComparison]::OrdinalIgnoreCase))
            {
                $Folder = ''
                if ($null -ne $ProfilePaths) { $Folder = ([string]$ProfilePaths[$Sid]).Trim().TrimEnd('\') }
                if ($Folder -notmatch '^[A-Za-z]:\\[^\\]') { $Folder = $null }
                if ($Folder) { $Prefix = $Folder + '\' }
                else { $Prefix = '' }
            }
            $Components = $UserData.OpenSubKey("$Sid\Components")
            if ($null -eq $Components) { continue }
            try
            {
                foreach ($Component in $Components.GetSubKeyNames())
                {
                    $Key = $Components.OpenSubKey($Component)
                    if ($null -eq $Key) { continue }
                    try
                    {
                        foreach ($ValueName in $Key.GetValueNames())
                        {
                            if ($ValueName -notmatch '^[0-9A-Fa-f]{32}$' -or $ValueName -match '^0{32}$') { continue }
                            $Path = [string]$Key.GetValue($ValueName)
                            # C?\ marks a component path the same way as C:\.
                            if ($Path -match '^[A-Za-z]\?\\') { $Path = $Path.Substring(0, 1) + ':' + $Path.Substring(2) }
                            if ($Path -notmatch '^[A-Za-z]:\\' -or -not $Path.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) { continue }
                            $File = $Path.ToLowerInvariant()
                            if ($null -ne $Prefix -and ($Prefix -eq '' -or -not $File.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase)))
                            {
                                $Ignored++
                                continue
                            }
                            $Code = ConvertFrom-AUPackedGuid $ValueName
                            if ($Shared.Contains($File)) { continue }
                            if ($Into.ContainsKey($File))
                            {
                                if (-not [string]::Equals([string]$Into[$File], $Code, [StringComparison]::OrdinalIgnoreCase))
                                {
                                    [void]$Shared.Add($File)
                                    $Into.Remove($File)
                                }
                                continue
                            }
                            $Into[$File] = $Code
                        }
                    }
                    finally { $Key.Close() }
                }
            }
            finally { $Components.Close() }
        }
        Write-CMTraceLog -Message "App Usage: Windows Installer records $($Into.Count) executables; $($Shared.Count) shared by two products were left out, and $Ignored per-user records outside their own profile folder were ignored." -Component 'AppUsage'
        return $true
    }
    catch
    {
        Write-CMTraceLog -Message "App Usage: couldn't read Windows Installer UserData: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 2
        return $false
    }
    finally { if ($null -ne $UserData) { $UserData.Close() } }
}#endfunction

function Read-AUUserApps
{
    <#
.SYNOPSIS
    Reads one user's ARP entries, from the loaded hive or from the snapshot's hive copy. Returns true
    when both Uninstall views were read. Never throws.
.DESCRIPTION
    A Copied user's copy is loaded at HKU\AU_<SID>, read, and unloaded in finally after a garbage
    collection. A copy that won't load sets the user's ProfileState to CopyFailed; a loaded copy sets
    the user's HiveUnloadFailed to whether it wouldn't unload afterwards. RegPath always shows
    HKEY_USERS\<SID>, never the mount name. SYSTEM's (S-1-5-18) entries are machine scope; other
    entries have the user's SID as Scope and ProfilePath. HKEY_CURRENT_USER\Software is shared between
    32-bit and 64-bit programs, so a per-user entry's Architecture is 32 only from Wow6432Node and
    otherwise $null.
.PARAMETER User
    A Get-AUUsers entry.
.PARAMETER Snapshot
    The New-AUSnapshot result, for HiveCopies.
.PARAMETER Native
    The list for entries from the native Uninstall key.
.PARAMETER Wow
    The list for entries from the Wow6432Node Uninstall key.
#>
    param (
        [pscustomobject]$User,
        $Snapshot,
        [System.Collections.Generic.List[object]]$Native,
        [System.Collections.Generic.List[object]]$Wow
    )

    $Sid = [string]$User.Sid
    $ShownBase = "HKEY_USERS\$Sid"
    $Scope = $Sid
    $EntryProfilePath = [string]$User.ProfilePath
    if ($Sid -eq $script:AUSystemSid)
    {
        $Scope = 'Machine'
        $EntryProfilePath = ''
    }
    $ReadHive = {
        param ([Microsoft.Win32.RegistryKey]$Base)
        $NativeRead = Read-AUArpEntries -Base $Base -ShownBase $ShownBase -SubPath $script:AUUninstallNative -Scope $Scope -ProfilePath $User.ProfilePath -EntryProfilePath $EntryProfilePath -Architecture $null -Into $Native
        $WowRead = Read-AUArpEntries -Base $Base -ShownBase $ShownBase -SubPath $script:AUUninstallWow -Scope $Scope -ProfilePath $User.ProfilePath -EntryProfilePath $EntryProfilePath -Architecture 32 -Into $Wow
        return ($NativeRead -and $WowRead)
    }

    try
    {
        switch ([string]$User.ProfileState)
        {
            'Loaded'
            {
                $Base = Open-AURegistryBase -Hive Users -Name $Sid
                if ($null -eq $Base)
                {
                    Write-CMTraceLog -Message "App Usage: a signed-in user's hive is no longer loaded, so that user's apps weren't read." -Component 'AppUsage' -Type 2
                    return $false
                }
                try { return [bool](& $ReadHive $Base) }
                finally { $Base.Close() }
            }
            'Copied'
            {
                $Copy = $null
                if ($null -ne $Snapshot -and $null -ne $Snapshot.HiveCopies) { $Copy = [string]$Snapshot.HiveCopies[$Sid] }
                $Mount = Get-AUHiveMountName -Sid $Sid
                if (-not (Mount-AUHive -MountName $Mount -Path $Copy))
                {
                    $User.ProfileState = 'CopyFailed'
                    return $false
                }
                $Base = $null
                try
                {
                    $Base = Open-AURegistryBase -Hive Users -Name $Mount
                    if ($null -eq $Base)
                    {
                        $User.ProfileState = 'CopyFailed'
                        Write-CMTraceLog -Message "App Usage: a hive copy isn't at its mount after loading it, so that user's apps weren't read." -Component 'AppUsage' -Type 3
                        return $false
                    }
                    return [bool](& $ReadHive $Base)
                }
                finally
                {
                    if ($null -ne $Base) { $Base.Close() }
                    $Base = $null
                    $User | Add-Member -NotePropertyName HiveUnloadFailed -NotePropertyValue (-not (Dismount-AUHive -MountName $Mount)) -Force
                }
            }
            default { return $false }
        }
    }
    catch
    {
        Write-CMTraceLog -Message "App Usage: couldn't read a user's apps: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3
        return $false
    }
}#endfunction

# Version 19's Windows 11 24H2 fix for Get-AppxPackage (Get-AppxInstalledApplications): these
# PowerShell DLLs must be in the global assembly cache, or Get-AppxPackage fails.
$script:AUAppxGacDlls = @('System.Memory.dll', 'System.Numerics.Vectors.dll', 'System.Runtime.CompilerServices.Unsafe.dll', 'System.Security.Principal.Windows.dll')
$script:AUAppxSupportChecked = $false

function Initialize-AUAppxSupport
{
    <#
.SYNOPSIS
    Applies version 19's Windows 11 24H2 fix before Get-AppxPackage, once per run. Never throws.
.DESCRIPTION
    The same fix as version 19's Get-AppxInstalledApplications: each DLL in $script:AUAppxGacDlls
    that isn't in the global assembly cache is installed there from
    C:\Windows\System32\WindowsPowerShell\v1.0 with System.EnterpriseServices'
    Publish.GacInstall. Both are in-box; nothing is compiled or downloaded (D25). Version 19 searches
    the whole cache for each file name; this looks only in the folders an assembly of that name can
    be in (GAC_MSIL, GAC_64, GAC_32), which gives the same answer without the recursive search.
    Failures are logged, and Get-AppxPackage is still tried.
#>
    if ($script:AUAppxSupportChecked) { return }
    $script:AUAppxSupportChecked = $true
    try
    {
        Add-Type -AssemblyName 'System.EnterpriseServices' -ErrorAction Stop
        $Publish = New-Object System.EnterpriseServices.Internal.Publish
    }
    catch
    {
        Write-CMTraceLog -Message "App Usage: couldn't load System.EnterpriseServices for the 24H2 Get-AppxPackage fix: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 2
        return
    }
    $Cache = [IO.Path]::Combine($env:SystemRoot, 'Microsoft.NET\assembly')
    foreach ($Dll in $script:AUAppxGacDlls)
    {
        try
        {
            $Name = [IO.Path]::GetFileNameWithoutExtension($Dll)
            $Present = $false
            foreach ($Folder in @('GAC_MSIL', 'GAC_64', 'GAC_32')) { if ([IO.Directory]::Exists([IO.Path]::Combine([IO.Path]::Combine($Cache, $Folder), $Name))) { $Present = $true } }
            if ($Present) { continue }
            $Publish.GacInstall([IO.Path]::Combine($env:SystemRoot, "System32\WindowsPowerShell\v1.0\$Dll"))
            Write-CMTraceLog -Message "App Usage: installed $Dll in the global assembly cache (24H2 Get-AppxPackage fix)." -Component 'AppUsage'
        }
        catch { Write-CMTraceLog -Message "App Usage: couldn't install $Dll in the global assembly cache: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 2 }
    }
}#endfunction

function Get-AUAppxPackages
{
    <#
.SYNOPSIS
    Returns every user's Store and MSIX packages (Get-AppxPackage -AllUsers), after version 19's
    24H2 fix (Initialize-AUAppxSupport). Throws on failure.
#>
    Initialize-AUAppxSupport
    return Get-AppxPackage -AllUsers -ErrorAction Stop
}#endfunction

function Get-AUAppxPublisher
{
    <#
.SYNOPSIS
    Returns a package's PublisherDisplayName from its manifest, as version 19 reads it. Throws on failure.
.PARAMETER PackageFullName
    The package full name.
#>
    param (
        [string]$PackageFullName
    )

    $Manifest = Get-AppxPackageManifest -Package $PackageFullName -ErrorAction Stop
    return $Manifest.Package.Properties.PublisherDisplayName
}#endfunction

function Read-AUStoreApps
{
    <#
.SYNOPSIS
    Adds an entry for each Store or MSIX package installed for a user. Returns true when the packages
    were read. Never throws.
.DESCRIPTION
    A package counts when a user has it in the Installed state, as in version 19's
    Get-AppxInstalledApplications; it gets one entry per such user, with that user's SID as Scope
    (S-1-5-18 is machine scope). DisplayName is the package name and DisplayVersion its version, as in
    version 19; PackageFamily, InstallLocation, and Architecture come from the package.
.PARAMETER Users
    The Get-AUUsers entries, for ProfilePath.
.PARAMETER Into
    The list the entries are added to.
#>
    param (
        [object[]]$Users,
        [System.Collections.Generic.List[object]]$Into
    )

    try { $Packages = @(Get-AUAppxPackages) }
    catch
    {
        Write-CMTraceLog -Message "App Usage: couldn't read the Store and MSIX packages: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3
        return $false
    }
    $Profiles = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
    foreach ($User in @($Users)) { if ($null -ne $User -and $User.Sid) { $Profiles[[string]$User.Sid] = [string]$User.ProfilePath } }
    $Complete = $true
    foreach ($Package in $Packages)
    {
        try
        {
            if ($null -eq $Package) { continue }
            $Sids = New-Object 'System.Collections.Generic.List[string]'
            $AnyInstalled = $false
            foreach ($Info in @($Package.PackageUserInformation))
            {
                if ($null -eq $Info -or [string]$Info.InstallState -ne 'Installed') { continue }
                $AnyInstalled = $true
                $Sid = ''
                if ($null -ne $Info.UserSecurityId) { $Sid = ([string]$Info.UserSecurityId.Sid).Trim() }
                if ($Sid -and -not $Sids.Contains($Sid)) { $Sids.Add($Sid) }
            }
            if (-not $AnyInstalled) { continue }
            $Publisher = $null
            try { $Publisher = Get-AUAppxPublisher -PackageFullName ([string]$Package.PackageFullName) }
            catch { Write-CMTraceLog -Message "App Usage: couldn't read the manifest of $($Package.PackageFullName): $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 2 }
            # Installed with no user SID shown: a blank Scope, which counts as present in every scope.
            if ($Sids.Count -eq 0) { $Sids.Add('') }
            foreach ($Sid in $Sids)
            {
                $Scope = $Sid
                $EntryPath = $null
                if ($Sid -eq $script:AUSystemSid) { $Scope = 'Machine' }
                elseif ($Sid -and $Profiles.ContainsKey($Sid) -and $Profiles[$Sid]) { $EntryPath = $Profiles[$Sid] }
                if (-not $Scope) { $Scope = $null }
                $Into.Add([pscustomobject]@{
                        DisplayName     = $Package.Name
                        DisplayVersion  = [string]$Package.Version
                        Publisher       = $Publisher
                        ProductCode     = $null
                        PackageFamily   = [string]$Package.PackageFamilyName
                        InstallLocation = [string]$Package.InstallLocation
                        DisplayIcon     = $null
                        UninstallString = $null
                        Architecture    = [string]$Package.Architecture
                        Scope           = $Scope
                        ProfilePath     = $EntryPath
                        InstallDate     = $null
                        AppType         = 'UWP'
                        RegPath         = $null
                    })
            }
        }
        catch
        {
            $Complete = $false
            Write-CMTraceLog -Message "App Usage: couldn't read the package $($Package.PackageFullName): $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 2
        }
    }
    return $Complete
}#endfunction

function Get-AUInstalledApps
{
    <#
.SYNOPSIS
    Discovers the installed apps on every accessible profile: Apps, ScopeRead, MsiFileMap,
    ProfilesFound, and ProfilesRead.
.DESCRIPTION
    Inventory entries come only from ARP Uninstall keys (HKLM, 64-bit and 32-bit, and every user's
    hive, loaded or copied) and, with -IncludeStore, Store and MSIX packages (D46, F33, F35). Windows
    Installer UserData feeds MsiFileMap only. Apps are in version 19's read order (HKLM native, each
    user's native key, HKLM Wow6432Node, each user's Wow6432Node key, then Store packages), so
    ConvertTo-AUInventoryApps gives version 19's result for the same data.
    ScopeRead (Task 7's shape) holds Machine and every user's SID, each Read or Unread. Machine is Read
    when both HKLM views and SYSTEM's hive (S-1-5-18 among the users) were read, so with no SYSTEM
    user, Machine stays Unread. S-1-5-18 takes Machine's state, because SYSTEM's entries are machine
    scope. A user is Read when both views of their hive were read; a user who is CopyFailed or
    Missing, or whose copy won't load (ProfileState becomes CopyFailed), is Unread. When -IncludeStore
    is set and the packages can't be read, every user SID, S-1-5-18 included, is Unread while Machine
    keeps its state, since a Store app could be missing from any of them. A Machine that isn't Read,
    or a Loaded user who isn't, means the list is worse than version 19's read, and the caller falls
    back to it (D20, D36). Per-user installs of LocalService and NetworkService (S-1-5-19, S-1-5-20)
    are in Apps with their SID as Scope, ARP and Store alike; ConvertTo-AUInventoryApps leaves them
    out of the inventory.
    ProfilesFound is the number of users given; ProfilesRead, how many are Read. MsiFileMapRead is
    false when Windows Installer UserData couldn't be read (MsiFileMap is then incomplete), and
    HiveUnloadFailures counts the hive copies left loaded at HKU\AU_<SID>; Invoke-AppUsage reports
    both. Never throws.
.PARAMETER Users
    The Get-AUUsers entries. A failed hive load changes the entry's ProfileState.
.PARAMETER Snapshot
    The New-AUSnapshot result, for HiveCopies.
.PARAMETER IncludeStore
    Include Store and MSIX packages (Invoke-AppUsage passes $CollectUWPInventory, D46).
#>
    param (
        [object[]]$Users,
        $Snapshot,
        [switch]$IncludeStore
    )

    $ScopeRead = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
    $MsiFileMap = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
    $MsiRead = $false
    $Native = New-Object 'System.Collections.Generic.List[object]'
    $Wow = New-Object 'System.Collections.Generic.List[object]'
    $Store = New-Object 'System.Collections.Generic.List[object]'
    $UserList = @($Users | Where-Object { $null -ne $_ -and $_.Sid })
    $ScopeRead['Machine'] = 'Unread'
    $ScopeRead[$script:AUSystemSid] = 'Unread'
    foreach ($User in $UserList) { $ScopeRead[[string]$User.Sid] = 'Unread' }

    try
    {
        $MachineRead = $false
        $Machine = $null
        try
        {
            $Machine = Open-AURegistryBase -Hive Machine
            $NativeRead = Read-AUArpEntries -Base $Machine -ShownBase 'HKEY_LOCAL_MACHINE' -SubPath $script:AUUninstallNative -Scope 'Machine' -Architecture 64 -Into $Native
            $WowRead = Read-AUArpEntries -Base $Machine -ShownBase 'HKEY_LOCAL_MACHINE' -SubPath $script:AUUninstallWow -Scope 'Machine' -Architecture 32 -Into $Wow
            $MachineRead = ($NativeRead -and $WowRead)
            $ProfilePaths = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
            foreach ($User in $UserList) { $ProfilePaths[[string]$User.Sid] = [string]$User.ProfilePath }
            $MsiRead = [bool](Read-AUMsiFileMap -Base $Machine -Into $MsiFileMap -ProfilePaths $ProfilePaths)
        }
        catch { Write-CMTraceLog -Message "App Usage: couldn't read the machine's apps: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3 }
        finally { if ($null -ne $Machine) { $Machine.Close() } }

        # Only an actual read of SYSTEM's hive counts (ruling 4).
        $SystemRead = $false
        foreach ($User in $UserList)
        {
            $UserRead = Read-AUUserApps -User $User -Snapshot $Snapshot -Native $Native -Wow $Wow
            if ([string]$User.Sid -eq $script:AUSystemSid) { $SystemRead = $UserRead }
            elseif ($UserRead) { $ScopeRead[[string]$User.Sid] = 'Read' }
        }
        if ($MachineRead -and $SystemRead) { $ScopeRead['Machine'] = 'Read' }
        $ScopeRead[$script:AUSystemSid] = $ScopeRead['Machine']

        if ($IncludeStore -and -not (Read-AUStoreApps -Users $UserList -Into $Store))
        {
            foreach ($Name in @($ScopeRead.Keys)) { if ($Name -ne 'Machine') { $ScopeRead[$Name] = 'Unread' } }
        }
    }
    catch
    {
        Write-CMTraceLog -Message "App Usage: app discovery failed: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3
        foreach ($Name in @($ScopeRead.Keys)) { $ScopeRead[$Name] = 'Unread' }
    }

    $Apps = New-Object 'System.Collections.Generic.List[object]'
    $Apps.AddRange($Native)
    $Apps.AddRange($Wow)
    $Apps.AddRange($Store)
    $Read = @($UserList | Where-Object { $ScopeRead[[string]$_.Sid] -eq 'Read' }).Count
    $Unloaded = @($UserList | Where-Object { $null -ne $_.PSObject.Properties['HiveUnloadFailed'] -and $_.HiveUnloadFailed -eq $true }).Count
    Write-CMTraceLog -Message "App Usage: found $($Apps.Count) installed apps ($($Store.Count) Store); machine $($ScopeRead['Machine']); $Read of $($UserList.Count) profiles read." -Component 'AppUsage'
    return [pscustomobject]@{
        Apps               = $Apps.ToArray()
        ScopeRead          = $ScopeRead
        MsiFileMap         = $MsiFileMap
        ProfilesFound      = $UserList.Count
        ProfilesRead       = $Read
        MsiFileMapRead     = $MsiRead
        HiveUnloadFailures = $Unloaded
    }
}#endfunction

function ConvertTo-AUInventoryApps
{
    <#
.SYNOPSIS
    Builds the App Inventory entries from discovered apps: one per DisplayName, newest version, with the
    inventory's seven fields and no scope (D19, D20).
.DESCRIPTION
    Maps each entry to version 19's input shape (DisplayName, DisplayVersion, Publisher,
    UninstallString, InstallDate, PSPath from RegPath, AppType), in version 19's order: ARP entries
    sorted by DisplayName, then Store packages sorted and made unique by DisplayName and
    DisplayVersion. Then ConvertTo-AUAppArray, the inventory's own de-duplication, builds the entries.
    For HKLM and the signed-in user's data this gives exactly version 19's result (F31). Entries
    whose Scope is LocalService or NetworkService (S-1-5-19, S-1-5-20) are left out: those accounts
    aren't anyone's profile.
.PARAMETER Apps
    The Get-AUInstalledApps Apps.
#>
    param (
        [object[]]$Apps
    )

    $Win32 = New-Object 'System.Collections.Generic.List[object]'
    $Store = New-Object 'System.Collections.Generic.List[object]'
    foreach ($App in @($Apps))
    {
        if ($null -eq $App -or $script:AUExcludedProfileSids -contains ([string]$App.Scope).Trim()) { continue }
        if ($App.AppType -eq 'UWP')
        {
            $Store.Add([pscustomobject]@{
                    DisplayName    = $App.DisplayName
                    DisplayVersion = $App.DisplayVersion
                    Publisher      = $App.Publisher
                    AppType        = 'UWP'
                })
            continue
        }
        $PSPath = $null
        if ($App.RegPath) { $PSPath = 'Microsoft.PowerShell.Core\Registry::' + $App.RegPath }
        $Win32.Add([pscustomobject]@{
                DisplayName     = $App.DisplayName
                DisplayVersion  = $App.DisplayVersion
                Publisher       = $App.Publisher
                UninstallString = $App.UninstallString
                InstallDate     = $App.InstallDate
                PSPath          = $PSPath
                AppType         = 'Win32'
            })
    }
    $Inventory = @($Win32 | Sort-Object DisplayName) + @($Store | Sort-Object DisplayName, DisplayVersion -Unique)
    # A DisplayVersion that isn't a version makes version 19's sort write an error record; App Usage
    # never writes to the console (D40). The sort, and so the result, is the same either way.
    $ErrorActionPreference = 'SilentlyContinue'
    return ConvertTo-AUAppArray -Apps $Inventory
}#endfunction

function ConvertTo-AUAppArray
{
    <#
.SYNOPSIS
    The App Inventory de-duplication and entry build, shared by metering off and on (F32).
.DESCRIPTION
    Moved unchanged from the inline App Inventory section of version 19: one entry per DisplayName,
    the newest version of duplicates, with AppName, AppVersion, AppPublisher, AppType,
    AppInstallDate, AppUninstallString, and AppUninstallRegPath. Callers wrap the result in @().
.PARAMETER Apps
    Version 19's app objects: DisplayName, DisplayVersion, Publisher, UninstallString, InstallDate,
    PSPath, and AppType.
#>
    param (
        [object[]]$Apps
    )
    Write-CMTraceLog "Deduplicating applications..."
    $UniqueApps = ($Apps | Group-Object Displayname | Where-Object { $_.Count -eq 1 } ).Group
    $DuplicatedApps = ($Apps | Group-Object Displayname | Where-Object { $_.Count -gt 1 } ).Group
    Write-CMTraceLog "Found $($UniqueApps.Count) unique apps and $($DuplicatedApps.Count) duplicated apps"

    Write-CMTraceLog "Selecting newest version of duplicated apps..."
    $NewestDuplicateApp = ($DuplicatedApps | Group-Object DisplayName) | ForEach-Object { $_.Group | Sort-Object { [version]$_.DisplayVersion } -Descending | Select-Object -First 1 }
    $CleanAppList = $UniqueApps + $NewestDuplicateApp | Sort-Object DisplayName
    Write-CMTraceLog "Clean app list contains $($CleanAppList.Count) applications after deduplication"

    Write-CMTraceLog "Building app array for upload..."
    $AppArray = @()
    $appArrayCount = 0
    foreach ($App in $CleanAppList)
    {
        $tempapp = New-Object -TypeName PSObject

        if ($null -ne $App.DisplayName)
        {
            $tempapp | Add-Member -MemberType NoteProperty -Name "AppName" -Value $App.DisplayName -Force
            $appArrayCount++
        }
        else
        {
            $tempapp | Add-Member -MemberType NoteProperty -Name "AppName" -Value "" -Force
        }

        if ($null -ne $App.DisplayVersion)
        {
            $tempapp | Add-Member -MemberType NoteProperty -Name "AppVersion" -Value $App.DisplayVersion -Force
        }
        else
        {
            $tempapp | Add-Member -MemberType NoteProperty -Name "AppVersion" -Value "" -Force
        }

        if ($null -ne $App.Publisher)
        {
            $tempapp | Add-Member -MemberType NoteProperty -Name "AppPublisher" -Value $App.Publisher -Force
        }
        else
        {
            $tempapp | Add-Member -MemberType NoteProperty -Name "AppPublisher" -Value "" -Force
        }

        if ($null -ne $App.AppType)
        {
            $tempapp | Add-Member -MemberType NoteProperty -Name "AppType" -Value $App.AppType -Force
        }
        else
        {
            $tempapp | Add-Member -MemberType NoteProperty -Name "AppType" -Value "Unknown" -Force
        }

        if ($App.PSObject.Properties.Name -contains "InstallDate" -and $App.InstallDate)
        {
            $tempapp | Add-Member -MemberType NoteProperty -Name "AppInstallDate" -Value $App.InstallDate -Force
        }
        else
        {
            $tempapp | Add-Member -MemberType NoteProperty -Name "AppInstallDate" -Value $null -Force
        }

        if ($App.PSObject.Properties.Name -contains "UninstallString" -and $App.UninstallString)
        {
            $tempapp | Add-Member -MemberType NoteProperty -Name "AppUninstallString" -Value $App.UninstallString -Force
        }
        else
        {
            $tempapp | Add-Member -MemberType NoteProperty -Name "AppUninstallString" -Value $null -Force
        }

        if ($App.PSObject.Properties.Name -contains "PSPath" -and $App.PSPath)
        {
            $tempapp | Add-Member -MemberType NoteProperty -Name "AppUninstallRegPath" -Value $App.PSPath.Split("::")[-1] -Force
        }
        else
        {
            $tempapp | Add-Member -MemberType NoteProperty -Name "AppUninstallRegPath" -Value $null -Force
        }

        $AppArray += $tempapp
    }
    Write-CMTraceLog "Added $appArrayCount applications to app array"
    return $AppArray
}#endfunction

# Split runs and the outbox (D44, F48 to F54). With metering on, a run's App Inventory data goes in
# one row when it fits, or in several rows of the same table tied by RunId_g when it doesn't. Each
# row is its own call. Rows that still fail wait in the outbox, C:\Windows\AppUsage_<Serial>_outbox\,
# and the next run sends them first, unchanged.
# The one row-size limit (F48): Send-LogIngestionAPI's guard (0.9 * 1024 * 1024, rounded down) uses
# this constant, so a row New-AURunRows builds never fails the guard.
$script:AUMaxRowBytes = 943718
# The table has 10 columns per blob, so a piece 11 would be dropped silently (F49).
$script:AUMaxPiecesPerBlob = 10
# The outbox keeps the rows of this many runs, the most recent ones (D44).
$script:AUOutboxMaxRuns = 5
# Outbox files are <RunId>-<RowIndex>.json.
$script:AUOutboxFilePattern = '^(?<RunId>[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})-(?<RowIndex>[1-9][0-9]{0,8})\.json$'

# Outbox temp files older than this are leftovers of a run that stopped mid-write; Send-AUOutbox
# deletes them.
$script:AUOutboxTempMaxAgeHours = 24

# The sender (F51): Send-AUOutbox and Send-AURunRows take it as a required scriptblock,
# param([byte[]]$Body, [string]$LogAPIMode, [string]$LogType, [bool]$SingleAttempt), whose last
# output is an object with Ok ($true only when the row was accepted) and Permanent ($true only when
# the ingestion POST rejected the row itself, Test-AUPermanentStatus); a [bool] alone is read as Ok.
# The region never reads the inventory's connection settings, so the inline App Inventory section
# builds it outside the region ($AUSender): it calls Send-LogIngestionAPI (or Send-DataCollectorAPI
# for the classic API) with the inventory's connection variables, as the inline App Inventory upload
# does, so this run's rows keep the inventory's existing retry (Invoke-LogSubmission); with
# SingleAttempt (the outbox drain) it makes one attempt with no backoff. Ok is whether the response
# is the success status the summary line checks (204, or 200 for the classic API). Tests pass a mock.

function Get-AUColumnName
{
    <#
.SYNOPSIS
    Returns a column name as the inventory writes it: with the type suffix for the Logs Ingestion API, without it for the classic API.
.PARAMETER Name
    The name without its suffix, such as RunId.
.PARAMETER Type
    The suffix letter, such as g.
.PARAMETER LogAPIMode
    The inventory's $LogAPIMode.
#>
    param (
        [string]$Name,
        [string]$Type,
        [string]$LogAPIMode
    )

    if ($LogAPIMode -eq 'LogIngestionAPI') { return "$($Name)_$Type" }
    return $Name
}#endfunction

function Get-AUFileNameSerial
{
    <#
.SYNOPSIS
    Returns the serial as the ledger and outbox names use it (F44).
.DESCRIPTION
    Characters that aren't allowed in a file name become _. A blank serial falls back to the
    computer name.
.PARAMETER Serial
    The device's serial number.
.PARAMETER ComputerName
    The computer name.
#>
    param (
        [string]$Serial,
        [string]$ComputerName
    )

    $Name = if ([string]::IsNullOrWhiteSpace($Serial)) { "$ComputerName" } else { $Serial }
    $Chars = $Name.ToCharArray()
    $Invalid = [IO.Path]::GetInvalidFileNameChars()
    for ($i = 0; $i -lt $Chars.Length; $i++)
    {
        if ($Invalid -contains $Chars[$i]) { $Chars[$i] = [char]'_' }
    }
    return (New-Object string (, $Chars))
}#endfunction

function Get-AUOutboxPath
{
    <#
.SYNOPSIS
    Returns the outbox folder, C:\Windows\AppUsage_<Serial>_outbox (F50).
.DESCRIPTION
    Next to the ledger, with the same sanitized serial (Get-AUFileNameSerial), so only SYSTEM and
    administrators can create it. Never under C:\ProgramData, where standard users can create files.
.PARAMETER Serial
    The device's serial number.
.PARAMETER ComputerName
    The computer name, used when the serial is blank.
.PARAMETER Root
    The folder that holds it, C:\Windows by default.
#>
    param (
        [string]$Serial,
        [string]$ComputerName,
        [string]$Root = $env:SystemRoot
    )

    return [IO.Path]::Combine($Root, "AppUsage_$(Get-AUFileNameSerial -Serial $Serial -ComputerName $ComputerName)_outbox")
}#endfunction

function ConvertTo-AURowBody
{
    <#
.SYNOPSIS
    Returns the request body for one App Inventory row, exactly as the inventory's upload builds it.
.DESCRIPTION
    The Logs Ingestion API body is "[" + the row as compressed JSON + "]"; the classic API body is
    the row as indented JSON. Both use ConvertTo-Json's default depth and UTF-8 bytes, as version 19
    does. New-AURunRows measures rows with it, and Send-AURunRows sends what it returns, so the
    size measured is the size sent.
.PARAMETER Row
    The row: an ordered dictionary or a PSCustomObject.
.PARAMETER LogAPIMode
    The inventory's $LogAPIMode.
#>
    [OutputType([byte[]])]
    param (
        $Row,
        [string]$LogAPIMode
    )

    $Json = if ($LogAPIMode -eq 'LogIngestionAPI') { "[$($Row | ConvertTo-Json -Compress)]" } else { $Row | ConvertTo-Json }
    return , ([System.Text.Encoding]::UTF8.GetBytes($Json))
}#endfunction

function New-AURunRows
{
    <#
.SYNOPSIS
    Packs one run's App Inventory data into rows: one when it fits, several tied by RunId_g when it doesn't (D44).
.DESCRIPTION
    Every row carries RunId_g, RowIndex_d, and RowCount_d. Row 1 has every column in MainColumns,
    in their order, then the run columns. Later rows have only ComputerName_s, ManagedDeviceID_g,
    and the run columns. Then come the pieces (ConvertTo-AUChunks, 64512 characters, or 31744 for
    the classic API), InstalledApps first, then ExeUsage, as many as fit. A row holds at most 10
    pieces per blob, numbered from 1 on every row (F49), and each row's body (ConvertTo-AURowBody)
    is at most MaxRowBytes. To rebuild a blob, take its pieces from every row ordered by RowIndex_d,
    then by column number. An empty blob has no pieces, so it has no columns, as in version 19;
    a run with no pieces at all is still one row.
    The same input gives byte-identical rows (F54). Returns an object[] of PSCustomObjects, even for
    one row: assign it directly, never wrap the call in @(). Throws when MainColumns isn't ordered,
    lacks the identity columns, or already has a run or piece column, when RunId isn't a GUID, or
    when row 1's columns alone are over MaxRowBytes.
.PARAMETER MainColumns
    Row 1's inventory and device columns: an ordered dictionary or a PSCustomObject (such as the
    inventory's $MainApp without its pieces). A Hashtable is refused, because its order isn't kept.
.PARAMETER InstalledAppsJson
    The InstalledApps JSON.
.PARAMETER ExeUsageJson
    The ExeUsage JSON.
.PARAMETER LogAPIMode
    The inventory's $LogAPIMode.
.PARAMETER MaxRowBytes
    The row-size limit, $script:AUMaxRowBytes by default (F48).
.PARAMETER RunId
    The run's GUID; a new one by default. Pass the run's own, so every row and the rest of the run
    share it.
#>
    [OutputType([object[]])]
    param (
        $MainColumns,
        [string]$InstalledAppsJson,
        [string]$ExeUsageJson,
        [string]$LogAPIMode,
        [int]$MaxRowBytes = $script:AUMaxRowBytes,
        [string]$RunId = ([guid]::NewGuid().ToString())
    )

    $Main = [ordered]@{}
    if ($MainColumns -is [System.Collections.Specialized.OrderedDictionary])
    {
        foreach ($Key in $MainColumns.Keys) { $Main[$Key] = $MainColumns[$Key] }
    }
    elseif ($null -ne $MainColumns -and $MainColumns.PSObject.BaseObject -is [System.Management.Automation.PSCustomObject])
    {
        foreach ($Property in $MainColumns.PSObject.Properties) { $Main[$Property.Name] = $Property.Value }
    }
    else { throw 'MainColumns must be an ordered dictionary or a PSCustomObject, so the rows keep their column order.' }

    $Guid = [guid]::Empty
    if (-not [guid]::TryParse($RunId, [ref]$Guid)) { throw "RunId '$RunId' isn't a GUID." }
    $RunIdText = $Guid.ToString()

    $ComputerColumn = Get-AUColumnName 'ComputerName' 's' $LogAPIMode
    $DeviceColumn = Get-AUColumnName 'ManagedDeviceID' 'g' $LogAPIMode
    $RunIdColumn = Get-AUColumnName 'RunId' 'g' $LogAPIMode
    $IndexColumn = Get-AUColumnName 'RowIndex' 'd' $LogAPIMode
    $CountColumn = Get-AUColumnName 'RowCount' 'd' $LogAPIMode
    foreach ($Key in $Main.Keys)
    {
        if (@($RunIdColumn, $IndexColumn, $CountColumn) -contains $Key -or $Key -match '^(InstalledApps|ExeUsage)\d+(_s)?$') { throw "MainColumns already has the column $Key, which New-AURunRows sets." }
    }
    if (-not $Main.Contains($ComputerColumn) -or -not $Main.Contains($DeviceColumn)) { throw "MainColumns needs $ComputerColumn and $DeviceColumn." }

    $ChunkSize = if ($LogAPIMode -eq 'LogIngestionAPI') { 64512 } else { 31744 }
    $Blobs = [ordered]@{}
    $Blobs['InstalledApps'] = (ConvertTo-AUChunks -Json $InstalledAppsJson -ChunkSize $ChunkSize)
    $Blobs['ExeUsage'] = (ConvertTo-AUChunks -Json $ExeUsageJson -ChunkSize $ChunkSize)

    # RowCount_d is known only at the end, so rows are measured with a placeholder of at least as
    # many digits (9, then 99, ...); setting the real count can't make a row longer.
    $Reserve = 9
    do
    {
        $Rows = New-Object System.Collections.Generic.List[System.Collections.Specialized.OrderedDictionary]
        $Row = [ordered]@{}
        foreach ($Key in $Main.Keys) { $Row[$Key] = $Main[$Key] }
        $Row[$RunIdColumn] = $RunIdText
        $Row[$IndexColumn] = 1
        $Row[$CountColumn] = $Reserve
        $Size = (ConvertTo-AURowBody -Row $Row -LogAPIMode $LogAPIMode).Length
        if ($Size -gt $MaxRowBytes) { throw "Row 1's columns alone are $Size bytes, over the $MaxRowBytes-byte row limit." }
        $Counts = @{}
        foreach ($Blob in $Blobs.Keys)
        {
            foreach ($Piece in $Blobs[$Blob])
            {
                $Number = [int]$Counts[$Blob] + 1
                $Fits = $false
                if ($Number -le $script:AUMaxPiecesPerBlob)
                {
                    $Name = Get-AUColumnName "$Blob$Number" 's' $LogAPIMode
                    $Row[$Name] = $Piece
                    if ((ConvertTo-AURowBody -Row $Row -LogAPIMode $LogAPIMode).Length -le $MaxRowBytes) { $Fits = $true }
                    else { $Row.Remove($Name) }
                }
                if (-not $Fits)
                {
                    $Rows.Add($Row)
                    $Row = [ordered]@{}
                    $Row[$ComputerColumn] = $Main[$ComputerColumn]
                    $Row[$DeviceColumn] = $Main[$DeviceColumn]
                    $Row[$RunIdColumn] = $RunIdText
                    $Row[$IndexColumn] = $Rows.Count + 1
                    $Row[$CountColumn] = $Reserve
                    $Counts = @{}
                    $Number = 1
                    $Name = Get-AUColumnName "$($Blob)1" 's' $LogAPIMode
                    $Row[$Name] = $Piece
                    $Size = (ConvertTo-AURowBody -Row $Row -LogAPIMode $LogAPIMode).Length
                    if ($Size -gt $MaxRowBytes) { throw "A row with one piece is $Size bytes, over the $MaxRowBytes-byte row limit." }
                }
                $Counts[$Blob] = $Number
            }
        }
        $Rows.Add($Row)
        $Done = ($Rows.Count -le $Reserve)
        if (-not $Done) { $Reserve = $Reserve * 10 + 9 }
    } while (-not $Done)

    $Result = New-Object object[] $Rows.Count
    for ($i = 0; $i -lt $Rows.Count; $i++)
    {
        $Rows[$i][$CountColumn] = $Rows.Count
        $Result[$i] = [pscustomobject]$Rows[$i]
    }
    if ($Rows.Count -gt 1) { Write-CMTraceLog -Message "App Usage: the run's App Inventory data is split into $($Rows.Count) rows (RunId $RunIdText)." -Component 'AppUsage' }
    return , $Result
}#endfunction

function Get-AUOutboxState
{
    <#
.SYNOPSIS
    Returns Absent, Trusted, or Untrusted for the outbox folder.
.DESCRIPTION
    Trusted only when Test-AUTrustedFolder passes: a real folder, not a link, owned by SYSTEM or
    Administrators, with the protected DACL. An untrusted outbox is never read, written, or
    deleted from. Fails closed. Never throws.
.PARAMETER OutboxDir
    The outbox folder.
#>
    param (
        [string]$OutboxDir
    )

    if (-not (Test-AUItemPresent -Path $OutboxDir)) { return 'Absent' }
    if (Test-AUTrustedFolder -Path $OutboxDir) { return 'Trusted' }
    return 'Untrusted'
}#endfunction

function Get-AUOutboxFiles
{
    <#
.SYNOPSIS
    Lists the rows waiting in a trusted outbox, oldest run first, then by RowIndex_d (F53).
.DESCRIPTION
    Only regular files named <RunId>-<RowIndex>.json and owned by SYSTEM or Administrators are
    listed; anything else (a link, a folder, a file with another owner or name) is logged and left
    alone, never read, sent, or deleted. The listing reads each entry's own attributes and doesn't
    follow links. A run's time is the write time of its oldest file. Returns an object[] of
    Path, RunId, RowIndex, WriteTime, and Length, even for one file. Throws when the folder can't be
    listed.
.PARAMETER OutboxDir
    The outbox folder, already checked with Get-AUOutboxState.
#>
    [OutputType([object[]])]
    param (
        [string]$OutboxDir
    )

    $Files = New-Object System.Collections.Generic.List[object]
    foreach ($Item in (New-Object IO.DirectoryInfo $OutboxDir).GetFileSystemInfos())
    {
        # Temp files and sent rows that couldn't be deleted (Remove-AUOutboxFile) aren't pending.
        if ($Item.Name.EndsWith('.tmp', [StringComparison]::OrdinalIgnoreCase) -or $Item.Name.EndsWith('.sent', [StringComparison]::OrdinalIgnoreCase)) { continue }
        if (($Item.Attributes -band ([IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::Directory)) -ne 0)
        {
            Write-CMTraceLog -Message "App Usage: $($Item.FullName) in the outbox isn't a regular file, so it's left alone." -Component 'AppUsage' -Type 2
            continue
        }
        $Match = [regex]::Match($Item.Name, $script:AUOutboxFilePattern)
        if (-not $Match.Success)
        {
            Write-CMTraceLog -Message "App Usage: $($Item.FullName) in the outbox isn't a saved row, so it's left alone." -Component 'AppUsage' -Type 2
            continue
        }
        $Trusted = $false
        try { $Trusted = Test-AUTrustedOwner -Security ([IO.File]::GetAccessControl($Item.FullName, [Security.AccessControl.AccessControlSections]::Owner)) }
        catch { $Trusted = $false }
        if (-not $Trusted)
        {
            Write-CMTraceLog -Message "App Usage: $($Item.FullName) in the outbox isn't owned by SYSTEM or Administrators, so it's never sent." -Component 'AppUsage' -Type 2
            continue
        }
        $Files.Add([pscustomobject]@{
                Path      = $Item.FullName
                RunId     = ([guid]$Match.Groups['RunId'].Value).ToString()
                RowIndex  = [int]$Match.Groups['RowIndex'].Value
                WriteTime = $Item.LastWriteTimeUtc
                Length    = $Item.Length
            })
    }

    $RunTimes = @{}
    foreach ($File in $Files)
    {
        if (-not $RunTimes.ContainsKey($File.RunId) -or $File.WriteTime -lt $RunTimes[$File.RunId]) { $RunTimes[$File.RunId] = $File.WriteTime }
    }
    $Sorted = @($Files | Sort-Object -Property @{ Expression = { $RunTimes[$_.RunId] } }, @{ Expression = { $_.RunId } }, @{ Expression = { $_.RowIndex } })
    return , $Sorted
}#endfunction

function Remove-AUOutboxFile
{
    <#
.SYNOPSIS
    Deletes one outbox file. Returns $true when it's gone, or no longer pending. Never throws.
.DESCRIPTION
    A read-only file has the attribute cleared and is deleted again. When a row that was sent still
    can't be deleted (-Sent), it's renamed to <name>.sent, so the listing (Get-AUOutboxFiles) never
    sends it again and Remove-AUStaleOutboxTemp deletes it later; that counts as gone.
.PARAMETER Path
    A file from Get-AUOutboxFiles.
.PARAMETER Sent
    The row was sent, so renaming it is enough when it can't be deleted.
#>
    param (
        [string]$Path,
        [switch]$Sent
    )

    $Message = ''
    try
    {
        Remove-AUFileItem -Path $Path
        return $true
    }
    catch { $Message = $_.Exception.Message }
    try
    {
        $Item = New-Object IO.FileInfo $Path
        if ($Item.Exists -and $Item.IsReadOnly)
        {
            $Item.IsReadOnly = $false
            Remove-AUFileItem -Path $Path
            return $true
        }
    }
    catch { $Message = $_.Exception.Message }
    if (-not $Sent)
    {
        Write-CMTraceLog -Message "App Usage: couldn't delete $Path from the outbox: $Message" -Component 'AppUsage' -Type 3
        return $false
    }
    try
    {
        $Target = "$Path.sent"
        if (Test-AUItemPresent -Path $Target) { $Target = "$Path.$([guid]::NewGuid().ToString('N')).sent" }
        [IO.File]::Move($Path, $Target)
        Write-CMTraceLog -Message "App Usage: couldn't delete the sent row $Path from the outbox ($Message), so it's renamed to $Target and never sent again." -Component 'AppUsage' -Type 2
        return $true
    }
    catch
    {
        Write-CMTraceLog -Message "App Usage: couldn't delete or rename the sent row $Path in the outbox, so the next run sends it again: $Message; $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3
        return $false
    }
}#endfunction

function Remove-AUFileItem
{
    <#
.SYNOPSIS
    Deletes a file ([IO.File]::Delete). A thin wrapper, so tests can make a delete fail.
.PARAMETER Path
    The file.
#>
    param (
        [string]$Path
    )

    [IO.File]::Delete($Path)
}#endfunction

function Limit-AUOutboxRuns
{
    <#
.SYNOPSIS
    Keeps the rows of the MaxRuns most recent runs in the outbox and deletes the rest (D44).
.DESCRIPTION
    Returns the files that are kept, in the same order, as an object[].
.PARAMETER Files
    The outbox files, from Get-AUOutboxFiles (oldest run first).
.PARAMETER MaxRuns
    How many runs to keep.
#>
    [OutputType([object[]])]
    param (
        [object[]]$Files,
        [int]$MaxRuns
    )

    $RunIds = New-Object System.Collections.Generic.List[string]
    foreach ($File in $Files) { if (-not $RunIds.Contains($File.RunId)) { $RunIds.Add($File.RunId) } }
    if ($RunIds.Count -le $MaxRuns) { return , @($Files) }

    $Dropped = $RunIds.GetRange(0, $RunIds.Count - $MaxRuns)
    $Kept = New-Object System.Collections.Generic.List[object]
    foreach ($File in $Files)
    {
        if ($Dropped.Contains($File.RunId)) { [void](Remove-AUOutboxFile -Path $File.Path) }
        else { $Kept.Add($File) }
    }
    Write-CMTraceLog -Message "App Usage: the outbox keeps the rows of the $MaxRuns most recent runs; deleted the rows of $($Dropped.Count) older run(s): $($Dropped -join ', ')." -Component 'AppUsage' -Type 2
    return , $Kept.ToArray()
}#endfunction

function Read-AUOutboxRow
{
    <#
.SYNOPSIS
    Reads a saved row's body, unchanged, after checking it's a row of this run and mode.
.DESCRIPTION
    Returns the bytes, or $null when the file isn't a valid saved row: over MaxRowBytes, not UTF-8
    JSON, not the body shape of LogAPIMode (an array of one row, or the classic API's one object),
    or its run columns don't match its file name. Throws when the file can't be read, or has become
    a link.
.PARAMETER File
    A file from Get-AUOutboxFiles.
.PARAMETER LogAPIMode
    The inventory's $LogAPIMode.
.PARAMETER MaxRowBytes
    The row-size limit.
#>
    param (
        [object]$File,
        [string]$LogAPIMode,
        [int]$MaxRowBytes
    )

    if ($File.Length -gt $MaxRowBytes) { return $null }
    if (Test-AUReparsePoint -Path $File.Path) { throw "$($File.Path) has become a link." }
    $Bytes = [IO.File]::ReadAllBytes($File.Path)
    if ($Bytes.Length -gt $MaxRowBytes) { return $null }
    try
    {
        $Text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($Bytes)
        $Parsed = ConvertFrom-Json -InputObject $Text -ErrorAction Stop
    }
    catch { return $null }

    if ($LogAPIMode -eq 'LogIngestionAPI')
    {
        if (-not $Text.StartsWith('[')) { return $null }
        $Records = @($Parsed)
        if ($Records.Count -ne 1) { return $null }
        $Record = $Records[0]
    }
    else
    {
        if (-not $Text.StartsWith('{')) { return $null }
        $Record = $Parsed
    }
    if ($null -eq $Record -or $Record -isnot [pscustomobject]) { return $null }

    $RunIdValue = $Record.PSObject.Properties[(Get-AUColumnName 'RunId' 'g' $LogAPIMode)]
    $IndexValue = $Record.PSObject.Properties[(Get-AUColumnName 'RowIndex' 'd' $LogAPIMode)]
    if ($null -eq $RunIdValue -or $null -eq $IndexValue) { return $null }
    $Guid = [guid]::Empty
    if (-not [guid]::TryParse("$($RunIdValue.Value)", [ref]$Guid) -or $Guid.ToString() -ne $File.RunId) { return $null }
    if ("$($IndexValue.Value)" -ne "$($File.RowIndex)") { return $null }
    return , $Bytes
}#endfunction

function Save-AUOutboxRow
{
    <#
.SYNOPSIS
    Writes a row's body to the outbox as <RunId>-<RowIndex>.json. Returns $true when it's saved. Never throws.
.DESCRIPTION
    The body is written unchanged to a temp file created with the protected DACL (SYSTEM and
    Administrators, inheritance off) and owned by Administrators, flushed to disk, then swapped in
    (Move-AUFileAtomic), so a power loss never leaves a partial row.
.PARAMETER OutboxDir
    The trusted outbox folder.
.PARAMETER RunId
    The row's RunId_g.
.PARAMETER RowIndex
    The row's RowIndex_d.
.PARAMETER Body
    The body, from ConvertTo-AURowBody.
#>
    param (
        [string]$OutboxDir,
        [string]$RunId,
        [int]$RowIndex,
        [byte[]]$Body
    )

    $Path = [IO.Path]::Combine($OutboxDir, "$RunId-$RowIndex.json")
    $Temp = "$Path.tmp"
    try
    {
        $Security = New-AUProtectedSecurity
        $Security.SetOwner((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'))
        if (Test-AUItemPresent -Path $Temp) { [IO.File]::Delete($Temp) }
        $Stream = New-Object IO.FileStream($Temp, [IO.FileMode]::CreateNew, [Security.AccessControl.FileSystemRights]::Write, [IO.FileShare]::None, 65536, [IO.FileOptions]::None, $Security)
        try
        {
            $Stream.Write($Body, 0, $Body.Length)
            $Stream.Flush($true)
        }
        finally { $Stream.Dispose() }
        Move-AUFileAtomic -Source $Temp -Target $Path
        return $true
    }
    catch
    {
        $Message = $_.Exception.Message
        try { if ([IO.File]::Exists($Temp)) { [IO.File]::Delete($Temp) } } catch { }
        Write-CMTraceLog -Message "App Usage: couldn't save row $RowIndex of run $RunId to the outbox, so it's lost: $Message" -Component 'AppUsage' -Type 3
        return $false
    }
}#endfunction

function Invoke-AUSend
{
    <#
.SYNOPSIS
    Sends one body with the sender. Returns Ok and Permanent. Never throws.
.DESCRIPTION
    The sender's last output is an object with Ok and Permanent (the contract the inventory's sender
    keeps), or a [bool] for Ok alone. Ok is $true only when the row was accepted. Permanent is $true
    only when the data collection rule's ingestion response rejected the row itself (400 or 413,
    Test-AUPermanentStatus), so a resend of the same row can't succeed. Anything else counts as a
    failed send that may work later. A sender that throws, such as the inventory's size guard or a
    failed token request, counts as a failed send that isn't permanent.
.PARAMETER Sender
    The sender scriptblock: param([byte[]]$Body, [string]$LogAPIMode, [string]$LogType,
    [bool]$SingleAttempt).
.PARAMETER Body
    The body.
.PARAMETER LogAPIMode
    The inventory's $LogAPIMode.
.PARAMETER LogType
    The App Inventory log type.
.PARAMETER SingleAttempt
    Ask the sender for one attempt with no backoff (the outbox drain).
#>
    param (
        [scriptblock]$Sender,
        [byte[]]$Body,
        [string]$LogAPIMode,
        [string]$LogType,
        [switch]$SingleAttempt
    )

    $Outcome = [pscustomobject]@{ Ok = $false; Permanent = $false }
    try
    {
        $Output = & $Sender $Body $LogAPIMode $LogType ([bool]$SingleAttempt)
        $Last = @($Output) | Select-Object -Last 1
        if ($Last -is [bool]) { $Outcome.Ok = $Last }
        elseif ($null -ne $Last -and $null -ne $Last.PSObject.Properties['Ok'])
        {
            $Outcome.Ok = ($Last.Ok -eq $true)
            $Outcome.Permanent = (-not $Outcome.Ok -and $null -ne $Last.PSObject.Properties['Permanent'] -and $Last.Permanent -eq $true)
        }
    }
    catch
    {
        Write-CMTraceLog -Message "App Usage: the App Inventory row upload failed: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3
    }
    return $Outcome
}#endfunction

function Test-AUPermanentStatus
{
    <#
.SYNOPSIS
    Tests whether a data collection rule's ingestion response rejected the row itself: 400 (bad request) or 413 (too large).
.DESCRIPTION
    Only those two say the row can never be accepted. 401, 403, and 404 are configuration (an
    expired secret, a missing role, a wrong rule), and 408, 429, and 5xx are transient, so those rows
    are kept. Pass only the status of the ingestion POST, never of the token request.
.PARAMETER StatusCode
    The HTTP status code, or $null when there was no response.
#>
    param (
        $StatusCode
    )

    $Code = $StatusCode -as [int]
    if ($null -eq $Code) { return $false }
    return ($Code -eq 400 -or $Code -eq 413)
}#endfunction

function Remove-AUStaleOutboxTemp
{
    <#
.SYNOPSIS
    Deletes leftover *.tmp files older than MaxAgeHours, and *.sent files of any age, in a trusted outbox. Returns how many were deleted. Never throws.
.DESCRIPTION
    A temp file is left only when a run stopped between creating it and swapping it in
    (Save-AUOutboxRow). A *.sent file is a row that was sent but couldn't be deleted
    (Remove-AUOutboxFile -Sent), so it's never needed again. Only regular files owned by SYSTEM or Administrators are deleted; links,
    folders, and files with another owner are left alone. The listing reads each entry's own
    attributes and doesn't follow links. Call it only for an outbox Get-AUOutboxState trusts.
.PARAMETER OutboxDir
    The trusted outbox folder.
.PARAMETER MaxAgeHours
    How old a temp file must be, $script:AUOutboxTempMaxAgeHours by default.
#>
    param (
        [string]$OutboxDir,
        [double]$MaxAgeHours = $script:AUOutboxTempMaxAgeHours
    )

    $Deleted = 0
    try
    {
        $Cutoff = [datetime]::UtcNow.AddHours(-$MaxAgeHours)
        foreach ($Item in (New-Object IO.DirectoryInfo $OutboxDir).GetFileSystemInfos())
        {
            $IsSent = $Item.Name.EndsWith('.sent', [StringComparison]::OrdinalIgnoreCase)
            if (-not $IsSent -and -not $Item.Name.EndsWith('.tmp', [StringComparison]::OrdinalIgnoreCase)) { continue }
            if (($Item.Attributes -band ([IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::Directory)) -ne 0) { continue }
            if (-not $IsSent -and $Item.LastWriteTimeUtc -ge $Cutoff) { continue }
            $Trusted = $false
            try { $Trusted = Test-AUTrustedOwner -Security ([IO.File]::GetAccessControl($Item.FullName, [Security.AccessControl.AccessControlSections]::Owner)) }
            catch { $Trusted = $false }
            if (-not $Trusted) { continue }
            if (Remove-AUOutboxFile -Path $Item.FullName) { $Deleted++ }
        }
    }
    catch { Write-CMTraceLog -Message "App Usage: couldn't list the outbox $OutboxDir for leftover temp files: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3 }
    if ($Deleted -gt 0) { Write-CMTraceLog -Message "App Usage: deleted $Deleted leftover file(s) (temp files older than $MaxAgeHours hours, and sent rows) from the outbox $OutboxDir." -Component 'AppUsage' -Type 2 }
    return $Deleted
}#endfunction

function Send-AUOutbox
{
    <#
.SYNOPSIS
    Sends the rows waiting in the outbox, oldest run first, each unchanged, and deletes each one once it's sent (F52, F53).
.DESCRIPTION
    Runs before this run's rows are built, so arrival order keeps run order, and row 1's
    AppUsageCollectionStatus_s reflects the flush: PendingRows is $true when rows still wait
    afterward. The outbox first keeps only the MaxRuns most recent runs. A saved row that isn't
    valid (Read-AUOutboxRow) is deleted unsent, and one that can't be read is kept; either way the
    drain stops there for this run, so a newer run's rows are never sent before an older run's.
    Each saved row gets one attempt with no backoff (Invoke-AUSend -SingleAttempt), so the drain
    takes at most one call per saved row. The first failure that may work later stops the drain:
    that row and the rest stay for the next run, and the run's RetryBudget (F51), which this run's
    own rows use (Send-AURunRows), isn't spent. Nothing is sent when RetryBudget is already 0. A row
    the ingestion service rejected itself (Invoke-AUSend's Permanent: a DCR response of 400 or 413)
    is deleted unsent and counted in Discarded, and the drain goes on. A sent row that can't be
    deleted is renamed to *.sent (Remove-AUOutboxFile -Sent), so it's never sent again.
    In a trusted outbox, leftover temp files older than 24 hours, and *.sent files, are deleted first
    (Remove-AUStaleOutboxTemp). An outbox that isn't trusted (Get-AUOutboxState) is never read,
    sent, or deleted from; OutboxSkipped is then $true, as it is when the folder can't be listed.
    A blank OutboxDir (no outbox this run) sends nothing.
    Concurrent runs: Send-AUInventoryRun calls Send-AUOutbox, New-AURunRows, and Send-AURunRows
    under the outbox lock, so two runs never use the outbox at once.
    Returns Sent, Remaining, Discarded, PendingRows, and OutboxSkipped. Throws only when Sender is
    missing.
.PARAMETER OutboxDir
    The outbox folder (Get-AUOutboxPath).
.PARAMETER RetryBudget
    The run's retry budget, a [ref] to an int. The drain reads it and never spends it.
.PARAMETER LogAPIMode
    The inventory's $LogAPIMode.
.PARAMETER LogType
    The App Inventory log type.
.PARAMETER Sender
    Required. The sender scriptblock Task 15 builds from the inventory's upload (see the note above
    Get-AUColumnName). There's no default, so the region never reads the connection settings.
.PARAMETER MaxRowBytes
    The row-size limit.
.PARAMETER MaxRuns
    How many runs the outbox keeps.
#>
    param (
        [string]$OutboxDir,
        [ref]$RetryBudget,
        [string]$LogAPIMode,
        [string]$LogType = $(if ($LogAPIMode -eq 'LogIngestionAPI') { 'PowerStacksAppInventory_CL' } else { 'PowerStacksAppInventory' }),
        [scriptblock]$Sender,
        [int]$MaxRowBytes = $script:AUMaxRowBytes,
        [int]$MaxRuns = $script:AUOutboxMaxRuns
    )

    if ($null -eq $Sender) { throw 'Send-AUOutbox needs -Sender.' }
    $Result = [pscustomobject]@{ Sent = 0; Remaining = 0; Discarded = 0; PendingRows = $false; OutboxSkipped = $false }
    if ([string]::IsNullOrWhiteSpace($OutboxDir)) { return $Result }
    $State = Get-AUOutboxState -OutboxDir $OutboxDir
    if ($State -eq 'Absent') { return $Result }
    if ($State -eq 'Untrusted')
    {
        Write-CMTraceLog -Message "App Usage: the outbox $OutboxDir isn't the protected folder the script creates, so it isn't read, sent, or changed this run." -Component 'AppUsage' -Type 3
        $Result.OutboxSkipped = $true
        return $Result
    }

    [void](Remove-AUStaleOutboxTemp -OutboxDir $OutboxDir)
    try { $Files = Get-AUOutboxFiles -OutboxDir $OutboxDir }
    catch
    {
        Write-CMTraceLog -Message "App Usage: couldn't list the outbox $OutboxDir, so it isn't sent this run: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3
        $Result.OutboxSkipped = $true
        return $Result
    }
    $Files = Limit-AUOutboxRuns -Files $Files -MaxRuns $MaxRuns
    $Remaining = $Files.Count
    foreach ($File in $Files)
    {
        if ($RetryBudget.Value -le 0) { break }
        try { $Body = Read-AUOutboxRow -File $File -LogAPIMode $LogAPIMode -MaxRowBytes $MaxRowBytes }
        catch
        {
            # Run order: the rows after it wait too.
            Write-CMTraceLog -Message "App Usage: couldn't read $($File.Path) from the outbox, so it and the rows after it wait: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3
            break
        }
        if ($null -eq $Body)
        {
            Write-CMTraceLog -Message "App Usage: $($File.Path) in the outbox isn't a valid saved row, so it's deleted unsent, and the rows after it wait for the next run." -Component 'AppUsage' -Type 3
            if (Remove-AUOutboxFile -Path $File.Path) { $Remaining-- }
            break
        }
        $Send = Invoke-AUSend -Sender $Sender -Body $Body -LogAPIMode $LogAPIMode -LogType $LogType -SingleAttempt
        if ($Send.Ok)
        {
            $Result.Sent++
            if (Remove-AUOutboxFile -Path $File.Path -Sent) { $Remaining-- }
        }
        elseif ($Send.Permanent)
        {
            # The service rejected the row itself, so resending can't fix it.
            $Result.Discarded++
            Write-CMTraceLog -Message "App Usage: row $($File.RowIndex) of run $($File.RunId) from the outbox was rejected permanently, so it's deleted unsent." -Component 'AppUsage' -Type 3
            if (Remove-AUOutboxFile -Path $File.Path) { $Remaining-- }
        }
        else
        {
            # One attempt only: the rest wait too, and this run's own rows keep the retry budget.
            Write-CMTraceLog -Message "App Usage: row $($File.RowIndex) of run $($File.RunId) from the outbox wasn't sent, so it and the rows after it wait for the next run." -Component 'AppUsage' -Type 2
            break
        }
    }
    $Result.Remaining = $Remaining
    $Result.PendingRows = ($Remaining -gt 0)
    if ($Result.Sent -gt 0 -or $Remaining -gt 0) { Write-CMTraceLog -Message "App Usage: sent $($Result.Sent) row(s) from the outbox; $Remaining still wait." -Component 'AppUsage' }
    return $Result
}#endfunction

function Send-AURunRows
{
    <#
.SYNOPSIS
    Sends this run's rows, each in its own call, and saves the rows that aren't sent to the outbox (D44, F51).
.DESCRIPTION
    Each row's body is ConvertTo-AURowBody's, the bytes New-AURunRows measured. RetryBudget is the
    one Send-AUOutbox used (F51): a send that still fails after the sender's own retry spends one
    unit, and once it's 0 every remaining row goes straight to the outbox without a send. A row
    over MaxRowBytes is never sent or saved (New-AURunRows never builds one).
    When every row was sent, the outbox rows of older runs are deleted: this newer complete run
    supersedes them (D44). The outbox then keeps only the MaxRuns most recent runs. A missing
    outbox is created with the protected DACL (New-AUProtectedFolder); one that isn't trusted is
    never written or deleted from, and OutboxSkipped is $true. Returns Sent, Pending (rows not
    sent), Saved (rows saved to the outbox), SentBytes, and OutboxSkipped. A blank OutboxDir means
    there's no outbox this run: unsent rows aren't saved, and OutboxSkipped is $true when there are
    any. A permanent rejection (Invoke-AUSend) of this run's row is handled like any failed send: it
    spends the budget and the row is saved, so the next run tries it once more and discards it if
    it's still rejected. Throws only when Sender is missing or a row lacks the run columns (pass
    New-AURunRows' result as it is, not wrapped in @()). Concurrent runs: Send-AUInventoryRun calls
    it under the outbox lock, with Send-AUOutbox, so two runs never use the outbox at once.
.PARAMETER Rows
    The rows, from New-AURunRows.
.PARAMETER OutboxDir
    The outbox folder (Get-AUOutboxPath).
.PARAMETER RetryBudget
    The run's retry budget, a [ref] to an int, shared with Send-AUOutbox.
.PARAMETER LogAPIMode
    The inventory's $LogAPIMode.
.PARAMETER LogType
    The App Inventory log type.
.PARAMETER Sender
    Required. The sender scriptblock Task 15 builds from the inventory's upload (see the note above
    Get-AUColumnName). There's no default, so the region never reads the connection settings.
.PARAMETER MaxRowBytes
    The row-size limit.
.PARAMETER MaxRuns
    How many runs the outbox keeps.
#>
    param (
        [object[]]$Rows,
        [string]$OutboxDir,
        [ref]$RetryBudget,
        [string]$LogAPIMode,
        [string]$LogType = $(if ($LogAPIMode -eq 'LogIngestionAPI') { 'PowerStacksAppInventory_CL' } else { 'PowerStacksAppInventory' }),
        [scriptblock]$Sender,
        [int]$MaxRowBytes = $script:AUMaxRowBytes,
        [int]$MaxRuns = $script:AUOutboxMaxRuns
    )

    if ($null -eq $Sender) { throw 'Send-AURunRows needs -Sender.' }
    $RunIdColumn = Get-AUColumnName 'RunId' 'g' $LogAPIMode
    $IndexColumn = Get-AUColumnName 'RowIndex' 'd' $LogAPIMode
    $Result = [pscustomobject]@{ Sent = 0; Pending = 0; Saved = 0; SentBytes = 0; OutboxSkipped = $false }
    $Unsent = New-Object System.Collections.Generic.List[object]
    $RunId = $null
    foreach ($Row in @($Rows))
    {
        if ($null -eq $Row -or $null -eq $Row.PSObject.Properties[$RunIdColumn] -or $null -eq $Row.PSObject.Properties[$IndexColumn]) { throw "Every row needs $RunIdColumn and $IndexColumn; pass New-AURunRows' result as it is." }
        $RunId = ([guid]"$($Row.$RunIdColumn)").ToString()
        $Index = [int]$Row.$IndexColumn
        $Body = ConvertTo-AURowBody -Row $Row -LogAPIMode $LogAPIMode
        if ($Body.Length -gt $MaxRowBytes)
        {
            Write-CMTraceLog -Message "App Usage: row $Index of run $RunId is $($Body.Length) bytes, over the $MaxRowBytes-byte limit, so it's never sent." -Component 'AppUsage' -Type 3
            $Result.Pending++
            continue
        }
        if ($RetryBudget.Value -gt 0)
        {
            if ((Invoke-AUSend -Sender $Sender -Body $Body -LogAPIMode $LogAPIMode -LogType $LogType).Ok)
            {
                $Result.Sent++
                $Result.SentBytes += $Body.Length
                continue
            }
            $RetryBudget.Value--
            Write-CMTraceLog -Message "App Usage: row $Index of run $RunId wasn't sent, so it goes to the outbox." -Component 'AppUsage' -Type 2
        }
        $Unsent.Add([pscustomobject]@{ Index = $Index; Body = $Body })
        $Result.Pending++
    }
    if ($null -eq $RunId) { return $Result }
    if ([string]::IsNullOrWhiteSpace($OutboxDir))
    {
        if ($Result.Pending -gt 0)
        {
            $Result.OutboxSkipped = $true
            Write-CMTraceLog -Message "App Usage: there's no outbox this run, so $($Result.Pending) unsent row(s) of run $RunId aren't saved." -Component 'AppUsage' -Type 3
        }
        return $Result
    }

    $State = Get-AUOutboxState -OutboxDir $OutboxDir
    if ($Result.Pending -eq 0)
    {
        if ($State -ne 'Trusted') { return $Result }
        try
        {
            $Superseded = 0
            foreach ($File in (Get-AUOutboxFiles -OutboxDir $OutboxDir))
            {
                if ($File.RunId -ne $RunId -and (Remove-AUOutboxFile -Path $File.Path)) { $Superseded++ }
            }
            if ($Superseded -gt 0) { Write-CMTraceLog -Message "App Usage: every row of run $RunId was sent, so $Superseded outbox row(s) of older runs were deleted." -Component 'AppUsage' }
        }
        catch { Write-CMTraceLog -Message "App Usage: couldn't list the outbox $OutboxDir to delete older runs: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3 }
        return $Result
    }
    if ($Unsent.Count -eq 0) { return $Result }

    if ($State -eq 'Absent')
    {
        try
        {
            New-AUProtectedFolder -Path $OutboxDir
            $State = 'Trusted'
        }
        catch
        {
            Write-CMTraceLog -Message "App Usage: couldn't create the outbox $OutboxDir, so $($Unsent.Count) unsent row(s) are lost: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3
            $Result.OutboxSkipped = $true
            return $Result
        }
    }
    if ($State -ne 'Trusted')
    {
        Write-CMTraceLog -Message "App Usage: the outbox $OutboxDir isn't the protected folder the script creates, so $($Unsent.Count) unsent row(s) aren't saved." -Component 'AppUsage' -Type 3
        $Result.OutboxSkipped = $true
        return $Result
    }
    foreach ($Item in $Unsent)
    {
        if (Save-AUOutboxRow -OutboxDir $OutboxDir -RunId $RunId -RowIndex $Item.Index -Body $Item.Body) { $Result.Saved++ }
    }
    Write-CMTraceLog -Message "App Usage: saved $($Result.Saved) of $($Unsent.Count) unsent row(s) of run $RunId to the outbox." -Component 'AppUsage' -Type 2
    try { [void](Limit-AUOutboxRuns -Files (Get-AUOutboxFiles -OutboxDir $OutboxDir) -MaxRuns $MaxRuns) }
    catch { Write-CMTraceLog -Message "App Usage: couldn't list the outbox $OutboxDir to keep it to $MaxRuns runs: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3 }
    return $Result
}#endfunction

# Orchestration (Task 15). Invoke-AppUsage runs every App Usage step in order, under the run lock, and
# never throws. It's the only App Usage function that reads the script settings (F3).

# Our mapping rules, Base64 of GZip-compressed JSON. The build fills this in (Task 18, F43); keep the
# three lines together and the markers exactly as they are.
# BEGIN APPUSAGE MAPPINGS
$script:AppUsageMappingsEmbedded = ''
# END APPUSAGE MAPPINGS

# The status tokens (F42). AppUsageCollectionStatus_s is OK, or these tokens joined by '; '. In a
# token, <count> is a whole number from 1 and <mode> a PowerShell language mode name. Every status App
# Usage reports is on this list, and Format-AUStatus refuses anything else. John sends it to Julien.
$script:AUStatusTokens = @(
    'OK'                                # Nothing to report.
    'UnsupportedOS'                     # Below Windows 11 25H2 (build 26200): App Usage skipped (D42).
    'LanguageMode:<mode>'               # Not Full Language; always followed by skipped (D37).
    'skipped'                           # Follows LanguageMode: App Usage didn't run.
    'MappingsUnavailable:Missing'       # Our rules aren't in the script: App Usage skipped.
    'MappingsUnavailable:Invalid'       # Our rules didn't load or validate: App Usage skipped.
    'AppUsageBusy'                      # Another run held the lock for 60 seconds: App Usage skipped (D23).
    'AppUsageFailed'                    # An unexpected error (see the log): usage fields blank.
    'AppUsageFailed:Serial'             # The serial number couldn't be read, so the ledger can't be named: App Usage skipped.
    'AppUsageFailed:OsBuild'            # The Windows build number couldn't be read: App Usage skipped.
    'ShadowCopyFailed'                  # No shadow copy of the system drive: App Usage skipped.
    'LowDiskSpace'                      # Too little free space for the snapshot copies: App Usage skipped.
    'SrumReadFailed:WorkDirUntrusted'   # C:\Windows\PowerStacksAppUsage isn't safe to use: App Usage skipped.
    'SrumReadFailed:CopyFailed'         # SRUDB.dat didn't copy from the shadow copy.
    'SrumReadFailed:EsentMissing'       # The ManagedEsent assembly isn't there.
    'SrumReadFailed:NoDatabase'         # No SRUM copy to read.
    'SrumReadFailed:LiveDatabase'       # The live SRUM database was refused.
    'SrumReadFailed:HeaderFailed'       # esentutl /mh gave no database signature.
    'SrumReadFailed:RepairFailed'       # Recovery and repair left the copy unclean.
    'SrumReadFailed:OpenFailed'         # The copy wouldn't open.
    'SrumReadFailed:IdMapFailed'        # The id map couldn't be read.
    'SrumReadFailed:NoTimeline'         # The AppTimelineProvider table isn't there.
    'SrumReadFailed:TimelineFailed'     # The AppTimelineProvider read stopped.
    'SrumReadFailed:ReadFailed'         # Any other SRUM read failure.
    'SrumReadFailed:NoRows'             # The read worked but held no usage rows.
    'LedgerReset'                       # The ledger was unreadable: moved aside and rebuilt.
    'LedgerWriteFailed'                 # The ledger couldn't be written; the file is unchanged.
    'DiscoveryFailed'                   # The all-profile app read failed: the inventory used its own read (D36).
    'ProfileUnread:<count>'             # Profiles whose apps weren't read.
    'HiveUnloadFailed:<count>'          # Hive copies left loaded at HKU\AU_<SID>.
    'MsiFileMapFailed'                  # Windows Installer UserData couldn't be read.
    'InvalidCustomerMappings'           # The customer file isn't valid: ignored this run (D45).
    'InvalidCustomerMappings:TooLarge'  # The customer file is over 1 MB: ignored this run (D45).
    'InvalidCustomerMappings:UnsafePath'    # The customer file path was refused: ignored this run.
    'InvalidCustomerMappings:ReparsePoint'  # The customer file is a link: ignored this run.
    'PendingRows'                       # Rows from an earlier run still wait in the outbox (D44).
    'OutboxSkipped'                     # The outbox couldn't be used this run: rows that weren't sent may be lost.
)
# No customer file isn't a problem, so it has no token: CustomerMappingsHash_s is blank then.
# Below this build App Usage doesn't run (D42).
$script:AUMinOsBuild = 26200
# How long Invoke-AppUsage waits for the run lock.
$script:AULockTimeoutSeconds = 60

function Test-AUStatusToken
{
    <#
.SYNOPSIS
    Tests whether a status token is on $script:AUStatusTokens, case-sensitively.
.PARAMETER Token
    The token, such as SrumReadFailed:EsentMissing or ProfileUnread:2.
#>
    param (
        [string]$Token
    )

    foreach ($Entry in $script:AUStatusTokens)
    {
        $Pattern = '^' + [regex]::Escape($Entry).Replace('<count>', '[1-9][0-9]{0,8}').Replace('<mode>', '[A-Za-z]+') + '$'
        if ($Token -cmatch $Pattern) { return $true }
    }
    return $false
}#endfunction

function Format-AUStatus
{
    <#
.SYNOPSIS
    Returns AppUsageCollectionStatus_s: the tokens joined by '; ', or OK when there are none (F42).
.DESCRIPTION
    Blank tokens and OK are left out, and a repeated token appears once, in first-seen order. Throws
    when a token isn't on $script:AUStatusTokens (Test-AUStatusToken).
.PARAMETER Tokens
    The status tokens.
#>
    param (
        [string[]]$Tokens
    )

    $Kept = New-Object 'System.Collections.Generic.List[string]'
    foreach ($Token in @($Tokens))
    {
        if ([string]::IsNullOrWhiteSpace($Token)) { continue }
        $Text = $Token.Trim()
        if (-not (Test-AUStatusToken $Text)) { throw "Format-AUStatus: '$Text' isn't on the App Usage status token list." }
        if ($Text -ceq 'OK' -or $Kept.Contains($Text)) { continue }
        $Kept.Add($Text)
    }
    if ($Kept.Count -eq 0) { return 'OK' }
    return ($Kept.ToArray() -join '; ')
}#endfunction

function Add-AUStatusToken
{
    <#
.SYNOPSIS
    Adds a status token to the run's list; a token that isn't on the list is logged and added as AppUsageFailed.
.PARAMETER Tokens
    The run's token list.
.PARAMETER Token
    The token.
#>
    param (
        [System.Collections.Generic.List[string]]$Tokens,
        [string]$Token
    )

    if ([string]::IsNullOrWhiteSpace($Token)) { return }
    $Text = $Token.Trim()
    if (-not (Test-AUStatusToken $Text))
    {
        Write-CMTraceLog -Message "App Usage: '$Text' isn't a status token, so AppUsageFailed is reported instead." -Component 'AppUsage' -Type 3
        $Text = 'AppUsageFailed'
    }
    if (-not $Tokens.Contains($Text)) { $Tokens.Add($Text) }
}#endfunction

function Get-AUOsBuild
{
    <#
.SYNOPSIS
    Returns the Windows build number (CurrentBuildNumber), or 0 when it can't be read (F40). Never throws.
#>
    $Key = $null
    try
    {
        $Key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion')
        if ($null -eq $Key) { return 0 }
        $Build = 0
        if ([int]::TryParse([string]$Key.GetValue('CurrentBuildNumber'), [ref]$Build)) { return $Build }
    }
    catch { Write-CMTraceLog -Message "App Usage: couldn't read the Windows build number: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 2 }
    finally { if ($null -ne $Key) { $Key.Close() } }
    return 0
}#endfunction

function Get-AULanguageMode
{
    <#
.SYNOPSIS
    Returns the session's language mode, such as FullLanguage or ConstrainedLanguage (F40).
#>
    return [string]$ExecutionContext.SessionState.LanguageMode
}#endfunction

function Get-AUSerial
{
    <#
.SYNOPSIS
    Returns the device's BIOS serial number (Win32_BIOS), trimmed: '' when the BIOS has none, so the
    computer name names the ledger (F44), and $null when it can't be read (AppUsageFailed:Serial).
    Never throws.
#>
    try
    {
        $Bios = @(Get-CimInstance -ClassName Win32_BIOS -OperationTimeoutSec $script:AUCimTimeoutSeconds -ErrorAction Stop)
        if ($Bios.Count -gt 0) { return ([string]$Bios[0].SerialNumber).Trim() }
        Write-CMTraceLog -Message 'App Usage: Win32_BIOS returned nothing, so the serial number is unknown.' -Component 'AppUsage' -Type 3
    }
    catch { Write-CMTraceLog -Message "App Usage: couldn't read the serial number: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3 }
    return $null
}#endfunction

function Get-AULedgerPath
{
    <#
.SYNOPSIS
    Returns the ledger path, C:\Windows\AppUsage_<Serial>.json (F44).
.DESCRIPTION
    The serial is sanitized by Get-AUFileNameSerial, as the outbox's is (Get-AUOutboxPath): a
    character that isn't allowed in a file name becomes _, and a blank serial falls back to the
    computer name.
.PARAMETER Serial
    The device's serial number.
.PARAMETER ComputerName
    The computer name, used when the serial is blank.
.PARAMETER Root
    The folder that holds it, C:\Windows by default.
#>
    param (
        [string]$Serial,
        [string]$ComputerName,
        [string]$Root = $env:SystemRoot
    )

    return [IO.Path]::Combine($Root, "AppUsage_$(Get-AUFileNameSerial -Serial $Serial -ComputerName $ComputerName).json")
}#endfunction

function Add-AUDeletedScopes
{
    <#
.SYNOPSIS
    Marks each SID that's no longer in ProfileList Deleted in ScopeRead, and returns how many (F29).
.DESCRIPTION
    A SID already in ScopeRead keeps its state. With no users (ProfileList couldn't be read),
    nothing is marked, because a profile can't be known to be gone.
.PARAMETER ScopeRead
    The discovery's ScopeRead.
.PARAMETER Users
    The Get-AUUsers entries (every profile in ProfileList).
.PARAMETER Sids
    The SIDs to check: the ledger's users.
#>
    param (
        [hashtable]$ScopeRead,
        [object[]]$Users,
        [string[]]$Sids
    )

    $Profiles = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($User in @($Users)) { if ($null -ne $User -and $User.Sid) { [void]$Profiles.Add(([string]$User.Sid).Trim()) } }
    if ($Profiles.Count -eq 0) { return 0 }
    $Count = 0
    foreach ($Sid in @($Sids))
    {
        $Value = ([string]$Sid).Trim()
        if (-not $Value -or $Profiles.Contains($Value)) { continue }
        $Known = $false
        foreach ($Name in $ScopeRead.Keys) { if ([string]::Equals([string]$Name, $Value, [StringComparison]::OrdinalIgnoreCase)) { $Known = $true; break } }
        if ($Known) { continue }
        $ScopeRead[$Value] = 'Deleted'
        $Count++
    }
    return $Count
}#endfunction

function Get-AUEntryFacts
{
    <#
.SYNOPSIS
    Returns the facts to use for a ledger entry this run (D24, D30, F13).
.DESCRIPTION
    Verified facts already in the ledger are kept, because a build's facts don't change (D24); only
    IsServiceBinary is refreshed from this run's service map, and the file isn't read again. Otherwise,
    when this run's SRUM read gives the entry's user and exe name candidate kernel paths, the path
    (Find-AUExePath) is read with Get-AUExeFacts. Without a path, the stored facts are kept, and an
    entry with none gets the facts its ExeInfo alone gives (its exe name, or a package's family), so
    an entry missing from this run's SRUM read is still recalculated (D13). Unverified facts never
    replace stored verified ones.
.PARAMETER Entry
    The ledger entry.
.PARAMETER ExeInfo
    The ConvertFrom-AUExeInfo result for the entry. When it isn't given, the entry's ExeInfo is
    parsed here, only if the stored facts aren't verified (they don't need it).
.PARAMETER Context
    The run context: ResourcePaths, VolumeCache, ReadBudget, MsiFileMap, and ServiceBinaries.
#>
    param (
        [pscustomobject]$Entry,
        [pscustomobject]$ExeInfo,
        [pscustomobject]$Context
    )

    $Stored = $Entry.Facts
    if ($null -ne $Stored -and $Stored.FactsVerified -eq $true)
    {
        $RunPath = ([string]$Stored.RunPath).Trim()
        if ($RunPath -and $null -ne $Stored.PSObject.Properties['IsServiceBinary'] -and $null -ne $Context.ServiceBinaries)
        {
            $Stored.IsServiceBinary = $Context.ServiceBinaries.ContainsKey($RunPath.ToLowerInvariant())
        }
        return $Stored
    }

    if ($null -eq $ExeInfo) { $ExeInfo = ConvertFrom-AUExeInfo ([string]$Entry.ExeInfo) }
    $Found = $null
    if ($ExeInfo.Kind -eq 'Win32')
    {
        $Paths = $Context.ResourcePaths["$(([string]$Entry.UserSid).Trim())|$($ExeInfo.ExeName)"]
        if ($null -ne $Paths) { $Found = Find-AUExePath -KernelPaths $Paths.ToArray() -ExeInfo $ExeInfo -VolumeCache $Context.VolumeCache -ReadBudget $Context.ReadBudget }
    }
    if ($null -eq $Found -and $null -ne $Stored) { return $Stored }
    $Path = $null
    if ($null -ne $Found) { $Path = [string]$Found.Path }
    return Get-AUExeFacts -Path $Path -ExeInfo $ExeInfo -MsiFileMap $Context.MsiFileMap -ServiceBinaries $Context.ServiceBinaries -UserSid ([string]$Entry.UserSid) -ExeInfoText ([string]$Entry.ExeInfo) -ReadBudget $Context.ReadBudget
}#endfunction

function Set-AUEntryResult
{
    <#
.SYNOPSIS
    Recalculates one ledger entry for this run and attaches the results (D13, F16, F17).
.DESCRIPTION
    In order: the facts (Get-AUEntryFacts), Resolve-AUIdentity, Resolve-AUTarget, then
    Get-AUClassification, with MatchSection Customer when the target is a customer match or a
    retained customer target (so PowerStacks rules don't apply to it, D38), then Get-AURole (F17).
    The entry's StoredTarget is replaced only when ConvertTo-AUStoredTarget gives a value (F16); a
    stored target that no longer counts (its rule is gone, Get-AUStoredTargetSection) is cleared.
    Attaches Target, Classification, Role, UserType (from the entry's own SID, so a deleted user
    keeps credited use), and InstallStatus (Get-AUInstallStatus for the entry's user), and sets Facts
    and FactsVerified.
.PARAMETER Entry
    The ledger entry.
.PARAMETER Context
    The run context: Mappings, CustomerRulesUnavailable, Apps, AppIndex (New-AUAppIndex of Apps,
    built once per run; built here when it's missing), ScopeRead, UserTypes, MachineDomainSid, and
    what Get-AUEntryFacts needs.
#>
    param (
        [pscustomobject]$Entry,
        [pscustomobject]$Context
    )

    # Get-AUEntryFacts parses the ExeInfo only when it needs it: verified facts don't.
    $Facts = Get-AUEntryFacts -Entry $Entry -Context $Context
    $Entry.Facts = $Facts
    $Entry.FactsVerified = ($null -ne $Facts -and $Facts.FactsVerified -eq $true)

    $Mappings = $Context.Mappings
    $Unavailable = [bool]$Context.CustomerRulesUnavailable
    $AppIndex = $Context.AppIndex
    if ($null -eq $AppIndex) { $AppIndex = New-AUAppIndex $Context.Apps }
    $Identity = Resolve-AUIdentity -Facts $Facts -Mappings $Mappings -InstalledApps $Context.Apps -AppIndex $AppIndex
    $Target = Resolve-AUTarget -Identity $Identity -StoredTarget $Entry.StoredTarget -Mappings $Mappings -CustomerRulesUnavailable:$Unavailable
    $Stored = ConvertTo-AUStoredTarget $Target
    if ($null -ne $Stored) { $Entry.StoredTarget = $Stored }
    elseif ($null -ne $Entry.StoredTarget -and $null -eq (Get-AUStoredTargetSection $Entry.StoredTarget $Mappings $Unavailable))
    {
        Write-CMTraceLog -Message "App Usage: cleared the stored target $($Entry.StoredTarget.MatchRuleId) of $($Entry.ExeName): its rule no longer exists." -Component 'AppUsage'
        $Entry.StoredTarget = $null
    }

    $Section = [string]$Target.MatchSection
    if ($Target.MatchSection -ceq 'Customer' -or $Target.RetainedFrom -ceq 'Customer') { $Section = 'Customer' }
    $Classification = Get-AUClassification -Facts $Facts -Mappings $Mappings -MatchSection $Section
    $Role = Get-AURole -Facts $Facts -Target $Target -Classification $Classification -InstalledApps $Context.Apps -AppIndex $AppIndex

    $Sid = ([string]$Entry.UserSid).Trim()
    $UserType = $Context.UserTypes[$Sid]
    if ($null -eq $UserType)
    {
        $UserType = Get-AUUserType -Sid $Sid -MachineDomainSid $Context.MachineDomainSid
        $Context.UserTypes[$Sid] = $UserType
    }
    $InstallStatus = Get-AUInstallStatus -Target $Target -InstalledApps $Context.Apps -ScopeRead $Context.ScopeRead -UserSid $Sid -AppIndex $AppIndex
    # As Add-Member -Force -NotePropertyMembers, without the cmdlet: this runs once per entry.
    $Results = [ordered]@{
        Target         = $Target
        Classification = $Classification
        Role           = $Role
        UserType       = [string]$UserType
        InstallStatus  = $InstallStatus
    }
    foreach ($Name in $Results.Keys)
    {
        if ($null -ne $Entry.PSObject.Properties[$Name]) { $Entry.PSObject.Properties.Remove($Name) }
        $Entry.PSObject.Properties.Add([Management.Automation.PSNoteProperty]::new($Name, $Results[$Name]))
    }
}#endfunction

function Invoke-AUCollection
{
    <#
.SYNOPSIS
    The App Usage work done under the run lock: snapshot, discovery, ledger, SRUM, matching,
    aggregation, and the ledger write (D23, Task 11).
.DESCRIPTION
    In order (F10, F16, F17, F29, F35, F36):
    1. New-AUWorkDir and New-AUSnapshot. An untrusted work root (New-AUWorkDir throws
       SrumReadFailed:WorkDirUntrusted), ShadowCopyFailed, or LowDiskSpace skips the rest of the run.
    2. Get-AUUsers and Get-AUInstalledApps -IncludeStore. A Machine scope that isn't Read, or a
       signed-in user who isn't, is DiscoveryFailed: InventoryApps and AppFields stay $null, and the
       inventory uses its own read (D20, D36). Unread profiles, hive copies left loaded, and an
       unread Windows Installer map are reported.
    3. Read-AULedger.
    4. Read-AUSrum. With IncludeStore off, Package-kind rows are dropped (D46, F35), and the merge
       gets the whole read's lowest AutoIncId, so the drop doesn't change what ages out.
       Merge-AUSrumRecords runs only when the read is OK with rows (F10), with UserTypes from the
       rows' own SIDs (case-insensitive), and with -NoArchive when the copy was repaired or the read
       is incomplete.
    5. Ledger SIDs missing from ProfileList become Deleted in ScopeRead (F29), after the merge so a
       deleted user's new rows count too.
    6. Every ledger entry is recalculated (Set-AUEntryResult; Package-kind entries only with
       IncludeStore), with one read budget and one service map for the run (F36).
    7. Invoke-AULedgerFold, then Get-AUKnownExes, Get-AUAppUsage, ConvertTo-AUExeUsage, and
       Get-AUUnmatchedExeCount over the folded ledger, so the output matches what's stored.
    8. The results go into Run.Result, then Write-AULedger; a failed write is LedgerWriteFailed.
    The read budget is closed and Remove-AUSnapshot runs in finally. Each stage's time is logged
    and kept in Run.Timings. Throws on an unexpected error (Invoke-AUWithLock catches it).
.PARAMETER Run
    The run built by Invoke-AppUsage.
#>
    param (
        [pscustomobject]$Run
    )

    $Tokens = $Run.Tokens
    $WorkDir = $null
    $Snapshot = $null
    $ReadBudget = $null
    $Clock = [Diagnostics.Stopwatch]::StartNew()
    $EndStage = {
        param ([string]$Name)
        $Run.Timings[$Name] = [long]$Clock.ElapsedMilliseconds
        Write-CMTraceLog -Message "App Usage: stage $Name took $($Clock.ElapsedMilliseconds) ms." -Component 'AppUsage'
        $Clock.Reset()
        $Clock.Start()
    }

    try
    {
        # 1. The protected work folder and the snapshot.
        try { $WorkDir = New-AUWorkDir -RunId $Run.RunId }
        catch
        {
            $Message = [string]$_.Exception.Message
            if (-not $Message.StartsWith($script:AUWorkDirUntrustedStatus, [StringComparison]::Ordinal)) { throw }
            Add-AUStatusToken $Tokens $script:AUWorkDirUntrustedStatus
            Write-CMTraceLog -Message "App Usage: skipped this run. $Message An administrator must delete $($script:AUWorkRoot) so the next run can recreate it." -Component 'AppUsage' -Type 3
            return
        }
        $Snapshot = New-AUSnapshot -WorkDir $WorkDir
        & $EndStage 'Snapshot'
        if ([string]$Snapshot.Status -eq 'ShadowCopyFailed')
        {
            Add-AUStatusToken $Tokens 'ShadowCopyFailed'
            Write-CMTraceLog -Message 'App Usage: skipped this run, because no shadow copy could be taken.' -Component 'AppUsage' -Type 3
            return
        }
        if ([string]$Snapshot.Status -eq 'LowDiskSpace')
        {
            Add-AUStatusToken $Tokens 'LowDiskSpace'
            return
        }

        # 2. Users and installed apps, every profile.
        $Users = @(Get-AUUsers -Snapshot $Snapshot | Where-Object { $null -ne $_ })
        $Discovery = Get-AUInstalledApps -Users $Users -Snapshot $Snapshot -IncludeStore:([bool]$Run.IncludeStore)
        $Apps = @($Discovery.Apps | Where-Object { $null -ne $_ })
        $ScopeRead = $Discovery.ScopeRead
        if ($null -eq $ScopeRead) { $ScopeRead = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase) }
        $DiscoveryOk = ([string]$ScopeRead['Machine'] -eq 'Read')
        foreach ($User in $Users)
        {
            if ([string]$User.ProfileState -eq 'Loaded' -and [string]$ScopeRead[[string]$User.Sid] -ne 'Read') { $DiscoveryOk = $false }
        }
        if (-not $DiscoveryOk)
        {
            Add-AUStatusToken $Tokens 'DiscoveryFailed'
            Write-CMTraceLog -Message 'App Usage: the all-profile app read is incomplete, so the inventory uses its own read this run (D36).' -Component 'AppUsage' -Type 2
        }
        $Unread = [int]$Discovery.ProfilesFound - [int]$Discovery.ProfilesRead
        if ($Unread -gt 0) { Add-AUStatusToken $Tokens "ProfileUnread:$Unread" }
        if ([int]$Discovery.HiveUnloadFailures -gt 0) { Add-AUStatusToken $Tokens "HiveUnloadFailed:$([int]$Discovery.HiveUnloadFailures)" }
        if ($Discovery.MsiFileMapRead -ne $true) { Add-AUStatusToken $Tokens 'MsiFileMapFailed' }
        $MsiFileMap = $Discovery.MsiFileMap
        if ($null -eq $MsiFileMap) { $MsiFileMap = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase) }
        & $EndStage 'Discovery'

        # 3. The ledger.
        $Ledger = Read-AULedger -Path $Run.LedgerPath
        foreach ($Token in @($Ledger.Status)) { Add-AUStatusToken $Tokens ([string]$Token) }
        & $EndStage 'LedgerRead'

        # 4. SRUM, merged only after a successful read with rows (F10).
        $Srum = $null
        $SrumOk = $false
        if ([string]$Snapshot.Status -ne 'OK') { Add-AUStatusToken $Tokens ([string]$Snapshot.Status) }
        else
        {
            $Srum = Read-AUSrum -DbPath $Snapshot.SrumDbPath
            if ([string]$Srum.Status -ne 'OK') { Add-AUStatusToken $Tokens ([string]$Srum.Status) }
            elseif (@($Srum.Timeline).Count -eq 0)
            {
                Add-AUStatusToken $Tokens 'SrumReadFailed:NoRows'
                Write-CMTraceLog -Message 'App Usage: the SRUM read gave no usage rows, so the ledger is not merged this run.' -Component 'AppUsage' -Type 2
            }
            else { $SrumOk = $true }
        }
        & $EndStage 'SrumRead'

        $UserTypes = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
        if ($SrumOk)
        {
            $Rows = New-Object 'System.Collections.Generic.List[object]'
            $Kinds = New-Object Collections.Hashtable ([StringComparer]::Ordinal)
            $Lowest = $null
            $Dropped = 0
            foreach ($Row in @($Srum.Timeline))
            {
                if ($null -eq $Row) { continue }
                # A blank AutoIncId isn't an ID ('' -as [long] would be 0).
                $IdText = ([string]$Row.AutoIncId).Trim()
                $Number = $null
                if ($IdText) { $Number = $IdText -as [long] }
                if ($null -ne $Number -and ($null -eq $Lowest -or $Number -lt $Lowest)) { $Lowest = $Number }
                if (-not $Run.IncludeStore)
                {
                    $Text = [string]$Row.ExeInfo
                    $Kind = $Kinds[$Text]
                    if ($null -eq $Kind) { $Kind = (ConvertFrom-AUExeInfo $Text).Kind; $Kinds[$Text] = $Kind }
                    if ($Kind -eq 'Package') { $Dropped++; continue }
                }
                $Rows.Add($Row)
                $Sid = ([string]$Row.UserSid).Trim()
                if (-not $UserTypes.ContainsKey($Sid)) { $UserTypes[$Sid] = Get-AUUserType -Sid $Sid -MachineDomainSid $Snapshot.MachineDomainSid }
            }
            if ($Dropped -gt 0) { Write-CMTraceLog -Message "App Usage: left out $Dropped Store and MSIX usage rows, because Store inventory is off (D46)." -Component 'AppUsage' }
            $NoArchive = ($Srum.Repaired -eq $true -or $Srum.Complete -ne $true)
            if ($NoArchive) { Write-CMTraceLog -Message "App Usage: nothing is archived this run (repaired $($Srum.Repaired), complete $($Srum.Complete))." -Component 'AppUsage' }
            Merge-AUSrumRecords -Ledger $Ledger -Rows $Rows.ToArray() -Epoch ([string]$Srum.Epoch) -UserTypes $UserTypes -MinFocusSeconds $Run.MinFocusSeconds -NoArchive:$NoArchive -LowestAutoIncId $Lowest
        }
        & $EndStage 'Merge'

        # 5. Users whose profile is gone (F29).
        $Sids = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($Entry in $Ledger.Entries.Values) { if ($Entry.UserSid) { [void]$Sids.Add([string]$Entry.UserSid) } }
        $Deleted = Add-AUDeletedScopes -ScopeRead $ScopeRead -Users $Users -Sids ([string[]]@($Sids))
        if ($Deleted -gt 0) { Write-CMTraceLog -Message "App Usage: $Deleted ledger users are no longer in ProfileList (Deleted)." -Component 'AppUsage' }

        # 6. Every entry, recalculated (D13).
        $ResourcePaths = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
        if ($SrumOk)
        {
            foreach ($Item in @($Srum.Resource))
            {
                if ($null -eq $Item -or [string]::IsNullOrWhiteSpace([string]$Item.KernelPath)) { continue }
                $Key = "$(([string]$Item.UserSid).Trim())|$(([string]$Item.ExeName).Trim().ToLowerInvariant())"
                if (-not $ResourcePaths.ContainsKey($Key)) { $ResourcePaths[$Key] = New-Object 'System.Collections.Generic.List[string]' }
                $ResourcePaths[$Key].Add([string]$Item.KernelPath)
            }
        }
        $ReadBudget = New-AUReadBudget
        $Context = [pscustomobject]@{
            Mappings                 = $Run.Mappings
            CustomerRulesUnavailable = [bool]$Run.CustomerRulesUnavailable
            Apps                     = $Apps
            AppIndex                 = (New-AUAppIndex $Apps)
            ScopeRead                = $ScopeRead
            MsiFileMap               = $MsiFileMap
            ServiceBinaries          = (Get-AUServiceBinaries)
            ResourcePaths            = $ResourcePaths
            VolumeCache              = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
            ReadBudget               = $ReadBudget
            UserTypes                = $UserTypes
            MachineDomainSid         = [string]$Snapshot.MachineDomainSid
        }
        $Keys = [string[]]@($Ledger.Entries.Keys)
        [Array]::Sort($Keys, [StringComparer]::Ordinal)
        $Entries = New-Object 'System.Collections.Generic.List[object]'
        foreach ($Key in $Keys)
        {
            $Entry = $Ledger.Entries[$Key]
            if (-not $Run.IncludeStore -and (ConvertFrom-AUExeInfo ([string]$Entry.ExeInfo)).Kind -eq 'Package') { continue }
            Set-AUEntryResult -Entry $Entry -Context $Context
            $Entries.Add($Entry)
        }
        Write-CMTraceLog -Message "App Usage: recalculated $($Entries.Count) of $($Keys.Count) ledger entries; $($ReadBudget.Reads) timed file reads, $($ReadBudget.TimedOut) timed out, $($ReadBudget.Skipped) skipped, $($ReadBudget.UntrustedOwner) with an untrusted owner." -Component 'AppUsage'
        & $EndStage 'Facts'

        # 7. Fold aged-out builds, then the output, from the folded ledger.
        Invoke-AULedgerFold -Ledger $Ledger
        $Kept = New-Object 'System.Collections.Generic.List[object]'
        foreach ($Entry in $Entries)
        {
            if ([object]::ReferenceEquals($Ledger.Entries["$($Entry.UserSid)|$($Entry.ExeInfo)"], $Entry)) { $Kept.Add($Entry) }
        }
        $Entries = $Kept.ToArray()
        $InventoryApps = $null
        $AppFields = $null
        if ($DiscoveryOk)
        {
            $InventoryApps = @(ConvertTo-AUInventoryApps -Apps $Apps)
            $Known = Get-AUKnownExes -Apps $Apps -MsiFileMap $MsiFileMap -Mappings $Run.Mappings -Entries $Entries
            $AppFields = Get-AUAppUsage -Entries $Entries -InventoryApps $InventoryApps -KnownExesByApp $Known -WatchingSince $Ledger.WatchingSince -ScopeRead $ScopeRead -Apps $Apps -CollectionOk $SrumOk
        }
        $ExeEntries = @(ConvertTo-AUExeUsage -Entries $Entries)
        $UnmatchedCount = [int](Get-AUUnmatchedExeCount -Entries $Entries)
        & $EndStage 'Aggregation'

        # 8. The results, then the ledger (Task 9: a failed write leaves the file unchanged).
        $Run.Result.InventoryApps = $InventoryApps
        $Run.Result.AppFields = $AppFields
        $Run.Result.ExeEntries = $ExeEntries
        $Run.Result.UnmatchedExeCount = $UnmatchedCount
        $Run.Result.WatchingSince = $Ledger.WatchingSince
        $Run.Result.ProfilesFound = [int]$Discovery.ProfilesFound
        $Run.Result.ProfilesRead = [int]$Discovery.ProfilesRead
        try { Write-AULedger -Ledger $Ledger -Path $Run.LedgerPath }
        catch
        {
            Add-AUStatusToken $Tokens 'LedgerWriteFailed'
            Write-CMTraceLog -Message "App Usage: the ledger wasn't written this run: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3
        }
        & $EndStage 'LedgerWrite'
    }
    finally
    {
        if ($null -ne $ReadBudget) { Close-AUReadBudget $ReadBudget }
        if ($null -ne $Snapshot) { Remove-AUSnapshot -Snapshot $Snapshot }
        elseif ($WorkDir) { Remove-AUSnapshot -Snapshot ([pscustomobject]@{ WorkDir = $WorkDir; ShadowId = $null }) }
    }
}#endfunction

function Invoke-AURun
{
    <#
.SYNOPSIS
    Checks the OS build, loads the mappings, and runs Invoke-AUCollection under the run lock.
.DESCRIPTION
    An unreadable build number stops the run with AppUsageFailed:OsBuild; below build 26200 it stops
    with UnsupportedOS. Either way no snapshot is taken (D42). The ledger and outbox paths come from
    the serial (Get-AUSerial unless the caller gave one); an unreadable serial stops the run with
    AppUsageFailed:Serial, and a blank one falls back to the computer name (F44). When our embedded
    rules are missing (MappingsUnavailable:Missing) or invalid (MappingsUnavailable:Invalid), the run
    stops before the lock, so stored targets and the ledger are untouched. An invalid customer file
    is reported (InvalidCustomerMappings, with TooLarge, UnsafePath, or ReparsePoint when that's the
    reason); a missing one isn't a problem and is only logged. Lock not acquired: AppUsageBusy. The work under the lock
    failed: AppUsageFailed, and the results are cleared.
.PARAMETER Run
    The run built by Invoke-AppUsage.
#>
    param (
        [pscustomobject]$Run
    )

    $Tokens = $Run.Tokens
    $Build = [int](Get-AUOsBuild)
    if ($Build -le 0)
    {
        Add-AUStatusToken $Tokens 'AppUsageFailed:OsBuild'
        Write-CMTraceLog -Message "App Usage: skipped, because the Windows build number couldn't be read." -Component 'AppUsage' -Type 3
        return
    }
    if ($Build -lt $script:AUMinOsBuild)
    {
        Add-AUStatusToken $Tokens 'UnsupportedOS'
        Write-CMTraceLog -Message "App Usage: skipped, because Windows build $Build is below $($script:AUMinOsBuild) (Windows 11 25H2, D42)." -Component 'AppUsage' -Type 2
        return
    }

    $Serial = $Run.Serial
    if (-not $Run.SerialGiven) { $Serial = Get-AUSerial }
    if ($null -eq $Serial)
    {
        # A blank serial falls back to the computer name (F44); an unread one could name a second
        # ledger for the same device, so the run stops.
        Add-AUStatusToken $Tokens 'AppUsageFailed:Serial'
        Write-CMTraceLog -Message "App Usage: skipped, because the serial number couldn't be read, so the ledger can't be named." -Component 'AppUsage' -Type 3
        return
    }
    $Serial = [string]$Serial
    $Run.LedgerPath = Get-AULedgerPath -Serial $Serial -ComputerName $Run.ComputerName
    $Run.Result.LedgerPath = $Run.LedgerPath
    $Run.Result.OutboxPath = Get-AUOutboxPath -Serial $Serial -ComputerName $Run.ComputerName

    $Mappings = Get-AUMappings -Embedded $Run.Embedded -BesideDir $Run.BesideDir -CustomerPath $Run.CustomerMappingsPath
    $Run.Result.MappingsVersion = [string]$Mappings.PowerStacksVersion
    $Run.Result.CustomerMappingsHash = [string]$Mappings.CustomerHash
    switch ([string]$Mappings.CustomerSource)
    {
        'Absent' { Write-CMTraceLog -Message 'App Usage: no customer mapping file, so only our rules apply.' -Component 'AppUsage' }
        'TooLarge' { Add-AUStatusToken $Tokens 'InvalidCustomerMappings:TooLarge' }
        'Invalid'
        {
            $Detail = [string]$Mappings.CustomerDetail
            if ($Detail -cin @('UnsafePath', 'ReparsePoint')) { Add-AUStatusToken $Tokens "InvalidCustomerMappings:$Detail" }
            else { Add-AUStatusToken $Tokens 'InvalidCustomerMappings' }
        }
    }
    if ([string]$Mappings.Source -eq 'None')
    {
        Add-AUStatusToken $Tokens 'MappingsUnavailable:Missing'
        Write-CMTraceLog -Message 'App Usage: skipped, because our mapping rules are missing from the script.' -Component 'AppUsage' -Type 3
        return
    }
    if ([string]::IsNullOrWhiteSpace([string]$Mappings.PowerStacksVersion))
    {
        Add-AUStatusToken $Tokens 'MappingsUnavailable:Invalid'
        Write-CMTraceLog -Message "App Usage: skipped, because our mapping rules ($($Mappings.Source)) didn't load." -Component 'AppUsage' -Type 3
        return
    }
    $Run.Mappings = $Mappings
    $Run.CustomerRulesUnavailable = ([string]$Mappings.CustomerSource -in @('Invalid', 'TooLarge'))

    $Lock = Invoke-AUWithLock -Body { Invoke-AUCollection -Run $Run } -TimeoutSeconds $script:AULockTimeoutSeconds
    if ($Lock.Acquired -ne $true)
    {
        Add-AUStatusToken $Tokens 'AppUsageBusy'
        return
    }
    if ($null -ne $Lock.Result) { Write-CMTraceLog -Message "App Usage: the work under the lock wrote unexpected output: $(Get-AUSafeLogText (@($Lock.Result) -join ' | '))" -Component 'AppUsage' -Type 2 }
    if ($null -ne $Lock.Error)
    {
        Add-AUStatusToken $Tokens 'AppUsageFailed'
        Clear-AUResultData $Run.Result
        Write-CMTraceLog -Message "App Usage: the run failed, so its usage results are blank: $(Get-AUSafeLogText $Lock.Error)" -Component 'AppUsage' -Type 3
    }
}#endfunction

function New-AUResult
{
    <#
.SYNOPSIS
    Returns an empty Invoke-AppUsage result (see Invoke-AppUsage for the fields). Uses only what
    Constrained Language Mode allows: New-Object PSObject, because it refuses a [pscustomobject] cast.
.PARAMETER RunId
    The run's GUID.
#>
    param (
        [string]$RunId
    )

    return New-Object PSObject -Property ([ordered]@{
        RunId                = $RunId
        Status               = 'OK'
        StatusTokens         = @()
        InventoryApps        = $null
        AppFields            = $null
        ExeEntries           = $null
        UnmatchedExeCount    = $null
        WatchingSince        = $null
        ProfilesFound        = $null
        ProfilesRead         = $null
        MappingsVersion      = ''
        CustomerMappingsHash = ''
        DeviceColumns        = $null
        LedgerPath           = $null
        OutboxPath           = $null
        Timings              = [ordered]@{}
    })
}#endfunction

function Clear-AUResultData
{
    <#
.SYNOPSIS
    Clears a result's usage data after a failure, so no partial result reaches the inventory.
.PARAMETER Result
    The Invoke-AppUsage result.
#>
    param (
        [pscustomobject]$Result
    )

    foreach ($Name in @('InventoryApps', 'AppFields', 'ExeEntries', 'UnmatchedExeCount', 'WatchingSince', 'ProfilesFound', 'ProfilesRead')) { $Result.$Name = $null }
}#endfunction

function New-AUDeviceColumns
{
    <#
.SYNOPSIS
    Returns the device columns for row 1, in the spec's order, named for the API mode (Get-AUColumnName).
.DESCRIPTION
    AppUsageEnabled_b (true: metering was on), WatchingSince_t (Format-AUDate text, or $null),
    AppUsageScriptVersion_s, MappingsVersion_s, CustomerMappingsHash_s, UnmatchedExeCount_d,
    ProfilesFound_d, ProfilesRead_d, and AppUsageCollectionStatus_s. The run columns RunId_g,
    RowIndex_d, and RowCount_d are New-AURunRows's. Uses only what Constrained Language Mode allows.
.PARAMETER Result
    The Invoke-AppUsage result, with Status set.
.PARAMETER LogAPIMode
    The inventory's $LogAPIMode.
.PARAMETER ScriptVersion
    The inventory's $ScriptVersion.
#>
    param (
        [pscustomobject]$Result,
        [string]$LogAPIMode,
        [string]$ScriptVersion
    )

    $Watching = $null
    if ($Result.WatchingSince -is [datetime]) { $Watching = ConvertTo-AUOutputDate $Result.WatchingSince }
    $Columns = [ordered]@{}
    $Columns[(Get-AUColumnName 'AppUsageEnabled' 'b' $LogAPIMode)] = $true
    $Columns[(Get-AUColumnName 'WatchingSince' 't' $LogAPIMode)] = $Watching
    $Columns[(Get-AUColumnName 'AppUsageScriptVersion' 's' $LogAPIMode)] = $ScriptVersion
    $Columns[(Get-AUColumnName 'MappingsVersion' 's' $LogAPIMode)] = [string]$Result.MappingsVersion
    $Columns[(Get-AUColumnName 'CustomerMappingsHash' 's' $LogAPIMode)] = [string]$Result.CustomerMappingsHash
    $Columns[(Get-AUColumnName 'UnmatchedExeCount' 'd' $LogAPIMode)] = $Result.UnmatchedExeCount
    $Columns[(Get-AUColumnName 'ProfilesFound' 'd' $LogAPIMode)] = $Result.ProfilesFound
    $Columns[(Get-AUColumnName 'ProfilesRead' 'd' $LogAPIMode)] = $Result.ProfilesRead
    $Columns[(Get-AUColumnName 'AppUsageCollectionStatus' 's' $LogAPIMode)] = [string]$Result.Status
    return $Columns
}#endfunction

function Invoke-AppUsage
{
    <#
.SYNOPSIS
    Runs App Usage for this inventory run and returns what the App Inventory upload needs. Never
    throws, and writes nothing to the console (D28, D40).
.DESCRIPTION
    The caller runs it only when $CollectAppMetering is on. It reads the script settings
    $MinFocusSecondsForUse, $CollectUWPInventory (Store and MSIX apps and their usage, D46),
    $AppUsageCustomerMappingsPath, $ScriptVersion, $LogAPIMode (the device column names), and
    $script:AppUsageMappingsEmbedded, and passes them down (F3).
    Order: the language mode first, because Constrained Language Mode blocks the .NET calls the rest
    needs (anything but FullLanguage: LanguageMode:<mode>; skipped, D37); then the OS build (below
    26200: UnsupportedOS, no snapshot, D42); then the mappings (Invoke-AURun); then, under the run
    lock Global\PowerStacksAppUsage, everything that reads or writes the ledger and the hive mounts
    (Invoke-AUCollection; lock busy: AppUsageBusy). Every stage's elapsed time is logged.
    Every output stream of the work is captured and logged, so nothing reaches the console. An
    unexpected error becomes AppUsageFailed, and the usage results are $null; the inventory itself
    is never affected.
    Returns a PSCustomObject (the contract Task 15b's inventory wiring uses):
      RunId              The run's GUID (the one given, or a new one when it isn't a GUID). Pass it
                         to New-AURunRows so every row of the run carries it.
      Status             AppUsageCollectionStatus_s for this run so far (Format-AUStatus of
                         StatusTokens).
      StatusTokens       The status tokens, string[]. The caller adds PendingRows and OutboxSkipped
                         after the outbox flush and sets AppUsageCollectionStatus_s in DeviceColumns
                         to Format-AUStatus of the whole list.
      InventoryApps      The App Inventory entries (ConvertTo-AUInventoryApps: one per DisplayName,
                         newest version, version 19's seven fields), or $null when discovery failed
                         or App Usage didn't run; then the inventory uses its own read (D36).
      AppFields          Hashtable keyed by AppName (ignoring case) of the usage fields for each
                         InventoryApps entry (Get-AUAppUsage: AppLastUsedDate, AppUsageStatus,
                         AppLastRanDate, AppInFocusSeconds, AppUsersWithUse, AppMatchedExeCount,
                         AppRunsAsService), or $null whenever InventoryApps is $null.
      ExeEntries         The ExeUsage blob entries (ConvertTo-AUExeUsage), or $null.
      UnmatchedExeCount  UnmatchedExeCount_d (Get-AUUnmatchedExeCount), or $null.
      WatchingSince      The ledger's WatchingSince (a Utc DateTime), or $null.
      ProfilesFound      ProfilesFound_d, or $null.
      ProfilesRead       ProfilesRead_d, or $null.
      MappingsVersion    MappingsVersion_s ('' when our rules didn't load).
      CustomerMappingsHash  CustomerMappingsHash_s ('' unless the customer file was used).
      DeviceColumns      Ordered dictionary of row 1's device columns (New-AUDeviceColumns), named
                         for LogAPIMode, without the run columns RunId_g, RowIndex_d, and RowCount_d.
      LedgerPath         C:\Windows\AppUsage_<Serial>.json, or $null when App Usage didn't get that far.
      OutboxPath         C:\Windows\AppUsage_<Serial>_outbox, the same serial (Get-AUOutboxPath), or $null.
      Timings            Ordered dictionary of stage name to milliseconds, and Total.
.PARAMETER RunId
    The run's GUID; a new one when it's blank or isn't a GUID.
.PARAMETER Serial
    The device's serial number for the ledger and outbox names; read from Win32_BIOS when not given.
.PARAMETER ComputerName
    The computer name, used when the serial is blank.
#>
    param (
        [string]$RunId,
        [string]$Serial,
        [string]$ComputerName = $env:COMPUTERNAME
    )

    # The script's own preference (powershell.exe -File), whatever the caller's: under Stop, any
    # non-terminating error, such as the logger's when the log is locked, would end the run. Every
    # call that must stop on an error passes -ErrorAction Stop.
    $ErrorActionPreference = 'Continue'
    $Version = [string]$ScriptVersion
    # The inventory's setting names the device columns (Get-AUColumnName).
    $ApiMode = [string]$LogAPIMode
    try
    {
        # Constrained Language Mode first: only plain types and cmdlets until it's known to be Full.
        $Mode = ''
        try { $Mode = [string](Get-AULanguageMode) } catch { $Mode = '' }
        if ($Mode -cne 'FullLanguage')
        {
            if ($Mode -notmatch '^[A-Za-z]+$') { $Mode = 'Unknown' }
            $Result = New-AUResult -RunId $RunId
            $Result.StatusTokens = @("LanguageMode:$Mode", 'skipped')
            $Result.Status = "LanguageMode:$Mode; skipped"
            $Result.DeviceColumns = New-AUDeviceColumns -Result $Result -LogAPIMode $ApiMode -ScriptVersion $Version
            Write-CMTraceLog -Message "App Usage: skipped, because the language mode is $Mode, not FullLanguage (D37)." -Component 'AppUsage' -Type 2
            return $Result
        }

        $Total = [Diagnostics.Stopwatch]::StartNew()
        $Guid = [guid]::Empty
        if (-not [guid]::TryParse([string]$RunId, [ref]$Guid))
        {
            if ($RunId) { Write-CMTraceLog -Message "App Usage: RunId '$RunId' isn't a GUID, so this run gets a new one." -Component 'AppUsage' -Type 2 }
            $Guid = [guid]::NewGuid()
        }
        $Result = New-AUResult -RunId $Guid.ToString()
        $MinFocus = $MinFocusSecondsForUse -as [double]
        if ($null -eq $MinFocus) { $MinFocus = [double]1 }
        $Run = [pscustomobject]@{
            RunId                    = $Result.RunId
            Serial                   = [string]$Serial
            SerialGiven              = $PSBoundParameters.ContainsKey('Serial')
            ComputerName             = [string]$ComputerName
            IncludeStore             = ($CollectUWPInventory -eq $true)
            MinFocusSeconds          = $MinFocus
            CustomerMappingsPath     = [string]$AppUsageCustomerMappingsPath
            Embedded                 = [string]$script:AppUsageMappingsEmbedded
            BesideDir                = [string]$PSScriptRoot
            Mappings                 = $null
            CustomerRulesUnavailable = $false
            LedgerPath               = $null
            Tokens                   = New-Object 'System.Collections.Generic.List[string]'
            Timings                  = $Result.Timings
            Result                   = $Result
        }
        Write-CMTraceLog -Message "App Usage: starting run $($Run.RunId) (Store apps $($Run.IncludeStore), focus floor $MinFocus s)." -Component 'AppUsage'

        try
        {
            # Every stream is captured, so a stray Write-Host, warning, or error never reaches the console (D40).
            $Stray = Invoke-AURun -Run $Run *>&1
            foreach ($Item in @($Stray))
            {
                if ($null -ne $Item) { Write-CMTraceLog -Message "App Usage: unexpected output: $(Get-AUSafeLogText ([string]$Item))" -Component 'AppUsage' -Type 2 }
            }
        }
        catch
        {
            Add-AUStatusToken $Run.Tokens 'AppUsageFailed'
            Clear-AUResultData $Result
            Write-CMTraceLog -Message "App Usage: the run failed, so its usage results are blank: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3
        }

        $Result.StatusTokens = $Run.Tokens.ToArray()
        try { $Result.Status = Format-AUStatus $Result.StatusTokens }
        catch
        {
            $Result.StatusTokens = @('AppUsageFailed')
            $Result.Status = 'AppUsageFailed'
        }
        $Result.DeviceColumns = New-AUDeviceColumns -Result $Result -LogAPIMode $ApiMode -ScriptVersion $Version
        $Result.Timings['Total'] = [long]$Total.ElapsedMilliseconds
        $Exes = 0
        if ($null -ne $Result.ExeEntries) { $Exes = @($Result.ExeEntries).Count }
        $AppCount = 'none'
        if ($null -ne $Result.InventoryApps) { $AppCount = @($Result.InventoryApps).Count }
        Write-CMTraceLog -Message "App Usage: run $($Result.RunId) finished in $($Total.ElapsedMilliseconds) ms: $($Result.Status); inventory apps $AppCount, $Exes executable entries, $($Result.UnmatchedExeCount) unmatched." -Component 'AppUsage'
        return $Result
    }
    catch
    {
        # Last resort: even the result couldn't be built normally. Plain types only, as in New-AUResult.
        try { Write-CMTraceLog -Message "App Usage: failed before a result was built: $(Get-AUSafeLogText $_.Exception.Message)" -Component 'AppUsage' -Type 3 } catch { }
        $Fallback = New-Object PSObject -Property ([ordered]@{
                RunId = $RunId; Status = 'AppUsageFailed'; StatusTokens = @('AppUsageFailed'); InventoryApps = $null; AppFields = $null; ExeEntries = $null
                UnmatchedExeCount = $null; WatchingSince = $null; ProfilesFound = $null; ProfilesRead = $null; MappingsVersion = ''; CustomerMappingsHash = ''
                DeviceColumns = $null; LedgerPath = $null; OutboxPath = $null; Timings = [ordered]@{}
            })
        try { $Fallback.DeviceColumns = New-AUDeviceColumns -Result $Fallback -LogAPIMode $ApiMode -ScriptVersion $Version } catch { }
        return $Fallback
    }
}#endfunction

# Inventory wiring (Task 15). The inline App Inventory section calls these when $CollectAppMetering is
# on; with it off, that section runs exactly version 19's code and calls none of them.

# The usage fields on each installed-app entry, in the spec's order (Get-AUAppUsage).
$script:AUAppFieldNames = @('AppLastUsedDate', 'AppUsageStatus', 'AppLastRanDate', 'AppInFocusSeconds', 'AppUsersWithUse', 'AppMatchedExeCount', 'AppRunsAsService')

function New-AUFailedResult
{
    <#
.SYNOPSIS
    Returns an Invoke-AppUsage result for a run where Invoke-AppUsage itself failed: AppUsageFailed, no usage data, and the device columns.
.PARAMETER RunId
    The run's GUID.
.PARAMETER LogAPIMode
    The inventory's $LogAPIMode.
.PARAMETER ScriptVersion
    The inventory's $ScriptVersion.
#>
    param (
        [string]$RunId,
        [string]$LogAPIMode,
        [string]$ScriptVersion
    )

    $Guid = [guid]::Empty
    if (-not [guid]::TryParse($RunId, [ref]$Guid)) { $Guid = [guid]::NewGuid() }
    $Result = New-AUResult -RunId $Guid.ToString()
    $Result.Status = 'AppUsageFailed'
    $Result.StatusTokens = @('AppUsageFailed')
    $Result.DeviceColumns = New-AUDeviceColumns -Result $Result -LogAPIMode $LogAPIMode -ScriptVersion $ScriptVersion
    return $Result
}#endfunction

function Add-AUAppFields
{
    <#
.SYNOPSIS
    Adds the usage fields ($script:AUAppFieldNames) to each App Inventory entry, from AppFields by AppName.
.DESCRIPTION
    Every entry gets all seven fields, after its version 19 fields. An entry with no AppFields value
    (App Usage failed, was skipped, or the inventory used its own read) gets them blank ($null), so
    the entries are otherwise unchanged (spec: Fields on Each Installed-App Entry).
.PARAMETER AppArray
    The App Inventory entries (ConvertTo-AUAppArray or Invoke-AppUsage's InventoryApps).
.PARAMETER AppFields
    Invoke-AppUsage's AppFields: AppName to the field values, or $null.
#>
    param (
        [object[]]$AppArray,
        [hashtable]$AppFields
    )

    foreach ($App in @($AppArray))
    {
        if ($null -eq $App) { continue }
        $Values = $null
        $Name = [string]$App.AppName
        if ($null -ne $AppFields -and $Name -and $AppFields.ContainsKey($Name)) { $Values = $AppFields[$Name] }
        foreach ($Field in $script:AUAppFieldNames)
        {
            $Value = $null
            if ($null -ne $Values) { $Value = $Values.$Field }
            $App | Add-Member -MemberType NoteProperty -Name $Field -Value $Value -Force
        }
    }
}#endfunction

function ConvertTo-AUExeUsageJson
{
    <#
.SYNOPSIS
    Returns the ExeUsage blob's JSON: an array of Invoke-AppUsage's ExeEntries, or '' when there are none to send.
.DESCRIPTION
    '' (no pieces, so no ExeUsage columns) when ExeEntries is $null: App Usage failed or was
    skipped. An empty list is "[]". Always an array, even for one entry, compressed, with depth for
    CandidateTargets.
.PARAMETER ExeEntries
    Invoke-AppUsage's ExeEntries.
#>
    param (
        [object[]]$ExeEntries
    )

    if ($null -eq $ExeEntries) { return '' }
    return (ConvertTo-Json -InputObject @($ExeEntries) -Depth 5 -Compress)
}#endfunction

function Send-AUInventoryRun
{
    <#
.SYNOPSIS
    Sends the run's App Inventory data with metering on: the outbox first, then this run's rows (D44, F45, F51 to F53).
.DESCRIPTION
    Under the outbox lock ($script:AUOutboxLockName, waited for up to LockTimeoutSeconds): Send-AUOutbox,
    then row 1's AppUsageCollectionStatus_s set to Format-AUStatus of StatusTokens plus PendingRows
    and OutboxSkipped from the flush, then New-AURunRows and Send-AURunRows, with one retry budget for
    the whole run. The run lock isn't held here, so a send that backs off for minutes never makes an
    overlapping run's App Usage AppUsageBusy; the outbox lock keeps two runs from using the outbox at
    once. When the outbox lock isn't acquired, the outbox isn't used this run (OutboxSkipped): the
    rows are still sent, and rows that aren't sent are lost. A blank OutboxDir (App Usage stopped
    before naming it) also means no outbox.
    MainColumns gets the final status, so the caller's $MainApp shows what row 1 sent. Returns
    RowCount, Sent, Pending, Saved, SentBytes, AllSent (every row of this run was sent), Status, and
    OutboxSent. Throws when the rows can't be built (New-AURunRows) or the work under the lock
    fails; the caller then uses its own upload.
.PARAMETER MainColumns
    Row 1's columns: the inventory's $MainApp (ComputerName, ManagedDeviceID, and the device columns), without pieces.
.PARAMETER InstalledAppsJson
    The InstalledApps JSON.
.PARAMETER ExeUsageJson
    The ExeUsage JSON (ConvertTo-AUExeUsageJson).
.PARAMETER StatusTokens
    Invoke-AppUsage's StatusTokens.
.PARAMETER RunId
    The run's GUID (Invoke-AppUsage's RunId).
.PARAMETER OutboxDir
    Invoke-AppUsage's OutboxPath, or blank.
.PARAMETER LogAPIMode
    The inventory's $LogAPIMode.
.PARAMETER LogType
    The App Inventory log type.
.PARAMETER Sender
    The inventory's row sender (see the note above Get-AUColumnName).
.PARAMETER LockTimeoutSeconds
    How long to wait for the outbox lock.
#>
    param (
        $MainColumns,
        [string]$InstalledAppsJson,
        [string]$ExeUsageJson,
        [string[]]$StatusTokens,
        [string]$RunId,
        [string]$OutboxDir,
        [string]$LogAPIMode,
        [string]$LogType,
        [scriptblock]$Sender,
        [int]$LockTimeoutSeconds = $script:AULockTimeoutSeconds
    )

    if ($null -eq $Sender) { throw 'Send-AUInventoryRun needs -Sender.' }
    $State = [pscustomobject]@{
        Tokens     = New-Object 'System.Collections.Generic.List[string]'
        OutboxDir  = [string]$OutboxDir
        Flush      = $null
        Rows       = $null
        Sent       = $null
        Status     = $null
    }
    foreach ($Token in @($StatusTokens)) { if (-not [string]::IsNullOrWhiteSpace($Token)) { Add-AUStatusToken $State.Tokens $Token } }
    $StatusColumn = Get-AUColumnName 'AppUsageCollectionStatus' 's' $LogAPIMode
    # One retry budget for the whole run (F51), shared by the outbox flush and this run's rows.
    $Budget = [ref]1
    $Work = {
        $State.Flush = Send-AUOutbox -OutboxDir $State.OutboxDir -RetryBudget $Budget -LogAPIMode $LogAPIMode -LogType $LogType -Sender $Sender
        if ($State.Flush.PendingRows) { Add-AUStatusToken $State.Tokens 'PendingRows' }
        if ($State.Flush.OutboxSkipped) { Add-AUStatusToken $State.Tokens 'OutboxSkipped' }
        try { $State.Status = Format-AUStatus $State.Tokens.ToArray() }
        catch { $State.Status = 'AppUsageFailed' }
        $MainColumns.$StatusColumn = $State.Status
        $State.Rows = New-AURunRows -MainColumns $MainColumns -InstalledAppsJson $InstalledAppsJson -ExeUsageJson $ExeUsageJson -LogAPIMode $LogAPIMode -RunId $RunId
        $State.Sent = Send-AURunRows -Rows $State.Rows -OutboxDir $State.OutboxDir -RetryBudget $Budget -LogAPIMode $LogAPIMode -LogType $LogType -Sender $Sender
    }

    $Lock = Invoke-AUWithLock -Name $script:AUOutboxLockName -TimeoutSeconds $LockTimeoutSeconds -Body $Work
    if ($Lock.Acquired -ne $true)
    {
        Write-CMTraceLog -Message 'App Usage: the outbox lock is held by another run, so this run sends its rows without the outbox.' -Component 'AppUsage' -Type 2
        Add-AUStatusToken $State.Tokens 'OutboxSkipped'
        $State.OutboxDir = ''
        & $Work
    }
    elseif ($null -ne $Lock.Error) { throw "The App Inventory rows weren't sent: $($Lock.Error)" }

    $RowCount = 0
    if ($null -ne $State.Rows) { $RowCount = @($State.Rows).Count }
    $Sent = $State.Sent
    $OutboxSent = 0
    if ($null -ne $State.Flush) { $OutboxSent = [int]$State.Flush.Sent }
    $Outcome = [pscustomobject]@{
        RowCount   = $RowCount
        Sent       = [int]$Sent.Sent
        Pending    = [int]$Sent.Pending
        Saved      = [int]$Sent.Saved
        SentBytes  = [long]$Sent.SentBytes
        AllSent    = ($RowCount -gt 0 -and [int]$Sent.Sent -eq $RowCount)
        Status     = $State.Status
        OutboxSent = $OutboxSent
    }
    Write-CMTraceLog -Message "App Usage: run $RunId sent $($Outcome.Sent) of $RowCount App Inventory row(s), $($Outcome.SentBytes) bytes; $($Outcome.Saved) saved to the outbox; $OutboxSent outbox row(s) sent first. Status: $($Outcome.Status)" -Component 'AppUsage'
    return $Outcome
}#endfunction

function Format-AUInventoryResponse
{
    <#
.SYNOPSIS
    Returns the App Inventory upload response for the summary line with metering on (D40, F41).
.DESCRIPTION
    When every row of the run was sent, it has the success status the summary line checks (204, or
    200 for the classic API), then the total size and the row count, in version 19's form:
    "204 : Upload payload size is 41.2Kb (1 row) ". Otherwise it says how many rows were sent, which
    the summary line reports as Fail.
.PARAMETER Outcome
    The Send-AUInventoryRun result.
.PARAMETER LogAPIMode
    The inventory's $LogAPIMode.
#>
    param (
        [pscustomobject]$Outcome,
        [string]$LogAPIMode
    )

    $Code = if ($LogAPIMode -eq 'LogIngestionAPI') { 204 } else { 200 }
    $Rows = if ($Outcome.RowCount -eq 1) { '1 row' } else { "$($Outcome.RowCount) rows" }
    if ($Outcome.AllSent) { return "$Code : Upload payload size is " + ($Outcome.SentBytes / 1024).ToString('#.#') + "Kb ($Rows) " }
    return "Sent $($Outcome.Sent) of $Rows "
}#endfunction
#endregion APPUSAGE

#region script

Write-CMTraceLog "========== Script Execution Started =========="
Write-CMTraceLog "Script version: $ScriptVersion"
Write-CMTraceLog "Log API Mode: $LogAPIMode"

# Delete old logs
# Delete old logs
Write-CMTraceLog "Cleaning up old transciption log files..."
try
{
    # Inventory_Script_* is the current transcript name; Intune_Inventory_* is the name older versions used
    $oldLogs = @(Get-ChildItem "C:\Windows\Logs" -Filter "Inventory_Script_*.log" -ErrorAction SilentlyContinue) + @(Get-ChildItem "C:\Windows\Logs" -Filter "Intune_Inventory_*.log" -ErrorAction SilentlyContinue) | Where-Object { $_.FullName -ne $logPath }
    Write-CMTraceLog "Found $($oldLogs.Count) old transciption log file(s) to delete"
    $oldLogs | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-CMTraceLog "Old transciption logs cleaned up successfully"
}
catch
{
    Write-CMTraceLog "Error cleaning up old transciption logs: $($_.Exception.Message)" -WarningMsg
}

Write-CMTraceLog "Cleaning up old script log files..."
try
{
    $oldLogs = Get-ChildItem "C:\Windows\Logs" -Filter "Enhanced_Intune_Inventory_*.log" -ErrorAction SilentlyContinue | Where-Object { $_.FullName -ne $CMLog }
    Write-CMTraceLog "Found $($oldLogs.Count) old script log file(s) to delete"
    $oldLogs | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-CMTraceLog "Old script logs cleaned up successfully"
}
catch
{
    Write-CMTraceLog "Error cleaning up old script logs: $($_.Exception.Message)" -WarningMsg
}


#Get Common data for App and Device Inventory:
Write-CMTraceLog "Gathering common device information..."

#Get Intune DeviceID and ManagedDeviceName
Write-CMTraceLog "Retrieving Intune enrollment information..."
try
{
    if (@(Get-ChildItem HKLM:SOFTWARE\Microsoft\Enrollments\ -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -eq 'MS DM Server' }))
    {
        $MSDMServerInfo = Get-ChildItem HKLM:SOFTWARE\Microsoft\Enrollments\ -Recurse | Where-Object { $_.PSChildName -eq 'MS DM Server' }
        $ManagedDeviceInfo = Get-ItemProperty -LiteralPath "Registry::$($MSDMServerInfo)"
        Write-CMTraceLog "Intune enrollment registry keys found"
    }
    else
    {
        Write-CMTraceLog "No Intune enrollment registry keys found" -WarningMsg
    }
}
catch
{
    Write-CMTraceLog "Error retrieving Intune enrollment information: $($_.Exception.Message)" -ErrorMsg
}

$ManagedDeviceName = $ManagedDeviceInfo.EntDeviceName
$ManagedDeviceID = $ManagedDeviceInfo.EntDMID

if (!($ManagedDeviceID))
{
    Write-CMTraceLog "Managed Device Name is Not Found!" -ErrorMsg
    Write-CMTraceLog "DEVICE APPEARS TO BE UNMANAGED!" -ErrorMsg
}
else
{
    Write-CMTraceLog "Managed Device Name: $ManagedDeviceName"
}

if (!($ManagedDeviceID))
{
    Write-CMTraceLog "Managed Device ID is Not Found!" -ErrorMsg
    Write-CMTraceLog "DEVICE APPEARS TO BE UNMANAGED!" -ErrorMsg

}
else
{
    Write-CMTraceLog "Managed Device ID: $ManagedDeviceID"
}

#Get Computer Info
Write-CMTraceLog "Retrieving computer information (Get-ComputerInfo)..."
try
{
    $ComputerInfo = Get-ComputerInfo
    Write-CMTraceLog "Computer information retrieved successfully"
}
catch
{
    Write-CMTraceLog "Error retrieving computer information: $($_.Exception.Message)" -ErrorMsg
    throw
}

$ComputerName = $ComputerInfo.CsName
$ComputerManufacturer = $ComputerInfo.CsManufacturer
Write-CMTraceLog "Computer Name: $ComputerName"
Write-CMTraceLog "Manufacturer: $ComputerManufacturer"

if ($ComputerManufacturer.ToUpper() -eq "LENOVO" -or $ComputerManufacturer.ToUpper() -eq "IBM")
{
    Write-CMTraceLog "Lenovo/IBM detected, retrieving model from Win32_ComputerSystemProduct..."
    try
    {
        $ComputerModel = (Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction SilentlyContinue).Version
        Write-CMTraceLog "Model retrieved: $ComputerModel"
    }
    catch
    {
        Write-CMTraceLog "Error retrieving Lenovo model: $($_.Exception.Message)" -WarningMsg
        $ComputerModel = $ComputerInfo.CsModel
    }
}
else
{
    $ComputerModel = $ComputerInfo.CsModel
    Write-CMTraceLog "Model: $ComputerModel"
}

#region DEVICEINVENTORY
if ($CollectDeviceInventory)
{
    Write-CMTraceLog "========== Starting Device Inventory Collection =========="
    #Set Name of Log
    $DeviceLog = "PowerStacksDeviceInventory$(if($LogAPIMode -eq "LogIngestionAPI"){"_CL"})"
    Write-CMTraceLog "Device inventory log name: $DeviceLog"

    # Get Computer Inventory Information
    Write-CMTraceLog "Gathering basic computer inventory information..."
    try
    {
        $ComputerLastBootUpTime = $ComputerInfo.OsLastBootUpTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
        $ComputerPhysicalMemory = $ComputerInfo.CsTotalPhysicalMemory
        Write-CMTraceLog "Last boot time: $ComputerLastBootUpTime, Physical memory: $ComputerPhysicalMemory bytes"
    }
    catch
    {
        Write-CMTraceLog "Error retrieving boot time or memory: $($_.Exception.Message)" -ErrorMsg
    }

    Write-CMTraceLog "Retrieving processor information..."
    try
    {
        $ComputerNumberOfProcessors = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).NumberOfProcessors
        $ComputerCPU = Get-CimInstance win32_processor -ErrorAction SilentlyContinue | Select-Object Manufacturer, Name, MaxClockSpeed, NumberOfCores, NumberOfLogicalProcessors
        Write-CMTraceLog "Number of processors: $ComputerNumberOfProcessors"
    }
    catch
    {
        Write-CMTraceLog "Error retrieving CPU information: $($_.Exception.Message)" -ErrorMsg
    }
    $ComputerProcessorManufacturer = $ComputerCPU.Manufacturer | Get-Unique
    $ComputerProcessorName = $ComputerCPU.Name | Get-Unique
    $ComputerProcessorMaxClockSpeed = $ComputerCPU.MaxClockSpeed | Get-Unique
    $ComputerNumberOfCores = $ComputerCPU.NumberOfCores | Get-Unique
    $ComputerNumberOfLogicalProcessors = $ComputerCPU.NumberOfLogicalProcessors | Get-Unique
    Write-CMTraceLog "CPU: $ComputerProcessorManufacturer $ComputerProcessorName, Cores: $ComputerNumberOfCores, Logical: $ComputerNumberOfLogicalProcessors"

    try
    {
        $ComputerOSInstallDate = $ComputerInfo.OsInstallDate.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
        Write-CMTraceLog "OS Install Date: $ComputerOSInstallDate"
    }
    catch
    {
        Write-CMTraceLog "Error retrieving OS install date: $($_.Exception.Message)" -WarningMsg
    }

    Write-CMTraceLog "Retrieving battery information..."
    try
    {
        $BatteryDesignedCapacity = (Get-WmiObject -Class "BatteryStaticData" -Namespace "ROOT\WMI" -ErrorAction SilentlyContinue).DesignedCapacity
        $BatteryFullChargedCapacity = (Get-WmiObject -Class "BatteryFullChargedCapacity" -Namespace "ROOT\WMI" -ErrorAction SilentlyContinue).FullChargedCapacity
        if ($BatteryDesignedCapacity)
        {
            Write-CMTraceLog "Battery found - Designed: $BatteryDesignedCapacity, Full Charged: $BatteryFullChargedCapacity"
        }
        else
        {
            Write-CMTraceLog "No battery detected (desktop or battery not available)"
        }
    }
    catch
    {
        Write-CMTraceLog "Error retrieving battery information: $($_.Exception.Message)" -WarningMsg
    }

    #Grab Built-in Monitors PNPDeviceID
    Write-CMTraceLog "Processing monitor inventory (RemoveBuiltInMonitors: $RemoveBuiltInMonitors)..."
    if ($RemoveBuiltInMonitors)
    {
        try
        {
            $BuiltInMonitors = Get-CimInstance Win32_DesktopMonitor -ErrorAction SilentlyContinue | Select-Object PNPDeviceID
            Write-CMTraceLog "Retrieved $($BuiltInMonitors.Count) built-in monitor(s) to filter"
        }
        catch
        {
            Write-CMTraceLog "Error retrieving built-in monitors: $($_.Exception.Message)" -WarningMsg
            $BuiltInMonitors = $null
        }
    }
    else
    {
        $BuiltInMonitors = $null
    }

    #Grabs the Monitor objects from WMI
    Write-CMTraceLog "Retrieving monitor information from WMI..."
    try
    {
        $Monitors = Get-WmiObject -Namespace "root\WMI" -Class "WMIMonitorID" -ErrorAction SilentlyContinue
        Write-CMTraceLog "Retrieved $($Monitors.Count) monitor(s) from WMI"
    }
    catch
    {
        Write-CMTraceLog "Error retrieving monitors from WMI: $($_.Exception.Message)" -WarningMsg
        $Monitors = @()
    }

    #Creates an empty array to hold the data
    $MonitorArray = @()

    #Takes each monitor object found and runs the following code:
    Write-CMTraceLog "Processing monitor details..."
    $monitorProcessedCount = 0
    foreach ($Monitor in $Monitors)
    {

        if (-not($Monitor.InstanceName.Substring(0, $Monitor.InstanceName.LastIndexOf('_')) -in $BuiltInMonitors.PNPDeviceID))
        {

            # Initialize variables with null by default
            $MonitorModel = $null
            $MonitorSerialNumber = $null
            $MonitorManufacturer = $null

            # Safely decode UserFriendlyName
            if ($Monitor.UserFriendlyName -ne $null)
            {
                $MonitorModel = ([System.Text.Encoding]::ASCII.GetString($Monitor.UserFriendlyName)).Replace("$([char]0x0000)", "")
            }

            # Safely decode SerialNumberID
            if ($Monitor.SerialNumberID -ne $null)
            {
                $MonitorSerialNumber = ([System.Text.Encoding]::ASCII.GetString($Monitor.SerialNumberID)).Replace("$([char]0x0000)", "")
            }

            # Safely decode ManufacturerName
            if ($Monitor.ManufacturerName -ne $null)
            {
                $MonitorManufacturer = ([System.Text.Encoding]::ASCII.GetString($Monitor.ManufacturerName)).Replace("$([char]0x0000)", "")
            }

            $MonitorWeekOfManufacture = $Monitor.WeekOfManufacture
            $MonitorYearOfManufacture = $Monitor.YearOfManufacture

            $tempmonitor = New-Object -TypeName PSObject
            $tempmonitor | Add-Member -MemberType NoteProperty -Name "Manufacturer" -Value "$MonitorManufacturer" -Force
            $tempmonitor | Add-Member -MemberType NoteProperty -Name "Model" -Value "$MonitorModel" -Force
            $tempmonitor | Add-Member -MemberType NoteProperty -Name "SerialNumber" -Value "$MonitorSerialNumber" -Force
            $tempmonitor | Add-Member -MemberType NoteProperty -Name "WeekOfManufacture" -Value "$MonitorWeekOfManufacture" -Force
            $tempmonitor | Add-Member -MemberType NoteProperty -Name "YearOfManufacture" -Value "$MonitorYearOfManufacture" -Force
            $MonitorArray += $tempmonitor
            $monitorProcessedCount++
        }
    }
    [System.Collections.ArrayList]$MonitorArrayList = $MonitorArray
    Write-CMTraceLog "Processed $monitorProcessedCount monitor(s) for inventory"

    # Obtain physical disk details
    Write-CMTraceLog "Retrieving physical disk information..."
    try
    {
        $Disks = Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.BusType -match "NVMe|SATA|SAS|ATAPI|RAID" } | Select-Object -Property DeviceId, BusType, FirmwareVersion, HealthStatus, Manufacturer, Model, FriendlyName, SerialNumber, Size, MediaType
        Write-CMTraceLog "Retrieved $($Disks.Count) physical disk(s)"
    }
    catch
    {
        Write-CMTraceLog "Error retrieving physical disks: $($_.Exception.Message)" -ErrorMsg
        $Disks = @()
    }

    #Creates an empty array to hold the data
    $DiskArray = @()

    Write-CMTraceLog "Processing disk health and SMART data for $($Disks.Count) disk(s)..."
    $diskProcessedCount = 0
    foreach ($Disk in ($Disks | Sort-Object DeviceID))
    {
        $diskProcessedCount++
        Write-CMTraceLog "Processing disk $diskProcessedCount/$($Disks.Count): $($Disk.FriendlyName) (ID: $($Disk.DeviceID))"

        # Obtain disk health information from current disk
        try
        {
            $DiskHealth = Get-PhysicalDisk | Where-Object { $_.DeviceId -eq $Disk.DeviceID } | Get-StorageReliabilityCounter -ErrorAction Stop | Select-Object -Property Wear, ReadErrorsTotal, ReadErrorsUncorrected, WriteErrorsTotal, WriteErrorsUncorrected, Temperature, TemperatureMax
        }
        catch
        {
            Write-CMTraceLog "Warning: Could not retrieve health data for disk $($Disk.DeviceID): $($_.Exception.Message)" -WarningMsg
            $DiskHealth = $null
        }

        # Obtain SMART failure information
        try
        {
            $DrivePNPDeviceID = (Get-WmiObject -Class Win32_DiskDrive -ErrorAction SilentlyContinue | Where-Object { $_.Index -eq $Disk.DeviceID }).PNPDeviceID
            $DriveSMARTStatus = (Get-WmiObject -Namespace root\wmi -Class MSStorageDriver_FailurePredictStatus -ErrorAction SilentlyContinue | Select-Object PredictFailure, Reason) | Where-Object { $_.InstanceName -eq $DrivePNPDeviceID }
        }
        catch
        {
            Write-CMTraceLog "Warning: Could not retrieve SMART data for disk $($Disk.DeviceID): $($_.Exception.Message)" -WarningMsg
            $DriveSMARTStatus = $null
        }

        # Create custom PSObject
        $tempdisk = New-Object -TypeName PSObject

        # Create disk health state entry
        $tempdisk | Add-Member -MemberType NoteProperty -Name "Number" -Value $Disk.DeviceID
        $tempdisk | Add-Member -MemberType NoteProperty -Name "BusType" -Value $Disk.BusType
        $tempdisk | Add-Member -MemberType NoteProperty -Name "FirmwareVersion" -Value $Disk.FirmwareVersion
        $tempdisk | Add-Member -MemberType NoteProperty -Name "HealthStatus" -Value $Disk.HealthStatus
        $tempdisk | Add-Member -MemberType NoteProperty -Name "Manufacturer" -Value $Disk.Manufacturer
        $tempdisk | Add-Member -MemberType NoteProperty -Name "Model" -Value $Disk.Model
        $tempdisk | Add-Member -MemberType NoteProperty -Name "Name" -Value $Disk.FriendlyName
        $tempdisk | Add-Member -MemberType NoteProperty -Name "SerialNumber" -Value $Disk.SerialNumber
        $tempdisk | Add-Member -MemberType NoteProperty -Name "Size" -Value $Disk.Size
        $tempdisk | Add-Member -MemberType NoteProperty -Name "Type" -Value $Disk.MediaType
        $tempdisk | Add-Member -MemberType NoteProperty -Name "SMARTPredictFailure" -Value $DriveSMARTStatus.PredictFailure
        $tempdisk | Add-Member -MemberType NoteProperty -Name "SMARTReason" -Value $DriveSMARTStatus.Reason
        $tempdisk | Add-Member -MemberType NoteProperty -Name "Wear" -Value $([int]($DiskHealth.Wear))
        $tempdisk | Add-Member -MemberType NoteProperty -Name "ReadErrorsUncorrected" -Value $DiskHealth.ReadErrorsUncorrected
        $tempdisk | Add-Member -MemberType NoteProperty -Name "ReadErrorsTotal" -Value $DiskHealth.ReadErrorsTotal
        $tempdisk | Add-Member -MemberType NoteProperty -Name "WriteErrorsUncorrected" -Value $DiskHealth.WriteErrorsUncorrected
        $tempdisk | Add-Member -MemberType NoteProperty -Name "WriteErrorsTotal" -Value $DiskHealth.WriteErrorsTotal
        $tempdisk | Add-Member -MemberType NoteProperty -Name "Temperature" -Value $([int]($DiskHealth.Temperature))
        $tempdisk | Add-Member -MemberType NoteProperty -Name "TemperatureMax" -Value $([int]($DiskHealth.TemperatureMax))

        $DiskArray += $tempdisk
    }
    [System.Collections.ArrayList]$DiskArrayList = $DiskArray
    Write-CMTraceLog "Completed processing $diskProcessedCount disk(s)"


    # Query Win32_SystemEnclosure
    Write-CMTraceLog "Retrieving system chassis information..."
    try
    {
        $SystemEnclosures = Get-WmiObject -Class Win32_SystemEnclosure -ErrorAction Stop
        Write-CMTraceLog "Retrieved $($SystemEnclosures.Count) system enclosure(s)"
    }
    catch
    {
        Write-CMTraceLog "Error retrieving system enclosures: $($_.Exception.Message)" -ErrorMsg
        $SystemEnclosures = @()
    }

    # Create an empty array to hold the data
    $ChassisArray = @()

    # Process each enclosure instance
    Write-CMTraceLog "Processing chassis type information..."
    foreach ($Enclosure in $SystemEnclosures)
    {
        $ChassisTypeCodes = $Enclosure.ChassisTypes | ForEach-Object { [int]$_ }
        $SMBIOSAssetTag = $Enclosure.SMBIOSAssetTag

        # Process each ChassisTypeCode for this enclosure
        foreach ($ChassisTypeCode in $ChassisTypeCodes)
        {
            # Create custom PSObject
            $tempChassis = New-Object -TypeName PSObject
            $tempChassis | Add-Member -MemberType NoteProperty -Name "ChassisTypeCode" -Value $ChassisTypeCode
            $tempChassis | Add-Member -MemberType NoteProperty -Name "ChassisTag" -Value $SMBIOSAssetTag

            # Add to array
            $ChassisArray += $tempChassis
        }
    }
    [System.Collections.ArrayList]$ChassisArrayList = $ChassisArray
    Write-CMTraceLog "Processed $($ChassisArray.Count) chassis type entries"


    # CollectMicrosoft365
    if ($CollectMicrosoft365)
    {
        Write-CMTraceLog "========== Collecting Microsoft 365 Information =========="
        # Get Microsoft 365
        Write-CMTraceLog 'Calling Get-Microsoft365 function...'
        $Microsoft365Data = Get-Microsoft365
        if ($Microsoft365Data)
        {
            Write-CMTraceLog "Microsoft 365 data retrieved successfully"
        }
        else
        {
            Write-CMTraceLog "No Microsoft 365 data returned (may not be Click-to-Run Office)" -WarningMsg
        }

        #Creates an empty object to hold the data
        $Microsoft365 = New-Object -TypeName PSObject

        if ($Microsoft365Data)
        {
            $Microsoft365 | Add-Member -MemberType NoteProperty -Name "InstalledVersion" -Value $Microsoft365Data.InstalledVersion
            $Microsoft365 | Add-Member -MemberType NoteProperty -Name "UpdateChannel" -Value $Microsoft365Data.UpdateChannel
            $Microsoft365 | Add-Member -MemberType NoteProperty -Name "LatestReleaseType" -Value $Microsoft365Data.LatestReleaseType
            $Microsoft365 | Add-Member -MemberType NoteProperty -Name "LatestReleaseVersion" -Value $Microsoft365Data.LatestReleaseVersion
            $Microsoft365 | Add-Member -MemberType NoteProperty -Name "EndOfSupportDate" -Value $Microsoft365Data.EndOfSupportDate
            $Microsoft365 | Add-Member -MemberType NoteProperty -Name "ReleaseDate" -Value $Microsoft365Data.ReleaseDate
            $Microsoft365 | Add-Member -MemberType NoteProperty -Name "ReleaseID" -Value $Microsoft365Data.ReleaseID
        }
    }

    # CollectWarranty
    if ($CollectWarranty)
    {
        Write-CMTraceLog "========== Collecting Warranty Information =========="
        try
        {
            $WarrantyBios = Get-WmiObject Win32_Bios -ErrorAction Stop
            $WarrantyMake = $WarrantyBios.Manufacturer
            $WarrantySerialNumber = $WarrantyBios.SerialNumber
            Write-CMTraceLog "Warranty Make  : $WarrantyMake"
            Write-CMTraceLog "Warranty Serial: $WarrantySerialNumber"
        }
        catch
        {
            Write-CMTraceLog "Error retrieving BIOS information for warranty: $($_.Exception.Message)" -ErrorMsg
        }

        Write-CMTraceLog "Calling Get-Warranty function..."
        $WarrantyData = Get-Warranty -SerialNumber $WarrantySerialNumber -Manufacturer $WarrantyMake
        if ($WarrantyData)
        {
            Write-CMTraceLog "Warranty data retrieved successfully"
        }
        else
        {
            Write-CMTraceLog "No warranty data returned" -WarningMsg
        }
        if ($WarrantyData)
        {
            $Warranty = [PSCustomObject]@{
                'ServiceProvider'         = $WarrantyData.ServiceProvider
                'ServiceModel'            = $WarrantyData.ServiceModel
                'ServiceTag'              = $WarrantyData.ServiceTag
                'ServiceLevelDescription' = $WarrantyData.ServiceLevelDescription
                'WarrantyStartDate'       = if ($WarrantyData.WarrantyStartDate)
                {
                    ([datetime]::Parse($WarrantyData.WarrantyStartDate)).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
                }
                else
                {
                    $null
                }
                'WarrantyEndDate'         = if ($WarrantyData.WarrantyEndDate)
                {
                    ([datetime]::Parse($WarrantyData.WarrantyEndDate)).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
                }
                else
                {
                    $null
                }
            }

        }
    }

    # Create JSON to Upload to Log Analytics
    Write-CMTraceLog "Building device inventory JSON object..."
    $Inventory = New-Object System.Object
    $Inventory | Add-Member -MemberType NoteProperty -Name "Memory" -Value "$ComputerPhysicalMemory" -Force
    $Inventory | Add-Member -MemberType NoteProperty -Name "CPUManufacturer" -Value "$ComputerProcessorManufacturer" -Force
    $Inventory | Add-Member -MemberType NoteProperty -Name "CPUName" -Value "$ComputerProcessorName" -Force
    $Inventory | Add-Member -MemberType NoteProperty -Name "CPUMaxClockSpeed" -Value "$ComputerProcessorMaxClockSpeed" -Force
    $Inventory | Add-Member -MemberType NoteProperty -Name "CPUPhysical" -Value "$ComputerNumberOfProcessors" -Force
    $Inventory | Add-Member -MemberType NoteProperty -Name "CPUCores" -Value "$ComputerNumberOfCores" -Force
    $Inventory | Add-Member -MemberType NoteProperty -Name "CPULogical" -Value "$ComputerNumberOfLogicalProcessors" -Force
    $Inventory | Add-Member -MemberType NoteProperty -Name "BatteryDesignedCapacity" -Value "$BatteryDesignedCapacity" -Force
    $Inventory | Add-Member -MemberType NoteProperty -Name "BatteryFullChargedCapacity" -Value "$BatteryFullChargedCapacity" -Force
    $Inventory | Add-Member -MemberType NoteProperty -Name "Monitors" -Value $MonitorArrayList -Force
    $Inventory | Add-Member -MemberType NoteProperty -Name "LastBootTime" -Value "$ComputerLastBootUpTime" -Force
    $Inventory | Add-Member -MemberType NoteProperty -Name "PhysicalDisks" -Value $DiskArrayList -Force
    $Inventory | Add-Member -MemberType NoteProperty -Name "DeviceManufacturer" -Value "$ComputerManufacturer" -Force
    $Inventory | Add-Member -MemberType NoteProperty -Name "DeviceModel" -Value "$ComputerModel" -Force
    $Inventory | Add-Member -MemberType NoteProperty -Name "Chassis" -Value $ChassisArrayList -Force
    $Inventory | Add-Member -MemberType NoteProperty -Name "OSInstallDate" -Value "$ComputerOSInstallDate" -Force
    if ($CollectMicrosoft365)
    {
        $Inventory | Add-Member -MemberType NoteProperty -Name "Microsoft365" -Value $Microsoft365 -Force
    }
    if ($CollectWarranty)
    {
        $Inventory | Add-Member -MemberType NoteProperty -Name "Warranty" -Value $Warranty -Force
    }

    Write-CMTraceLog "Converting device inventory to JSON..."
    $DeviceDetailsJson = $Inventory | ConvertTo-Json
    Write-CMTraceLog "Device inventory JSON size: $($DeviceDetailsJson.Length) characters"

    Write-CMTraceLog "Compressing device inventory JSON with GZip..."
    try
    {
        $ms = New-Object System.IO.MemoryStream
        $cs = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Compress)
        $sw = New-Object System.IO.StreamWriter($cs)
        $sw.Write($DeviceDetailsJson)
        $sw.Close();
        $DeviceDetailsJson = [System.Convert]::ToBase64String($ms.ToArray())
        Write-CMTraceLog "Device inventory compressed successfully, Base64 size: $($DeviceDetailsJson.Length) characters"
    }
    catch
    {
        Write-CMTraceLog "Error compressing device inventory: $($_.Exception.Message)" -ErrorMsg
        throw
    }

    Write-CMTraceLog "Building main device upload object..."
    $MainDevice = New-Object -TypeName PSObject
    $MainDevice | Add-Member -MemberType NoteProperty -Name "ComputerName$(if($LogAPIMode -eq "LogIngestionAPI"){"_s"})" -Value "$ComputerName" -Force
    $MainDevice | Add-Member -MemberType NoteProperty -Name "ManagedDeviceID$(if($LogAPIMode -eq "LogIngestionAPI"){"_g"})" -Value "$ManagedDeviceID" -Force
    if ($CollectMicrosoft365)
    {
        $MainDevice | Add-Member -MemberType NoteProperty -Name "Microsoft365$(if($LogAPIMode -eq "LogIngestionAPI"){"_b"})" -Value $true -Force
    }
    if ($CollectWarranty -and $Warranty -and $Warranty.PSObject.Properties.Count -gt 0)
    {
        Write-CMTraceLog "Warranty property count: $($Warranty.PSObject.Properties.Count)"
        Write-CMTraceLog "Warranty data contents:`n$($WarrantyData | Out-String)"
        Write-CMTraceLog "Warranty contents:`n$($Warranty | Out-String)"
        $MainDevice | Add-Member -MemberType NoteProperty -Name "Warranty$(if($LogAPIMode -eq "LogIngestionAPI"){"_b"})" -Value $true -Force
    }
    else
    {
        if (-not $CollectWarranty)
        {
            Write-CMTraceLog "Warranty collection not enabled. Skipping warranty flag."
        }
        elseif (-not $Warranty)
        {
            Write-CMTraceLog "Warranty object is null."
        }
        elseif ($Warranty.PSObject.Properties.Count -eq 0)
        {
            Write-CMTraceLog "Warranty object is present but has no properties."
        }
        else
        {
            Write-CMTraceLog "Warranty check did not meet conditions. Unexpected state."
        }
        $MainDevice | Add-Member -MemberType NoteProperty -Name "Warranty$(if($LogAPIMode -eq "LogIngestionAPI"){"_b"})" -Value $false -Force
    }

    Write-CMTraceLog "Splitting device details into chunks..."
    $DeviceDetailsJsonArr = $DeviceDetailsJson -split "(.{$(if($LogAPIMode -eq 'LogIngestionAPI'){64512}else{31744})})"
    $i = 0
    foreach ($DeviceDetails in $DeviceDetailsJsonArr)
    {
        if ($DeviceDetails.Length -gt 0 )
        {
            $i++
            $MainDevice | Add-Member -MemberType NoteProperty -Name ("DeviceDetails" + $i.ToString() + "$(if($LogAPIMode -eq "LogIngestionAPI"){"_s"})") -Value $DeviceDetails -Force
        }
    }
    Write-CMTraceLog "Device details split into $i chunk(s)"

    if ($DeviceDetailsJson.Length -gt $(if ($LogAPIMode -eq "LogIngestionAPI")
            {
                10 * 63 * 1024
            }
            else
            {
                10 * 31 * 1024
            }))
    {
        $errorMsg = "DeviceDetails is too big and exceeds the $(if($LogAPIMode -eq 'LogIngestionAPI'){64}else{32})Kb limit per column for a single upload. Please increase number of columns (#10). Current payload size is: $(($DeviceDetailsJson.Length/1024).ToString('#.#')) Kb"
        Write-CMTraceLog $errorMsg -ErrorMsg
        throw $errorMsg
    }

    Write-CMTraceLog "Converting main device object to JSON for upload..."
    $DeviceJson = if ($LogAPIMode -eq "LogIngestionAPI")
    {
        "[$($MainDevice | ConvertTo-Json -Compress)]"
    }
    else
    {
        $MainDevice | ConvertTo-Json
    }
    Write-CMTraceLog "Final device JSON payload size: $($DeviceJson.Length) characters"

    # Submit the data to the API endpoint
    Write-CMTraceLog "Uploading device inventory to Log Analytics (Mode: $LogAPIMode)..."
    $ResponseDeviceInventory =
    if ($LogAPIMode -eq "LogIngestionAPI")
    {
        Write-CMTraceLog "Calling Send-LogIngestionAPI for device inventory..."
        Send-LogIngestionAPI -tenantId $TenantId -clientId $ClientId -clientSecret $ClientSecret -body ([System.Text.Encoding]::UTF8.GetBytes($DeviceJson)) -dceURI $DceURI -dcrImmutableId $DcrImmutableId -logType $DeviceLog
    }
    else
    {
        Write-CMTraceLog "Calling Send-DataCollectorAPI for device inventory..."
        Send-DataCollectorAPI -customerId $customerId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($DeviceJson)) -logType $DeviceLog
    }
    Write-CMTraceLog "Device inventory upload response: $ResponseDeviceInventory"
}
# end region DEVICEINVENTORY

# region APPINVENTORY
if ($CollectAppInventory)
{
    Write-CMTraceLog "========== Starting App Inventory Collection =========="
    #Set Name of Log
    $AppLog = "PowerStacksAppInventory$(if($LogAPIMode -eq "LogIngestionAPI"){"_CL"})"
    Write-CMTraceLog "App inventory log name: $AppLog"

    Write-CMTraceLog "Determining currently logged on user..."
    try
    {
        $CurrentLoggedOnUser = (Get-WmiObject -Class win32_computersystem -ErrorAction SilentlyContinue).UserName
        if ($null -eq $CurrentLoggedOnUser)
        {
            Write-CMTraceLog "No user from win32_computersystem, attempting to get from explorer.exe process..."
            $CurrentOwner = Get-CimInstance Win32_Process -Filter 'name = "explorer.exe"' -ErrorAction SilentlyContinue | Invoke-CimMethod -MethodName getowner
            $CurrentLoggedOnUser = "$($CurrentOwner.Domain)\$($CurrentOwner.User)"
        }
        Write-CMTraceLog "Current logged on user: $CurrentLoggedOnUser"
    }
    catch
    {
        Write-CMTraceLog "Error determining logged on user: $($_.Exception.Message)" -ErrorMsg
    }

    Write-CMTraceLog "Translating user account to SID..."
    $UserSid = $null
    try
    {
        $AdObj = New-Object System.Security.Principal.NTAccount($CurrentLoggedOnUser)
        $strSID = $AdObj.Translate([System.Security.Principal.SecurityIdentifier])
        $UserSid = $strSID.Value
        Write-CMTraceLog "User SID: $UserSid"
    }
    catch
    {
        # IdentityNotMappedException: the account can't be resolved to a SID (orphaned/renamed/deleted
        # account, a stale explorer.exe owner, or a name the local resolver doesn't know). This is not
        # fatal - fall back to matching the user's profile folder in the registry, and if that also
        # fails, continue with no user SID (Get-InstalledApplications then returns machine-scope apps
        # only, since it always scans the HKLM uninstall keys).
        Write-CMTraceLog "Could not translate '$CurrentLoggedOnUser' to a SID ($($_.Exception.Message)). Trying profile-list fallback..." -WarningMsg
        try
        {
            $userLeaf = ($CurrentLoggedOnUser -split '\\')[-1]
            $UserSid = Get-CimInstance Win32_UserProfile -ErrorAction Stop |
                Where-Object { -not $_.Special -and $_.LocalPath -and (Split-Path $_.LocalPath -Leaf) -ieq $userLeaf } |
                Select-Object -First 1 -ExpandProperty SID
            if ($UserSid)
            {
                Write-CMTraceLog "Resolved user SID from profile list: $UserSid"
            }
            else
            {
                Write-CMTraceLog "No matching user profile found; continuing without a user SID (machine-scope app inventory only)." -WarningMsg
            }
        }
        catch
        {
            Write-CMTraceLog "Profile-list SID fallback failed ($($_.Exception.Message)); continuing without a user SID." -WarningMsg
        }
    }

    # App Usage (software metering) runs only with $CollectAppMetering on. With it off, this section
    # runs exactly version 19's code. No App Usage failure stops or changes the inventory, and the
    # exit code is the inventory's (D28); App Usage's result goes in AppUsageCollectionStatus_s.
    $AUResult = $null
    if ($CollectAppMetering)
    {
        Write-CMTraceLog "App Usage is on, calling Invoke-AppUsage..."
        try
        {
            $AUResult = Invoke-AppUsage -RunId ([guid]::NewGuid().ToString()) -ComputerName $ComputerName
        }
        catch
        {
            Write-CMTraceLog "App Usage failed, so the inventory uses its own read: $(Get-AUSafeLogText $_.Exception.Message)" -ErrorMsg
            $AUResult = $null
        }
        if ($null -eq $AUResult -or $null -eq $AUResult.DeviceColumns)
        {
            try
            {
                $AUResult = New-AUFailedResult -RunId $(if ($AUResult) { $AUResult.RunId } else { '' }) -LogAPIMode $LogAPIMode -ScriptVersion $ScriptVersion
            }
            catch
            {
                Write-CMTraceLog "App Usage result could not be built: $(Get-AUSafeLogText $_.Exception.Message)" -ErrorMsg
                $AUResult = $null
            }
        }
        if ($AUResult)
        {
            Write-CMTraceLog "App Usage status: $($AUResult.Status)"
        }
    }

    if ($AUResult -and $null -ne $AUResult.InventoryApps)
    {
        # App Usage read every profile's apps (D20); its entries are version 19's, built the same way.
        $AppArray = @($AUResult.InventoryApps)
        Write-CMTraceLog "Using the App Usage all-profile app read: $($AppArray.Count) applications"
    }
    else
    {
        Write-CMTraceLog "Calling Get-InstalledApplications for Win32 apps..."
        $MyApps = Get-InstalledApplications -UserSid $UserSid
        Write-CMTraceLog "Retrieved $($MyApps.Count) Win32 applications"
        $MyApps | ForEach-Object { $_ | Add-Member -NotePropertyName AppType -NotePropertyValue 'Win32' -Force }

        if ($CollectUWPInventory)
        {
            Write-CMTraceLog "UWP inventory enabled, calling Get-AppxInstalledApplications..."
            $MyAppsAppx = Get-AppxInstalledApplications # Due to limitations of Get-AppxPackage on AADJ devices we don't use the SID
            Write-CMTraceLog "Retrieved $($MyAppsAppx.Count) UWP applications"
            $MyApps += $MyAppsAppx
            Write-CMTraceLog "Combined total: $($MyApps.Count) applications (Win32 + UWP)"
        }
        else
        {
            Write-CMTraceLog "UWP inventory disabled, skipping"
        }

        $AppArray = @(ConvertTo-AUAppArray -Apps $MyApps)
    }

    if ($AUResult)
    {
        # The usage fields on each entry; blank when App Usage has none for this run.
        try
        {
            Add-AUAppFields -AppArray $AppArray -AppFields $AUResult.AppFields
        }
        catch
        {
            Write-CMTraceLog "App Usage fields could not be added: $(Get-AUSafeLogText $_.Exception.Message)" -ErrorMsg
        }
    }

    Write-CMTraceLog 'Converting app array to JSON...'
    $InstalledAppJson = $AppArray | ConvertTo-Json
    Write-CMTraceLog "App inventory JSON size: $($InstalledAppJson.Length) characters"

    # With metering on, the run's rows go through the outbox and split runs (D44): one row when it
    # fits, more when it doesn't, so a large device never hits the 10-chunk limit below (F45).
    $AUInventorySent = $false
    if ($AUResult)
    {
        Write-CMTraceLog "Building the App Inventory rows with App Usage..."
        try
        {
            $MainApp = New-Object -TypeName PSObject
            $MainApp | Add-Member -MemberType NoteProperty -Name "ComputerName$(if($LogAPIMode -eq "LogIngestionAPI"){"_s"})" -Value "$ComputerName" -Force
            $MainApp | Add-Member -MemberType NoteProperty -Name "ManagedDeviceID$(if($LogAPIMode -eq "LogIngestionAPI"){"_g"})" -Value "$ManagedDeviceID" -Force
            foreach ($AUColumn in $AUResult.DeviceColumns.Keys)
            {
                $MainApp | Add-Member -MemberType NoteProperty -Name $AUColumn -Value $AUResult.DeviceColumns[$AUColumn] -Force
            }

            # Each row is sent with the inventory's own upload, and its retry, using the connection
            # settings above. A saved outbox row asks for one attempt with no backoff (SingleAttempt).
            # Ok: the success status the summary line checks. Permanent: the ingestion POST itself
            # rejected the row (400 or 413). The status comes only from that POST, never from the
            # token request, so an expired secret or a missing role never discards a row.
            $AUSender = {
                param ([byte[]]$Body, [string]$Mode, [string]$Type, [bool]$SingleAttempt)
                # The script's own preference, whatever the caller's, so a logging error never ends the send.
                $ErrorActionPreference = 'Continue'
                if ($SingleAttempt)
                {
                    # Invoke-LogSubmission reads this setting; this scope's copy holds for this call only.
                    $SubmissionMaxRetries = 0
                }
                $script:LastSubmissionStatusCode = $null
                $Code = $null
                $Response = ''
                try
                {
                    if ($Mode -eq "LogIngestionAPI")
                    {
                        $Response = Send-LogIngestionAPI -tenantId $TenantId -clientId $ClientId -clientSecret $ClientSecret -body $Body -dceURI $DceURI -dcrImmutableId $DcrImmutableId -logType $Type
                        # Set only by the DCR POST (Invoke-LogSubmission).
                        $Code = $script:LastSubmissionStatusCode
                    }
                    else
                    {
                        $Response = Send-DataCollectorAPI -customerId $customerId -sharedKey $sharedKey -body $Body -logType $Type
                    }
                }
                catch
                {
                    # The classic API has no token request, so its error response is the POST's.
                    if ($Mode -ne "LogIngestionAPI" -and $_.Exception.Response)
                    {
                        try
                        {
                            $Code = [int]$_.Exception.Response.StatusCode
                        }
                        catch
                        {
                        }
                    }
                    try { Write-CMTraceLog "App inventory row upload failed: $(Get-AUSafeLogText $_.Exception.Message)" -WarningMsg } catch { }
                }
                # The outcome is decided from the response before anything is logged, so a failed log line can't change it.
                $Ok = ("$Response" -match "^$(if($Mode -eq 'LogIngestionAPI'){204}else{200}) :")
                $Outcome = New-Object PSObject -Property @{ Ok = $Ok; Permanent = ((-not $Ok) -and (Test-AUPermanentStatus $Code)) }
                try { Write-CMTraceLog "App inventory row upload response: $Response" } catch { }
                $Outcome
            }

            $AUOutcome = Send-AUInventoryRun -MainColumns $MainApp -InstalledAppsJson $InstalledAppJson -ExeUsageJson (ConvertTo-AUExeUsageJson -ExeEntries $AUResult.ExeEntries) -StatusTokens $AUResult.StatusTokens -RunId $AUResult.RunId -OutboxDir $AUResult.OutboxPath -LogAPIMode $LogAPIMode -LogType $AppLog -Sender $AUSender
            $ResponseAppInventory = Format-AUInventoryResponse -Outcome $AUOutcome -LogAPIMode $LogAPIMode
            $AUInventorySent = $true
            Write-CMTraceLog "App inventory upload response: $ResponseAppInventory"
        }
        catch
        {
            Write-CMTraceLog "App Inventory rows could not be sent with App Usage, so the inventory uses its own upload: $(Get-AUSafeLogText $_.Exception.Message)" -ErrorMsg
        }
    }

    if (-not $AUInventorySent)
    {
        Write-CMTraceLog "Compressing app inventory JSON with GZip and splitting it into chunks..."
        try
        {
            $InstalledAppJsonArr = ConvertTo-AUChunks -Json $InstalledAppJson -ChunkSize $(if($LogAPIMode -eq 'LogIngestionAPI'){64512}else{31744})
            $InstalledAppBase64Length = 0
            foreach ($InstalledApp in $InstalledAppJsonArr) { $InstalledAppBase64Length += $InstalledApp.Length }
            Write-CMTraceLog "App inventory compressed successfully, Base64 size: $InstalledAppBase64Length characters"
        }
        catch
        {
            Write-CMTraceLog "Error compressing app inventory: $($_.Exception.Message)" -ErrorMsg
            throw
        }

        Write-CMTraceLog "Building main app upload object..."
        $MainApp = New-Object -TypeName PSObject
        $MainApp | Add-Member -MemberType NoteProperty -Name "ComputerName$(if($LogAPIMode -eq "LogIngestionAPI"){"_s"})" -Value "$ComputerName" -Force
        $MainApp | Add-Member -MemberType NoteProperty -Name "ManagedDeviceID$(if($LogAPIMode -eq "LogIngestionAPI"){"_g"})" -Value "$ManagedDeviceID" -Force

        Write-CMTraceLog "Adding app inventory chunks to the upload object..."
        $i = 0
        foreach ($InstalledApp in $InstalledAppJsonArr)
        {
            if ($InstalledApp.Length -gt 0 )
            {
                $i++
                $MainApp | Add-Member -MemberType NoteProperty -Name ("InstalledApps" + $i.ToString() + "$(if($LogAPIMode -eq "LogIngestionAPI"){"_s"})") -Value $InstalledApp -Force
            }
        }
        Write-CMTraceLog "App inventory split into $i chunk(s)"

        if ($InstalledAppBase64Length -gt $(if ($LogAPIMode -eq "LogIngestionAPI")
                {
                    10 * 63 * 1024
                }
                else
                {
                    10 * 31 * 1024
                }))
        {
            $errorMsg = "InstallApp is too big and exceed the $(if($LogAPIMode -eq 'LogIngestionAPI'){64}else{32})Kb limit per column for a single upload. Please increase number of columns (#10). Current payload size is: " + ($InstalledAppBase64Length / 1024).ToString("#.#") + "Kb"
            Write-CMTraceLog $errorMsg -ErrorMsg
            throw($errorMsg)
        }

        Write-CMTraceLog "Converting main app object to JSON for upload..."
        $AppJson = if ($LogAPIMode -eq "LogIngestionAPI")
        {
            "[$($MainApp | ConvertTo-Json -Compress)]"
        }
        else
        {
            $MainApp | ConvertTo-Json
        }
        Write-CMTraceLog "Final app JSON payload size: $($AppJson.Length) characters"

        # Submit the data to the API endpoint
        Write-CMTraceLog "Uploading app inventory to Log Analytics (Mode: $LogAPIMode)..."
        $ResponseAppInventory =
        if ($LogAPIMode -eq "LogIngestionAPI")
        {
            Write-CMTraceLog "Calling Send-LogIngestionAPI for app inventory..."
            Send-LogIngestionAPI -tenantId $TenantId -clientId $ClientId -clientSecret $ClientSecret -body ([System.Text.Encoding]::UTF8.GetBytes($AppJson)) -dceURI $DceURI -dcrImmutableId $DcrImmutableId -logType $AppLog
        }
        else
        {
            Write-CMTraceLog "Calling Send-DataCollectorAPI for app inventory..."
            Send-DataCollectorAPI -customerId $customerId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($AppJson)) -logType $AppLog
        }
        Write-CMTraceLog "App inventory upload response: $ResponseAppInventory"
    }
}
# end region APPINVENTORY



#region DRIVERINVENTORY
if ($CollectDriverInventory)
{
    Write-CMTraceLog "========== Starting Driver Inventory Collection =========="
    #Set Name of Log
    $DriverLog = "PowerStacksDriverInventory$(if($LogAPIMode -eq "LogIngestionAPI"){"_CL"})"
    Write-CMTraceLog "Driver inventory log name: $DriverLog"

    #get drivers
    Write-CMTraceLog "Calling Get-InstalledDrivers function..."
    $Drivers = Get-InstalledDrivers
    Write-CMTraceLog "Retrieved $($Drivers.Count) driver entries from Get-InstalledDrivers"

    Write-CMTraceLog "Building driver array for upload..."
    $DriverArray = @()
    foreach ($Driver in $Drivers)
    {
        $tempdriver = New-Object -TypeName PSObject
        $tempdriver | Add-Member -MemberType NoteProperty -Name "WUName" -Value $Driver.WUName -Force
        $tempdriver | Add-Member -MemberType NoteProperty -Name "DriverName" -Value $Driver.DriverName -Force
        $tempdriver | Add-Member -MemberType NoteProperty -Name "DriverVersion" -Value $Driver.DriverVersion -Force
        $tempdriver | Add-Member -MemberType NoteProperty -Name "DriverReleaseDate" -Value $Driver.DriverReleaseDate -Force
        $tempdriver | Add-Member -MemberType NoteProperty -Name "DriverClass" -Value $Driver.DriverClass -Force
        $tempdriver | Add-Member -MemberType NoteProperty -Name "DriverID" -Value $Driver.DriverID -Force
        $tempdriver | Add-Member -MemberType NoteProperty -Name "DriverHardwareID" -Value $Driver.DriverHardwareID -Force
        $tempdriver | Add-Member -MemberType NoteProperty -Name "DriverManufacturer" -Value $Driver.DriverManufacturer -Force
        $tempdriver | Add-Member -MemberType NoteProperty -Name "DriverInfName" -Value $Driver.DriverInfName -Force
        $tempdriver | Add-Member -MemberType NoteProperty -Name "DriverLocation" -Value $Driver.DriverLocation -Force
        $tempdriver | Add-Member -MemberType NoteProperty -Name "DriverDescription" -Value $Driver.DriverDescription -Force
        $tempdriver | Add-Member -MemberType NoteProperty -Name "DriverProvider" -Value $Driver.DriverProvider -Force
        $tempdriver | Add-Member -MemberType NoteProperty -Name "DriverPublishedOn" -Value $Driver.DriverPublishedOn -Force
        $tempdriver | Add-Member -MemberType NoteProperty -Name "DriverStatus" -Value $Driver.DriverStatus -Force
        $DriverArray += $tempdriver
    }
    Write-CMTraceLog "Built driver array with $($DriverArray.Count) drivers"

    Write-CMTraceLog "Converting driver array to JSON..."
    $ListedDriverJson = $DriverArray | ConvertTo-Json
    Write-CMTraceLog "Driver inventory JSON size: $($ListedDriverJson.Length) characters"

    Write-CMTraceLog "Compressing driver inventory JSON with GZip..."
    try
    {
        $ms = New-Object System.IO.MemoryStream
        $cs = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Compress)
        $sw = New-Object System.IO.StreamWriter($cs)
        $sw.Write($ListedDriverJson)
        $sw.Close();
        $ListedDriverJson = [System.Convert]::ToBase64String($ms.ToArray())
        Write-CMTraceLog "Driver inventory compressed successfully, Base64 size: $($ListedDriverJson.Length) characters"
    }
    catch
    {
        Write-CMTraceLog "Error compressing driver inventory: $($_.Exception.Message)" -ErrorMsg
        throw
    }

    Write-CMTraceLog "Building main driver upload object..."
    $MainDriver = New-Object -TypeName PSObject
    $MainDriver | Add-Member -MemberType NoteProperty -Name "ComputerName$(if($LogAPIMode -eq "LogIngestionAPI"){"_s"})" -Value "$ComputerName" -Force
    $MainDriver | Add-Member -MemberType NoteProperty -Name "ManagedDeviceID$(if($LogAPIMode -eq "LogIngestionAPI"){"_g"})" -Value "$ManagedDeviceID" -Force

    Write-CMTraceLog "Splitting driver inventory into chunks..."
    $ListedDriverJsonArr = $ListedDriverJson -split "(.{$(if($LogAPIMode -eq 'LogIngestionAPI'){64512}else{31744})})"
    $i = 0
    foreach ($ListedDriver in $ListedDriverJsonArr)
    {
        if ($ListedDriver.Length -gt 0 )
        {
            $i++
            $MainDriver | Add-Member -MemberType NoteProperty -Name ("ListedDrivers" + $i.ToString() + "$(if($LogAPIMode -eq "LogIngestionAPI"){"_s"})") -Value $ListedDriver -Force
        }
    }
    Write-CMTraceLog "Driver inventory split into $i chunk(s)"

    if ($ListedDriverJson.Length -gt $(if ($LogAPIMode -eq "LogIngestionAPI")
            {
                10 * 63 * 1024
            }
            else
            {
                10 * 31 * 1024
            }))
    {
        $errorMsg = "Driver is too big and exceed the $(if($LogAPIMode -eq 'LogIngestionAPI'){64}else{32})Kb limit per column for a single upload. Please increase number of columns (#10). Current payload size is: " + ($ListedDriverJson.Length / 1024).ToString("#.#") + "Kb"
        Write-CMTraceLog $errorMsg -ErrorMsg
        throw($errorMsg)
    }

    Write-CMTraceLog "Converting main driver object to JSON for upload..."
    $DriverJson = if ($LogAPIMode -eq "LogIngestionAPI")
    {
        "[$($MainDriver | ConvertTo-Json -Compress)]"
    }
    else
    {
        $MainDriver | ConvertTo-Json
    }
    Write-CMTraceLog "Final driver JSON payload size: $($DriverJson.Length) characters"

    # Submit the data to the API endpoint
    Write-CMTraceLog "Uploading driver inventory to Log Analytics (Mode: $LogAPIMode)..."
    $ResponseDriverInventory =
    if ($LogAPIMode -eq "LogIngestionAPI")
    {
        Write-CMTraceLog "Calling Send-LogIngestionAPI for driver inventory..."
        Send-LogIngestionAPI -tenantId $TenantId -clientId $ClientId -clientSecret $ClientSecret -body ([System.Text.Encoding]::UTF8.GetBytes($DriverJson)) -dceURI $DceURI -dcrImmutableId $DcrImmutableId -logType $DriverLog
    }
    else
    {
        Write-CMTraceLog "Calling Send-DataCollectorAPI for driver inventory..."
        Send-DataCollectorAPI -customerId $customerId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($DriverJson)) -logType $DriverLog
    }
    Write-CMTraceLog "Driver inventory upload response: $ResponseDriverInventory"
}
#endregion DRIVERINVENTORY

# Report back status
Write-CMTraceLog "========== Generating Final Status Report =========="
$date = (Get-Date).ToUniversalTime().ToString($InventoryDateFormat)
$OutputMessage = "InventoryDate: $date "

if ($CollectDeviceInventory)
{
    Write-CMTraceLog "Checking device inventory upload status..."
    if ($ResponseDeviceInventory -match "$(if($LogAPIMode -eq 'LogIngestionAPI'){204}else{200}) :")
    {
        $OutputMessage = $OutPutMessage + "DeviceInventory: OK " + $ResponseDeviceInventory
        Write-CMTraceLog "Device inventory upload: SUCCESS"
    }
    else
    {
        $OutputMessage = $OutPutMessage + "DeviceInventory: Fail "
        Write-CMTraceLog "Device inventory upload: FAILED" -ErrorMsg
    }
}
if ($CollectAppInventory)
{
    Write-CMTraceLog "Checking app inventory upload status..."
    if ($ResponseAppInventory -match "$(if($LogAPIMode -eq 'LogIngestionAPI'){204}else{200}) :")
    {
        $OutputMessage = $OutPutMessage + " AppInventory: OK " + $ResponseAppInventory
        Write-CMTraceLog "App inventory upload: SUCCESS"
    }
    else
    {
        $OutputMessage = $OutPutMessage + " AppInventory: Fail "
        Write-CMTraceLog "App inventory upload: FAILED" -ErrorMsg
    }
}
if ($CollectDriverInventory)
{
    Write-CMTraceLog "Checking driver inventory upload status..."
    if ($ResponseDriverInventory -match "$(if($LogAPIMode -eq 'LogIngestionAPI'){204}else{200}) :")
    {
        $OutputMessage = $OutPutMessage + " DriverInventory: OK " + $ResponseDriverInventory
        Write-CMTraceLog "Driver inventory upload: SUCCESS"
    }
    else
    {
        $OutputMessage = $OutPutMessage + " DriverInventory: Fail "
        Write-CMTraceLog "Driver inventory upload: FAILED" -ErrorMsg
    }
}

Write-CMTraceLog "========== Script Execution Completed =========="
Write-CMTraceLog $OutputMessage

if ($Transcribe)
{
    Stop-Transcript | Out-Null
}

# The script's only console output: one line with each upload's result and payload size.
# Intune shows it in the detection output column. Everything else is in the log file.
Write-Output $OutputMessage
#endregion script

