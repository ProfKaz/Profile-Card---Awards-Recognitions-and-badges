#requires -Version 7.0
<#
.SYNOPSIS
    STEP 1 - Creates the Microsoft Entra App Registration and Service Principal
    required by the Microsoft Learn / Credly -> Microsoft 365 People Profile solution.

.DESCRIPTION
    This script is designed to run AFTER:

        00 - Initialize-MSLearnPeopleConnector.ps1

    Step 0 owns the project structure and creates the centralized configuration:

        Config\MSLearnPeopleConnector.json

    Step 1 therefore DOES NOT recreate that JSON. It loads SchemaVersion 2.2,
    validates the required sections, creates the Entra application objects, and
    updates only the sections owned by this step:

        Application
        Authentication
        MicrosoftGraph.AdminConsentStatus
        ManagementUrls
        LastUpdatedUtc

    All other sections are preserved, including:

        Connector
        Schema
        Provisioning
        CredentialSources
        UserSource
        FieldMapping
        Synchronization
        Output

    Administrator authentication uses a fresh OAuth 2.0 Device Code flow obtained
    directly from Microsoft identity platform. The resulting access token is then
    passed to Microsoft Graph PowerShell. This avoids silently reusing an old
    Microsoft Graph PowerShell/WAM context.

    Microsoft Graph APPLICATION permissions are read from the centralized
    configuration created by Step 0. With the current schema they are:

        ExternalConnection.ReadWrite.OwnedBy
        ExternalItem.ReadWrite.All
        PeopleSettings.ReadWrite.All

    The administrator session used only to bootstrap the application requests:

        Application.ReadWrite.All
        AppRoleAssignment.ReadWrite.All

.SECURITY
    The current PoC stores Authentication.ClientSecret in clear text because the
    later steps consume that value. Protect the Config directory appropriately.
    For production, migrate to certificate authentication, Key Vault, Managed
    Identity, or another protected secret mechanism.

.EXAMPLE
    .\01 - Create-MSLearnPeopleConnectorApp.ps1

