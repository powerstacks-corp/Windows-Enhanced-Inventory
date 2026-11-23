# App Usage

App Usage (software metering) records which installed apps people actually use, from the Windows System Resource Usage Monitor (SRUM). It's off by default. To turn it on, set `$CollectAppMetering = $true` in `Intune_Windows_Inventory.ps1`.

## Turn On App Usage

App Usage runs only where it's supported. On any other device, the inventory runs as before, and App Usage reports why it skipped in `AppUsageCollectionStatus_s`.

- **Windows:** Windows 11 25H2 (build 26200) or later. Windows 10 and earlier Windows 11 releases report `UnsupportedOS`.
- **PowerShell:** 64-bit Windows PowerShell 5.1, running as SYSTEM, the way Intune runs the script, in Full Language mode. App Usage can't run in Constrained Language Mode. See [Application Control](#application-control).

Before you turn it on:

1. Install the BI for Intune release that reads split runs. With App Usage on, a large device can send its App Inventory data as several rows (see [How the Data Is Sent](#how-the-data-is-sent)), and earlier releases don't read those rows.
1. Add the App Usage columns to the `PowerStacksAppInventory_CL` table and its data collection rule. Run `Update-PowerStacksAppInventorySchema.ps1` from the `postdeploy` folder of [EnhancedInventoryDeploy](https://github.com/powerstacks-corp/EnhancedInventoryDeploy). Until it reaches the main branch, the updater is on the repository's release branch, `release/app-usage-v1`. [Add the App Usage columns to an existing deployment](https://github.com/powerstacks-corp/EnhancedInventoryDeploy/blob/release/app-usage-v1/README.md#add-the-app-usage-columns-to-an-existing-deployment) has the steps, including the backup it saves and how to roll back. A deployment made from a version of EnhancedInventoryDeploy that includes App Usage already has the columns.
1. Wait the full 30 minutes after the data collection rule changes. A change reaches the service's ingestion points unevenly. Until it reaches them all, uploads still succeed, but a row can lose its new columns without any error, and a test row that keeps them doesn't prove that every upload will. Reports ignore a row that lost its run columns, and the rest of its run.
1. Get the release build of the script. See [Deploy the Release Build](#deploy-the-release-build).

Then set `$CollectAppMetering = $true` in the release build of `Intune_Windows_Inventory.ps1`, and deploy it as before. Start with a few devices, and then the rest.

These settings, at the top of the script, control App Usage:

| Setting | Default | What it does |
|---|---|---|
| `$CollectAppMetering` | `$false` | Turns App Usage on. |
| `$CollectUWPInventory` | `$false` | The existing Store app inventory setting. Store and MSIX apps are discovered, and their usage collected, only when it's `$true`, so their inventory and usage are on or off together. |
| `$MinFocusSecondsForUse` | `1` | How many seconds of focus or input count as use. |
| `$AppUsageCustomerMappingsPath` | `C:\ProgramData\PowerStacks\AppUsage\customer-mappings.json` | Where the script looks for your mapping rules. |

To turn App Usage off, set `$CollectAppMetering = $false`. The next run sends exactly the App Inventory row it sent before App Usage, and the usage history stays on the device. If you also roll back the data collection rule, change the script first and the rule only after devices stop sending App Usage rows. The updater's `-RollbackFrom` parameter puts back the rule it saved; see [Roll back](https://github.com/powerstacks-corp/EnhancedInventoryDeploy/blob/release/app-usage-v1/README.md#roll-back).

### Deploy the Release Build

Deploy the `Intune_Windows_Inventory.ps1` from a release of this repository, not the file in the repository itself. The repository file is the source. It's over the 512 KB size limit Intune puts on a remediation script, and it doesn't have the PowerStacks mapping rules built in, so App Usage would skip and report `MappingsUnavailable:Missing`. PowerStacks makes the release build from it with `Build-InventoryRelease.ps1`, which builds the rules in and removes the comments inside functions. Keep `Test-AppUsageMappings.ps1` and `customer-mappings.example.json` from the same release with it. See [What a Release Contains](#what-a-release-contains).

## Privacy

App Usage records which apps people use on their devices, and for how long. That's activity monitoring, and some organizations need approval first, for example from a works council.

- Everyone with access to the BI for Intune app sees all of its data. BI for Intune is a Power BI template app, and template apps don't support row-level security, so you can't limit who sees which devices' usage. Turning App Usage on or off is the control.
- App Usage sends no user names or SIDs as fields, and its user fields are counts. But `RunPath`, and `ExeInfo` for some executables, is the path the executable ran from. For an app installed in a user's profile, that path includes the profile folder, such as `C:\Users\<profile folder>\...`, which often contains the user's name. Treat `RunPath` and `ExeInfo` as data that can identify a user in your reports.
- Who used what stays in the usage history on each device, which only SYSTEM and administrators can read (see [Usage History on the Device](#usage-history-on-the-device)).
- App Usage writes no user names, SIDs, or profile paths to the script log in `C:\Windows\Logs`, because standard users can read that log.

## Application Control

App Control for Business (formerly WDAC) script rules apply to the whole inventory script, not only App Usage. On a device that enforces them, PowerShell runs any script the policy doesn't allow in Constrained Language Mode.

The inventory script doesn't work in Constrained Language Mode. It writes no log and uploads nothing, whether App Usage is on or off. App Usage can't run in that mode, and nothing about App Usage is logged.

For the inventory script to run in Full Language mode, your application control policy must allow it:

- If your policy doesn't already allow scripts that Intune deploys, sign `Intune_Windows_Inventory.ps1` with a code-signing certificate your policy trusts. The certificate's root must also be in the device's trusted root store.
- Sign the script after you set its settings, and sign it again after any change, because editing the file invalidates the signature.
- Your mapping rules are a separate file, so changing them doesn't mean signing the script again.

For more information, see [Understand App Control script enforcement](https://learn.microsoft.com/windows/security/application-security/application-control/app-control-for-business/design/script-enforcement).

## Usage History on the Device

SRUM keeps only about 30 to 60 days of usage, so the script keeps its own history on each device, in `C:\Windows\AppUsage_<Serial>.json`. `<Serial>` is the device's serial number, with any character that isn't allowed in a file name replaced by `_`. When the device reports no serial number, the computer name is used instead. The file holds each user's usage of each executable build. Each run adds the usage SRUM recorded since the last run. SRUM records the script has already counted add nothing when they're read again, and usage moves into the history once SRUM drops it, so the history outlasts SRUM.

- Only SYSTEM and administrators can read or change the file, because it holds every user's activity on the device. Standard users can't open it.
- The script writes a new copy of the file to disk and then swaps it in, so a run that stops partway, or a power loss, leaves the earlier file in place.
- If the file can't be read, the script never overwrites it. It renames the file to `AppUsage_<Serial>.corrupt-<yyyyMMddHHmmss>.json`, with the time in UTC, starts a new history from what SRUM still holds, and reports `LedgerReset`. The renamed copy can also be read only by SYSTEM and administrators.
- An app update brings a new build of its executable. Once SRUM holds no usage of the old build, the script combines the old build's history into a newer build of the same app for the same user. It combines builds only when both are matched to the same app, or, for unmatched builds, when the script verified both builds and they have the same company and product names. Executables that only share a file name, such as two `setup.exe` files from different publishers, are never combined.

### The Work Folder

While it runs, App Usage copies the SRUM database, and the registry hives of users who aren't signed in, into a folder for the run under `C:\Windows\PowerStacksAppUsage`, and deletes the copies when it's done. The script creates `C:\Windows\PowerStacksAppUsage` so that only SYSTEM and administrators can open it, because the copies hold every user's activity.

If `C:\Windows\PowerStacksAppUsage` already exists and isn't a folder that only SYSTEM and administrators control, the script never changes, reads, or deletes it, and App Usage skips the run with `SrumReadFailed:WorkDirUntrusted`. That includes a folder an administrator made by hand or with another tool, which gets the permissions of `C:\Windows`. App Usage skips on every run until an administrator deletes the folder. The next run then creates it again.

## Installed Apps and Profiles

App Usage reads the installed apps of every profile on the device, not only the signed-in user's:

- **Profiles:** every profile Windows lists in `ProfileList` (`HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList`), signed in or not. Apps come from signed-in and signed-out users, plus SYSTEM's own per-user installs, which deployment tools often make. Per-user installs under the LocalService and NetworkService accounts aren't listed, because those aren't anyone's profile.
- **Signed-in users:** their apps are read from their loaded registry hive.
- **Signed-out users:** the script copies the user's `NTUSER.DAT` from a shadow copy of the system drive into a folder that only SYSTEM and administrators can open, reads the copy, and deletes it. It never opens a user's live hive file, so a user who signs in during the run isn't affected.
- **Apps:** the uninstall entries (the apps in **Installed apps** or **Programs and Features**) of the device, 64-bit and 32-bit, and of each profile. Store and MSIX apps are included only when `$CollectUWPInventory` is `$true`, the same setting the App Inventory uses. Windows Installer records tell the script which installed app an executable belongs to; they never add an app to the inventory. A per-user installation's records count only for files in that user's profile folder, so one user's installation can't claim a file every user runs.

A profile the script can't read is a coverage gap, never a reason to call an app missing. That's a profile whose folder isn't on the device (for example, a profile container or roaming profile that isn't attached), or a signed-out user whose hive couldn't be copied or loaded. Apps in that profile are never `NotInstalled`, and their usage status stays blank. Unread profiles are counted in the App Usage device columns and the collection status.

### The Expanded App Inventory

When App Usage is on, the App Inventory data lists the installed apps of every profile the script read. A device can report more apps than before, mostly per-user installs of users who aren't signed in. Entries are still combined into one per DisplayName, with the newest version, by the same code as before, and they carry no user. When App Usage is off, the App Inventory is read exactly as before: the device's apps and the signed-in user's apps. If the all-profile read fails on a run, that run's App Inventory falls back to the earlier read.

## What App Usage Reports

App Usage adds usage fields to each app in the App Inventory data (`PowerStacksAppInventory_CL`), and sends a list of the executables it has seen. Both combine every user on the device: their user fields are counts, not names. An executable's path can still include a user's profile folder (see [Privacy](#privacy)). Who used what stays in the history file on the device.

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
| `Ambiguous` | Nothing is credited to the app, but an executable that might be the app's ran: one that could belong to it or to another app (see [When a Rule Matches Several Installed Apps](#when-a-rule-matches-several-installed-apps)), an unmatched executable with the name of one of the app's known executables, for example a build the script couldn't verify, or an unmatched executable that ran from inside the app's install folder. An executable matched to an app that isn't installed counts as unmatched here. Not a reclamation candidate. |
| `NotUsed` | App Usage knows the app's executables, and none of them ran since the watching-since date, whether matched to the app or not. The only value that marks a reclamation candidate. |
| `NotCovered` | App Usage knows no executable for the app, so it can't measure its use. |
| Blank | App Usage didn't run or failed on this run, the watching-since date isn't known yet, or the script couldn't read every place the app is installed (the device's apps, or a user's apps). Blank never means `NotUsed`. |

App Usage knows an app's executables when Windows Installer lists them as part of the app, when an identity rule whose target matches the app names them in `when.exeName` (a pattern such as `contoso*.exe` covers every name it matches), or when it has seen one of them run and matched it to the app. An executable that an ignore rule matches isn't one of the app's known executables, so an app whose only known executable is ignored is `NotCovered`. An executable matched to a different app doesn't count as a run of this one.

### Executable Usage

App Usage also sends one entry for each executable build it has seen and each app the build is matched to, with every user combined. Every executable is listed: matched or unmatched, installed or not, and the ones ignore rules match.

| Field | Meaning |
|---|---|
| `ExeInfo` | The executable build, as SRUM records it. For a Store or MSIX app, its package name. For some executables it's the path the executable ran from, which can include a user's profile folder. |
| `ExeName` | The file name, in lowercase. Blank for a Store or MSIX app. |
| `RunPath` | The path the build ran from, when the script found it and confirmed it's the same build. For an app installed in a user's profile, the path includes the profile folder, which often contains the user's name. |
| `LocationClass` | The kind of folder it ran from: `Windows`, `ProgramFiles`, `UserProfile`, `Temp`, `Download`, `ManagementCache`, or `Other`. |
| `FileDescription`, `FileProductName`, `FileCompanyName`, `FileVersion`, `ProductVersion` | The build's file details. Only when the script verified the build (`FactsVerified` is `true`); blank otherwise. |
| `FactsVerified` | `true` when the file on disk is the build that ran. A file outside the Windows and Program Files folders counts only when SYSTEM, Administrators, TrustedInstaller, or the user who ran it owns the file, so one user can't plant a file that gives another user's executable its details. |
| `EvidenceCompanyName`, `EvidenceProductName`, `EvidenceSource` | For a build the script couldn't verify: the company and product names of the file now at the same path, with `EvidenceSource` set to `CurrentFileAtPath`. They can match the executable to an app, but they aren't the build's own details. Blank for a verified build, and blank when the file is outside the Windows and Program Files folders and its owner isn't one of those listed for `FactsVerified`. |
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

This run's rows get the script's usual upload retries. A row that still fails is saved on the device, in `C:\Windows\AppUsage_<Serial>_outbox\`, next to the usage history and with the same `<Serial>`, as `<RunId>-<RowIndex>.json`. The next run sends it first, unchanged.

- Only SYSTEM and administrators can open the folder and its files, because the rows hold usage data. If something else is at that path, such as a link, a folder owned by another account, or a folder other users can open, the script never reads, sends, or deletes anything there, and saves nothing to it. To fix that, delete the folder as an administrator; the next run that needs it creates it again.
- Each run sends the saved rows first, oldest run first, and then its own rows, so the rows arrive in run order.
- Saved rows get one attempt each, with no retries or waits, so sending them never holds up the run for long. The first saved row that fails stops the sending of saved rows: it and the rest wait for the next run. A saved row that can't be read stops it the same way. A saved row that isn't a valid row is deleted without being sent, and the rest wait for the next run.
- This run's own rows then get the script's usual retries, one round in total. Once a row still fails after its retries, every row left waits in the folder for the next run. A network or service outage costs one round of retries, not one for each row.
- The folder keeps the rows of the 5 most recent runs. Once every row of a newer run is sent, the saved rows of older runs are deleted, because the newer run replaces them.
- While rows wait, row 1's `AppUsageCollectionStatus_s` includes `PendingRows`. The status is set after the saved rows are sent, so a run that empties the folder doesn't report it.
- The ingestion service can reject a row itself, with HTTP 400 (bad request) or 413 (too large), and a resend of the same row can't succeed. A saved row rejected that way is deleted, and the run goes on to the next saved row. A new row rejected that way is saved like any other, so the next run tries it once more.
- No other failure deletes a row. That includes 401 and 403, for example from an expired client secret or a missing role on the data collection rule, a throttled or timed-out request, a server error, and a failed token request. The row waits for the next run.
- A saved row that was sent but can't be deleted is renamed to `<RunId>-<RowIndex>.json.sent`, so it's never sent again, and a later run deletes it.
- Two inventory runs never use the folder at the same time. They take turns with a lock, `Global\PowerStacksAppUsageOutbox`. A run that waits 60 seconds and still can't get the lock sends its own rows without the folder and reports `OutboxSkipped`; any of its rows that fail may be lost. Usually another inventory run holds the lock, but any process on the device can hold it.
- When App Usage is off, the folder stays on the device and its rows aren't sent.

## Device Columns

Row 1 of every run with App Usage on carries these columns, next to the App Inventory columns:

| Column | Meaning |
|---|---|
| `AppUsageEnabled_b` | `true`: App Usage was on for this run. |
| `WatchingSince_t` | The earliest usage App Usage has for the device, in UTC. Blank until the device has some. |
| `AppUsageScriptVersion_s` | The script version. |
| `MappingsVersion_s` | The version of the PowerStacks mapping rules built into the script. Blank when App Usage skipped before it loaded them. |
| `CustomerMappingsHash_s` | The SHA-256 of the customer mapping file the run used. Blank when there's no file or it's invalid. |
| `UnmatchedExeCount_d` | How many executables no rule matched. Executables that ignore rules match aren't counted. |
| `ProfilesFound_d`, `ProfilesRead_d` | How many profiles Windows lists, and how many the script read. The difference is the coverage gap. |
| `AppUsageCollectionStatus_s` | `OK`, or what went wrong. See [Collection Status](#collection-status). |

## Collection Status

`AppUsageCollectionStatus_s` is `OK` when there's nothing to report. Otherwise it lists problems as tokens in the form `Token` or `Token:detail`, separated by `; `, for example `SrumReadFailed:EsentMissing; ProfileUnread:1`. No App Usage problem stops or changes the inventory: when App Usage skips or fails, the App Inventory data is still sent, with its usage fields blank.

| Token | Meaning |
|---|---|
| `OK` | Nothing to report. |
| `UnsupportedOS` | Windows is older than Windows 11 25H2 (build 26200). App Usage skipped. |
| `LanguageMode:<mode>; skipped` | PowerShell isn't in Full Language mode, so App Usage skipped. You won't see this token for Constrained Language Mode: in that mode the inventory script writes no log and uploads nothing. See [Application Control](#application-control). |
| `AppUsageFailed:OsBuild` | The Windows build number couldn't be read. App Usage skipped. |
| `AppUsageFailed:Serial` | The serial number couldn't be read, so the usage history can't be named. App Usage skipped. A device with no serial number uses its computer name instead and isn't affected. |
| `MappingsUnavailable:Missing` | The PowerStacks mapping rules aren't in the script, which happens when the script that ran is the repository's source file instead of the release build. App Usage skipped. See [Deploy the Release Build](#deploy-the-release-build). |
| `MappingsUnavailable:Invalid` | The PowerStacks mapping rules in the script didn't load. App Usage skipped. |
| `AppUsageBusy` | App Usage couldn't get its lock, `Global\PowerStacksAppUsage`, within 60 seconds (or couldn't open it), so App Usage skipped this run. Usually that's another inventory run, but any process on the device can hold the lock. If a device reports this on every run, look for a process that holds it. |
| `AppUsageFailed` | An unexpected error. The script log has the details. The usage fields are blank for this run. |
| `ShadowCopyFailed` | No shadow copy of the system drive could be taken. App Usage skipped. |
| `LowDiskSpace` | The drive that holds the work folder had less free space than the copies need: at least 2 GB, and at least three times the size of the SRUM database and the signed-out users' hives. Nothing was copied, and App Usage skipped. |
| `SrumReadFailed:WorkDirUntrusted` | The work folder `C:\Windows\PowerStacksAppUsage` isn't a folder that only SYSTEM and administrators control, so the script left it alone and App Usage skipped. A folder an administrator made counts too. App Usage skips on every run until an administrator deletes the folder; the next run creates it again. See [The Work Folder](#the-work-folder). |
| `SrumReadFailed:<reason>` | The SRUM database couldn't be read this run, so no new usage was added. The history on the device is unchanged. The reason is `CopyFailed`, `EsentMissing`, `NoDatabase`, `LiveDatabase`, `HeaderFailed`, `RepairFailed`, `OpenFailed`, `IdMapFailed`, `NoTimeline`, `TimelineFailed`, `ReadFailed`, or `NoRows` (the read worked but held no usage). |
| `LedgerReset` | The usage history on the device couldn't be read. It was renamed and a new one started. |
| `LedgerWriteFailed` | The usage history couldn't be saved. The earlier file is unchanged, and this run's results were still sent. |
| `DiscoveryFailed` | The all-profile app read was incomplete, so the App Inventory used the earlier read: the device's apps and the signed-in user's apps. |
| `ProfileUnread:<count>` | How many profiles couldn't be read. Their apps are never `NotInstalled`. |
| `HiveUnloadFailed:<count>` | How many copied user hives were still loaded at the end of the run, under `HKEY_USERS\AU_<SID>`. They hold copies, not the users' own hives. The next run that reads that user unloads it first; restarting the device also unloads it. |
| `MsiFileMapFailed` | The Windows Installer component records couldn't be read, so they didn't help match executables to apps. |
| `InvalidCustomerMappings` | The customer mapping file isn't valid, so it was ignored this run. With `:TooLarge`, it's over 1 MB. With `:UnsafePath` or `:ReparsePoint`, its path was refused. |
| `PendingRows` | Rows from an earlier run are still waiting to be sent. See [Rows That Fail to Send](#rows-that-fail-to-send). |
| `OutboxSkipped` | The folder for unsent rows couldn't be used this run: something held its lock for 60 seconds, the folder couldn't be read, or it isn't the protected folder the script creates. This run's rows were still sent, but any that failed may be lost. See [Rows That Fail to Send](#rows-that-fail-to-send). |

A device without a customer mapping file reports `OK`; its blank `CustomerMappingsHash_s` shows that it has none.

## Script Output and Exit Code

App Usage writes nothing to the console. The script's only output is still the one-line upload summary that Intune shows in its output column, for example:

```text
InventoryDate: 11-23 02:10 DeviceInventory: OK 204 : Upload payload size is 12.4Kb  AppInventory: OK 204 : Upload payload size is 41.2Kb (1 row)  DriverInventory: OK 204 : Upload payload size is 30.1Kb
```

With App Usage on, the App Inventory part reports `OK` only when every row of the run was sent, with the total size and the number of rows, and `Fail` otherwise. App Usage adds nothing else to the line. Its result is in `AppUsageCollectionStatus_s` and the script log.

App Usage never changes the script's exit code: a run whose inventory succeeds exits the same way whether App Usage worked or not.

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

A target pattern also makes the rule's executable one of the known executables of every installed app the pattern matches. In the `Contoso*` example, Contoso Beta knows the rule's executable too, and when that executable runs and is matched to Contoso Alpha, it isn't a run of Contoso Beta. So when an unmatched executable runs from inside Contoso Beta's install folder, Contoso Beta is reported as `Ambiguous`, not `NotUsed`. To measure each app, give each one its own rule with a target that matches only that app, for example `Contoso Alpha*` and `Contoso Beta*`.

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

An ignore rule has the same `when` conditions as a classification rule and no `role`. It marks an executable that isn't an app, such as a kiosk shell. The executable's usage is still recorded, but it doesn't make an app count as used, it isn't counted as unmatched, and it isn't one of the app's known executables. An app whose only known executable is ignored is reported as `NotCovered`, never `NotUsed`.

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

- **Absent:** the run uses PowerStacks rules only. Executables that your rules matched before are matched again from PowerStacks rules on that run. `CustomerMappingsHash_s` is blank, so a delivery that didn't arrive shows in reports. A missing file isn't a problem on its own, so the run's status stays `OK`.
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

### What a Release Contains

Each release publishes three files. You deploy the script; keep the other two with it.

| File | What it is |
|---|---|
| `Intune_Windows_Inventory.ps1` | The script you deploy, with the PowerStacks rules built in. |
| `Test-AppUsageMappings.ps1` | The validator for your rules file. Keep it in the same folder as the script. |
| `customer-mappings.example.json` | An example rules file. Copy it, name the copy `customer-mappings.json`, and replace the examples with your rules. |

A release never contains a file named `customer-mappings.json`, so it can't replace yours.

The `Intune_Windows_Inventory.ps1` in the repository itself is the source, not the file you deploy: it's over Intune's 512 KB limit and has no PowerStacks rules built in. PowerStacks builds the release file from it with `Build-InventoryRelease.ps1`.

The PowerStacks rules are the Base64 value between the `# BEGIN APPUSAGE MAPPINGS` and `# END APPUSAGE MAPPINGS` lines of the script. Don't edit that block by hand. The script checks the rules on every run; if they don't load or don't validate, App Usage skips the run and reports `MappingsUnavailable:Invalid`. To change how executables match, use your own file.

The published script has fewer comments than the source: the comments inside its functions are removed to keep it under the Intune size limit for remediation scripts. The settings at the top keep all their guidance.
