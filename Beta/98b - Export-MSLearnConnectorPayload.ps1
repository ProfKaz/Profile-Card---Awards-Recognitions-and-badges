#requires -Version 7.0
<#
.SYNOPSIS
    Step 98b - Exports connector externalItems for payload diagnostics.
.DESCRIPTION
    Read-only Graph diagnostic. Resolves users and externalItem IDs from the
    operational CSV and JSON configuration. Exports the complete externalItem,
    decoded certifications, JSON parse results and a run manifest.
    Does not change the connector, schema, Profile API or local configuration.
    Credentials and configuration are never included in the exported files.
    This is a JSON parsing check, not a complete Microsoft Graph schema validator.
.EXAMPLE
    & '.\98b - Export-MSLearnConnectorPayload.ps1' -UserPrincipalName 'enieto@unlimitech.ai','p-gballadares@unlimitech.ai'
.EXAMPLE
    & '.\Beta\98b - Export-MSLearnConnectorPayload.ps1' -ConfigPath '.\Config\MSLearnPeopleConnector.json' -UserPrincipalName 'enieto@unlimitech.ai'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$UserPrincipalName,
    [string]$ConfigPath,
    [string]$OutputDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-OptionalValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
}
function Get-RequiredValue {
    param($Object, [string]$Name)
    $value = Get-OptionalValue $Object $Name
    if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
        throw "Missing required configuration value: $Name"
    }
    return $value
}
function Resolve-LocalPath {
    param([string]$Path, [string]$Base)
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $Base $Path))
}
function Save-Json {
    param($Value, [string]$Path)
    ConvertTo-Json -InputObject $Value -Depth 100 |
        Set-Content -LiteralPath $Path -Encoding utf8
}

