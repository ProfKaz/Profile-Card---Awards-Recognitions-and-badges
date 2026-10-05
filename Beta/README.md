# Beta — Preview scripts and diagnostics

This preview validates application-logo branding independently before the behavior is added to the production provisioning or migration script.

## Files

- `90b - Test-M365ProfileCardAwardsEntraBranding.ps1`: reads the existing operational configuration, obtains the published branding asset, validates Microsoft Graph access and applies/verifies the configured App Registration logo.
- `Assets/m365-profile-card-awards-entra-215.png`: Entra-compatible image (215 × 215 PNG, opaque background, under 100 KB).

The test does not modify the JSON configuration, external connection, schema, profile source, user items or Copilot visibility.

## Prerequisites

- PowerShell 7 or later.
- `Microsoft.Graph.Authentication` and `Microsoft.Graph.Applications` installed.
- An account able to consent to and use delegated `Application.ReadWrite.All` for the configured tenant and application.
- An existing operational `Config/MSLearnPeopleConnector.json` populated by Steps 00 and 01.

The script resolves `Application.TenantId`, `Application.ApplicationObjectId` and `Application.ClientId` from that configuration. It rejects an Object ID/Client ID mismatch so the logo cannot silently be applied to another App Registration.

## Validation sequence

The script can be downloaded and executed without downloading the `Assets` folder. It first checks for `Assets/m365-profile-card-awards-entra-215.png` beside the script. If that file is unavailable, it downloads the published image from this repository to a uniquely named temporary file, validates its SHA-256 and image contract, and removes it in `finally`, including after an error.

Supplying `-LogoPath` continues to require and use that explicit local file instead of downloading the published asset.

First run the non-mutating preflight:

```powershell
& '.\Beta\90b - Test-M365ProfileCardAwardsEntraBranding.ps1' `
    -ConfigPath '.\Config\MSLearnPeopleConnector.json' `
    -ValidateOnly
```

This validates the configuration, image contract, required modules, authenticated tenant, delegated Graph scope and configured application identity. It does not change the logo.

Then run the full Beta test:

```powershell
& '.\Beta\90b - Test-M365ProfileCardAwardsEntraBranding.ps1' `
    -ConfigPath '.\Config\MSLearnPeopleConnector.json'
```

The full test:

1. Resolves the local branding asset or downloads and validates the published image.
2. Reads the supported read-only `Application.Info.LogoUrl` and downloads the existing logo for backup when one is available.
3. Applies the Beta asset with `Set-MgApplicationLogo`.
4. Refreshes `logoUrl` and retries the CDN download briefly after the update.
5. Requires the downloaded image SHA-256 to match the submitted image.
6. Prints a restore command when a previous logo was backed up.

The binary application `logo` property is not read directly because Graph can return `Request_UnsupportedQuery`; retrieval uses the generated `logoUrl` instead.

Backups and verification files are written under the configured `Output.ReportsDirectory/Branding` path. Use `-BackupDirectory` to select another location. `-WhatIf` is also supported.

## Promotion gate

Do not update Step 01 until the full test succeeds against the intended tenant and the new logo is visible in Entra after normal portal propagation. The Microsoft 365 connector icon remains a separate administrative concern because the public `externalConnection` Graph resource does not expose an icon property.

## Connector payload diagnostics (Step 98b)

Added on 2026-10-05, version 1.0.0.

The read-only `98b - Export-MSLearnConnectorPayload.ps1` captures evidence when an externalItem is available to Copilot but its certifications are absent from the Microsoft 365 Profile API. It reads the operational configuration and CSV; no tenant IDs, user IDs or credentials are hardcoded.

Requirements: PowerShell 7+, the installed Microsoft.Graph.Authentication module, and the existing application credentials with permission to read this connection's externalItems. No delegated Profile API sign-in is required.

Copy the script into the operational folder, or execute it from Beta with an explicit configuration path:

```powershell
& '.\Beta\98b - Export-MSLearnConnectorPayload.ps1' `
    -ConfigPath '.\Config\MSLearnPeopleConnector.json' `
    -UserPrincipalName 'enieto@unlimitech.ai','p-gballadares@unlimitech.ai'
```

UserPrincipalName accepts one or more UPNs. The script resolves each user's EntraObjectId from the mapped CSV columns and applies the configured Synchronization.ExternalItemIdPrefix (default: u). Explicitly selected users can be exported even if their CSV row is disabled. Relative CSV paths are resolved from the operational root above the Config folder.

Each run creates a unique timestamped folder under Reports/ConnectorPayload, or under the directory supplied with -OutputDirectory. It contains:

- UPN-externalItem.json: complete Graph externalItem response, preserving the original JSON-encoded strings in the properties.
- UPN-certifications-decoded.json: successfully decoded certification objects.
- UPN-json-checks.json: element indexes, UTF-8 byte sizes and JSON parsing errors.
- manifest.json: script version, UTC export time, connection ID, result counts and SHA-256 hashes of the externalItem exports.

The script only performs GET requests to Graph. It does not change the schema, connection, profile data or operational configuration. Configuration and credentials are not exported. It disconnects its process-scoped Graph session after execution. Exported payloads contain user credential data; share the evidence with the intended diagnostic audience rather than committing it here.

JSON checks validate that each collection element is a string containing a JSON object. They do not validate the complete personCertification contract, confirm materialization, or establish a numeric limit on profile credentials.

Export the affected user and a working comparison user before reducing the Credly window, then export again after synchronization to preserve both payloads.
