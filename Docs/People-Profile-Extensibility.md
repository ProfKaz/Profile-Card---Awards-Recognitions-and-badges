# Extending People Profiles: Custom Properties, Skills, and Limits

M365 Profile Card Awards | Documentation reviewed: September 30, 2026. Implementation promoted: October 1, 2026.

## 1. Choose the representation

A new credential provider or internal capability inventory can reuse this connector architecture. Decide what each value means before choosing its destination.

| Representation | Recommended use | Validation |
|---|---|---|
| Native entity with a person* label | A supported profile concept | External item and composed profile facet |
| Custom property without a semantic label | Organization-specific context | External item, Search and Copilot |
| Native visual projection plus custom context | A credential whose detailed semantics need preservation | Validate both representations separately |

A property name alone does not map data to a native entity. For example, naming a field skills without assigning personSkills does not create a native skills mapping. Ingestion, profile composition, search retrieval and card presentation are separate checks. [1]

### Current repository behavior

Production Source now uses Schema 2.4: Microsoft Learn certifications and recent Credly entries are published through certifications / personCertifications, with Microsoft Applied Skills represented through two additional properties. The previously tested Beta implementation was promoted on October 1, 2026.

| Production property | Label | Role |
|---|---|---|
| certifications | personCertifications | Existing certifications |
| microsoftAppliedSkills | None | Custom semantic context for Applied Skills |
| appliedSkillsAwards | personAwards | Award projection for profile presentation |

The custom property contains one YAML-like text block per credential: type, name, ID, issue date, issuer, source and transcript URL. The award projection is a project design choice, not a Microsoft Applied Skills-specific profile entity. Applied Skills are not added to personCertifications. This preserves the distinction between a scenario-based credential and a Microsoft Certification.

The other examples in this guide are extension patterns. They are not additional features already implemented by the scripts. See the [Source guide](../Source/README.md) for the tested implementation.

## 2. Quantities and limits: count the right thing

| Scope | Published quantity | Interpretation | Source |
|---|---|---|---|
| Schema properties per connection | 1 to 128 | Total properties, including identity and metadata | [2] |
| Schema property name | Up to 32 characters; alphanumeric | Names such as deliveryCapabilities | [3] |
| Schema property description | Up to 200 characters | Keep semantic guidance concise | [3] |
| Item ingestion size | 30 MB request-body limit | Not a credential count | [4] |
| personAddresses | Up to 3; one per Home, Work, Other | Native address mapping | [1] |
| personEmails | Up to 3 | Native email mapping | [1] |
| Entra card extension attributes | 15 available attributes | Separate profileCardProperty mechanism | [5] |
| Awards, certifications, skills or custom collection entries per person | No numeric maximum established by the reviewed people-connector/entity references | Do not claim unlimited capacity or invent a universal count | [1], [6], [7] |

### Example: properties are not credentials

The sample Schema 2.3 defines six properties. The sample Schema 2.4 defines eight, including the two Applied Skills properties. Ten Applied Skills entries inside microsoftAppliedSkills still use one schema property. The same ten credentials projected inside appliedSkillsAwards use one more property. They remain ten credentials represented twice for different purposes.

The 128-property limit does not mean 128 certifications, 128 people, or 128 fields visible on the card. Nor does the API limits table's property-size entry of N/A establish unlimited profile storage. Validate large collections with realistic payloads and tenant behavior.

### Custom fields on the card

Connector custom properties and the older Entra extension-attribute mechanism have different contracts. The 15 Entra extension attributes do not define the custom-field quota of a people connector. The Entra mechanism documents custom fields as nonsearchable; people-connector indexing must be assessed separately. [5]

For forthcoming connector custom-field presentation, verify Message Center MC1193692 and Roadmap 529851 in the target tenant. The reviewed public profile-card administration article does not establish that display quota. This guide therefore does not assert a universal card custom-field count or assume rollout is complete. A searchable custom property should not be promised as an automatically rendered card field.

## 3. Native profile properties available for enrichment

The following catalog follows Microsoft's people-connector mapping table. S = string; C = stringCollection. The entity contract defines the fields inside each serialized value. [1]

| Semantic label | Type | Entity |
|---|---|---|
| personAccount | S | userAccountInformation |
| personCurrentPosition | S | workPosition |
| personAddresses | C | itemAddress |
| personAnniversaries | C | personAnniversary |
| personAwards | C | personAward |
| personCertifications | C | personCertification |
| personEducationalActivities | C | educationalActivity |
| personEmails | C | itemEmail |
| personInterests | C | personInterest |
| personLanguages | C | languageProficiency |
| personName | S | personName |
| personNote | S | personAnnotation |
| personPatents | C | itemPatent |
| personPhones | C | itemPhone |
| personPublications | C | itemPublication |
| personProjects | C | projectParticipation |
| personSkills | C | skillProficiency |
| personWebAccounts | C | webAccount |
| personWebSite | S | webSite |
| personWorkPositions | C | workPosition |

