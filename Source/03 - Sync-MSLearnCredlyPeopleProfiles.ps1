#requires -Version 7.0
<#
.SYNOPSIS
    Step 3 - Synchronizes Microsoft Learn certifications and Credly badges into
    the existing Microsoft 365 People Data Connector using centralized JSON configuration.

.DESCRIPTION
    This script reads all environment and runtime configuration from:

        .\Config\MSLearnPeopleConnector.json

    unless -ConfigPath is specified.

    It does NOT hardcode:
      - TenantId
      - ClientId
      - ClientSecret
      - ConnectionId
      - connector property names
      - Microsoft Learn endpoints
      - Credly endpoints
      - Credly rolling window
      - CSV / JSON input paths
      - SharePoint Online site/list identifiers
      - source field names
      - synchronization behavior
      - output directories

    Supported user sources:
      - CSV
      - JSON
      - SharePoint Online list through Microsoft Graph

    Synchronization behavior:
      Microsoft Learn
        -> active certifications
      Credly
        -> public/accepted badges within configured rolling window
      Then
        -> deduplicate Credly against Learn when configured
        -> read current externalItem
        -> merge locally
        -> preserve or remove unmanaged credentials according to configuration
        -> remove or preserve stale managed credentials according to configuration
        -> PUT the complete property bag
        -> read back and validate

    The script preserves the merge behavior validated in
    Sync-MSLearnCredlyPeopleProfiles-v1.ps1 while externalizing configuration.

.CONFIGURATION
    Expected SchemaVersion: 2.2 or later.

    Default path:
      .\Config\MSLearnPeopleConnector.json

.NOTES
    Microsoft Learn profile/transcript endpoints and Credly badges.json are public
    web endpoints used by this implementation. They should be monitored for changes.

    ClientSecret is intentionally read as plain text while the current validation
    phase uses Authentication.SecretStorage = PlainText.
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
# Technical dependencies only.
# Environment/runtime values are loaded from JSON.
# ---------------------------------------------------------------------------

