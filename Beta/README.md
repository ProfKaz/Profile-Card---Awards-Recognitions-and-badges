# Beta — upcoming releases

<p align="center">
  <img src="../Assets/Branding/beta/m365-profile-card-awards-beta-512.png" alt="M365 Profile Card Awards Beta shield" width="200">
</p>

This folder is reserved for upcoming preview versions of **M365 Profile Card Awards**. New versions will be released here with their corresponding version number, detailed changes, configuration/schema requirements, known limitations, validation instructions and promotion status.

## Current status

Schema **2.4** was promoted to [Source](../Source/README.md) on **October 1, 2026**. There are currently no preview scripts or configuration samples in this folder. The promoted implementation includes Microsoft Applied Skills, the dual custom-property/award representation, synchronization fixes, branding and the population validator.

Use the production scripts in `Source` and the sanitized sample in `Support/MSLearnPeopleConnector.sample.json`. Previous Beta scripts remain available through Git history.

## Future preview release details

Each preview release will document:

- Version, release date, purpose and changes from production.
- Script list and execution order.
- Schema/configuration changes and compatibility requirements.
- Separate preview application, connection, configuration and user mappings.
- Validation results, known issues and migration/rollback instructions.
- Whether it is still under evaluation or has been promoted to production.

The Beta identity and icons remain reserved for preview deployments. Publishing this repository change does not rename, delete or migrate existing tenant connections or their external items. See [the production migration guide](../Source/README.md#upgrade-from-schema-23-or-a-beta-working-directory).
