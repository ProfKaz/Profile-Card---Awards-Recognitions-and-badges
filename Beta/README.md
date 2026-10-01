# Beta — Entra branding validation

This preview validates application-logo branding independently before the behavior is added to the production provisioning or migration script.

## Files

- `90b - Test-M365ProfileCardAwardsEntraBranding.ps1`: reads the existing operational configuration, validates Microsoft Graph access and applies/verifies the configured App Registration logo.
- `Assets/m365-profile-card-awards-entra-215.png`: Entra-compatible image (215 × 215 PNG, opaque background, under 100 KB).

The test does not modify the JSON configuration, external connection, schema, profile source, user items or Copilot visibility.

## Prerequisites

- PowerShell 7 or later.
- `Microsoft.Graph.Authentication` and `Microsoft.Graph.Applications` installed.
- An account able to consent to and use delegated `Application.ReadWrite.All` for the configured tenant and application.
- An existing operational `Config/MSLearnPeopleConnector.json` populated by Steps 00 and 01.

The script resolves `Application.TenantId`, `Application.ApplicationObjectId` and `Application.ClientId` from that configuration. It rejects an Object ID/Client ID mismatch so the logo cannot silently be applied to another App Registration.

## Validation sequence

Keep the script and `Assets` folder together. First run the non-mutating preflight:

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

1. Downloads the existing logo when one is available.
2. Applies the Beta asset with `Set-MgApplicationLogo`.
3. Downloads the stored logo again.
4. Requires its SHA-256 to match the submitted image.
5. Prints a restore command when a previous logo was backed up.

Backups and verification files are written under the configured `Output.ReportsDirectory/Branding` path. Use `-BackupDirectory` to select another location. `-WhatIf` is also supported.

## Promotion gate

Do not update Step 01 until the full test succeeds against the intended tenant and the new logo is visible in Entra after normal portal propagation. The Microsoft 365 connector icon remains a separate administrative concern because the public `externalConnection` Graph resource does not expose an icon property.
