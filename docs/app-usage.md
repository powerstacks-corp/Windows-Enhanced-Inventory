# App Usage

App Usage (software metering) records which installed apps people actually use, from the Windows System Resource Usage Monitor (SRUM). It's off by default. To turn it on, set `$CollectAppMetering = $true` in `Intune_Windows_Inventory.ps1`.

## Usage History on the Device

SRUM keeps only about 30 to 60 days of usage, so the script keeps its own history on each device, in `C:\Windows\AppUsage_<Serial>.json`. `<Serial>` is the device's serial number, with any character that isn't allowed in a file name replaced by `_`. When the device reports no serial number, the computer name is used instead. The file holds each user's usage of each executable build. Each run adds the usage SRUM recorded since the last run. SRUM records the script has already counted add nothing when they're read again, and usage moves into the history once SRUM drops it, so the history outlasts SRUM.

- Only SYSTEM and administrators can read or change the file, because it holds every user's activity on the device. Standard users can't open it.
- The script writes a new copy of the file to disk and then swaps it in, so a run that stops partway, or a power loss, leaves the earlier file in place.
- If the file can't be read, the script never overwrites it. It renames the file to `AppUsage_<Serial>.corrupt-<yyyyMMddHHmmss>.json`, with the time in UTC, starts a new history from what SRUM still holds, and reports `LedgerReset`. The renamed copy can also be read only by SYSTEM and administrators.
- An app update brings a new build of its executable. Once SRUM holds no usage of the old build, the script combines the old build's history into a newer build of the same app for the same user. It combines builds only when both are matched to the same app, or, for unmatched builds, when the script verified both builds and they have the same company and product names. Executables that only share a file name, such as two `setup.exe` files from different publishers, are never combined.

## Installed Apps and Profiles

App Usage reads the installed apps of every profile on the device, not only the signed-in user's:

- **Profiles:** every profile Windows lists in `ProfileList` (`HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList`), signed in or not. Apps come from signed-in and signed-out users, plus SYSTEM's own per-user installs, which deployment tools often make. Per-user installs under the LocalService and NetworkService accounts aren't listed, because those aren't anyone's profile.
- **Signed-in users:** their apps are read from their loaded registry hive.
- **Signed-out users:** the script copies the user's `NTUSER.DAT` from a shadow copy of the system drive into a folder that only SYSTEM and administrators can open, reads the copy, and deletes it. It never opens a user's live hive file, so a user who signs in during the run isn't affected.
- **Apps:** the uninstall entries (the apps in **Installed apps** or **Programs and Features**) of the device, 64-bit and 32-bit, and of each profile. Store and MSIX apps are included only when `$CollectUWPInventory` is `$true`, the same setting the App Inventory uses. Windows Installer records tell the script which installed app an executable belongs to; they never add an app to the inventory.

A profile the script can't read is a coverage gap, never a reason to call an app missing. That's a profile whose folder isn't on the device (for example, a profile container or roaming profile that isn't attached), or a signed-out user whose hive couldn't be copied or loaded. Apps in that profile are never `NotInstalled`, and their usage status stays blank. Unread profiles are counted in the App Usage device columns and the collection status.

### The Expanded App Inventory

When App Usage is on, the App Inventory data lists the installed apps of every profile the script read. A device can report more apps than before, mostly per-user installs of users who aren't signed in. Entries are still combined into one per DisplayName, with the newest version, by the same code as before, and they carry no user. When App Usage is off, the App Inventory is read exactly as before: the device's apps and the signed-in user's apps. If the all-profile read fails on a run, that run's App Inventory falls back to the earlier read.

## What App Usage Reports

App Usage adds usage fields to each app in the App Inventory data (`PowerStacksAppInventory_CL`), and sends a list of the executables it has seen. Both combine every user on the device: they count users, and never name them. Who used what stays in the history file on the device.

### How Use Is Counted

An executable's run counts as use only when a person used it:

- The account that ran it is a person's account: a Microsoft Entra ID, domain, or local user account. Runs under SYSTEM or a service account never count as use, only as runs.
- The executable had focus or keyboard and mouse input for at least `$MinFocusSecondsForUse` seconds (1 by default).
- A command-line tool (role `CLI`) counts on any run by a person, even with no focus, because the focus goes to the terminal window. Its last-used date is the end of that run.

