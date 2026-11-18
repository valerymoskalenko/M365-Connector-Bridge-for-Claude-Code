<#
.SYNOPSIS
  ONE script for every draft in the target mailbox: a new draft, a reply / reply-all draft, or an update of
  the same draft. Never sends.

.DESCRIPTION
  Per email you only write the text, as an HTML fragment file (no <html>/<body>). The script:
  - adds the user's current Outlook signature (Get-M365Signature.ps1) unless -NoSignature;
  - embeds inline images: put <img src="cid:<file name>"> in the fragment and pass the file with -Images;
  - adds file attachments; files over about 2.8 MB go through an upload session, because a request through
    the connector may not be larger than 4 MB (base64 makes a file about 1.37 times larger);
  - for a reply draft, puts your text and the signature above the quoted thread;
  - on an update, replaces only your part of the body and keeps the quoted thread, so the draft id and any
    edit link the user already has stay valid. If the draft is a reply and the start of the quoted thread is
    not found, it stops (-ReplaceWholeBody replaces the whole body anyway);
  - removes or replaces only attachments it added itself (inline images with contentId = file name, signature
    images, files with the same name). Images of the quoted thread are never touched;
  - reads the draft back and prints subject, To, Cc, signature check, attachments, DraftId and the edit link.

  If a step fails after the draft was created, a warning shows the DraftId: fix the problem and run again
  with -DraftId, so no second draft is made.

  Writes to the mailbox: run it only after the user approved the draft action in the chat.

  Call it with "&" from PowerShell. "pwsh -File" and bash can't pass arrays such as -Cc @() or two -Images.

.EXAMPLE
  # new draft
  & .\Save-M365Draft.ps1 -To pat@contoso.com -Subject 'Mailbox clean-up' -BodyFile .\body.html -Images .\step1.png, .\step2.png
.EXAMPLE
  # reply-all draft in an existing thread
  & .\Save-M365Draft.ps1 -ReplyTo <messageId> -ReplyAll -BodyFile .\reply.html -Cc pat@contoso.com, sam@contoso.com
.EXAMPLE
  # update the SAME draft; only the parts you pass are changed (-Cc @() removes all Cc)
  & .\Save-M365Draft.ps1 -DraftId <id> -BodyFile .\body.html -Cc @()
#>
[CmdletBinding()]
param(
    [string]$DraftId,          # update this draft
    [string]$ReplyTo,          # create a reply draft to this message id
    [switch]$ReplyAll,         # with -ReplyTo: reply-all
    [string[]]$To,
    [string[]]$Cc,
    [string]$Subject,
    [string]$BodyFile,
    [string[]]$Images,         # inline, referenced in the body as cid:<file name>
    [string[]]$Attachments,    # normal file attachments
    [switch]$NoSignature,
    [switch]$ReplaceWholeBody, # update of a reply draft whose quoted thread is not found: replace the whole body
    [switch]$Open,           # open the edit link in the default browser
    [string]$EdgeProfile       # or open it in the Edge profile signed in as this address
)
$ErrorActionPreference = 'Stop'
$g = Join-Path $PSScriptRoot 'Invoke-M365Graph.ps1'
$maxInlineBytes = 2.8MB        # larger files go through createUploadSession

if (@($DraftId, $ReplyTo | Where-Object { $_ }).Count -gt 1) { throw 'Use either -DraftId (update) or -ReplyTo (new reply draft), not both.' }
if ($ReplyAll -and -not $ReplyTo) { throw '-ReplyAll needs -ReplyTo <messageId>.' }

