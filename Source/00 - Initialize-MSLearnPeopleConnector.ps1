#requires -Version 7.0
<#
.SYNOPSIS
    STEP 0 bootstrap for the Microsoft Learn / Credly -> Microsoft 365 People Profile solution.

.DESCRIPTION
    Prepares the local project structure, validates PowerShell prerequisites,
    creates the centralized configuration skeleton, creates the user input CSV,
    and writes README files for Config, Data, Logs and Reports.

    Existing operational files are preserved by default.

.EXAMPLE
    & '.\00 - Initialize-MSLearnPeopleConnector.ps1'

.EXAMPLE
    & '.\00 - Initialize-MSLearnPeopleConnector.ps1' -SkipModuleInstall

.EXAMPLE
    & '.\00 - Initialize-MSLearnPeopleConnector.ps1' -RefreshDocumentation

.EXAMPLE
    & '.\00 - Initialize-MSLearnPeopleConnector.ps1' -ResetConfig

.NOTES
    Recommended location: C:\MyDev\MSLearn
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$RootPath,

    [Parameter()]
    [switch]$SkipModuleInstall,

    [Parameter()]
    [switch]$RefreshDocumentation,

    [Parameter()]
    [switch]$ResetConfig,

    [Parameter()]
    [switch]$ResetDataFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Centralized configuration contract managed by Step 0.
# Step 0 never downgrades a configuration that is newer than this version.
$TargetSchemaVersionText = '2.4'
$TargetSchemaVersion = [version]$TargetSchemaVersionText

if ([string]::IsNullOrWhiteSpace($RootPath)) {
    $RootPath = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $PSScriptRoot
    }
    else {
        (Get-Location).Path
    }
}

$RootPath = [System.IO.Path]::GetFullPath($RootPath)

$ConfigDirectory  = Join-Path $RootPath 'Config'
$DataDirectory    = Join-Path $RootPath 'Data'
$LogsDirectory    = Join-Path $RootPath 'Logs'
$ReportsDirectory = Join-Path $RootPath 'Reports'

$ConfigPath      = Join-Path $ConfigDirectory 'MSLearnPeopleConnector.json'
$TemplatePath    = Join-Path $ConfigDirectory 'MSLearnPeopleConnector.Template.json'
$UsersPath       = Join-Path $DataDirectory 'CredentialUsers.csv'
$UsersSamplePath = Join-Path $DataDirectory 'CredentialUsers-Sample.csv'

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ''
    Write-Host ('=' * 88) -ForegroundColor DarkCyan
    Write-Host $Message -ForegroundColor Cyan
    Write-Host ('=' * 88) -ForegroundColor DarkCyan
}

function Write-Success {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-WarnMessage {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "[WARNING] $Message" -ForegroundColor Yellow
}

function Write-InfoMessage {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor DarkGray
}

function Save-JsonAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Object
    )

    $tempPath = "$Path.tmp"

    try {
        $Object |
            ConvertTo-Json -Depth 30 |
            Set-Content -LiteralPath $tempPath -Encoding utf8

        Get-Content -LiteralPath $tempPath -Raw |
            ConvertFrom-Json |
            Out-Null

        Move-Item -LiteralPath $tempPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-ConfigurationObject {
    param($Value)

    if ($null -eq $Value) {
        return $false
    }

    return (
        $Value -is [System.Collections.IDictionary] -or
        $Value -is [PSCustomObject]
    )
}

function Copy-ConfigurationValue {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    # JSON round-trip gives us a detached value so inserting defaults never
    # mutates the in-memory base configuration object.
    return (
        $Value |
            ConvertTo-Json -Depth 30 |
            ConvertFrom-Json
    )
}

function Add-MissingConfigurationProperties {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)]$Defaults,
        [Parameter(Mandatory)][string]$Path
    )

    $AddedPaths = @()

    foreach ($DefaultProperty in $Defaults.PSObject.Properties) {
        $Name = [string]$DefaultProperty.Name
        $DefaultValue = $DefaultProperty.Value
        $TargetProperty = $Target.PSObject.Properties[$Name]
        $CurrentPath = "$Path.$Name"

        if ($null -eq $TargetProperty) {
            $Target | Add-Member -NotePropertyName $Name -NotePropertyValue (Copy-ConfigurationValue -Value $DefaultValue)
            $AddedPaths += $CurrentPath
            continue
        }

        if (
            (Test-ConfigurationObject -Value $DefaultValue) -and
            (Test-ConfigurationObject -Value $TargetProperty.Value)
        ) {
            $AddedPaths += @(
                Add-MissingConfigurationProperties -Target $TargetProperty.Value -Defaults $DefaultValue -Path $CurrentPath
            )
        }
    }

    return @($AddedPaths)
}

