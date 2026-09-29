# Beta – Schema 2.4 Applied Skills experiment

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

## Isolation controls

The beta defaults are different from production:

- Schema version: `2.4`
- Application display name: `MSLearn People Connector Beta`
- Connection ID: `mslearncredbeta`
- Configuration file: `Config/MSLearnPeopleConnector.beta.json`
- User file: `Data/CredentialUsers.beta.csv`

Steps 02b and 03b stop if `Connector.ConnectionId` does not contain `beta`.

Do not point these scripts at the production configuration.

## Files

- `00b - Initialize-MSLearnPeopleConnector.ps1`
- `01b - Create-MSLearnPeopleConnectorApp.ps1`
- `02b - New-MSLearnPeopleConnector.ps1`
- `03b - Sync-MSLearnCredlyPeopleProfiles.ps1`
- `MSLearnPeopleConnector.beta.sample.json`

## Execution order

1. Copy/download the **Beta** folder to an isolated working directory.
2. Run `00b`.
3. Populate only `Data/CredentialUsers.beta.csv` with test users.
4. Run `01b` against the test tenant.
5. Grant the requested Graph application permissions/admin consent.
6. Run `02b` to create the `mslearncredbeta` connector with Schema 2.4.
7. Run `03b`.
8. Validate Profile Card, Microsoft 365 Search and Copilot before considering any production change.

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