A run with no focus or input, such as a background process, counts as a run, not as use. Use is worked out again from the history on every run, so a new rule, or a role that changes, applies to past usage too.

### Usage Fields on Each Installed App

The App Inventory data keeps one entry for each DisplayName, with the newest version, as before. App Usage adds these fields to each entry, combined across every user on the device:

| Field | Meaning |
|---|---|
| `AppLastUsedDate` | The latest use by any user, in UTC, formatted `yyyy-MM-ddTHH:mm:ss.fffffffZ`. Blank when nobody used it. |
| `AppUsageStatus` | Whether the app is used. See [Usage Status](#usage-status). |
| `AppLastRanDate` | The latest run of any kind, by any account, including background runs. Same format. |
| `AppInFocusSeconds` | Total focus time under people's accounts, in whole seconds. Focus under SYSTEM or a service account isn't counted. |
| `AppUsersWithUse` | How many users used the app. A count, not names. |
| `AppMatchedExeCount` | How many of the app's executables App Usage has seen. |
| `AppRunsAsService` | `true` when one of the app's executables is the program of a Windows service, or has the `Service` role. Don't treat these apps as unused only because nobody focused them. |

When App Usage is off, or fails on a run, these fields are blank. An executable that an ignore rule matches doesn't count toward any of them.

### Usage Status

`AppUsageStatus` is one of these values. When more than one applies, the first in the table wins.

| Value | Meaning |
|---|---|
| `Used` | Someone used one of the app's executables since the device's watching-since date, the earliest usage App Usage has for the device. |
| `RanNotUsed` | One of the app's executables ran since then, but nobody used it: for example, it ran only in the background or only under SYSTEM. Not a reclamation candidate on its own. |
| `Ambiguous` | Nothing is credited to the app, but an executable that might be the app's ran: one that could belong to it or to another app (see [When a Rule Matches Several Installed Apps](#when-a-rule-matches-several-installed-apps)), or an unmatched executable with the name of one of the app's known executables, for example a build the script couldn't verify. Not a reclamation candidate. |
| `NotUsed` | App Usage knows the app's executables, and none of them ran since the watching-since date, whether matched to the app or not. The only value that marks a reclamation candidate. |
| `NotCovered` | App Usage knows no executable for the app, so it can't measure its use. |
| Blank | App Usage didn't run or failed on this run, the watching-since date isn't known yet, or the script couldn't read every place the app is installed (the device's apps, or a user's apps). Blank never means `NotUsed`. |

App Usage knows an app's executables when Windows Installer lists them as part of the app, when an identity rule whose target matches the app names them in `when.exeName` (a pattern such as `contoso*.exe` covers every name it matches), or when it has seen one of them run and matched it to the app. An executable matched to a different app doesn't count as a run of this one.

### Executable Usage

App Usage also sends one entry for each executable build it has seen and each app the build is matched to, with every user combined. Every executable is listed: matched or unmatched, installed or not, and the ones ignore rules match.

| Field | Meaning |
|---|---|
| `ExeInfo` | The executable build, as SRUM records it. For a Store or MSIX app, its package name. |
| `ExeName` | The file name, in lowercase. Blank for a Store or MSIX app. |
| `RunPath` | The path the build ran from, when the script found it and confirmed it's the same build. |
| `LocationClass` | The kind of folder it ran from: `Windows`, `ProgramFiles`, `UserProfile`, `Temp`, `Download`, `ManagementCache`, or `Other`. |
| `FileDescription`, `FileProductName`, `FileCompanyName`, `FileVersion`, `ProductVersion` | The build's file details. Only when the script verified the build (`FactsVerified` is `true`); blank otherwise. |
| `FactsVerified` | `true` when the file on disk is the build that ran. |
| `EvidenceCompanyName`, `EvidenceProductName`, `EvidenceSource` | For a build the script couldn't verify: the company and product names of the file now at the same path, with `EvidenceSource` set to `CurrentFileAtPath`. They can match the executable to an app, but they aren't the build's own details. Blank for a verified build. |
| `Subsystem` | Whether it's a console (command-line) or graphical program, when the script could tell. |
| `Role` | The kind of executable it is. See [Role](#role). |
| `ClassificationRuleId` | The ID of the ignore rule that matched it, or else of the classification rule that set its role. Blank when neither did. |
| `ResolvedAppName` | The DisplayName of the installed app it's matched to, or of the app it was last matched to when that app is no longer installed. |
| `TargetPattern`, `Publisher` | The name and publisher patterns of the target it's matched to. |
| `ProductCode` | The target app's Windows Installer product code, or its package family for a Store or MSIX app. |
| `MatchSection` | `Customer` (one of your rules), `PowerStacks`, `Retained` (a target saved from an earlier run), or `None`. |
| `MatchRuleId` | The ID of the rule that matched it. |
| `InstallStatus` | Whether the target app is installed. See [Install Status](#install-status). With several users, it's `Installed` when the app is installed for any of them, else `Unknown` when any of them is unknown, else `NotInstalled`. |
| `FirstSeen` | The first time App Usage saw the build run, in UTC. |
| `LastUsedTime` | The latest use by any user, in UTC. |
| `LastRanTime` | The latest run of any kind, in UTC. |
| `InFocusSeconds` | Total focus time under people's accounts, in whole seconds. Focus under SYSTEM or a service account isn't counted. |
| `UsersWithUse` | How many users used it. A count, not names. |
| `RanAsSystemOnly` | `true` when it ran, and every run was under SYSTEM or a service account. |
| `CandidateTargets` | Only for an executable left unmatched with two or more candidate apps: the DisplayNames of those apps. Absent otherwise. |

### How the Data Is Sent

When App Usage is on, every run gets a run ID, and every App Inventory row it sends carries three more columns:

| Column | Meaning |
|---|---|
| `RunId_g` | A GUID, one per run. Every row of the run has the same one. |
| `RowIndex_d` | This row's position in the run, from 1. |
| `RowCount_d` | How many rows the run sent. |

The installed apps (`InstalledApps1_s` to `InstalledApps10_s`) and the executable list (`ExeUsage1_s` to `ExeUsage10_s`) are each compressed and cut into pieces of 64,512 characters (31,744 with the classic Data Collector API), the way the App Inventory has always cut the installed apps.

- **One row when it fits.** When the whole row is at most 943,718 bytes, the script's upload limit, which is just under the 1 MB the Logs Ingestion API accepts in one call, and each list fits in 10 pieces, the run sends one row, with `RowIndex_d` and `RowCount_d` both `1`. That's nearly every device.
- **A split run when it doesn't.** A large device, such as a shared PC or a multi-session host, sends its run as several rows of the same table, each in its own call. Row 1 has every column the App Inventory sends, the App Usage device columns, and as many pieces as fit. Rows 2 and on have only `ComputerName_s`, `ManagedDeviceID_g`, the three run columns, and the remaining pieces. Pieces fill in order, installed apps first, then executables, and each row numbers its pieces from 1, up to 10 for each list.

To rebuild a list, take its pieces from every row of the run, ordered by `RowIndex_d` and then by column number, join them, and decode them as before. A run is complete when all `RowCount_d` rows with its `RunId_g` are present. Reports use each device's latest complete run and never show part of a run. Rows 2 and on aren't devices, so a query that takes each device's latest row has to take its latest complete run instead.

Turning App Usage on requires the BI for Intune release that reads split runs. When App Usage is off, the script sends exactly the row it always sent, with no run columns.

### Rows That Fail to Send

Each row gets the script's usual upload retries. A row that still fails is saved on the device, in `C:\Windows\AppUsage_<Serial>_outbox\`, next to the usage history and with the same `<Serial>`, as `<RunId>-<RowIndex>.json`. The next run sends it first, unchanged.

- Only SYSTEM and administrators can open the folder and its files, because the rows hold usage data. If something else is at that path, such as a link, a folder owned by another account, or a folder other users can open, the script never reads, sends, or deletes anything there, and saves nothing to it. To fix that, delete the folder as an administrator; the next run that needs it creates it again.
- Each run sends the saved rows first, oldest run first, and then its own rows, so the rows arrive in run order.
- A run spends one round of retries in total. Once a row still fails after its retries, every row left to send, saved or new, waits in the folder for the next run. A network or service outage costs one round of retries, not one for each row.
- The folder keeps the rows of the 5 most recent runs. Once every row of a newer run is sent, the saved rows of older runs are deleted, because the newer run replaces them.
- While rows wait, row 1's `AppUsageCollectionStatus_s` includes `PendingRows`. The status is set after the saved rows are sent, so a run that empties the folder doesn't report it.
- When App Usage is off, the folder stays on the device and its rows aren't sent.

## Mapping Rules

App Usage sees executables, not apps. Mapping rules decide which installed app each executable belongs to, and what kind of executable it is. Rules come from two files:

| File | Owner | Where it lives |
|---|---|---|
| `powerstacks-mappings.json` | PowerStacks | Built into the `Intune_Windows_Inventory.ps1` we publish. Each release replaces it. You don't edit it or deploy it. |
| `customer-mappings.json` | You | Optional. You put it on devices yourself, at the path in `$AppUsageCustomerMappingsPath`. |

PowerStacks never reads, writes, or ships a file named `customer-mappings.json`, so a PowerStacks update can't change or break your rules. The script only reads your file. It parses the file as JSON data and never runs anything in it.

Because your rules aren't in the script, changing them doesn't change the script. If you sign the script, you don't need to sign it again after a rule change.

### How Rules Are Applied

Your rules always win. For each executable, the script tries, in this order:

1. Your identity rules.
1. A target that one of your rules matched on an earlier run, if that rule still exists.
1. PowerStacks identity rules.
1. A target that a PowerStacks rule matched on an earlier run, if that rule still exists.
1. Otherwise, the executable is reported as unmatched.

Within each file, the first rule that matches wins, so put narrower rules before broader ones.

Classification and ignore rules then run on every executable, matched or not, again with your rules first. For an executable that one of your identity rules matched, PowerStacks classification and ignore rules are skipped, and only yours apply.

One limit applies to every rule: it has to match. A rule with a version range (`versionMin` or `versionMax`) matches only a build whose file facts the script verified. When the script can't verify the build that ran, a version-range rule doesn't match it, and matching moves on to the next rule.

### When a Rule Matches Several Installed Apps

The rule that wins sets the app's name pattern, and the installed apps that pattern matches are the candidates. Usually there's one, and the executable is matched to it. When there are several, for example a `Contoso*` target on a device with Contoso Alpha and Contoso Beta installed, the script narrows the list with what it knows about the executable. It applies these checks in order and stops as soon as one app is left:

| Check | Keeps the app whose | Rule ID for a PowerStacks match |
|---|---|---|
| Install path | Install folder holds the executable. When several do, the deepest folder wins. | `ps-resolve-path` |
| Windows Installer | Windows Installer product owns the executable. Verified builds only. | `ps-resolve-msi` |
| Publisher | Publisher equals the executable's publisher, ignoring case, spaces, and suffixes such as Inc. and Corporation. | `ps-resolve-publisher` |
| Product name | Name equals the executable's ProductName or FileDescription, ignoring versions and tags such as (64-bit). | `ps-resolve-product` |
| Version | Version shares its first two parts with the executable's FileVersion or ProductVersion. Verified builds only. | `ps-resolve-version` |
| Architecture | Entry is 32-bit, for an executable under `Program Files (x86)`, or 64-bit, for one under `Program Files`. | `ps-resolve-arch` |
| Install scope | Per-user install belongs to the user who ran the executable from their own profile. | `ps-resolve-scope` |

A check that has nothing to go on, or that would rule out every app, is skipped. When a check leaves one app, the executable is matched to it. If the candidates came from one of your rules, your rule's ID is reported, so if you delete the rule, the executable is matched again from the rules that remain. If they came from PowerStacks rules, the check's ID is reported as the rule ID.

When two or more apps are left after every check, the executable is reported as unmatched, and `CandidateTargets` lists the apps it could belong to. Those apps aren't reported as unused because of it: when the executable runs, an app among them with no use or runs of its own is reported as `Ambiguous`. To settle it yourself, give your rule a narrower `target.displayName`.

### Targets From Earlier Runs

When a rule matches an executable, the script saves the target (the installed app, the rule ID, and whose rule it was) with the executable's usage on the device. The saved target keeps the executable matched after the evidence for the match is gone, for example after the app is uninstalled, so its usage stays credited to the app and the app can be reported as not installed.

- A saved target is used only while its rule exists. If you delete a rule, the executables it matched are matched again from the remaining rules on the next run. The `ps-resolve-` rule IDs always exist.
- A saved target from one of your rules wins over every PowerStacks match.
- Your identity rules replace a saved PowerStacks target, even when the script couldn't verify the build that ran.
- A PowerStacks match replaces a saved PowerStacks target only when the script verified the build. A match on the current file at the same path, for a build the script couldn't verify, doesn't replace it, and the conflict is written to the script's log.

### Install Status

Each executable's usage reports an `InstallStatus` for its target:

| Value | Meaning |
|---|---|
| `Installed` | The target app is installed on the device, either for all users or for the user who ran the executable. An updated app still counts. |
| `NotInstalled` | The script read the device's apps and the user's apps on this run, and the target app isn't there. Also used when the user's profile is no longer on the device. |
| `Unknown` | The target is known, but the script couldn't read the device's apps or the user's apps on this run. |
| `Unmatched` | No rule matched the executable, and it has no target from an earlier run. |

An executable whose app was uninstalled stays matched to it, and its usage is still recorded. `NotInstalled` says only that the app isn't installed now. It doesn't say when or why the app was removed.

### Role

Each executable's usage reports a `Role`, the kind of executable it is. The first one that applies, in this order, is the role:

| Role | When |
|---|---|
| `Installer` | It ran from a `Temp`, `Download`, or `ManagementCache` location. This beats every classification rule. |
| The rule's role | A classification rule matched it. The role is `Windows`, `Installer`, `Helper`, `Service`, or `CLI`. |
| `Service` | It's the program of a Windows service on the device. |
| `CLI` | It's a console (command-line) program. |
| `App` | It's matched to an app, and it's the app's main executable. |
| `Helper` | It's matched to an app, and it isn't the app's main executable. |
| `Unmatched` | It isn't matched to an app. |

An executable is the app's main executable when an identity rule matched it, through its `exeName`, or when its path is the file in the app's **DisplayIcon** uninstall value and the script verified the build. A Store or MSIX app is its own main executable, so a matched one is `App`. Every executable an identity rule matches is a main executable, so with a pattern such as `contoso*.exe`, add a classification rule with the `Helper` role for the ones that aren't.

An executable that's matched to an app stays `App` or `Helper` after the app is uninstalled. There's no role for SYSTEM: who ran an executable doesn't change its role.

### File Format

```json
{
  "schemaVersion": 1,
  "customer": {
    "identityRules": [],
    "classificationRules": []
  }
}
```

- `schemaVersion` is `1`.
- `identityRules` holds rules of type `identity`. They map an executable to an installed app.
- `classificationRules` holds rules of type `classification` and `ignore`. They describe the executable itself.
- Every rule has an `id` and a `type`, and can have a `description` for your own notes.

#### Rule IDs

- Your rule IDs start with `c-`, for example `c-timesheets-1`. PowerStacks rule IDs start with `ps-`.
- Each ID is used once in the file. Case doesn't count, so `c-App-1` and `c-app-1` are the same ID.
- IDs use only letters, digits, `.`, `_`, and `-`.
- IDs that start with `ps-resolve-` are reserved.

Rule IDs are reported with each executable's usage, so keep an ID when you edit its rule, and use a new ID for a new rule.

#### Patterns

Text conditions are wildcard patterns, the same as the PowerShell `-like` operator, and they ignore case. `*` matches any characters, `?` matches one character, and `[a-c]` matches one character in a range. They aren't regular expressions. For example, `7-Zip*` matches `7-Zip 24.08 (x64)`. Use patterns for app names that include a version, so a rule keeps working after an update.

#### Identity Rules

| Field | Required | Matches |
|---|---|---|
| `when.exeName` | Yes | The executable's file name, for example `contoso*.exe`. |
| `when.publisher` | Yes | The file's publisher (CompanyName in its file info). Use `""` for an executable with no publisher, which is common for in-house apps. |
| `when.productName` | No | The file's ProductName. |
| `when.fileDescription` | No | The file's FileDescription. |
| `when.versionMin`, `when.versionMax` | No | A version range for the build, for example `8.0` to `8.99`. Each bound compares only as many parts as it has, so `8.99` includes 8.99.1 and `8` includes 8.0.0. The build matches when its FileVersion or its ProductVersion is in the range. Matches verified builds only. |
| `target.displayName` | Yes | The installed app's name in **Installed apps** (its uninstall entry DisplayName). |
| `target.publisher` | Yes | The installed app's publisher. `""` is allowed. |

A rule matches only when every condition it has matches. An identity rule still matches when the app isn't installed, so usage of an app that was removed stays credited to it.

When the script can't verify the build that ran, it uses the publisher and product name of the file at the same path now, and reports the match as unverified. That can satisfy `exeName`, `publisher`, and `productName`, but never `fileDescription`, `versionMin`, or `versionMax`. When the publisher isn't known at all, no identity rule matches, including one with `"publisher": ""`.

#### Classification Rules

| Field | Required | Value |
|---|---|---|
| `when` | Yes | One or more of `exeName`, `companyName`, `fileDescription`, and `locationClass`. Every condition you give must match. |
| `role` | Yes | `Windows`, `Installer`, `Helper`, `Service`, or `CLI`. |

`locationClass` is where the executable ran from: `Windows`, `ProgramFiles`, `UserProfile`, `Temp`, `Download`, `ManagementCache` (the Intune and Configuration Manager cache folders), or `Other`. A `Temp` or `Downloads` folder counts as `Temp` or `Download` wherever it is, including under the Windows folder or a user profile.

`exeName` and `locationClass` always apply. `companyName` and `fileDescription` match only a build whose file facts the script verified.

#### Ignore Rules

An ignore rule has the same `when` conditions as a classification rule and no `role`. It marks an executable that isn't an app, such as a kiosk shell. The executable's usage is still recorded, but it doesn't make an app count as used, and it isn't counted as unmatched.

The validator rejects any field it doesn't know, so a misspelled condition can't quietly make a rule match more than you meant.

### Examples

`customer-mappings.example.json`, published with the script, has these examples ready to copy.

An in-house app whose executable has no publisher:

```json
{
  "id": "c-timesheets-1",
  "type": "identity",
  "when": { "exeName": "contosotimesheets.exe", "publisher": "" },
  "target": { "displayName": "Contoso Timesheets*", "publisher": "Contoso*" }
}
```

An app that PowerStacks rules match to the wrong installed app. Your rule wins:

```json
{
  "id": "c-designer-1",
  "type": "identity",
  "when": { "exeName": "designer.exe", "publisher": "Fabrikam*" },
  "target": { "displayName": "Fabrikam Designer*", "publisher": "Fabrikam*" }
}
```

An executable to ignore:

```json
{
  "id": "c-ignore-kiosk-1",
  "type": "ignore",
  "when": { "exeName": "contosokiosk.exe" }
}
```

### Validate the File

Check the file before you deploy it. `Test-AppUsageMappings.ps1` is published with the script. Keep it in the same folder as the `Intune_Windows_Inventory.ps1` you deploy, and run:

```powershell
.\Test-AppUsageMappings.ps1 -Path .\customer-mappings.json
```

The validator reads the file the same way devices do and uses the validation rules from the inventory script next to it. To use an inventory script in another folder, add `-InventoryScriptPath`. The validator only reads; it never changes your file.

| Exit code | Meaning |
|---|---|
| `0` | The file is valid. The validator prints its SHA-256, the value devices report in `CustomerMappingsHash_s`. |
| `1` | The file is missing, larger than 1 MB, isn't valid JSON, or has rule errors. Each error names its rule ID. |
| `2` | The inventory script wasn't found, or it's an older version without App Usage. |

### Deploy the File to Devices

The script looks for your file at `$AppUsageCustomerMappingsPath`, which defaults to `C:\ProgramData\PowerStacks\AppUsage\customer-mappings.json`. To use another path, change that setting in the script.

- The file has no permission requirement. The script uses any valid file of up to 1 MB at that path, whoever owns it. Anyone who can write the file can change how usage on that device is matched; `CustomerMappingsHash_s` shows any device whose file differs from the one you deployed.
- The path must be a local drive path, and neither the file nor any folder above it can be a junction, symbolic link, or other reparse point; otherwise the script ignores the file as invalid and reports `InvalidCustomerMappings:UnsafePath` or `InvalidCustomerMappings:ReparsePoint`, so no user can redirect what the SYSTEM account opens.
- Save the file as UTF-8. UTF-16 with a byte order mark, which Windows PowerShell `Out-File` writes, also works.
- Devices use a new file on their next inventory run.

You can deliver the file however you like: an Intune Win32 app, an Intune remediation, Configuration Manager, Group Policy, or a file copy. Two Intune examples follow. In both, replace `<SHA-256>` with the value the validator printed.

#### Intune Win32 App

1. Put `customer-mappings.json` and this `Install-CustomerMappings.ps1` in one folder, and package the folder with the Microsoft Win32 Content Prep Tool.

    ```powershell
    $Folder = 'C:\ProgramData\PowerStacks\AppUsage'
    New-Item -ItemType Directory -Path $Folder -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'customer-mappings.json') -Destination (Join-Path $Folder 'customer-mappings.json') -Force
    exit 0
    ```

1. Create the Win32 app with these settings:
    - **Install command:** `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-CustomerMappings.ps1`
    - **Uninstall command:** `powershell.exe -NoProfile -Command "Remove-Item -LiteralPath 'C:\ProgramData\PowerStacks\AppUsage\customer-mappings.json' -Force"`
    - **Install behavior:** System
    - **Detection rules:** a custom detection script:

        ```powershell
        $Path = 'C:\ProgramData\PowerStacks\AppUsage\customer-mappings.json'
        $Expected = '<SHA-256>'
        if ((Test-Path -LiteralPath $Path) -and (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $Expected) { Write-Output 'Installed' }
        exit 0
        ```

1. When you change the file, update the package and the hash in the detection script.

#### Intune Remediation

The remediation script carries the file as Base64, so it writes exactly the bytes you validated. To get the Base64 text, run:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes('.\customer-mappings.json'))
```

Detection script:

```powershell
$Path = 'C:\ProgramData\PowerStacks\AppUsage\customer-mappings.json'
$Expected = '<SHA-256>'
if (-not (Test-Path -LiteralPath $Path) -or (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Expected)
{
    Write-Output 'Customer mappings missing or out of date'
    exit 1
}
Write-Output 'Customer mappings current'
exit 0
```

Remediation script:

```powershell
$Folder = 'C:\ProgramData\PowerStacks\AppUsage'
$Bytes = [Convert]::FromBase64String('<Base64 text>')
New-Item -ItemType Directory -Path $Folder -Force | Out-Null
[IO.File]::WriteAllBytes((Join-Path $Folder 'customer-mappings.json'), $Bytes)
exit 0
```

Run both scripts in 64-bit PowerShell, and leave **Run this script using the logged-on credentials** set to **No**. A remediation script has a size limit, so for a large file, use a Win32 app.

### When the File Is Absent or Invalid

A missing or invalid file never stops inventory collection.

- **Absent:** the run uses PowerStacks rules only. Executables that your rules matched before are matched again from PowerStacks rules on that run. The run reports `CustomerMappingsAbsent`, and `CustomerMappingsHash_s` is blank, so a delivery that didn't arrive shows in reports.
- **Invalid or larger than 1 MB:** the script ignores the whole file for that run; it never uses part of a file. Executables that already have a target keep it, including targets from your rules, so a typo doesn't move apps back to PowerStacks matches. New executables match on PowerStacks rules until a valid file arrives. The run reports `InvalidCustomerMappings`, and `CustomerMappingsHash_s` is blank.

Usage keeps accumulating either way.

### Check Which Rules Reached Devices

Each run reports the SHA-256 of the customer file it used in `CustomerMappingsHash_s` (blank when the file was absent or invalid), and the PowerStacks rules version in `MappingsVersion_s`. Compare the hash with the one the validator printed, or with `(Get-FileHash .\customer-mappings.json).Hash`. To count devices by the file they use:

```kusto
PowerStacksAppInventory_CL
| where TimeGenerated > ago(2d)
| summarize Devices = dcount(ComputerName_s) by CustomerMappingsHash_s
```

### Updating to a New PowerStacks Release

There's nothing to do for your rules. A new release replaces only the PowerStacks rules built into the script; your file stays where it is, and your rules keep winning.
