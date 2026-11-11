<#
.SYNOPSIS
  Creates an Azure API connection (Microsoft.Web/connections) for a managed connector and prints the
  portal link where the account owner authorizes it with the target account.
  Defaults come from connections.json, if it exists ($env:M365_BRIDGE_CONFIG, ~/.m365-bridge/connections.json,
  or the folder above scripts\).
.EXAMPLE
  .\New-M365Connection.ps1 -Api office365users
  .\New-M365Connection.ps1 -Api teams -ResourceGroup rg-m365-bridge
#>
param(
    [Parameter(Mandatory)][ValidateSet('office365', 'teams', 'office365users', 'sharepointonline', 'onedriveforbusiness')][string]$Api,
    [string]$ResourceGroup,
    [string]$SubscriptionId,
    [string]$Location,
    [string]$Name = "m365bridge-$Api",
    [string]$HomeTenantId
)
$ErrorActionPreference = 'Stop'
$cfgFile = @($env:M365_BRIDGE_CONFIG, (Join-Path $HOME '.m365-bridge/connections.json'), (Join-Path (Split-Path $PSScriptRoot -Parent) 'connections.json')) |
    Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
$cfg = if ($cfgFile) { Get-Content $cfgFile -Raw | ConvertFrom-Json } else { $null }
if (-not $ResourceGroup) { $ResourceGroup = $cfg.resourceGroup }
if (-not $SubscriptionId) { $SubscriptionId = $cfg.subscriptionId }
if (-not $Location) { $Location = if ($cfg.location) { $cfg.location } else { 'westeurope' } }
if (-not $HomeTenantId) { $HomeTenantId = $cfg.homeTenantId }
if (-not $ResourceGroup -or -not $SubscriptionId) { throw "Pass -ResourceGroup and -SubscriptionId, or set them in connections.json." }

$displayName = if ($cfg.account) { "M365 Connector Bridge $Api ($($cfg.account))" } else { "M365 Connector Bridge $Api" }
$props = @{
    location   = $Location
    properties = @{
        displayName = $displayName
        api         = @{ id = "/subscriptions/$SubscriptionId/providers/Microsoft.Web/locations/$Location/managedApis/$Api" }
    }
} | ConvertTo-Json -Depth 5 -Compress
$tmp = New-TemporaryFile
Set-Content $tmp $props -Encoding utf8
try {
    az resource create --subscription $SubscriptionId -g $ResourceGroup --resource-type Microsoft.Web/connections -n $Name --properties "@$tmp" --is-full-object --query "{name:name,status:properties.overallStatus}" -o tsv
}
finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
$id = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/connections/$Name"
$tenantPart = if ($HomeTenantId) { "@$HomeTenantId" } else { '' }
"Authorize: https://portal.azure.com/#$tenantPart/resource$id/edit"
"Id: $id"
