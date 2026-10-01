#requires -Version 7.0
<#
.SYNOPSIS
Preview or remove selected users' externalItems without changing connector schemas.
.DESCRIPTION
Default is preview. Supply -Execute to delete verified items after complete
preflight and backup. -WhatIf is supported. This does not directly delete Profile
API facets or guarantee immediate profile-card propagation.
Known item IDs only; historical prefixes require their operational configurations.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium', DefaultParameterSetName = 'Selected')]
param(
    [Parameter(Mandatory)][string[]]$ConfigPaths,
    [Parameter(Mandatory, ParameterSetName = 'Selected')][string[]]$UserPrincipalName,
    [Parameter(Mandatory, ParameterSetName = 'All')][switch]$AllCsvUsers,
    [string]$ProjectRoot = (Get-Location).Path,
    [string]$ReportDirectory = 'Reports',
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:GraphConnected = $false
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



function Import-CredentialUsers {
    param(
        [Parameter(Mandatory)][string]$CsvPath,
        [Parameter(Mandatory)]$FieldMapping,
        [switch]$IncludeDisabled
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
                ($IncludeDisabled -or $_.Enabled) -and -not [string]::IsNullOrWhiteSpace($_.UserPrincipalName)
            }
    )

    if ($Users.Count -eq 0) {
        throw "The CSV contains no selected users."
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



function Resolve-ProjectPath {
    param([string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) { return $Path }
    return Join-Path $ProjectRoot $Path
}
function Test-NotFound {
    param($Record)
    $Response = Get-OptionalPropertyValue $Record.Exception 'Response'
    $Status = Get-OptionalPropertyValue $Response 'StatusCode'
    if ($null -eq $Status) { $Status = Get-OptionalPropertyValue $Record.Exception 'ResponseStatusCode' }
    return ($null -ne $Status -and [int]$Status -eq 404)
}
function Connect-Entry {
    param($Entry)
    Connect-ConnectorApplication $Entry.Tenant $Entry.Config.Application.ClientId $Entry.Config.Authentication.ClientSecret
}
$Entries = @()
$Plan = [Collections.Generic.List[object]]::new()
$Backups = [Collections.Generic.List[object]]::new()
$Errors = [Collections.Generic.List[object]]::new()
$DeletedCount = 0
try {
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    if ($ConfigPaths.Count -eq 0) { throw 'Select at least one configuration.' }
    if (-not $AllCsvUsers -and @($UserPrincipalName | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -ne $UserPrincipalName.Count) {
        throw 'UserPrincipalName cannot contain empty values.'
    }
    $UserMap = @{}
    foreach ($Path in $ConfigPaths) {
        $Config = Get-Content -LiteralPath (Resolve-ProjectPath $Path) -Raw -Encoding UTF8 | ConvertFrom-Json
        $Tenant = [string](Get-RequiredPropertyValue $Config.Application 'TenantId' 'Application')
        $Connection = [string](Get-RequiredPropertyValue $Config.Connector 'ConnectionId' 'Connector')
        if ($Connection -notmatch '^[A-Za-z0-9]+$') { throw 'Invalid connection ID.' }
        $null = Get-RequiredPropertyValue $Config.Application 'ClientId' 'Application'
        $null = Get-RequiredPropertyValue $Config.Authentication 'ClientSecret' 'Authentication'
        $CsvPath = Get-OptionalPropertyValue $Config.UserSource 'CsvPath'
        if (-not $CsvPath) { $CsvPath = Get-RequiredPropertyValue $Config.UserSource.Csv 'Path' 'UserSource.Csv' }
        # Include disabled rows: maintenance is independent of synchronization eligibility.
        $Users = @(Import-CredentialUsers (Resolve-ProjectPath $CsvPath) $Config.FieldMapping -IncludeDisabled)
        if (-not $AllCsvUsers) {
            foreach ($Upn in $UserPrincipalName) {
                if (@($Users | Where-Object UserPrincipalName -IEQ $Upn.Trim()).Count -ne 1) {
                    throw "Expected exactly one CSV row for $Upn in $Path."
                }
            }
            $Users = @($Users | Where-Object { $_.UserPrincipalName -in @($UserPrincipalName | ForEach-Object { $_.Trim() }) })
        }
        $DuplicateRows = @($Users | Group-Object UserPrincipalName | Where-Object Count -GT 1)
        if ($DuplicateRows.Count) { throw "Duplicate user rows in $Path." }
        foreach ($User in $Users) {
            $Guid = [guid]::Empty
            if (-not [guid]::TryParse($User.EntraObjectId, [ref]$Guid)) { throw "Invalid EntraObjectId for $($User.UserPrincipalName)." }
            $Key = $User.UserPrincipalName.ToLowerInvariant()
            if ($UserMap.ContainsKey($Key) -and $UserMap[$Key] -ne $Guid.ToString()) { throw "Conflicting identity for $Key." }
            $UserMap[$Key] = $Guid.ToString()
        }
        $Entries += [pscustomobject]@{ Config = $Config; Tenant = $Tenant; Connection = $Connection; Users = $Users }
    }
    if (@($Entries.Tenant | Select-Object -Unique).Count -ne 1) { throw 'Configurations must target one tenant.' }
    if (@($Entries | Group-Object Connection | Where-Object Count -GT 1).Count) { throw 'Select each connection only once.' }

    foreach ($Entry in $Entries) {
        try {
            Connect-Entry $Entry
            $Prefix = Get-OptionalPropertyValue $Entry.Config.Synchronization 'ExternalItemIdPrefix'
            if (-not $Prefix) { $Prefix = 'u' }
            $AccountName = Get-RequiredPropertyValue $Entry.Config.Schema.AccountProperty 'Name' 'Schema.AccountProperty'
            foreach ($User in $Entry.Users) {
                # Reproduce the sync script exactly, preserving the CSV object's case.
                $ItemId = "$Prefix$($User.EntraObjectId -replace '[^A-Za-z0-9]', '')"
                $Uri = "https://graph.microsoft.com/v1.0/external/connections/$($Entry.Connection)/items/$([Uri]::EscapeDataString($ItemId))"
                $Row = [pscustomobject]@{
                    UserPrincipalName = $User.UserPrincipalName; EntraObjectId = $User.EntraObjectId
                    ConnectionId = $Entry.Connection; ExternalItemId = $ItemId; Uri = $Uri
                    Status = 'Unverified'; Error = $null
                }
                $Plan.Add($Row)
                try {
                    $Item = Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType PSObject
                    $Account = (Get-RequiredPropertyValue $Item.properties $AccountName 'Item.properties') | ConvertFrom-Json
                    $MappedUpn = [string](Get-OptionalPropertyValue $Account 'userPrincipalName')
                    $MappedId = [string](Get-OptionalPropertyValue $Account 'externalDirectoryObjectId')
                    if ((-not $MappedUpn -and -not $MappedId) -or
                        ($MappedUpn -and $MappedUpn -ine $User.UserPrincipalName) -or
                        ($MappedId -and $MappedId -ine $User.EntraObjectId)) {
                        throw 'External item identity does not match the CSV. No deletion permitted.'
                    }
                    $Backups.Add([pscustomobject]@{
                        UserPrincipalName = $User.UserPrincipalName; ConnectionId = $Entry.Connection
                        ExternalItemId = $ItemId; ExternalItem = $Item
                    })
                    $Row.Status = 'Ready'
                }
                catch {
                    if (Test-NotFound $_) { $Row.Status = 'AlreadyAbsent' }
                    else { $Row.Status = 'ReadFailed'; $Row.Error = $_.Exception.Message; $Errors.Add($Row) }
                }
            }
        }
        catch { $Errors.Add([pscustomobject]@{ ConnectionId = $Entry.Connection; Error = $_.Exception.Message }) }
        finally { Clear-GraphConnection }
    }
    $Plan | Format-Table UserPrincipalName, ConnectionId, ExternalItemId, Status -AutoSize
    $Directory = Resolve-ProjectPath $ReportDirectory
    $null = New-Item -ItemType Directory -Path $Directory -Force -WhatIf:$false
    $Stem = Join-Path $Directory ("ProfileCleanup-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    $BackupPath = "$Stem.backup.json"
    # Complete backup and plan on disk BEFORE any deletion. Never serialize Config.
    [pscustomobject]@{
        CapturedUtc = [DateTime]::UtcNow.ToString('o'); TenantId = $Entries[0].Tenant
        Items = @($Backups.ToArray()); Plan = @($Plan.ToArray()); Errors = @($Errors.ToArray())
    } | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $BackupPath -Encoding UTF8 -WhatIf:$false
    Write-Host "Backup and plan: $BackupPath" -ForegroundColor Green
    if ($Errors.Count) { throw 'Preflight is incomplete. No items were deleted. Review the backup report errors.' }

    if ($Execute) {
        foreach ($Entry in $Entries) {
            try {
                Connect-Entry $Entry
                foreach ($Row in @($Plan | Where-Object { $_.ConnectionId -eq $Entry.Connection -and $_.Status -eq 'Ready' })) {
                    if (-not $PSCmdlet.ShouldProcess("$($Row.UserPrincipalName) / $($Row.ConnectionId) / $($Row.ExternalItemId)", 'Delete verified externalItem')) {
                        $Row.Status = 'Skipped'; continue
                    }
                    try {
                        # Re-read and compare with the snapshot; abort this item if it changed.
                        $Current = Invoke-MgGraphRequest -Method GET -Uri $Row.Uri -OutputType PSObject
                        $Snapshot = @($Backups | Where-Object { $_.ConnectionId -eq $Row.ConnectionId -and $_.ExternalItemId -eq $Row.ExternalItemId })[0].ExternalItem
                        if (($Current | ConvertTo-Json -Depth 80 -Compress) -cne ($Snapshot | ConvertTo-Json -Depth 80 -Compress)) {
                            throw 'Item changed since backup. Run preview again.'
                        }
                        $null = Invoke-MgGraphRequest -Method DELETE -Uri $Row.Uri
                        $Row.Status = 'DeleteAccepted'; $DeletedCount++
                        try {
                            $null = Invoke-MgGraphRequest -Method GET -Uri $Row.Uri -OutputType PSObject
                            $Row.Status = 'DeleteAcceptedStillReadable'
                        }
                        catch {
                            if (Test-NotFound $_) { $Row.Status = 'RemovedAtSource' }
                            else { $Row.Status = 'DeleteAcceptedVerificationFailed'; $Row.Error = $_.Exception.Message }
                        }
                    }
                    catch { $Row.Status = 'DeleteFailed'; $Row.Error = $_.Exception.Message }
                    finally {
                        $Plan | Export-Csv -LiteralPath "$Stem.results.csv" -NoTypeInformation -Encoding UTF8 -WhatIf:$false
                    }
                }
            }
            catch {
                foreach ($Row in @($Plan | Where-Object { $_.ConnectionId -eq $Entry.Connection -and $_.Status -eq 'Ready' })) {
                    $Row.Status = 'ConnectionFailed'; $Row.Error = $_.Exception.Message
                }
            }
            finally { Clear-GraphConnection }
        }
    }
    else { Write-Host 'PREVIEW ONLY. Supply -Execute to delete; -Execute -WhatIf simulates deletion.' -ForegroundColor Yellow }
    $Plan | Export-Csv -LiteralPath "$Stem.results.csv" -NoTypeInformation -Encoding UTF8 -WhatIf:$false
    $Plan | Format-Table UserPrincipalName, ConnectionId, Status, Error -AutoSize -Wrap
    if ($DeletedCount -gt 0) {
        $Earliest = [DateTime]::UtcNow.AddHours(12)
        [pscustomobject]@{
            LastDeletionBatchCompletedUtc = [DateTime]::UtcNow.ToString('o')
            EarliestRecommendedRevalidationUtc = $Earliest.ToString('o')
            AcceptedDeletes = $DeletedCount
            Instruction = 'Keep sync paused at least 12 hours, then verify Profile API and card before syncing only the intended source. This is not a propagation SLA.'
        } | ConvertTo-Json | Set-Content -LiteralPath "$Stem.wait.json" -Encoding UTF8 -WhatIf:$false
        Write-Warning "Keep sync paused. Earliest recommended revalidation UTC: $($Earliest.ToString('o')). Source deletion does not prove profile removal."
    }
    if (@($Plan | Where-Object { $_.Status -match 'Failed|StillReadable' }).Count) { throw "Cleanup has unresolved results. Review $Stem.results.csv." }
}
finally { if ($script:GraphConnected) { Clear-GraphConnection } }
