# Support

This folder contains sanitized reference material for the project.

## MSLearnPeopleConnector.sample.json

The sample JSON mirrors the configuration model used by the scripts while deliberately excluding tenant-specific and secret values.

The following fields are intentionally empty:

- `Application.TenantId`
- `Application.ClientId`
- `Application.ApplicationObjectId`
- `Application.ServicePrincipalObjectId`
- `Authentication.ClientSecret`
- `Authentication.SecretKeyId`
- `Authentication.SecretExpirationUtc`

Those values must be generated or populated in the local operational configuration. They must never be committed to a public repository.

## Configuration sections

### SchemaVersion

Identifies the expected configuration contract. The current project baseline is `2.2`.

### Application

Stores the Entra application identity created in Step 01.

Environment-specific identifiers are blank in the public sample.

### Authentication

Defines how the scripts authenticate as the application.

The current PoC uses a client secret. For production deployments, consider certificate-based authentication or another protected secret mechanism.

### MicrosoftGraph

Contains Microsoft Graph endpoints and the application permissions required by the solution.

The Microsoft Graph resource application ID:

`00000003-0000-0000-c000-000000000000`

is a Microsoft first-party constant, not a tenant-specific value.

### ManagementUrls

Contains safe Microsoft administration/documentation entry points in the public sample.

The operational Step 01 script can replace these with application-specific management URLs after the Entra application is created.

### Connector

Defines the People Data Connector identity and profile source behavior.

Important defaults:

- `ConnectionId`: `mslearncred`
- `ContentCategory`: `people`
- `ProfileSourceKind`: `MicrosoftLearn`

The following values are Microsoft profile-service constants rather than private tenant identifiers:

- `ProfilePropertySettingId = 00000000-0000-0000-0000-000000000001`
- `EntraIdSourceId = 4ce763dd-9214-4eff-af7c-da491cc3782d`

### Schema

Defines the mapping between connector properties and Microsoft 365 people profile entities.

The default project schema publishes:

- `accountInformation` as `personAccount`
- `certifications` as `personCertifications`

### Provisioning

Controls how long Step 02 waits for the connector schema to become ready and how frequently it polls Microsoft Graph.

### CredentialSources

Controls Microsoft Learn and Credly ingestion.

Default behavior:

- Microsoft Learn enabled.
- Credly enabled.
- Credly rolling window set to 12 months.

### UserSource

Points to the controlled user mapping file.

Default:

`Data\CredentialUsers.csv`

### FieldMapping

Maps the configured source columns to the fields Step 03 expects.

### Synchronization

Controls stale managed credential cleanup, preservation of unmanaged values, per-user error handling and dry-run behavior.

### Output

Defines the locations for PowerShell transcripts/logs and structured reports.

### Documentation

Contains safe public documentation links. These values are informational and contain no tenant-specific data.

## Security recommendation

The public sample is safe to commit because it contains no operational credentials or tenant/application identifiers.

The real local file `Config\MSLearnPeopleConnector.json` can contain confidential authentication data. Protect it as a secret-bearing configuration artifact and exclude it from source control.
