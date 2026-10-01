#requires -Version 7.0
<#
.SYNOPSIS
    Beta validation for the M365 Profile Card Awards Entra application logo.

.DESCRIPTION
    Reads the existing production-style MSLearnPeopleConnector.json file to
    resolve the tenant and application identity, resolves the Entra logo locally
    or downloads the published asset to a temporary file, and requests the
    delegated Microsoft Graph permission required to update the
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
$DefaultLogoUri = (
    'https://raw.githubusercontent.com/ProfKaz/' +
    'Profile-Card---Awards-Recognitions-and-badges/' +
    'main/Beta/Assets/m365-profile-card-awards-entra-215.png'
)
$ExpectedDefaultLogoSha256 = 'FFC0AE7B77B0E4907CC14F57E195D907DEBF77F8CCFA156B84DDA1E03BE57710'
$script:GraphConnected = $false
$TemporaryLogoPath = $null

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
            -Property 'Id,AppId,DisplayName,Info' `
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
        -Property 'Id,AppId,DisplayName,Info' `
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

    $LogoDownloadedFromWeb = $false

    if ([string]::IsNullOrWhiteSpace($LogoPath)) {
        $LocalLogoPath = Join-Path `
            $PSScriptRoot `
            'Assets\m365-profile-card-awards-entra-215.png'

        if (Test-Path -LiteralPath $LocalLogoPath -PathType Leaf) {
            $LogoPath = [string](Resolve-Path -LiteralPath $LocalLogoPath).Path
            Write-InfoMessage "Using local branding asset: $LogoPath"
        }
        else {
            $TemporaryLogoPath = Join-Path `
                ([System.IO.Path]::GetTempPath()) `
                "m365-profile-card-awards-entra-$([guid]::NewGuid().ToString('N')).png"

            Write-InfoMessage 'The branding asset is not available locally.'
            Write-InfoMessage "Downloading published branding asset: $DefaultLogoUri"

            try {
                Invoke-WebRequest `
                    -Uri $DefaultLogoUri `
                    -OutFile $TemporaryLogoPath `
                    -MaximumRedirection 5 `
                    -ErrorAction Stop
            }
            catch {
                if (Test-Path -LiteralPath $TemporaryLogoPath) {
                    Remove-Item -LiteralPath $TemporaryLogoPath -Force -ErrorAction SilentlyContinue
                }

                throw (
                    'The Beta Entra branding logo was not found locally and could not be ' +
                    "downloaded from '$DefaultLogoUri'. $($_.Exception.Message)"
                )
            }

            $LogoPath = $TemporaryLogoPath
            $LogoDownloadedFromWeb = $true
        }
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

    if (
        $LogoDownloadedFromWeb -and
        $LogoValidation.Sha256 -ne $ExpectedDefaultLogoSha256
    ) {
        throw (
            'The downloaded branding asset failed the integrity check. ' +
            "Expected SHA-256: $ExpectedDefaultLogoSha256. " +
            "Downloaded SHA-256: $($LogoValidation.Sha256)."
        )
    }

    Write-Host "Configuration : $ConfigPath"
    Write-Host "Tenant ID     : $TenantId"
    Write-Host "Logo          : $($LogoValidation.Path)"
    Write-Host "Dimensions    : $($LogoValidation.Width) x $($LogoValidation.Height)"
    Write-Host "Opaque PNG    : Yes"
    Write-Host "File size     : $($LogoValidation.Length) bytes"
    Write-Host "SHA-256       : $($LogoValidation.Sha256)"
    if ($LogoDownloadedFromWeb) {
        Write-Success 'The downloaded Entra logo passed format and integrity validation.'
    }
    else {
        Write-Success 'The local Entra logo satisfies the Beta validation contract.'
    }

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
    $CurrentLogoUrl = [string]$Application.Info.LogoUrl

    if ([string]::IsNullOrWhiteSpace($CurrentLogoUrl)) {
        Write-InfoMessage 'The application does not currently expose a logoUrl; no backup file was created.'
    }
    else {
        try {
            Invoke-WebRequest `
                -Uri $CurrentLogoUrl `
                -OutFile $PreviousLogoPath `
                -Headers @{ 'Cache-Control' = 'no-cache' } `
                -MaximumRedirection 5 `
                -ErrorAction Stop

            if (
                -not (Test-Path -LiteralPath $PreviousLogoPath) -or
                (Get-Item -LiteralPath $PreviousLogoPath).Length -eq 0
            ) {
                throw 'The logoUrl request returned an empty backup file.'
            }

            $PreviousLogoBackedUp = $true
            Write-Success "Existing application logo backed up from logoUrl: $PreviousLogoPath"
        }
        catch {
            if (Test-Path -LiteralPath $PreviousLogoPath) {
                Remove-Item -LiteralPath $PreviousLogoPath -Force -ErrorAction SilentlyContinue
            }

            throw (
                'The current application logoUrl was found, but its content could not be backed up. ' +
                $_.Exception.Message
            )
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

        $VerificationSucceeded = $false
        $RetrievedHash = $null
        $VerificationLogoUrl = $null
        $VerificationAttempts = 6

        for ($Attempt = 1; $Attempt -le $VerificationAttempts; $Attempt++) {
            if ($Attempt -gt 1) {
                Write-InfoMessage (
                    "Waiting for logoUrl/CDN propagation before verification " +
                    "attempt $Attempt of $VerificationAttempts..."
                )
                Start-Sleep -Seconds 5
            }

            $VerificationApplication = Get-MgApplication `
                -ApplicationId ([string]$Application.Id) `
                -Property 'Id,Info' `
                -ErrorAction Stop

            $VerificationLogoUrl = [string]$VerificationApplication.Info.LogoUrl

            if ([string]::IsNullOrWhiteSpace($VerificationLogoUrl)) {
                continue
            }

            if (Test-Path -LiteralPath $VerificationPath) {
                Remove-Item -LiteralPath $VerificationPath -Force
            }

            try {
                Invoke-WebRequest `
                    -Uri $VerificationLogoUrl `
                    -OutFile $VerificationPath `
                    -Headers @{ 'Cache-Control' = 'no-cache' } `
                    -MaximumRedirection 5 `
                    -ErrorAction Stop
            }
            catch {
                Write-WarnMessage (
                    "Verification attempt $Attempt could not download logoUrl: " +
                    $_.Exception.Message
                )
                continue
            }

            if (
                -not (Test-Path -LiteralPath $VerificationPath) -or
                (Get-Item -LiteralPath $VerificationPath).Length -eq 0
            ) {
                continue
            }

            $RetrievedHash = (
                Get-FileHash -LiteralPath $VerificationPath -Algorithm SHA256
            ).Hash

            if ($RetrievedHash -eq $LogoValidation.Sha256) {
                $VerificationSucceeded = $true
                break
            }
        }

        Write-Host "Submitted SHA-256 : $($LogoValidation.Sha256)"
        Write-Host "Retrieved SHA-256 : $(if ($RetrievedHash) { $RetrievedHash } else { 'Not available' })"
        Write-Host "Verification URL  : $(if ($VerificationLogoUrl) { $VerificationLogoUrl } else { 'Not available' })"
        Write-Host "Verification file : $VerificationPath"

        if (-not $VerificationSucceeded) {
            throw (
                "The application logo did not match the submitted image after " +
                "$VerificationAttempts logoUrl/CDN verification attempts. " +
                'Preserve the previous-logo backup and inspect the URL and downloaded file.'
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

    if (
        -not [string]::IsNullOrWhiteSpace($TemporaryLogoPath) -and
        (Test-Path -LiteralPath $TemporaryLogoPath)
    ) {
        Remove-Item -LiteralPath $TemporaryLogoPath -Force -ErrorAction SilentlyContinue
        Write-Host 'Temporary branding asset removed.' -ForegroundColor DarkGray
    }
}
