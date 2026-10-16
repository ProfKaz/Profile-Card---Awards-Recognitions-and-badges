#requires -Version 7.0
<#
.SYNOPSIS
  Beta-only Credly issuer isolation test. Four controlled Microsoft 365 users, one public source.
.DESCRIPTION
  Downloads Credly badges.json fresh (never imports badge data from a local CSV).
  Reads a CSV with ONLY test-user mapping (Scenario,UserPrincipalName,EntraObjectId).
  Builds the same schema 2.4 certifications strings and externalItem shape as Step 03.
  Uses a fixed rolling window of 12 calendar months and four scenarios:
    MicrosoftAll : all eligible badges issued by Microsoft
    OtherIssuers : all eligible badges issued by other organizations
    MicrosoftA   : deterministic first half of Microsoft badge IDs
    MicrosoftB   : deterministic second half of Microsoft badge IDs
  Safety: preview by default, -Publish required to write. Does not alter Step 03, schema,
  or connector. Never runs against existing externalItems unless -Overwrite is specified.
.EXAMPLE
  & '.\Beta\03d - Test-CredlyIssuerIsolation.ps1' -UsersCsv '.\Data\CredlyIssuerTestUsers.csv'
.EXAMPLE
  & '.\Beta\03d - Test-CredlyIssuerIsolation.ps1' -UsersCsv '.\Data\CredlyIssuerTestUsers.csv' -Publish
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$UsersCsv,
    [string]$CredlyUser = 'elias-nieto.65efb4e7',
    [switch]$Publish,
    [switch]$Overwrite
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Culture = [Globalization.CultureInfo]::InvariantCulture
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path $Root 'Config/MSLearnPeopleConnector.json' }
# Resolve relative paths from the caller's current PowerShell directory, not the process working directory.
# The default config remains anchored at the solution root.
if (-not [IO.Path]::IsPathFullyQualified($ConfigPath)) {
    $ConfigPath = Join-Path (Get-Location).Path $ConfigPath
}
if (-not [IO.Path]::IsPathFullyQualified($UsersCsv)) {
    $UsersCsv = Join-Path (Get-Location).Path $UsersCsv
}
$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
$UsersCsv = [IO.Path]::GetFullPath($UsersCsv)
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Configuration missing: $ConfigPath" }
if (-not (Test-Path -LiteralPath $UsersCsv)) { throw "Test mapping missing: $UsersCsv" }
$Config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
if ([version]$Config.SchemaVersion -lt [version]'2.4') { throw 'SchemaVersion 2.4 or later is required.' }
$ConnectionId = [string]$Config.Connector.ConnectionId
$TenantId = [string]$Config.Application.TenantId
$ClientId = [string]$Config.Application.ClientId
$Secret = [string]$Config.Authentication.ClientSecret
$GraphBase = ([string]$Config.MicrosoftGraph.GraphV1).TrimEnd('/')
if (-not $GraphBase) { throw 'MicrosoftGraph.GraphV1 is required.' }
if (-not $ConnectionId -or -not $TenantId -or -not $ClientId -or -not $Secret) {
    throw 'Missing Connector.ConnectionId, Application IDs, or Authentication.ClientSecret.'
}
# StrictMode-safe access for optional entries in both configuration and Credly JSON.
function Get-OptionalValue {
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}
function Get-PropertyByLabel([string]$Label) {
    $matching = @($Config.Schema.PSObject.Properties | Where-Object {
        if ($_.Name -eq 'BaseType' -or $null -eq $_.Value) { return $false }
        $LabelsProperty = $_.Value.PSObject.Properties['Labels']
        if ($null -eq $LabelsProperty -or $null -eq $LabelsProperty.Value) { return $false }
        return @($LabelsProperty.Value) -contains $Label
    })
    if ($matching.Count -ne 1) { throw "Expected exactly one Schema property with label '$Label', found $($matching.Count)." }
    return [string]$matching[0].Value.Name
}
$CertProperty = Get-PropertyByLabel 'personCertifications'
$AccountProperty = Get-PropertyByLabel 'personAccount'
$SkillsProperty = [string]$Config.Schema.AppliedSkillsProperty.Name
$AwardProperty = Get-PropertyByLabel 'personAwards'
$TitleProperty = Get-PropertyByLabel 'title'
$UrlProperty = Get-PropertyByLabel 'url'
$ModifiedByProperty = Get-PropertyByLabel 'lastModifiedBy'
$ModifiedDateProperty = Get-PropertyByLabel 'lastModifiedDateTime'
foreach ($item in @($CertProperty,$AccountProperty,$SkillsProperty,$AwardProperty,$TitleProperty,$UrlProperty,$ModifiedByProperty,$ModifiedDateProperty)) {
    if ([string]::IsNullOrWhiteSpace($item)) { throw 'Missing a required Schema 2.4 property in configuration.' }
}
$Allowed = @('MicrosoftAll','OtherIssuers','MicrosoftA','MicrosoftB')
$Users = @(Import-Csv -LiteralPath $UsersCsv -Encoding utf8)
if ($Users.Count -ne 4) { throw 'The CSV must contain exactly four test user rows.' }
$RequiredColumns = @('Scenario','UserPrincipalName','EntraObjectId')
$AvailableColumns = if ($Users.Count -gt 0) { @($Users[0].PSObject.Properties.Name) } else { @() }
$MissingColumns = @($RequiredColumns | Where-Object { $_ -notin $AvailableColumns })
if ($MissingColumns.Count -gt 0) {
    throw ("Incorrect test mapping CSV. Required columns: Scenario,UserPrincipalName,EntraObjectId. " +
        "Missing: $($MissingColumns -join ', '). The regular CredentialUsers.csv or CredentialUsers-Sample.csv " +
        "cannot be used here; create Data/CredlyIssuerTestUsers.csv instead.")
}
# Reject placeholder data before any Graph request.
$PlaceholderGuids = @(
    '11111111-1111-4111-8111-111111111111',
    '22222222-2222-4222-8222-222222222222',
    '33333333-3333-4333-8333-333333333333',
    '44444444-4444-4444-8444-444444444444'
)
$ExampleRows = @($Users | Where-Object {
    ([string]$_.UserPrincipalName) -match '@example\.com$' -or
    ([string]$_.EntraObjectId) -in $PlaceholderGuids
})
if ($ExampleRows.Count -gt 0) {
    throw 'CSV contains template identities. Replace each UPN and EntraObjectId with a real dedicated test user.'
}
if (@($Users.Scenario | Sort-Object -Unique).Count -ne 4) {
    throw 'Scenarios must be unique.'
}
foreach ($Scenario in $Allowed) {
    if ($Scenario -notin @($Users.Scenario)) { throw "Missing scenario: $Scenario" }
}
if (@($Users.UserPrincipalName | Sort-Object -Unique).Count -ne 4 -or
    @($Users.EntraObjectId | Sort-Object -Unique).Count -ne 4) {
    throw 'UPNs and Object IDs must be unique across the four rows.'
}
foreach ($User in $Users) {
    $Guid = [guid]::Empty
    if (-not [guid]::TryParse([string]$User.EntraObjectId, [ref]$Guid) -or $Guid -eq [guid]::Empty) {
        throw "Invalid EntraObjectId for $($User.Scenario)"
    }
    if ([string]$User.UserPrincipalName -notmatch '^[^@\s]+@[^@\s]+$') { throw "Invalid UPN: $($User.UserPrincipalName)" }
}

