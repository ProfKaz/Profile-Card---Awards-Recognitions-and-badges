#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:GraphConnected = $false
$script:GraphPowerShellClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'

function Write-Section {
    param([Parameter(Mandatory)][string]$Title)

    Write-Host ""
    Write-Host ("=" * 88) -ForegroundColor DarkGray
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ("=" * 88) -ForegroundColor DarkGray
}

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

function Resolve-OperationalConfigPath {
    param([string]$RequestedPath)

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $Resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RequestedPath)
        if (-not (Test-Path -LiteralPath $Resolved -PathType Leaf)) {
            throw "Configuration file was not found: $Resolved"
        }
        return $Resolved
    }

    $OperationalConfigPath = Join-Path $PSScriptRoot "Config\MSLearnPeopleConnector.json"
    if (-not (Test-Path -LiteralPath $OperationalConfigPath -PathType Leaf)) {
        throw "Production configuration was not found: $OperationalConfigPath. Use -ConfigPath only for another Schema 2.4 operational path."
    }

    return $OperationalConfigPath
}

function Resolve-OperationalPath {
    param([Parameter(Mandatory)][string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return Join-Path $PSScriptRoot $Path
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

function ConvertFrom-ConnectorJsonCollection {
    param($Values)

    $Result = @()
    foreach ($Value in @($Values)) {
        if ($null -eq $Value) { continue }
        if ($Value -isnot [string]) {
            $Result += $Value
            continue
        }

        if ([string]::IsNullOrWhiteSpace($Value)) { continue }
        try {
            $Result += ($Value | ConvertFrom-Json -ErrorAction Stop)
        }
        catch {
            $Result += [PSCustomObject]@{
                displayName = $Value
                parseStatus = "Raw value - JSON parsing failed"
            }
        }
    }

    return @($Result)
}

function ConvertFrom-AppliedSkillTextCollection {
    param($Values)

    $Result = @()
    foreach ($Value in @($Values)) {
        if ($null -eq $Value) { continue }
        if ($Value -isnot [string]) {
            $Result += $Value
            continue
        }

        $Fields = [ordered]@{}
        foreach ($Line in ($Value -split "`r?`n")) {
            if ($Line -match '^\s*([^:]+):\s*(.*)$') {
                $Fields[$Matches[1].Trim()] = $Matches[2].Trim()
            }
        }

        if ($Fields.Count -eq 0) {
            $Fields['displayName'] = $Value
            $Fields['parseStatus'] = 'Raw value - field parsing failed'
        }

        $Result += [PSCustomObject]$Fields
    }

    return @($Result)
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

function Get-ExternalValidationResult {
    param(
        [Parameter(Mandatory)]$User,
        [Parameter(Mandatory)][string]$ItemsUri,
        [Parameter(Mandatory)][string]$ExternalItemIdPrefix,
        [Parameter(Mandatory)][string]$CertificationPropertyName,
        [Parameter(Mandatory)][string]$AppliedSkillsPropertyName,
        [Parameter(Mandatory)][string]$AppliedSkillsAwardsPropertyName
    )

    if ([string]::IsNullOrWhiteSpace($User.EntraObjectId)) {
        throw "EntraObjectId is missing in the CSV for $($User.UserPrincipalName)."
    }

    $SanitizedObjectId = $User.EntraObjectId -replace '[^A-Za-z0-9]', ''
    $ItemId = "$ExternalItemIdPrefix$SanitizedObjectId"
    $Item = Invoke-MgGraphRequest `
        -Method GET `
        -Uri "$ItemsUri/$ItemId" `
        -OutputType PSObject `
        -ErrorAction Stop

    $Properties = Get-OptionalPropertyValue $Item 'properties'
    $CertValues = Get-OptionalPropertyValue $Properties $CertificationPropertyName
    $AppliedValues = Get-OptionalPropertyValue $Properties $AppliedSkillsPropertyName
    $AwardValues = Get-OptionalPropertyValue $Properties $AppliedSkillsAwardsPropertyName

    return [PSCustomObject]@{
        ExternalItemId      = $ItemId
        Certifications      = @(ConvertFrom-ConnectorJsonCollection $CertValues)
        AppliedSkillsCustom = @(ConvertFrom-AppliedSkillTextCollection $AppliedValues)
        AppliedSkillsAwards = @(ConvertFrom-ConnectorJsonCollection $AwardValues)
        Error               = $null
    }
}

function Get-ProfileValidationResult {
    param(
        [Parameter(Mandatory)]$User,
        [Parameter(Mandatory)][string]$GraphBeta,
        [Parameter(Mandatory)][string]$AccessToken
    )

    $EncodedUser = [Uri]::EscapeDataString($User.UserPrincipalName)
    $BaseUri = "$($GraphBeta.TrimEnd('/'))/users/$EncodedUser/profile"

    $Certifications = @()
    $Awards = @()
    $Errors = @()

    try { $Certifications = @(Get-ProfileGraphCollection "$BaseUri/certifications" $AccessToken) }
    catch { $Errors += "certifications: $($_.Exception.Message)" }

    try { $Awards = @(Get-ProfileGraphCollection "$BaseUri/awards" $AccessToken) }
    catch { $Errors += "awards: $($_.Exception.Message)" }

    return [PSCustomObject]@{
        Certifications = $Certifications
        Awards          = $Awards
        Error           = if ($Errors.Count -eq 0) { $null } else { $Errors -join ' | ' }
    }
}

function Get-ProfileFacetKey {
    param(
        [Parameter(Mandatory)]$Item,
        [Parameter(Mandatory)][ValidateSet('Certification', 'Award')][string]$Facet
    )

    if ($Facet -eq 'Certification') {
        $Id = [string](Get-OptionalPropertyValue $Item 'certificationId')
        if (-not [string]::IsNullOrWhiteSpace($Id)) {
            return 'id:' + $Id.Trim().ToLowerInvariant()
        }
    }

    $Name = [string](Get-OptionalPropertyValue $Item 'displayName')
    $NormalizedName = $Name.Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', ''
    $NormalizedName = $NormalizedName.ToLowerInvariant() -replace '[^a-z0-9]', ''
    return 'name:' + $NormalizedName
}

function Get-MaterializationState {
    param([Parameter(Mandatory)]$Result)

    if ($Result.ExternalError -or $Result.ProfileError) { return 'Error' }

    $ExpectedCertifications = @($Result.External.Certifications)
    $ExpectedAwards = @($Result.External.AppliedSkillsAwards)
    $ActualCertifications = @($Result.Profile.Certifications)
    $ActualAwards = @($Result.Profile.Awards)

    if ($ExpectedCertifications.Count -eq 0 -and $ExpectedAwards.Count -eq 0) {
        if ($ActualCertifications.Count -gt 0 -or $ActualAwards.Count -gt 0) {
            return 'OtherSourceData'
        }
        return 'NoData'
    }

    $ActualCertificationKeys = @{}
    foreach ($Item in $ActualCertifications) {
        $ActualCertificationKeys[(Get-ProfileFacetKey $Item 'Certification')] = $true
    }

    $ActualAwardKeys = @{}
    foreach ($Item in $ActualAwards) {
        $ActualAwardKeys[(Get-ProfileFacetKey $Item 'Award')] = $true
    }

    foreach ($Item in $ExpectedCertifications) {
        if (-not $ActualCertificationKeys.ContainsKey((Get-ProfileFacetKey $Item 'Certification'))) {
            return 'Pending'
        }
    }

    foreach ($Item in $ExpectedAwards) {
        if (-not $ActualAwardKeys.ContainsKey((Get-ProfileFacetKey $Item 'Award'))) {
            return 'Pending'
        }
    }

    return 'Materialized'
}

function Show-UserDetail {
    param([Parameter(Mandatory)]$Result)

    Write-Section "USER - $($Result.UserPrincipalName)"
    [PSCustomObject]@{
        UserPrincipalName         = $Result.UserPrincipalName
        EntraObjectId             = $Result.EntraObjectId
        ExternalItemId            = $Result.External.ExternalItemId
        ExternalCertifications    = $Result.ExternalCertifications
        ExternalAppliedSkills     = $Result.ExternalAppliedSkillsCustom
        ExternalAppliedAwards     = $Result.ExternalAppliedSkillsAwards
        ProfileCertifications     = $Result.ProfileCertifications
        ProfileAwards             = $Result.ProfileAwards
        Materialization           = $Result.Materialization
    } | Format-List

    if ($Result.ExternalError) {
        Write-Warning "External item validation failed: $($Result.ExternalError)"
    }
    if ($Result.ProfileError) {
        Write-Warning "Profile API validation failed: $($Result.ProfileError)"
    }

    Write-Host "Connector item - certifications" -ForegroundColor Green
    if ($Result.External.Certifications.Count -eq 0) { Write-Host "  (none)" }
    else {
        $Result.External.Certifications |
            Select-Object certificationId, displayName, issuedDate, endDate, issuingAuthority |
            Format-Table -AutoSize -Wrap
    }

    Write-Host "Connector item - Microsoft Applied Skills custom property" -ForegroundColor Green
    if ($Result.External.AppliedSkillsCustom.Count -eq 0) { Write-Host "  (none)" }
    else {
        $Result.External.AppliedSkillsCustom |
            Select-Object credentialType, displayName, credentialId, issuedDate, issuingAuthority |
            Format-Table -AutoSize -Wrap
    }

    Write-Host "Connector item - Applied Skills mapped as awards" -ForegroundColor Green
    if ($Result.External.AppliedSkillsAwards.Count -eq 0) { Write-Host "  (none)" }
    else {
        $Result.External.AppliedSkillsAwards |
            Select-Object displayName, issuedDate, issuingAuthority, webUrl |
            Format-Table -AutoSize -Wrap
    }

    Write-Host "Profile API - certifications" -ForegroundColor Magenta
    if ($Result.Profile.Certifications.Count -eq 0) { Write-Host "  (none or not materialized yet)" }
    else {
        $Result.Profile.Certifications |
            Select-Object id, certificationId, displayName, issuedDate, endDate |
            Format-Table -AutoSize -Wrap
    }

    Write-Host "Profile API - awards" -ForegroundColor Magenta
    if ($Result.Profile.Awards.Count -eq 0) { Write-Host "  (none or not materialized yet)" }
    else {
        $Result.Profile.Awards |
            Select-Object id, displayName, issuedDate, issuingAuthority |
            Format-Table -AutoSize -Wrap
    }
}

function Select-ValidationMode {
    Write-Section 'VALIDATION MODE'
    Write-Host '  [1] Detailed validation for every enabled user'
    Write-Host '  [2] Detailed validation for one user'
    Write-Host '  [3] Summary table for every enabled user'
    Write-Host '  [Q] Quit'

    do {
        $Choice = (Read-Host 'Select an option').Trim().ToUpperInvariant()
    } until ($Choice -in @('1', '2', '3', 'Q'))

    return $Choice
}

try {
    Write-Section 'STEP 99 - Schema 2.4 population validation'

    $ConfigPath = Resolve-OperationalConfigPath $ConfigPath
    $Config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

    if ([string]$Config.SchemaVersion -ne '2.4') {
        throw "Step 99 requires SchemaVersion 2.4. Current value: '$($Config.SchemaVersion)'."
    }

    $Application = Get-RequiredPropertyValue $Config 'Application' 'root'
    $Authentication = Get-RequiredPropertyValue $Config 'Authentication' 'root'
    $Graph = Get-RequiredPropertyValue $Config 'MicrosoftGraph' 'root'
    $Connector = Get-RequiredPropertyValue $Config 'Connector' 'root'
    $Schema = Get-RequiredPropertyValue $Config 'Schema' 'root'
    $UserSource = Get-RequiredPropertyValue $Config 'UserSource' 'root'
    $FieldMapping = Get-RequiredPropertyValue $Config 'FieldMapping' 'root'

    $TenantId = [string](Get-RequiredPropertyValue $Application 'TenantId' 'Application')
    $ClientId = [string](Get-RequiredPropertyValue $Application 'ClientId' 'Application')
    $ClientSecret = [string](Get-RequiredPropertyValue $Authentication 'ClientSecret' 'Authentication')
    $GraphV1 = [string](Get-RequiredPropertyValue $Graph 'GraphV1' 'MicrosoftGraph')
    $GraphBeta = [string](Get-RequiredPropertyValue $Graph 'GraphBeta' 'MicrosoftGraph')
    $ConnectionId = [string](Get-RequiredPropertyValue $Connector 'ConnectionId' 'Connector')

    $CsvPathValue = Get-OptionalPropertyValue $UserSource 'CsvPath'
    if ([string]::IsNullOrWhiteSpace([string]$CsvPathValue)) {
        $CsvConfig = Get-RequiredPropertyValue $UserSource 'Csv' 'UserSource'
        $CsvPathValue = Get-RequiredPropertyValue $CsvConfig 'Path' 'UserSource.Csv'
    }
    $CsvPath = Resolve-OperationalPath ([string]$CsvPathValue)

    $CertificationProperty = Get-RequiredPropertyValue $Schema 'CertificationProperty' 'Schema'
    $CertificationPropertyName = [string](Get-RequiredPropertyValue $CertificationProperty 'Name' 'Schema.CertificationProperty')

    $AppliedSkillsProperty = Get-OptionalPropertyValue $Schema 'AppliedSkillsProperty'
    $AppliedSkillsPropertyName = if ($null -eq $AppliedSkillsProperty) {
        'microsoftAppliedSkills'
    } else { [string](Get-RequiredPropertyValue $AppliedSkillsProperty 'Name' 'Schema.AppliedSkillsProperty') }

    $AppliedAwardsProperty = Get-OptionalPropertyValue $Schema 'AppliedSkillsAwardsProperty'
    $AppliedAwardsPropertyName = if ($null -eq $AppliedAwardsProperty) {
        'appliedSkillsAwards'
    } else { [string](Get-RequiredPropertyValue $AppliedAwardsProperty 'Name' 'Schema.AppliedSkillsAwardsProperty') }

    $Synchronization = Get-OptionalPropertyValue $Config 'Synchronization'
    $PrefixValue = Get-OptionalPropertyValue $Synchronization 'ExternalItemIdPrefix'
    $ExternalItemIdPrefix = if ([string]::IsNullOrWhiteSpace([string]$PrefixValue)) { 'u' } else { [string]$PrefixValue }

    $Users = @(Import-EnabledCredentialUsers -CsvPath $CsvPath -FieldMapping $FieldMapping)
    $Mode = Select-ValidationMode
    if ($Mode -eq 'Q') { return }

    $SelectedUsers = $Users
    if ($Mode -eq '2') {
        Write-Host ''
        for ($Index = 0; $Index -lt $Users.Count; $Index++) {
            Write-Host "  [$($Index + 1)] $($Users[$Index].UserPrincipalName)"
        }

        do {
            $UserChoice = (Read-Host 'Enter a row number or exact UPN').Trim()
            $Number = 0
            if ([int]::TryParse($UserChoice, [ref]$Number) -and $Number -ge 1 -and $Number -le $Users.Count) {
                $Selected = $Users[$Number - 1]
            }
            else {
                $Selected = $Users | Where-Object UserPrincipalName -IEQ $UserChoice | Select-Object -First 1
            }
        } until ($null -ne $Selected)

        $SelectedUsers = @($Selected)
    }

    Write-Host "Configuration            : $ConfigPath"
    Write-Host "Schema version           : $($Config.SchemaVersion)"
    Write-Host "Connection ID            : $ConnectionId"
    Write-Host "CSV                      : $CsvPath"
    Write-Host "Selected enabled users   : $($SelectedUsers.Count)"

    $ItemsUri = "$($GraphV1.TrimEnd('/'))/external/connections/$ConnectionId/items"
    $ExternalResults = @{}

    Write-Section 'LAYER 1 - Connector externalItem population'
    Connect-ConnectorApplication -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret

    foreach ($User in $SelectedUsers) {
        Write-Host "Reading connector item: $($User.UserPrincipalName)"
        try {
            $ExternalResults[$User.UserPrincipalName] = Get-ExternalValidationResult `
                -User $User `
                -ItemsUri $ItemsUri `
                -ExternalItemIdPrefix $ExternalItemIdPrefix `
                -CertificationPropertyName $CertificationPropertyName `
                -AppliedSkillsPropertyName $AppliedSkillsPropertyName `
                -AppliedSkillsAwardsPropertyName $AppliedAwardsPropertyName
        }
        catch {
            $ExternalResults[$User.UserPrincipalName] = [PSCustomObject]@{
                ExternalItemId      = $null
                Certifications      = @()
                AppliedSkillsCustom = @()
                AppliedSkillsAwards = @()
                Error               = $_.Exception.Message
            }
        }
    }

    Write-Section 'LAYER 2 - Microsoft 365 Profile API materialization'
    Clear-GraphConnection
    $ProfileAccessToken = Get-ProfileValidationAccessToken -TenantId $TenantId
    $ProfileResults = @{}

    foreach ($User in $SelectedUsers) {
        Write-Host "Reading profile facets: $($User.UserPrincipalName)"
        $ProfileResults[$User.UserPrincipalName] = Get-ProfileValidationResult `
            -User $User `
            -GraphBeta $GraphBeta `
            -AccessToken $ProfileAccessToken
    }

    $Results = @(
        foreach ($User in $SelectedUsers) {
            $External = $ExternalResults[$User.UserPrincipalName]
            $Profile = $ProfileResults[$User.UserPrincipalName]

            $Row = [PSCustomObject]@{
                UserPrincipalName            = $User.UserPrincipalName
                EntraObjectId                = $User.EntraObjectId
                External                     = $External
                Profile                      = $Profile
                ExternalCertifications       = $External.Certifications.Count
                ExternalAppliedSkillsCustom  = $External.AppliedSkillsCustom.Count
                ExternalAppliedSkillsAwards  = $External.AppliedSkillsAwards.Count
                ProfileCertifications        = $Profile.Certifications.Count
                ProfileAwards                = $Profile.Awards.Count
                ExternalError                = $External.Error
                ProfileError                 = $Profile.Error
                Materialization              = $null
            }
            $Row.Materialization = Get-MaterializationState $Row
            $Row
        }
    )

    if ($Mode -in @('1', '2')) {
        foreach ($Result in $Results) { Show-UserDetail $Result }
    }
    else {
        Write-Section 'SCHEMA POPULATION SUMMARY'
        $Results |
            Select-Object `
                UserPrincipalName,
                @{N='Ext Cert';E={$_.ExternalCertifications}},
                @{N='Ext Applied';E={$_.ExternalAppliedSkillsCustom}},
                @{N='Ext Awards';E={$_.ExternalAppliedSkillsAwards}},
                @{N='Profile Cert';E={$_.ProfileCertifications}},
                @{N='Profile Awards';E={$_.ProfileAwards}},
                Materialization |
            Format-Table -AutoSize

        Write-Host ''
        [PSCustomObject]@{
            Users                       = $Results.Count
            ExternalCertifications      = ($Results | Measure-Object ExternalCertifications -Sum).Sum
            ExternalAppliedSkillsCustom = ($Results | Measure-Object ExternalAppliedSkillsCustom -Sum).Sum
            ExternalAppliedSkillsAwards = ($Results | Measure-Object ExternalAppliedSkillsAwards -Sum).Sum
            ProfileCertifications       = ($Results | Measure-Object ProfileCertifications -Sum).Sum
            ProfileAwards               = ($Results | Measure-Object ProfileAwards -Sum).Sum
            Materialized                 = @($Results | Where-Object Materialization -EQ 'Materialized').Count
            Pending                      = @($Results | Where-Object Materialization -EQ 'Pending').Count
            OtherSourceData              = @($Results | Where-Object Materialization -EQ 'OtherSourceData').Count
            NoData                       = @($Results | Where-Object Materialization -EQ 'NoData').Count
            Errors                       = @($Results | Where-Object Materialization -EQ 'Error').Count
        } | Format-List

        $FailedResults = @($Results | Where-Object Materialization -EQ 'Error')
        if ($FailedResults.Count -gt 0) {
            Write-Section 'VALIDATION ERRORS'
            $FailedResults |
                Select-Object UserPrincipalName, ExternalError, ProfileError |
                Format-List
        }
    }

    Write-Host ''
    Write-Host "Materialized means every item from this connector was found in the shared Profile API facets." -ForegroundColor DarkGray
    Write-Host "OtherSourceData means this connector has no items but the shared profile contains data from another source." -ForegroundColor DarkGray
    Write-Host "Pending means one or more connector items were not found in the shared profile yet." -ForegroundColor DarkGray
}
catch {
    Write-Host ''
    Write-Host 'SCRIPT FAILED' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    throw
}
finally {
    if ($script:GraphConnected) {
        Clear-GraphConnection
    }
}
