#requires -Version 7.0
<#
.SYNOPSIS
Read-only comparison of one user's credential data in multiple people connectors.
.DESCRIPTION
Uses each connector's existing application credentials for GET requests, then a
delegated User.Read.All sign-in for Profile API certifications and awards.
Does not delete items, edit schemas, change precedence, or synchronize users.
Run locally in the operational project root. Reports contain personal data, but
never configuration secrets or access tokens. Protect the Reports directory.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$UserPrincipalName,
    [string[]]$ConfigPaths = @('Config\MSLearnPeopleConnector.json', 'Config\MSLearnPeopleConnector.beta.json'),
    [string]$ProjectRoot = (Get-Location).Path,
    [string]$ReportDirectory = 'Reports'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:GraphConnected = $false
$script:GraphPowerShellClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'

function Get-OptionalPropertyValue {
    param(
        [Parameter(Mandatory)][AllowNull()]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) { return $null }

    $Property = $Object.PSObject.Properties[$Name]
    if ($null -eq $Property) { return $null }

    return $Property.Value
}


function Get-RequiredPropertyValue {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path
    )

    $Value = Get-OptionalPropertyValue -Object $Object -Name $Name
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        throw "Configuration value '$Path.$Name' is missing."
    }

    return $Value
}


function ConvertTo-EnabledBoolean {
    param($Value)

    if ($Value -is [bool]) { return $Value }
    return ([string]$Value).Trim() -match '^(1|true|yes|y|si|sí)$'
}


function Import-EnabledCredentialUsers {
    param(
        [Parameter(Mandatory)][string]$CsvPath,
        [Parameter(Mandatory)]$FieldMapping
    )

    if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) {
        throw "Credential user CSV was not found: $CsvPath"
    }

    $Header = Get-Content -LiteralPath $CsvPath -TotalCount 1 -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($Header)) {
        throw "Credential user CSV is empty: $CsvPath"
    }

    $Delimiters = @(',', ';', "`t")
    $ExpectedNames = @(
        [string](Get-RequiredPropertyValue $FieldMapping 'UserPrincipalName' 'FieldMapping')
        [string](Get-RequiredPropertyValue $FieldMapping 'EntraObjectId' 'FieldMapping')
        [string](Get-RequiredPropertyValue $FieldMapping 'Enabled' 'FieldMapping')
    )

    $Delimiter = $null
    foreach ($Candidate in $Delimiters) {
        $Headers = @($Header -split [regex]::Escape([string]$Candidate)) |
            ForEach-Object { $_.Trim().Trim('"').TrimStart([char]0xFEFF) }

        if (@($ExpectedNames | Where-Object { $_ -notin $Headers }).Count -eq 0) {
            $Delimiter = [char]$Candidate
            break
        }
    }

    if ($null -eq $Delimiter) {
        throw "Unable to detect the CSV delimiter or required mapped columns."
    }

    $UpnField = [string]$FieldMapping.UserPrincipalName
    $ObjectIdField = [string]$FieldMapping.EntraObjectId
    $EnabledField = [string]$FieldMapping.Enabled

    $Users = @(
        Import-Csv -LiteralPath $CsvPath -Delimiter $Delimiter -Encoding UTF8 |
            ForEach-Object {
                [PSCustomObject]@{
                    UserPrincipalName = ([string]$_.$UpnField).Trim()
                    EntraObjectId     = ([string]$_.$ObjectIdField).Trim()
                    Enabled           = ConvertTo-EnabledBoolean $_.$EnabledField
                }
            } |
            Where-Object {
                $_.Enabled -and -not [string]::IsNullOrWhiteSpace($_.UserPrincipalName)
            }
    )

    if ($Users.Count -eq 0) {
        throw "The CSV contains no enabled users."
    }

    return $Users
}


function Connect-ConnectorApplication {
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ClientSecret
    )

    Clear-GraphConnection
    $SecureSecret = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
    $Credential = [PSCredential]::new($ClientId, $SecureSecret)

    Connect-MgGraph `
        -TenantId $TenantId `
        -ClientSecretCredential $Credential `
        -NoWelcome `
        -ErrorAction Stop

    $Context = Get-MgContext
    if ($Context.AuthType -ne 'AppOnly') {
        throw "Expected AppOnly authentication for connector item validation."
    }

    $script:GraphConnected = $true
}


