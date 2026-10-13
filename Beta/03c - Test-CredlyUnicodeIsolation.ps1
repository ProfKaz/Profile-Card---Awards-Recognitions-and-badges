#requires -Version 7.0
<#
.SYNOPSIS
  Beta-only Credly Unicode isolation test. Three controlled Microsoft 365 users, one public source.
.DESCRIPTION
  Downloads Credly badges.json fresh (never imports badge data from a local CSV).
  Reads a CSV with ONLY test-user mapping (Scenario,UserPrincipalName,EntraObjectId).
  Builds the same schema 2.4 certifications strings and externalItem shape as Step 03.
  Uses a fixed rolling window of 12 calendar months and three scenarios:
    WithoutU200B : include badges with no U+200B in the RAW badge_template.name
    OnlyU200B    : include badges containing U+200B in the RAW badge_template.name
    Normalized   : include ALL eligible badges; normalize string fields
  Safety: preview by default, -Publish required to write. Does not alter Step 03, schema,
  or connector. Never runs against existing externalItems unless -Overwrite is specified.
.EXAMPLE
  & '.\Beta\03c - Test-CredlyUnicodeIsolation.ps1' -UsersCsv '.\Data\CredlyUnicodeTestUsers.csv'
.EXAMPLE
  & '.\Beta\03c - Test-CredlyUnicodeIsolation.ps1' -UsersCsv '.\Data\CredlyUnicodeTestUsers.csv' -Publish
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
$CertProperty = [string]$Config.Schema.CertificationsProperty.Name
$AccountProperty = [string]$Config.Schema.AccountProperty.Name
$SkillsProperty = [string]$Config.Schema.AppliedSkillsProperty.Name
$AwardProperty = [string]$Config.Schema.AppliedSkillsAwardsProperty.Name
$TitleProperty = [string]$Config.Schema.TitleProperty.Name
$UrlProperty = [string]$Config.Schema.UrlProperty.Name
$ModifiedByProperty = [string]$Config.Schema.LastModifiedByProperty.Name
$ModifiedDateProperty = [string]$Config.Schema.LastModifiedDateTimeProperty.Name
foreach ($item in @($CertProperty,$AccountProperty,$SkillsProperty,$AwardProperty,$TitleProperty,$UrlProperty,$ModifiedByProperty,$ModifiedDateProperty)) {
    if ([string]::IsNullOrWhiteSpace($item)) { throw 'Missing a required Schema 2.4 property in configuration.' }
}
$Allowed = @('WithoutU200B','OnlyU200B','Normalized')
$Users = @(Import-Csv -LiteralPath $UsersCsv -Encoding utf8)
if ($Users.Count -ne 3) { throw 'The CSV must contain exactly three test user rows.' }
if (@($Users.Scenario | Sort-Object -Unique).Count -ne 3) { throw 'Scenarios must be unique.' }
foreach ($Scenario in $Allowed) {
    if ($Scenario -notin @($Users.Scenario)) { throw "Missing scenario: $Scenario" }
}
if (@($Users.UserPrincipalName | Sort-Object -Unique).Count -ne 3 -or
    @($Users.EntraObjectId | Sort-Object -Unique).Count -ne 3) {
    throw 'UPNs and Object IDs must be unique across the three rows.'
}
foreach ($User in $Users) {
    $Guid = [guid]::Empty
    if (-not [guid]::TryParse([string]$User.EntraObjectId, [ref]$Guid) -or $Guid -eq [guid]::Empty) {
        throw "Invalid EntraObjectId for $($User.Scenario)"
    }
    if ([string]$User.UserPrincipalName -notmatch '^[^@\s]+@[^@\s]+$') { throw "Invalid UPN: $($User.UserPrincipalName)" }
}

function Normalize-Text([string]$Value) {
    if ($null -eq $Value) { return '' }
    # Remove Unicode Format code points (including U+200B), normalize composed characters,
    # normalize whitespace, and trim. No local CSV round-trip of original badge data.
    $s = [regex]::Replace($Value, '\p{Cf}', '')
    $s = $s.Normalize([Text.NormalizationForm]::FormC)
    return ([regex]::Replace($s, '\s+', ' ')).Trim()
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
    $name = @($Badge.issuer.entities | ForEach-Object { $_.entity.name } | Where-Object { $_ } | Select-Object -First 1)
    return if ($name.Count) { [string]$name[0] } else { '' }
}

