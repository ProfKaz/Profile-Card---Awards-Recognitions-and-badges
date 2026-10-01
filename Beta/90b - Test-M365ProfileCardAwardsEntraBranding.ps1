#requires -Version 7.0
<#
.SYNOPSIS
    Beta validation for the M365 Profile Card Awards Entra application logo.

.DESCRIPTION
    Reads the existing production-style MSLearnPeopleConnector.json file to
    resolve the tenant and application identity, validates the local Entra logo,
    requests the delegated Microsoft Graph permission required to update the
    application, backs up the current application logo when one exists, applies
    the Beta test logo, downloads the stored logo, and validates its SHA-256.

    This script does not modify the configuration, external connection, schema,
    profile source, user items, or Copilot Visibility.

.EXAMPLE
    & '.\90b - Test-M365ProfileCardAwardsEntraBranding.ps1'

.EXAMPLE
    & '.\90b - Test-M365ProfileCardAwardsEntraBranding.ps1' -ValidateOnly

.EXAMPLE
    & '.\90b - Test-M365ProfileCardAwardsEntraBranding.ps1' `
        -ConfigPath 'C:\MyDev\MSLearn\Config\MSLearnPeopleConnector.json' `
        -LogoPath '.\Assets\m365-profile-card-awards-entra-215.png'
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$LogoPath,

    [Parameter()]
    [string]$BackupDirectory,

    [Parameter()]
    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RequiredScope = 'Application.ReadWrite.All'
$ExpectedLogoWidth = 215
$ExpectedLogoHeight = 215
$MaximumLogoBytes = 100KB
$script:GraphConnected = $false

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)

    Write-Host ''
    Write-Host ('=' * 88) -ForegroundColor DarkGray
    Write-Host $Message -ForegroundColor Cyan
    Write-Host ('=' * 88) -ForegroundColor DarkGray
}