function Clear-GraphConnection {
    try {
        Disconnect-MgGraph `
            -ErrorAction SilentlyContinue `
            -WarningAction SilentlyContinue |
            Out-Null
    }
    catch {
        # Cleanup must not interrupt a read-only validation.
    }

    $script:GraphConnected = $false
}


function Get-ProfileValidationAccessToken {
    param([Parameter(Mandatory)][string]$TenantId)

    $AuthorityTenant = $TenantId.Trim()
    $DeviceCodeUri = "https://login.microsoftonline.com/$AuthorityTenant/oauth2/v2.0/devicecode"
    $TokenUri = "https://login.microsoftonline.com/$AuthorityTenant/oauth2/v2.0/token"

    $Device = Invoke-RestMethod `
        -Method POST `
        -Uri $DeviceCodeUri `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{
            client_id = $script:GraphPowerShellClientId
            scope     = 'https://graph.microsoft.com/User.Read.All openid profile'
        } `
        -ErrorAction Stop

    if (-not $Device.device_code -or -not $Device.user_code) {
        throw 'Microsoft identity platform did not return a valid Device Code response.'
    }

    $VerificationUriValue = Get-OptionalPropertyValue $Device 'verification_uri'
    $VerificationUrlValue = Get-OptionalPropertyValue $Device 'verification_url'
    $VerificationUri = if (-not [string]::IsNullOrWhiteSpace([string]$VerificationUriValue)) {
        [string]$VerificationUriValue
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$VerificationUrlValue)) {
        [string]$VerificationUrlValue
    }
    else {
        'https://microsoft.com/devicelogin'
    }

    Write-Host ''
    Write-Host 'A delegated sign-in is required to read Profile API facets.' -ForegroundColor Yellow
    Write-Host "Open: $VerificationUri" -ForegroundColor Cyan
    Write-Host "Code: $($Device.user_code)" -ForegroundColor Green
    Write-Host 'Waiting for authentication...' -ForegroundColor DarkGray

    $IntervalValue = Get-OptionalPropertyValue $Device 'interval'
    $ExpiresInValue = Get-OptionalPropertyValue $Device 'expires_in'
    $Interval = if ($null -ne $IntervalValue) { [int]$IntervalValue } else { 5 }
    $ExpiresIn = if ($null -ne $ExpiresInValue) { [int]$ExpiresInValue } else { 900 }
    $Deadline = (Get-Date).AddSeconds($ExpiresIn)

    $TokenBody = @{
        grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
        client_id   = $script:GraphPowerShellClientId
        device_code = $Device.device_code
    }

    while ((Get-Date) -lt $Deadline) {
        Start-Sleep -Seconds $Interval
        $TokenStatusCode = $null

        $Token = Invoke-RestMethod `
            -Method POST `
            -Uri $TokenUri `
            -ContentType 'application/x-www-form-urlencoded' `
            -Body $TokenBody `
            -SkipHttpErrorCheck `
            -StatusCodeVariable TokenStatusCode

        $AccessTokenValue = [string](Get-OptionalPropertyValue $Token 'access_token')

        if (
            $TokenStatusCode -ge 200 -and
            $TokenStatusCode -lt 300 -and
            -not [string]::IsNullOrWhiteSpace($AccessTokenValue)
        ) {
            $Claims = ConvertFrom-JwtPayload -Jwt $AccessTokenValue
            $DelegatedScopes = [string](Get-OptionalPropertyValue $Claims 'scp')
            if (($DelegatedScopes -split ' ') -notcontains 'User.Read.All') {
                throw "The delegated token does not contain User.Read.All. Scopes returned: $DelegatedScopes"
            }

            Write-Host '[OK] Delegated authentication completed.' -ForegroundColor Green
            Write-Host "Delegated scopes         : $DelegatedScopes"
            return $AccessTokenValue
        }

        $OAuthError = [string](Get-OptionalPropertyValue $Token 'error')
        $OAuthDescription = [string](Get-OptionalPropertyValue $Token 'error_description')

        if ($OAuthError -eq 'authorization_pending') { continue }
        if ($OAuthError -eq 'slow_down') {
            $Interval += 5
            continue
        }
        if ($TokenStatusCode -eq 429 -or $TokenStatusCode -ge 500) { continue }

        throw "Device Code authentication failed: $OAuthError - $OAuthDescription"
    }

    throw 'The Device Code expired before authentication was completed.'
}