function Get-MissingConfigurationProperties {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)]$Defaults,
        [Parameter(Mandatory)][string]$Path
    )

    $MissingPaths = @()

    foreach ($DefaultProperty in $Defaults.PSObject.Properties) {
        $Name = [string]$DefaultProperty.Name
        $DefaultValue = $DefaultProperty.Value
        $TargetProperty = $Target.PSObject.Properties[$Name]
        $CurrentPath = "$Path.$Name"

        if ($null -eq $TargetProperty) {
            $MissingPaths += $CurrentPath
            continue
        }

        if (
            (Test-ConfigurationObject -Value $DefaultValue) -and
            (Test-ConfigurationObject -Value $TargetProperty.Value)
        ) {
            $MissingPaths += @(
                Get-MissingConfigurationProperties -Target $TargetProperty.Value -Defaults $DefaultValue -Path $CurrentPath
            )
        }
    }

    return @($MissingPaths)
}

function Ensure-RequiredModule {
    param([Parameter(Mandatory)][string]$Name)

    $module = Get-Module -ListAvailable -Name $Name |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if (-not $module) {
        if ($SkipModuleInstall) {
            throw "Required PowerShell module '$Name' is not installed."
        }

        if (-not (Get-Command Install-Module -ErrorAction SilentlyContinue)) {
            throw "Install-Module is unavailable. Install/update PowerShellGet before continuing."
        }

        Write-WarnMessage "Module '$Name' is not installed. Installing for CurrentUser..."

        Install-Module `
            -Name $Name `
            -Scope CurrentUser `
            -Repository PSGallery `
            -Force `
            -AllowClobber `
            -ErrorAction Stop

        $module = Get-Module -ListAvailable -Name $Name |
            Sort-Object Version -Descending |
            Select-Object -First 1
    }

    if (-not $module) {
        throw "Module '$Name' could not be located after installation."
    }

    Import-Module $Name -ErrorAction Stop
    Write-Success "Module available: $Name $($module.Version)"
}

