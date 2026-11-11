<#
.SYNOPSIS
  Microsoft Graph as the target account, through the Azure API connections "mail" (Office 365 Outlook:
  mail, calendar) and "teams" (Microsoft Teams: chats, teams) from connections.json - for local Claude Code.

.DESCRIPTION
  For a tenant that gives no app consent for mail/chats:
  local az login (home tenant account) -> ARM POST <connection>/dynamicInvoke -> the connector's
  "Send an HTTP request" operation -> Graph, signed in as the target account.

  Needs connections.json (see connections.example.json): $env:M365_BRIDGE_CONFIG, else
  ~/.m365-bridge/connections.json, else the folder above scripts\.

  READ-ONLY by default. Anything but GET needs -AllowWrite, and Claude may pass it only after
  the account owner approved that exact action in the chat (drafts, Teams messages).

.PARAMETER Path
  Graph path ("v1.0/me/messages?...") or a full https://graph.microsoft.com/... URL (nextLink, hostedContents).
.PARAMETER Connection
  auto (default: chats/teams/joinedTeams -> teams, everything else -> mail), mail, teams.
.PARAMETER All
  Follow @odata.nextLink (up to -MaxPages) and return all "value" items.
.PARAMETER OutFile
  Save binary content (Teams hostedContents/$value, attachment /$value) to this file.
.PARAMETER Html
  Keep HTML bodies. Default: mail bodies come as text (Prefer header), Teams HTML is turned
  into text with pasted images shown as [image: <url>] (download them with -OutFile).
.PARAMETER Raw
  Return PowerShell objects instead of JSON text.

.EXAMPLE
  .\Invoke-M365Graph.ps1 'v1.0/me/mailFolders/inbox/messages?$top=10&$select=subject,from,receivedDateTime,bodyPreview'
.EXAMPLE
  .\Invoke-M365Graph.ps1 'v1.0/me/chats?$expand=members,lastMessagePreview&$orderby=lastMessagePreview/createdDateTime desc&$top=20'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Path,
    [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')][string]$Method = 'GET',
    [object]$Body,
    [ValidateSet('auto', 'mail', 'teams')][string]$Connection = 'auto',
    [switch]$All,
    [int]$MaxPages = 10,
    [string]$OutFile,
    [switch]$Html,
    [switch]$Raw,
    [switch]$AllowWrite
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

# ---------------------------------------------------------------- config: $env:M365_BRIDGE_CONFIG, then ~/.m365-bridge/connections.json, then the folder above scripts\
$cfgFile = @($env:M365_BRIDGE_CONFIG, (Join-Path $HOME '.m365-bridge/connections.json'), (Join-Path (Split-Path $PSScriptRoot -Parent) 'connections.json')) |
    Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $cfgFile) { throw "No connections.json. Copy connections.example.json to $(Join-Path $HOME '.m365-bridge/connections.json') (or set M365_BRIDGE_CONFIG) and fill in the connection ids." }
$cfg = Get-Content $cfgFile -Raw | ConvertFrom-Json
$sub = $cfg.subscriptionId
$conn = @{ mail = $cfg.mail; teams = $cfg.teams }
if (-not $sub -or -not $conn.mail -or -not $conn.teams) { throw "$cfgFile needs subscriptionId, mail and teams." }
$opPath = @{ mail = '/codeless/httprequest'; teams = '/httprequest' }

if ($Method -ne 'GET' -and -not $AllowWrite) {
    throw "Refused: $Method changes the target account's mailbox/Teams. Run it only after the account owner approved this exact action, with -AllowWrite."
}

# ---------------------------------------------------------------- path rules of the connectors (found 7 Nov 2026)
function ConvertTo-ConnectorUrl([string]$p) {
    $u = if ($p -match '^https?://') { $p } else { 'https://graph.microsoft.com/' + $p.TrimStart('/') }
    $q = $u.IndexOf('?')
    $head = if ($q -lt 0) { $u } else { $u.Substring(0, $q) }
    $tail = if ($q -lt 0) { '' } else { $u.Substring($q) }
    $head = [regex]::Replace($head, "/(\w+)\('([^']*)'\)", '/$1/$2')                                   # mailFolders('inbox') -> mailFolders/inbox
    $head = [regex]::Replace($head, '^(https://graph\.microsoft\.com/(?:v1\.0|beta))/chats/', '$1/me/chats/')   # Teams: first segment must be me|teams|users
    return $head + $tail
}
function Get-ConnectionFor([string]$p) {
    if ($Connection -ne 'auto') { return $Connection }
    if ($p -match '/(chats|teams|joinedTeams|onlineMeetings)(/|\?|$)') { return 'teams' }
    return 'mail'
}

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