function ConvertFrom-JwtPayload {
    param([Parameter(Mandatory)][string]$Jwt)

    $Parts = $Jwt.Split('.')
    if ($Parts.Count -lt 2) {
        throw 'The delegated access token is not a valid JWT.'
    }

    $Payload = $Parts[1].Replace('-', '+').Replace('_', '/')
    switch ($Payload.Length % 4) {
        2 { $Payload += '==' }
        3 { $Payload += '=' }
    }

    $Bytes = [Convert]::FromBase64String($Payload)
    return ([Text.Encoding]::UTF8.GetString($Bytes) | ConvertFrom-Json)
}


function Get-ProfileGraphCollection {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$AccessToken
    )

    $Items = @()
    $NextUri = $Uri

    while (-not [string]::IsNullOrWhiteSpace($NextUri)) {
        $StatusCode = $null
        $Response = Invoke-RestMethod `
            -Method GET `
            -Uri $NextUri `
            -Headers @{
                Authorization = "Bearer $AccessToken"
                Accept        = 'application/json'
            } `
            -SkipHttpErrorCheck `
            -StatusCodeVariable StatusCode

        if ($StatusCode -lt 200 -or $StatusCode -ge 300) {
            $GraphError = Get-OptionalPropertyValue $Response 'error'
            $ErrorCode = [string](Get-OptionalPropertyValue $GraphError 'code')
            $ErrorMessage = [string](Get-OptionalPropertyValue $GraphError 'message')
            $PermissionHint = if ($StatusCode -eq 403) {
                ' Verify that User.Read.All has tenant admin consent and that the delegated account belongs to the target tenant.'
            }
            else { '' }

            throw "Profile API HTTP $StatusCode - $ErrorCode - $ErrorMessage.$PermissionHint"
        }

        $Items += @($Response.value)
        $NextProperty = $Response.PSObject.Properties['@odata.nextLink']
        $NextUri = if ($null -eq $NextProperty) { $null } else { [string]$NextProperty.Value }
    }

    return @($Items)
}


function Resolve-ProjectPath {
    param([string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) { return $Path }
    return Join-Path $ProjectRoot $Path
}
function Get-FieldText {
    param($Object, [string]$Name)
    return [string](Get-OptionalPropertyValue $Object $Name)
}
function New-EvidenceRow {
    param($Item, [string]$Layer, [string]$Connection, [string]$Facet, [string]$Property)
    $Name = Get-FieldText $Item 'displayName'
    $CredentialId = Get-FieldText $Item 'certificationId'
    # Match candidates conservatively; names alone are not proof of duplicates.
    $Key = if ($CredentialId) { 'id:' + $CredentialId.Trim().ToLowerInvariant() }
    else { 'name:' + (($Name.Trim().ToLowerInvariant()) -replace '\s+', ' ') }
    $Issued = Get-FieldText $Item 'issuedDate'
    $End = Get-FieldText $Item 'endDate'
    if ($Facet -eq 'Awards') { $Issued = Get-FieldText $Item 'awardedDate' }
    [pscustomobject]@{
        Layer = $Layer; ConnectionId = $Connection; Facet = $Facet
        Property = $Property; MatchCandidate = $Key
        RecordId = Get-FieldText $Item 'id'; CredentialId = $CredentialId
        DisplayName = $Name; IssuedOrAwardedDate = $Issued; EndDate = $End
        IssuingAuthority = Get-FieldText $Item 'issuingAuthority'
        Source = (Get-OptionalPropertyValue $Item 'source' | ConvertTo-Json -Depth 30 -Compress)
        CreatedBy = (Get-OptionalPropertyValue $Item 'createdBy' | ConvertTo-Json -Depth 30 -Compress)
        LastModifiedBy = (Get-OptionalPropertyValue $Item 'lastModifiedBy' | ConvertTo-Json -Depth 30 -Compress)
    }
}
$Evidence = [Collections.Generic.List[object]]::new()
$Rows = [Collections.Generic.List[object]]::new()
$Failures = [Collections.Generic.List[object]]::new()
$Configurations = @()
$ProfileAccessToken = $null
try {
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    # Validate all tenants and identities before making any Graph request.
    foreach ($Path in $ConfigPaths) {
        $ResolvedPath = Resolve-ProjectPath $Path
        $Config = Get-Content -LiteralPath $ResolvedPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $CsvValue = Get-OptionalPropertyValue $Config.UserSource 'CsvPath'
        if (-not $CsvValue) {
            $CsvValue = Get-RequiredPropertyValue $Config.UserSource.Csv 'Path' 'UserSource.Csv'
        }
        $Users = @(Import-EnabledCredentialUsers (Resolve-ProjectPath $CsvValue) $Config.FieldMapping)
        $Matches = @($Users | Where-Object UserPrincipalName -IEQ $UserPrincipalName)
        if ($Matches.Count -ne 1) {
            throw "Expected exactly one enabled CSV row for $UserPrincipalName in $ResolvedPath."
        }
        $Guid = [guid]::Empty
        if (-not [guid]::TryParse($Matches[0].EntraObjectId, [ref]$Guid)) {
            throw "Missing or invalid EntraObjectId in $ResolvedPath."
        }
        $Tenant = Get-RequiredPropertyValue $Config.Application 'TenantId' 'Application'
        $Connection = Get-RequiredPropertyValue $Config.Connector 'ConnectionId' 'Connector'
        $null = Get-RequiredPropertyValue $Config.Application 'ClientId' 'Application'
        $null = Get-RequiredPropertyValue $Config.Authentication 'ClientSecret' 'Authentication'
        if ($Connection -notmatch '^[A-Za-z0-9]+$') { throw 'Invalid connection ID.' }
        $Configurations += [pscustomobject]@{
            Config = $Config; User = $Matches[0]; Tenant = $Tenant
            Connection = $Connection; ObjectId = $Guid.ToString()
        }
    }
    if ($Configurations.Count -lt 2) { throw 'Provide at least two configuration paths for comparison.' }
    if (@($Configurations.Tenant | Select-Object -Unique).Count -ne 1) {
        throw 'All configurations must target the same tenant.'
    }
    if (@($Configurations.ObjectId | Select-Object -Unique).Count -ne 1) {
        throw 'The CSV rows target different Entra users. Correct the mapping before testing.'
    }

    foreach ($Entry in $Configurations) {
        $Config = $Entry.Config
        $Prefix = Get-OptionalPropertyValue $Config.Synchronization 'ExternalItemIdPrefix'
        if (-not $Prefix) { $Prefix = 'u' }
        $ItemId = "$Prefix$($Entry.ObjectId -replace '[^A-Za-z0-9]', '')"
        $Base = "https://graph.microsoft.com/v1.0/external/connections/$($Entry.Connection)"
        Write-Host "Reading $($Entry.Connection) / $ItemId" -ForegroundColor Cyan
        try {
            Connect-ConnectorApplication $Entry.Tenant $Config.Application.ClientId $Config.Authentication.ClientSecret
            $Item = Invoke-MgGraphRequest -Method GET -Uri "$Base/items/$([Uri]::EscapeDataString($ItemId))" -OutputType PSObject
            $AccountName = Get-RequiredPropertyValue $Config.Schema.AccountProperty 'Name' 'Schema.AccountProperty'
            $Account = (Get-RequiredPropertyValue $Item.properties $AccountName 'Item.properties') | ConvertFrom-Json
            $MappedUpn = Get-FieldText $Account 'userPrincipalName'
            $MappedId = Get-FieldText $Account 'externalDirectoryObjectId'
            $IdentityVerified = ($MappedUpn -ieq $UserPrincipalName) -or ($MappedId -ieq $Entry.ObjectId)
            $Evidence.Add([pscustomobject]@{
                ConnectionId = $Entry.Connection; SchemaVersion = $Config.SchemaVersion
                ExternalItemId = $ItemId; IdentityVerified = $IdentityVerified; ExternalItem = $Item
            })
            if (-not $IdentityVerified) { throw 'External item does not map to the requested user.' }

            foreach ($Spec in @(
                @{ Section = 'CertificationProperty'; Facet = 'Certifications' },
                @{ Section = 'AppliedSkillsAwardsProperty'; Facet = 'Awards' }
            )) {
                $Definition = Get-OptionalPropertyValue $Config.Schema $Spec.Section
                if ($null -eq $Definition) { continue }
                $Property = Get-RequiredPropertyValue $Definition 'Name' "Schema.$($Spec.Section)"
                foreach ($Value in @(Get-OptionalPropertyValue $Item.properties $Property)) {
                    if ($null -eq $Value) { continue }
                    $Credential = if ($Value -is [string]) { $Value | ConvertFrom-Json } else { $Value }
                    $Rows.Add((New-EvidenceRow $Credential 'ExternalItem' $Entry.Connection $Spec.Facet $Property))
                }
            }
        }
        catch {
            $Failures.Add([pscustomobject]@{ Layer = 'ExternalItem'; ConnectionId = $Entry.Connection; Error = $_.Exception.Message })
            Write-Warning "$($Entry.Connection): $($_.Exception.Message)"
        }
        finally { Clear-GraphConnection }
    }

    Write-Host 'Reading the shared Microsoft 365 profile with delegated authentication.' -ForegroundColor Cyan
    $ProfileAccessToken = Get-ProfileValidationAccessToken $Configurations[0].Tenant
    $UserId = [Uri]::EscapeDataString($Configurations[0].ObjectId)
    foreach ($Facet in @('certifications', 'awards')) {
        try {
            $Items = @(Get-ProfileGraphCollection "https://graph.microsoft.com/beta/users/$UserId/profile/$Facet" $ProfileAccessToken)
            $Evidence.Add([pscustomobject]@{ Facet = $Facet; Layer = 'Profile'; Items = $Items })
            foreach ($Item in $Items) {
                $FacetName = if ($Facet -eq 'certifications') { 'Certifications' } else { 'Awards' }
                $Rows.Add((New-EvidenceRow $Item 'Profile' '' $FacetName $Facet))
            }
        }
        catch {
            $Failures.Add([pscustomobject]@{ Layer = 'Profile'; Facet = $Facet; Error = $_.Exception.Message })
            Write-Warning "$Facet : $($_.Exception.Message)"
        }
    }
    Write-Host 'Connector and profile comparison' -ForegroundColor Cyan
    $Rows | Format-Table Layer, ConnectionId, Facet, DisplayName, CredentialId, RecordId -AutoSize -Wrap
    $Candidates = @(
        foreach ($Group in @($Rows | Group-Object Layer, Facet, MatchCandidate)) {
            if ($Group.Count -gt 1) {
                [pscustomobject]@{
                    Group = $Group.Name; Count = $Group.Count
                    Connections = @($Group.Group.ConnectionId | Select-Object -Unique)
                    Records = @($Group.Group)
                }
            }
        }
    )
    Write-Host "Repeated match candidates: $($Candidates.Count). Inspect dates, IDs and raw metadata before concluding."
    $Directory = Resolve-ProjectPath $ReportDirectory
    $null = New-Item -ItemType Directory -Path $Directory -Force
    $SafeUpn = $UserPrincipalName -replace '[^A-Za-z0-9@._-]', '_'
    $Stem = Join-Path $Directory ("ProfileDuplicates-$SafeUpn-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    [pscustomobject]@{
        GeneratedUtc = [DateTime]::UtcNow.ToString('o'); UserPrincipalName = $UserPrincipalName
        EntraObjectId = $Configurations[0].ObjectId; Evidence = @($Evidence.ToArray())
        MatchCandidates = $Candidates; Failures = @($Failures.ToArray())
        Scope = 'Known deterministic item ID from each configuration; not a scan of every connector item.'
    } | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath "$Stem.json" -Encoding UTF8
    $Rows | Export-Csv -LiteralPath "$Stem.csv" -NoTypeInformation -Encoding UTF8
    Write-Host "Reports: $Stem.json and $Stem.csv" -ForegroundColor Green
    if ($Failures.Count) { Write-Warning 'Diagnostic is incomplete. Failures are not evidence that records are absent.' }
}
finally {
    $ProfileAccessToken = $null
    if ($script:GraphConnected) { Clear-GraphConnection }
}