# -NoEnumerate: an empty list must reach Graph as [] (a plain return turns it into null -> HTTP 400 RequestBodyRead)
function ConvertTo-Recipients([string[]]$addrs) {
    Write-Output -NoEnumerate ([object[]]@($addrs | Where-Object { $_ } | ForEach-Object { @{ emailAddress = @{ address = $_ } } }))
}
function Get-ContentType([string]$name) {
    $t = @{ '.png' = 'image/png'; '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'; '.gif' = 'image/gif'; '.pdf' = 'application/pdf'
            '.txt' = 'text/plain'; '.csv' = 'text/csv'; '.zip' = 'application/zip'
            '.xlsx' = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
            '.docx' = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
            '.pptx' = 'application/vnd.openxmlformats-officedocument.presentationml.presentation' }[[IO.Path]::GetExtension($name).ToLower()]
    if ($t) { $t } else { 'application/octet-stream' }
}
function New-FileItem([string]$path, [bool]$inline) {
    $full = (Resolve-Path $path).Path
    $name = Split-Path $full -Leaf
    [PSCustomObject]@{ Path = $full; Name = $name; Inline = $inline; Size = (Get-Item $full).Length; Type = Get-ContentType $name }
}
function Add-FileItem([string]$id, $f) {
    if ($f.Size -le $maxInlineBytes) {
        $a = @{ '@odata.type' = '#microsoft.graph.fileAttachment'; name = $f.Name; contentType = $f.Type
                contentBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($f.Path)) }
        if ($f.Inline) { $a.isInline = $true; $a.contentId = $f.Name }
        & $g "v1.0/me/messages/$id/attachments" -Method POST -AllowWrite -Body $a | Out-Null
        return
    }
    # large file: upload session, then PUT the bytes straight to uploadUrl (no auth header) in parts
    $item = @{ attachmentType = 'file'; name = $f.Name; size = $f.Size; contentType = $f.Type }
    if ($f.Inline) { $item.isInline = $true; $item.contentId = $f.Name }
    $s = & $g "v1.0/me/messages/$id/attachments/createUploadSession" -Method POST -AllowWrite -Raw -Body @{ AttachmentItem = $item }
    if (-not $s.uploadUrl) { throw "No uploadUrl for $($f.Name)." }
    $bytes = [IO.File]::ReadAllBytes($f.Path)
    $part = 327680 * 9                                       # 2.8 MB, a multiple of 320 KiB, under the 4 MB part limit
    for ($a = 0; $a -lt $bytes.Length; $a += $part) {
        $b = [Math]::Min($a + $part, $bytes.Length) - 1
        $chunk = [byte[]]::new($b - $a + 1); [Array]::Copy($bytes, $a, $chunk, 0, $chunk.Length)
        Invoke-WebRequest -Method PUT -Uri $s.uploadUrl -SkipHeaderValidation -Headers @{ 'Content-Range' = "bytes $a-$b/$($bytes.Length)" } `
            -ContentType 'application/octet-stream' -Body $chunk | Out-Null
    }
}
# Start of the quoted thread in a reply draft (Outlook/Graph markup), or -1. Our own part is everything before it.
function Find-QuoteStart([string]$html) {
    # Outlook on the web puts <div id="appendonsend"> before the quote; a draft made by Graph has only the
    # <hr> + <div id="divRplyFwdMsg"> header. Take whichever comes FIRST: the quoted thread itself can hold
    # the "appendonsend" of an older reply, deeper down.
    $a = $html.IndexOf('<div id="appendonsend"')
    $i = $html.IndexOf('id="divRplyFwdMsg"')
    if ($i -ge 0) {
        $i = $html.LastIndexOf('<div', $i)
        $hr = $html.LastIndexOf('<hr', $i)                   # the line above "From:" belongs to the quote
        if ($hr -ge 0 -and $i - $hr -lt 400) { $i = $hr }
    }
    $found = @($a, $i | Where-Object { $_ -ge 0 } | Sort-Object)
    if ($found.Count) { return $found[0] }
    return -1
}
# $keepAll: fresh reply draft, everything after <body> is the quote. $isReply: the draft answers another message.
function Set-OwnPart([string]$html, [string]$own, [bool]$keepAll, [bool]$isReply) {
    $bm = [regex]::Match($html, '(?is)<body[^>]*>')
    if (-not $bm.Success) { throw 'The draft body has no <body> tag (read without -Html, or a plain-text mail). Stopped so the quoted thread is not flattened.' }
    $head = $html.Substring(0, $bm.Index + $bm.Length)
    $after = $html.Substring($bm.Index + $bm.Length)
    if ($keepAll) { return $head + $own + $after }
    $q = Find-QuoteStart $after
    if ($q -lt 0 -and $isReply -and -not $ReplaceWholeBody) {
        throw 'This is a reply draft, but the start of the quoted thread was not found in its body. Stopped so the thread is not removed. Pass -ReplaceWholeBody to replace the whole body anyway.'
    }
    $rest = if ($q -ge 0) { $after.Substring($q) } else { '</body></html>' }
    return $head + $own + $rest
}

# ---------------------------------------------------------------- body
$own = $null; $sig = $null
if ($BodyFile) {
    $fragment = Get-Content -Raw -Encoding UTF8 $BodyFile
    if ($fragment -match '(?is)<body|<html') { throw 'The body file must be an HTML fragment, without <html>/<body>.' }
    foreach ($img in $Images) {
        $n = Split-Path $img -Leaf
        if ($fragment -notmatch [regex]::Escape("cid:$n")) { throw "Image $n is not referenced in the body as cid:$n" }
    }
    if ($NoSignature) { $own = "<div>$fragment</div>" }
    else {
        if ($fragment -match '(?i)best regards|kind regards') { Write-Warning 'The body has its own closing line; the signature may add another one.' }
        $sig = & (Join-Path $PSScriptRoot 'Get-M365Signature.ps1')
        $own = "<div>$fragment</div><br>$($sig.Html)"
    }
}
elseif ($Images) { throw '-Images needs -BodyFile (the body must reference each image).' }

$patch = @{}
if ($PSBoundParameters.ContainsKey('Subject')) { $patch.subject = $Subject }
if ($PSBoundParameters.ContainsKey('To'))      { $patch.toRecipients = ConvertTo-Recipients $To }
if ($PSBoundParameters.ContainsKey('Cc'))      { $patch.ccRecipients = ConvertTo-Recipients $Cc }

# ---------------------------------------------------------------- create or update
$files = @(); if ($Images) { $files += $Images | ForEach-Object { New-FileItem $_ $true } }      # a missing file stops here, before a draft exists
if ($Attachments) { $files += $Attachments | ForEach-Object { New-FileItem $_ $false } }

$newBody = $null; $created = $false
try {
    if ($ReplyTo) {
        if (-not $BodyFile) { throw 'A reply draft needs -BodyFile.' }
        $op = if ($ReplyAll) { 'createReplyAll' } else { 'createReply' }
        $d = & $g "v1.0/me/messages/$ReplyTo/$op" -Method POST -AllowWrite -Raw -Body @{}
        $DraftId = $d.id; $created = $true
        $cur = (& $g "v1.0/me/messages/$DraftId`?`$select=body" -Raw -Html).body.content
        $newBody = Set-OwnPart $cur $own $true $true
    }
    elseif (-not $DraftId) {
        if (-not $To -or -not $Subject -or -not $BodyFile) { throw 'A new draft needs -To, -Subject and -BodyFile.' }
        $patch.body = @{ contentType = 'HTML'; content = $own }
        $d = & $g 'v1.0/me/messages' -Method POST -AllowWrite -Raw -Body $patch
        if (-not $d.isDraft) { throw 'Graph did not return a draft.' }
        $DraftId = $d.id; $created = $true
        $patch = @{}
    }
    else {
        # extended property 0x1042 = "in reply to": set on a draft that answers another message
        $cur = & $g "v1.0/me/messages/$DraftId`?`$select=isDraft,body&`$expand=singleValueExtendedProperties(`$filter=id eq 'String 0x1042')" -Raw -Html
        if (-not $cur.isDraft) { throw "Message $DraftId is not a draft (already sent?)." }
        if ($BodyFile) { $newBody = Set-OwnPart $cur.body.content $own $false ([bool]$cur.singleValueExtendedProperties) }
    }
    if ($newBody) { $patch.body = @{ contentType = 'HTML'; content = $newBody } }
    if ($patch.Count) { & $g "v1.0/me/messages/$DraftId" -Method PATCH -AllowWrite -Body $patch | Out-Null }

    # ------------------------------------------------------------ attachments
    $sigAtts = if ($sig) { @($sig.Attachments) } else { @() }
    if ($files -or $sigAtts -or $BodyFile) {
        $have = @((& $g "v1.0/me/messages/$DraftId/attachments?`$select=id,name,isInline,microsoft.graph.fileAttachment/contentId" -Raw).value)
        $newNames = @($files | ForEach-Object { $_.Name })
        $sigCids = @($sigAtts | ForEach-Object { $_.contentId })
        $bodyNow = if ($BodyFile) { (& $g "v1.0/me/messages/$DraftId`?`$select=body" -Raw -Html).body.content } else { $null }
        foreach ($a in $have) {
            # Only attachments this script added are removed. An image it added has contentId = file name.
            # Images of the quoted thread have other content ids (a GUID, image001.png@01DA...): never touch them.
            $ours = $a.isInline -and $a.contentId -and $a.contentId -eq $a.name
            $drop = ($a.name -in $newNames -and ($ours -or -not $a.isInline)) -or              # the same file is passed again
                    ($ours -and $bodyNow -and -not $bodyNow.Contains("cid:$($a.name)")) -or    # our image, no longer in the body
                    ($a.isInline -and $a.contentId -and $a.contentId -in $sigCids)             # signature image, added again below
            if ($drop) { & $g "v1.0/me/messages/$DraftId/attachments/$($a.id)" -Method DELETE -AllowWrite | Out-Null }
        }
        foreach ($a in $sigAtts) { & $g "v1.0/me/messages/$DraftId/attachments" -Method POST -AllowWrite -Body $a | Out-Null }
        foreach ($f in $files) { Add-FileItem $DraftId $f }
    }
}
catch {
    if ($created) { Write-Warning "The draft was created but is not complete. DraftId: $DraftId - fix the problem and run again with -DraftId (don't make another draft)." }
    throw
}

# ---------------------------------------------------------------- read back
$chk = & $g "v1.0/me/messages/$DraftId`?`$select=subject,toRecipients,ccRecipients,body,isDraft,webLink" -Raw -Html
"Subject: $($chk.subject) | isDraft=$($chk.isDraft)"
'To: ' + (($chk.toRecipients | ForEach-Object { $_.emailAddress.address }) -join ', ')
'Cc: ' + (($chk.ccRecipients | ForEach-Object { $_.emailAddress.address }) -join ', ')
if (-not $NoSignature -and $BodyFile) { 'Signature in body: ' + ($chk.body.content -match 'id="Signature"') + " (from: $($sig.Source))" }
(& $g "v1.0/me/messages/$DraftId/attachments?`$select=name,size,isInline" -Raw).value | ForEach-Object { "Attachment: $($_.name) $($_.size) inline=$($_.isInline)" }
"DraftId: $DraftId"
$linkArgs = @{ WebLinkOrId = $chk.webLink }
if ($EdgeProfile) { $linkArgs.EdgeProfile = $EdgeProfile } elseif ($Open) { $linkArgs.Open = $true }
& (Join-Path $PSScriptRoot 'Get-M365DraftLink.ps1') @linkArgs
