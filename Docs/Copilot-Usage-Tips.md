# Tips for Getting the Most from the People Connector with Microsoft 365 Copilot

> Practical guidance for getting more consistent, explainable, and useful answers from Microsoft 365 Copilot when certification and recognition data is published through a Microsoft 365 People Data Connector.

## Why this guide exists

Publishing certifications, badges, and recognitions into Microsoft 365 profiles improves the people context available to Microsoft 365 Copilot, Microsoft Search, profile cards, and other people experiences.

However, a well-designed connector does **not** make every Copilot question deterministic.

Copilot still has to interpret the user's request, choose a retrieval and reasoning strategy, decide which organizational sources are relevant, and generate an answer from the information it retrieves. The selected model can also affect response depth, instruction following, source selection, and how aggressively the system attempts multi-step reasoning.

This means that two important things can both be true:

1. The connector can contain the correct profile data.
2. Two Copilot runs can still produce different answers for the same business question.

The goal of this document is to make those differences easier to manage.

---

## 1. Understand what the connector gives Copilot

This project publishes credential data using Microsoft 365 People Data Connector semantic labels, including:

- \`personAccount\`
- \`personCertifications\`

Certification records can include structured fields such as:

- \`certificationId\`
- \`displayName\`
- \`description\`
- \`issuedDate\`
- \`startDate\`
- \`endDate\`
- \`issuingAuthority\`
- \`issuingCompany\`
- \`webUrl\`

Microsoft recommends reusing supported profile entities and semantic labels because they improve how Microsoft 365 understands and reasons over people data.

Official documentation:

- [Microsoft 365 Copilot connectors for people data](https://learn.microsoft.com/en-us/graph/peopleconnectors)
- [Build Microsoft 365 Copilot connectors for people data](https://learn.microsoft.com/en-us/microsoft-365/copilot/extensibility/build-connectors-with-people-data)

The connector therefore provides **structured organizational context**. It does not behave like a relational database query endpoint where every prompt automatically enumerates every row in the tenant.

---

## 2. Model selection can change the result

Microsoft 365 Copilot can expose multiple model choices. Microsoft documents that the default **Auto** mode uses a real-time router to select an underlying model based on the prompt. Different model choices can affect response depth, reasoning behavior, performance, and output style.

See:

- [Overview of Microsoft Copilot Chat](https://learn.microsoft.com/en-us/copilot/tutorials/learn-microsoft-copilot/02-copilot-technical-leaders)
- [Microsoft 365 Copilot release notes](https://learn.microsoft.com/en-us/microsoft-365/copilot/release-notes)

### Recommended approach

**Auto is a reasonable default for normal discovery questions.**

Examples:

- Who has SC-200?
- Do we have any Microsoft Certified Trainers?
- Who has certifications related to Microsoft Purview?
- Which people have security-related credentials?

For prompts that require more deliberate multi-step reasoning, consider explicitly selecting the most capable reasoning model available in your Microsoft 365 Copilot experience.

Examples include:

- Comparing certification coverage across multiple people.
- Calculating expiration windows.
- Separating overlapping time periods.
- Evaluating an RFP against multiple profiles.
- Enforcing strict source boundaries.
- Detecting duplicates or conflicting records.
- Producing a result that must be repeatable or auditable.

Available model names can change over time and can differ by tenant, license, region, and Microsoft 365 release. The recommendation is therefore about **reasoning capability**, not a permanent preference for one specific model name.

### Important

A stronger reasoning model is not automatically more authoritative.

A model that searches more aggressively might discover additional Microsoft 365 content that was **not intended to be part of the analysis**, such as an old SharePoint document containing historical certification information.

For that reason, **model choice and prompt grounding must be treated as separate controls**.

---

## 3. Scope the source explicitly

Compare these two prompts.

### Ambiguous

> Of the team's certifications, which ones expire in the next 3 and 6 months?

The prompt leaves several decisions to Copilot:

- What does "the team" mean?
- Which profiles should be included?
- Should it search only People Profile data?
- Can it use SharePoint, OneDrive, email, PDFs, public transcripts, or web results?
- Does "3 and 6 months" mean overlapping or non-overlapping periods?
- Should a credential without an expiration date be inferred?

### Better

> Using only certification information available in Microsoft 365 People Profiles from the People Connector, identify certifications that expire within the next six months. Do not use SharePoint documents, OneDrive files, PDFs, email, Teams messages, public transcripts, web results, or historical certification documents as alternative sources.

When the purpose is to test the connector, source boundaries should be explicit.

---

## 4. Ask Copilot to report coverage before trusting an aggregate answer

A semantic retrieval result is not necessarily an exhaustive organizational inventory.

If Copilot returns three people, there is an important difference between:

> I found three matching profiles.

and:

> I evaluated all 150 profiles and three matched the condition.

For aggregate or compliance-style questions, ask Copilot to state what it actually evaluated.

Recommended instruction:

> Before giving the result, report how many Microsoft 365 People Profiles with certification information you were able to retrieve. Do not describe the result as organization-wide unless the full relevant population was actually evaluated.

For expiration analysis, also request:

- Number of profiles retrieved.
- Number of profiles containing certification data.
- Number of certification records containing \`endDate\`.
- Number of profiles that could not be evaluated.
- Whether the result is complete or retrieval-limited.

This turns an otherwise plausible answer into something much easier to assess.

---

## 5. Separate discovery from authoritative reporting

The connector is particularly strong for **people and capability discovery**.

Examples:

> Who has a certification related to Microsoft Purview?

> Find people whose credentials could support this customer requirement.

> Do we have anyone with Microsoft Certified Trainer recognition?

> Which people have credentials related to Microsoft security?

These questions are naturally compatible with semantic people discovery.

Other questions are closer to a database or reporting workload:

> List every certification across the company that expires in the next six months.

> Give me the exact number of active certifications by employee.

> Prove that all employees were checked for a partner compliance requirement.

Those questions require **exhaustive enumeration**, not only relevant retrieval.

For authoritative reporting, use a structured source or deterministic query process when completeness matters, and then use Copilot to summarize, explain, or interact with that result.

A useful design principle is:

\`\`\`text
People Connector -> Copilot -> discovery, reasoning, staffing, capability search

Structured inventory -> deterministic calculation -> Copilot -> explanation and decision support
\`\`\`

Do not treat a semantically retrieved result as an exhaustive audit unless the response provides evidence that the full target population was evaluated.

---

## 6. Make date logic explicit

Natural-language date windows can be interpreted in multiple ways.

For example:

> Which certifications expire in the next 3 and 6 months?

could mean:

- 0-3 months and 0-6 months, which overlap; or
- 0-3 months and >3-6 months, which do not overlap.

For operational reports, define the windows yourself.

Recommended wording:

> Use today's date as the reference date and divide the result into two non-overlapping groups:
>
> 1. Expiring from today through the next 3 calendar months.
> 2. Expiring after 3 months and through the next 6 calendar months.

Also state:

> Use the certification \`endDate\` as the expiration date. Do not infer an expiration date when \`endDate\` is missing.

---

## 7. Ask for uncertainty instead of silent assumptions

For credential data, missing information is often meaningful.

Useful instructions include:

> If \`endDate\` is missing, report the expiration as unknown rather than estimating it.

> If duplicate certifications have conflicting dates, flag the conflict rather than choosing one silently.

> Distinguish certifications from badges, awards, and recognitions.

> Do not infer practical experience, seniority, project availability, or customer-facing capability from certification data alone.

This is especially important when Microsoft Learn certifications and Credly recognitions coexist in the same profile.

---

## 8. Recommended prompt pattern

For queries that require higher confidence, use the following structure:

\`\`\`text
SCOPE
Use only [specific source].

POPULATION
Evaluate [specific group or organizational scope].

TASK
Perform [specific analysis].

FIELD RULES
Use [specific profile properties].
Do not infer missing values.

TIME / LOGIC
Use [reference date] and [explicit non-overlapping ranges].

OUTPUT
Return [required columns / structure].

VALIDATION
Report coverage, missing data, duplicates, and conflicts.

LIMITATION
Do not claim full organizational coverage unless the full population
was actually evaluated.
\`\`\`

This structure usually matters more than adding more general prose to the prompt.

---

# Practical example: certification expiration analysis

The following example is based on a real connector test performed on **September 29, 2026**. Names, profile links, and transcript URLs have been anonymized.

The objective was to identify certifications expiring within three and six months and to understand how model choice and prompt specificity affected the answer.

## Test 1 - Short prompt

### Prompt

> Of the team's certifications, which ones expire in the next 3 and 6 months?

### Auto result

The initial Auto response stated that it could not retrieve certification records with expiration dates and therefore could not perform the calculation.

### Manually selected reasoning model result

Using the same short prompt with a manually selected higher-reasoning model produced a much more detailed answer. It retrieved three People Profiles and calculated expiration windows.

However, it also found an **older certification document stored in SharePoint** for another employee and attempted to include that historical date as a possible expiration.

### Lesson

The stronger result performed more reasoning, but it also broadened the information sources beyond the People Connector.

**More retrieval is not the same as better grounding.**

For connector testing, explicitly restrict the source.

---

## Test 2 - Source-scoped expiration prompt

### Prompt

\`\`\`text
Using only the certification information available in the Microsoft 365
People Profiles for members of my organization, identify certifications
that expire within the next six months.

Use the certification endDate stored in the user's People Profile as the
expiration date.

Do not use SharePoint documents, OneDrive files, PDFs, emails, Teams
messages, public Microsoft Learn transcripts, web results, or historical
certification documents as alternative sources.

Use today's date as the reference date and divide the results into two
non-overlapping groups:

1. Expiring from today through the next 3 calendar months.
2. Expiring after 3 months and through the next 6 calendar months.

For each result show:
Person | Certification | Expiration date | Days remaining | Time window

Do not infer an expiration date if endDate is missing.

If conflicting or duplicate certification records exist, flag them rather
than choosing one silently.

Finally, report:
- how many user profiles were evaluated;
- how many contained certification data;
- how many certifications contained an endDate;
- how many profiles could not be evaluated.

Do not claim that the result covers the entire organization unless all
relevant user profiles were actually evaluated.
\`\`\`

### Auto result

Auto successfully followed the stricter prompt.

It reported that only three profiles were actually retrieved and evaluated:

- **User A**
- **User B**
- **User C**

It used the reference date **2026-09-29** and returned:

| Window | Result |
| --- | --- |
| Today through 2026-12-29 | No matching certifications found |
| After 2026-12-29 through 2027-03-29 | User A - one credential expiring 2026-12-31 |

It also reported:

| Metric | Result |
| --- | ---: |
| User profiles evaluated | 3 |
| Profiles containing credential data | 3 |
| Certification records containing an \`endDate\` | 5 |
| Profiles that could not be evaluated | 0 |

Most importantly, the response explicitly stated that the three retrieved profiles **could not be treated as complete organizational coverage**.

### Lesson

The improved prompt significantly changed the behavior of Auto.

This shows that **prompt design can be as important as model selection**.

---

## Test 3 - Coverage diagnostic prompt

### Prompt

\`\`\`text
Before giving me the expiration report, tell me how many Microsoft 365
People Profiles with certification information you were able to retrieve
for this analysis.

Do not search documents or other Microsoft 365 content.

If you cannot enumerate all profiles, state that explicitly and do not
describe the resulting list as complete.
\`\`\`

### Auto result

Auto reported:

- Three People Profiles were retrieved from the connector.
- The retrieved profiles were User A, User B, and User C.
- The result did not provide evidence that these three represented every profile in the organization.
- Therefore the result should not be described as a complete enumeration.

### Manually selected reasoning model result

The reasoning model also reported three retrieved People Profiles.

It added a useful semantic distinction:

- User A contained certification information.
- User B contained badge information but no formal Microsoft certification entry relevant to an expiration report.
- User C contained credential/profile information returned by the source.

### Lesson

Both models agreed on the **retrieved profile count**, but the reasoning model provided a more nuanced interpretation of the type of credential information present.

This is a good example of why users should distinguish:

- profile coverage;
- certification coverage;
- badge/recognition coverage; and
- completeness of the organizational population.

---

# Recommended model strategy

Use this as a practical rule of thumb rather than a rigid requirement.

| Scenario | Suggested approach |
| --- | --- |
| Find a person with a specific certification | Auto is normally appropriate |
| Find trainers, MVPs, or people with a specific recognition | Auto is normally appropriate |
| Match an attached RFP to relevant certified people | Auto can work; use a reasoning model for more complex mappings |
| Compare multiple certification requirements across many people | Prefer a reasoning-capable model |
| Calculate expiration windows | Prefer explicit source scope; reasoning model recommended when the query is complex |
| Require strict source isolation | State exclusions explicitly regardless of model |
| Need exhaustive organization-wide counts | Use deterministic reporting in addition to Copilot |
| Need repeatable or audit-sensitive output | Fix the source, logic, population, and preferably the model/mode used |

The most important rule is:

> **Do not use model selection as a substitute for grounding instructions.**

---

# Recommended production prompt for expiration analysis

\`\`\`text
Using only certification information from Microsoft 365 People Profiles
provided by the organization's People Data Connector, analyze certification
expiration dates.

Do not use SharePoint, OneDrive, email, Teams messages, PDFs, public
transcripts, web content, or other historical documents as alternate
credential sources.

First report:
1. The number of People Profiles retrieved for the analysis.
2. The number containing certification records.
3. The number of certification records containing endDate.
4. Whether you were able to evaluate the complete target population.

Then use the certification endDate field and today's date to create two
non-overlapping groups:

A. Expiring today through the next 3 calendar months.
B. Expiring after 3 months and through the next 6 calendar months.

Return:
Person | Certification | Expiration date | Days remaining | Window

Do not infer missing expiration dates.
Flag duplicate or conflicting records.
Distinguish certifications from badges and recognitions.

If the retrieved profiles do not represent the complete target population,
clearly label the result as retrieval-limited and do not describe it as an
organization-wide report.
\`\`\`

---

# Final recommendations

1. **Start with Auto for normal people discovery.**
2. **Use a reasoning-capable model for multi-step, cross-profile, date-driven, or validation-heavy tasks.**
3. **Explicitly identify the source you want Copilot to use.**
4. **Explicitly exclude other Microsoft 365 sources when testing the connector in isolation.**
5. **Ask for retrieval coverage before accepting aggregate conclusions.**
6. **Do not confuse retrieved profiles with the complete organizational population.**
7. **Define time windows and calculation rules explicitly.**
8. **Treat missing \`endDate\` values as unknown.**
9. **Separate certifications from awards, badges, and recognitions.**
10. **Use deterministic reporting when completeness is a business requirement, then use Copilot to interpret the result.**
11. **Expect answers to vary somewhat by model, model mode, tenant configuration, indexing state, and product updates.**
12. **Retest important prompts when Microsoft changes available models or Copilot orchestration behavior.**

---

## Related project documentation

- [Copilot Prompt Library](Copilot-Prompt-Library.md)
- [Project README](../README.md)
- [Source scripts](../Source/README.md)
- [Support and configuration](../Support/README.md)

## Microsoft references

- [Microsoft 365 Copilot connectors for people data](https://learn.microsoft.com/en-us/graph/peopleconnectors)
- [Build Microsoft 365 Copilot connectors for people data](https://learn.microsoft.com/en-us/microsoft-365/copilot/extensibility/build-connectors-with-people-data)
- [Overview of Microsoft Copilot Chat](https://learn.microsoft.com/en-us/copilot/tutorials/learn-microsoft-copilot/02-copilot-technical-leaders)
- [Microsoft 365 Copilot release notes](https://learn.microsoft.com/en-us/microsoft-365/copilot/release-notes)

---

> **Testing note:** The examples above document observed behavior from a specific tenant and point in time. They are not a benchmark or guarantee that every tenant, model, or future Microsoft 365 Copilot release will return the same retrieval set or response.