.EXAMPLE
    & '.\01 - Create-MSLearnPeopleConnectorApp.ps1' `
        -TargetTenantId 'contoso.onmicrosoft.com'

.EXAMPLE
    & '.\01 - Create-MSLearnPeopleConnectorApp.ps1' `
        -DisplayName 'Contoso Credential Profile Connector' `
        -SecretValidityMonths 6

.NOTES
    Recommended project location:
        C:\MyDev\MSLearn

    Recommended sequence:
        Step 0 -> Local structure/configuration/prerequisites
        Step 1 -> App Registration + Service Principal
        Step 2 -> People Data Connector + schema + profile source
        Step 3 -> Microsoft Learn + Credly synchronization
#>

[CmdletBinding()]
param(
    # Optional override. If omitted, Application.DisplayName from the Step 0
    # configuration is used.
    [Parameter()]
    [string]$DisplayName,

    [Parameter()]
    [ValidateRange(1,24)]
    [int]$SecretValidityMonths = 12,

    # Optional override. Defaults to <script folder>\Config.
    [Parameter()]
    [string]$ConfigDirectory,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigFileName = 'MSLearnPeopleConnector.json',

    # Optional tenant ID or verified tenant domain used as the Device Code authority.
    # If omitted and Application.TenantId is still blank, the operator is prompted.
    [Parameter()]
    [string]$TargetTenantId,

    # Allows creation when another application with the same display name exists.
    [Parameter()]
    [switch]$AllowDuplicateAppName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

$GraphPowerShellClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'

$BootstrapScopes = @(
    'Application.ReadWrite.All'
    'AppRoleAssignment.ReadWrite.All'
)

$script:GraphSessionEstablished = $false
$script:TranscriptStarted = $false

# -----------------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($ConfigDirectory)) {
    $ConfigDirectory = Join-Path -Path $PSScriptRoot -ChildPath 'Config'
}

$ConfigDirectory = [System.IO.Path]::GetFullPath($ConfigDirectory)
$ConfigPath = Join-Path -Path $ConfigDirectory -ChildPath $ConfigFileName

# -----------------------------------------------------------------------------
# Console helpers
# -----------------------------------------------------------------------------

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

# -----------------------------------------------------------------------------
# Generic object/config helpers
# -----------------------------------------------------------------------------

function Get-RequiredProperty {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Context
    )

    if ($null -eq $Object) {
        throw "Configuration object '$Context' is null."
    }

    $property = $Object.PSObject.Properties[$Name]

    if ($null -eq $property) {
        throw "Configuration property '$Context.$Name' is missing."
    }

    return $property.Value
}

function Set-ObjectProperty {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        $Value
    )

    $property = $Object.PSObject.Properties[$Name]

    if ($null -eq $property) {
        Add-Member -InputObject $Object -MemberType NoteProperty -Name $Name -Value $Value
    }
    else {
        $property.Value = $Value
    }
}

function Get-OptionalPropertyValue {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]

    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Save-JsonAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Object
    )

    $parent = Split-Path -Parent $Path

    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "Configuration directory does not exist: $parent. Run Step 0 first."
    }

    $tempPath = "$Path.tmp"

    try {
        $Object |
            ConvertTo-Json -Depth 30 |
            Set-Content -LiteralPath $tempPath -Encoding utf8

        # Verify that the temporary file is valid JSON before replacing the live file.
        Get-Content -LiteralPath $tempPath -Raw |
            ConvertFrom-Json -ErrorAction Stop |
            Out-Null

        Move-Item -LiteralPath $tempPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Import-Step0Configuration {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw @"
Centralized configuration was not found:

    $Path

Run Step 0 first. Step 1 no longer creates a new configuration file because
doing so would overwrite the connector/source/synchronization settings owned by
Step 0.
"@
    }

    try {
        $config = Get-Content -LiteralPath $Path -Raw |
            ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Unable to parse centralized configuration '$Path'. $($_.Exception.Message)"
    }

    $schemaVersion = [string](Get-RequiredProperty `
        -Object $config `
        -Name 'SchemaVersion' `
        -Context 'root')

    if ($schemaVersion -ne '2.2') {
        throw @"
Unsupported centralized configuration SchemaVersion '$schemaVersion'.

Step 1 expects SchemaVersion 2.2 generated by Step 0.
Do not allow Step 1 to downgrade or recreate this configuration.
"@
    }

    # Validate the sections Step 1 owns or consumes.
    $application     = Get-RequiredProperty -Object $config -Name 'Application'     -Context 'root'
    $authentication  = Get-RequiredProperty -Object $config -Name 'Authentication'  -Context 'root'
    $microsoftGraph  = Get-RequiredProperty -Object $config -Name 'MicrosoftGraph'  -Context 'root'
    $managementUrls  = Get-RequiredProperty -Object $config -Name 'ManagementUrls'  -Context 'root'
    $output           = Get-RequiredProperty -Object $config -Name 'Output'          -Context 'root'

    # Validate the Step 0 sections that must survive Step 1.
    $null = Get-RequiredProperty -Object $config -Name 'Connector'          -Context 'root'
    $null = Get-RequiredProperty -Object $config -Name 'Schema'             -Context 'root'
    $null = Get-RequiredProperty -Object $config -Name 'Provisioning'       -Context 'root'
    $null = Get-RequiredProperty -Object $config -Name 'CredentialSources'  -Context 'root'
    $null = Get-RequiredProperty -Object $config -Name 'UserSource'         -Context 'root'
    $null = Get-RequiredProperty -Object $config -Name 'FieldMapping'       -Context 'root'
    $null = Get-RequiredProperty -Object $config -Name 'Synchronization'    -Context 'root'

    # Validate the specific Graph settings required for application creation.
    $resourceAppId = [string](Get-RequiredProperty `
        -Object $microsoftGraph `
        -Name 'ResourceAppId' `
        -Context 'MicrosoftGraph')

    $applicationPermissions = @(
        Get-RequiredProperty `
            -Object $microsoftGraph `
            -Name 'ApplicationPermissions' `
            -Context 'MicrosoftGraph'
    )

    if ([string]::IsNullOrWhiteSpace($resourceAppId)) {
        throw 'MicrosoftGraph.ResourceAppId is empty.'
    }

    if ($applicationPermissions.Count -eq 0) {
        throw 'MicrosoftGraph.ApplicationPermissions is empty.'
    }

    foreach ($permission in $applicationPermissions) {
        if ([string]::IsNullOrWhiteSpace([string]$permission)) {
            throw 'MicrosoftGraph.ApplicationPermissions contains an empty value.'
        }
    }

    return [PSCustomObject]@{
        Config                 = $config
        Application            = $application
        Authentication         = $authentication
        MicrosoftGraph         = $microsoftGraph
        ManagementUrls         = $managementUrls
        Output                 = $output
        ResourceAppId          = $resourceAppId
        ApplicationPermissions = [string[]]$applicationPermissions
    }
}

