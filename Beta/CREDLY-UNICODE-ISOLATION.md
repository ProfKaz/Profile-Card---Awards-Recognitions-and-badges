# Credly Unicode isolation experiment (Schema 2.4)

**Beta-only diagnostic**: `03c - Test-CredlyUnicodeIsolation.ps1`. This does not change the production Step 03, connection schema, or existing users. Use a tenant where `mslearncred` is already configured and ready.

## Hypothesis

The Profile API may fail to materialize some/all certificates when the Credly source contains U+200B ZERO WIDTH SPACE. This is an **unconfirmed hypothesis**. The experiment isolates character presence while keeping the same source, tenant, connection, schema, date window, write method and execution time. Each scenario has its own newly created Entra user.

| Scenario | Eligible badges (12 months) | Transformation |
|---|---|---|
| `WithoutU200B` | Raw Credly badge names **without** U+200B | No string normalization |
| `OnlyU200B` | Raw Credly badge names **with** U+200B | No string normalization |
| `Normalized` | All eligible Credly badges | Remove Unicode Format characters from name/issuer/description, apply NFC and collapse whitespace |

**Important:** The third scenario also differs in badge count from the first two. Results therefore require cautious interpretation. In addition, only the *badge name* determines U+200B inclusion; other fields can contain special characters. All three scenarios use a strict 12-month window from the day of execution, independent of `CredentialSources.Credly.MonthsBack`.

## Prepare three NEW test users

Create three licensed (if required for the profile experience) internal Entra users. Obtain their exact immutable **Entra user object IDs** (not tenant ID or application ID). They must not have existing externalItems in the test connector.

Create `Data/CredlyUnicodeTestUsers.csv` locally, **not in GitHub**, encoded UTF-8:

```csv
Scenario,UserPrincipalName,EntraObjectId
WithoutU200B,usuario.sinunicode@example.com,11111111-1111-4111-8111-111111111111
OnlyU200B,usuario.conunicode@example.com,22222222-2222-4222-8222-222222222222
Normalized,usuario.normalizado@example.com,33333333-3333-4333-8333-333333333333
```

Replace example UPNs and GUIDs with real identities. **Do not use the production `CredentialUsers.csv` or `CredentialUsers-Sample.csv`**: they use a different set of headers and serve a different purpose. The beta test accepts exactly three rows with the three headers shown above.

## Run

Download this script into a `Beta` subfolder under the **same working directory** where `Config/MSLearnPeopleConnector.json` exists. Relative paths for `-UsersCsv` are resolved from the current PowerShell directory; the default configuration path is resolved from the script's parent solution folder.

```powershell
# Run while your prompt is in the solution's Beta folder:
# & '.\\03c - Test-CredlyUnicodeIsolation.ps1' -UsersCsv '..\\Data\\CredlyUnicodeTestUsers.csv'

# Or, from the solution root, always preview first (no Graph sign-in or writes)
& '.\Beta\03c - Test-CredlyUnicodeIsolation.ps1' -UsersCsv '.\Data\CredlyUnicodeTestUsers.csv'

# Only after reviewing the preview, publish the three test externalItems
& '.\Beta\03c - Test-CredlyUnicodeIsolation.ps1' -UsersCsv '.\Data\CredlyUnicodeTestUsers.csv' -Publish
```

The script downloads fresh public data from `https://www.credly.com/users/elias-nieto.65efb4e7/badges.json`, applies the 12-month cutoff and publishes stringified certifications using the same representation as production Step 03. It reads the operational JSON for authentication, Graph endpoint, schema names and connection ID. There is no CSV import/export for badge payloads, eliminating local spreadsheet encoding changes. A test user mapping CSV is used **only** for destination identities.

**Safety:** Preview is the default. `-Publish` writes. If any target item already exists, all writes are blocked unless `-Overwrite` is explicitly added. `-Overwrite` replaces complete externalItems, so use it only for dedicated test accounts; never for production users. Preflight checks all three before writing.

## Record the results

Run Step 99 in detailed mode for all three test users after adding them as enabled rows to the usual `Data/CredentialUsers.csv` (with source usernames blank if you do not want the production Step 03 to synchronize them). **Do not run the production Step 03 over these three experimental users**; that would rewrite the prepared externalItems and invalidate the comparison. If Step 99 requires source identifiers, use the same Credly username in the CSV mapping but still do not run Step 03.

Record per user:
- exact UTC time of PUT and GET read-back;
- expected external certification count and actual read-back;
- Profile API certification count and IDs at each observation;
- whether the Profile Card UI displays the same entries;
- latency and any Graph error response or service diagnostics.

The PUT/read-back confirms connector storage, **not** Microsoft 365 profile materialization. `Pending` in Step 99 is the validator's classification, not necessarily a service error. Avoid interpreting a result before allowing a comparable propagation window for all three users.

## Interpretation matrix

- WithoutU200B materializes, OnlyU200B does not: supports (but does not prove) a U+200B effect.
- All three materialize: original issue may have been transient or affected by a different set of badges.
- Normalized materializes but raw cases do not: normalization may help, but counts and other characters still confound.
- All remain pending: investigate source precedence, downstream materialization, externalItem schema and service processing before changing Step 03.
- Partial materialization: compare exactly which certification IDs appeared.

Do not remove Unicode formatting in production until evidence supports a change. This experiment is deliberately diagnostic, not a permanent policy for badges.

## Fix: relative CSV path and Schema.Labels errors

The first beta revision used .NET's process working directory to resolve relative `-UsersCsv` paths; this could unexpectedly turn `..\\Data\\...` into `C:\\Users\\Data\\...`. This is corrected: relative CSV paths now use the current PowerShell location. The schema label resolver previously assumed every schema entry had a `Labels` property; `AppliedSkillsProperty` and other custom properties can legitimately omit it. The resolver now safely skips unlabeled properties under PowerShell strict mode. The script also reports a specific error if a standard Step 03 CSV is supplied instead of the required three-row beta mapping.

## Fix: optional Credly configuration under PowerShell StrictMode

If the preview fails with `The property 'ProfileBaseUrl' cannot be found`, the configuration has intentionally omitted an optional value. The beta test now uses the same defaults as the production Step 03: `ProfileBaseUrl = https://www.credly.com/users` and `BadgesEndpointSuffix = badges.json`. Optional `Synchronization.ExternalItemIdPrefix` defaults to `u`. Optional badge fields (`expires_at_date`, `earner_path`, `image_url`, and issuer entity nesting) are read safely without changing the raw Credly JSON. **Do not add these optional properties to the production configuration solely to work around beta errors.**