$connected = $false
try {
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $candidates = @(
            (Join-Path $PSScriptRoot 'Config/MSLearnPeopleConnector.json'),
            (Join-Path (Split-Path $PSScriptRoot -Parent) 'Config/MSLearnPeopleConnector.json'),
            (Join-Path (Get-Location).Path 'Config/MSLearnPeopleConnector.json')
        )
        $ConfigPath = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
            throw 'Operational configuration not found. Supply -ConfigPath.'
        }
    }
    $ConfigPath = Resolve-LocalPath $ConfigPath (Get-Location).Path
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
    $operationalRoot = Split-Path (Split-Path $ConfigPath -Parent) -Parent
    $application = Get-RequiredValue $cfg 'Application'
    $authentication = Get-RequiredValue $cfg 'Authentication'
    $graph = Get-RequiredValue $cfg 'MicrosoftGraph'
    $connector = Get-RequiredValue $cfg 'Connector'
    $source = Get-RequiredValue $cfg 'UserSource'
    $mapping = Get-OptionalValue $cfg 'FieldMapping'
    if ($null -eq $mapping) { $mapping = Get-RequiredValue $source 'FieldMapping' }
    $csvPath = Get-OptionalValue $source 'CsvPath'
    $csvConfig = Get-OptionalValue $source 'Csv'
    if ([string]::IsNullOrWhiteSpace([string]$csvPath)) {
        $csvPath = Get-RequiredValue $csvConfig 'Path'
    }
    $csvPath = Resolve-LocalPath ([string]$csvPath) $operationalRoot
    $upnField = [string](Get-RequiredValue $mapping 'UserPrincipalName')
    $idField = [string](Get-RequiredValue $mapping 'EntraObjectId')
    $header = Get-Content -LiteralPath $csvPath -TotalCount 1 -Encoding utf8
    $delimiter = $null
    foreach ($candidate in @(',', ';', [string][char]9, '|')) {
        $names = @($header -split [regex]::Escape($candidate) |
            ForEach-Object { $_.Trim().Trim('"').TrimStart([char]0xFEFF) })
        if ($upnField -in $names -and $idField -in $names) {
            $delimiter = [char]$candidate
            break
        }
    }
    if ($null -eq $delimiter) { throw 'Cannot detect CSV delimiter or mapped user columns.' }
    $rows = @(Import-Csv -LiteralPath $csvPath -Delimiter $delimiter -Encoding utf8)
    # Explicitly requested users may be exported even if their CSV row is disabled.
    $targets = @(
        foreach ($upn in ($UserPrincipalName | Select-Object -Unique)) {
            $matches = @($rows | Where-Object { ([string]$_.$upnField).Trim() -ieq $upn.Trim() })
            if ($matches.Count -ne 1) { throw "Expected one CSV row for $upn; found $($matches.Count)." }
            $objectId = ([string]$matches[0].$idField).Trim()
            $parsedId = [guid]::Empty
            if (-not [guid]::TryParse($objectId, [ref]$parsedId)) { throw "Invalid EntraObjectId for $upn." }
            [pscustomobject]@{ UPN = $upn.Trim(); ObjectId = $objectId }
        }
    )
    $prefix = Get-OptionalValue (Get-OptionalValue $cfg 'Synchronization') 'ExternalItemIdPrefix'
    if ([string]::IsNullOrWhiteSpace([string]$prefix)) { $prefix = 'u' }
    $certProperty = [string](Get-RequiredValue (Get-RequiredValue (Get-RequiredValue $cfg 'Schema') 'CertificationProperty') 'Name')
    $connectionId = [string](Get-RequiredValue $connector 'ConnectionId')
    $graphV1 = ([string](Get-RequiredValue $graph 'GraphV1')).TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
        $OutputDirectory = Join-Path $operationalRoot 'Reports/ConnectorPayload'
    }
    $OutputDirectory = Resolve-LocalPath $OutputDirectory (Get-Location).Path
    $runDirectory = Join-Path $OutputDirectory ((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmssZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null

    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $tenantId = [string](Get-RequiredValue $application 'TenantId')
    $clientId = [string](Get-RequiredValue $application 'ClientId')
    $secret = ConvertTo-SecureString ([string](Get-RequiredValue $authentication 'ClientSecret')) -AsPlainText -Force
    $credential = [pscredential]::new($clientId, $secret)
    Connect-MgGraph -TenantId $tenantId -ClientSecretCredential $credential -ContextScope Process -NoWelcome
    $connected = $true
    $results = @(
        foreach ($target in $targets) {
            $itemId = [string]$prefix + ($target.ObjectId -replace '[^A-Za-z0-9]', '')
            $uri = "$graphV1/external/connections/$([uri]::EscapeDataString($connectionId))/items/$([uri]::EscapeDataString($itemId))"
            $stem = $target.UPN -replace '[^A-Za-z0-9@._-]', '_'
            try {
                $item = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject -ErrorAction Stop
                $rawPath = Join-Path $runDirectory "$stem-externalItem.json"
                Save-Json $item $rawPath
                $properties = Get-RequiredValue $item 'properties'
                $values = @(Get-OptionalValue $properties $certProperty)
                $decoded = [Collections.Generic.List[object]]::new()
                $checks = @(
                    for ($index = 0; $index -lt $values.Count; $index++) {
                        $value = $values[$index]
                        $errorText = $null
                        try {
                            if ($value -isnot [string]) { throw 'Collection element is not a string.' }
                            $object = ConvertFrom-Json -InputObject $value -ErrorAction Stop
                            if ($object -isnot [pscustomobject]) { throw 'JSON value is not an object.' }
                            $decoded.Add($object)
                        }
                        catch { $errorText = $_.Exception.Message }
                        [pscustomobject]@{
                            Index = $index
                            ValidJsonObjectString = ($null -eq $errorText)
                            Utf8Bytes = [Text.Encoding]::UTF8.GetByteCount([string]$value)
                            Error = $errorText
                        }
                    }
                )
                Save-Json ($decoded.ToArray()) (Join-Path $runDirectory "$stem-certifications-decoded.json")
                Save-Json $checks (Join-Path $runDirectory "$stem-json-checks.json")
                $invalid = @($checks | Where-Object { -not $_.ValidJsonObjectString }).Count
                [pscustomobject]@{
                    UserPrincipalName = $target.UPN
                    ExternalItemId = $itemId
                    Status = 'Exported'
                    CertificationStrings = $values.Count
                    InvalidJsonElements = $invalid
                    ExternalItemSha256 = (Get-FileHash -LiteralPath $rawPath -Algorithm SHA256).Hash
                    Error = $null
                }
            }
            catch {
                [pscustomobject]@{
                    UserPrincipalName = $target.UPN
                    ExternalItemId = $itemId
                    Status = 'Failed'
                    Error = $_.Exception.Message
                }
            }
        }
    )
    Save-Json ([ordered]@{
        ScriptVersion = '1.0.0'
        ExportedUtc = (Get-Date).ToUniversalTime().ToString('o')
        ConnectionId = $connectionId
        CertificationProperty = $certProperty
        Results = $results
    }) (Join-Path $runDirectory 'manifest.json')
    $results | Format-Table UserPrincipalName, Status, CertificationStrings, InvalidJsonElements -AutoSize
    Write-Host "Evidence directory: $runDirectory"
    if (@($results | Where-Object Status -eq 'Failed').Count -gt 0) {
        throw 'One or more exports failed. See manifest.json for details.'
    }
}
finally {
    if ($connected) { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null }
}