function Update-CentralizedConfiguration {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ApplicationName,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$AppId,
        [Parameter(Mandatory)][string]$AppObjectId,
        [Parameter(Mandatory)][string]$ServicePrincipalId,
        [Parameter(Mandatory)][string]$ClientSecret,
        [Parameter(Mandatory)][string]$SecretKeyId,
        [Parameter(Mandatory)][datetime]$SecretExpirationUtc,
        [Parameter(Mandatory)][string]$AdminConsentStatus,
        [Parameter(Mandatory)][string]$AppPortalUrl,
        [Parameter(Mandatory)][string]$ApiPermissionsPortalUrl,
        [Parameter(Mandatory)][string]$AdminConsentUrl
    )

    # IMPORTANT:
    # Reload the live configuration every time we update it. This ensures that
    # Step 1 preserves every section/value that Step 0 (or the operator) owns.
    $state = Import-Step0Configuration -Path $Path
    $config = $state.Config

    Set-ObjectProperty -Object $config.Application -Name 'DisplayName'              -Value $ApplicationName
    Set-ObjectProperty -Object $config.Application -Name 'TenantId'                 -Value $TenantId
    Set-ObjectProperty -Object $config.Application -Name 'ClientId'                 -Value $AppId
    Set-ObjectProperty -Object $config.Application -Name 'ApplicationObjectId'       -Value $AppObjectId
    Set-ObjectProperty -Object $config.Application -Name 'ServicePrincipalObjectId'  -Value $ServicePrincipalId

    Set-ObjectProperty -Object $config.Authentication -Name 'ClientSecret'        -Value $ClientSecret
    Set-ObjectProperty -Object $config.Authentication -Name 'SecretKeyId'         -Value $SecretKeyId
    Set-ObjectProperty -Object $config.Authentication -Name 'SecretExpirationUtc' -Value $SecretExpirationUtc.ToString('o')
    Set-ObjectProperty -Object $config.Authentication -Name 'SecretStorage'       -Value 'PlainText'

    Set-ObjectProperty -Object $config.MicrosoftGraph -Name 'AdminConsentStatus' -Value $AdminConsentStatus

    Set-ObjectProperty -Object $config.ManagementUrls -Name 'AppRegistration' -Value $AppPortalUrl
    Set-ObjectProperty -Object $config.ManagementUrls -Name 'ApiPermissions'  -Value $ApiPermissionsPortalUrl
    Set-ObjectProperty -Object $config.ManagementUrls -Name 'AdminConsent'    -Value $AdminConsentUrl

    Set-ObjectProperty `
        -Object $config `
        -Name 'LastUpdatedUtc' `
        -Value ((Get-Date).ToUniversalTime().ToString('o'))

    Save-JsonAtomic -Path $Path -Object $config
}

function Backup-CentralizedConfiguration {
    param([Parameter(Mandatory)][string]$Path)

    $backupPath = '{0}.pre-step1-{1}.bak' -f $Path, (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item -LiteralPath $Path -Destination $backupPath -Force
    return $backupPath
}

# -----------------------------------------------------------------------------
# Module/session helpers
# -----------------------------------------------------------------------------

function Import-RequiredGraphModule {
    param([Parameter(Mandatory)][string]$ModuleName)

    $module = Get-Module -ListAvailable -Name $ModuleName |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if (-not $module) {
        throw @"
Required PowerShell module '$ModuleName' is not installed.

Step 0 is responsible for validating/installing prerequisites.
Run Step 0 again before Step 1.
"@
    }

    Import-Module $ModuleName -ErrorAction Stop
    Write-Success "Module loaded: $ModuleName $($module.Version)"
}

function Clear-GraphConnection {
    [CmdletBinding()]
    param([switch]$Silent)

    $ctx = $null

    try {
        $ctx = Get-MgContext -ErrorAction SilentlyContinue
    }
    catch {
        $ctx = $null
    }

    if ($ctx -and -not $Silent) {
        Write-Host (
            "Closing Microsoft Graph context for '{0}' / tenant '{1}'..." -f
            $ctx.Account,
            $ctx.TenantId
        ) -ForegroundColor DarkGray
    }

    try {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    }
    catch {
        # Cleanup must never stop Step 1.
    }

    $script:GraphSessionEstablished = $false
}

# -----------------------------------------------------------------------------
# OAuth Device Code helpers
# -----------------------------------------------------------------------------

function ConvertFrom-JwtPayload {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Jwt)

    $parts = $Jwt.Split('.')

    if ($parts.Count -lt 2) {
        throw 'The access token is not a valid JWT.'
    }

    $payload = $parts[1].Replace('-', '+').Replace('_', '/')

    switch ($payload.Length % 4) {
        2 { $payload += '==' }
        3 { $payload += '=' }
    }

    $bytes = [Convert]::FromBase64String($payload)
    $json = [Text.Encoding]::UTF8.GetString($bytes)

    return $json | ConvertFrom-Json
}

function Get-FreshGraphDeviceCodeToken {
    [CmdletBinding()]
    param([string]$RequestedTenant)

    $authorityTenant = if ([string]::IsNullOrWhiteSpace($RequestedTenant)) {
        'organizations'
    }
    else {
        $RequestedTenant.Trim()
    }

    $scopeValues = @(
        foreach ($scope in $BootstrapScopes) {
            "https://graph.microsoft.com/$scope"
        }

        'openid'
        'profile'
    )

    $scopeString = $scopeValues -join ' '

    $deviceCodeUri = "https://login.microsoftonline.com/$authorityTenant/oauth2/v2.0/devicecode"
    $tokenUri      = "https://login.microsoftonline.com/$authorityTenant/oauth2/v2.0/token"

    $deviceCodeBody = @{
        client_id = $GraphPowerShellClientId
        scope     = $scopeString
    }

    Write-Host ''
    Write-Host 'Requesting a NEW Device Code from Microsoft identity platform...' -ForegroundColor Cyan

    try {
        $device = Invoke-RestMethod `
            -Method POST `
            -Uri $deviceCodeUri `
            -ContentType 'application/x-www-form-urlencoded' `
            -Body $deviceCodeBody
    }
    catch {
        throw "Unable to obtain a Device Code from tenant authority '$authorityTenant'. $($_.Exception.Message)"
    }

    if (-not $device.device_code -or -not $device.user_code) {
        throw 'Microsoft identity platform did not return a valid Device Code response.'
    }

    $verificationUri = if ($device.verification_uri) {
        $device.verification_uri
    }
    elseif ($device.verification_url) {
        $device.verification_url
    }
    else {
        'https://microsoft.com/devicelogin'
    }

    Write-Host ''
    Write-Host ('=' * 88) -ForegroundColor Yellow
    Write-Host 'NEW ADMINISTRATOR SIGN-IN REQUIRED' -ForegroundColor Yellow
    Write-Host ('=' * 88) -ForegroundColor Yellow
    Write-Host ''
    Write-Host '1. Open this URL in a browser:' -ForegroundColor White
    Write-Host "   $verificationUri" -ForegroundColor Cyan
    Write-Host ''
    Write-Host '2. Enter this Device Code:' -ForegroundColor White
    Write-Host "   $($device.user_code)" -ForegroundColor Green
    Write-Host ''
    Write-Host '3. Sign in with the administrator account for the TARGET tenant.' -ForegroundColor White
    Write-Host ''

    if ($RequestedTenant) {
        Write-Host "Requested tenant/authority: $RequestedTenant" -ForegroundColor DarkGray
    }

    Write-Host 'The script is waiting for authentication...' -ForegroundColor DarkGray
    Write-Host ''

    $interval  = if ($device.interval)   { [int]$device.interval }   else { 5 }
    $expiresIn = if ($device.expires_in) { [int]$device.expires_in } else { 900 }
    $deadline  = (Get-Date).AddSeconds($expiresIn)

    $tokenBody = @{
        grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
        client_id   = $GraphPowerShellClientId
        device_code = $device.device_code
    }

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $interval

        $tokenStatusCode = $null

        try {
            $token = Invoke-RestMethod `
                -Method POST `
                -Uri $tokenUri `
                -ContentType 'application/x-www-form-urlencoded' `
                -Body $tokenBody `
                -SkipHttpErrorCheck `
                -StatusCodeVariable tokenStatusCode
        }
        catch {
            throw "Device Code token endpoint transport failure. $($_.Exception.Message)"
        }

        if (
            $tokenStatusCode -ge 200 -and
            $tokenStatusCode -lt 300 -and
            $token.access_token
        ) {
            Write-Success 'Administrator authentication completed.'
            return $token
        }

        $oauthError = [string]$token.error
        $oauthDescription = [string]$token.error_description

        # Device Code is a polling protocol. authorization_pending is an expected
        # response until the administrator finishes the browser sign-in.
        #
        # IMPORTANT:
        # Do not put the polling 'continue' statements inside a PowerShell switch.
        # In that context, 'continue' applies to switch processing and execution can
        # then fall through to the generic fatal-error block below. Use explicit
        # if/elseif checks so 'continue' targets the surrounding while loop.
        if ($oauthError -eq 'authorization_pending') {
            continue
        }

        if ($oauthError -eq 'slow_down') {
            $interval += 5
            continue
        }

        if ($oauthError -eq 'authorization_declined') {
            throw 'The administrator declined the Device Code authentication request.'
        }

        if ($oauthError -eq 'access_denied') {
            throw "Access was denied during Device Code authentication. $oauthDescription"
        }

        if ($oauthError -eq 'bad_verification_code') {
            throw 'Microsoft identity platform rejected the Device Code. Run Step 1 again and use the newly generated code.'
        }

        if ($oauthError -eq 'expired_token') {
            throw 'The Device Code expired before authentication was completed. Run Step 1 again.'
        }

        if ($tokenStatusCode -eq 429 -or $tokenStatusCode -ge 500) {
            Write-WarnMessage "Transient token endpoint response HTTP $tokenStatusCode. Retrying..."
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace($oauthError)) {
            throw "Device Code authentication failed: $oauthError - $oauthDescription"
        }

        throw "Device Code authentication failed with HTTP $tokenStatusCode and no OAuth error payload."
    }

    throw 'The Device Code expired before authentication was completed. Run Step 1 again.'
}

function Connect-FreshGraphSession {
    [CmdletBinding()]
    param([string]$RequestedTenant)

    while ($true) {
        Clear-GraphConnection -Silent

        $tenantToUse = $RequestedTenant

        if ([string]::IsNullOrWhiteSpace($tenantToUse)) {
            Write-Host ''
            Write-Host 'Enter a Tenant ID or verified tenant domain.' -ForegroundColor DarkGray
            Write-Host 'Example: contoso.onmicrosoft.com or xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' -ForegroundColor DarkGray
            Write-Host "Press ENTER to authenticate against the generic 'organizations' authority." -ForegroundColor DarkGray

            $tenantToUse = Read-Host 'Target Tenant ID or domain'
        }

        Write-Host ''
        Write-Host 'Bootstrap delegated scopes requested for the administrator session:' -ForegroundColor Cyan

        $BootstrapScopes |
            ForEach-Object {
                Write-Host "  - $_"
            }

        $token = Get-FreshGraphDeviceCodeToken -RequestedTenant $tenantToUse
        $claims = ConvertFrom-JwtPayload -Jwt $token.access_token

        # Claims can vary by tenant, account type and token shape. Because the
        # script runs with StrictMode enabled, directly reading a missing optional
        # property (for example $claims.preferred_username) is a terminating error.
        # Read optional claims through PSObject.Properties instead.
        $actualTenantId = [string](
            Get-OptionalPropertyValue -Object $claims -Name 'tid'
        )

        $actualAccount = $null

        foreach ($claimName in @(
            'preferred_username',
            'upn',
            'unique_name',
            'email'
        )) {
            $claimValue = [string](
                Get-OptionalPropertyValue -Object $claims -Name $claimName
            )

            if (-not [string]::IsNullOrWhiteSpace($claimValue)) {
                $actualAccount = $claimValue
                break
            }
        }

        if ([string]::IsNullOrWhiteSpace($actualAccount)) {
            $displayNameClaim = [string](
                Get-OptionalPropertyValue -Object $claims -Name 'name'
            )

            if (-not [string]::IsNullOrWhiteSpace($displayNameClaim)) {
                $actualAccount = $displayNameClaim
            }
            else {
                $actualAccount = '<account identifier not present in token>'
            }
        }

        if ([string]::IsNullOrWhiteSpace($actualTenantId)) {
            throw 'The access token does not contain a tenant ID (tid) claim.'
        }

        $secureAccessToken = ConvertTo-SecureString `
            $token.access_token `
            -AsPlainText `
            -Force

        Connect-MgGraph `
            -AccessToken $secureAccessToken `
            -NoWelcome `
            -ErrorAction Stop

        $script:GraphSessionEstablished = $true

        Write-Host ''
        Write-Host 'Authenticated Microsoft Graph context' -ForegroundColor Cyan
        Write-Host "  Account   : $actualAccount"
        Write-Host "  Tenant ID : $actualTenantId"
        Write-Host (
            '  Authority : {0}' -f
            $(if ([string]::IsNullOrWhiteSpace($tenantToUse)) {
                'organizations'
            }
            else {
                $tenantToUse
            })
        )

        $confirm = Read-Host 'Continue and create the application in THIS tenant? [Y/N]'

        if ($confirm -match '^(Y|YES|S|SI|SÍ)$') {
            return [PSCustomObject]@{
                TenantId = $actualTenantId
                Account  = $actualAccount
                Claims   = $claims
            }
        }

        Write-WarnMessage 'Authentication context rejected. No changes have been made.'
        Clear-GraphConnection

        # Do not silently reuse the rejected tenant on the next attempt.
        $RequestedTenant = $null
    }
}

# -----------------------------------------------------------------------------
# Graph helpers
# -----------------------------------------------------------------------------

function Get-GraphApplicationRole {
    param(
        [Parameter(Mandatory)][object]$GraphServicePrincipal,
        [Parameter(Mandatory)][string]$PermissionName
    )

    $role = $GraphServicePrincipal.AppRoles |
        Where-Object {
            $_.Value -eq $PermissionName -and
            $_.IsEnabled -eq $true -and
            $_.AllowedMemberTypes -contains 'Application'
        } |
        Select-Object -First 1

    if (-not $role) {
        throw "Microsoft Graph application permission '$PermissionName' was not found."
    }

    return $role
}

function Get-AppPortalUrl {
    param([Parameter(Mandatory)][string]$AppId)

    return "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/Overview/appId/$AppId/isMSAApp~/false"
}

function Get-ApiPermissionsPortalUrl {
    param([Parameter(Mandatory)][string]$AppId)

    return "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/CallAnAPI/appId/$AppId/isMSAApp~/false"
}

function Get-AdminConsentUrl {
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$AppId
    )

    return "https://login.microsoftonline.com/$TenantId/adminconsent?client_id=$AppId"
}

function Wait-ServicePrincipal {
    param(
        [Parameter(Mandatory)][string]$AppId,
        [int]$Attempts = 12,
        [int]$DelaySeconds = 5
    )

    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            $servicePrincipal = Get-MgServicePrincipal `
                -Filter "appId eq '$AppId'" `
                -Property 'Id,AppId,DisplayName' `
                -ErrorAction Stop |
                Select-Object -First 1

            if ($servicePrincipal) {
                return $servicePrincipal
            }
        }
        catch {
            # Entra replication can take a few seconds.
        }

        if ($i -lt $Attempts) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    return $null
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

