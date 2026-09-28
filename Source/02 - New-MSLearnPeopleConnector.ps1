#requires -Version 7.0
<#
.SYNOPSIS
    Step 2 - Creates and configures the Microsoft 365 People Data Connector
    using the centralized MSLearnPeopleConnector.json configuration.

.DESCRIPTION
    This script intentionally contains no tenant-specific, application-specific,
    connector-specific, schema-specific, profile-source-specific, or user data.

    Runtime flow:
      1. Load Config\MSLearnPeopleConnector.json.
      2. Validate the required configuration contract.
      3. Connect to Microsoft Graph using App-Only authentication.
      4. Create or validate the People external connection.
      5. Register the schema from the JSON configuration when the connection is draft.
      6. Wait for the connection to become ready using configured provisioning values.
      7. Register the connector as a Microsoft 365 profile source.
      8. Configure profile source precedence from the JSON configuration.
      9. Validate the resulting configuration.
     10. Disconnect Microsoft Graph in all cases.

    This script does NOT ingest users, certifications, badges, externalItems,
    test records, or sample data.

.CONFIGURATION
    Default:
      .\Config\MSLearnPeopleConnector.json

    Required configuration sections:
      Application
      Authentication
      MicrosoftGraph
      Connector
      Output

.NOTES
    Step 3 is responsible for Microsoft Learn / Credly synchronization.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [switch]$SkipModuleInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Script-local technical dependencies only.
# No environment or tenant data is stored here.
# ---------------------------------------------------------------------------

$RequiredModules = @(
    "Microsoft.Graph.Authentication",
    "Microsoft.Graph.Beta.Identity.DirectoryManagement"
)

$ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($ScriptDirectory)) {
    $ScriptDirectory = (Get-Location).Path
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $ScriptDirectory "Config\MSLearnPeopleConnector.json"
}
else {
    $ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
}

$script:TranscriptStarted = $false
$script:GraphConnected = $false
$script:LogPath = $null

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)

    Write-Host ""
    Write-Host ("=" * 84) -ForegroundColor DarkGray
    Write-Host $Message -ForegroundColor Cyan
    Write-Host ("=" * 84) -ForegroundColor DarkGray
}

function Write-Success {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Get-ConfigProperty {
    param(
        [Parameter(Mandatory)]
        $Object,

        [Parameter(Mandatory)]
        [string]$PropertyName,

        [Parameter(Mandatory)]
        [string]$ConfigPathName,

        [switch]$AllowEmpty
    )

    if ($null -eq $Object) {
        throw "Configuration object '$ConfigPathName' is missing."
    }

    $Property = $Object.PSObject.Properties[$PropertyName]

    if ($null -eq $Property) {
        throw "Configuration value '$ConfigPathName.$PropertyName' is missing."
    }

    if (-not $AllowEmpty) {
        if ($null -eq $Property.Value) {
            throw "Configuration value '$ConfigPathName.$PropertyName' is null."
        }

        if ($Property.Value -is [string] -and
            [string]::IsNullOrWhiteSpace([string]$Property.Value)) {
            throw "Configuration value '$ConfigPathName.$PropertyName' is empty."
        }
    }

    return $Property.Value
}

function Resolve-ConfigRelativePath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath(
        (Join-Path $ScriptDirectory $Path)
    )
}