$ProfileBase = [string]$Config.CredentialSources.Credly.ProfileBaseUrl
if (-not $ProfileBase) { $ProfileBase = 'https://www.credly.com/users' }
$Suffix = [string]$Config.CredentialSources.Credly.BadgesEndpointSuffix
if (-not $Suffix) { $Suffix = 'badges.json' }
$Base = $ProfileBase.TrimEnd('/')
$CredlyUrl = "$Base/$([uri]::EscapeDataString($CredlyUser))"
$Uri = "$CredlyUrl/$($Suffix.TrimStart('/'))"
$Response = Invoke-RestMethod -Uri $Uri -Method GET -Headers @{
    Accept = 'application/json'
    'User-Agent' = 'Mozilla/5.0 (compatible; CredentialProfileSync/3.1)'
} -ErrorAction Stop
if ($null -eq $Response.data) { throw "Credly response missing data at $Uri" }
$FetchedAt = [datetimeoffset]::UtcNow
$Cutoff = (Get-Date).Date.AddMonths(-12)
$Candidates = @()
foreach ($Badge in @($Response.data)) {
    if ([string]$Badge.state -ne 'accepted' -or $Badge.public -ne $true) { continue }
    $Issued = Profile-Date $Badge.issued_at_date
    if (-not $Issued) { continue }
    if ([datetime]::ParseExact($Issued,'yyyy-MM-dd',$Culture) -lt $Cutoff) { continue }
    $Name = [string]$Badge.badge_template.name
    $Issuer = Get-Issuer $Badge
    if (-not $Badge.id -or -not $Name -or -not $Issuer) {
        throw "Incomplete eligible badge: $($Badge.id). Stop rather than silently dropping a record."
    }
    $Candidates += $Badge
}
if ($Candidates.Count -eq 0) { throw 'No eligible badges found. Nothing published.' }
$ItemBase = "$GraphBase/external/connections/$ConnectionId/items"
$Summaries = @()
$Prepared = @()
foreach ($User in $Users) {
    $Scenario = [string]$User.Scenario
    $Selected = @($Candidates | Where-Object {
        $has = ([string]$_.badge_template.name).Contains([char]0x200B)
        switch ($Scenario) {
            'WithoutU200B' { -not $has }
            'OnlyU200B'    { $has }
            'Normalized'   { $true }
        }
    })
    $BadgeStrings = @(
        foreach ($Badge in $Selected) {
            $Name = [string]$Badge.badge_template.name
            $Issuer = Get-Issuer $Badge
            $Description = "Credly badge synchronized from public profile - $Name"
            if ($Scenario -eq 'Normalized') {
                $Name = Normalize-Text $Name
                $Issuer = Normalize-Text $Issuer
                $Description = Normalize-Text $Description
            }
            $IssueDate = Profile-Date $Badge.issued_at_date
            $EndDate = Profile-Date $Badge.expires_at_date
            $record = [ordered]@{
                certificationId = "credly:$($Badge.id)"
                displayName = $Name
                description = $Description
                issuedDate = $IssueDate
                startDate = $IssueDate
                issuingAuthority = $Issuer
                issuingCompany = $Issuer
            }
            if ($EndDate) { $record.endDate = $EndDate }
            $Path = [string]$Badge.earner_path
            if ($Path) {
                $Origin = ([uri]$ProfileBase).GetLeftPart([uriPartial]::Authority)
                $record.webUrl = if ($Path -match '^https?://') { $Path } else { "$Origin/$($Path.TrimStart('/'))" }
            }
            if ($Badge.image_url) { $record.thumbnailUrl = [string]$Badge.image_url }
            ConvertTo-Json -InputObject $record -Depth 10 -Compress
        }
    )
    $ObjectId = ([guid]$User.EntraObjectId).ToString('N')
    $ItemId = "u$ObjectId"
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
        U200BNames = @($Selected | Where-Object { ([string]$_.badge_template.name).Contains([char]0x200B) }).Count
    }
}
Write-Host "Source: $Uri"
Write-Host "Fetched UTC: $($FetchedAt.ToString('u')); eligible badges (12 months): $($Candidates.Count)"
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
    # Preflight ALL three items before ANY write.
    foreach ($P in $Prepared) {
        try {
            $Existing = Invoke-MgGraphRequest -Method GET -Uri $P.Uri -ErrorAction Stop
            if (-not $Overwrite) { throw "External item $($P.ItemId) already exists. Refusing overwrite; use -Overwrite deliberately." }
        } catch {
            $e = $_
            if ($e.Exception.Message -match 'already exists') { throw }
            $status = $null
            if ($e.Exception.Response) { $status = [int]$e.Exception.Response.StatusCode }
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
