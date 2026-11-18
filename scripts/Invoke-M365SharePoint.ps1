<#
.SYNOPSIS
  SharePoint REST (GET only) as the target account, through the Azure API connection "sharepoint"
  (SharePoint connector, "Send an HTTP request to SharePoint") from connections.json - for local Claude Code.

.DESCRIPTION
  local az login (home tenant account) -> ARM POST <connection>/dynamicInvoke -> connector operation
  /datasets/{site URL, URL-encoded twice}/httprequest -> https://<site>/_api/... signed in as the target account.

  Covers SharePoint sites AND OneDrive:
    _api/search/query?querytext='...'          search in all sites and OneDrives the account can open
    _api/v2.0/shares/u!<base64url>/driveItem   any file / folder / library by its URL or sharing link
    _api/v2.0/drives/{id}/items/{id}/children  OneDrive API (the same as Graph drives/...)
    _api/web/...                               classic SharePoint REST
  One site (the tenant root) works for search and for v2.0/shares of every site and every OneDrive.

  READ-ONLY: this script sends GET requests only. Results are limited to what the target account may
  open (search results are security-trimmed; other paths answer 403 / 404).

  Needs connections.json with "sharepoint" (and "sharepointRoot" = https://<tenant>.sharepoint.com, or the
  "users" connection, used once to find it).

.PARAMETER Uri
  "_api/..." (relative to -Site) or a full https://<site>/_api/... URL (for example an @odata.nextLink).
.PARAMETER Site
  The site the request is sent to. Default: the site part of a full -Uri, else sharepointRoot.
.PARAMETER All
  Follow @odata.nextLink (v2.0 lists, up to -MaxPages) and return all "value" items.
.PARAMETER Raw
  Return PowerShell objects instead of JSON text.

.EXAMPLE
  .\Invoke-M365SharePoint.ps1 "_api/search/query?querytext='budget filetype:xlsx'&rowlimit=10"
.EXAMPLE
  .\Invoke-M365SharePoint.ps1 '_api/v2.0/drives?$select=id,name' -Site https://contoso.sharepoint.com/sites/Marketing
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Uri,
    [string]$Site,
    [switch]$All,
    [int]$MaxPages = 10,
    [switch]$Raw
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

# ---------------------------------------------------------------- config: $env:M365_BRIDGE_CONFIG, then ~/.m365-bridge/connections.json, then the folder above scripts\
$cfgFile = @($env:M365_BRIDGE_CONFIG, (Join-Path $HOME '.m365-bridge/connections.json'), (Join-Path (Split-Path $PSScriptRoot -Parent) 'connections.json')) |
    Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $cfgFile) { throw "No connections.json. Copy connections.example.json to $(Join-Path $HOME '.m365-bridge/connections.json') (or set M365_BRIDGE_CONFIG) and fill in the connection ids." }
$cfg = Get-Content $cfgFile -Raw | ConvertFrom-Json
$sub = $cfg.subscriptionId
if (-not $sub -or -not $cfg.sharepoint) { throw "$cfgFile needs subscriptionId and sharepoint (the SharePoint connection id). Create it with New-M365Connection.ps1 -Api sharepointonline." }

# ---------------------------------------------------------------- ARM token (az login, home tenant) - kept in memory only
$script:armToken = $null
function Get-ArmToken {
    if (-not $script:armToken) {
        $t = az account get-access-token --resource https://management.azure.com --subscription $sub --query accessToken -o tsv 2>$null
        if (-not $t) { throw "No Azure token. Run 'az login' with a home tenant account that can use subscription $sub, then retry." }
        $script:armToken = $t
    }
    $script:armToken
}

