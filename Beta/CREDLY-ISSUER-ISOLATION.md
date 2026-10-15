# Credly issuer isolation — Beta Step 03d

This controlled experiment investigates why some Credly badge collections materialize in Microsoft 365 Profile API while another user's 22 certifications and three Applied Skills successfully materialized.

**Scope:** Four dedicated NEW Entra test users, all written to the existing configured `mslearncred` People connection (Schema 2.4). Production Step 03 and Step 99 are unchanged. No tenant-specific information is embedded in repository files.

## Groups and controls

| Scenario | Filter | Expected from October 14, 2026 diagnosis |
| --- | --- | --- |
| `MicrosoftAll` | `issuer.entities[0].entity.name` matches Microsoft (case-insensitive) | 18 |
| `OtherIssuers` | Issuer is not Microsoft (e.g. Cisco, IBM, AWS) | 6 |
| `MicrosoftA` | First half of Microsoft badges sorted by badge ID | 9 |
| `MicrosoftB` | Remaining Microsoft badges sorted by badge ID | 9 |

These expected counts are historical observations, **not** hardcoded filters or validation limits. The source is always freshly retrieved via public `https://www.credly.com/users/elias-nieto.65efb4e7/badges.json`, with a rolling **12-month** cutoff calculated on the execution day. State must be accepted and visibility public. Partitioning is by issuer only, not by Unicode or date within the window.

`MicrosoftA` and `MicrosoftB` are disjoint, and their union exactly covers `MicrosoftAll`; the test prints actual counts. The same badge may legitimately appear in `MicrosoftAll` and one of the halves, **but on different test users**. Microsoft and OtherIssuers have no overlap.

The beta script uses the same structured certification fields as production Step 03 (badge ID prefix, issuer, dates, URLs, thumbnail, and managed description) without stripping characters. Only the destination test UPN/ObjectId and the selected badge subset vary.

## Create the user CSV

The file [CredlyIssuerTestUsers.template.csv](CredlyIssuerTestUsers.template.csv) is a **template**, not a list of actual Entra identities. Create **four real test users** and record their exact UPN and Entra user **Object ID** (not tenant ID or client ID).

Copy the template from Beta to your local solution's Data folder as `CredlyIssuerTestUsers.csv`; replace **every** `@example.com` UPN and placeholder GUID. The script refuses to proceed while template identities are present.

```csv
Scenario,UserPrincipalName,EntraObjectId
MicrosoftAll,usuario.microsoftall@yourtenant.example,REPLACE-WITH-USER-OBJECT-ID
OtherIssuers,usuario.otherissuers@yourtenant.example,REPLACE-WITH-USER-OBJECT-ID
MicrosoftA,usuario.microsofta@yourtenant.example,REPLACE-WITH-USER-OBJECT-ID
MicrosoftB,usuario.microsoftb@yourtenant.example,REPLACE-WITH-USER-OBJECT-ID
```

Save as UTF-8. The mapping CSV contains *only destination test accounts*, not a copy of Credly badges.

## Run from your existing Beta directory

```powershell
# C:\Deploy\M365 Profile Card Awards\Beta
# Preview: checks local configuration and mapping, fetches fresh public Credly JSON
& '.\03d - Test-CredlyIssuerIsolation.ps1' -UsersCsv '..\Data\CredlyIssuerTestUsers.csv'

# Confirm four scenarios and counts; explicit publication:
& '.\03d - Test-CredlyIssuerIsolation.ps1' -UsersCsv '..\Data\CredlyIssuerTestUsers.csv' -Publish
```

The script uses `Config/MSLearnPeopleConnector.json` from the parent project directory, and resolves a relative `-UsersCsv` path against the current PowerShell location. Optional Credly URL settings and optional badge properties use StrictMode-safe defaults/readers, consistent with Step 03.

**Safety:** Default execution is preview-only. `-Publish` is required to perform any Graph write. If **any** destination `externalItem` already exists, preflight blocks publishing unless `-Overwrite` is intentionally supplied. `-Overwrite` replaces the entire item, so use it only for disposable test users. Do not run production Step 03 against these four users; it would replace their controlled data.

For repeatability, record the actual list of badge IDs, fetched time, issuer classification, source counts, and payload bytes. The script prints counts and approximate UTF-8 certification-payload sizes; do not publish secret configuration or access tokens as part of results.

## Step 99 validation

Add the four UPN/ObjectId rows to the local `Data/CredentialUsers.csv` as **enabled** solely so Step 99 can read them. Keep them excluded from production Step 03 runs. Execute Step 99 in summary and detailed modes and record `Ext Cert`, `Profile Cert`, `Materialization`, Profile Card UI state, and time since publication.

Interpretation requires controlling for propagation delay:
- 18 Microsoft materializes but 6 non-Microsoft does not: inspect third-party issuer differences.
- Both groups materialize but some combined cases do not: investigate combined payload size and materialization behavior.
- MicrosoftAll fails but both nine-item halves materialize: investigate collection volume/size or a combination effect.
- Both nine-item halves fail: investigate shared metadata and service behavior, not solely a single bad badge.
- All succeed: previous Pending results may have reflected propagation, existing-user state, or different content.

Never interpret a Graph PUT/read-back as proof of successful Profile API materialization.