function New-BaseConfiguration {
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $now = (Get-Date).ToUniversalTime().ToString('o')

    [ordered]@{
        SchemaVersion  = $TargetSchemaVersionText
        CreatedUtc     = $now
        LastUpdatedUtc = $now

        Application = [ordered]@{
            DisplayName              = 'M365 Profile Card Awards Connector'
            TenantId                 = ''
            ClientId                 = ''
            ApplicationObjectId      = ''
            ServicePrincipalObjectId = ''
        }

        Authentication = [ordered]@{
            ClientSecret        = ''
            SecretKeyId         = ''
            SecretExpirationUtc = ''
            SecretStorage       = 'PlainText'
        }

        MicrosoftGraph = [ordered]@{
            ResourceAppId = '00000003-0000-0000-c000-000000000000'
            ApplicationPermissions = @(
                'ExternalConnection.ReadWrite.OwnedBy'
                'ExternalItem.ReadWrite.All'
                'PeopleSettings.ReadWrite.All'
            )
            AdminConsentStatus = 'NotConfigured'
            GraphV1   = 'https://graph.microsoft.com/v1.0'
            GraphBeta = 'https://graph.microsoft.com/beta'
        }

        ManagementUrls = [ordered]@{
            AppRegistration = ''
            ApiPermissions  = ''
            AdminConsent    = ''
        }

        Connector = [ordered]@{
            ConnectionId          = 'mslearncred'
            ConnectionName        = 'M365 Profile Card Awards'
            ConnectionDescription = 'Professional credentials and recognitions from Microsoft Learn and Credly for Microsoft 365 profile cards, Search and Copilot.'
            ContentCategory       = 'people'
            ProfileSourceKind     = 'MicrosoftLearn'
            ProfileSourceWebUrl   = 'https://learn.microsoft.com/'
            ProfilePropertySettingId = '00000000-0000-0000-0000-000000000001'
            EntraIdSourceId          = '4ce763dd-9214-4eff-af7c-da491cc3782d'
            CopilotVisibilityRecommended = 'On'
        }

        Schema = [ordered]@{
            BaseType = 'microsoft.graph.externalItem'

            AccountProperty = [ordered]@{
                Name   = 'accountInformation'
                Type   = 'string'
                Labels = @('personAccount')
            }

            CertificationProperty = [ordered]@{
                Name   = 'certifications'
                Type   = 'stringCollection'
                Labels = @('personCertifications')
            }

            # Schema 2.4:
            # Applied Skills remain distinct from Certifications.
            AppliedSkillsProperty = [ordered]@{
                Name        = 'microsoftAppliedSkills'
                Type        = 'stringCollection'
                Description = 'Microsoft Applied Skills credentials earned by the person. Scenario-based Microsoft credentials distinct from Microsoft Certifications.'
            }

            # Visual projection for Profile Card validation.
            AppliedSkillsAwardsProperty = [ordered]@{
                Name   = 'appliedSkillsAwards'
                Type   = 'stringCollection'
                Labels = @('personAwards')
            }

            TitleProperty = [ordered]@{
                Name          = 'title'
                Type          = 'string'
                IsRetrievable = $true
                Labels        = @('title')
            }

            UrlProperty = [ordered]@{
                Name          = 'sourceUrl'
                Type          = 'string'
                IsRetrievable = $true
                Labels        = @('url')
            }

            LastModifiedByProperty = [ordered]@{
                Name          = 'lastModifiedBy'
                Type          = 'string'
                IsRetrievable = $true
                Labels        = @('lastModifiedBy')
            }

            LastModifiedDateTimeProperty = [ordered]@{
                Name          = 'lastModifiedDateTime'
                Type          = 'dateTime'
                IsRetrievable = $true
                Labels        = @('lastModifiedDateTime')
            }
        }

        Provisioning = [ordered]@{
            SchemaTimeoutMinutes = 20
            SchemaPollSeconds    = 15
        }

        CredentialSources = [ordered]@{
            MicrosoftLearn = [ordered]@{
                Enabled                         = $true
                Locale                          = 'en-us'
                PublishActiveCertificationsOnly = $true
                PublishAppliedSkills            = $true
                PublishAppliedSkillsAsAwards    = $true
                AppliedSkillManagedDescription  = 'Microsoft Applied Skills credential synchronized from Microsoft Learn'
            }
            Credly = [ordered]@{
                Enabled    = $true
                MonthsBack = 12
            }
        }

        UserSource = [ordered]@{
            Type = 'Csv'
            CsvPath = (Join-Path $ProjectRoot 'Data\CredentialUsers.csv')
        }

        FieldMapping = [ordered]@{
            UserPrincipalName = 'UserPrincipalName'
            EntraObjectId     = 'EntraObjectId'
            LearnUserName     = 'LearnUserName'
            TranscriptId      = 'TranscriptId'
            CredlyUser        = 'CredlyUser'
            Enabled           = 'Enabled'
        }

        Synchronization = [ordered]@{
            RemoveStaleManaged  = $true
            PreserveUnmanaged   = $true
            ContinueOnUserError = $true
            DryRun              = $false
        }

        Output = [ordered]@{
            LogsDirectory    = $LogsDirectory
            ReportsDirectory = $ReportsDirectory
        }
    }
}

$RootReadme = @'
# Microsoft Learn / Credly -> Microsoft 365 People Profile

Recommended execution order:

1. `0-Initialize-MSLearnPeopleConnector.ps1`
   - Creates folder structure, configuration skeleton and sample data files.
   - Validates required PowerShell modules.

2. Step 1
   - Creates the Entra App Registration and Service Principal.
   - Updates the centralized JSON with tenant/application/authentication values.

3. Step 2
   - Creates the People Data Connector and schema.
   - Registers the Microsoft 365 profile source and precedence.

4. Step 3
   - Reads enabled users and synchronizes Microsoft Learn and Credly credentials.

Folders:

- `Config`: centralized configuration and template.
- `Data`: operational user mapping CSV and sample CSV.
- `Logs`: PowerShell transcripts and diagnostic logs.
- `Reports`: structured synchronization reports.

Security note: during the PoC the configuration can contain a client secret in clear text.
Protect access to the Config folder and migrate to protected secret storage for production.
'@