function Invoke-Dynamic([string]$connectionId, [hashtable]$req) {
    $json = @{ request = $req } | ConvertTo-Json -Depth 30 -Compress
    for ($i = 1; ; $i++) {
        try {
            $r = Invoke-RestMethod -Method POST -Uri "https://management.azure.com$connectionId/dynamicInvoke?api-version=2016-06-01" `
                -Headers @{ Authorization = "Bearer $(Get-ArmToken)" } -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json))
        }
        catch {
            if (-not $_.Exception.Response -and $i -lt 4) { Start-Sleep -Seconds (5 * $i); continue }   # network failure: GET only, safe to repeat
            throw
        }
        $code = "$($r.response.statusCode)"
        $num = 0; if (-not [int]::TryParse($code, [ref]$num)) { try { $num = [int][Net.HttpStatusCode]$code } catch { $num = 0 } }
        if (($num -eq 429 -or $num -ge 500) -and $i -lt 4) { Start-Sleep -Seconds (5 * $i); continue }
        return @{ num = $num; code = $code; body = $r.response.body }
    }
}

# ---------------------------------------------------------------- the site to call: -Site, the site part of a full URL, sharepointRoot, or found once through "users"
function Get-SharePointRoot {
    if ($cfg.sharepointRoot) { return $cfg.sharepointRoot.TrimEnd('/') }
    if (-not $cfg.users) { throw "Add `"sharepointRoot`": `"https://<tenant>.sharepoint.com`" to $cfgFile (or a `"users`" connection to find it)." }
    $r = Invoke-Dynamic $cfg.users ([ordered]@{ method = 'POST'; path = '/codeless/httprequest'; headers = [ordered]@{ Uri = 'https://graph.microsoft.com/v1.0/me/drive?$select=webUrl'; Method = 'GET' } })
    if ($r.num -ne 200 -or -not $r.body.webUrl) { throw "Could not find the SharePoint root through the users connection (HTTP $($r.code)). Add `"sharepointRoot`" to $cfgFile." }
    $h = ([uri]$r.body.webUrl).Host -replace '-my\.sharepoint\.', '.sharepoint.'
    Write-Warning "Add `"sharepointRoot`": `"https://$h`" to $cfgFile to save one call per run."
    return "https://$h"
}

function Split-SpUrl([string]$u) {
    if ($u -match '^(https://[^/]+(?:/[^?]*?)?)/(_api/.*)$') { return @($Matches[1], $Matches[2]) }
    if ($u -match '^https://') { throw "A full URL must contain /_api/: $u" }
    return @($null, $u.TrimStart('/'))
}

function Invoke-Sp([string]$u) {
    $parts = Split-SpUrl $u
    $s = if ($parts[0]) { $parts[0] } elseif ($Site) { $Site.TrimEnd('/') } else { $script:root }
    $dataset = [uri]::EscapeDataString([uri]::EscapeDataString($s))       # the connector needs the site URL encoded TWICE (once -> 404)
    $req = [ordered]@{
        method = 'POST'; path = "/datasets/$dataset/httprequest"
        body   = [ordered]@{ method = 'GET'; uri = $parts[1]; headers = @{ Accept = 'application/json;odata=nometadata' } }
    }
    $r = Invoke-Dynamic $cfg.sharepoint $req
    if ($r.num -ge 300 -and $r.num -lt 400) {
        throw "SharePoint answered with a redirect (HTTP $($r.num)) for $($parts[1]). The connector drops the redirect target: for file content use the item's @content.downloadUrl (Get-M365File.ps1 does this)."
    }
    if ($r.num -lt 200 -or $r.num -gt 299) {
        $msg = $r.body | ConvertTo-Json -Depth 5 -Compress
        if ($msg.Length -gt 600) { $msg = $msg.Substring(0, 600) + '...' }
        $hint = if ($r.num -eq 400 -and $msg -match 'Unexpected response from the service') { "`n(The connector hides SharePoint's own error. Usual causes: no such file / folder (SharePoint's 404 arrives as this 400), the account may not open it, or the URL is a bare site URL, which has no item - use Get-M365File.ps1 -Libraries.)" } else { '' }
        throw "SharePoint via sharepoint connection: HTTP $($r.num) $($r.code) for GET $($parts[1]) on $s`n$msg$hint"
    }
    return $r.body
}

# ---------------------------------------------------------------- run
$script:root = if ($Site -or $Uri -match '^https://') { $null } else { Get-SharePointRoot }

if ($All) {
    $items = [Collections.Generic.List[object]]::new()
    $u = $Uri
    for ($p = 0; $u -and $p -lt $MaxPages; $p++) {
        $b = Invoke-Sp $u
        foreach ($v in @($b.value)) { if ($null -ne $v) { $items.Add($v) } }
        $u = $b.'@odata.nextLink'
        if ($u -and $u -notmatch '^https://') { $u = $null }
    }
    if ($u) { Write-Warning "Stopped after $MaxPages pages; more results exist (raise -MaxPages)." }
    $out = $items.ToArray()
}
else { $out = Invoke-Sp $Uri }

if ($Raw) { return $out }
$out | ConvertTo-Json -Depth 30