One account property with personAccount is required. personManager, personAssistants, personColleagues, personAlternateContacts and personEmergencyContacts are listed as unsupported in the builder guidance. Their presence in an enum is not sufficient evidence of working ingestion. [1]

### Practical choices for future extensions

| Business information | Candidate destination | Design decision |
|---|---|---|
| Verified certification | personCertifications | Retain issuer, ID and validity evidence |
| Internal recognition | personAwards | Preserve its original name and source |
| Governed capability such as KQL threat hunting | personSkills | Define how the capability is assessed |
| Languages | personLanguages | Use explicit language evidence |
| Delivery history | personProjects | Review customer confidentiality |
| Articles and research | personPublications | Include traceable publication links |
| Internal capability evidence or service accreditation context | Custom property | Explain meaning and limitations |

Connector support is not a promise that every entity receives its own visible card section in every application. The broader beta Profile API also contains responsibilities, but the builder table does not document a corresponding personResponsibilities label. Do not invent one. [6]

## 4. Add a custom property

Use a governed internal capability inventory as an example. The property represents recorded delivery capabilities; it does not prove certification, seniority, availability or expert proficiency.

### Schema fragment

```json
{
  "name": "deliveryCapabilities",
  "type": "stringCollection",
  "description": "Recorded delivery capabilities with evidence and review dates; not certifications or inferred proficiency."
}
```

This illustrative fragment must be merged into the existing schema, not submitted as a replacement that discards account and credential mappings. It intentionally has no semantic label.

### External-item properties fragment

```json
{
  "deliveryCapabilities@odata.type": "Collection(String)",
  "deliveryCapabilities": [
    "Capability: Microsoft Purview DLP\nEvidence: Internal practical assessment\nReviewedOn: 2026-09-30\nSource: Capability inventory\nEvidenceUrl: https://example.com/evidence/123"
  ]
}
```

For complex custom content, use meaningful text or YAML/Markdown rather than treating an opaque JSON string as the business description. Native entities use serialized JSON instead. [1]

### Changes required in this project

1. Define the source, owner, evidence standard, lifecycle and stable record key. For this example, use person ID + capability ID as the key; keep review date as mutable metadata.
2. Add a named configuration contract in the initializer and sanitized sample.
3. Extend Step 02 schema construction and schema comparison to include the new property.
4. Extend Step 03 source retrieval, normalization, deduplication and item-property construction.
5. Add the property to read-back validation and structured reporting. Define what an empty source response means before removing records.
6. Extend the validator to inspect this custom field in the raw external item. Pilot retrieval with a known positive and negative user.

Adding an arbitrary JSON key to the operational configuration is not enough. The scripts build and validate explicit property contracts; both provisioning and synchronization must understand the extension.

Retain the same external-item ID for each user within a connection. Publish the intended current collection and validate preservation/removal behavior. A changing item ID or overlapping producer can create competing records.

Suggested prompt: "Using only recorded deliveryCapabilities from the people connector, identify people with Microsoft Purview DLP assessment evidence. Show the evidence date and source. Do not infer certifications or availability."

## 5. Publish skills with the native contract

A skill describes a capability; Microsoft Applied Skills is a credential family. A credential title should not be converted automatically into an expert proficiency rating. Keep evidence in the credential record or a custom property and define a separate, approved skill taxonomy.

### Schema fragment

```json
{
  "name": "skills",
  "type": "stringCollection",
  "labels": ["personSkills"]
}
```

### PowerShell serialization example

```powershell
$Skill = @{ displayName = 'KQL threat hunting' }
$Properties = @{
    'skills@odata.type' = 'Collection(String)'
    skills = @(
        ($Skill | ConvertTo-Json -Depth 10 -Compress)
    )
}
```

This builds an illustrative properties fragment, not a full PUT request. Merge it into the existing user payload and serialize the complete payload afterward. Each native collection member is a JSON-encoded string, not an embedded object.

The skillProficiency entity includes displayName, proficiency, categories, collaborationTags and webUrl. Proficiency values include elementary, limitedWorking, generalProfessional, advancedProfessional and expert. Collaboration tags include askMeAbout, ableToMentor, wantsToLearn and wantsToImprove. Use optional values only when supported by explicit evidence, and validate their actual consumption in the tenant. [7]

### People Skills changes the card behavior

| Tenant configuration | Connector skill behavior |
|---|---|
| People Skills not enabled | Read-only connector skills merge with user-editable skills unless editing is disabled |
| People Skills enabled | The card shows People Skills-origin skills; connector skills remain available in people search and Microsoft 365 Copilot Chat |