function Invoke-Connector([string]$p, [string]$m, [object]$b) {
    $which = Get-ConnectionFor $p
    $headers = [ordered]@{ Uri = (ConvertTo-ConnectorUrl $p); Method = $m }
    if ($which -eq 'mail' -and -not $Html) { $headers.CustomHeader1 = 'Prefer: outlook.body-content-type="text"' }
    $req = [ordered]@{ method = 'POST'; path = $opPath[$which]; headers = $headers }
    if ($m -ne 'GET') { $headers.ContentType = 'application/json' }   # also with no body, e.g. me/messages/{id}/send (else 400 "Empty Content-Type")
    if ($null -ne $b) { $req.body = $b }
    $json = @{ request = $req } | ConvertTo-Json -Depth 30 -Compress
    for ($i = 1; ; $i++) {
        $r = Invoke-RestMethod -Method POST -Uri "https://management.azure.com$($conn[$which])/dynamicInvoke?api-version=2016-06-01" `
            -Headers @{ Authorization = "Bearer $(Get-ArmToken)" } -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json))
        $code = "$($r.response.statusCode)"
        $num = 0; if (-not [int]::TryParse($code, [ref]$num)) { try { $num = [int][Net.HttpStatusCode]$code } catch { $num = 0 } }
        if (($num -eq 429 -or $num -ge 500) -and $i -lt 4) { Start-Sleep -Seconds (5 * $i); continue }
        if ($num -lt 200 -or $num -gt 299) {
            $msg = ($r.response.body | ConvertTo-Json -Depth 5 -Compress)
            if ($msg.Length -gt 600) { $msg = $msg.Substring(0, 600) + '...' }
            throw "Graph via $which connection: HTTP $num $code for $m $p`n$msg"
        }
        return $r.response.body
    }
}

# ---------------------------------------------------------------- Teams HTML -> text (pasted images kept as links)
function ConvertFrom-TeamsHtml([string]$h) {
    if (-not $h) { return $h }
    $t = [regex]::Replace($h, '<img[^>]+src="([^"]+/hostedContents/[^"]+)"[^>]*>', { param($m) "[image: $([Net.WebUtility]::HtmlDecode($m.Groups[1].Value))]" })
    $t = [regex]::Replace($t, '<img[^>]*alt="([^"]*)"[^>]*>', '$1')                       # emoji
    $t = [regex]::Replace($t, '<a [^>]*href="([^"]+)"[^>]*>(.*?)</a>', { param($m) if ($m.Groups[2].Value -eq $m.Groups[1].Value) { $m.Groups[1].Value } else { "$($m.Groups[2].Value) ($($m.Groups[1].Value))" } })
    $t = [regex]::Replace($t, '<(br|/p|/div|/li|/tr|/h\d)[^>]*>', "`n")
    $t = [regex]::Replace($t, '<li[^>]*>', '- ')
    $t = [regex]::Replace($t, '<[^>]+>', '')
    $t = [Net.WebUtility]::HtmlDecode($t)
    return ([regex]::Replace($t, "\n{3,}", "`n`n")).Trim()
}
function Convert-Bodies($o) {
    if ($Html -or $null -eq $o) { return $o }
    foreach ($x in @($o)) {
        if ($x.PSObject.Properties['body'] -and $x.body.contentType -eq 'html' -and $x.body.content) { $x.body.content = ConvertFrom-TeamsHtml $x.body.content; $x.body.contentType = 'text' }
        if ($x.PSObject.Properties['lastMessagePreview'] -and $x.lastMessagePreview.body.contentType -eq 'html') { $x.lastMessagePreview.body.content = ConvertFrom-TeamsHtml $x.lastMessagePreview.body.content; $x.lastMessagePreview.body.contentType = 'text' }
    }
    return $o
}

# ---------------------------------------------------------------- run
if ($OutFile) {
    $b = Invoke-Connector $Path 'GET' $null
    $b64 = if ($b.PSObject.Properties['$content']) { $b.'$content' } elseif ($b -is [string]) { $b } elseif ($b.PSObject.Properties['contentBytes']) { $b.contentBytes } else { $null }
    if (-not $b64) { throw "No binary content in the response (keys: $(@($b.PSObject.Properties.Name) -join ', '))" }
    $bytes = [Convert]::FromBase64String($b64)
    $dir = Split-Path $OutFile -Parent; if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory $dir | Out-Null }
    [IO.File]::WriteAllBytes($OutFile, $bytes)
    "Saved $($bytes.Length) bytes to $OutFile"
    return
}

if ($All) {
    $items = [Collections.Generic.List[object]]::new()
    $u = $Path
    for ($p = 0; $u -and $p -lt $MaxPages; $p++) {
        $r = Invoke-Connector $u 'GET' $null
        foreach ($v in @($r.value)) { if ($null -ne $v) { $items.Add($v) } }
        $u = $r.'@odata.nextLink'
    }
    $out = Convert-Bodies $items.ToArray()
    if ($u) { Write-Warning "Stopped after $MaxPages pages; more results exist (raise -MaxPages)." }
}
else {
    $out = Invoke-Connector $Path $Method $Body
    if ($out -and $out.PSObject.Properties['value']) { $null = Convert-Bodies $out.value } else { $null = Convert-Bodies $out }
}
if ($Raw) { return $out }
$out | ConvertTo-Json -Depth 30
