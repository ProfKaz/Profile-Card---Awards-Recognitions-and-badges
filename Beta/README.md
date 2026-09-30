# Beta – Schema 2.4 Applied Skills experiment

<p align="center">
  <img src="../Assets/Branding/beta/m365-profile-card-awards-beta-512.png" alt="M365 Profile Card Awards Beta shield" width="200">
</p>

This folder is intentionally isolated from the production scripts under `/Source`.

## Objective

Validate how Microsoft Applied Skills should be represented in a Microsoft 365 People Data Connector without classifying them as Microsoft Certifications.

Schema 2.4 uses a dual representation:

| Source data | Connector property | Semantic label | Purpose |
|---|---|---|---|
| Microsoft Certifications | `certifications` | `personCertifications` | Existing certification experience |
| Microsoft Applied Skills | `microsoftAppliedSkills` | none (custom) | Search/Copilot semantic retrieval |
| Microsoft Applied Skills | `appliedSkillsAwards` | `personAwards` | Profile Card visual projection |
| Credly | `certifications` | `personCertifications` | Preserves current behavior during the experiment |

Applied Skills are **not** written to `personCertifications` by the beta code.

The custom property stores one YAML-like text block per Applied Skill with the credential type, display name, credential ID, issue date, issuer, source and public transcript URL.

Its schema description explicitly states that these are scenario-based Microsoft credentials distinct from Microsoft Certifications. This description is intentional metadata for Copilot/Search reasoning.

## Isolation controls

The beta defaults are different from production:

- Schema version: `2.4`
- Application display name: `M365 Profile Card Awards Connector Beta`
- Connection display name: `M365 Profile Card Awards Beta`
- Connection ID: `mslearncredbeta`
- Configuration file: `Config/MSLearnPeopleConnector.beta.json`
- User file: `Data/CredentialUsers.beta.csv`

Steps 02b and 03b stop if `Connector.ConnectionId` does not contain `beta`.

Do not point these scripts at the production configuration.

## Copilot visibility

The recommended setting for the beta connection is **On** while validating Microsoft Search and Copilot retrieval. Step 02b prints a post-deployment reminder because the current implementation does not rely on an undocumented Graph property to change this control.

Validate manually in:

`Microsoft 365 admin center > Copilot > Connectors > Your connections > M365 Profile Card Awards Beta > Copilot Visibility > On`

Keep access to the beta connection limited to the intended test population and tenant controls.

## Files

- `00b - Initialize-MSLearnPeopleConnector.ps1`
- `01b - Create-MSLearnPeopleConnectorApp.ps1`
- `02b - New-MSLearnPeopleConnector.ps1`
- `03b - Sync-MSLearnCredlyPeopleProfiles.ps1`
- `99b - Test-MSLearnProfileSchemaPopulation.ps1`
- `MSLearnPeopleConnector.beta.sample.json`

## Execution order

1. Copy/download the **Beta** folder to an isolated working directory.
2. Run `00b`.
3. Populate only `Data/CredentialUsers.beta.csv` with test users.
4. Run `01b` against the test tenant.
5. Grant the requested Graph application permissions/admin consent.
6. Run `02b` to create the `mslearncredbeta` connector with Schema 2.4.
7. Run `03b`.
8. Run `99b` to compare raw Schema 2.4 population with the Profile API facets.
9. Validate Profile Card, Microsoft 365 Search and Copilot before considering any production change.

## Propagation delay and direct validation

> [!WARNING]
> A successful Step 03b write is not displayed immediately in every Microsoft 365 experience. Profile Card, Microsoft 365 Search and Copilot propagation can take several hours and, in observed deployments, may exceed 12 hours. Do not rerun or redesign the connector solely because the Profile Card has not updated yet.

`99b - Test-MSLearnProfileSchemaPopulation.ps1` is the only population validator maintained during the Schema 2.4 experiment. Run it for the repeatable validation workflow. It reads `Data/CredentialUsers.beta.csv` and can show every enabled user, one selected user, or an aggregate count summary. The raw external item is connection-specific, but `/profile/certifications` and `/profile/awards` return the user's composed Microsoft 365 profile. When production and Beta connectors coexist, `99b` therefore verifies that every Beta item is present without requiring the shared profile count to equal the Beta connector count.

Schema 2.4 stores the experiment in three different properties, so each layer must be validated against the correct endpoint:

| Schema 2.4 property | Representation | Direct validation |
|---|---|---|
| `certifications` | `personCertifications` | `/users/{id-or-UPN}/profile/certifications` |
| `appliedSkillsAwards` | `personAwards` projection | `/users/{id-or-UPN}/profile/awards` |
| `microsoftAppliedSkills` | Custom connector property | Raw external item or Step 03b read-back/report |

### Validate another user's Profile API facets

Use the user's Entra object ID or user principal name in place of `me`. The following example is read-only:

```powershell
Connect-MgGraph `
    -Scopes "User.Read.All" `
    -NoWelcome

$UserPrincipalName = "user@contoso.com"
$EncodedUser = [Uri]::EscapeDataString($UserPrincipalName)

$Certifications = Invoke-MgGraphRequest `
    -Method GET `
    -Uri "https://graph.microsoft.com/beta/users/$EncodedUser/profile/certifications" `
    -OutputType PSObject

$Awards = Invoke-MgGraphRequest `
    -Method GET `
    -Uri "https://graph.microsoft.com/beta/users/$EncodedUser/profile/awards" `
    -OutputType PSObject

$Certifications.value |
    Select-Object `
        id,
        certificationId,
        displayName,
        issuedDate,
        endDate |
    Format-Table -AutoSize

$Awards.value |
    Select-Object `
        id,
        displayName,
        issuedDate,
        issuingAuthority,
        webUrl |
    Format-Table -AutoSize
```

Use delegated `User.Read` for the signed-in user's own profile. Step 99b performs cross-user batch validation, so it requests delegated `User.Read.All` and verifies that the scope is present in the access token. This permission requires tenant administrator consent. A token containing only `User.Read` returned `403 ErrorAccessDenied` for `/users/{id-or-UPN}/profile/*` in the tested tenant.

### Validate the raw Schema 2.4 external item

The custom `microsoftAppliedSkills` property is not a native Profile API certification or award facet. Validate it from the external item written by Step 03b. This requires a delegated or application permission supported by the external-item GET operation, such as `ExternalItem.Read.All`, or the connector application's existing owned-item permission.

The beta script generates the external item ID from the configured prefix (default `u`) plus the user's Entra object ID with punctuation removed:

```powershell
Connect-MgGraph `
    -Scopes "ExternalItem.Read.All" `
    -NoWelcome

$ConnectionId = "mslearncredbeta"
$ExternalItemIdPrefix = "u"
$EntraObjectId = "00000000-0000-0000-0000-000000000000"

$ExternalItemId =
    $ExternalItemIdPrefix +
    ($EntraObjectId -replace "[^A-Za-z0-9]", "")

$ExternalItem = Invoke-MgGraphRequest `
    -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/external/connections/$ConnectionId/items/$ExternalItemId" `
    -OutputType PSObject

$ExternalItem.properties |
    Select-Object `
        certifications,
        microsoftAppliedSkills,
        appliedSkillsAwards,
        title,
        sourceUrl,
        lastModifiedBy,
        lastModifiedDateTime |
    Format-List
```

`ExternalItem.Read.All` requires administrator consent. Step 03b already performs an immediate read-back after every PUT and records the result in its log/report, so that built-in validation is preferable when additional delegated consent is not desired.

A successful raw-item read confirms ingestion. A successful Profile API read confirms that the semantic facet can be retrieved. Neither confirms that Profile Card, Search or Copilot propagation has finished.

## Suggested validation prompts

- What Microsoft certifications does Claudio Bravo have?
- What Microsoft Applied Skills credentials does Claudio Bravo have?
- Does Claudio Bravo have any Microsoft credentials?
- Who has Microsoft certifications?
- Who has Microsoft Applied Skills?
- Who has credentials related to Microsoft Purview?
- Who has scenario-based credentials related to Microsoft 365 Copilot?
- Who has both Microsoft Certifications and Microsoft Applied Skills?

Expected behavior: Applied Skills should be discoverable as Applied Skills, but they should not cause a user with zero Microsoft Certifications to be described as certified solely because of the Applied Skills data.

## Microsoft Learn transcript mapping

The beta script reads:

`appliedSkillsData.appliedSkillsCredentials`

and maps:

- `title`
- `credentialId`
- `awardedOn`

The transcript endpoint is a public web endpoint used by this reference implementation and should be monitored for changes.

No files under `/Source` or `/Support` are modified by this beta experiment.