$ConfigReadme = @'
# Config

## MSLearnPeopleConnector.json

Operational centralized configuration used by Steps 1, 2 and 3.

Commonly modified sections:

- `Application`: TenantId, ClientId and object IDs.
- `Authentication`: ClientSecret, expiration and storage method.
- `Connector`: connection/profile source identifiers.
- `CredentialSources`: enable/disable Microsoft Learn or Credly and set Credly rolling window.
- `UserSource`: operational CSV path.
- `Synchronization`: cleanup, preservation and DryRun behavior.
- `Output`: Logs and Reports locations.

Step 1 should update the existing file rather than replace it, so that settings created
by Step 0 are preserved.

## MSLearnPeopleConnector.Template.json

Reference copy of the current base SchemaVersion 2.4 configuration.
'@

$DataReadme = @'
# Data

## CredentialUsers.csv

Operational input used by the synchronization script.

Columns:

- UserPrincipalName
- EntraObjectId
- LearnUserName
- TranscriptId
- CredlyUser
- Enabled

Microsoft Learn and Credly identifiers can be populated independently according to the
sources available for each user.

## CredentialUsers-Sample.csv

Disabled fictitious sample row for reference only.
'@

$LogsReadme = @'
# Logs

Contains PowerShell transcripts and detailed execution logs generated by the solution.
Use these files for authentication, connector provisioning and synchronization troubleshooting.

Logs can contain tenant, user and credential metadata and should be protected accordingly.
'@

$ReportsReadme = @'
# Reports

Contains structured synchronization result files, normally JSON.

Reports can include users processed, Learn/Credly credentials discovered, additions,
updates, stale removals and errors.
'@

Write-Host ''
Write-Host 'Microsoft Learn / Credly -> Microsoft 365 People Profile' -ForegroundColor White
Write-Host 'STEP 0 - Initialize local environment' -ForegroundColor White

