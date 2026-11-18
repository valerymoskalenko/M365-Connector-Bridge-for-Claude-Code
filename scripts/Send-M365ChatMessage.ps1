<#
.SYNOPSIS
  Posts ONE message to a Teams chat of the target account: checks the chat for new messages first, posts,
  then reads the message back. One script for every chat post.

.DESCRIPTION
  1. Check: reads the newest messages. If any message is newer than -ReviewedUtc (the time of the last
     message the user saw when they approved the text), it prints those messages and stops with exit code 2.
     Nothing is posted: show the new messages to the user and wait for a new "send".
  2. Post (skipped with -CheckOnly).
  3. Read back: prints POSTED with the time and id of the new message.

  Running it again is safe: the message just posted is newer than -ReviewedUtc, so the check stops it.
  That also covers a time-out on the POST (the message may or may not have been posted): run the same
  command again, the check tells you which.

  Writes to Teams: run it only after the user said "send" for this exact text.

.PARAMETER ChatId
  The chat id ("19:...@thread.v2", "19:..._...@unq.gbl.spaces", "48:notes" = note to self).
.PARAMETER Text
  Plain text. Line breaks are kept; the text is HTML-encoded.
.PARAMETER BodyFile
  Instead of -Text: a UTF-8 file with an HTML fragment (<p>, <b>, <a>, lists).
.PARAMETER ReviewedUtc
  createdDateTime (UTC) of the newest message the user reviewed, for example 2026-01-31T15:30:00.123Z.
.PARAMETER NewChat
  The chat was created minutes ago: a post to a new chat returns 405 for about 4 minutes. With this switch
  the script waits and tries again for up to 5 minutes (405 = not posted, so trying again is safe).
.PARAMETER CheckOnly
  Do the check and print what would be posted, but don't post.

.EXAMPLE
  .\Send-M365ChatMessage.ps1 -ChatId '19:abc...@unq.gbl.spaces' -Text 'Thanks, I will check it today.' -ReviewedUtc 2026-01-31T15:30:00.123Z
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ChatId,
    [string]$Text,
    [string]$BodyFile,
    [Parameter(Mandatory)][string]$ReviewedUtc,
    [switch]$NewChat,
    [switch]$CheckOnly
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$g = Join-Path $PSScriptRoot 'Invoke-M365Graph.ps1'

if ([bool]$Text -eq [bool]$BodyFile) { throw 'Pass either -Text or -BodyFile.' }
$html = if ($BodyFile) { (Get-Content -Raw -Encoding UTF8 $BodyFile).Trim() }
        else { '<p>' + ((($Text -replace "`r", '') -split "`n" | ForEach-Object { [Net.WebUtility]::HtmlEncode($_) }) -join '<br>') + '</p>' }
if (-not $html) { throw 'The message is empty.' }

# With -Raw, Graph times arrive as [datetime] (UTC); a parameter string ending in Z must be parsed as
# datetimeoffset ([datetime]'...Z' becomes LOCAL time).
function ConvertTo-Utc($v) {
    if ($v -is [datetimeoffset]) { return $v.UtcDateTime }
    if ($v -is [datetime]) { return $v.ToUniversalTime() }
    [datetimeoffset]::Parse("$v", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime
}
function Get-Newest([int]$top) {
    @((& $g "v1.0/chats/$ChatId/messages?`$top=$top" -Raw).value) |
        Where-Object { $_.messageType -eq 'message' -and -not $_.deletedDateTime } | Sort-Object { ConvertTo-Utc $_.createdDateTime }
}
function Format-Line($m) {
    $who = if ($m.from.user) { $m.from.user.displayName } elseif ($m.from.application) { $m.from.application.displayName } else { '?' }
    '{0:yyyy-MM-ddTHH:mm:ss.fffZ} | {1}: {2}' -f (ConvertTo-Utc $m.createdDateTime), $who, ("$($m.body.content)" -replace '\s+', ' ')
}

# ---------------------------------------------------------------- 1. check
$cut = ConvertTo-Utc $ReviewedUtc
$before = @(Get-Newest 10)
$newer = @($before | Where-Object { (ConvertTo-Utc $_.createdDateTime) -gt $cut })
if ($newer) {
    "STOP: $($newer.Count) message(s) newer than $($cut.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')) - nothing was posted."
    $newer | ForEach-Object { 'NEW ' + (Format-Line $_) }
    exit 2
}
if ($CheckOnly) { "CHECK OK: no message newer than $($cut.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')). Would post: $html"; return }

# ---------------------------------------------------------------- 2. post
$deadline = [datetime]::UtcNow.AddMinutes(5)
for ($try = 1; ; $try++) {
    try {
        $sent = & $g "v1.0/chats/$ChatId/messages" -Method POST -AllowWrite -Raw -Body @{ body = @{ contentType = 'html'; content = $html } }
        break
    }
    catch {
        if ($NewChat -and "$_" -match 'HTTP 405' -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Seconds ([Math]::Min(20 * $try, 60)); continue }
        Write-Warning 'The POST failed. The message may or may not have been posted: run the same command again - its check shows whether it is in the chat.'
        throw
    }
}

# ---------------------------------------------------------------- 3. read back
$after = @(Get-Newest 5)
$mine = $after | Where-Object { $_.id -eq $sent.id } | Select-Object -First 1
if ($mine) { "POSTED $((ConvertTo-Utc $mine.createdDateTime).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')) | id $($mine.id)" }
else { Write-Warning "The POST returned id $($sent.id), but the message is not among the newest 5. Read the chat." }
