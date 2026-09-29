#requires -Version 7.0
<#
.SYNOPSIS
    Step 3 BETA - Synchronizes Microsoft Learn certifications, Applied Skills and Credly badges into
    the existing Microsoft 365 People Data Connector using centralized JSON configuration.

.DESCRIPTION
    This script reads all environment and runtime configuration from:

        .\Config\MSLearnPeopleConnector.beta.json

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
      - CSV with the compact Step 0 contract.
      - JSON and SharePoint Online when their extended source configuration is present.

    Synchronization behavior:
      Microsoft Learn
        -> active certifications -> personCertifications
        -> Applied Skills -> microsoftAppliedSkills (custom)
        -> Applied Skills -> personAwards (Profile Card projection)
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
    Expected SchemaVersion: 2.3 or later.

    Default path:
      .\Config\MSLearnPeopleConnector.beta.json

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

# Step 3 publishes properties introduced by the SchemaVersion 2.4 contract.
$MinimumSupportedSchemaVersionText = "2.4"
$MinimumSupportedSchemaVersion = [version]$MinimumSupportedSchemaVersionText

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
    $ConfigPath = Join-Path $ScriptDirectory "Config\MSLearnPeopleConnector.beta.json"
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

function Get-SchemaPropertyByLabel {
    param(
        [Parameter(Mandatory)]
        $Schema,

        [Parameter(Mandatory)]
        [string]$Label
    )

    foreach ($SchemaEntry in $Schema.PSObject.Properties) {
        if ($SchemaEntry.Name -eq "BaseType") {
            continue
        }

        $Candidate = $SchemaEntry.Value

        if ($null -eq $Candidate) {
            continue
        }

        $Labels =
            @(
                Get-OptionalPropertyValue `
                    -Object $Candidate `
                    -Name "Labels"
            )

        if (
            @(
                $Labels |
                    Where-Object {
                        ([string]$_).Equals(
                            $Label,
                            [System.StringComparison]::OrdinalIgnoreCase
                        )
                    }
            ).Count -gt 0
        ) {
            return $Candidate
        }
    }

    return $null
}

function Get-ExternalSchema {
    param([Parameter(Mandatory)][string]$ConnectionUri)

    $Response =
        Invoke-MgGraphRequest `
            -Method GET `
            -Uri "$ConnectionUri/schema" `
            -Headers @{
                Prefer = "include-unknown-enum-members"
            } `
            -OutputType PSObject `
            -ErrorAction Stop

    $ValueProperty =
        $Response.PSObject.Properties["value"]

    if ($null -ne $ValueProperty -and $null -ne $ValueProperty.Value) {
        return $ValueProperty.Value
    }

    return $Response
}

function Test-ExternalSchemaContract {
    param(
        [Parameter(Mandatory)]
        $ExternalSchema,

        [Parameter(Mandatory)]
        [object[]]$ExpectedProperties
    )

    $ActualProperties =
        @(
            Get-OptionalPropertyValue `
                -Object $ExternalSchema `
                -Name "properties"
        )

    $Errors = @()

    foreach ($ExpectedProperty in $ExpectedProperties) {
        $ExpectedName =
            [string](Get-RequiredPropertyValue `
                -Object $ExpectedProperty `
                -Name "Name" `
                -Path "Schema")

        $ExpectedType =
            [string](Get-RequiredPropertyValue `
                -Object $ExpectedProperty `
                -Name "Type" `
                -Path "Schema")

        $ActualProperty =
            @(
                $ActualProperties |
                    Where-Object {
                        $ActualName =
                            [string](
                                Get-OptionalPropertyValue `
                                    -Object $_ `
                                    -Name "name"
                            )

                        $ActualName.Equals(
                            $ExpectedName,
                            [System.StringComparison]::OrdinalIgnoreCase
                        )
                    }
            ) |
            Select-Object -First 1

        if (-not $ActualProperty) {
            $Errors += "Missing external schema property '$ExpectedName'."
            continue
        }

        $ActualType =
            [string](
                Get-OptionalPropertyValue `
                    -Object $ActualProperty `
                    -Name "type"
            )

        if (
            -not $ActualType.Equals(
                $ExpectedType,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        ) {
            $Errors += (
                "External schema property '$ExpectedName' has type '$ActualType'; " +
                "expected '$ExpectedType'."
            )
        }
    }

    return @($Errors)
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

    $AppliedSkillsData =
        Get-OptionalPropertyValue `
            -Object $Transcript `
            -Name "appliedSkillsData"

    $AppliedSkillsRaw =
        Get-OptionalPropertyValue `
            -Object $AppliedSkillsData `
            -Name "appliedSkillsCredentials"

    $AppliedSkills =
        @(
            foreach ($Skill in @($AppliedSkillsRaw)) {
                if ($null -eq $Skill) {
                    continue
                }

                [PSCustomObject]@{
                    Name =
                        Get-OptionalPropertyValue `
                            -Object $Skill `
                            -Name "title"

                    CredentialNumber =
                        Get-OptionalPropertyValue `
                            -Object $Skill `
                            -Name "credentialId"

                    DateEarned =
                        Get-OptionalPropertyValue `
                            -Object $Skill `
                            -Name "awardedOn"
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

        AppliedSkills =
            $AppliedSkills

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


function Convert-ToSingleLineText {
    param($Value)

    if ($null -eq $Value) {
        return ""
    }

    return (([string]$Value) -replace "[\r\n]+", " ").Trim()
}

function Convert-LearnAppliedSkillToCustomString {
    param(
        [Parameter(Mandatory)]
        $Skill,

        [Parameter(Mandatory)]
        [string]$TranscriptUrl
    )

    $IssuedDate =
        Convert-ToProfileDate -Value $Skill.DateEarned

    $Lines = @(
        "credentialType: Microsoft Applied Skills"
        "displayName: $(Convert-ToSingleLineText -Value $Skill.Name)"
        "credentialId: $(Convert-ToSingleLineText -Value $Skill.CredentialNumber)"
        "issuedDate: $IssuedDate"
        "issuingAuthority: Microsoft"
        "source: Microsoft Learn"
        "credentialUrl: $(Convert-ToSingleLineText -Value $TranscriptUrl)"
    )

    return ($Lines -join "`n")
}

