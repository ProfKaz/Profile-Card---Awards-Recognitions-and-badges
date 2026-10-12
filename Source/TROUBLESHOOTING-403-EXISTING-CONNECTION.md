# Troubleshooting: Step 02 fails with HTTP 403 on an existing connection

## Symptom

`02 - New-MSLearnPeopleConnector.ps1` authenticates successfully using app-only Microsoft Graph authentication, but fails at **STEP 3 - Create or reconcile the People external connection**:

```text
GET https://graph.microsoft.com/v1.0/external/connections/mslearncred
403 Forbidden
AccessDenied: The client doesn't have permission to perform the action.
```

This is **not** evidence of a PowerShell module failure, and running unrelated scripts in a different PowerShell window does not normally cause it. Successful app-only sign-in and admin consent establish the token's permissions, not ownership of an individual pre-existing external connection.

## Root cause to check first

`ExternalConnection.ReadWrite.OwnedBy` only authorizes operations on connections that the application created or is explicitly authorized to manage. A previous deployment can leave `mslearncred` owned by a **different application/client ID**. Changing the Entra application without changing the persistent connection ID can therefore produce this failure even when API permissions and admin consent are correct.

This is a **diagnosis to confirm**, not proof of ownership from an export alone.

### Example from an October 2026 deployment

- Configured connection ID: `mslearncred`.
- Current application (client) ID: `ae179187-b21f-4dd3-9d0d-8fa3633a3235`.
- Microsoft 365 admin center export reported `connectionState: Ready`, `indexedItemCount: 0`, and an older **two-property** schema.
- The current Schema 2.4 contract expects **eight properties**.
- The export exposed `authorizedObjectIds`, **not** Microsoft Graph `configuration.authorizedAppIds`. Do **not** equate these two properties or interpret either as proof that the current application owns the connection.
- Do not commit tenant exports, tenant IDs, secrets, or user data to this repository.

## Preferred resolution: authorize the new app without deleting the connector

1. **Back up** the Copilot connector export and record the current connection settings. Do not delete `mslearncred`, the profile source, or schema as the initial remedy.
2. Open a fresh PowerShell 7 session and authenticate as an authorized administrator using a delegated Microsoft Graph identity that can **read and update this connection** (for example, a suitably privileged identity with consented `ExternalConnection.ReadWrite.All`). Merely having an Entra administrator role is not a substitute for an effective Graph token and permissions.
3. Read the actual Microsoft Graph connection:

   ```powershell
   Connect-MgGraph -Scopes "ExternalConnection.ReadWrite.All" -NoWelcome

   $connectionId = "mslearncred"
   $newClientId = "<CURRENT-CONNECTOR-APPLICATION-CLIENT-ID>"
   $uri = "https://graph.microsoft.com/v1.0/external/connections/$connectionId"

   $connection = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject -ErrorAction Stop
   $connection | Select-Object id, name, contentCategory, state, configuration | Format-List
   ```

4. Preserve existing authorized application IDs and add the **application/client ID** (not the Entra service principal object ID). Review the resulting list before sending the PATCH:

   ```powershell
   $existingIds = @(
       if ($null -ne $connection.configuration -and $null -ne $connection.configuration.authorizedAppIds) {
           $connection.configuration.authorizedAppIds
       }
   )
   $authorizedIds = @($existingIds + $newClientId | Where-Object { $_ } | Select-Object -Unique)
   $authorizedIds

   # Confirm the list above is correct and no existing app will be removed.
   $body = @{ configuration = @{ authorizedAppIds = $authorizedIds } } |
       ConvertTo-Json -Depth 10

   Invoke-MgGraphRequest -Method PATCH -Uri $uri -Body $body `
       -ContentType "application/json" -ErrorAction Stop

   $verified = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject
   $verified.configuration.authorizedAppIds
   Disconnect-MgGraph
   ```

   **Do not blindly replace** `authorizedAppIds` with only the new ID: other legitimate ingestion applications may already be authorized. The PATCH requires a caller who is authorized to modify the **existing** connection; running it as the still-unauthorized new app will likely receive 403 again.

5. Re-run Step 02 with the existing app-only configuration. It should now be able to read `mslearncred`; let its schema reconciliation compare the older schema with the Schema 2.4 contract. **Do not use `-ForceSchemaUpdate` initially.**
6. Verify schema/state using the project's Step 99 validator and then continue with Step 03 synchronization as appropriate. Profile-card display can propagate asynchronously.

If a permitted delegated read of the connection still returns 403, check the token's effective permissions, tenant, administrative access, conditional access, and the connection's authorization state before modifying anything. If the application already appears in `authorizedAppIds`, investigate token issuance/permissions and service-side authorization; do not assume an ownership mismatch.

## Alternative: reuse the original application

If the original Entra application and its credential are still available, and using that application is acceptable, updating the **local configuration** to use its original Client ID and valid secret may be even simpler. Validate the tenant and the original app's assigned Graph permissions first. Do not publish credentials or secrets.

## Last resort: recreate only in a disposable test environment

Deleting a connector can remove its schema, indexed items and profile-source configuration. A reported `indexedItemCount: 0` is **not** proof that nothing else depends on the connection. Re-create the connection **only after** checking dependencies, authorization, a backup and an explicit decision to accept data loss/reprovisioning. Never automate deletion in Step 02 in response to HTTP 403. This is not the recommended production recovery path.

## Implementation note

The existing Step 02 `Get-ExternalConnection` helper treats 404 as connection-not-found and rethrows other failures. A 403 is an **authorization error, not a missing connection**. It must never trigger `POST` to silently create a replacement. A future improvement could catch 403 to print actionable instructions and the connection ID without swallowing the error.

## References

- [Microsoft Graph: update externalConnection](https://learn.microsoft.com/en-us/graph/api/externalconnectors-externalconnection-update)
- [Microsoft Graph: externalConnectors configuration and authorizedAppIds](https://learn.microsoft.com/en-us/graph/api/resources/externalconnectors-configuration)
- [Microsoft 365 Developer Blog: fine-grained connector permissions](https://devblogs.microsoft.com/microsoft365dev/breaking-changes-to-the-microsoft-graph-connectors-api-beta/)
