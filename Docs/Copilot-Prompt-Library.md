# Microsoft 365 Copilot Prompt Library for Certification and Recognition Data

> Turn certification and recognition data in Microsoft 365 profiles into practical organizational intelligence for staffing, proposals, capability discovery, renewal planning, specialization readiness, mentoring, and workforce development.

## Purpose

This prompt library is designed for organizations that publish certifications, awards, badges, and professional recognitions into Microsoft 365 profiles through a People Data Connector.

The connector's value is not limited to making credentials visible on a profile card. Microsoft 365 Copilot can use people data as organizational context when responding to people-related questions. When credential data is current and consistently published, natural-language questions can help users discover relevant capabilities across the organization.

Typical business scenarios include:

- Finding people with a required certification or recognition.
- Matching project or RFP requirements with available certified capabilities.
- Identifying certification coverage gaps.
- Preparing staffing options for customer engagements.
- Tracking certification renewals and upcoming expirations.
- Assessing readiness for Microsoft specialization or partner requirements.
- Identifying potential candidates for additional training.
- Finding internal mentors, trainers, or subject-matter experts.
- Creating management-level capability summaries.

> **Getting inconsistent results?** Model choice, source grounding, and retrieval coverage can affect Copilot answers. See **[Tips for Getting the Most from the People Connector with Microsoft 365 Copilot](Copilot-Usage-Tips.md)** before using aggregate, expiration, or organization-wide prompts.

## Important interpretation guidance

Certifications and recognitions are useful evidence of demonstrated knowledge, but they should not automatically be treated as proof of project experience, availability, seniority, or customer-facing capability.

When using these prompts, Copilot should distinguish between:

- **Currently qualified** — the profile contains the certification or recognition explicitly requested.
- **Related capability** — the profile contains a credential relevant to the requested technology or domain.
- **Potential training candidate** — the person has adjacent or prerequisite credentials that may make further specialization reasonable.
- **Unknown** — the available profile data is insufficient to make the requested determination.

For customer staffing, hiring, formal compliance, or Microsoft Partner qualification decisions, validate the result against the authoritative requirements and current organizational records.

## Reusable grounding instruction

The following instruction can be added to prompts where precision is important:

> Use only information available in Microsoft 365 profiles and the documents I provide. Do not infer certifications, practical experience, availability, seniority, or eligibility that is not explicitly supported by the available data. Clearly separate people who already meet the stated requirement from people who only have related credentials and may be candidates for additional training.

---

# Prompt Library

## 1. Skills and certification discovery

1. **Active Microsoft certifications**

   > Who in our organization currently holds active Microsoft certifications? Group the results by certification and include the number of certified people for each one.

2. **Security certifications**

   > Which team members currently hold Microsoft security-related certifications? Include the certification name and expiration date when available.

3. **Security technology domains**

   > Who in our organization has certifications related to Microsoft Purview, Microsoft Defender, Microsoft Entra, Azure Security, or Microsoft 365 Security?

4. **Certification inventory by person**

   > Show the active Microsoft certifications held by each member of our organization, including the total number of active certifications per person.

5. **Data security and compliance**

   > Identify team members who have certifications related to data security, compliance, information protection, data governance, or cybersecurity.

6. **Microsoft Certified Trainers**

   > Do we have anyone in the organization who is a Microsoft Certified Trainer?

7. **Professional recognitions**

   > Do we have team members with Microsoft MVP, Microsoft Certified Trainer, or other professional recognitions recorded in their profile?

8. **Certifications plus recognitions**

   > Show me employees who have both technical certifications and professional recognitions such as Microsoft MVP or Microsoft Certified Trainer.

## 2. Project staffing and capability matching

9. **Customer requirements to people**

   > I have attached a document describing the technical requirements for a customer engagement. Based on those requirements, identify people in our organization whose certifications could help us deliver this project. Explain why each person may be relevant.

10. **Statement of Work analysis**

   > Based on the attached Statement of Work, identify team members with certifications that align with the technologies and services required by the customer.

11. **Microsoft Purview staffing**

   > We are preparing a Microsoft Purview implementation. Which members of our organization have certifications or recognitions that could support the engagement?