function Convert-LearnAppliedSkillToAwardObject {
    param(
        [Parameter(Mandatory)]
        $Skill,

        [Parameter(Mandatory)]
        [string]$TranscriptUrl
    )

    $IssuedDate =
        Convert-ToProfileDate -Value $Skill.DateEarned

    return [PSCustomObject][ordered]@{
        displayName      = "Microsoft Applied Skills: $([string]$Skill.Name)"
        description      = "$($script:AppliedSkillManagedDescription); Credential ID: $([string]$Skill.CredentialNumber)"
        issuedDate       = $IssuedDate
        issuingAuthority = "Microsoft"
        webUrl           = $TranscriptUrl
    }
}

# ---------------------------------------------------------------------------
# Credly
# ---------------------------------------------------------------------------

function Get-CredlyPublicProfileUrl {
    param(
        [Parameter(Mandatory)]
        [string]$CredlyUser
    )

    $EncodedCredlyUser =
        [System.Uri]::EscapeDataString($CredlyUser)

    return (
        "$($script:CredlyProfileBaseUrl.TrimEnd('/'))/" +
        $EncodedCredlyUser
    )
}

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

    if ($SchemaVersion -lt $MinimumSupportedSchemaVersion) {
        throw (
            "Configuration SchemaVersion '$SchemaVersionText' is too old for Step 3. " +
            "Step 3 requires SchemaVersion $MinimumSupportedSchemaVersionText or later. " +
            "Run Step 0 and Step 2 before continuing."
        )
    }

    # -----------------------------------------------------------------------
    # Application / authentication
    # -----------------------------------------------------------------------

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

    $script:PublisherDisplayName =
        [string](Get-RequiredPropertyValue `
            -Object $Application `
            -Name "DisplayName" `
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

    # Authentication.Mode existed in an earlier 2.2 draft but is not part of the
    # Step 0 contract currently published in this repository. If present, validate
    # it; otherwise ClientSecret is the implicit authentication mode.
    $AuthModeValue =
        Get-OptionalPropertyValue `
            -Object $Authentication `
            -Name "Mode"

    $AuthMode =
        if ([string]::IsNullOrWhiteSpace([string]$AuthModeValue)) {
            "ClientSecret"
        }
        else {
            [string]$AuthModeValue
        }

    if ($AuthMode -ne "ClientSecret") {
        throw "Authentication.Mode '$AuthMode' is not supported by this version."
    }

    $SecretExpirationText =
        [string](Get-OptionalPropertyValue `
            -Object $Authentication `
            -Name "SecretExpirationUtc")

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

    # -----------------------------------------------------------------------
    # Microsoft Graph
    # -----------------------------------------------------------------------

    $MicrosoftGraph =
        Get-RequiredPropertyValue `
            -Object $Config `
            -Name "MicrosoftGraph" `
            -Path "root"

    $GraphV1Value =
        Get-OptionalPropertyValue `
            -Object $MicrosoftGraph `
            -Name "GraphV1"

    if ([string]::IsNullOrWhiteSpace([string]$GraphV1Value)) {
        # Backward compatibility with the earlier configuration contract.
        $GraphV1Value =
            Get-OptionalPropertyValue `
                -Object $MicrosoftGraph `
                -Name "BaseUri"
    }

    if ([string]::IsNullOrWhiteSpace([string]$GraphV1Value)) {
        throw "Configuration value 'MicrosoftGraph.GraphV1' is missing."
    }

    $script:GraphV1 =
        ([string]$GraphV1Value).TrimEnd("/")

    # -----------------------------------------------------------------------
    # Connector and schema
    # -----------------------------------------------------------------------

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

    if ($script:ConnectionId -notmatch '(?i)beta') {
        throw (
            "BETA safety guard: Connector.ConnectionId must contain 'beta'. " +
            "Current value: '$($script:ConnectionId)'."
        )
    }

    $ConfiguredContentCategory =
        [string](Get-RequiredPropertyValue `
            -Object $Connector `
            -Name "ContentCategory" `
            -Path "Connector")

    # SchemaVersion 2.4 stores the portable schema at the root level. Step 3
    # resolves property names from semantic labels instead of hardcoding them.
    $ConnectorSchema =
        Get-RequiredPropertyValue `
            -Object $Config `
            -Name "Schema" `
            -Path "root"

    $SchemaContracts =
        @(
            [PSCustomObject]@{
                Label        = "personAccount"
                ExpectedType = "string"
                ScriptName   = "AccountPropertyName"
            }
            [PSCustomObject]@{
                Label        = "personCertifications"
                ExpectedType = "stringCollection"
                ScriptName   = "CertificationPropertyName"
            }
            [PSCustomObject]@{
                Label        = "personAwards"
                ExpectedType = "stringCollection"
                ScriptName   = "AppliedSkillsAwardsPropertyName"
            }
            [PSCustomObject]@{
                Label        = "title"
                ExpectedType = "string"
                ScriptName   = "TitlePropertyName"
            }
            [PSCustomObject]@{
                Label        = "url"
                ExpectedType = "string"
                ScriptName   = "UrlPropertyName"
            }
            [PSCustomObject]@{
                Label        = "lastModifiedBy"
                ExpectedType = "string"
                ScriptName   = "LastModifiedByPropertyName"
            }
            [PSCustomObject]@{
                Label        = "lastModifiedDateTime"
                ExpectedType = "dateTime"
                ScriptName   = "LastModifiedDateTimePropertyName"
            }
        )

    $ExpectedSchemaProperties = @()

    foreach ($SchemaContract in $SchemaContracts) {
        $SchemaProperty =
            Get-SchemaPropertyByLabel `
                -Schema $ConnectorSchema `
                -Label $SchemaContract.Label

        if ($null -eq $SchemaProperty) {
            throw (
                "SchemaVersion $SchemaVersionText does not define a property labeled " +
                "'$($SchemaContract.Label)'. Run Step 0 before Step 3."
            )
        }

        $PropertyName =
            [string](Get-RequiredPropertyValue `
                -Object $SchemaProperty `
                -Name "Name" `
                -Path "Schema")

        $PropertyType =
            [string](Get-RequiredPropertyValue `
                -Object $SchemaProperty `
                -Name "Type" `
                -Path "Schema")

        if (
            -not $PropertyType.Equals(
                $SchemaContract.ExpectedType,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        ) {
            throw (
                "Schema property '$PropertyName' labeled '$($SchemaContract.Label)' " +
                "uses type '$PropertyType'; expected '$($SchemaContract.ExpectedType)'."
            )
        }

        Set-Variable `
            -Scope Script `
            -Name $SchemaContract.ScriptName `
            -Value $PropertyName

        $ExpectedSchemaProperties += $SchemaProperty
    }

    # Schema 2.4 custom property used for Search/Copilot semantics.
    $AppliedSkillsSchemaProperty =
        Get-RequiredPropertyValue `
            -Object $ConnectorSchema `
            -Name "AppliedSkillsProperty" `
            -Path "Schema"

    $script:AppliedSkillsPropertyName =
        [string](Get-RequiredPropertyValue `
            -Object $AppliedSkillsSchemaProperty `
            -Name "Name" `
            -Path "Schema.AppliedSkillsProperty")

    $AppliedSkillsPropertyType =
        [string](Get-RequiredPropertyValue `
            -Object $AppliedSkillsSchemaProperty `
            -Name "Type" `
            -Path "Schema.AppliedSkillsProperty")

    if (
        -not $AppliedSkillsPropertyType.Equals(
            "stringCollection",
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw (
            "Schema.AppliedSkillsProperty '$($script:AppliedSkillsPropertyName)' uses type " +
            "'$AppliedSkillsPropertyType'; expected 'stringCollection'."
        )
    }

    $ExpectedSchemaProperties += $AppliedSkillsSchemaProperty

    # Step 0 intentionally keeps ACL implementation details out of the portable
    # configuration. Use the People connector ACL behavior validated by v1 unless
    # an older/extended ExternalItemAcl object is explicitly present.
    $ExternalItemAcl =
        Get-OptionalPropertyValue `
            -Object $Connector `
            -Name "ExternalItemAcl"

    if ($null -ne $ExternalItemAcl) {

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
    }
    else {
        $script:AclType = "everyone"
        $script:AclValue = $script:TenantId
        $script:AclAccessType = "grant"
    }

    $script:ConnectionUri =
        "$($script:GraphV1)/external/connections/$($script:ConnectionId)"

    $script:ItemsUri =
        "$($script:ConnectionUri)/items"

    # -----------------------------------------------------------------------
    # Credential sources
    # -----------------------------------------------------------------------

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

    $LearnLocale =
        [string](Get-OptionalPropertyValue `
            -Object $LearnConfig `
            -Name "Locale")

    if ([string]::IsNullOrWhiteSpace($LearnLocale)) {
        $LearnLocale = "en-us"
    }

    $Value =
        Get-OptionalPropertyValue -Object $LearnConfig -Name "ProfileBaseUrl"
    $script:LearnProfileBaseUrl =
        if ([string]::IsNullOrWhiteSpace([string]$Value)) {
            "https://learn.microsoft.com/api/profiles"
        }
        else {
            [string]$Value
        }

    $Value =
        Get-OptionalPropertyValue -Object $LearnConfig -Name "TranscriptBaseUrl"
    $script:LearnTranscriptBaseUrl =
        if ([string]::IsNullOrWhiteSpace([string]$Value)) {
            "https://learn.microsoft.com/api/profiles/transcript/share"
        }
        else {
            [string]$Value
        }

    $Value =
        Get-OptionalPropertyValue -Object $LearnConfig -Name "PublicTranscriptBaseUrl"
    $script:LearnPublicTranscriptBaseUrl =
        if ([string]::IsNullOrWhiteSpace([string]$Value)) {
            "https://learn.microsoft.com/$LearnLocale/users"
        }
        else {
            [string]$Value
        }

    $Value =
        Get-OptionalPropertyValue -Object $LearnConfig -Name "ManagedDescription"
    $script:LearnManagedDescription =
        if ([string]::IsNullOrWhiteSpace([string]$Value)) {
            "Microsoft certification synchronized from Microsoft Learn"
        }
        else {
            [string]$Value
        }

    $Value =
        Get-OptionalPropertyValue `
            -Object $LearnConfig `
            -Name "PublishAppliedSkills"

    $script:PublishAppliedSkills =
        if ($null -eq $Value) { $true } else { [bool]$Value }

    $Value =
        Get-OptionalPropertyValue `
            -Object $LearnConfig `
            -Name "PublishAppliedSkillsAsAwards"

    $script:PublishAppliedSkillsAsAwards =
        if ($null -eq $Value) { $true } else { [bool]$Value }

    $Value =
        Get-OptionalPropertyValue `
            -Object $LearnConfig `
            -Name "AppliedSkillManagedDescription"

    $script:AppliedSkillManagedDescription =
        if ([string]::IsNullOrWhiteSpace([string]$Value)) {
            "Microsoft Applied Skills credential synchronized from Microsoft Learn"
        }
        else {
            [string]$Value
        }

    $PublishActiveValue =
        Get-OptionalPropertyValue `
            -Object $LearnConfig `
            -Name "PublishActiveCertificationsOnly"

    $PublishActiveOnly =
        if ($null -eq $PublishActiveValue) {
            $true
        }
        else {
            [bool]$PublishActiveValue
        }

    if ($script:LearnEnabled -and -not $PublishActiveOnly) {
        throw (
            "This Step 3 implementation currently supports Microsoft Learn active " +
            "certifications only."
        )
    }

    $script:CredlyEnabled =
        [bool](Get-RequiredPropertyValue `
            -Object $CredlyConfig `
            -Name "Enabled" `
            -Path "CredentialSources.Credly")

    $Value =
        Get-OptionalPropertyValue -Object $CredlyConfig -Name "ProfileBaseUrl"
    $script:CredlyProfileBaseUrl =
        if ([string]::IsNullOrWhiteSpace([string]$Value)) {
            "https://www.credly.com/users"
        }
        else {
            [string]$Value
        }

    $Value =
        Get-OptionalPropertyValue -Object $CredlyConfig -Name "BadgesEndpointSuffix"
    $script:CredlyBadgesEndpointSuffix =
        if ([string]::IsNullOrWhiteSpace([string]$Value)) {
            "badges.json"
        }
        else {
            [string]$Value
        }

    $script:CredlyMonthsBack =
        [int](Get-RequiredPropertyValue `
            -Object $CredlyConfig `
            -Name "MonthsBack" `
            -Path "CredentialSources.Credly")

    $Value =
        Get-OptionalPropertyValue -Object $CredlyConfig -Name "RequireAccepted"
    $script:CredlyRequireAccepted =
        if ($null -eq $Value) { $true } else { [bool]$Value }

    $Value =
        Get-OptionalPropertyValue -Object $CredlyConfig -Name "AcceptedState"
    $script:CredlyAcceptedState =
        if ([string]::IsNullOrWhiteSpace([string]$Value)) {
            "accepted"
        }
        else {
            [string]$Value
        }

    $Value =
        Get-OptionalPropertyValue -Object $CredlyConfig -Name "RequirePublic"
    $script:CredlyRequirePublic =
        if ($null -eq $Value) { $true } else { [bool]$Value }

    $Value =
        Get-OptionalPropertyValue -Object $CredlyConfig -Name "DeduplicateAgainstMicrosoftLearn"
    $script:CredlyDeduplicateAgainstLearn =
        if ($null -eq $Value) { $true } else { [bool]$Value }

    $Value =
        Get-OptionalPropertyValue -Object $CredlyConfig -Name "ManagedDescriptionPrefix"
    $script:CredlyManagedDescriptionPrefix =
        if ([string]::IsNullOrWhiteSpace([string]$Value)) {
            "Credly badge synchronized from public profile"
        }
        else {
            [string]$Value
        }

    $Value =
        Get-OptionalPropertyValue -Object $CredlyConfig -Name "CredentialIdPrefix"
    $script:CredlyCredentialIdPrefix =
        if ([string]::IsNullOrWhiteSpace([string]$Value)) {
            "credly:"
        }
        else {
            [string]$Value
        }

    if ($script:CredlyMonthsBack -lt 1) {
        throw "CredentialSources.Credly.MonthsBack must be greater than zero."
    }

    # -----------------------------------------------------------------------
    # User source
    # -----------------------------------------------------------------------

    $UserSourceConfig =
        Get-RequiredPropertyValue `
            -Object $Config `
            -Name "UserSource" `
            -Path "root"

    $script:UserSourceType =
        [string](Get-RequiredPropertyValue `
            -Object $UserSourceConfig `
            -Name "Type" `
            -Path "UserSource")

    if ($script:UserSourceType -notin @("Csv","Json","SharePointOnline")) {
        throw "Unsupported UserSource.Type '$($script:UserSourceType)'."
    }

    $PathResolutionValue =
        Get-OptionalPropertyValue `
            -Object $UserSourceConfig `
            -Name "PathResolution"

    $script:UserSourcePathResolution =
        if ([string]::IsNullOrWhiteSpace([string]$PathResolutionValue)) {
            "ScriptRoot"
        }
        else {
            [string]$PathResolutionValue
        }

    if (
        $script:UserSourcePathResolution -notin
        @("ScriptRoot","ConfigRoot","CurrentDirectory")
    ) {
        throw "Unsupported UserSource.PathResolution '$($script:UserSourcePathResolution)'."
    }

    # FieldMapping is a root-level object in the current Step 0 contract.
    $script:FieldMapping =
        Get-OptionalPropertyValue `
            -Object $Config `
            -Name "FieldMapping"

    if ($null -eq $script:FieldMapping) {
        $script:FieldMapping =
            Get-OptionalPropertyValue `
                -Object $UserSourceConfig `
                -Name "FieldMapping"
    }

    if ($null -eq $script:FieldMapping) {
        throw "Configuration object 'FieldMapping' is missing."
    }

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
            -Path "FieldMapping")
    }

    # Normalize the current compact UserSource contract into the richer runtime
    # object expected by the import helper functions.
    if ($script:UserSourceType -eq "Csv") {

        $CsvConfig =
            Get-OptionalPropertyValue `
                -Object $UserSourceConfig `
                -Name "Csv"

        if ($null -eq $CsvConfig) {

            $CsvPath =
                [string](Get-RequiredPropertyValue `
                    -Object $UserSourceConfig `
                    -Name "CsvPath" `
                    -Path "UserSource")

            $CsvConfig =
                [PSCustomObject]@{
                    Path      = $CsvPath
                    Delimiter = "Auto"
                    Encoding  = "UTF8"
                }
        }

        $script:UserSource =
            [PSCustomObject]@{
                Type = "Csv"
                Csv  = $CsvConfig
            }
    }
    elseif ($script:UserSourceType -eq "Json") {

        $JsonConfig =
            Get-OptionalPropertyValue `
                -Object $UserSourceConfig `
                -Name "Json"

        if ($null -eq $JsonConfig) {
            throw "UserSource.Type is Json but UserSource.Json is not configured."
        }

        $script:UserSource =
            [PSCustomObject]@{
                Type = "Json"
                Json = $JsonConfig
            }
    }
    else {

        $SharePointConfig =
            Get-OptionalPropertyValue `
                -Object $UserSourceConfig `
                -Name "SharePointOnline"

        if ($null -eq $SharePointConfig) {
            throw "UserSource.Type is SharePointOnline but UserSource.SharePointOnline is not configured."
        }

        $script:UserSource =
            [PSCustomObject]@{
                Type             = "SharePointOnline"
                SharePointOnline = $SharePointConfig
            }
    }

    # -----------------------------------------------------------------------
    # Synchronization
    # -----------------------------------------------------------------------

    $Synchronization =
        Get-RequiredPropertyValue `
            -Object $Config `
            -Name "Synchronization" `
            -Path "root"

    $Value =
        Get-OptionalPropertyValue -Object $Synchronization -Name "RemoveStaleManaged"

    if ($null -eq $Value) {
        $Value =
            Get-OptionalPropertyValue `
                -Object $Synchronization `
                -Name "RemoveStaleManagedCredentials"
    }

    $script:RemoveStaleManagedCredentials =
        if ($null -eq $Value) { $true } else { [bool]$Value }

    $Value =
        Get-OptionalPropertyValue -Object $Synchronization -Name "PreserveUnmanaged"

    if ($null -eq $Value) {
        $Value =
            Get-OptionalPropertyValue `
                -Object $Synchronization `
                -Name "PreserveUnmanagedCredentials"
    }

    $script:PreserveUnmanagedCredentials =
        if ($null -eq $Value) { $true } else { [bool]$Value }

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

    $Value =
        Get-OptionalPropertyValue -Object $Synchronization -Name "ExternalItemIdPrefix"

    $script:ExternalItemIdPrefix =
        if ([string]::IsNullOrWhiteSpace([string]$Value)) {
            "u"
        }
        else {
            [string]$Value
        }

    # -----------------------------------------------------------------------
    # Output
    # -----------------------------------------------------------------------

    $Output =
        Get-RequiredPropertyValue `
            -Object $Config `
            -Name "Output" `
            -Path "root"

    $PathResolutionValue =
        Get-OptionalPropertyValue -Object $Output -Name "PathResolution"

    $OutputPathResolution =
        if ([string]::IsNullOrWhiteSpace([string]$PathResolutionValue)) {
            "ScriptRoot"
        }
        else {
            [string]$PathResolutionValue
        }

    if (
        $OutputPathResolution -notin
        @("ScriptRoot","ConfigRoot","CurrentDirectory")
    ) {
        throw "Unsupported Output.PathResolution '$OutputPathResolution'."
    }

    $LogDirectoryValue =
        Get-OptionalPropertyValue -Object $Output -Name "LogsDirectory"

    if ([string]::IsNullOrWhiteSpace([string]$LogDirectoryValue)) {
        $LogDirectoryValue =
            Get-OptionalPropertyValue -Object $Output -Name "LogDirectory"
    }

    if ([string]::IsNullOrWhiteSpace([string]$LogDirectoryValue)) {
        throw "Configuration value 'Output.LogsDirectory' is missing."
    }

    $ReportDirectoryValue =
        Get-OptionalPropertyValue -Object $Output -Name "ReportsDirectory"

    if ([string]::IsNullOrWhiteSpace([string]$ReportDirectoryValue)) {
        $ReportDirectoryValue =
            Get-OptionalPropertyValue -Object $Output -Name "ReportDirectory"
    }

    if ([string]::IsNullOrWhiteSpace([string]$ReportDirectoryValue)) {
        throw "Configuration value 'Output.ReportsDirectory' is missing."
    }

    $LogDirectory =
        Resolve-ConfiguredPath `
            -Path ([string]$LogDirectoryValue) `
            -Resolution $OutputPathResolution

    $ReportDirectory =
        Resolve-ConfiguredPath `
            -Path ([string]$ReportDirectoryValue) `
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
    Write-Host "Title property           : $($script:TitlePropertyName)"
    Write-Host "URL property             : $($script:UrlPropertyName)"
    Write-Host "Last modified by         : $($script:LastModifiedByPropertyName)"
    Write-Host "Last modified date/time  : $($script:LastModifiedDateTimePropertyName)"
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

    $ExternalSchema =
        Get-ExternalSchema `
            -ConnectionUri $script:ConnectionUri

    $ExternalSchemaErrors =
        @(
            Test-ExternalSchemaContract `
                -ExternalSchema $ExternalSchema `
                -ExpectedProperties $ExpectedSchemaProperties
        )

    if ($ExternalSchemaErrors.Count -gt 0) {
        throw (
            "The live external schema does not match SchemaVersion $SchemaVersionText. " +
            "Run Step 2 before Step 3. " +
            ($ExternalSchemaErrors -join " | ")
        )
    }

    Write-Success "External schema matches the configured SchemaVersion contract."

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

            $TranscriptUrl =
                $null

            $LearnCertObjects =
                @()

            $LearnAppliedSkills =
                @()

            $AppliedSkillCustomStrings =
                @()

            $AppliedSkillAwardObjects =
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
                Write-Host "    Applied Skills        : $($Learn.AppliedSkills.Count)"

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

                if ($script:PublishAppliedSkills) {

                    $LearnAppliedSkills =
                        @($Learn.AppliedSkills)

                    $AppliedSkillCustomStrings =
                        @(
                            foreach ($Skill in $LearnAppliedSkills) {
                                Convert-LearnAppliedSkillToCustomString `
                                    -Skill $Skill `
                                    -TranscriptUrl $TranscriptUrl
                            }
                        )

                    if ($script:PublishAppliedSkillsAsAwards) {
                        $AppliedSkillAwardObjects =
                            @(
                                foreach ($Skill in $LearnAppliedSkills) {

                                    $AwardObject =
                                        Convert-LearnAppliedSkillToAwardObject `
                                            -Skill $Skill `
                                            -TranscriptUrl $TranscriptUrl

                                    Write-Host (
                                        "      [Applied Skill] " +
                                        $Skill.Name
                                    ) -ForegroundColor DarkCyan

                                    $AwardObject
                                }
                            )
                    }
                }
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

            $CredlyProfileUrl =
                $null

            $CredlyCertObjects =
                @()

            $CredlySkippedDuplicates =
                0

            if ($HasCredly) {

                $CredlyProfileUrl =
                    Get-CredlyPublicProfileUrl `
                        -CredlyUser $CredlyUser

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
            Write-Host "    Learn certifications     : $($LearnCertObjects.Count)"
            Write-Host "    Learn Applied Skills     : $($LearnAppliedSkills.Count)"
            Write-Host "    Applied Skills awards    : $($AppliedSkillAwardObjects.Count)"
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

            $AppliedSkillAwardStrings =
                @(
                    foreach ($AwardObject in $AppliedSkillAwardObjects) {
                        $AwardObject |
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

            $LearnDisplayName =
                if ($null -ne $Learn -and $null -ne $Learn.Profile) {
                    [string](
                        Get-OptionalPropertyValue `
                            -Object $Learn.Profile `
                            -Name "DisplayName"
                    )
                }
                else {
                    ""
                }

            $ItemTitle =
                if (-not [string]::IsNullOrWhiteSpace($LearnDisplayName)) {
                    $LearnDisplayName
                }
                else {
                    $UPN
                }

            $ItemSourceUrl =
                if (-not [string]::IsNullOrWhiteSpace([string]$TranscriptUrl)) {
                    [string]$TranscriptUrl
                }
                elseif (-not [string]::IsNullOrWhiteSpace([string]$CredlyProfileUrl)) {
                    [string]$CredlyProfileUrl
                }
                else {
                    throw "No public source URL could be resolved for '$UPN'."
                }

            $ItemModifiedBy =
                $script:PublisherDisplayName

            $ItemModifiedDateTime =
                [datetimeoffset]::UtcNow

            # Use a canonical UTC representation for Graph dateTime properties.
            # Millisecond precision is sufficient for synchronization metadata and
            # avoids false mismatches when Graph normalizes fractional precision.
            $ItemModifiedDateTimeText =
                $ItemModifiedDateTime.
                    ToUniversalTime().
                    ToString(
                        "yyyy-MM-dd'T'HH:mm:ss.fff'Z'",
                        [System.Globalization.CultureInfo]::InvariantCulture
                    )

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

            $ItemProperties[
                "$($script:AppliedSkillsPropertyName)@odata.type"
            ] =
                "Collection(String)"

            $ItemProperties[$script:AppliedSkillsPropertyName] =
                $AppliedSkillCustomStrings

            $ItemProperties[
                "$($script:AppliedSkillsAwardsPropertyName)@odata.type"
            ] =
                "Collection(String)"

            $ItemProperties[$script:AppliedSkillsAwardsPropertyName] =
                $AppliedSkillAwardStrings

            $ItemProperties[$script:TitlePropertyName] =
                $ItemTitle

            $ItemProperties[$script:UrlPropertyName] =
                $ItemSourceUrl

            $ItemProperties[$script:LastModifiedByPropertyName] =
                $ItemModifiedBy

            $ItemProperties[$script:LastModifiedDateTimePropertyName] =
                $ItemModifiedDateTimeText

            Write-Host ""
            Write-Host "  Semantic metadata:"
            Write-Host "    Title                 : $ItemTitle"
            Write-Host "    URL                   : $ItemSourceUrl"
            Write-Host "    Last modified by      : $ItemModifiedBy"
            Write-Host "    Last modified UTC     : $ItemModifiedDateTimeText"
            Write-Host "    Applied Skills custom : $($AppliedSkillCustomStrings.Count)"
            Write-Host "    Applied Skills awards : $($AppliedSkillAwardStrings.Count)"

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
                    throw "External item validation failed after PUT: item ID mismatch."
                }

                $ReadBackProperties =
                    Get-OptionalPropertyValue `
                        -Object $ReadBack `
                        -Name "properties"

                if ($null -eq $ReadBackProperties) {
                    throw "External item validation failed after PUT: properties were not returned."
                }

                foreach ($CollectionValidation in @(
                    [PSCustomObject]@{
                        Name     = $script:AppliedSkillsPropertyName
                        Expected = $AppliedSkillCustomStrings.Count
                    }
                    [PSCustomObject]@{
                        Name     = $script:AppliedSkillsAwardsPropertyName
                        Expected = $AppliedSkillAwardStrings.Count
                    }
                )) {
                    if ($CollectionValidation.Expected -gt 0) {
                        $ActualCollection =
                            @(
                                Get-OptionalPropertyValue `
                                    -Object $ReadBackProperties `
                                    -Name $CollectionValidation.Name
                            )

                        if ($ActualCollection.Count -ne $CollectionValidation.Expected) {
                            throw (
                                "External item validation failed after PUT: collection " +
                                "'$($CollectionValidation.Name)' returned $($ActualCollection.Count) " +
                                "item(s); expected $($CollectionValidation.Expected)."
                            )
                        }
                    }
                }

                foreach ($SemanticValidation in @(
                    [PSCustomObject]@{
                        Name     = $script:TitlePropertyName
                        Expected = $ItemTitle
                    }
                    [PSCustomObject]@{
                        Name     = $script:UrlPropertyName
                        Expected = $ItemSourceUrl
                    }
                    [PSCustomObject]@{
                        Name     = $script:LastModifiedByPropertyName
                        Expected = $ItemModifiedBy
                    }
                )) {
                    $ActualSemanticValue =
                        [string](
                            Get-OptionalPropertyValue `
                                -Object $ReadBackProperties `
                                -Name $SemanticValidation.Name
                        )

                    if ($ActualSemanticValue -ne [string]$SemanticValidation.Expected) {
                        throw (
                            "External item validation failed after PUT: property " +
                            "'$($SemanticValidation.Name)' returned '$ActualSemanticValue'; " +
                            "expected '$($SemanticValidation.Expected)'."
                        )
                    }
                }

                $ReadBackModifiedText =
                    [string](
                        Get-OptionalPropertyValue `
                            -Object $ReadBackProperties `
                            -Name $script:LastModifiedDateTimePropertyName
                    )

                if ([string]::IsNullOrWhiteSpace($ReadBackModifiedText)) {
                    throw (
                        "External item validation failed after PUT: property " +
                        "'$($script:LastModifiedDateTimePropertyName)' was not returned."
                    )
                }

                try {
                    # Some Graph externalItem responses can normalize a dateTime
                    # without returning an explicit offset. Treat offset-less values
                    # as UTC because this connector always publishes UTC timestamps.
                    $ReadBackModifiedDateTime =
                        [datetimeoffset]::Parse(
                            $ReadBackModifiedText,
                            [System.Globalization.CultureInfo]::InvariantCulture,
                            (
                                [System.Globalization.DateTimeStyles]::AssumeUniversal -bor
                                [System.Globalization.DateTimeStyles]::AdjustToUniversal
                            )
                        )
                }
                catch {
                    throw (
                        "External item validation failed after PUT: property " +
                        "'$($script:LastModifiedDateTimePropertyName)' returned " +
                        "'$ReadBackModifiedText', which is not a valid dateTime value."
                    )
                }

                $ModifiedDeltaSeconds =
                    [math]::Abs(
                        (
                            $ReadBackModifiedDateTime.ToUniversalTime() -
                            $ItemModifiedDateTime.ToUniversalTime()
                        ).TotalSeconds
                    )

                if ($ModifiedDeltaSeconds -gt 2) {
                    throw (
                        "External item validation failed after PUT: property " +
                        "'$($script:LastModifiedDateTimePropertyName)' returned " +
                        "'$ReadBackModifiedText' while '$ItemModifiedDateTimeText' was submitted " +
                        "(difference: $([math]::Round($ModifiedDeltaSeconds, 3)) seconds)."
                    )
                }

                Write-Success "Connector item updated and semantic metadata validated."

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

                    LearnAppliedSkills =
                        $LearnAppliedSkills.Count

                    AppliedSkillAwards =
                        $AppliedSkillAwardObjects.Count

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

                    LearnAppliedSkills =
                        0

                    AppliedSkillAwards =
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
            LearnAppliedSkills,
            AppliedSkillAwards,
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