function Profile-Date($Raw) {
    if ($null -eq $Raw -or [string]::IsNullOrWhiteSpace([string]$Raw)) { return $null }
    $parsed = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse([string]$Raw,$Culture,[Globalization.DateTimeStyles]::AssumeUniversal,[ref]$parsed)) {
        throw "Unparseable Credly date: $Raw"
    }
    return $parsed.ToString('yyyy-MM-dd',$Culture)
}
function Get-Issuer($Badge) {
    $issuer = Get-OptionalValue -Object $Badge -Name 'issuer'
    $entities = Get-OptionalValue -Object $issuer -Name 'entities'
    $names = @(
        foreach ($entry in @($entities)) {
            $entity = Get-OptionalValue -Object $entry -Name 'entity'
            $value = Get-OptionalValue -Object $entity -Name 'name'
            if ($value) { [string]$value }
        }
    )
    if ($names.Count -gt 0) { return [string]$names[0] }
    return ''
}

$CredlySettings = Get-OptionalValue -Object $Config.CredentialSources -Name 'Credly'
if ($null -eq $CredlySettings) { throw 'Missing CredentialSources.Credly configuration.' }
$ProfileBase = [string](Get-OptionalValue -Object $CredlySettings -Name 'ProfileBaseUrl')
if (-not $ProfileBase) { $ProfileBase = 'https://www.credly.com/users' }
$Suffix = [string](Get-OptionalValue -Object $CredlySettings -Name 'BadgesEndpointSuffix')
if (-not $Suffix) { $Suffix = 'badges.json' }
$Base = $ProfileBase.TrimEnd('/')
$CredlyUrl = "$Base/$([uri]::EscapeDataString($CredlyUser))"
$Uri = "$CredlyUrl/$($Suffix.TrimStart('/'))"
$Response = Invoke-RestMethod -Uri $Uri -Method GET -Headers @{
    Accept = 'application/json'
    'User-Agent' = 'Mozilla/5.0 (compatible; CredentialProfileSync/3.1)'
} -ErrorAction Stop
$ResponseData = Get-OptionalValue -Object $Response -Name 'data'
if ($null -eq $ResponseData) { throw "Credly response missing data at $Uri" }
$FetchedAt = [datetimeoffset]::UtcNow
$Cutoff = (Get-Date).Date.AddMonths(-12)
$Candidates = @()
foreach ($Badge in @($ResponseData)) {
    if ([string](Get-OptionalValue -Object $Badge -Name 'state') -ne 'accepted' -or
        (Get-OptionalValue -Object $Badge -Name 'public') -ne $true) { continue }
    $Issued = Profile-Date (Get-OptionalValue -Object $Badge -Name 'issued_at_date')
    if (-not $Issued) { continue }
    if ([datetime]::ParseExact($Issued,'yyyy-MM-dd',$Culture) -lt $Cutoff) { continue }
    $Name = [string](Get-OptionalValue -Object (Get-OptionalValue -Object $Badge -Name 'badge_template') -Name 'name')
    $Issuer = Get-Issuer $Badge
    if (-not (Get-OptionalValue -Object $Badge -Name 'id') -or -not $Name -or -not $Issuer) {
        throw "Incomplete eligible badge: $(Get-OptionalValue -Object $Badge -Name 'id'). Stop rather than silently dropping a record."
    }
    $Candidates += $Badge
}
if ($Candidates.Count -eq 0) { throw 'No eligible badges found. Nothing published.' }
# Freeze a single fetched source snapshot for all four scenarios.
# Deterministic partition by Credly badge ID, not API response order.
$MicrosoftBadges = @($Candidates | Where-Object { (Get-Issuer $_).Trim() -ieq 'Microsoft' } |
    Sort-Object { [string](Get-OptionalValue -Object $_ -Name 'id') })