12. **Multi-workload security project**

   > We need to build a project team for a Microsoft security engagement covering Defender, Entra, Purview, and Intune. Identify people whose certifications align with these technologies.

13. **Capability matrix**

   > For the requirements in the attached RFP, create a capability matrix showing the required technology area, relevant certifications, and team members who currently hold those certifications.

14. **Requirement coverage by person**

   > For this engagement, show how each relevant person's active certifications map to the project requirements. Do not infer practical experience that is not present in the available data.

15. **Coverage gaps**

   > Identify any areas in the attached project requirements where we currently do not appear to have a team member with a directly relevant active certification.

## 3. Proposal and RFP support

16. **Strengthen a proposal**

   > Review the attached customer requirements and identify certifications held by our team that could strengthen our technical response.

17. **Organizational credentials summary**

   > Create a summary of organizational certifications that could be referenced as evidence of technical capability for this proposal.

18. **RFP certification mapping**

   > Based on the attached RFP, identify which Microsoft certifications represented in our organization are directly relevant to the requested services.

19. **Proposal evidence table**

   > Create a table with the customer requirement, relevant Microsoft certification, certified team members, and how that certification relates to the requested capability.

20. **Security and compliance capability statement**

   > We need to demonstrate expertise in Microsoft Security and Compliance. Summarize the active certifications and recognitions across our team that could support that statement.

## 4. Certification expiration and renewal management

21. **Next 90 days**

   > Which Microsoft certifications held by our team will expire within the next 90 days?

22. **Next six months**

   > Show me certifications that will expire within the next six months, grouped by employee.

23. **Renewal attention**

   > Which team members currently have certifications that require renewal soon? Include the certification name and expiration date.

24. **Renewal calendar**

   > Create a certification renewal calendar for the next six months based on the expiration dates available in employee profiles.

25. **Capability at risk**

   > Which certifications are approaching expiration and could reduce our organizational coverage for a technology or service area if they are not renewed?

26. **Twelve-month outlook**

   > How many active certifications do we have today, and how many of them are expected to expire during the next 12 months?

## 5. Microsoft Partner and specialization readiness

27. **Required certification count**

   > We are working toward a Microsoft specialization that requires at least six individuals with [CERTIFICATION]. Identify everyone who currently holds that active certification.

28. **Current gap**

   > We need six people with [CERTIFICATION]. How many people currently meet that certification requirement, and what is the remaining gap?

29. **Multiple certification requirements**

   > For a Microsoft specialization requiring [CERTIFICATION A] and [CERTIFICATION B], identify team members who already satisfy either requirement. Keep the two certification groups separate.

30. **Training pipeline**

   > We need additional people certified in [TARGET CERTIFICATION]. Identify team members who already hold related or prerequisite certifications and could be considered for further specialization. Do not count them as currently qualified.

31. **Adjacent credentials**

   > Identify employees whose existing Microsoft certifications are closely related to [TARGET CERTIFICATION] and summarize the adjacent credentials that could make them reasonable candidates for a training plan.

32. **Readiness matrix**

   > Create a readiness matrix for [MICROSOFT SPECIALIZATION], showing required certifications, current certified employees, certification gaps, and relevant certifications approaching expiration.

33. **Qualified versus candidates**

   > We currently need six certified individuals for [SPECIALIZATION]. Separate the results into two groups: people who already meet the stated certification requirement and people with adjacent certifications who may be suitable candidates for training.

## 6. Workforce development

34. **Lowest coverage areas**

   > Which Microsoft technology areas have the lowest certification coverage in our organization?

35. **Single-person dependency**

   > Identify technology areas where only one person currently holds a relevant active certification, creating a potential concentration of certified capability.

36. **Common versus unique credentials**

   > Which certifications are held by multiple team members, and which active certifications are currently held by only one person?

37. **Training opportunities**

   > Based on our current certification inventory, identify technology areas where additional training could improve organizational coverage.

38. **Certification progression**

   > Identify team members who have foundational Microsoft certifications but do not yet have an associate or expert-level certification in the same or a closely related area.

39. **Security development path**

   > Identify employees who have Microsoft security fundamentals or adjacent security certifications and may be candidates for more advanced Microsoft Security certification paths.

40. **Capability progression view**

   > Create a certification progression view showing team members with foundational, associate, expert, or specialty credentials in related Microsoft technology areas.

