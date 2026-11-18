<#
.SYNOPSIS
  Prints (and optionally opens) the Outlook on the web link that opens a draft of the target account in
  EDIT mode, in its own compose window.

.DESCRIPTION
  A draft's webLink (.../owa/?ItemID=...&viewmodel=ReadMessageItem) opens it read-only. This script builds
    https://outlook.cloud.microsoft/mail/<account>/deeplink/compose/<id>?ItemID=<id>&exvsurl=1&login_hint=<account>
  - In the path the id has "/" -> "-", "+" -> "_" and "=" -> "%3D". With a plain "=" Outlook opened the draft
    read-only (tested).
  - "/mail/<account>/" and "login_hint" pin the mailbox. Without them the link opens in whatever account the
    browser tab is signed in with, and Outlook shows "(No subject) - This message might have been moved or
    deleted". With them Outlook opens the target mailbox, or asks to sign in as the target account.

.PARAMETER WebLinkOrId
  The draft's webLink or its message id.
.PARAMETER Account
  The target account's address. Default: "account" in connections.json.
.PARAMETER Open
  Open the link in the default browser.
.PARAMETER EdgeProfile
  Open the link in the Microsoft Edge profile signed in as this address (Windows). Use it when the default
  browser profile is signed in with another account.

.EXAMPLE
  .\Get-M365DraftLink.ps1 $draft.webLink
.EXAMPLE
  .\Get-M365DraftLink.ps1 $draft.id -EdgeProfile user@contoso.com
#>
param(
    [Parameter(Mandatory, Position = 0)][string]$WebLinkOrId,
    [string]$Account,
    [switch]$Open,
    [string]$EdgeProfile
)
$ErrorActionPreference = 'Stop'

if (-not $Account) {
    $cfgFile = @($env:M365_BRIDGE_CONFIG, (Join-Path $HOME '.m365-bridge/connections.json'), (Join-Path (Split-Path $PSScriptRoot -Parent) 'connections.json')) |
        Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if ($cfgFile) { $Account = (Get-Content $cfgFile -Raw | ConvertFrom-Json).account }
}

$m = [regex]::Match($WebLinkOrId, 'ItemID=([^&]+)')
$id = if ($m.Success) { [uri]::UnescapeDataString($m.Groups[1].Value) } else { $WebLinkOrId }
$pathId = $id.Replace('/', '-').Replace('+', '_').Replace('=', '%3D')
$mailbox = if ($Account) { "mail/$Account/" } else { 'mail/' }
$link = "https://outlook.cloud.microsoft/$($mailbox)deeplink/compose/$pathId`?ItemID=$([uri]::EscapeDataString($id))&exvsurl=1"
if ($Account) { $link += '&login_hint=' + [uri]::EscapeDataString($Account) }
else { Write-Warning 'No account in connections.json: the link is not pinned to the target mailbox.' }
"Edit link: $link"

if ($EdgeProfile) {
    $state = Get-Content (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\Local State') -Raw | ConvertFrom-Json
    $prof = @($state.profile.info_cache.PSObject.Properties | Where-Object { $_.Value.user_name -eq $EdgeProfile })
    if ($prof.Count -ne 1) { throw "Expected one Edge profile signed in as $EdgeProfile, found $($prof.Count)." }
    Start-Process 'msedge.exe' -ArgumentList "--profile-directory=`"$($prof[0].Name)`"", "`"$link`""
    "Opened in Edge profile '$($prof[0].Value.name)'"
}
elseif ($Open) {
    Start-Process $link
}