This behavior is documented by Microsoft. Successful ingestion of personSkills does not override the People Skills card rule. [8]

Recommended pilot: ingest one distinct skill for one user, validate the raw string collection, inspect the beta profile skills facet, test a targeted Copilot question, and then inspect the card with the tenant's People Skills configuration recorded. Do not change proficiency to expert merely to improve search relevance.

## 6. Validate ingestion, composition and presentation

| Layer | Read or check | Expected evidence |
|---|---|---|
| Live schema | GET /v1.0/external/connections/{connectionId}/schema | Name, type, label and description match the intended contract |
| Raw item | GET /v1.0/external/connections/{connectionId}/items/{itemId} | Correct account, current records and serialization |
| Composed profile | GET /beta/users/{id-or-UPN}/profile/skills, /awards or /certifications | Native records and contributing sources |
| Search / Copilot | Positive, negative and type-specific questions | Correct person, credential type and evidence |
| Profile card | Inspect each required client | Correct visible content after propagation |

Use the connector application's already authorized permissions for raw-item checks where possible. Cross-user profile checks in the production population validator use delegated User.Read.All with admin consent. The Profile API remains beta and is subject to change; its use in production applications is not supported by Microsoft. [6]

Custom fields such as microsoftAppliedSkills are checked in the raw external item; they do not have a native /profile/microsoftAppliedSkills facet. The existing 99 validator covers the production Schema 2.4 contract; a new skills or custom-property extension requires corresponding validator changes.

### Coexisting connections and duplicates

The external-item read is connection-specific. The Profile API returns a composed view that can include production, Beta and other sources. Microsoft documents that precedence selects authoritative single values, while for multi-value data it affects ordering and the API can retain duplicates. [9]

For this project, compare normalized credential identity and source rather than requiring the composed count to equal the count from one connection. Record connection ID, external-item ID, issuer, credential ID, type and source URL. Two representations of an Applied Skill are intentional; two certification records from overlapping connectors require diagnosis. Higher priority is not a deduplication control.

### Timing and exposure

Microsoft's builder guidance mentions up to six hours after connection creation. The project has observed longer presentation delays, including more than twelve hours; that observation is not a service SLA. Optional card visibility changes are documented as taking up to twenty-four hours. [1], [10]

Use a small test-user dataset in a separate connection. Do not assume Beta naming limits the audience: people data is organization-visible by default, and the builder requires an everyone ACL. Do not ingest confidential HR notes or customer-sensitive project details as test data. [1], [8]

For optional card properties, review Settings > Org settings > People settings > Profile card > Contact info. Visibility settings control presentation; hiding a property does not delete its underlying data. [10]

### Completion criteria for an extension

An extension is ready for review when its schema, source mapping, stable keys, collection lifecycle, read-back report and validation are documented; known positive/negative cases pass; and the actual card/Search/Copilot behavior is recorded. Promote the tested contract deliberately rather than assuming an edit to Beta automatically updates production.

## References

1. [Build Microsoft 365 Copilot connectors for people data](https://learn.microsoft.com/en-us/microsoft-365/copilot/extensibility/build-connectors-with-people-data)
2. [schema resource type](https://learn.microsoft.com/en-us/graph/api/resources/externalconnectors-schema?view=graph-rest-1.0)
3. [property resource type](https://learn.microsoft.com/en-us/graph/api/resources/externalconnectors-property?view=graph-rest-1.0)
4. [Copilot connectors API limits](https://learn.microsoft.com/en-us/graph/connecting-external-content-api-limits)
5. [Add or remove custom attributes on a profile card](https://learn.microsoft.com/en-us/graph/add-properties-profilecard)
6. [profile resource type (beta)](https://learn.microsoft.com/en-us/graph/api/resources/profile?view=graph-rest-beta)
7. [skillProficiency resource type (beta)](https://learn.microsoft.com/en-us/graph/api/resources/skillproficiency?view=graph-rest-beta)
8. [Microsoft 365 Copilot connectors for people data](https://learn.microsoft.com/en-us/graph/peopleconnectors)
9. [Manage profile source precedence](https://learn.microsoft.com/en-us/graph/profilepriority-configure-profilepropertysetting)
10. [Enriching and customizing profile cards](https://learn.microsoft.com/en-us/microsoft-365/admin/manage/customize-profile-cards)
11. [Microsoft 365 Roadmap: verify item 529851](https://www.microsoft.com/en-us/microsoft-365/roadmap?searchterms=529851)
12. [Project: production Schema 2.4 implementation](https://github.com/ProfKaz/Profile-Card---Awards-Recognitions-and-badges/tree/main/Source)