## 7. Internal expert discovery

41. **Purview assistance**

   > I need help with Microsoft Purview. Who in the organization has certifications or professional recognitions related to this technology?

42. **Defender for Endpoint**

   > I am starting a Microsoft Defender for Endpoint project. Who can I identify internally based on relevant active certifications?

43. **Identity and access management**

   > Who in our organization has credentials related to identity and access management?

44. **Customer workshop**

   > I need people with Microsoft security credentials to participate in a customer workshop. Show team members with relevant active certifications or recognitions. Do not infer availability or presentation experience.

45. **Microsoft 365 administration**

   > Who has active certifications related to Microsoft 365 administration and could be considered for a Microsoft 365 architecture discussion?

46. **Azure and Microsoft 365 security**

   > Find people in our organization whose certification profiles include both Azure security and Microsoft 365 security-related credentials.

## 8. Cross-skill and multidisciplinary searches

47. **Cybersecurity and Microsoft 365**

   > Who has active certifications covering both cybersecurity and Microsoft 365?

48. **Azure, Microsoft 365, and Security**

   > Identify team members with certifications represented across Azure, Microsoft 365, and Security.

49. **Security plus compliance**

   > Who combines Microsoft security certifications with data governance, compliance, or information protection credentials?

50. **Multiple solution areas**

   > Identify people whose active certification profile spans multiple Microsoft solution areas rather than a single technology domain.

51. **Customer-facing workshop candidates**

   > Who has both relevant technical certifications and trainer or community recognitions that may be useful when identifying candidates for customer-facing workshops? Do not infer presentation experience solely from the credentials.

52. **Infrastructure and data security**

   > Identify people with active certifications that indicate knowledge across both infrastructure security and data security.

## 9. Executive and management queries

53. **Executive capability summary**

   > Give me an executive summary of the Microsoft-certified capabilities currently represented across our organization.

54. **People with certifications**

   > How many employees currently have at least one active Microsoft certification?

55. **Certification footprint**

   > How many active Microsoft certifications are represented across the organization, and which certification areas have the broadest representation?

56. **Capability map**

   > Create a high-level organizational capability map based on the active certifications currently held by our employees.

57. **Solution-area summary**

   > Summarize our organizational Microsoft certification coverage across Security, Azure, Microsoft 365, Data, AI, and Business Applications.

58. **Capability concentration**

   > Identify certification areas where our coverage is concentrated among only a small number of employees.

59. **Expiration management summary**

   > Provide a management summary of certifications expiring in the next 12 months and the capability areas they may affect.

## 10. Customer opportunity matching

60. **Opportunity qualification**

   > We have received an opportunity involving Microsoft Purview, Defender XDR, and Entra ID. Identify which internal capabilities can be demonstrated through active certifications.

61. **Opportunity document analysis**

   > Based on the attached customer opportunity, identify the Microsoft technologies mentioned and map them to relevant certifications held by our team.

62. **Supported versus uncovered requirements**

   > For this opportunity, show which requirements are supported by active certifications currently represented in our team and which requirements do not have an obvious certification match.

63. **Customer capability coverage matrix**

   > Create a capability coverage matrix for this customer opportunity using the active certifications currently available across our organization.

64. **Credentials relevant to customer technologies**

   > Which members of our organization have active credentials relevant to the customer technologies described in this document?

## 11. Training and mentoring

65. **Potential mentors**

   > Who could potentially mentor employees preparing for [CERTIFICATION], based on already holding that active certification or a more advanced related certification?

66. **MCT plus technical certification**

   > Do we have Microsoft Certified Trainers who also hold active certifications related to [TECHNOLOGY]?

67. **Internal knowledge-sharing**

   > Identify certified employees who could be considered for an internal knowledge-sharing session on Microsoft Security. List the credentials that make them relevant, but do not infer presentation skills or availability.

68. **Advanced-to-foundational mentoring**

   > Who holds advanced certifications in an area where other employees currently have only foundational certifications?

69. **Mentor discovery by technology**

   > Identify potential internal mentors for Microsoft Purview, Microsoft Defender, Microsoft Entra, Azure, and Microsoft 365 based on certification profiles.