try {
    Write-Step 'STEP 0.1 - Validate PowerShell environment'

    Write-Success "PowerShell version: $($PSVersionTable.PSVersion)"
    Write-InfoMessage "Project root: $RootPath"

    Write-Step 'STEP 0.2 - Create folder structure'

    foreach ($directory in @($ConfigDirectory, $DataDirectory, $LogsDirectory, $ReportsDirectory)) {
        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            Write-Success "Created: $directory"
        }
        else {
            Write-InfoMessage "Already exists: $directory"
        }
    }

    Write-Step 'STEP 0.3 - Validate required PowerShell modules'

    $RequiredModules = @(
        'Microsoft.Graph.Authentication'
        'Microsoft.Graph.Applications'
        'Microsoft.Graph.Beta.Identity.DirectoryManagement'
    )

    foreach ($moduleName in $RequiredModules) {
        Ensure-RequiredModule -Name $moduleName
    }

    Write-Step 'STEP 0.4 - Create centralized configuration'

    $baseConfig = New-BaseConfiguration -ProjectRoot $RootPath

    # New-BaseConfiguration intentionally uses [ordered] dictionaries so the JSON
    # is emitted in a predictable order. For recursive contract comparison, first
    # normalize that object through JSON into PSCustomObject. Enumerating
    # OrderedDictionary.PSObject.Properties exposes adapter members such as Count,
    # Keys, Values and SyncRoot instead of only the configuration keys.
    $baseContract =
        $baseConfig |
            ConvertTo-Json -Depth 30 |
            ConvertFrom-Json

    # Keep the reference template aligned with the latest configuration contract.
    # The template contains no operational secrets, so an older template can be
    # safely refreshed in place.
    $writeTemplate = $false

    if (-not (Test-Path -LiteralPath $TemplatePath)) {
        $writeTemplate = $true
        Write-InfoMessage "Template does not exist and will be created."
    }
    elseif ($RefreshDocumentation) {
        $writeTemplate = $true
        Write-InfoMessage "Template refresh explicitly requested."
    }
    else {
        try {
            $existingTemplate =
                Get-Content -LiteralPath $TemplatePath -Raw -Encoding utf8 |
                ConvertFrom-Json -ErrorAction Stop

            $templateVersionText = [string]$existingTemplate.SchemaVersion

            if ([string]::IsNullOrWhiteSpace($templateVersionText)) {
                $writeTemplate = $true
                Write-WarnMessage "Template SchemaVersion is missing. The template will be refreshed."
            }
            else {
                $templateVersion = [version]$templateVersionText

                if ($templateVersion -lt $TargetSchemaVersion) {
                    $writeTemplate = $true
                    Write-InfoMessage (
                        "Template SchemaVersion $templateVersionText is older than " +
                        "$TargetSchemaVersionText and will be refreshed."
                    )
                }
                else {
                    Write-InfoMessage (
                        "Template SchemaVersion $templateVersionText is current or newer. Preserving it."
                    )
                }
            }
        }
        catch {
            $writeTemplate = $true
            Write-WarnMessage (
                "Template could not be validated and will be refreshed: " +
                $_.Exception.Message
            )
        }
    }

    if ($writeTemplate) {
        Save-JsonAtomic -Path $TemplatePath -Object $baseConfig
        Write-Success "Template written: $TemplatePath"
    }

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Save-JsonAtomic -Path $ConfigPath -Object $baseConfig
        Write-Success (
            "Operational configuration created with SchemaVersion " +
            $TargetSchemaVersionText + ": " + $ConfigPath
        )
    }
    elseif ($ResetConfig) {
        $backup = "$ConfigPath.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
        Copy-Item -LiteralPath $ConfigPath -Destination $backup -Force
        Write-WarnMessage "Existing configuration backed up to: $backup"

        Save-JsonAtomic -Path $ConfigPath -Object $baseConfig
        Write-Success (
            "Operational configuration reset to SchemaVersion " +
            $TargetSchemaVersionText + ": " + $ConfigPath
        )
    }
    else {
        try {
            $existingConfig =
                Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 |
                ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw (
                "Existing operational configuration is not valid JSON and was not modified: " +
                $ConfigPath + [Environment]::NewLine + $_.Exception.Message
            )
        }

        $schemaVersionProperty =
            $existingConfig.PSObject.Properties['SchemaVersion']

        if (
            $null -eq $schemaVersionProperty -or
            [string]::IsNullOrWhiteSpace([string]$schemaVersionProperty.Value)
        ) {
            throw (
                "Existing operational configuration does not contain a valid SchemaVersion. " +
                "The file was not modified: $ConfigPath"
            )
        }

        $currentSchemaVersionText =
            [string]$schemaVersionProperty.Value

        try {
            $currentSchemaVersion =
                [version]$currentSchemaVersionText
        }
        catch {
            throw (
                "Existing operational configuration has an invalid SchemaVersion " +
                "'$currentSchemaVersionText'. The file was not modified: $ConfigPath"
            )
        }

        if ($currentSchemaVersion -gt $TargetSchemaVersion) {
            Write-WarnMessage (
                "Operational configuration SchemaVersion $currentSchemaVersionText is newer than " +
                "this Step 0 target ($TargetSchemaVersionText). The file was preserved unchanged."
            )
        }
        else {
            $configurationChanged = $false

            # Cleanup for a short-lived Step 0 implementation that recursively
            # enumerated OrderedDictionary adapter members rather than configuration
            # keys. If that build was executed, it could persist these root-level
            # JSON properties. They are not part of any supported configuration
            # contract and must be removed before reconciliation.
            $adapterArtifactNames = @(
                'Count',
                'IsReadOnly',
                'Keys',
                'Values',
                'IsFixedSize',
                'SyncRoot',
                'IsSynchronized'
            )

            $removedAdapterArtifacts = @()

            foreach ($artifactName in $adapterArtifactNames) {
                $artifactProperty =
                    $existingConfig.PSObject.Properties[$artifactName]

                if ($null -ne $artifactProperty) {
                    $existingConfig.PSObject.Properties.Remove($artifactName)
                    $removedAdapterArtifacts += "root.$artifactName"
                    $configurationChanged = $true
                }
            }

            if ($removedAdapterArtifacts.Count -gt 0) {
                Write-WarnMessage (
                    "Removed invalid configuration artifacts created by an earlier " +
                    "Step 0 contract-reconciliation build:"
                )

                foreach ($artifactPath in $removedAdapterArtifacts) {
                    Write-Host "  - $artifactPath" -ForegroundColor DarkGray
                }
            }

            if ($currentSchemaVersion -lt $TargetSchemaVersion) {
                # Schema itself is owned by the schema contract. Upgrade it while
                # preserving operational values elsewhere.
                $existingConfig.SchemaVersion = $TargetSchemaVersionText

                $schemaProperty = $existingConfig.PSObject.Properties['Schema']

                if ($null -eq $schemaProperty) {
                    $existingConfig | Add-Member -NotePropertyName 'Schema' -NotePropertyValue (Copy-ConfigurationValue -Value $baseContract.Schema)
                }
                else {
                    $existingConfig.Schema = Copy-ConfigurationValue -Value $baseContract.Schema
                }

                $configurationChanged = $true
            }

            # Development-era configurations can already report the current
            # SchemaVersion while still missing sections introduced later, such as
            # Provisioning. Restore only missing properties; never overwrite an
            # existing tenant ID, application ID, secret, path, source setting, or
            # synchronization choice.
            $addedConfigurationPaths = @(
                Add-MissingConfigurationProperties -Target $existingConfig -Defaults $baseContract -Path 'root'
            )

            if ($addedConfigurationPaths.Count -gt 0) {
                $configurationChanged = $true
                Write-InfoMessage 'Missing configuration properties detected and restored:'

                foreach ($addedPath in $addedConfigurationPaths) {
                    Write-Host "  + $addedPath" -ForegroundColor DarkGray
                }
            }

            # Migrate project-owned legacy branding while preserving custom names and identities.
            $brandingUpdates = @(
                @{ Section = 'Application'; Name = 'DisplayName'; Legacy = @('MSLearn People Connector', 'Microsoft Learn Credentials'); Value = $baseContract.Application.DisplayName },
                @{ Section = 'Connector'; Name = 'ConnectionName'; Legacy = @('Microsoft Learn Credentials'); Value = $baseContract.Connector.ConnectionName },
                @{ Section = 'Connector'; Name = 'ConnectionDescription'; Legacy = @('Microsoft Learn and Credly credentials for Microsoft 365 people profiles'); Value = $baseContract.Connector.ConnectionDescription }
            )
            foreach ($brandingUpdate in $brandingUpdates) {
                $section = $existingConfig.PSObject.Properties[$brandingUpdate.Section].Value
                $property = $section.PSObject.Properties[$brandingUpdate.Name]
                if ($null -ne $property -and [string]$property.Value -in $brandingUpdate.Legacy) {
                    $property.Value = $brandingUpdate.Value
                    $configurationChanged = $true
                    Write-InfoMessage "Updated project branding: $($brandingUpdate.Section).$($brandingUpdate.Name)"
                }
            }

            if ($configurationChanged) {
                $backup = "$ConfigPath.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
                Copy-Item -LiteralPath $ConfigPath -Destination $backup -Force
                Write-WarnMessage "Existing configuration backed up to: $backup"

                $lastUpdatedProperty = $existingConfig.PSObject.Properties['LastUpdatedUtc']

                if ($null -eq $lastUpdatedProperty) {
                    $existingConfig | Add-Member -NotePropertyName 'LastUpdatedUtc' -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o'))
                }
                else {
                    $existingConfig.LastUpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
                }

                Save-JsonAtomic -Path $ConfigPath -Object $existingConfig

                if ($currentSchemaVersion -lt $TargetSchemaVersion) {
                    Write-Success (
                        "Operational configuration upgraded from SchemaVersion " +
                        "$currentSchemaVersionText to $TargetSchemaVersionText and reconciled."
                    )
                }
                else {
                    Write-Success (
                        "Operational configuration SchemaVersion $TargetSchemaVersionText " +
                        "contract reconciled without replacing existing operational values."
                    )
                }
            }
            else {
                Write-Success (
                    "Operational configuration already matches SchemaVersion " +
                    "$TargetSchemaVersionText contract. No migration required."
                )
            }
        }
    }

    Write-Step 'STEP 0.5 - Create data files'

    $csvHeader = 'UserPrincipalName,EntraObjectId,LearnUserName,TranscriptId,CredlyUser,Enabled'

    if (-not (Test-Path -LiteralPath $UsersPath)) {
        Set-Content -LiteralPath $UsersPath -Value $csvHeader -Encoding utf8
        Write-Success "Operational CSV created: $UsersPath"
    }
    elseif ($ResetDataFile) {
        $backup = "$UsersPath.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
        Copy-Item -LiteralPath $UsersPath -Destination $backup -Force
        Write-WarnMessage "Existing data file backed up to: $backup"
        Set-Content -LiteralPath $UsersPath -Value $csvHeader -Encoding utf8
        Write-Success "Operational CSV reset: $UsersPath"
    }
    else {
        Write-InfoMessage "Operational CSV preserved: $UsersPath"
    }

    $sample = @'