function Ensure-Module {
    param([Parameter(Mandatory)][string]$Name)

    if (-not (Get-Module -ListAvailable -Name $Name)) {
        if ($SkipModuleInstall) {
            throw "Required module '$Name' is not installed."
        }

        Write-Host "Installing required module: $Name" -ForegroundColor Yellow

        Install-Module `
            -Name $Name `
            -Scope CurrentUser `
            -Force `
            -AllowClobber `
            -ErrorAction Stop
    }

    Import-Module $Name -ErrorAction Stop
}

function Get-ExternalConnection {
    param([Parameter(Mandatory)][string]$Id)

    try {
        return Invoke-MgGraphRequest `
            -Method GET `
            -Uri "$script:ConnectionsUri/$Id" `
            -OutputType PSObject `
            -ErrorAction Stop
    }
    catch {
        if ($_.Exception.Message -match "404|Not Found") {
            return $null
        }

        throw
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {

    Write-Step "STEP 0 - Load centralized configuration"

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Configuration file not found: $ConfigPath"
    }

    try {
        $Config =
            Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Configuration file is not valid JSON: $ConfigPath`n$($_.Exception.Message)"
    }

    $SchemaVersion =
        [string](Get-ConfigProperty `
            -Object $Config `
            -PropertyName "SchemaVersion" `
            -ConfigPathName "root")

    if ($SchemaVersion -ne "2.2") {
        throw "Unsupported configuration SchemaVersion '$SchemaVersion'. Step 2 expects SchemaVersion 2.2 generated by Step 0."
    }

    # -----------------------------------------------------------------------
    # Application / authentication
    # -----------------------------------------------------------------------

    $Application =
        Get-ConfigProperty `
            -Object $Config `
            -PropertyName "Application" `
            -ConfigPathName "root"

    $Authentication =
        Get-ConfigProperty `
            -Object $Config `
            -PropertyName "Authentication" `
            -ConfigPathName "root"

    $TenantId =
        [string](Get-ConfigProperty `
            -Object $Application `
            -PropertyName "TenantId" `
            -ConfigPathName "Application")

    $ClientId =
        [string](Get-ConfigProperty `
            -Object $Application `
            -PropertyName "ClientId" `
            -ConfigPathName "Application")

    $ClientSecret =
        [string](Get-ConfigProperty `
            -Object $Authentication `
            -PropertyName "ClientSecret" `
            -ConfigPathName "Authentication")

    $SecretStorage =
        [string](Get-ConfigProperty `
            -Object $Authentication `
            -PropertyName "SecretStorage" `
            -ConfigPathName "Authentication")

    if ($SecretStorage -ne "PlainText") {
        throw "Authentication.SecretStorage '$SecretStorage' is not supported by this version. Expected 'PlainText'."
    }

    $AuthModeProperty = $Authentication.PSObject.Properties["Mode"]
    if ($null -ne $AuthModeProperty -and
        -not [string]::IsNullOrWhiteSpace([string]$AuthModeProperty.Value) -and
        [string]$AuthModeProperty.Value -ne "ClientSecret") {

        throw "Authentication.Mode '$($AuthModeProperty.Value)' is not supported by this version."
    }

    $ExpirationProperty =
        $Authentication.PSObject.Properties["SecretExpirationUtc"]

    if ($null -ne $ExpirationProperty -and
        -not [string]::IsNullOrWhiteSpace([string]$ExpirationProperty.Value)) {

        $SecretExpirationUtc =
            [datetimeoffset]::Parse(
                [string]$ExpirationProperty.Value,
                [System.Globalization.CultureInfo]::InvariantCulture
            )

        if ($SecretExpirationUtc -le [datetimeoffset]::UtcNow) {
            throw "The configured client secret expired at $($SecretExpirationUtc.ToString('u'))."
        }
    }

    # -----------------------------------------------------------------------
    # Microsoft Graph
    # -----------------------------------------------------------------------

    $MicrosoftGraph =
        Get-ConfigProperty `
            -Object $Config `
            -PropertyName "MicrosoftGraph" `
            -ConfigPathName "root"

    $GraphV1 =
        ([string](Get-ConfigProperty `
            -Object $MicrosoftGraph `
            -PropertyName "GraphV1" `
            -ConfigPathName "MicrosoftGraph")).TrimEnd("/")

    $GraphBeta =
        ([string](Get-ConfigProperty `
            -Object $MicrosoftGraph `
            -PropertyName "GraphBeta" `
            -ConfigPathName "MicrosoftGraph")).TrimEnd("/")

    $script:ConnectionsUri =
        "$GraphV1/external/connections"

    $ProfileSourcesUri =
        "$GraphV1/admin/people/profileSources"

    $BetaProfileSourcesBase =
        "$GraphBeta/admin/people/profileSources"

    # -----------------------------------------------------------------------
    # Connector
    # -----------------------------------------------------------------------

    $Connector =
        Get-ConfigProperty `
            -Object $Config `
            -PropertyName "Connector" `
            -ConfigPathName "root"

    $ConnectionId =
        [string](Get-ConfigProperty `
            -Object $Connector `
            -PropertyName "ConnectionId" `
            -ConfigPathName "Connector")

    if ($ConnectionId -notmatch '^[A-Za-z0-9]{3,32}$') {
        throw "Connector.ConnectionId '$ConnectionId' does not meet the expected Graph connection ID format."
    }

    $ConnectionName =
        [string](Get-ConfigProperty `
            -Object $Connector `
            -PropertyName "ConnectionName" `
            -ConfigPathName "Connector")

    $ConnectionDescription =
        [string](Get-ConfigProperty `
            -Object $Connector `
            -PropertyName "ConnectionDescription" `
            -ConfigPathName "Connector")

    $ContentCategory =
        [string](Get-ConfigProperty `
            -Object $Connector `
            -PropertyName "ContentCategory" `
            -ConfigPathName "Connector")

    # -----------------------------------------------------------------------
    # Connector schema
    # -----------------------------------------------------------------------

    # SchemaVersion 2.2 stores the schema at the root level. Step 0 currently
    # defines the two People profile properties used by this solution:
    #   - Schema.AccountProperty
    #   - Schema.CertificationProperty

    $Schema =
        Get-ConfigProperty `
            -Object $Config `
            -PropertyName "Schema" `
            -ConfigPathName "root"

    $SchemaBaseType =
        [string](Get-ConfigProperty `
            -Object $Schema `
            -PropertyName "BaseType" `
            -ConfigPathName "Schema")

    $AccountProperty =
        Get-ConfigProperty `
            -Object $Schema `
            -PropertyName "AccountProperty" `
            -ConfigPathName "Schema"

    $CertificationProperty =
        Get-ConfigProperty `
            -Object $Schema `
            -PropertyName "CertificationProperty" `
            -ConfigPathName "Schema"

    $ConfiguredSchemaProperties = @(
        $AccountProperty
        $CertificationProperty
    )

    $SchemaProperties = @(
        foreach ($Property in $ConfiguredSchemaProperties) {

            $PropertyName =
                [string](Get-ConfigProperty `
                    -Object $Property `
                    -PropertyName "Name" `
                    -ConfigPathName "Schema")

            $PropertyType =
                [string](Get-ConfigProperty `
                    -Object $Property `
                    -PropertyName "Type" `
                    -ConfigPathName "Schema")

            $Labels =
                @(
                    Get-ConfigProperty `
                        -Object $Property `
                        -PropertyName "Labels" `
                        -ConfigPathName "Schema"
                )

            [ordered]@{
                name   = $PropertyName
                type   = $PropertyType
                labels = $Labels
            }
        }
    )

    $SchemaBody = [ordered]@{
        baseType   = $SchemaBaseType
        properties = $SchemaProperties
    }

    # -----------------------------------------------------------------------
    # Profile source
    # -----------------------------------------------------------------------

    # SchemaVersion 2.2 keeps profile-source settings directly under Connector.

    $ProfileSourceKind =
        [string](Get-ConfigProperty `
            -Object $Connector `
            -PropertyName "ProfileSourceKind" `
            -ConfigPathName "Connector")

    $ProfileSourceWebUrl =
        [string](Get-ConfigProperty `
            -Object $Connector `
            -PropertyName "ProfileSourceWebUrl" `
            -ConfigPathName "Connector")

    $PrecedenceSettingId =
        [string](Get-ConfigProperty `
            -Object $Connector `
            -PropertyName "ProfilePropertySettingId" `
            -ConfigPathName "Connector")

    $EntraIdSourceId =
        [string](Get-ConfigProperty `
            -Object $Connector `
            -PropertyName "EntraIdSourceId" `
            -ConfigPathName "Connector")

    # -----------------------------------------------------------------------
    # Provisioning
    # -----------------------------------------------------------------------

    $Provisioning =
        Get-ConfigProperty `
            -Object $Config `
            -PropertyName "Provisioning" `
            -ConfigPathName "root"

    $SchemaTimeoutMinutes =
        [int](Get-ConfigProperty `
            -Object $Provisioning `
            -PropertyName "SchemaTimeoutMinutes" `
            -ConfigPathName "Provisioning")

    $SchemaPollSeconds =
        [int](Get-ConfigProperty `
            -Object $Provisioning `
            -PropertyName "SchemaPollSeconds" `
            -ConfigPathName "Provisioning")

    if ($SchemaTimeoutMinutes -lt 1) {
        throw "Provisioning.SchemaTimeoutMinutes must be greater than zero."
    }

    if ($SchemaPollSeconds -lt 1) {
        throw "Provisioning.SchemaPollSeconds must be greater than zero."
    }

    # -----------------------------------------------------------------------
    # Output
    # -----------------------------------------------------------------------

    $Output =
        Get-ConfigProperty `
            -Object $Config `
            -PropertyName "Output" `
            -ConfigPathName "root"

    $LogDirectorySetting =
        [string](Get-ConfigProperty `
            -Object $Output `
            -PropertyName "LogsDirectory" `
            -ConfigPathName "Output")

    $LogDirectory =
        Resolve-ConfigRelativePath -Path $LogDirectorySetting

    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item `
            -ItemType Directory `
            -Path $LogDirectory `
            -Force |
            Out-Null
    }

    $script:LogPath =
        Join-Path `
            $LogDirectory `
            ("New-MSLearnPeopleConnector-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

    try {
        Start-Transcript -Path $script:LogPath -Force | Out-Null
        $script:TranscriptStarted = $true
    }
    catch {
        Write-Warning "Could not start transcript logging: $($_.Exception.Message)"
    }

    Write-Host "Configuration file : $ConfigPath"
    Write-Host "Schema version     : $SchemaVersion"
    Write-Host "Application        : $($Application.DisplayName)"
    Write-Host "Tenant ID          : $TenantId"
    Write-Host "Client ID          : $ClientId"
    Write-Host "Connection ID      : $ConnectionId"
    Write-Host "Connection name    : $ConnectionName"
    Write-Host "Content category   : $ContentCategory"
    Write-Host "Graph v1           : $GraphV1"
    Write-Host "Graph beta         : $GraphBeta"
    Write-Success "Centralized configuration loaded and validated."

    # -----------------------------------------------------------------------
    # Modules
    # -----------------------------------------------------------------------

    Write-Step "STEP 1 - Validate Microsoft Graph PowerShell modules"

    foreach ($Module in $RequiredModules) {
        Ensure-Module -Name $Module
        Write-Success "Module available: $Module"
    }

    # -----------------------------------------------------------------------
    # Authentication
    # -----------------------------------------------------------------------

    Write-Step "STEP 2 - Authenticate to Microsoft Graph (App-Only)"

    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null

    $SecureClientSecret =
        ConvertTo-SecureString `
            -String $ClientSecret `
            -AsPlainText `
            -Force

    $ClientSecretCredential =
        [System.Management.Automation.PSCredential]::new(
            $ClientId,
            $SecureClientSecret
        )

    Connect-MgGraph `
        -TenantId $TenantId `
        -ClientSecretCredential $ClientSecretCredential `
        -NoWelcome `
        -ErrorAction Stop

    $script:GraphConnected = $true

    $Context = Get-MgContext

    $Context |
        Select-Object ClientId, TenantId, AuthType, Scopes |
        Format-List

    if ($Context.AuthType -ne "AppOnly") {
        throw "Expected AppOnly authentication but received '$($Context.AuthType)'."
    }

    if ($Context.TenantId -ne $TenantId) {
        throw "Connected tenant '$($Context.TenantId)' does not match configured tenant '$TenantId'."
    }

    if ($Context.ClientId -ne $ClientId) {
        throw "Connected ClientId '$($Context.ClientId)' does not match configured ClientId '$ClientId'."
    }

    Write-Success "Authenticated to Microsoft Graph with the configured application."

    # -----------------------------------------------------------------------
    # Connection
    # -----------------------------------------------------------------------

    Write-Step "STEP 3 - Create or validate the People external connection"

    $Connection = Get-ExternalConnection -Id $ConnectionId

    if (-not $Connection) {

        Write-Host "Creating external connection '$ConnectionId'..."

        $ConnectionBody = [ordered]@{
            id              = $ConnectionId
            name            = $ConnectionName
            description     = $ConnectionDescription
            contentCategory = $ContentCategory
        }

        $Connection =
            Invoke-MgGraphRequest `
                -Method POST `
                -Uri $script:ConnectionsUri `
                -Body ($ConnectionBody | ConvertTo-Json -Depth 10 -Compress) `
                -ContentType "application/json" `
                -OutputType PSObject `
                -ErrorAction Stop

        Write-Success "External connection created."
    }
    else {
        Write-Success "External connection already exists."
    }

    $Connection = Get-ExternalConnection -Id $ConnectionId

    $Connection |
        Select-Object id, name, description, contentCategory, state |
        Format-List

    if ($Connection.contentCategory -ne $ContentCategory) {
        throw "Connection '$ConnectionId' contentCategory '$($Connection.contentCategory)' does not match configured '$ContentCategory'."
    }

    if ($Connection.state -in @("obsolete", "limitExceeded")) {
        throw "Connection '$ConnectionId' is in unsupported state '$($Connection.state)'."
    }

    # -----------------------------------------------------------------------
    # Schema
    # -----------------------------------------------------------------------

    Write-Step "STEP 4 - Validate/register configured People Data schema"

    $Connection = Get-ExternalConnection -Id $ConnectionId

    if ($Connection.state -eq "ready") {

        Write-Success "Connection is already READY. Schema registration is skipped."

    }
    elseif ($Connection.state -eq "draft") {

        Write-Host "Connection is DRAFT. Registering schema from configuration..."

        Invoke-MgGraphRequest `
            -Method PATCH `
            -Uri "$($script:ConnectionsUri)/$ConnectionId/schema" `
            -Body ($SchemaBody | ConvertTo-Json -Depth 30 -Compress) `
            -ContentType "application/json" `
            -ErrorAction Stop |
            Out-Null

        Write-Host (
            "Waiting for schema provisioning " +
            "(timeout $SchemaTimeoutMinutes min, poll every $SchemaPollSeconds sec)..."
        )

        $Deadline =
            (Get-Date).AddMinutes($SchemaTimeoutMinutes)

        do {
            Start-Sleep -Seconds $SchemaPollSeconds

            $Connection =
                Get-ExternalConnection -Id $ConnectionId

            Write-Host "Connection state: $($Connection.state)"

            if ($Connection.state -eq "ready") {
                break
            }

            if ($Connection.state -in @("obsolete", "limitExceeded")) {
                throw "Schema provisioning ended with connection state '$($Connection.state)'."
            }

            if ((Get-Date) -ge $Deadline) {
                throw "Timeout after $SchemaTimeoutMinutes minutes waiting for schema provisioning."
            }

        } while ($true)

        Write-Success "Connector schema provisioned. Connection is READY."

    }
    else {
        throw "Unexpected external connection state '$($Connection.state)'."
    }

    # -----------------------------------------------------------------------
    # Profile source
    # -----------------------------------------------------------------------

    Write-Step "STEP 5 - Register connector as a Microsoft 365 profile source"

    $Sources =
        Invoke-MgGraphRequest `
            -Method GET `
            -Uri $ProfileSourcesUri `
            -OutputType PSObject `
            -ErrorAction Stop

    $ProfileSource =
        @(
            $Sources.value |
                Where-Object {
                    $_.sourceId -eq $ConnectionId
                }
        ) |
        Select-Object -First 1

    if (-not $ProfileSource) {

        Write-Host "Registering profile source '$ConnectionId'..."

        $ProfileSourceBody = [ordered]@{
            sourceId    = $ConnectionId
            displayName = $ConnectionName
            kind        = $ProfileSourceKind
            webUrl      = $ProfileSourceWebUrl
        }

        $ProfileSource =
            Invoke-MgGraphRequest `
                -Method POST `
                -Uri $ProfileSourcesUri `
                -Body ($ProfileSourceBody | ConvertTo-Json -Depth 10 -Compress) `
                -ContentType "application/json; charset=utf-8" `
                -OutputType PSObject `
                -ErrorAction Stop

        Write-Success "Profile source registered."
    }
    else {
        Write-Success "Profile source is already registered."
    }

    $ProfileSource |
        Select-Object id, sourceId, kind, displayName, webUrl |
        Format-List

    # -----------------------------------------------------------------------
    # Precedence
    # -----------------------------------------------------------------------

    Write-Step "STEP 6 - Configure Microsoft 365 profile source precedence"

    $BetaSettings =
        Get-MgBetaAdminPeopleProfilePropertySetting `
            -ErrorAction Stop

    $Setting =
        @(
            $BetaSettings |
                Where-Object {
                    [string]$_.Id -eq $PrecedenceSettingId
                }
        ) |
        Select-Object -First 1

    if (-not $Setting) {
        throw "Configured profilePropertySetting '$PrecedenceSettingId' was not returned by Microsoft Graph."
    }

    Write-Host "profilePropertySetting ID: $($Setting.Id)"

    $ConnectorSourceUrl =
        "$BetaProfileSourcesBase(sourceId='$ConnectionId')"

    $EntraSourceUrl =
        "$BetaProfileSourcesBase(sourceId='$EntraIdSourceId')"

    $ExistingSourceUrls =
        @(
            $Setting.PrioritizedSourceUrls |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace([string]$_)
                } |
                ForEach-Object {

                    $CurrentUrl = [string]$_

                    $V1Prefix =
                        "$GraphV1/admin/people/profileSources"

                    if ($CurrentUrl.StartsWith(
                        $V1Prefix,
                        [System.StringComparison]::OrdinalIgnoreCase
                    )) {
                        $CurrentUrl =
                            $BetaProfileSourcesBase +
                            $CurrentUrl.Substring($V1Prefix.Length)
                    }

                    $CurrentUrl
                }
        )

    # Always place the external Microsoft Learn/Credly connector before the
    # configured Entra ID profile source, while preserving any other sources.
    $OtherSourceUrls =
        @(
            $ExistingSourceUrls |
                Where-Object {
                    $_ -ne $ConnectorSourceUrl -and
                    $_ -ne $EntraSourceUrl
                } |
                Select-Object -Unique
        )

    [string[]]$PrioritySources =
        @($ConnectorSourceUrl, $EntraSourceUrl) + $OtherSourceUrls

    Write-Host "Configured profile source precedence:"

    for ($i = 0; $i -lt $PrioritySources.Count; $i++) {
        Write-Host ("  {0}. {1}" -f ($i + 1), $PrioritySources[$i])
    }

    $PriorityParams = @{
        prioritizedSourceUrls = $PrioritySources
    }

    Update-MgBetaAdminPeopleProfilePropertySetting `
        -ProfilePropertySettingId $Setting.Id `
        -BodyParameter $PriorityParams `
        -ErrorAction Stop |
        Out-Null

    Write-Success "Profile source precedence updated successfully."

    $VerifySetting =
        Get-MgBetaAdminPeopleProfilePropertySetting `
            -ProfilePropertySettingId $Setting.Id `
            -ErrorAction Stop

    if (@($VerifySetting.PrioritizedSourceUrls) -notcontains $ConnectorSourceUrl) {
        throw "Profile source precedence verification failed for '$ConnectorSourceUrl'."
    }

    # -----------------------------------------------------------------------
    # Final validation
    # -----------------------------------------------------------------------

    Write-Step "STEP 7 - Final validation"

    $FinalConnection =
        Get-ExternalConnection -Id $ConnectionId

    $FinalSources =
        Invoke-MgGraphRequest `
            -Method GET `
            -Uri $ProfileSourcesUri `
            -OutputType PSObject `
            -ErrorAction Stop

    $FinalSetting =
        Get-MgBetaAdminPeopleProfilePropertySetting `
            -ProfilePropertySettingId $Setting.Id `
            -ErrorAction Stop

    Write-Host ""
    Write-Host "External connection:" -ForegroundColor Cyan

    $FinalConnection |
        Select-Object id, name, description, contentCategory, state |
        Format-List

    Write-Host "Registered profile source:" -ForegroundColor Cyan

    $FinalSources.value |
        Where-Object { $_.sourceId -eq $ConnectionId } |
        Select-Object sourceId, displayName, kind, webUrl |
        Format-List

    Write-Host "Profile source precedence:" -ForegroundColor Cyan

    $FinalSetting.PrioritizedSourceUrls |
        ForEach-Object {
            Write-Host "  $_"
        }

    Write-Host ""
    Write-Success "Step 2 completed. No user/test data was inserted."

    if ($script:LogPath) {
        Write-Host "Log file: $($script:LogPath)" -ForegroundColor DarkGray
    }
}
catch {

    Write-Host ""
    Write-Host "SCRIPT FAILED" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red

    if ($_.InvocationInfo) {
        Write-Host ""
        Write-Host "Location:" -ForegroundColor Yellow
        Write-Host $_.InvocationInfo.PositionMessage
    }

    if ($script:LogPath) {
        Write-Host ""
        Write-Host "Log file: $($script:LogPath)" -ForegroundColor DarkGray
    }

    throw
}
finally {

    if ($script:GraphConnected) {
        try {
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
            Write-Host "Microsoft Graph session closed." -ForegroundColor DarkGray
        }
        catch {
        }
    }
    else {
        try {
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        }
        catch {
        }
    }

    if ($script:TranscriptStarted) {
        try {
            Stop-Transcript | Out-Null
        }
        catch {
        }
    }
}