## 12. Recognition and talent visibility

70. **Recent professional recognitions**

   > Which members of our organization have professional awards, badges, or recognitions from the last 12 months recorded in their profile?

71. **Recent recognition summary**

   > Show recent professional recognitions recorded for members of our organization.

72. **Recently earned credentials**

   > Who has recently earned a new certification, badge, or professional recognition?

73. **Certifications plus external recognition**

   > Identify employees who have both active Microsoft certifications and external professional recognitions recorded in their profile.

74. **Internal recognition communication**

   > Create a summary of recent certifications and professional recognitions across the organization that could be considered for an internal recognition communication.

---

# High-value showcase prompts

The following prompts are particularly effective for demonstrating the business value of the connector.

## Opportunity to people

> I have attached a customer RFP. Identify the technical capabilities requested and show which members of our organization have active certifications that could support each requirement. Clearly separate direct certification matches from related credentials.

## Find an internal capability

> I need someone who can help with Microsoft Purview and data security. Who in our organization has relevant active certifications or professional recognitions? Explain which credentials are relevant.

## Partner specialization readiness

> We need at least six individuals with [CERTIFICATION] to support a Microsoft specialization requirement. How many people currently meet the certification requirement, who are they, and what is the remaining gap?

## Build a training pipeline

> We need more people certified in [TARGET CERTIFICATION]. Identify employees with related certifications who could be candidates for further training. Keep current certification holders separate from potential training candidates.

## Protect existing capability

> Which active certifications supporting our Microsoft Security capabilities will expire within the next six months? Group the results by certification and employee.

## Executive capability view

> Create an executive summary of the Microsoft-certified capabilities represented across our organization, including areas with broad certification coverage, areas with limited coverage, and credentials approaching expiration.

---

# Example: combining a customer document with people data

A high-value scenario is to provide Copilot with a customer RFP, Statement of Work, requirements document, or opportunity summary and then ask it to correlate those requirements with people data.

Example:

> Review the attached customer requirements. Extract the Microsoft technologies, security capabilities, and certification-sensitive requirements. Then use our organizational profile data to identify:
>
> 1. People with active certifications that directly align with each requirement.
> 2. People with adjacent certifications who may be useful subject to further validation.
> 3. Requirements for which no directly relevant certification is currently represented.
> 4. Certifications approaching expiration that could affect our capability coverage.
>
> Do not infer project experience, customer experience, availability, or eligibility that is not explicitly supported by the available data.

This transforms a profile connector from a display mechanism into a practical capability-discovery layer that can support business and delivery workflows.

# Business value model

The connector enables a progression from credential visibility to organizational intelligence:

```text
Credential source
    ↓
Microsoft Learn / Credly
    ↓
Microsoft 365 People Data Connector
    ↓
Microsoft 365 profile
    ↓
Microsoft 365 Copilot / People Search
    ↓
Natural-language capability discovery
    ↓
Staffing, proposals, readiness, renewals and workforce development
```

The most significant value is therefore not **"show a badge on a profile card."**

It is:

> **Make demonstrated professional capabilities discoverable at the point where people are making business, staffing, delivery, and development decisions.**

# Notes and limitations

- Results depend on the data actually published to Microsoft 365 profiles.
- Credential expiration dates should be kept current when the source exposes them.
- Microsoft Learn and Credly remain the authoritative sources for credentials synchronized by this reference implementation.
- A certification should not be treated as proof of practical experience, project history, customer experience, seniority, or availability.
- Microsoft Partner or specialization requirements can change. Validate current requirements against official Microsoft documentation before making qualification decisions.
- Microsoft 365 Copilot behavior depends on tenant configuration, licensing, permissions, indexing, profile composition, and the quality of the ingested data.
- People data should be published only when the organization is authorized to expose it internally.

# Microsoft documentation

- [Microsoft 365 Copilot connectors for people data](https://learn.microsoft.com/en-us/graph/peopleconnectors)
- [Build Microsoft 365 Copilot connectors for people data](https://learn.microsoft.com/en-us/microsoft-365/copilot/extensibility/build-connectors-with-people-data)
- [View awards and certification badges on your profile card](https://support.microsoft.com/en-us/office/view-awards-and-certification-badges-on-your-profile-card)