UserPrincipalName,EntraObjectId,LearnUserName,TranscriptId,CredlyUser,Enabled
user@contoso.com,00000000-0000-0000-0000-000000000000,learn-user,public-transcript-id,credly-user,False
'@

    if (-not (Test-Path -LiteralPath $UsersSamplePath) -or $RefreshDocumentation) {
        Set-Content -LiteralPath $UsersSamplePath -Value $sample.Trim() -Encoding utf8
        Write-Success "Sample CSV written: $UsersSamplePath"
    }
    else {
        Write-InfoMessage "Sample CSV preserved: $UsersSamplePath"
    }

    Write-Step 'STEP 0.6 - Create README files'

    $readmes = @(
        @{ Path = (Join-Path $RootPath 'README.md');            Content = $RootReadme },
        @{ Path = (Join-Path $ConfigDirectory 'README.md');     Content = $ConfigReadme },
        @{ Path = (Join-Path $DataDirectory 'README.md');       Content = $DataReadme },
        @{ Path = (Join-Path $LogsDirectory 'README.md');       Content = $LogsReadme },
        @{ Path = (Join-Path $ReportsDirectory 'README.md');    Content = $ReportsReadme }
    )

    foreach ($readme in $readmes) {
        if (-not (Test-Path -LiteralPath $readme.Path) -or $RefreshDocumentation) {
            Set-Content -LiteralPath $readme.Path -Value $readme.Content.Trim() -Encoding utf8
            Write-Success "README written: $($readme.Path)"
        }
        else {
            Write-InfoMessage "README preserved: $($readme.Path)"
        }
    }

    Write-Step 'STEP 0.7 - Final validation'

    $expectedPaths = @(
        $ConfigDirectory,
        $DataDirectory,
        $LogsDirectory,
        $ReportsDirectory,
        $ConfigPath,
        $TemplatePath,
        $UsersPath,
        $UsersSamplePath
    )

    $missing = @($expectedPaths | Where-Object { -not (Test-Path -LiteralPath $_) })

    if ($missing.Count -gt 0) {
        throw "Initialization completed with missing paths: $($missing -join ', ')"
    }

    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

    $validatedSchemaVersionText =
        [string]$config.SchemaVersion

    try {
        $validatedSchemaVersion =
            [version]$validatedSchemaVersionText
    }
    catch {
        throw "Operational configuration contains an invalid SchemaVersion '$validatedSchemaVersionText'."
    }

    if ($validatedSchemaVersion -lt $TargetSchemaVersion) {
        throw (
            "Operational configuration validation failed. Expected SchemaVersion " +
            "$TargetSchemaVersionText or later but found $validatedSchemaVersionText."
        )
    }

    if ($validatedSchemaVersion -eq $TargetSchemaVersion) {
        $missingContractProperties = @(
            Get-MissingConfigurationProperties -Target $config -Defaults $baseContract -Path 'root'
        )

        if ($missingContractProperties.Count -gt 0) {
            throw (
                "Operational configuration is SchemaVersion $TargetSchemaVersionText but " +
                "is missing required contract properties: " +
                ($missingContractProperties -join ', ')
            )
        }
    }

    Write-Success (
        "Operational configuration JSON and contract validated " +
        "(SchemaVersion $validatedSchemaVersionText)."
    )

    Write-Host ''
    Write-Host 'Initialization completed successfully.' -ForegroundColor Green
    Write-Host "Project root : $RootPath"
    Write-Host "Config       : $ConfigPath"
    Write-Host "Users        : $UsersPath"
    Write-Host "Logs         : $LogsDirectory"
    Write-Host "Reports      : $ReportsDirectory"
    Write-Host ''
    Write-Host 'Step 0 configuration validation/migration completed.' -ForegroundColor Cyan
    Write-Host 'Validate SchemaVersion 2.4 before continuing with the next project step.' -ForegroundColor Cyan
}
catch {
    Write-Host ''
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    throw
}