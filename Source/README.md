# Source

This folder contains the five production PowerShell scripts that implement the solution.

The scripts are intentionally separated from operational configuration, user mappings, logs and reports. For a real deployment, copy the five scripts to a dedicated working directory such as `C:\MyDev\MSLearn` and run them there.

## Execution order

| Step | Script | Purpose |
|---|---|---|
| 00 | `00 - Initialize-MSLearnPeopleConnector.ps1` | Creates the local folder structure, validates PowerShell prerequisites, generates the centralized configuration skeleton and creates the user mapping files. |
| 01 | `01 - Create-MSLearnPeopleConnectorApp.ps1` | Creates the Microsoft Entra app registration and service principal, configures required Microsoft Graph application permissions, creates the authentication credential and updates the centralized JSON. |
| 02 | `02 - New-MSLearnPeopleConnector.ps1` | Creates/validates the Microsoft 365 People Data Connector, registers its schema, registers the connector as a profile source and configures source precedence. |
| 03 | `03 - Sync-MSLearnCredlyPeopleProfiles.ps1` | Reads configured users, retrieves Microsoft Learn certifications and Applied Skills plus Credly badges, and publishes their configured representations. |
| 99 | `99 - Test-MSLearnProfileSchemaPopulation.ps1` | Compares connector data with the composed profile for all enabled users, one user or a summary. |

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

The current configuration baseline is **SchemaVersion 2.4**. When Step 00 encounters an older or incomplete configuration, it creates a backup, upgrades the schema contract when required, and restores missing configuration properties without replacing existing tenant/application/source/synchronization values.

## Step 01 – Entra application and service principal

Step 01 creates the security principal used by Steps 02 and 03.

Key behaviors include:

- Fresh administrator authentication using OAuth device code.
- Dynamic resolution of Microsoft Graph application permission role IDs.
- Single-tenant Entra application creation.
- Service principal creation.
- Client credential creation or reuse of the configured valid secret; rotation requires the explicit switch.
- Reconciliation of the configured application and service principal display names without replacing their identities.
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
- Reconciles schema drift while the connection is in either `draft` or `ready` state.
- Preserves schema properties that are not owned by the current project contract.
- Waits for asynchronous schema operations and final schema convergence when an update is required.
- Registers the connector as a Microsoft 365 profile source.
- Configures profile source precedence.
- Performs final validation without inserting demonstration/test user data.

The SchemaVersion 2.4 default schema uses:

| Connector property | Type | Microsoft 365 label |
|---|---|---|
| `accountInformation` | `string` | `personAccount` |
| `certifications` | `stringCollection` | `personCertifications` |
| `microsoftAppliedSkills` | `stringCollection` | none (custom semantic context) |
| `appliedSkillsAwards` | `stringCollection` | `personAwards` |
| `title` | `string` | `title` |
| `sourceUrl` | `string` | `url` |
| `lastModifiedBy` | `string` | `lastModifiedBy` |
| `lastModifiedDateTime` | `dateTime` | `lastModifiedDateTime` |

Normally Step 02 updates the schema only when drift is detected. The optional `-ForceSchemaUpdate` switch is intended for explicit troubleshooting/reapply scenarios.

## Step 03 – Microsoft Learn and Credly synchronization

Step 03 also reads its operational settings from the centralized JSON.

For each enabled user, it can:

- Validate that the live external schema matches the SchemaVersion 2.4 contract before processing users.
- Resolve Microsoft Learn profile/transcript information.
- Publish active Microsoft certifications.
- Read Microsoft Applied Skills from `appliedSkillsData.appliedSkillsCredentials` and publish custom YAML-like semantic context plus an award projection. Applied Skills are not classified as Microsoft Certifications.
- Retrieve public/accepted Credly badges within the configured rolling window.
- Deduplicate Credly items against Microsoft Learn by normalized credential name.
- Merge managed credentials with existing profile data.
- Preserve unmanaged profile entries.
- Remove stale credentials previously managed by this solution when configured to do so.
- Publish semantic metadata:
  - `title`: Microsoft Learn display name, with UPN fallback.
  - `sourceUrl`: Microsoft Learn public transcript URL, with Credly public profile fallback.
  - `lastModifiedBy`: connector application display name.
  - `lastModifiedDateTime`: UTC synchronization timestamp.
