# Source

This folder contains the four PowerShell scripts that implement the solution.

The scripts are intentionally separated from operational configuration, user mappings, logs and reports. For a real deployment, copy the four scripts to a dedicated working directory such as `C:\MyDev\MSLearn` and run them there.

## Execution order

| Step | Script | Purpose |
|---|---|---|
| 00 | `00 - Initialize-MSLearnPeopleConnector.ps1` | Creates the local folder structure, validates PowerShell prerequisites, generates the centralized configuration skeleton and creates the user mapping files. |
| 01 | `01 - Create-MSLearnPeopleConnectorApp.ps1` | Creates the Microsoft Entra app registration and service principal, configures required Microsoft Graph application permissions, creates the authentication credential and updates the centralized JSON. |
| 02 | `02 - New-MSLearnPeopleConnector.ps1` | Creates/validates the Microsoft 365 People Data Connector, registers its schema, registers the connector as a profile source and configures source precedence. |
| 03 | `03 - Sync-MSLearnCredlyPeopleProfiles.ps1` | Reads configured users, retrieves Microsoft Learn and Credly credentials, deduplicates/merges data and publishes the resulting credentials to Microsoft 365 profiles. |

## Step 00 – Initialize

The initialization script:

- Requires PowerShell 7+.
- Creates:
  - `Config`
  - `Data`
  - `Logs`
  - `Reports`
- Validates or installs the Microsoft Graph PowerShell modules required by the solution.
- Creates `Config\MSLearnPeopleConnector.json`.
- Creates a configuration template.
- Creates `Data\CredentialUsers.csv` and a disabled sample row.
- Creates local README files for the operational folders.

Existing operational files are preserved by default unless one of the explicit reset switches is used.

## Step 01 – Entra application and service principal

Step 01 creates the security principal used by Steps 02 and 03.

Key behaviors include:

- Fresh administrator authentication using OAuth device code.
- Dynamic resolution of Microsoft Graph application permission role IDs.
- Single-tenant Entra application creation.
- Service principal creation.
- Client credential creation.
- Optional automatic admin consent.
- Updating the configuration created by Step 00 instead of replacing the full configuration contract.

Configured Microsoft Graph application permissions:

- `ExternalConnection.ReadWrite.OwnedBy`
- `ExternalItem.ReadWrite.All`
- `PeopleSettings.ReadWrite.All`

### Security note

The current PoC flow can write the client secret to the local configuration file. That file must be protected and must not be committed to GitHub.

## Step 02 – People Data Connector

Step 02 is configuration-driven. It loads `Config\MSLearnPeopleConnector.json` and does not embed tenant-specific values in the script.

It:

- Authenticates app-only to Microsoft Graph.
- Creates or validates the configured external connection.
- Enforces `contentCategory = people`.
- Registers the configured People Data schema while the connection is in draft.
- Waits until schema provisioning completes.
- Registers the connector as a Microsoft 365 profile source.
- Configures profile source precedence.
- Performs final validation without inserting demonstration/test user data.

The default schema uses:

| Connector property | Type | Microsoft 365 label |
|---|---|---|
| `accountInformation` | `string` | `personAccount` |
| `certifications` | `stringCollection` | `personCertifications` |

## Step 03 – Microsoft Learn and Credly synchronization

Step 03 also reads its operational settings from the centralized JSON.

For each enabled user, it can:

- Resolve Microsoft Learn profile/transcript information.
- Publish active Microsoft certifications.
- Retrieve public/accepted Credly badges within the configured rolling window.
- Deduplicate Credly items against Microsoft Learn by normalized credential name.
- Merge managed credentials with existing profile data.
- Preserve unmanaged profile entries.
- Remove stale credentials previously managed by this solution when configured to do so.
- Continue processing other users after a per-user error when configured.
- Support dry-run behavior for validation.
- Write detailed logs and JSON reports.

The default Credly window is 12 months.

## User mapping

The default CSV contract is:

```text
UserPrincipalName,EntraObjectId,LearnUserName,TranscriptId,CredlyUser,Enabled
```

Microsoft Learn and Credly identifiers are independent. A user can be synchronized from one source or both, subject to the runtime validation rules in Step 03.

## Operational folders

After Step 00, a typical working directory looks like:

```text
C:\MyDev\MSLearn
├── 00 - Initialize-MSLearnPeopleConnector.ps1
├── 01 - Create-MSLearnPeopleConnectorApp.ps1
├── 02 - New-MSLearnPeopleConnector.ps1
├── 03 - Sync-MSLearnCredlyPeopleProfiles.ps1
├── Config/
├── Data/
├── Logs/
└── Reports/
```

Do not use the public `Support/MSLearnPeopleConnector.sample.json` as a place to store production secrets. Let Step 00 create the operational configuration and let Step 01 populate the environment-specific values.