$OtherBadges = @($Candidates | Where-Object { (Get-Issuer $_).Trim() -ine 'Microsoft' } |
    Sort-Object { [string](Get-OptionalValue -Object $_ -Name 'id') })
$Split = [int][math]::Ceiling($MicrosoftBadges.Count / 2.0)
$MicrosoftA = @($MicrosoftBadges | Select-Object -First $Split)
$MicrosoftB = @($MicrosoftBadges | Select-Object -Skip $Split)
if ($MicrosoftBadges.Count -eq 0 -or $OtherBadges.Count -eq 0 -or
    $MicrosoftA.Count -eq 0 -or $MicrosoftB.Count -eq 0) {
    throw 'Could not build four nonempty issuer partitions from the Credly response.'
}
if (($MicrosoftBadges.Count + $OtherBadges.Count) -ne $Candidates.Count) {
    throw 'Issuer partition coverage validation failed.'
}
if (($MicrosoftA.Count + $MicrosoftB.Count) -ne $MicrosoftBadges.Count) {
    throw 'Microsoft split coverage validation failed.'
}
$ScenarioBadges = @{
    MicrosoftAll = $MicrosoftBadges
    OtherIssuers = $OtherBadges
    MicrosoftA = $MicrosoftA
    MicrosoftB = $MicrosoftB
}
$ItemBase = "$GraphBase/external/connections/$ConnectionId/items"
$Summaries = @()
$Prepared = @()
foreach ($User in $Users) {
    $Scenario = [string]$User.Scenario
    $Selected = @($ScenarioBadges[$Scenario])
    $BadgeStrings = @(
        foreach ($Badge in $Selected) {
            $Name = [string](Get-OptionalValue -Object (Get-OptionalValue -Object $Badge -Name 'badge_template') -Name 'name')
            $Issuer = Get-Issuer $Badge
            $Description = "Credly badge synchronized from public profile - $Name"
            $IssueDate = Profile-Date (Get-OptionalValue -Object $Badge -Name 'issued_at_date')
            $EndDate = Profile-Date (Get-OptionalValue -Object $Badge -Name 'expires_at_date')
            $record = [ordered]@{
                certificationId = "credly:$(Get-OptionalValue -Object $Badge -Name 'id')"
                displayName = $Name
                description = $Description
                issuedDate = $IssueDate
                startDate = $IssueDate
                issuingAuthority = $Issuer
                issuingCompany = $Issuer
            }
            if ($EndDate) { $record.endDate = $EndDate }
            $Path = [string](Get-OptionalValue -Object $Badge -Name 'earner_path')
            if ($Path) {
                $Origin = ([uri]$ProfileBase).GetLeftPart([uriPartial]::Authority)
                $record.webUrl = if ($Path -match '^https?://') { $Path } else { "$Origin/$($Path.TrimStart('/'))" }
            }
            $ImageUrl = Get-OptionalValue -Object $Badge -Name 'image_url'
            if ($ImageUrl) { $record.thumbnailUrl = [string]$ImageUrl }
            ConvertTo-Json -InputObject $record -Depth 10 -Compress
        }
    )
    $ObjectId = ([guid]$User.EntraObjectId).ToString('N')
    $IdPrefix = [string](Get-OptionalValue -Object $Config.Synchronization -Name 'ExternalItemIdPrefix')
    if (-not $IdPrefix) { $IdPrefix = 'u' }
    $ItemId = "$IdPrefix$ObjectId"
    $Props = [ordered]@{}
    $Props[$AccountProperty] = (@{
        userPrincipalName = [string]$User.UserPrincipalName
        externalDirectoryObjectId = ([guid]$User.EntraObjectId).ToString()
    } | ConvertTo-Json -Compress)
    $Props["$CertProperty@odata.type"] = 'Collection(String)'
    $Props[$CertProperty] = $BadgeStrings
    $Props["$SkillsProperty@odata.type"] = 'Collection(String)'
    $Props[$SkillsProperty] = @()
    $Props["$AwardProperty@odata.type"] = 'Collection(String)'
    $Props[$AwardProperty] = @()
    $Props[$TitleProperty] = [string]$User.UserPrincipalName
    $Props[$UrlProperty] = $CredlyUrl
    $Props[$ModifiedByProperty] = [string]$Config.Application.DisplayName
    $Props[$ModifiedDateProperty] = [datetimeoffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'",$Culture)
    $Payload = [ordered]@{
        id = $ItemId
        acl = @(@{ type='everyone'; value=$TenantId; accessType='grant' })
        properties = $Props
    }
    $Prepared += [pscustomobject]@{ Scenario=$Scenario; UPN=$User.UserPrincipalName; ItemId=$ItemId; Uri="$ItemBase/$ItemId"; Body=$Payload; Count=$BadgeStrings.Count }
    $Summaries += [pscustomobject]@{
        Scenario = $Scenario; UPN = $User.UserPrincipalName; Badges = $Selected.Count
        U200BNames = @($Selected | Where-Object { ([string](Get-OptionalValue -Object (Get-OptionalValue -Object $_ -Name 'badge_template') -Name 'name')).Contains([char]0x200B) }).Count
        PayloadBytes = [Text.Encoding]::UTF8.GetByteCount(($BadgeStrings -join ''))
        Issuers = (@($Selected | ForEach-Object { Get-Issuer $_ } | Sort-Object -Unique) -join ', ')
    }
}
Write-Host "Source: $Uri"
Write-Host "Fetched UTC: $($FetchedAt.ToString('u')); eligible badges (12 months): $($Candidates.Count)"
Write-Host "Microsoft: $($MicrosoftBadges.Count); other issuers: $($OtherBadges.Count); Microsoft halves: $($MicrosoftA.Count) + $($MicrosoftB.Count)"
$Summaries | Format-Table -AutoSize
if (-not $Publish) {
    Write-Host 'PREVIEW ONLY. No Graph authentication or writes. Specify -Publish to execute.' -ForegroundColor Yellow
    return
}
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    throw 'Install Microsoft.Graph.Authentication first.'
}
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
$Secure = ConvertTo-SecureString $Secret -AsPlainText -Force
$Credential = [pscredential]::new($ClientId,$Secure)
Connect-MgGraph -TenantId $TenantId -ClientSecretCredential $Credential -NoWelcome -ErrorAction Stop | Out-Null
try {
    $Context = Get-MgContext
    if ($Context.AuthType -ne 'AppOnly' -or $Context.TenantId -ne $TenantId -or $Context.ClientId -ne $ClientId) {
        throw 'Unexpected Graph authentication context.'
    }
    $Connection = Invoke-MgGraphRequest -Method GET -Uri "$GraphBase/external/connections/$ConnectionId" -ErrorAction Stop
    if ([string]$Connection.contentCategory -ne 'people' -or [string]$Connection.state -ne 'ready') {
        throw 'Connection must be a Ready People Data Connector.'
    }
    # Preflight ALL four items before ANY write.
    foreach ($P in $Prepared) {
        try {
            $Existing = Invoke-MgGraphRequest -Method GET -Uri $P.Uri -ErrorAction Stop
            if (-not $Overwrite) { throw "External item $($P.ItemId) already exists. Refusing overwrite; use -Overwrite deliberately." }
        } catch {
            $e = $_
            if ($e.Exception.Message -match 'already exists') { throw }
            $status = $null
            $responseProperty = $e.Exception.PSObject.Properties['Response']
            if ($null -ne $responseProperty -and $null -ne $responseProperty.Value) {
                $status = [int]$responseProperty.Value.StatusCode
            }
            if ($status -ne 404) { throw }
        }
    }
    foreach ($P in $Prepared) {
        $Json = ConvertTo-Json -InputObject $P.Body -Depth 30 -Compress
        Invoke-MgGraphRequest -Method PUT -Uri $P.Uri -Body $Json -ContentType 'application/json' -ErrorAction Stop | Out-Null
        $Check = Invoke-MgGraphRequest -Method GET -Uri $P.Uri -ErrorAction Stop
        $Actual = @($Check.properties.$CertProperty)
        if ($Actual.Count -ne $P.Count) {
            throw "Read-back mismatch for $($P.UPN): expected $($P.Count), got $($Actual.Count)"
        }
        Write-Host "[OK] $($P.Scenario): $($P.UPN); count $($P.Count); item $($P.ItemId)" -ForegroundColor Green
    }
} finally {
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}
Write-Host 'Graph externalItem writes verified. Profile API materialization must be checked separately with Step 99.'