- Read the external item back after PUT and validate the semantic metadata.
- Continue processing other users after a per-user error when configured.
- Support dry-run behavior for validation.
- Write detailed logs and JSON reports.

The default Credly window is 12 months. The value is configurable and is a project choice rather than a Microsoft 365 platform limit.

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
├── 99 - Test-MSLearnProfileSchemaPopulation.ps1
├── Config/
├── Data/
├── Logs/
└── Reports/
```

Do not use the public `Support/MSLearnPeopleConnector.sample.json` as a place to store production secrets. Let Step 00 create the operational configuration and let Step 01 populate the environment-specific values.


## Branding and Copilot visibility

- Application/service principal: **M365 Profile Card Awards Connector**.
- Connection: **M365 Profile Card Awards**; default ID: `mslearncred`.
- Entra branding icon: `Assets/Branding/main/m365-profile-card-awards-docs-256.png`.
- Connector icon: `Assets/Branding/main/m365-profile-card-awards-copilot-48.png`.

Use the production icons without the Beta marker. Apply icons through the relevant administration UI; the scripts print the production asset paths. Step 02 reconciles the connection name and description. Step 01 reconciles the application/service principal names using their existing configured identities.

After Step 02, set **Copilot Visibility > On** in `Microsoft 365 admin center > Copilot > Connectors > Your connections > M365 Profile Card Awards`. `CopilotVisibilityRecommended` is guidance, not an automatic API toggle.

## Step 99 — population validation

Run `99 - Test-MSLearnProfileSchemaPopulation.ps1` after synchronization. Its default configuration is `Config/MSLearnPeopleConnector.json`, with users read from `Data/CredentialUsers.csv`. It supports detailed validation for all enabled users, a selected user or a summary table.

The validator reads connector-specific external items using the configured application, then requests delegated `User.Read.All` with administrator consent for the composed Microsoft 365 profile. It checks certifications and awards separately and validates custom Applied Skills context from the raw item. The Microsoft Graph Profile API still uses the `/beta` endpoint; promotion of these repository scripts does not change the API's release status.

Profiles can include multiple sources. The validator checks expected entries rather than requiring the total shared-profile count to equal the selected connector's count. A successful external-item write is not proof of profile materialization or card visibility. Preserve logs and repeat read-only validation while propagation completes. The enieto case remained pending at promotion; it has not been proven resolved by this release.

## Upgrade from Schema 2.3 or a Beta working directory

### Existing production deployment

1. Download all five scripts from `Source` into the existing production working directory.
2. Run `00` without reset switches. It backs up changed configuration, upgrades the schema contract to 2.4, adds missing settings and migrates known legacy project display names. Existing tenant/application IDs, credentials, connection ID, user mappings and custom operational choices are preserved.
3. Review `Config/MSLearnPeopleConnector.json`: confirm the production identity and paths, Applied Skills settings and desired branding. Existing source options and Credly windows are preserved; the default for new deployments is 12 months.
4. Run `01` to reconcile app/service principal branding and permissions. An existing valid configured secret is reused unless rotation is explicitly requested.
5. Run `02` to reconcile the existing connection and its Schema 2.4 properties. Schema drift is applied without deleting the connection.
6. Run `03`, then `99`. Verify raw ingestion, profile materialization and the actual card/Search/Copilot experience separately.
7. Apply the production icons and confirm Copilot Visibility is On.

### Existing Beta deployment

Promoting scripts does not automatically convert `mslearncredbeta` into `mslearncred`. Do not merely rename the Beta JSON into the production configuration: it retains Beta IDs, application credentials and CSV paths.

Use the production working directory and its configuration, or initialize a separate production directory and populate its user mappings. Publish a pilot through production and verify it with Step 99. When retiring the Beta contribution, use the preview-first [schema-preserving cleanup utility](../Support/Profile-Credential-Cleanup.md), targeting only the intended Beta source and users. Allow removal to propagate before republishing where duplicate prevention is required. Keep the Beta source out of recurring synchronization after cutover.

Both connectors can contribute entries to the same composed profile; source precedence does not guarantee deduplication of collections. The repository promotion itself does not remove tenant data.

### Rollback

Previous scripts and samples remain in Git history. Step 00 creates a local configuration backup before modifying it. Reverting the repository does not revert a schema already applied in Microsoft 365 or remove profile data. Review the saved configuration and live schema before resuming the previous version; do not blindly restore a 2.3 configuration against a 2.4 connection.
