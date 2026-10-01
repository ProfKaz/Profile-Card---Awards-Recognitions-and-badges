# Remove user items without changing schemas

Use [98-Remove-MSLearnConnectorUserItems.ps1](98-Remove-MSLearnConnectorUserItems.ps1)
after the [read-only duplicate diagnostic](Profile-Credential-Duplicate-Diagnostics.md).
Copy it from Support into the operational project root and run PowerShell 7 there.
No files in Source or Beta need to be modified.

## Confirmed pilot pattern

The reviewed pilot contained 11 unique credential entries in each of two
connections: eight Microsoft Learn certifications and three Credly badges.
The source credential payloads were identical. The shared Profile API contained
22 records with 22 distinct record IDs but only 11 certification IDs. Every pair
had one `sources[].sourceId` for the 2.3 source and one for the 2.4 Beta source.
There were no read failures and no awards or Applied Skills for that pilot user.

This confirms overlapping contributions from two sources in that pilot.
It does not validate Applied Skills cleanup, every tenant user, or the propagation
behavior of deletion. No uploaded user report or tenant identity is published here.

## Recommended first test: retire only the old source for one user

Pause both sync jobs for the selected user. Preview the old 2.3 item:

```powershell
& '.\98-Remove-MSLearnConnectorUserItems.ps1' `
    -ConfigPaths @('Config\MSLearnPeopleConnector.json') `
    -UserPrincipalName 'user@contoso.com'
```

Review the connection ID, user and item ID. A preview makes no Graph changes.
To simulate deletion decisions, append `-Execute -WhatIf`.
Local reports are written even in WhatIf mode.

To perform that same selected cleanup, append `-Execute`:

```powershell
& '.\98-Remove-MSLearnConnectorUserItems.ps1' `
    -ConfigPaths @('Config\MSLearnPeopleConnector.json') `
    -UserPrincipalName 'user@contoso.com' `
    -Execute
```

The Beta item remains. After propagation, the expected pilot state is 11
certifications from Beta and no records from the old source. The Profile API
and profile card must be checked to establish that this actually happened.

## Reset both source contributions

To clear both known items before republishing through only 2.4:

```powershell
& '.\98-Remove-MSLearnConnectorUserItems.ps1' `
    -ConfigPaths @(
        'Config\MSLearnPeopleConnector.json',
        'Config\MSLearnPeopleConnector.beta.json'
    ) `
    -UserPrincipalName 'user@contoso.com'
```

This is again preview only. Append `-Execute` after reviewing the plan.
Removing an item removes its certifications, mapped awards and custom properties
at the source. The script does not directly delete materialized Profile API facets.

For multiple selected users, supply an array to `-UserPrincipalName`.
For every CSV row, explicitly replace that parameter with `-AllCsvUsers`.
This includes disabled rows because old data may remain after sync is disabled.
Each config uses its own CSV; all supplied configs must target the same tenant.
Unknown historical item IDs and different prefixes are outside automatic scope.

## Controls and output

- Uses the existing connector application's credentials and permissions.
- Validates CSV identity and existing item's account mapping. Conflicting UPN
  or object ID stops preflight.
- Reads every target and writes a complete backup before any deletion.
- Aborts all deletes if any preflight read or authentication fails.
- Treats an explicit HTTP 404 as already absent; other errors are failures.
- Re-reads each item and refuses deletion if its JSON snapshot changed.
  This check is not an atomic lock: keep sync paused throughout maintenance.
- Supports `-WhatIf` and `-Confirm`; requires `-Execute` for Graph deletion.
- Deletes only `/external/connections/{id}/items/{itemId}`.
  Schemas, connections, applications, profile sources, precedence, Entra users
  and mailboxes are not modified.
- Saves backup JSON, per-item results CSV and, after accepted deletes, a waiting
  instruction JSON with a recommended UTC revalidation time.

Backups contain personal data and full externalItems; protect Reports and do not
commit them. Configuration secrets and tokens are not serialized.
Backups preserve evidence; this utility does not implement automatic restoration.

`RemovedAtSource` means the post-delete source read returned 404.
`DeleteAcceptedStillReadable` and verification failures require investigation.
No result means profile-card deletion has already propagated.

## Wait and validate before republishing

Keep synchronization paused for **at least 12 hours after the last accepted
deletion**, then inspect the shared Profile API and the card. Twelve hours is an
operational minimum, not a Microsoft SLA or a promise that deletion is complete.
If source-owned facets remain, diagnose them before republishing.

Once verified, run only the intended 2.4 sync for the selected users. Do not run
2.3 again for those users: that can restore the overlapping contribution.
For a full reset of both sources, the intermediate expectation is zero facets
owned by those sources; unrelated sources or manually added credentials can remain.

The duplicate diagnostic records a missing source item as an incomplete read;
that is expected for a deleted item. Inspect its raw shared-profile evidence
and `sources[].sourceId` instead of relying on its item-read failure alone.

## Permissions and limitations

[Delete externalItem](https://learn.microsoft.com/en-us/graph/api/externalconnectors-externalitem-delete?view=graph-rest-1.0)
supports application `ExternalItem.ReadWrite.OwnedBy` or the higher-privilege
`ExternalItem.ReadWrite.All` already used by this project's operational configs.
Deleting source items and observing removal of materialized profile data are
separate validation steps.

No live tenant deletion was performed during authoring. Static checks completed;
PowerShell runtime execution and end-to-end source-to-profile removal remain
to be verified by the one-user pilot.