Write-Host ''
Write-Host 'Microsoft Learn / Credly -> Microsoft 365 People Profile' -ForegroundColor White
Write-Host 'STEP 1 - Create Entra App Registration / Service Principal' -ForegroundColor White
Write-Host 'Centralized configuration merge - SchemaVersion 2.2' -ForegroundColor DarkGray

try {
    # -------------------------------------------------------------------------
    # STEP 1.0 - Read Step 0 configuration before touching Graph.
    # -------------------------------------------------------------------------

    Write-Step 'STEP 1.0 - Load and validate Step 0 configuration'

    $configurationState = Import-Step0Configuration -Path $ConfigPath
    $config = $configurationState.Config

    $GraphAppId = $configurationState.ResourceAppId
    [string[]]$RequiredApplicationPermissions =
        $configurationState.ApplicationPermissions

    $configuredDisplayName = [string](
        Get-RequiredProperty `
            -Object $config.Application `
            -Name 'DisplayName' `
            -Context 'Application'
    )

    if ([string]::IsNullOrWhiteSpace($DisplayName)) {
        $DisplayName = $configuredDisplayName
    }

    if ([string]::IsNullOrWhiteSpace($DisplayName)) {
        throw 'Application.DisplayName is empty and -DisplayName was not supplied.'
    }

    $configuredTenantId = [string](
        Get-RequiredProperty `
            -Object $config.Application `
            -Name 'TenantId' `
            -Context 'Application'
    )

    if (
        [string]::IsNullOrWhiteSpace($TargetTenantId) -and
        -not [string]::IsNullOrWhiteSpace($configuredTenantId)
    ) {
        $TargetTenantId = $configuredTenantId
        Write-InfoMessage "Using Application.TenantId from configuration: $TargetTenantId"
    }

    $logsDirectory = [string](
        Get-RequiredProperty `
            -Object $config.Output `
            -Name 'LogsDirectory' `
            -Context 'Output'
    )

    if ([string]::IsNullOrWhiteSpace($logsDirectory)) {
        throw 'Output.LogsDirectory is empty. Run Step 0 again or correct the centralized configuration.'
    }

    if (-not (Test-Path -LiteralPath $logsDirectory -PathType Container)) {
        throw "Configured Logs directory does not exist: $logsDirectory. Run Step 0 first."
    }

    $runStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $logPath = Join-Path $logsDirectory "Create-MSLearnPeopleConnectorApp-$runStamp.log"

    try {
        Start-Transcript -Path $logPath -Force | Out-Null
        $script:TranscriptStarted = $true
        Write-Success "Transcript started: $logPath"
    }
    catch {
        Write-WarnMessage "Unable to start transcript: $($_.Exception.Message)"
    }

    Write-Host "Configuration file       : $ConfigPath"
    Write-Host "Schema version           : $($config.SchemaVersion)"
    Write-Host "Application display name : $DisplayName"
    Write-Host "Graph resource App ID    : $GraphAppId"
    Write-Host 'Graph application permissions:'
    $RequiredApplicationPermissions |
        ForEach-Object {
            Write-Host "  - $_"
        }

    Write-Success 'Step 0 configuration is compatible with Step 1.'

    # Create a recoverable snapshot before the first Step 1 mutation.
    $configBackupPath = Backup-CentralizedConfiguration -Path $ConfigPath
    Write-Success "Pre-Step-1 configuration backup: $configBackupPath"

    # -------------------------------------------------------------------------
    # STEP 1.1 - Modules
    # -------------------------------------------------------------------------

    Write-Step 'STEP 1.1 - Validate Microsoft Graph PowerShell modules'

    Import-RequiredGraphModule -ModuleName 'Microsoft.Graph.Authentication'
    Import-RequiredGraphModule -ModuleName 'Microsoft.Graph.Applications'

    # -------------------------------------------------------------------------
    # STEP 1.2 - Clear Graph context
    # -------------------------------------------------------------------------

    Write-Step 'STEP 1.2 - Close existing Microsoft Graph context'

    $existingContext = $null

    try {
        $existingContext = Get-MgContext -ErrorAction SilentlyContinue
    }
    catch {
        $existingContext = $null
    }

    if ($existingContext) {
        Write-WarnMessage (
            "An existing Graph context was detected: {0} / {1}" -f
            $existingContext.Account,
            $existingContext.TenantId
        )
    }
    else {
        Write-InfoMessage 'No active Microsoft Graph context was detected.'
    }

    Clear-GraphConnection
    Write-Success 'Any active Microsoft Graph context has been closed.'

    # -------------------------------------------------------------------------
    # STEP 1.3 - Fresh admin auth
    # -------------------------------------------------------------------------

    Write-Step 'STEP 1.3 - Request a NEW administrator authentication'

    $authContext = Connect-FreshGraphSession -RequestedTenant $TargetTenantId

    $TenantId = $authContext.TenantId
    $AdminAccount = $authContext.Account

    Write-Success "Fresh administrator authentication confirmed: $AdminAccount"
    Write-Success "Target Tenant ID: $TenantId"

    # Protect against accidentally authenticating to a different tenant when the
    # configuration already contains a tenant from a previous Step 1 execution.
    if (
        -not [string]::IsNullOrWhiteSpace($configuredTenantId) -and
        $configuredTenantId -ne $TenantId
    ) {
        throw @"
The authenticated tenant does not match Application.TenantId in the centralized
configuration.

Configured tenant : $configuredTenantId
Authenticated      : $TenantId

Use the intended project/configuration or reset the deployment intentionally.
"@
    }

    # -------------------------------------------------------------------------
    # STEP 1.4 - Resolve Graph app roles
    # -------------------------------------------------------------------------

    Write-Step 'STEP 1.4 - Resolve Microsoft Graph application permissions'

    $graphSp = Get-MgServicePrincipal `
        -Filter "appId eq '$GraphAppId'" `
        -Property 'Id,AppId,DisplayName,AppRoles' `
        -ErrorAction Stop |
        Select-Object -First 1

    if (-not $graphSp) {
        throw "The Microsoft Graph Service Principal '$GraphAppId' could not be found in tenant '$TenantId'."
    }

    $resolvedRoles = @()

    foreach ($permissionName in $RequiredApplicationPermissions) {
        $role = Get-GraphApplicationRole `
            -GraphServicePrincipal $graphSp `
            -PermissionName $permissionName

        $resolvedRoles += [PSCustomObject]@{
            Name = $permissionName
            Id   = [Guid]$role.Id
        }

        Write-Success "$permissionName -> $($role.Id)"
    }

    $resourceAccess = @(
        foreach ($role in $resolvedRoles) {
            @{                Id   = $role.Id
                Type = 'Role'
            }
        }
    )

    $requiredResourceAccess = @(
        @{
            ResourceAppId  = $GraphAppId
            ResourceAccess = $resourceAccess
        }
    )

    # -------------------------------------------------------------------------
    # STEP 1.5 - Duplicate check
    # -------------------------------------------------------------------------

    Write-Step 'STEP 1.5 - Check for an existing App Registration'

    if (-not $AllowDuplicateAppName) {
        $escapedDisplayName = $DisplayName.Replace("'", "''")

        $existingApps = @(
            Get-MgApplication `
                -Filter "displayName eq '$escapedDisplayName'" `
                -Property 'Id,AppId,DisplayName' `
                -ErrorAction Stop
        )

        if ($existingApps.Count -gt 0) {
            Write-WarnMessage "An App Registration named '$DisplayName' already exists in tenant '$TenantId'."

            $existingApps |
                Format-Table DisplayName, AppId, Id -AutoSize

            throw @"
No application was created.

If the duplicate is intentional, rerun Step 1 with -AllowDuplicateAppName.
Otherwise, use the existing application intentionally or remove/rename the
conflicting application before retrying.
"@
        }
    }

    Write-Success 'No conflicting App Registration was found.'

    # -------------------------------------------------------------------------
    # STEP 1.6 - Create App Registration
    # -------------------------------------------------------------------------

    Write-Step 'STEP 1.6 - Create App Registration'

    $app = New-MgApplication `
        -DisplayName $DisplayName `
        -SignInAudience 'AzureADMyOrg' `
        -RequiredResourceAccess $requiredResourceAccess `
        -ErrorAction Stop

    if (-not $app -or -not $app.AppId) {
        throw 'The App Registration could not be created.'
    }

    $AppObjectId = [string]$app.Id
    $AppId = [string]$app.AppId

    Write-Success 'Application created.'
    Write-Host "  Display Name          : $DisplayName"
    Write-Host "  Application (Client)  : $AppId"
    Write-Host "  Application Object ID : $AppObjectId"

    # -------------------------------------------------------------------------
    # STEP 1.7 - Create Service Principal
    # -------------------------------------------------------------------------

    Write-Step 'STEP 1.7 - Create Service Principal'

    $servicePrincipal = $null

    try {
        $servicePrincipal = New-MgServicePrincipal `
            -AppId $AppId `
            -ErrorAction Stop
    }
    catch {
        Write-WarnMessage 'Initial Service Principal creation did not complete immediately. Checking Entra replication...'
    }

    if (-not $servicePrincipal) {
        $servicePrincipal = Wait-ServicePrincipal -AppId $AppId
    }

    if (-not $servicePrincipal) {
        Start-Sleep -Seconds 5

        try {
            $servicePrincipal = New-MgServicePrincipal `
                -AppId $AppId `
                -ErrorAction Stop
        }
        catch {
            $servicePrincipal = Wait-ServicePrincipal -AppId $AppId
        }
    }

    if (-not $servicePrincipal) {
        throw "The Service Principal for application '$AppId' could not be created or retrieved."
    }

    $ServicePrincipalId = [string]$servicePrincipal.Id
    Write-Success "Service Principal ready: $ServicePrincipalId"

    # -------------------------------------------------------------------------
    # STEP 1.8 - Create secret + persist immediately
    # -------------------------------------------------------------------------

    Write-Step 'STEP 1.8 - Create Client Secret'

    $secretStart = (Get-Date).ToUniversalTime()
    $secretEnd = $secretStart.AddMonths($SecretValidityMonths)

    $passwordCredential = @{
        DisplayName   = 'MSLearn-People-Connector-Secret'
        StartDateTime = $secretStart
        EndDateTime   = $secretEnd
    }

    $secretResult = Add-MgApplicationPassword `
        -ApplicationId $AppObjectId `
        -PasswordCredential $passwordCredential `
        -ErrorAction Stop

    if (-not $secretResult.SecretText) {
        throw 'The client secret was created but its value was not returned.'
    }

    $ClientSecret = [string]$secretResult.SecretText
    $SecretKeyId = [string]$secretResult.KeyId

    Write-Success 'Client secret created.'
    Write-Host "  Secret expiration UTC : $($secretEnd.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-WarnMessage 'The secret value can only be retrieved at creation time.'

    $AppPortalUrl = Get-AppPortalUrl -AppId $AppId
    $ApiPermissionsPortalUrl = Get-ApiPermissionsPortalUrl -AppId $AppId
    $AdminConsentUrl = Get-AdminConsentUrl -TenantId $TenantId -AppId $AppId

    $AdminConsentStatus = 'Pending operator decision'

    # Store immediately so the newly created secret survives a later consent error.
    Update-CentralizedConfiguration `
        -Path $ConfigPath `
        -ApplicationName $DisplayName `
        -TenantId $TenantId `
        -AppId $AppId `
        -AppObjectId $AppObjectId `
        -ServicePrincipalId $ServicePrincipalId `
        -ClientSecret $ClientSecret `
        -SecretKeyId $SecretKeyId `
        -SecretExpirationUtc $secretEnd `
        -AdminConsentStatus $AdminConsentStatus `
        -AppPortalUrl $AppPortalUrl `
        -ApiPermissionsPortalUrl $ApiPermissionsPortalUrl `
        -AdminConsentUrl $AdminConsentUrl

    Write-Success 'Application/authentication values merged into the centralized configuration.'
    Write-Success 'Step 0 connector/source/synchronization sections were preserved.'

    # -------------------------------------------------------------------------
    # STEP 1.9 - Admin Consent
    # -------------------------------------------------------------------------

    Write-Step 'STEP 1.9 - Admin Consent'

    Write-Host 'The application requests these Microsoft Graph APPLICATION permissions:'

    $RequiredApplicationPermissions |
        ForEach-Object {
            Write-Host "  - $_"
        }

    Write-Host ''
    $consentAnswer = Read-Host 'Grant Admin Consent now? [Y/N]'

    $consentFailures = @()

    if ($consentAnswer -match '^(Y|YES|S|SI|SÍ)$') {
        Write-Host ''
        Write-Host 'Granting Microsoft Graph application permissions...' -ForegroundColor Cyan

        $servicePrincipal = Wait-ServicePrincipal -AppId $AppId

        if (-not $servicePrincipal) {
            throw 'The client Service Principal could not be refreshed before Admin Consent.'
        }

        foreach ($role in $resolvedRoles) {
            try {
                $existingAssignment = @(
                    Get-MgServicePrincipalAppRoleAssignment `
                        -ServicePrincipalId $servicePrincipal.Id `
                        -All `
                        -ErrorAction Stop |
                    Where-Object {
                        $_.ResourceId -eq $graphSp.Id -and
                        $_.AppRoleId -eq $role.Id
                    }
                )

                if ($existingAssignment.Count -gt 0) {
                    Write-Success "$($role.Name) is already granted."
                    continue
                }

                $body = @{
                    PrincipalId = $servicePrincipal.Id
                    ResourceId  = $graphSp.Id
                    AppRoleId   = $role.Id
                }

                New-MgServicePrincipalAppRoleAssignment `
                    -ServicePrincipalId $servicePrincipal.Id `
                    -BodyParameter $body `
                    -ErrorAction Stop |
                    Out-Null

                Write-Success "Granted: $($role.Name)"
            }
            catch {
                $message = $_.Exception.Message
                $consentFailures += "$($role.Name): $message"
                Write-WarnMessage "Could not grant '$($role.Name)': $message"
            }
        }

        if ($consentFailures.Count -eq 0) {
            $AdminConsentStatus = 'Granted automatically'
            Write-Success 'Admin Consent completed for all requested permissions.'
        }
        else {
            $AdminConsentStatus = 'Partially granted or failed - manual review required'
            Write-WarnMessage 'One or more permissions require manual review.'
        }
    }
    else {
        $AdminConsentStatus = 'Not granted automatically'

        Write-WarnMessage 'Admin Consent was not granted automatically.'
        Write-Host ''
        Write-Host 'App Registration:' -ForegroundColor Cyan
        Write-Host $AppPortalUrl -ForegroundColor White
        Write-Host ''
        Write-Host 'API Permissions:' -ForegroundColor Cyan
        Write-Host $ApiPermissionsPortalUrl -ForegroundColor White
        Write-Host ''
        Write-Host 'Tenant-wide Admin Consent URL:' -ForegroundColor Cyan
        Write-Host $AdminConsentUrl -ForegroundColor White
    }

    # Save only the Step 1-owned values again, now with the final consent state.
    Update-CentralizedConfiguration `
        -Path $ConfigPath `
        -ApplicationName $DisplayName `
        -TenantId $TenantId `
        -AppId $AppId `
        -AppObjectId $AppObjectId `
        -ServicePrincipalId $ServicePrincipalId `
        -ClientSecret $ClientSecret `
        -SecretKeyId $SecretKeyId `
        -SecretExpirationUtc $secretEnd `
        -AdminConsentStatus $AdminConsentStatus `
        -AppPortalUrl $AppPortalUrl `
        -ApiPermissionsPortalUrl $ApiPermissionsPortalUrl `
        -AdminConsentUrl $AdminConsentUrl

    # -------------------------------------------------------------------------
    # STEP 1.10 - Validate merge
    # -------------------------------------------------------------------------

    Write-Step 'STEP 1.10 - Validate centralized configuration'

    $finalState = Import-Step0Configuration -Path $ConfigPath
    $finalConfig = $finalState.Config

    if ([string]$finalConfig.Application.ClientId -ne $AppId) {
        throw 'Configuration validation failed: Application.ClientId does not match the created application.'
    }

    if ([string]$finalConfig.Application.ServicePrincipalObjectId -ne $ServicePrincipalId) {
        throw 'Configuration validation failed: Application.ServicePrincipalObjectId does not match the created Service Principal.'
    }

    if ([string]$finalConfig.Authentication.SecretKeyId -ne $SecretKeyId) {
        throw 'Configuration validation failed: Authentication.SecretKeyId does not match the created secret.'
    }

    # Presence of these objects confirms that Step 1 did not collapse the Step 0 JSON.
    foreach ($preservedSection in @(
        'Connector',
        'Schema',
        'Provisioning',
        'CredentialSources',
        'UserSource',
        'FieldMapping',
        'Synchronization',
        'Output'
    )) {
        $null = Get-RequiredProperty `
            -Object $finalConfig `
            -Name $preservedSection `
            -Context 'root'
    }

    Write-Success 'Centralized configuration merge validated.'
    Write-Success 'All Step 0 sections required by Steps 2 and 3 remain present.'

    # -------------------------------------------------------------------------
    # RESULT
    # -------------------------------------------------------------------------

    Write-Step 'RESULT'

    Write-Host "Application Name        : $DisplayName"
    Write-Host "Administrator           : $AdminAccount"
    Write-Host "Tenant ID               : $TenantId"
    Write-Host "Application (Client) ID : $AppId"
    Write-Host "Application Object ID   : $AppObjectId"
    Write-Host "Service Principal ID    : $ServicePrincipalId"
    Write-Host "Secret Key ID           : $SecretKeyId"
    Write-Host "Secret Expiration UTC   : $($secretEnd.ToString('o'))"
    Write-Host "Admin Consent           : $AdminConsentStatus"
    Write-Host "Config file             : $ConfigPath"
    Write-Host "Config backup           : $configBackupPath"

    if ($script:TranscriptStarted) {
        Write-Host "Log file                : $logPath"
    }

    Write-Host ''
    Write-WarnMessage 'Authentication.ClientSecret is currently stored in clear text in the centralized JSON.'
    Write-Host 'Next step: run Step 2 to create/validate the People Data Connector and schema.' -ForegroundColor Cyan
}
catch {
    Write-Host ''
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    throw
}
finally {
    Write-Host ''
    Write-Host 'Closing Microsoft Graph session...' -ForegroundColor DarkGray

    Clear-GraphConnection -Silent

    Write-Host 'Microsoft Graph session closed.' -ForegroundColor DarkGray

    if ($script:TranscriptStarted) {
        try {
            Stop-Transcript | Out-Null
        }
        catch {
            # Transcript cleanup must not hide the original result/error.
        }
    }

    Write-Host ''
}