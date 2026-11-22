# App Usage

App Usage (software metering) records which installed apps people actually use, from the Windows System Resource Usage Monitor (SRUM). It's off by default. To turn it on, set `$CollectAppMetering = $true` in `Intune_Windows_Inventory.ps1`.

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

When two or more apps are left after every check, the executable is reported as unmatched, and `CandidateTargets` lists the apps it could belong to. Those apps aren't reported as unused because of it. To settle it yourself, give your rule a narrower `target.displayName`.

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