$RequiredModules = @(
    "Microsoft.Graph.Authentication"
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
$script:ReportPath = $null

# ---------------------------------------------------------------------------
# Console helpers
# ---------------------------------------------------------------------------

function Write-Step {
    param([Parameter(Mandatory)][string]$Text)

    Write-Host ""
    Write-Host ("=" * 88) -ForegroundColor DarkGray
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ("=" * 88) -ForegroundColor DarkGray
}

function Write-Success {
    param([Parameter(Mandatory)][string]$Text)

    Write-Host "[OK] $Text" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Configuration helpers
# ---------------------------------------------------------------------------

function Get-RequiredPropertyValue {
    param(
        [Parameter(Mandatory)]
        $Object,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Path,

        [switch]$AllowEmpty
    )

    if ($null -eq $Object) {
        throw "Configuration object '$Path' is missing."
    }

    $Property = $Object.PSObject.Properties[$Name]

    if ($null -eq $Property) {
        throw "Configuration value '$Path.$Name' is missing."
    }

    if (-not $AllowEmpty) {

        if ($null -eq $Property.Value) {
            throw "Configuration value '$Path.$Name' is null."
        }

        if (
            $Property.Value -is [string] -and
            [string]::IsNullOrWhiteSpace([string]$Property.Value)
        ) {
            throw "Configuration value '$Path.$Name' is empty."
        }
    }

    return $Property.Value
}

function Get-OptionalPropertyValue {
    param(
        [Parameter(Mandatory)]
        $Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $Property = $Object.PSObject.Properties[$Name]

    if ($null -eq $Property) {
        return $null
    }

    return $Property.Value
}

function Resolve-ConfiguredPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateSet("ScriptRoot","ConfigRoot","CurrentDirectory")]
        [string]$Resolution
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    switch ($Resolution) {

        "ScriptRoot" {
            $BaseDirectory = $ScriptDirectory
        }

        "ConfigRoot" {
            $BaseDirectory = Split-Path -Parent $ConfigPath
        }

        "CurrentDirectory" {
            $BaseDirectory = (Get-Location).Path
        }
    }

    return [System.IO.Path]::GetFullPath(
        (Join-Path $BaseDirectory $Path)
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

# ---------------------------------------------------------------------------
# User source helpers
# ---------------------------------------------------------------------------

function Test-EnabledValue {
    param($Value)

    if ($null -eq $Value) {
        return $true
    }

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    $Text = ([string]$Value).Trim()

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $true
    }

    return ($Text -match '^(1|true|yes|y|si|sí)$')
}

function Get-MappedSourceValue {
    param(
        [Parameter(Mandatory)]
        $SourceObject,

        [Parameter(Mandatory)]
        [string]$LogicalName
    )

    $MappingProperty =
        $script:FieldMapping.PSObject.Properties[$LogicalName]

    if ($null -eq $MappingProperty) {
        throw "UserSource.FieldMapping.$LogicalName is missing."
    }

    $PhysicalName = ([string]$MappingProperty.Value).Trim()

    if ([string]::IsNullOrWhiteSpace($PhysicalName)) {
        throw "UserSource.FieldMapping.$LogicalName is empty."
    }

    # Be tolerant of BOM/whitespace/case in source headers, but never silently
    # accept a missing mapped field.
    $SourceProperty =
        @(
            $SourceObject.PSObject.Properties |
                Where-Object {
                    $CandidateName =
                        ([string]$_.Name).
                            Trim().
                            TrimStart([char]0xFEFF)

                    $CandidateName.Equals(
                        $PhysicalName,
                        [System.StringComparison]::OrdinalIgnoreCase
                    )
                }
        ) |
        Select-Object -First 1

    if ($null -eq $SourceProperty) {

        $Available =
            @(
                $SourceObject.PSObject.Properties |
                    ForEach-Object {
                        ([string]$_.Name).
                            Trim().
                            TrimStart([char]0xFEFF)
                    }
            ) -join ", "

        throw (
            "Mapped source field '$PhysicalName' for logical field '$LogicalName' " +
            "was not found. Available fields: $Available"
        )
    }

    return $SourceProperty.Value
}

function Get-ExpectedSourceFieldNames {

    return @(
        foreach ($LogicalName in @(
            "UserPrincipalName",
            "EntraObjectId",
            "LearnUserName",
            "TranscriptId",
            "CredlyUser",
            "Enabled"
        )) {

            $MappingProperty =
                $script:FieldMapping.PSObject.Properties[$LogicalName]

            if ($null -eq $MappingProperty) {
                throw "UserSource.FieldMapping.$LogicalName is missing."
            }

            $PhysicalName =
                ([string]$MappingProperty.Value).Trim()

            if ([string]::IsNullOrWhiteSpace($PhysicalName)) {
                throw "UserSource.FieldMapping.$LogicalName is empty."
            }

            $PhysicalName
        }
    )
}

function Get-NormalizedCsvHeaderNames {
    param(
        [Parameter(Mandatory)]
        [string]$HeaderLine,

        [Parameter(Mandatory)]
        [char]$Delimiter
    )

    return @(
        $HeaderLine.Split($Delimiter) |
            ForEach-Object {
                ([string]$_).
                    Trim().
                    Trim('"').
                    Trim().
                    TrimStart([char]0xFEFF)
            }
    )
}

function Get-CsvDelimiterDisplay {
    param(
        [Parameter(Mandatory)]
        [char]$Delimiter
    )

    switch ($Delimiter) {
        "`t" { return "<TAB>" }
        default { return [string]$Delimiter }
    }
}

function Find-BestCsvDelimiter {
    param(
        [Parameter(Mandatory)]
        [string]$HeaderLine,

        [Parameter(Mandatory)]
        [string[]]$ExpectedFields
    )

    $Candidates =
        @(
            [char]',',
            [char]';',
            [char]"`t",
            [char]'|'
        )

    $Best =
        $null

    foreach ($Candidate in $Candidates) {

        $Headers =
            @(
                Get-NormalizedCsvHeaderNames `
                    -HeaderLine $HeaderLine `
                    -Delimiter $Candidate
            )

        $Matches =
            0

        foreach ($Expected in $ExpectedFields) {

            if (
                @(
                    $Headers |
                        Where-Object {
                            $_.Equals(
                                $Expected,
                                [System.StringComparison]::OrdinalIgnoreCase
                            )
                        }
                ).Count -gt 0
            ) {
                $Matches++
            }
        }

        $CandidateResult =
            [PSCustomObject]@{
                Delimiter = $Candidate
                Headers   = $Headers
                Matches   = $Matches
            }

        if (
            $null -eq $Best -or
            $CandidateResult.Matches -gt $Best.Matches
        ) {
            $Best = $CandidateResult
        }
    }

    return $Best
}

function Test-CsvHeaderMapping {
    param(
        [Parameter(Mandatory)]
        [string[]]$Headers,

        [Parameter(Mandatory)]
        [string[]]$ExpectedFields
    )

    $Missing =
        @(
            foreach ($Expected in $ExpectedFields) {

                $Found =
                    @(
                        $Headers |
                            Where-Object {
                                $_.Equals(
                                    $Expected,
                                    [System.StringComparison]::OrdinalIgnoreCase
                                )
                            }
                    ).Count -gt 0

                if (-not $Found) {
                    $Expected
                }
            }
        )

    return [PSCustomObject]@{
        IsValid = ($Missing.Count -eq 0)
        Missing = $Missing
    }
}

function Convert-ToCanonicalUser {
    param(
        [Parameter(Mandatory)]
        $SourceObject
    )

    return [PSCustomObject]@{
        UserPrincipalName =
            Get-MappedSourceValue `
                -SourceObject $SourceObject `
                -LogicalName "UserPrincipalName"

        EntraObjectId =
            Get-MappedSourceValue `
                -SourceObject $SourceObject `
                -LogicalName "EntraObjectId"

        LearnUserName =
            Get-MappedSourceValue `
                -SourceObject $SourceObject `
                -LogicalName "LearnUserName"

        TranscriptId =
            Get-MappedSourceValue `
                -SourceObject $SourceObject `
                -LogicalName "TranscriptId"

        CredlyUser =
            Get-MappedSourceValue `
                -SourceObject $SourceObject `
                -LogicalName "CredlyUser"

        Enabled =
            Get-MappedSourceValue `
                -SourceObject $SourceObject `
                -LogicalName "Enabled"
    }
}

function Import-CsvCredentialUsers {

    $CsvConfig = $script:UserSource.Csv

    $ConfiguredPath =
        [string](Get-RequiredPropertyValue `
            -Object $CsvConfig `
            -Name "Path" `
            -Path "UserSource.Csv")

    $InputPath =
        Resolve-ConfiguredPath `
            -Path $ConfiguredPath `
            -Resolution $script:UserSourcePathResolution

    if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) {
        throw "Configured CSV user source was not found: $InputPath"
    }

    $ConfiguredDelimiterText =
        [string](Get-RequiredPropertyValue `
            -Object $CsvConfig `
            -Name "Delimiter" `
            -Path "UserSource.Csv")

    $Encoding =
        [string](Get-RequiredPropertyValue `
            -Object $CsvConfig `
            -Name "Encoding" `
            -Path "UserSource.Csv")

    $ExpectedFields =
        @(
            Get-ExpectedSourceFieldNames
        )

    # Read the actual header before Import-Csv. This lets us fail early with a
    # useful message and recover from common Excel/localization delimiter changes.
    $HeaderLine =
        Get-Content `
            -LiteralPath $InputPath `
            -Encoding $Encoding `
            -TotalCount 1

    if ([string]::IsNullOrWhiteSpace([string]$HeaderLine)) {
        throw "Configured CSV user source is empty: $InputPath"
    }

    $BestDelimiter =
        Find-BestCsvDelimiter `
            -HeaderLine ([string]$HeaderLine) `
            -ExpectedFields $ExpectedFields

    if ($null -eq $BestDelimiter) {
        throw "Unable to determine the CSV delimiter for '$InputPath'."
    }

    if ($ConfiguredDelimiterText -eq "Auto") {

        if ($BestDelimiter.Matches -ne $ExpectedFields.Count) {
            throw (
                "CSV delimiter auto-detection could not match all configured fields. " +
                "Detected headers: $($BestDelimiter.Headers -join ', '). " +
                "Expected fields: $($ExpectedFields -join ', ')."
            )
        }

        [char]$Delimiter =
            $BestDelimiter.Delimiter
    }
    else {

        if ([string]::IsNullOrEmpty($ConfiguredDelimiterText)) {
            throw "UserSource.Csv.Delimiter is empty."
        }

        if ($ConfiguredDelimiterText -eq "\t") {
            [char]$Delimiter = "`t"
        }
        elseif ($ConfiguredDelimiterText.Length -eq 1) {
            [char]$Delimiter =
                $ConfiguredDelimiterText[0]
        }
        else {
            throw (
                "UserSource.Csv.Delimiter must be one character, '\t', or 'Auto'. " +
                "Configured value: '$ConfiguredDelimiterText'."
            )
        }

        $ConfiguredHeaders =
            @(
                Get-NormalizedCsvHeaderNames `
                    -HeaderLine ([string]$HeaderLine) `
                    -Delimiter $Delimiter
            )

        $ConfiguredValidation =
            Test-CsvHeaderMapping `
                -Headers $ConfiguredHeaders `
                -ExpectedFields $ExpectedFields

        if (-not $ConfiguredValidation.IsValid) {

            if ($BestDelimiter.Matches -eq $ExpectedFields.Count) {

                $ConfiguredDisplay =
                    Get-CsvDelimiterDisplay `
                        -Delimiter $Delimiter

                $DetectedDisplay =
                    Get-CsvDelimiterDisplay `
                        -Delimiter $BestDelimiter.Delimiter

                Write-Warning (
                    "Configured CSV delimiter '$ConfiguredDisplay' does not match the file. " +
                    "Detected '$DetectedDisplay'. The script will use the detected delimiter."
                )

                [char]$Delimiter =
                    $BestDelimiter.Delimiter
            }
            else {

                throw (
                    "CSV header validation failed. Missing mapped field(s): " +
                    "$($ConfiguredValidation.Missing -join ', '). " +
                    "Headers read with configured delimiter: " +
                    "$($ConfiguredHeaders -join ', '). " +
                    "Raw header: $HeaderLine"
                )
            }
        }
    }

    $Rows =
        @(
            Import-Csv `
                -LiteralPath $InputPath `
                -Delimiter $Delimiter `
                -Encoding $Encoding
        )

    if ($Rows.Count -eq 0) {
        throw "Configured CSV contains no data rows: $InputPath"
    }

    $ActualHeaders =
        @(
            $Rows[0].PSObject.Properties |
                ForEach-Object {
                    ([string]$_.Name).
                        Trim().
                        TrimStart([char]0xFEFF)
                }
        )

    $FinalValidation =
        Test-CsvHeaderMapping `
            -Headers $ActualHeaders `
            -ExpectedFields $ExpectedFields

    if (-not $FinalValidation.IsValid) {
        throw (
            "CSV import succeeded but required mapped field(s) are still missing: " +
            "$($FinalValidation.Missing -join ', '). " +
            "Imported fields: $($ActualHeaders -join ', ')."
        )
    }

    $DelimiterDisplay =
        Get-CsvDelimiterDisplay `
            -Delimiter $Delimiter

    Write-Host "CSV delimiter used       : $DelimiterDisplay"
    Write-Host "CSV columns              : $($ActualHeaders -join ', ')"

    $Canonical =
        @(
            foreach ($Row in $Rows) {

                $User =
                    Convert-ToCanonicalUser `
                        -SourceObject $Row

                if (Test-EnabledValue -Value $User.Enabled) {
                    $User
                }
            }
        )

    return [PSCustomObject]@{
        Description = "CSV: $InputPath"
        Users       = $Canonical
    }
}

function Import-JsonCredentialUsers {

    $JsonConfig = $script:UserSource.Json

    $ConfiguredPath =
        [string](Get-RequiredPropertyValue `
            -Object $JsonConfig `
            -Name "Path" `
            -Path "UserSource.Json")

    $InputPath =
        Resolve-ConfiguredPath `
            -Path $ConfiguredPath `
            -Resolution $script:UserSourcePathResolution

    if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) {
        throw "Configured JSON user source was not found: $InputPath"
    }

    $Encoding =
        [string](Get-RequiredPropertyValue `
            -Object $JsonConfig `
            -Name "Encoding" `
            -Path "UserSource.Json")

    $RootProperty =
        [string](Get-RequiredPropertyValue `
            -Object $JsonConfig `
            -Name "RootProperty" `
            -Path "UserSource.Json" `
            -AllowEmpty)

    $Json =
        Get-Content `
            -LiteralPath $InputPath `
            -Raw `
            -Encoding $Encoding |
        ConvertFrom-Json

    if ([string]::IsNullOrWhiteSpace($RootProperty)) {

        $Rows = @($Json)

    }
    else {

        $Property =
            $Json.PSObject.Properties[$RootProperty]

        if ($null -eq $Property) {
            throw "Configured JSON RootProperty '$RootProperty' was not found in '$InputPath'."
        }

        $Rows = @($Property.Value)
    }

    $Canonical =
        @(
            foreach ($Row in $Rows) {

                $User =
                    Convert-ToCanonicalUser `
                        -SourceObject $Row

                if (Test-EnabledValue -Value $User.Enabled) {
                    $User
                }
            }
        )

    return [PSCustomObject]@{
        Description = "JSON: $InputPath"
        Users       = $Canonical
    }
}

function Import-SharePointCredentialUsers {

    $SpoConfig =
        $script:UserSource.SharePointOnline

    $Enabled =
        [bool](Get-RequiredPropertyValue `
            -Object $SpoConfig `
            -Name "Enabled" `
            -Path "UserSource.SharePointOnline")

    if (-not $Enabled) {
        throw "UserSource.Type is SharePointOnline but UserSource.SharePointOnline.Enabled is false."
    }

    $AccessMethod =
        [string](Get-RequiredPropertyValue `
            -Object $SpoConfig `
            -Name "AccessMethod" `
            -Path "UserSource.SharePointOnline")

    if ($AccessMethod -ne "MicrosoftGraph") {
        throw "Unsupported SharePointOnline AccessMethod '$AccessMethod'. Expected 'MicrosoftGraph'."
    }

    $SiteId =
        [string](Get-RequiredPropertyValue `
            -Object $SpoConfig `
            -Name "SiteId" `
            -Path "UserSource.SharePointOnline")

    $ListId =
        [string](Get-RequiredPropertyValue `
            -Object $SpoConfig `
            -Name "ListId" `
            -Path "UserSource.SharePointOnline")

    $ListName =
        [string](Get-RequiredPropertyValue `
            -Object $SpoConfig `
            -Name "ListName" `
            -Path "UserSource.SharePointOnline" `
            -AllowEmpty)

    $PageSize =
        [int](Get-RequiredPropertyValue `
            -Object $SpoConfig `
            -Name "PageSize" `
            -Path "UserSource.SharePointOnline")

    if ($PageSize -lt 1) {
        throw "UserSource.SharePointOnline.PageSize must be greater than zero."
    }

    $Uri =
        "$($script:GraphV1)/sites/$SiteId/lists/$ListId/items?`$expand=fields&`$top=$PageSize"

    $Rows = @()

    do {

        $Response =
            Invoke-MgGraphRequest `
                -Method GET `
                -Uri $Uri `
                -OutputType PSObject `
                -ErrorAction Stop

        foreach ($Item in @($Response.value)) {

            $Fields =
                Get-OptionalPropertyValue `
                    -Object $Item `
                    -Name "fields"

            if ($null -eq $Fields) {
                continue
            }

            $Rows += $Fields
        }

        $NextLink =
            Get-OptionalPropertyValue `
                -Object $Response `
                -Name "@odata.nextLink"

        if ([string]::IsNullOrWhiteSpace([string]$NextLink)) {
            $Uri = $null
        }
        else {
            $Uri = [string]$NextLink
        }

    } while ($null -ne $Uri)

    $Canonical =
        @(
            foreach ($Row in $Rows) {

                $User =
                    Convert-ToCanonicalUser `
                        -SourceObject $Row

                if (Test-EnabledValue -Value $User.Enabled) {
                    $User
                }
            }
        )

    $Description =
        if ([string]::IsNullOrWhiteSpace($ListName)) {
            "SharePoint Online ListId: $ListId"
        }
        else {
            "SharePoint Online: $ListName ($ListId)"
        }

    return [PSCustomObject]@{
        Description = $Description
        Users       = $Canonical
    }
}

function Import-CredentialUsers {

    switch ($script:UserSourceType) {

        "Csv" {
            return Import-CsvCredentialUsers
        }

        "Json" {
            return Import-JsonCredentialUsers
        }

        "SharePointOnline" {
            return Import-SharePointCredentialUsers
        }

        default {
            throw "Unsupported UserSource.Type '$($script:UserSourceType)'."
        }
    }
}

# ---------------------------------------------------------------------------
# Date handling
# ---------------------------------------------------------------------------

function Convert-ToDateTimeInvariant {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [System.DateTimeOffset]) {
        return $Value.DateTime
    }

    if ($Value -is [System.DateTime]) {
        return $Value
    }

    $Text = ([string]$Value).Trim()

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $DateTimeOffsetValue =
        [System.DateTimeOffset]::MinValue

    if (
        [System.DateTimeOffset]::TryParse(
            $Text,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AllowWhiteSpaces,
            [ref]$DateTimeOffsetValue
        )
    ) {
        return $DateTimeOffsetValue.DateTime
    }

    $Formats = @(
        "yyyy-MM-dd",
        "yyyy-MM-ddTHH:mm:ssK",
        "yyyy-MM-ddTHH:mm:ss",
        "MM/dd/yyyy HH:mm:ss",
        "M/d/yyyy H:mm:ss",        "dd/MM/yyyy HH:mm:ss",
        "d/M/yyyy H:mm:ss",
        "dd-MM-yyyy HH:mm:ss",
        "d-M-yyyy H:mm:ss",
        "yyyy-MM-dd HH:mm:ss"
    )

    $DateTimeValue =
        [System.DateTime]::MinValue

    foreach ($Format in $Formats) {

        if (
            [System.DateTime]::TryParseExact(
                $Text,
                $Format,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AllowWhiteSpaces,
                [ref]$DateTimeValue
            )
        ) {
            return $DateTimeValue
        }
    }

    throw "Unable to parse date '$Text'."
}

function Convert-ToProfileDate {
    param($Value)

    $DateValue =
        Convert-ToDateTimeInvariant -Value $Value

    if ($null -eq $DateValue) {
        return $null
    }

    return $DateValue.ToString("yyyy-MM-dd")
}

# ---------------------------------------------------------------------------
# Microsoft Learn
# ---------------------------------------------------------------------------

function Get-MSLearnProfile {

    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$UserName,

        [Parameter(Mandatory)]
        [string]$TranscriptId
    )

    $Headers = @{
        "User-Agent" = "Mozilla/5.0 (compatible; MSLearnProfile/3.1)"
        "Accept"     = "application/json"
    }

    $EncodedUserName =
        [System.Uri]::EscapeDataString($UserName)

    $EncodedTranscriptId =
        [System.Uri]::EscapeDataString($TranscriptId)

    $ProfileUri =
        "$($script:LearnProfileBaseUrl.TrimEnd('/'))/$EncodedUserName"

    $TranscriptUri =
        "$($script:LearnTranscriptBaseUrl.TrimEnd('/'))/$EncodedTranscriptId"

    $Profile =
        Invoke-RestMethod `
            -Uri $ProfileUri `
            -Headers $Headers `
            -Method Get `
            -ErrorAction Stop

    $Transcript =
        Invoke-RestMethod `
            -Uri $TranscriptUri `
            -Headers $Headers `
            -Method Get `
            -ErrorAction Stop

    $CertificationData =
        Get-OptionalPropertyValue `
            -Object $Transcript `
            -Name "certificationData"

    $ActiveRaw =
        Get-OptionalPropertyValue `
            -Object $CertificationData `
            -Name "activeCertifications"

    $ActiveCertifications =
        @(
            foreach ($Cert in @($ActiveRaw)) {

                $Expiration =
                    Get-OptionalPropertyValue `
                        -Object $Cert `
                        -Name "expiration"

                [PSCustomObject]@{
                    Name =
                        Get-OptionalPropertyValue `
                            -Object $Cert `
                            -Name "name"

                    CredentialNumber =
                        Get-OptionalPropertyValue `
                            -Object $Cert `
                            -Name "certificationNumber"

                    Status =
                        Get-OptionalPropertyValue `
                            -Object $Cert `
                            -Name "status"

                    DateEarned =
                        Get-OptionalPropertyValue `
                            -Object $Cert `
                            -Name "dateEarned"

                    Expiration =
                        $Expiration

                    HasExpiration =
                        (-not [string]::IsNullOrWhiteSpace([string]$Expiration))
                }
            }
        )

    $Affiliations =
        @(
            Get-OptionalPropertyValue `
                -Object $Profile `
                -Name "affiliations"
        )

    return [PSCustomObject]@{

        Profile = [PSCustomObject]@{
            DisplayName =
                Get-OptionalPropertyValue `
                    -Object $Profile `
                    -Name "displayName"

            UserName =
                Get-OptionalPropertyValue `
                    -Object $Profile `
                    -Name "userName"

            UserId =
                Get-OptionalPropertyValue `
                    -Object $Profile `
                    -Name "userId"

            ContactEmail =
                Get-OptionalPropertyValue `
                    -Object $Transcript `
                    -Name "contactEmail"

            Affiliations =
                $Affiliations

            IsMvp =
                ($Affiliations -contains "Mvp")
        }

        CertificationProfile = [PSCustomObject]@{
            MCID =
                Get-OptionalPropertyValue `
                    -Object $CertificationData `
                    -Name "mcid"

            LegalName =
                Get-OptionalPropertyValue `
                    -Object $CertificationData `
                    -Name "legalName"

            ActiveCertifications =
                Get-OptionalPropertyValue `
                    -Object $CertificationData `
                    -Name "totalActiveCertifications"
        }

        ActiveCertifications =
            $ActiveCertifications

        RawProfile =
            $Profile

        RawTranscript =
            $Transcript
    }
}

function Get-MSLearnPublicTranscriptUrl {
    param(
        [Parameter(Mandatory)]
        [string]$UserName,

        [Parameter(Mandatory)]
        [string]$TranscriptId
    )

    $EncodedUserName =
        [System.Uri]::EscapeDataString($UserName)

    $EncodedTranscriptId =
        [System.Uri]::EscapeDataString($TranscriptId)

    return (
        "$($script:LearnPublicTranscriptBaseUrl.TrimEnd('/'))/" +
        "$EncodedUserName/transcript/$EncodedTranscriptId"
    )
}

function Convert-LearnCertToProfileObject {
    param(
        [Parameter(Mandatory)]
        $Cert,

        [Parameter(Mandatory)]
        [string]$TranscriptUrl
    )

    $IssuedDate =
        Convert-ToProfileDate -Value $Cert.DateEarned

    $Result = [ordered]@{
        displayName      = [string]$Cert.Name
        certificationId  = [string]$Cert.CredentialNumber
        description      = $script:LearnManagedDescription
        issuedDate       = $IssuedDate
        startDate        = $IssuedDate
        issuingAuthority = "Microsoft"
        issuingCompany   = "Microsoft"
        webUrl           = $TranscriptUrl
    }

    if ($Cert.HasExpiration) {

        $EndDate =
            Convert-ToProfileDate -Value $Cert.Expiration

        if (-not [string]::IsNullOrWhiteSpace($EndDate)) {
            $Result.endDate = $EndDate
        }
    }

    return [PSCustomObject]$Result
}

# ---------------------------------------------------------------------------
# Credly
# ---------------------------------------------------------------------------

function Get-CredlyRecentBadges {

    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$CredlyUser
    )

    $EncodedCredlyUser =
        [System.Uri]::EscapeDataString($CredlyUser)

    $Uri =
        "$($script:CredlyProfileBaseUrl.TrimEnd('/'))/" +
        "$EncodedCredlyUser/" +
        "$($script:CredlyBadgesEndpointSuffix.TrimStart('/'))"

    $Headers = @{
        "User-Agent" = "Mozilla/5.0 (compatible; CredentialProfileSync/3.1)"
        "Accept"     = "application/json"
    }

    $Response =
        Invoke-RestMethod `
            -Uri $Uri `
            -Headers $Headers `
            -Method Get `
            -ErrorAction Stop

    $Data =
        Get-OptionalPropertyValue `
            -Object $Response `
            -Name "data"

    $CutoffDate =
        (Get-Date).AddMonths(-$script:CredlyMonthsBack).Date

    $BaseUriObject =
        [System.Uri]$script:CredlyProfileBaseUrl

    $CredlyOrigin =
        "$($BaseUriObject.Scheme)://$($BaseUriObject.Authority)"

    $Result =
        @(
            foreach ($Badge in @($Data)) {

                $State =
                    [string](
                        Get-OptionalPropertyValue `
                            -Object $Badge `
                            -Name "state"
                    )

                $Public =
                    Get-OptionalPropertyValue `
                        -Object $Badge `
                        -Name "public"

                if (
                    $script:CredlyRequireAccepted -and
                    $State -ne $script:CredlyAcceptedState
                ) {
                    continue
                }

                if (
                    $script:CredlyRequirePublic -and
                    $Public -ne $true
                ) {
                    continue
                }

                $IssuedRaw =
                    Get-OptionalPropertyValue `
                        -Object $Badge `
                        -Name "issued_at_date"

                $Issued =
                    Convert-ToDateTimeInvariant `
                        -Value $IssuedRaw

                if ($null -eq $Issued) {
                    continue
                }

                if ($Issued.Date -lt $CutoffDate) {
                    continue
                }

                $BadgeTemplate =
                    Get-OptionalPropertyValue `
                        -Object $Badge `
                        -Name "badge_template"

                $IssuerObject =
                    Get-OptionalPropertyValue `
                        -Object $Badge `
                        -Name "issuer"

                $Issuer = $null

                if ($null -ne $IssuerObject) {

                    $Entities =
                        @(
                            Get-OptionalPropertyValue `
                                -Object $IssuerObject `
                                -Name "entities"
                        )

                    if ($Entities.Count -gt 0) {

                        $EntityContainer =
                            Get-OptionalPropertyValue `
                                -Object $Entities[0] `
                                -Name "entity"

                        if ($null -ne $EntityContainer) {

                            $Issuer =
                                Get-OptionalPropertyValue `
                                    -Object $EntityContainer `
                                    -Name "name"
                        }
                    }
                }

                $EarnerPath =
                    [string](
                        Get-OptionalPropertyValue `
                            -Object $Badge `
                            -Name "earner_path"
                    )

                $WebUrl = $null

                if (-not [string]::IsNullOrWhiteSpace($EarnerPath)) {

                    if ($EarnerPath -match "^https?://") {
                        $WebUrl = $EarnerPath
                    }
                    else {
                        $WebUrl =
                            $CredlyOrigin +
                            "/" +
                            $EarnerPath.TrimStart("/")
                    }
                }

                [PSCustomObject]@{
                    Id =
                        Get-OptionalPropertyValue `
                            -Object $Badge `
                            -Name "id"

                    Name =
                        Get-OptionalPropertyValue `
                            -Object $BadgeTemplate `
                            -Name "name"

                    Description =
                        Get-OptionalPropertyValue `
                            -Object $BadgeTemplate `
                            -Name "description"

                    Issuer =
                        $Issuer

                    Issued =
                        $Issued

                    Expiration =
                        Get-OptionalPropertyValue `
                            -Object $Badge `
                            -Name "expires_at_date"

                    WebUrl =
                        $WebUrl

                    ImageUrl =
                        Get-OptionalPropertyValue `
                            -Object $Badge `
                            -Name "image_url"

                    State =
                        $State

                    Public =
                        $Public
                }
            }
        )

    return $Result
}

function Convert-CredlyBadgeToProfileObject {

    param(
        [Parameter(Mandatory)]
        $Badge
    )

    $IssuedDate =
        Convert-ToProfileDate -Value $Badge.Issued

    $Issuer =
        [string]$Badge.Issuer

    $Result = [ordered]@{
        certificationId =
            "$($script:CredlyCredentialIdPrefix)$($Badge.Id)"

        displayName =
            [string]$Badge.Name

        description =
            "$($script:CredlyManagedDescriptionPrefix) - $($Badge.Name)"

        issuedDate =
            $IssuedDate

        startDate =
            $IssuedDate

        issuingAuthority =
            $Issuer

        issuingCompany =
            $Issuer
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Badge.Expiration)) {

        $EndDate =
            Convert-ToProfileDate -Value $Badge.Expiration

        if (-not [string]::IsNullOrWhiteSpace($EndDate)) {
            $Result.endDate = $EndDate
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Badge.WebUrl)) {
        $Result.webUrl = [string]$Badge.WebUrl
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Badge.ImageUrl)) {
        $Result.thumbnailUrl = [string]$Badge.ImageUrl
    }

    return [PSCustomObject]$Result
}

# ---------------------------------------------------------------------------
# Credential normalization / merge
# ---------------------------------------------------------------------------

function Get-NormalizedCredentialName {

    param(
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ""
    }

    $Normalized =
        $Name.Normalize(
            [System.Text.NormalizationForm]::FormD
        )

    $Builder =
        [System.Text.StringBuilder]::new()

    foreach ($Character in $Normalized.ToCharArray()) {

        $Category =
            [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory(
                $Character
            )

        if (
            $Category -ne
            [System.Globalization.UnicodeCategory]::NonSpacingMark
        ) {
            [void]$Builder.Append($Character)
        }
    }

    return (
        $Builder.ToString().
            ToLowerInvariant() `
            -replace '[^a-z0-9]', ''
    )
}

function Get-CertificationKey {
    param($Certification)

    $Id =
        [string](
            Get-OptionalPropertyValue `
                -Object $Certification `
                -Name "certificationId"
        )

    if (-not [string]::IsNullOrWhiteSpace($Id)) {
        return "id:" + $Id.Trim().ToLowerInvariant()
    }

    $Name =
        [string](
            Get-OptionalPropertyValue `
                -Object $Certification `
                -Name "displayName"
        )

    return "name:" + (
        Get-NormalizedCredentialName -Name $Name
    )
}

function Convert-ExistingCertificationStrings {
    param($CertificationStrings)

    $Result = @()

    foreach ($Value in @($CertificationStrings)) {

        if ($null -eq $Value) {
            continue
        }

        if ($Value -is [string]) {

            if ([string]::IsNullOrWhiteSpace($Value)) {
                continue
            }

            try {
                $Result +=
                    ($Value | ConvertFrom-Json -ErrorAction Stop)
            }
            catch {
                Write-Warning (
                    "An existing certification could not be parsed as JSON " +
                    "and will not participate in the merge."
                )
            }
        }
        else {
            $Result += $Value
        }
    }

    return @($Result)
}

function Get-ProfileFieldValue {
    param(
        [Parameter(Mandatory)]
        $Object,

        [Parameter(Mandatory)]
        [string]$Field
    )

    $Value =
        Get-OptionalPropertyValue `
            -Object $Object `
            -Name $Field

    if ($null -eq $Value) {
        return ""
    }

    return [string]$Value
}

function Test-CertificationEquivalent {
    param(
        [Parameter(Mandatory)]
        $A,

        [Parameter(Mandatory)]
        $B
    )

    $Fields = @(
        "displayName",
        "certificationId",
        "description",
        "issuedDate",
        "startDate",
        "endDate",
        "issuingAuthority",
        "issuingCompany",
        "webUrl",
        "thumbnailUrl"
    )

    foreach ($Field in $Fields) {

        $AValue =
            Get-ProfileFieldValue `
                -Object $A `
                -Field $Field

        $BValue =
            Get-ProfileFieldValue `
                -Object $B `
                -Field $Field

        if ($AValue -ne $BValue) {
            return $false
        }
    }

    return $true
}

function Test-IsManagedCertification {
    param($Certification)

    $Id =
        Get-ProfileFieldValue `
            -Object $Certification `
            -Field "certificationId"

    $Description =
        Get-ProfileFieldValue `
            -Object $Certification `
            -Field "description"

    if (
        -not [string]::IsNullOrWhiteSpace($script:CredlyCredentialIdPrefix) -and
        $Id.StartsWith(
            $script:CredlyCredentialIdPrefix,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        return $true
    }

    if ($Description -eq $script:LearnManagedDescription) {
        return $true
    }

    if (
        -not [string]::IsNullOrWhiteSpace($script:CredlyManagedDescriptionPrefix) -and
        $Description.StartsWith(
            $script:CredlyManagedDescriptionPrefix,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        return $true
    }

    return $false
}

# ---------------------------------------------------------------------------
# Graph authentication
# ---------------------------------------------------------------------------

function Connect-CredentialGraph {

    Disconnect-MgGraph `
        -ErrorAction SilentlyContinue |
        Out-Null

    $SecureSecret =
        ConvertTo-SecureString `
            $script:ClientSecret `
            -AsPlainText `
            -Force

    $Credential =
        [PSCredential]::new(
            $script:ClientId,
            $SecureSecret
        )

    Connect-MgGraph `
        -TenantId $script:TenantId `
        -ClientSecretCredential $Credential `
        -NoWelcome `
        -ErrorAction Stop

    $script:GraphConnected = $true

    $Context =
        Get-MgContext

    if ($Context.AuthType -ne "AppOnly") {
        throw "Expected AppOnly authentication. Current AuthType: $($Context.AuthType)"
    }

    if ($Context.TenantId -ne $script:TenantId) {
        throw "Connected tenant '$($Context.TenantId)' does not match configured tenant '$($script:TenantId)'."
    }

    if ($Context.ClientId -ne $script:ClientId) {
        throw "Connected ClientId '$($Context.ClientId)' does not match configured ClientId '$($script:ClientId)'."
    }

    return $Context
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {

    # -----------------------------------------------------------------------
    # Configuration
    # -----------------------------------------------------------------------

    Write-Step "STEP 0 - Load centralized configuration"

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Configuration file not found: $ConfigPath"
    }

    try {
        $Config =
            Get-Content `
                -LiteralPath $ConfigPath `
                -Raw `
                -Encoding UTF8 `
                -ErrorAction Stop |
            ConvertFrom-Json `
                -ErrorAction Stop
    }
    catch {
        throw "Configuration file is not valid JSON: $ConfigPath`n$($_.Exception.Message)"
    }

    $SchemaVersionText =
        [string](Get-RequiredPropertyValue `
            -Object $Config `
            -Name "SchemaVersion" `
            -Path "root")

    try {
        $SchemaVersion = [version]$SchemaVersionText
    }
    catch {
        throw "SchemaVersion '$SchemaVersionText' is not a valid version value."
    }

    if ($SchemaVersion -lt [version]"2.2") {
        throw (
            "Configuration SchemaVersion '$SchemaVersionText' is too old for Step 3. " +
            "Run Update-MSLearnPeopleConnectorConfig-v2.2.ps1 first."
        )
    }

    # Application / authentication

    $Application =
        Get-RequiredPropertyValue `
            -Object $Config `
            -Name "Application" `
            -Path "root"

    $Authentication =
        Get-RequiredPropertyValue `
            -Object $Config `
            -Name "Authentication" `
            -Path "root"

    $script:TenantId =
        [string](Get-RequiredPropertyValue `
            -Object $Application `
            -Name "TenantId" `
            -Path "Application")

    $script:ClientId =
        [string](Get-RequiredPropertyValue `
            -Object $Application `
            -Name "ClientId" `
            -Path "Application")

    $script:ClientSecret =
        [string](Get-RequiredPropertyValue `
            -Object $Authentication `
            -Name "ClientSecret" `
            -Path "Authentication")

    $SecretStorage =
        [string](Get-RequiredPropertyValue `
            -Object $Authentication `
            -Name "SecretStorage" `
            -Path "Authentication")

    if ($SecretStorage -ne "PlainText") {
        throw "Authentication.SecretStorage '$SecretStorage' is not supported by this version."
    }

    $AuthMode =
        [string](Get-RequiredPropertyValue `
            -Object $Authentication `
            -Name "Mode" `
            -Path "Authentication")

    if ($AuthMode -ne "ClientSecret") {
        throw "Authentication.Mode '$AuthMode' is not supported by this version."
    }

    $SecretExpirationText =
        [string](Get-RequiredPropertyValue `
            -Object $Authentication `
            -Name "SecretExpirationUtc" `
            -Path "Authentication" `
            -AllowEmpty)

    if (-not [string]::IsNullOrWhiteSpace($SecretExpirationText)) {

        $SecretExpiration =
            [datetimeoffset]::Parse(
                $SecretExpirationText,
                [System.Globalization.CultureInfo]::InvariantCulture
            )

        if ($SecretExpiration -le [datetimeoffset]::UtcNow) {
            throw "Configured client secret expired at $($SecretExpiration.ToString('u'))."
        }
    }

    # Graph

    $MicrosoftGraph =
        Get-RequiredPropertyValue `
            -Object $Config `
            -Name "MicrosoftGraph" `
            -Path "root"

    $script:GraphV1 =
        ([string](Get-RequiredPropertyValue `
            -Object $MicrosoftGraph `
            -Name "BaseUri" `
            -Path "MicrosoftGraph")).TrimEnd("/")

    # Connector

    $Connector =
        Get-RequiredPropertyValue `
            -Object $Config `
            -Name "Connector" `
            -Path "root"

    $script:ConnectionId =
        [string](Get-RequiredPropertyValue `
            -Object $Connector `
            -Name "ConnectionId" `
            -Path "Connector")

    $ConfiguredContentCategory =
        [string](Get-RequiredPropertyValue `
            -Object $Connector `
            -Name "ContentCategory" `
            -Path "Connector")

    $ConnectorSchema =
        Get-RequiredPropertyValue `
            -Object $Connector `
            -Name "Schema" `
            -Path "Connector"

    $ConfiguredSchemaProperties =
        @(
            Get-RequiredPropertyValue `
                -Object $ConnectorSchema `
                -Name "Properties" `
                -Path "Connector.Schema"
        )

    $AccountSchemaProperty =
        @(
            $ConfiguredSchemaProperties |
                Where-Object {
                    @(
                        Get-OptionalPropertyValue `
                            -Object $_ `
                            -Name "Labels"
                    ) -contains "personAccount"
                }
        ) |
        Select-Object -First 1

    $CertificationSchemaProperty =
        @(
            $ConfiguredSchemaProperties |
                Where-Object {
                    @(
                        Get-OptionalPropertyValue `
                            -Object $_ `
                            -Name "Labels"
                    ) -contains "personCertifications"
                }
        ) |
        Select-Object -First 1

    if ($null -eq $AccountSchemaProperty) {
        throw "Connector.Schema does not define a property labeled 'personAccount'."
    }

    if ($null -eq $CertificationSchemaProperty) {
        throw "Connector.Schema does not define a property labeled 'personCertifications'."
    }

    $script:AccountPropertyName =
        [string](Get-RequiredPropertyValue `
            -Object $AccountSchemaProperty `
            -Name "Name" `
            -Path "Connector.Schema.Properties[personAccount]")

    $AccountPropertyType =
        [string](Get-RequiredPropertyValue `
            -Object $AccountSchemaProperty `
            -Name "Type" `
            -Path "Connector.Schema.Properties[personAccount]")

    $script:CertificationPropertyName =
        [string](Get-RequiredPropertyValue `
            -Object $CertificationSchemaProperty `
            -Name "Name" `
            -Path "Connector.Schema.Properties[personCertifications]")

    $CertificationPropertyType =
        [string](Get-RequiredPropertyValue `
            -Object $CertificationSchemaProperty `
            -Name "Type" `
            -Path "Connector.Schema.Properties[personCertifications]")
    if ($AccountPropertyType -ne "string") {
        throw "The configured personAccount property must use schema type 'string'."
    }

    if ($CertificationPropertyType -ne "stringCollection") {
        throw "The configured personCertifications property must use schema type 'stringCollection'."
    }

    $ExternalItemAcl =
        Get-RequiredPropertyValue `
            -Object $Connector `
            -Name "ExternalItemAcl" `
            -Path "Connector"

    $script:AclType =
        [string](Get-RequiredPropertyValue `
            -Object $ExternalItemAcl `
            -Name "Type" `
            -Path "Connector.ExternalItemAcl")

    $script:AclAccessType =
        [string](Get-RequiredPropertyValue `
            -Object $ExternalItemAcl `
            -Name "AccessType" `
            -Path "Connector.ExternalItemAcl")

    $AclValueSource =
        [string](Get-RequiredPropertyValue `
            -Object $ExternalItemAcl `
            -Name "ValueSource" `
            -Path "Connector.ExternalItemAcl")

    switch ($AclValueSource) {

        "TenantId" {
            $script:AclValue = $script:TenantId
        }

        "Literal" {
            $script:AclValue =
                [string](Get-RequiredPropertyValue `
                    -Object $ExternalItemAcl `
                    -Name "Value" `
                    -Path "Connector.ExternalItemAcl")
        }

        default {
            throw "Unsupported Connector.ExternalItemAcl.ValueSource '$AclValueSource'."
        }
    }

    $script:ConnectionUri =
        "$($script:GraphV1)/external/connections/$($script:ConnectionId)"

    $script:ItemsUri =
        "$($script:ConnectionUri)/items"

    # Credential sources

    $CredentialSources =
        Get-RequiredPropertyValue `
            -Object $Config `
            -Name "CredentialSources" `
            -Path "root"

    $LearnConfig =
        Get-RequiredPropertyValue `
            -Object $CredentialSources `
            -Name "MicrosoftLearn" `
            -Path "CredentialSources"

    $CredlyConfig =
        Get-RequiredPropertyValue `
            -Object $CredentialSources `
            -Name "Credly" `
            -Path "CredentialSources"

    $script:LearnEnabled =
        [bool](Get-RequiredPropertyValue `
            -Object $LearnConfig `
            -Name "Enabled" `
            -Path "CredentialSources.MicrosoftLearn")

    $script:LearnProfileBaseUrl =
        [string](Get-RequiredPropertyValue `
            -Object $LearnConfig `
            -Name "ProfileBaseUrl" `
            -Path "CredentialSources.MicrosoftLearn")

    $script:LearnTranscriptBaseUrl =
        [string](Get-RequiredPropertyValue `
            -Object $LearnConfig `
            -Name "TranscriptBaseUrl" `
            -Path "CredentialSources.MicrosoftLearn")

    $script:LearnPublicTranscriptBaseUrl =
        [string](Get-RequiredPropertyValue `
            -Object $LearnConfig `
            -Name "PublicTranscriptBaseUrl" `
            -Path "CredentialSources.MicrosoftLearn")

    $script:LearnManagedDescription =
        [string](Get-RequiredPropertyValue `
            -Object $LearnConfig `
            -Name "ManagedDescription" `
            -Path "CredentialSources.MicrosoftLearn")

    $PublishActiveOnly =
        [bool](Get-RequiredPropertyValue `
            -Object $LearnConfig `
            -Name "PublishActiveCertificationsOnly" `
            -Path "CredentialSources.MicrosoftLearn")

    if ($script:LearnEnabled -and -not $PublishActiveOnly) {
        throw (
            "This Step 3 implementation currently supports Microsoft Learn active " +
            "certifications only. Set PublishActiveCertificationsOnly to true."
        )
    }

    $script:CredlyEnabled =
        [bool](Get-RequiredPropertyValue `
            -Object $CredlyConfig `
            -Name "Enabled" `
            -Path "CredentialSources.Credly")

    $script:CredlyProfileBaseUrl =
        [string](Get-RequiredPropertyValue `
            -Object $CredlyConfig `
            -Name "ProfileBaseUrl" `
            -Path "CredentialSources.Credly")

    $script:CredlyBadgesEndpointSuffix =
        [string](Get-RequiredPropertyValue `
            -Object $CredlyConfig `
            -Name "BadgesEndpointSuffix" `
            -Path "CredentialSources.Credly")

    $script:CredlyMonthsBack =
        [int](Get-RequiredPropertyValue `
            -Object $CredlyConfig `
            -Name "MonthsBack" `
            -Path "CredentialSources.Credly")

    $script:CredlyRequireAccepted =
        [bool](Get-RequiredPropertyValue `
            -Object $CredlyConfig `
            -Name "RequireAccepted" `
            -Path "CredentialSources.Credly")

    $script:CredlyAcceptedState =
        [string](Get-RequiredPropertyValue `
            -Object $CredlyConfig `
            -Name "AcceptedState" `
            -Path "CredentialSources.Credly")

    $script:CredlyRequirePublic =
        [bool](Get-RequiredPropertyValue `
            -Object $CredlyConfig `
            -Name "RequirePublic" `
            -Path "CredentialSources.Credly")

    $script:CredlyDeduplicateAgainstLearn =
        [bool](Get-RequiredPropertyValue `
            -Object $CredlyConfig `
            -Name "DeduplicateAgainstMicrosoftLearn" `
            -Path "CredentialSources.Credly")

    $script:CredlyManagedDescriptionPrefix =
        [string](Get-RequiredPropertyValue `
            -Object $CredlyConfig `
            -Name "ManagedDescriptionPrefix" `
            -Path "CredentialSources.Credly")

    $script:CredlyCredentialIdPrefix =
        [string](Get-RequiredPropertyValue `
            -Object $CredlyConfig `
            -Name "CredentialIdPrefix" `
            -Path "CredentialSources.Credly")

    if ($script:CredlyMonthsBack -lt 1) {
        throw "CredentialSources.Credly.MonthsBack must be greater than zero."
    }

    # User source

    $script:UserSource =
        Get-RequiredPropertyValue `
            -Object $Config `
            -Name "UserSource" `
            -Path "root"

    $script:UserSourceType =
        [string](Get-RequiredPropertyValue `
            -Object $script:UserSource `
            -Name "Type" `
            -Path "UserSource")

    if ($script:UserSourceType -notin @("Csv","Json","SharePointOnline")) {
        throw "Unsupported UserSource.Type '$($script:UserSourceType)'."
    }

    $script:UserSourcePathResolution =
        [string](Get-RequiredPropertyValue `
            -Object $script:UserSource `
            -Name "PathResolution" `
            -Path "UserSource")

    if (
        $script:UserSourcePathResolution -notin
        @("ScriptRoot","ConfigRoot","CurrentDirectory")
    ) {
        throw "Unsupported UserSource.PathResolution '$($script:UserSourcePathResolution)'."
    }

    $script:FieldMapping =
        Get-RequiredPropertyValue `
            -Object $script:UserSource `
            -Name "FieldMapping" `
            -Path "UserSource"

    foreach ($LogicalField in @(
        "UserPrincipalName",
        "EntraObjectId",
        "LearnUserName",
        "TranscriptId",
        "CredlyUser",
        "Enabled"
    )) {
        [void](Get-RequiredPropertyValue `
            -Object $script:FieldMapping `
            -Name $LogicalField `
            -Path "UserSource.FieldMapping")
    }

    # Synchronization

    $Synchronization =
        Get-RequiredPropertyValue `
            -Object $Config `
            -Name "Synchronization" `
            -Path "root"

    $script:RemoveStaleManagedCredentials =
        [bool](Get-RequiredPropertyValue `
            -Object $Synchronization `
            -Name "RemoveStaleManagedCredentials" `
            -Path "Synchronization")

    $script:PreserveUnmanagedCredentials =
        [bool](Get-RequiredPropertyValue `
            -Object $Synchronization `
            -Name "PreserveUnmanagedCredentials" `
            -Path "Synchronization")

    $script:ContinueOnUserError =
        [bool](Get-RequiredPropertyValue `
            -Object $Synchronization `
            -Name "ContinueOnUserError" `
            -Path "Synchronization")

    $script:DryRun =
        [bool](Get-RequiredPropertyValue `
            -Object $Synchronization `
            -Name "DryRun" `
            -Path "Synchronization")

    $script:ExternalItemIdPrefix =
        [string](Get-RequiredPropertyValue `
            -Object $Synchronization `
            -Name "ExternalItemIdPrefix" `
            -Path "Synchronization")

    # Output

    $Output =
        Get-RequiredPropertyValue `
            -Object $Config `
            -Name "Output" `
            -Path "root"

    $OutputPathResolution =
        [string](Get-RequiredPropertyValue `
            -Object $Output `
            -Name "PathResolution" `
            -Path "Output")

    if (
        $OutputPathResolution -notin
        @("ScriptRoot","ConfigRoot","CurrentDirectory")
    ) {
        throw "Unsupported Output.PathResolution '$OutputPathResolution'."
    }

    $LogDirectorySetting =
        [string](Get-RequiredPropertyValue `
            -Object $Output `
            -Name "LogDirectory" `
            -Path "Output")

    $ReportDirectorySetting =
        [string](Get-RequiredPropertyValue `
            -Object $Output `
            -Name "ReportDirectory" `
            -Path "Output")

    $LogDirectory =
        Resolve-ConfiguredPath `
            -Path $LogDirectorySetting `
            -Resolution $OutputPathResolution

    $ReportDirectory =
        Resolve-ConfiguredPath `
            -Path $ReportDirectorySetting `
            -Resolution $OutputPathResolution

    foreach ($Directory in @($LogDirectory,$ReportDirectory)) {

        if (-not (Test-Path -LiteralPath $Directory)) {
            New-Item `
                -ItemType Directory `
                -Path $Directory `
                -Force |
                Out-Null
        }
    }

    $RunStamp =
        Get-Date -Format "yyyyMMdd-HHmmss"

    $script:LogPath =
        Join-Path `
            $LogDirectory `
            "Sync-MSLearnCredlyPeopleProfiles-$RunStamp.log"

    $script:ReportPath =
        Join-Path `
            $ReportDirectory `
            "Sync-MSLearnCredlyPeopleProfiles-$RunStamp.json"

    try {
        Start-Transcript `
            -Path $script:LogPath `
            -Force |
            Out-Null

        $script:TranscriptStarted = $true
    }
    catch {
        Write-Warning "Unable to start transcript logging: $($_.Exception.Message)"
    }

    Write-Host "Configuration file       : $ConfigPath"
    Write-Host "Schema version           : $SchemaVersionText"
    Write-Host "Tenant ID                : $($script:TenantId)"
    Write-Host "Client ID                : $($script:ClientId)"
    Write-Host "Connection ID            : $($script:ConnectionId)"
    Write-Host "Account property         : $($script:AccountPropertyName)"
    Write-Host "Certification property   : $($script:CertificationPropertyName)"
    Write-Host "User source              : $($script:UserSourceType)"
    Write-Host "Microsoft Learn enabled  : $($script:LearnEnabled)"
    Write-Host "Credly enabled           : $($script:CredlyEnabled)"
    Write-Host "Credly rolling window    : $($script:CredlyMonthsBack) month(s)"
    Write-Host "Remove stale managed     : $($script:RemoveStaleManagedCredentials)"
    Write-Host "Preserve unmanaged       : $($script:PreserveUnmanagedCredentials)"
    Write-Host "Continue on user error   : $($script:ContinueOnUserError)"
    Write-Host "Dry run                  : $($script:DryRun)"

    Write-Success "Centralized configuration loaded and validated."

    # -----------------------------------------------------------------------
    # Module
    # -----------------------------------------------------------------------

    Write-Step "STEP 1 - Validate Microsoft Graph module"

    foreach ($Module in $RequiredModules) {
        Ensure-Module -Name $Module
        Write-Success "Module available: $Module"
    }

    # -----------------------------------------------------------------------
    # Graph authentication
    # -----------------------------------------------------------------------

    Write-Step "STEP 2 - Connect to Microsoft Graph"

    $Context =
        Connect-CredentialGraph

    $Context |
        Select-Object `
            ClientId,
            TenantId,
            AuthType,
            Scopes |
        Format-List

    Write-Success "Connected to Microsoft Graph."

    # -----------------------------------------------------------------------
    # Connector validation
    # -----------------------------------------------------------------------

    Write-Step "STEP 3 - Validate existing People Data Connector"

    $Connection =
        Invoke-MgGraphRequest `
            -Method GET `
            -Uri $script:ConnectionUri `
            -OutputType PSObject `
            -ErrorAction Stop

    $Connection |
        Select-Object `
            id,
            name,
            contentCategory,
            state |
        Format-List

    if ($Connection.state -ne "ready") {
        throw "Connector '$($script:ConnectionId)' is not ready. Current state: $($Connection.state)"
    }

    if ($Connection.contentCategory -ne $ConfiguredContentCategory) {
        throw (
            "Connector '$($script:ConnectionId)' contentCategory " +
            "'$($Connection.contentCategory)' does not match configured " +
            "'$ConfiguredContentCategory'."
        )
    }

    Write-Success "Connector is READY."

    # -----------------------------------------------------------------------
    # Users
    # -----------------------------------------------------------------------

    Write-Step "STEP 4 - Load configured user source"

    $ImportedUsers =
        Import-CredentialUsers

    $Users =
        @($ImportedUsers.Users)

    Write-Host "Source  : $($ImportedUsers.Description)"
    Write-Host "Enabled : $($Users.Count)"

    if ($Users.Count -eq 0) {
        throw "No enabled users were returned by the configured user source."
    }

    # -----------------------------------------------------------------------
    # Synchronization
    # -----------------------------------------------------------------------

    Write-Step "STEP 5 - Read sources and synchronize profile credentials"

    $Results = @()

    foreach ($User in $Users) {

        $UPN =
            ([string]$User.UserPrincipalName).Trim()

        $ObjectId =
            ([string]$User.EntraObjectId).Trim()

        $LearnUserName =
            ([string]$User.LearnUserName).Trim()

        $TranscriptId =
            ([string]$User.TranscriptId).Trim()

        $CredlyUser =
            ([string]$User.CredlyUser).Trim()

        Write-Host ""
        Write-Host "User: $UPN" -ForegroundColor Cyan

        try {

            if ([string]::IsNullOrWhiteSpace($UPN)) {
                throw "UserPrincipalName is empty."
            }

            if ([string]::IsNullOrWhiteSpace($ObjectId)) {
                throw "EntraObjectId is empty for '$UPN'."
            }

            $HasLearn =
                $script:LearnEnabled -and
                (-not [string]::IsNullOrWhiteSpace($LearnUserName)) -and
                (-not [string]::IsNullOrWhiteSpace($TranscriptId))

            $HasCredly =
                $script:CredlyEnabled -and
                (-not [string]::IsNullOrWhiteSpace($CredlyUser))

            if (-not $HasLearn -and -not $HasCredly) {
                throw "No enabled Microsoft Learn or Credly source is configured for '$UPN'."
            }

            # ---------------------------------------------------------------
            # Microsoft Learn
            # ---------------------------------------------------------------

            $Learn =
                $null

            $LearnCertObjects =
                @()

            $LearnNames =
                @{}

            if ($HasLearn) {

                $Learn =
                    Get-MSLearnProfile `
                        -UserName $LearnUserName `
                        -TranscriptId $TranscriptId

                $TranscriptUrl =
                    Get-MSLearnPublicTranscriptUrl `
                        -UserName $LearnUserName `
                        -TranscriptId $TranscriptId

                Write-Host "  Microsoft Learn:"
                Write-Host "    Display Name          : $($Learn.Profile.DisplayName)"
                Write-Host "    UserName              : $($Learn.Profile.UserName)"
                Write-Host "    Contact Email         : $($Learn.Profile.ContactEmail)"
                Write-Host "    MCID                  : $($Learn.CertificationProfile.MCID)"
                Write-Host "    MVP affiliation       : $($Learn.Profile.IsMvp)"
                Write-Host "    Active certifications : $($Learn.ActiveCertifications.Count)"

                $LearnCertObjects =
                    @(
                        foreach ($Cert in $Learn.ActiveCertifications) {

                            $ProfileCert =
                                Convert-LearnCertToProfileObject `
                                    -Cert $Cert `
                                    -TranscriptUrl $TranscriptUrl

                            $NormalizedName =
                                Get-NormalizedCredentialName `
                                    -Name $ProfileCert.displayName

                            if (
                                -not [string]::IsNullOrWhiteSpace(
                                    $NormalizedName
                                )
                            ) {
                                $LearnNames[$NormalizedName] = $true
                            }

                            Write-Host "      - $($ProfileCert.displayName)"

                            $ProfileCert
                        }
                    )
            }
            elseif (-not $script:LearnEnabled) {
                Write-Host "  Microsoft Learn: disabled in configuration."
            }
            else {
                Write-Host "  Microsoft Learn: not configured for this user."
            }

            # ---------------------------------------------------------------
            # Credly
            # ---------------------------------------------------------------

            $CredlyBadges =
                @()

            $CredlyCertObjects =
                @()

            $CredlySkippedDuplicates =
                0

            if ($HasCredly) {

                $CredlyBadges =
                    @(
                        Get-CredlyRecentBadges `
                            -CredlyUser $CredlyUser
                    )

                Write-Host "  Credly:"
                Write-Host "    User                  : $CredlyUser"
                Write-Host "    Recent badges         : $($CredlyBadges.Count)"

                $CredlyCertObjects =
                    @(
                        foreach ($Badge in $CredlyBadges) {

                            $ProfileCert =
                                Convert-CredlyBadgeToProfileObject `
                                    -Badge $Badge

                            $NormalizedName =
                                Get-NormalizedCredentialName `
                                    -Name $ProfileCert.displayName

                            if (
                                $script:CredlyDeduplicateAgainstLearn -and
                                -not [string]::IsNullOrWhiteSpace(
                                    $NormalizedName
                                ) -and
                                $LearnNames.ContainsKey(
                                    $NormalizedName
                                )
                            ) {

                                $CredlySkippedDuplicates++

                                Write-Host (
                                    "      SKIP duplicate of Learn: " +
                                    $ProfileCert.displayName
                                ) -ForegroundColor DarkGray

                                continue
                            }

                            Write-Host "      - $($ProfileCert.displayName)"

                            $ProfileCert
                        }
                    )
            }
            elseif (-not $script:CredlyEnabled) {
                Write-Host "  Credly: disabled in configuration."
            }
            else {
                Write-Host "  Credly: not configured for this user."
            }

            # ---------------------------------------------------------------
            # Desired managed credentials
            # ---------------------------------------------------------------

            $DesiredObjects =
                @(
                    $LearnCertObjects
                    $CredlyCertObjects
                )

            $DesiredByKey =
                [ordered]@{}

            foreach ($CredentialObject in $DesiredObjects) {

                $Key =
                    Get-CertificationKey `
                        -Certification $CredentialObject

                $DesiredByKey[$Key] =
                    $CredentialObject
            }

            # ---------------------------------------------------------------
            # Current connector item
            # ---------------------------------------------------------------

            $SanitizedObjectId =
                $ObjectId -replace "[^A-Za-z0-9]", ""

            $ItemId =
                "$($script:ExternalItemIdPrefix)$SanitizedObjectId"

            if ($ItemId.Length -gt 128) {
                throw "Generated externalItem ID exceeds 128 characters."
            }

            $ItemUri =
                "$($script:ItemsUri)/$ItemId"

            $CurrentItem =
                $null

            try {

                $CurrentItem =
                    Invoke-MgGraphRequest `
                        -Method GET `
                        -Uri $ItemUri `
                        -OutputType PSObject `
                        -ErrorAction Stop
            }
            catch {

                if ($_.Exception.Message -notmatch "404|Not Found") {
                    throw
                }
            }

            $ExistingCertObjects =
                @()

            if ($null -ne $CurrentItem) {

                $Properties =
                    Get-OptionalPropertyValue `
                        -Object $CurrentItem `
                        -Name "properties"

                if ($null -ne $Properties) {

                    $ExistingStrings =
                        Get-OptionalPropertyValue `
                            -Object $Properties `
                            -Name $script:CertificationPropertyName

                    if ($null -ne $ExistingStrings) {

                        $ExistingCertObjects =
                            @(
                                Convert-ExistingCertificationStrings `
                                    -CertificationStrings $ExistingStrings
                            )
                    }
                }
            }

            Write-Host ""
            Write-Host "  Merge:"
            Write-Host "    Existing connector credentials : $($ExistingCertObjects.Count)"
            Write-Host "    Desired managed credentials    : $($DesiredByKey.Count)"

            # ---------------------------------------------------------------
            # Merge existing
            # ---------------------------------------------------------------

            $Merged =
                [ordered]@{}

            $DuplicateCount =
                0

            $RemovedUnmanaged =
                0

            foreach ($Existing in $ExistingCertObjects) {

                $IsManaged =
                    Test-IsManagedCertification `
                        -Certification $Existing

                if (
                    -not $IsManaged -and
                    -not $script:PreserveUnmanagedCredentials
                ) {

                    $RemovedUnmanaged++

                    Write-Host (
                        "    REMOVE unmanaged: " +
                        (Get-ProfileFieldValue `
                            -Object $Existing `
                            -Field "displayName")
                    ) -ForegroundColor Magenta

                    continue
                }

                $Key =
                    Get-CertificationKey `
                        -Certification $Existing

                if ($Merged.Contains($Key)) {

                    $DuplicateCount++

                    Write-Host (
                        "    REMOVE duplicate existing: " +
                        (Get-ProfileFieldValue `
                            -Object $Existing `
                            -Field "displayName")
                    ) -ForegroundColor Magenta

                    continue
                }

                $Merged[$Key] =
                    $Existing
            }

            # ---------------------------------------------------------------
            # Apply desired
            # ---------------------------------------------------------------

            $Added =
                0

            $Updated =
                0

            $Unchanged =
                0

            foreach ($Key in $DesiredByKey.Keys) {

                $Desired =
                    $DesiredByKey[$Key]

                if ($Merged.Contains($Key)) {

                    $Current =
                        $Merged[$Key]

                    if (
                        Test-CertificationEquivalent `
                            -A $Current `
                            -B $Desired
                    ) {
                        $Unchanged++
                    }
                    else {

                        $OldEnd =
                            Get-ProfileFieldValue `
                                -Object $Current `
                                -Field "endDate"

                        $NewEnd =
                            Get-ProfileFieldValue `
                                -Object $Desired `
                                -Field "endDate"

                        $Merged[$Key] =
                            $Desired

                        $Updated++

                        Write-Host (
                            "    UPDATE: " +
                            $Desired.displayName
                        ) -ForegroundColor Yellow

                        if ($OldEnd -ne $NewEnd) {

                            $OldEndText =
                                if ([string]::IsNullOrWhiteSpace($OldEnd)) {
                                    "<none>"
                                }
                                else {
                                    $OldEnd
                                }

                            $NewEndText =
                                if ([string]::IsNullOrWhiteSpace($NewEnd)) {
                                    "<none>"
                                }
                                else {
                                    $NewEnd
                                }

                            Write-Host (
                                "            expiration: " +
                                "$OldEndText -> $NewEndText"
                            ) -ForegroundColor Yellow
                        }
                    }
                }
                else {

                    $Merged[$Key] =
                        $Desired

                    $Added++

                    Write-Host (
                        "    ADD   : " +
                        $Desired.displayName
                    ) -ForegroundColor Green
                }
            }

            # ---------------------------------------------------------------
            # Remove stale managed credentials
            # ---------------------------------------------------------------

            $RemovedStale =
                0

            if ($script:RemoveStaleManagedCredentials) {

                foreach ($Key in @($Merged.Keys)) {

                    if ($DesiredByKey.Contains($Key)) {
                        continue
                    }

                    $CredentialObject =
                        $Merged[$Key]

                    if (
                        Test-IsManagedCertification `
                            -Certification $CredentialObject
                    ) {

                        Write-Host (
                            "    REMOVE stale managed: " +
                            (Get-ProfileFieldValue `
                                -Object $CredentialObject `
                                -Field "displayName")
                        ) -ForegroundColor Magenta

                        $Merged.Remove($Key)

                        $RemovedStale++
                    }
                }
            }

            $FinalObjects =
                @($Merged.Values)

            Write-Host ""
            Write-Host "  Merge summary:"
            Write-Host "    Learn active             : $($LearnCertObjects.Count)"
            Write-Host "    Credly recent            : $($CredlyBadges.Count)"
            Write-Host "    Credly skipped as Learn  : $CredlySkippedDuplicates"
            Write-Host "    Added                    : $Added"
            Write-Host "    Updated                  : $Updated"
            Write-Host "    Unchanged                : $Unchanged"
            Write-Host "    Existing duplicates rm   : $DuplicateCount"
            Write-Host "    Unmanaged removed        : $RemovedUnmanaged"
            Write-Host "    Stale managed removed    : $RemovedStale"
            Write-Host "    Final profile credentials: $($FinalObjects.Count)"

            # ---------------------------------------------------------------
            # Complete property bag
            # ---------------------------------------------------------------

            $CertificationStrings =
                @(
                    foreach ($CredentialObject in $FinalObjects) {

                        $CredentialObject |
                            ConvertTo-Json `
                                -Depth 10 `
                                -Compress
                    }
                )

            $AccountInformation =
                @{
                    userPrincipalName =
                        $UPN

                    externalDirectoryObjectId =
                        $ObjectId
                } |
                ConvertTo-Json `
                    -Compress

            $ItemProperties =
                [ordered]@{}

            $ItemProperties[$script:AccountPropertyName] =
                $AccountInformation

            $ItemProperties[
                "$($script:CertificationPropertyName)@odata.type"
            ] =
                "Collection(String)"

            $ItemProperties[$script:CertificationPropertyName] =
                $CertificationStrings

            $ExternalItem =
                @{
                    id =
                        $ItemId

                    acl =
                        @(
                            @{
                                type       = $script:AclType
                                value      = $script:AclValue
                                accessType = $script:AclAccessType
                            }
                        )

                    properties =
                        $ItemProperties
                }

            # ---------------------------------------------------------------
            # Write / validate
            # ---------------------------------------------------------------

            if ($script:DryRun) {
                Write-Host ""
                Write-Host "  [DRY RUN] No Graph write performed." `
                    -ForegroundColor Yellow

                $Status =
                    "DryRun"
            }
            else {

                Invoke-MgGraphRequest `
                    -Method PUT `
                    -Uri $ItemUri `
                    -Body (
                        $ExternalItem |
                            ConvertTo-Json `
                                -Depth 30 `
                                -Compress
                    ) `
                    -ContentType "application/json" `
                    -OutputType PSObject `
                    -ErrorAction Stop |
                    Out-Null

                $ReadBack =
                    Invoke-MgGraphRequest `
                        -Method GET `
                        -Uri $ItemUri `
                        -OutputType PSObject `
                        -ErrorAction Stop

                $ReadBackId =
                    Get-OptionalPropertyValue `
                        -Object $ReadBack `
                        -Name "id"

                if ($ReadBackId -ne $ItemId) {
                    throw "External item validation failed after PUT."
                }

                Write-Success "Connector item updated."

                $Status =
                    "Synchronized"
            }

            $Results +=
                [PSCustomObject]@{
                    UserPrincipalName =
                        $UPN

                    LearnUserName =
                        $LearnUserName

                    CredlyUser =
                        $CredlyUser

                    LearnActive =
                        $LearnCertObjects.Count

                    CredlyRecent =
                        $CredlyBadges.Count

                    CredlySkipped =
                        $CredlySkippedDuplicates

                    Existing =
                        $ExistingCertObjects.Count

                    Added =
                        $Added

                    Updated =
                        $Updated

                    Unchanged =
                        $Unchanged

                    DuplicatesRemoved =
                        $DuplicateCount

                    UnmanagedRemoved =
                        $RemovedUnmanaged

                    StaleRemoved =
                        $RemovedStale

                    Final =
                        $FinalObjects.Count

                    Status =
                        $Status

                    Error =
                        $null
                }
        }
        catch {

            $UserError =
                $_.Exception.Message

            Write-Host (
                "  [ERROR] " +
                $UserError
            ) -ForegroundColor Red

            $Results +=
                [PSCustomObject]@{
                    UserPrincipalName =
                        $UPN

                    LearnUserName =
                        $LearnUserName

                    CredlyUser =
                        $CredlyUser

                    LearnActive =
                        0

                    CredlyRecent =
                        0

                    CredlySkipped =
                        0

                    Existing =
                        0

                    Added =
                        0

                    Updated =
                        0

                    Unchanged =
                        0

                    DuplicatesRemoved =
                        0

                    UnmanagedRemoved =
                        0

                    StaleRemoved =
                        0

                    Final =
                        0

                    Status =
                        "Failed"

                    Error =
                        $UserError
                }

            if (-not $script:ContinueOnUserError) {
                throw
            }
        }
    }

    # -----------------------------------------------------------------------
    # Summary / report
    # -----------------------------------------------------------------------

    Write-Step "STEP 6 - Summary"

    $Results |
        Format-Table `
            UserPrincipalName,
            LearnActive,
            CredlyRecent,
            CredlySkipped,
            Existing,
            Added,
            Updated,
            Unchanged,
            StaleRemoved,
            Final,
            Status `
        -AutoSize

    $Report =
        [ordered]@{
            GeneratedUtc =
                (Get-Date).ToUniversalTime().ToString("o")

            Configuration = [ordered]@{
                ConfigPath =
                    $ConfigPath

                SchemaVersion =
                    $SchemaVersionText

                TenantId =
                    $script:TenantId

                ClientId =
                    $script:ClientId

                ConnectionId =
                    $script:ConnectionId

                UserSourceType =
                    $script:UserSourceType

                DryRun =
                    $script:DryRun
            }

            Results =
                $Results
        }

    $Report |
        ConvertTo-Json `
            -Depth 20 |
        Set-Content `
            -LiteralPath $script:ReportPath `
            -Encoding UTF8

    $Failures =
        @(
            $Results |
                Where-Object {
                    $_.Status -eq "Failed"
                }
        )

    Write-Host ""
    Write-Host "Report : $($script:ReportPath)"
    Write-Host "Log    : $($script:LogPath)"

    if ($Failures.Count -gt 0) {
        Write-Warning "$($Failures.Count) user(s) failed."
    }
    else {
        Write-Success "Synchronization completed."
    }
}
catch {

    Write-Host ""
    Write-Host "SCRIPT FAILED" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red

    if ($_.InvocationInfo) {
        Write-Host ""
        Write-Host $_.InvocationInfo.PositionMessage `
            -ForegroundColor Yellow
    }

    throw
}
finally {

    if ($script:GraphConnected) {
        try {
            Disconnect-MgGraph `
                -ErrorAction SilentlyContinue |
                Out-Null

            Write-Host "Microsoft Graph session closed." `
                -ForegroundColor DarkGray
        }
        catch {
        }
    }
    else {
        try {
            Disconnect-MgGraph `
                -ErrorAction SilentlyContinue |
                Out-Null
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