function Write-Success {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-InfoMessage {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-WarnMessage {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Test-GraphNotFoundError {
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $StatusCode = $null

    if ($ErrorRecord.Exception.PSObject.Properties['ResponseStatusCode']) {
        $StatusCode = [int]$ErrorRecord.Exception.ResponseStatusCode
    }

    return (
        $StatusCode -eq 404 -or
        $ErrorRecord.Exception.Message -match '(?i)\b404\b|Request_ResourceNotFound|not found'
    )
}

function Resolve-ExistingFile {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string[]]$Candidates
    )

    foreach ($Candidate in $Candidates) {
        if ([string]::IsNullOrWhiteSpace($Candidate)) {
            continue
        }

        try {
            $Resolved = Resolve-Path -LiteralPath $Candidate -ErrorAction Stop
            return [string]$Resolved.Path
        }
        catch {
        }
    }

    throw "$Description was not found. Checked: $($Candidates -join '; ')"
}

function Get-RequiredPropertyValue {
    param(
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Context
    )

    $Property = $Object.PSObject.Properties[$Name]

    if ($null -eq $Property) {
        throw "Configuration property '$Context.$Name' is missing."
    }

    return $Property.Value
}

function Import-RequiredModule {
    param([Parameter(Mandatory)][string]$Name)

    $Module = Get-Module -ListAvailable -Name $Name |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if (-not $Module) {
        throw "Required module '$Name' is not installed. Install it with: Install-Module $Name -Scope CurrentUser"
    }

    Import-Module $Name -ErrorAction Stop
    Write-Success "Module available: $Name $($Module.Version)"
}

function Test-EntraLogoFile {
    param([Parameter(Mandatory)][string]$Path)

    $File = Get-Item -LiteralPath $Path -ErrorAction Stop

    if ($File.Extension -ne '.png') {
        throw "The Entra application logo must be a PNG file. Current extension: '$($File.Extension)'."
    }

    if ($File.Length -gt $MaximumLogoBytes) {
        throw "The Entra application logo is $($File.Length) bytes. Maximum allowed by this validation is $MaximumLogoBytes bytes."
    }

    try {
        Add-Type -AssemblyName System.Drawing.Common -ErrorAction Stop
    }
    catch {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    }

    $Image = $null

    try {
        $Image = [System.Drawing.Image]::FromFile($Path)

        if (
            $Image.Width -ne $ExpectedLogoWidth -or
            $Image.Height -ne $ExpectedLogoHeight
        ) {
            throw (
                "The Entra application logo must be exactly " +
                "$ExpectedLogoWidth x $ExpectedLogoHeight pixels. " +
                "Current dimensions: $($Image.Width) x $($Image.Height)."
            )
        }

        if ([System.Drawing.Image]::IsAlphaPixelFormat($Image.PixelFormat)) {
            throw 'The Entra application logo contains an alpha channel. Use a solid, opaque background.'
        }

        return [PSCustomObject]@{
            Path       = $File.FullName
            Width      = $Image.Width
            Height     = $Image.Height
            Length     = $File.Length
            PixelFormat = [string]$Image.PixelFormat
            Sha256     = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash
        }
    }
    finally {
        if ($Image) {
            $Image.Dispose()
        }
    }
}

function Resolve-ConfiguredApplication {
    param(
        [Parameter(Mandatory)][object]$ApplicationConfiguration
    )

    $ConfiguredObjectId = [string](
        Get-RequiredPropertyValue `
            -Object $ApplicationConfiguration `
            -Name 'ApplicationObjectId' `
            -Context 'Application'
    )

    $ConfiguredClientId = [string](
        Get-RequiredPropertyValue `
            -Object $ApplicationConfiguration `
            -Name 'ClientId' `
            -Context 'Application'
    )

    if (-not [string]::IsNullOrWhiteSpace($ConfiguredObjectId)) {
        $Application = Get-MgApplication `
            -ApplicationId $ConfiguredObjectId `
            -Property 'Id,AppId,DisplayName' `
            -ErrorAction Stop

        if (
            -not [string]::IsNullOrWhiteSpace($ConfiguredClientId) -and
            [string]$Application.AppId -ne $ConfiguredClientId
        ) {
            throw (
                "The configured ApplicationObjectId resolves to AppId '$($Application.AppId)', " +
                "which does not match configured ClientId '$ConfiguredClientId'."
            )
        }

        return $Application
    }

    if ([string]::IsNullOrWhiteSpace($ConfiguredClientId)) {
        throw 'Application.ApplicationObjectId and Application.ClientId are both empty.'
    }

    $Application = Get-MgApplication `
        -Filter "appId eq '$ConfiguredClientId'" `
        -Property 'Id,AppId,DisplayName' `
        -ErrorAction Stop |
        Select-Object -First 1

    if (-not $Application) {
        throw "No App Registration was found for configured ClientId '$ConfiguredClientId'."
    }

    return $Application
}

Write-Host ''
Write-Host 'M365 Profile Card Awards' -ForegroundColor White
Write-Host 'STEP 90b - Beta Entra application branding validation' -ForegroundColor White

try {
    Write-Step 'STEP 1 - Resolve configuration and branding asset'

    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Resolve-ExistingFile `
            -Description 'MSLearnPeopleConnector.json' `
            -Candidates @(
                (Join-Path (Split-Path $PSScriptRoot -Parent) 'Config\MSLearnPeopleConnector.json'),
                (Join-Path $PSScriptRoot 'Config\MSLearnPeopleConnector.json'),
                (Join-Path (Get-Location) 'Config\MSLearnPeopleConnector.json')
            )
    }
    else {
        $ConfigPath = Resolve-ExistingFile `
            -Description 'MSLearnPeopleConnector.json' `
            -Candidates @($ConfigPath)
    }

    if ([string]::IsNullOrWhiteSpace($LogoPath)) {
        $LogoPath = Resolve-ExistingFile `
            -Description 'Beta Entra branding logo' `
            -Candidates @(
                (Join-Path $PSScriptRoot 'Assets\m365-profile-card-awards-entra-215.png')
            )
    }
    else {
        $LogoPath = Resolve-ExistingFile `
            -Description 'Entra branding logo' `
            -Candidates @($LogoPath)
    }

    $Configuration = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 |
        ConvertFrom-Json -Depth 50

    $ApplicationConfiguration = Get-RequiredPropertyValue `
        -Object $Configuration `
        -Name 'Application' `
        -Context 'root'

    $TenantId = [string](
        Get-RequiredPropertyValue `
            -Object $ApplicationConfiguration `
            -Name 'TenantId' `
            -Context 'Application'
    )

    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        throw 'Application.TenantId is empty in the configuration.'
    }

    if ([string]::IsNullOrWhiteSpace($BackupDirectory)) {
        $ConfiguredReportsDirectory = $null

        if ($Configuration.PSObject.Properties['Output']) {
            $ConfiguredReportsDirectory = [string]$Configuration.Output.ReportsDirectory
        }

        if (-not [string]::IsNullOrWhiteSpace($ConfiguredReportsDirectory)) {
            $BackupDirectory = Join-Path $ConfiguredReportsDirectory 'Branding'
        }
        else {
            $BackupDirectory = Join-Path (Split-Path $ConfigPath -Parent) '..\Reports\Branding'
        }
    }

    $BackupDirectory = [System.IO.Path]::GetFullPath($BackupDirectory)
    New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null

    $LogoValidation = Test-EntraLogoFile -Path $LogoPath

    Write-Host "Configuration : $ConfigPath"
    Write-Host "Tenant ID     : $TenantId"
    Write-Host "Logo          : $($LogoValidation.Path)"
    Write-Host "Dimensions    : $($LogoValidation.Width) x $($LogoValidation.Height)"
    Write-Host "Opaque PNG    : Yes"
    Write-Host "File size     : $($LogoValidation.Length) bytes"
    Write-Host "SHA-256       : $($LogoValidation.Sha256)"
    Write-Success 'The local Entra logo satisfies the Beta validation contract.'

    Write-Step 'STEP 2 - Validate Microsoft Graph modules and delegated permission'

    Import-RequiredModule -Name 'Microsoft.Graph.Authentication'
    Import-RequiredModule -Name 'Microsoft.Graph.Applications'

    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null

    Connect-MgGraph `
        -TenantId $TenantId `
        -Scopes $RequiredScope `
        -UseDeviceCode `
        -ContextScope Process `
        -NoWelcome `
        -ErrorAction Stop

    $script:GraphConnected = $true
    $Context = Get-MgContext -ErrorAction Stop

    if ($Context.TenantId -ne $TenantId) {
        throw "Authenticated tenant '$($Context.TenantId)' does not match configured tenant '$TenantId'."
    }

    if (@($Context.Scopes) -notcontains $RequiredScope) {
        throw "The Graph session does not contain required delegated scope '$RequiredScope'."
    }

    Write-Success "Delegated Graph scope confirmed: $RequiredScope"
    Write-Success "Authenticated tenant confirmed: $TenantId"

    Write-Step 'STEP 3 - Resolve configured App Registration'

    $Application = Resolve-ConfiguredApplication `
        -ApplicationConfiguration $ApplicationConfiguration

    Write-Host "Application name      : $($Application.DisplayName)"
    Write-Host "Application object ID : $($Application.Id)"
    Write-Host "Application client ID : $($Application.AppId)"
    Write-Success 'The configured App Registration was resolved successfully.'

    if ($ValidateOnly) {
        Write-Step 'RESULT'
        Write-Success 'Validation completed. The logo was not changed because -ValidateOnly was specified.'
        return
    }

    Write-Step 'STEP 4 - Back up current application logo'

    $Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $PreviousLogoPath = Join-Path `
        $BackupDirectory `
        "ApplicationLogo-before-$Timestamp.png"

    $PreviousLogoBackedUp = $false

    try {
        Get-MgApplicationLogo `
            -ApplicationId ([string]$Application.Id) `
            -OutFile $PreviousLogoPath `
            -ErrorAction Stop

        if ((Test-Path -LiteralPath $PreviousLogoPath) -and (Get-Item $PreviousLogoPath).Length -gt 0) {
            $PreviousLogoBackedUp = $true
            Write-Success "Existing application logo backed up: $PreviousLogoPath"
        }
    }
    catch {
        if (-not (Test-GraphNotFoundError -ErrorRecord $_)) {
            throw (
                'The current logo could not be read. This may indicate missing permission or a Graph error. ' +
                $_.Exception.Message
            )
        }

        Write-InfoMessage 'No existing application logo was returned; no backup file was created.'

        if (Test-Path -LiteralPath $PreviousLogoPath) {
            Remove-Item -LiteralPath $PreviousLogoPath -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Step 'STEP 5 - Apply and verify Beta branding logo'

    if ($PSCmdlet.ShouldProcess(
        "$($Application.DisplayName) [$($Application.Id)]",
        "Set application logo from '$LogoPath'"
    )) {
        Set-MgApplicationLogo `
            -ApplicationId ([string]$Application.Id) `
            -InFile $LogoPath `
            -ContentType 'image/png' `
            -Confirm:$false `
            -ErrorAction Stop |
            Out-Null

        Write-Success 'Microsoft Graph accepted the application logo update.'

        $VerificationPath = Join-Path `
            $BackupDirectory `
            "ApplicationLogo-verified-$Timestamp.png"

        Get-MgApplicationLogo `
            -ApplicationId ([string]$Application.Id) `
            -OutFile $VerificationPath `
            -ErrorAction Stop

        if (-not (Test-Path -LiteralPath $VerificationPath)) {
            throw 'Graph did not return a verification logo file after the update.'
        }

        $RetrievedHash = (
            Get-FileHash -LiteralPath $VerificationPath -Algorithm SHA256
        ).Hash

        $HashMatch = $RetrievedHash -eq $LogoValidation.Sha256

        Write-Host "Submitted SHA-256 : $($LogoValidation.Sha256)"
        Write-Host "Retrieved SHA-256 : $RetrievedHash"
        Write-Host "Verification file : $VerificationPath"

        if (-not $HashMatch) {
            throw (
                'The application logo was returned by Graph, but its SHA-256 does not match ' +
                'the submitted file. Preserve the backup and inspect the returned image.'
            )
        }

        Write-Success 'Downloaded application logo matches the submitted image exactly.'

        Write-Step 'RESULT'
        Write-Success 'Beta Entra branding validation completed successfully.'
        Write-Host "Previous logo backup : $(if ($PreviousLogoBackedUp) { $PreviousLogoPath } else { 'Not available' })"
        Write-Host "Applied logo         : $LogoPath"
        Write-Host "Verification logo    : $VerificationPath"

        if ($PreviousLogoBackedUp) {
            Write-Host ''
            Write-Host 'Restore command:' -ForegroundColor Cyan
            Write-Host (
                "Set-MgApplicationLogo -ApplicationId '$($Application.Id)' " +
                "-InFile '$PreviousLogoPath' -ContentType 'image/png'"
            )
        }
    }
    else {
        Write-Step 'RESULT'
        Write-WarnMessage 'The branding update was skipped by ShouldProcess/WhatIf.'
    }
}
catch {
    Write-Host ''
    Write-Host 'SCRIPT FAILED' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red

    if ($_.InvocationInfo) {
        Write-Host ''
        Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor Yellow
    }

    throw
}
finally {
    if ($script:GraphConnected) {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        Write-Host 'Microsoft Graph session closed.' -ForegroundColor DarkGray
    }
}
