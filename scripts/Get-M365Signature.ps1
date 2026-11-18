<#
.SYNOPSIS
  Returns the target account's current Outlook signature, ready to add to a draft.

.DESCRIPTION
  Drafts made through Graph (POST me/messages, createReply, createReplyAll) never get the Outlook signature.
  This script takes the <div id="Signature"> block from the newest Sent Items message that has one, so the
  signature is always the one the user uses now, plus the inline images it references by cid: (logos, icons)
  as fileAttachment objects for Graph.

  A reply whose own part has no signature still contains the OTHER person's signature in the quoted thread.
  So a block counts only if it contains the sender's own display name (from the sent message, or -Name).

  A copy is cached in ~/.m365-bridge/signature-cache and used when no sent message with a signature is found.
  Outlook on the web and new Outlook write <div id="Signature">. Classic Outlook for Windows uses other markup,
  which this script does not find.

.PARAMETER Look
  How many of the newest sent messages to check. Default 15.
.PARAMETER Name
  Text that must appear in the signature block. Default: the display name of the sender of each sent message.

.OUTPUTS
  PSCustomObject: Html (signature HTML), Attachments (array of hashtables for Graph), Source (subject + sent time, or 'cache').

.EXAMPLE
  $sig = & .\Get-M365Signature.ps1
  $html = $myBodyHtml + $sig.Html     # don't write your own "Best regards": the signature has it
#>
[CmdletBinding()]
param([int]$Look = 15, [string]$Name)

$ErrorActionPreference = 'Stop'
$g = Join-Path $PSScriptRoot 'Invoke-M365Graph.ps1'
$cacheDir = Join-Path $HOME '.m365-bridge/signature-cache'

function Get-SignatureBlock([string]$html, [string]$owner) {
    $from = 0
    while (($start = $html.IndexOf('<div id="Signature"', $from)) -ge 0) {
        $depth = 0; $block = $null
        foreach ($m in [regex]::Matches($html.Substring($start), '(?i)<div\b|</div>')) {
            if ($m.Value -like '</*') { $depth-- } else { $depth++ }
            if ($depth -eq 0) { $block = $html.Substring($start, $m.Index + $m.Length); break }
        }
        if (-not $block) { return $null }
        if (-not $owner -or $block.Contains($owner) -or $block.Contains([Net.WebUtility]::HtmlEncode($owner))) { return $block }
        $from = $start + $block.Length
    }
    return $null
}

$sigHtml = $null; $atts = @(); $source = $null
$sent = (& $g "v1.0/me/mailFolders/sentitems/messages?`$orderby=sentDateTime desc&`$top=$Look&`$select=id,subject,sentDateTime,from" -Raw).value
foreach ($s in $sent) {
    $owner = if ($Name) { $Name } else { $s.from.emailAddress.name }
    $body = (& $g "v1.0/me/messages/$($s.id)?`$select=body" -Html -Raw).body.content
    $block = Get-SignatureBlock $body $owner
    if (-not $block) { continue }
    $sigHtml = $block
    $cids = [regex]::Matches($block, 'src="cid:([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
    if ($cids) {
        # download only the signature's own images, not every file attached to that message
        $list = (& $g "v1.0/me/messages/$($s.id)/attachments?`$select=id,name,isInline,microsoft.graph.fileAttachment/contentId" -Raw).value
        foreach ($a in $list | Where-Object { $_.isInline -and $cids -contains $_.contentId }) {
            $f = & $g "v1.0/me/messages/$($s.id)/attachments/$($a.id)" -Raw
            $atts += @{ '@odata.type' = '#microsoft.graph.fileAttachment'; name = $f.name; contentType = $f.contentType
                        isInline = $true; contentId = $f.contentId; contentBytes = $f.contentBytes }
        }
    }
    $source = "$($s.subject) ($($s.sentDateTime))"
    break
}

if ($sigHtml) {
    if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory $cacheDir -Force | Out-Null }
    [IO.File]::WriteAllText((Join-Path $cacheDir 'signature.html'), $sigHtml, [Text.UTF8Encoding]::new($false))
    ConvertTo-Json -InputObject @($atts) -Depth 3 | Set-Content (Join-Path $cacheDir 'attachments.json') -Encoding utf8
} elseif (Test-Path (Join-Path $cacheDir 'signature.html')) {
    Write-Warning "No signature in the last $Look sent messages - using the cached copy (it may be out of date)."
    $sigHtml = [IO.File]::ReadAllText((Join-Path $cacheDir 'signature.html'))
    $atts = @(Get-Content (Join-Path $cacheDir 'attachments.json') -Raw | ConvertFrom-Json -AsHashtable)
    $source = 'cache'
} else {
    throw "No signature found in the last $Look sent messages and no cache in $cacheDir. If the signature does not contain the account's display name, pass -Name <text in the signature>. To make a draft without a signature, use Save-M365Draft.ps1 -NoSignature."
}

[PSCustomObject]@{ Html = $sigHtml; Attachments = $atts; Source = $source }
