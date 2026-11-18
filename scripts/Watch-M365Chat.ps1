<#
.SYNOPSIS
  Watches one Teams chat of the target account: checks it every N seconds and prints one line per new message.
  Read-only. Made for Claude Code's Monitor tool ("read this chat every minute").

.DESCRIPTION
  Output lines (filter them with grep):
    START <time> | chat <id>
    CHAT <time> | <sender>: <text>          pasted images are saved to -ImageDir and shown as [image saved: <file>]
    CHAT-ERROR <message>                    one failed check; the watcher keeps going
    END <time>                              -StopUtc reached
  Times are shown in -TimeZoneId (default: this computer's time zone). The user's own messages are listed too.

  Short watch (under 30 minutes), straight in Monitor:
    pwsh -NoProfile -File Watch-M365Chat.ps1 -ChatId '<id>' -ImageDir <temp> 2>&1 | grep --line-buffered -E "^(START|CHAT|END)"
  Long watch (hours): run the script in the background with its output in a log file, and follow the file
  with Monitor, so a Monitor re-arm does not restart the script and repeat messages:
    1. background: pwsh -NoProfile -File Watch-M365Chat.ps1 -ChatId '<id>' -StopUtc <utc> -ImageDir <temp> > <temp>/watch.log 2>&1
    2. Monitor:    tail -n 0 -F <temp>/watch.log | grep --line-buffered -E "^(START|CHAT|END)|Exception"

.EXAMPLE
  .\Watch-M365Chat.ps1 -ChatId '19:abc...@unq.gbl.spaces' -Since 2026-01-31T15:30:00Z -IntervalSeconds 60 -ImageDir $env:TEMP
#>
param(
    [Parameter(Mandatory)][string]$ChatId,
    [string]$Since = [datetimeoffset]::UtcNow.ToString('o'),   # only messages after this time (UTC); use the last reviewed message
    [int]$IntervalSeconds = 60,
    [string]$StopUtc,                                            # stop at this time (UTC); empty = run until stopped
    [string]$ImageDir = [IO.Path]::GetTempPath(),
    [string]$TimeZoneId = [TimeZoneInfo]::Local.Id
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$g = Join-Path $PSScriptRoot 'Invoke-M365Graph.ps1'
$tz = [TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneId)
# Compare times in UTC. With -Raw, Graph times arrive as [datetime] (Kind=Utc); a parameter string ending in Z must be
# parsed as datetimeoffset ([datetime]'...Z' becomes LOCAL time and gives wrong results).
function ConvertTo-Utc($v) {
    if ($v -is [datetimeoffset]) { return $v.UtcDateTime }
    if ($v -is [datetime]) { return $v.ToUniversalTime() }
    [datetimeoffset]::Parse("$v", [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
}
function Format-Time([datetime]$utc) { [TimeZoneInfo]::ConvertTimeFromUtc($utc, $tz).ToString('yyyy-MM-dd HH:mm:ss') }

$last = ConvertTo-Utc $Since
$stop = if ($StopUtc) { ConvertTo-Utc $StopUtc } else { [datetime]::MaxValue }
$seen = @{}; $img = 0
if (-not (Test-Path $ImageDir)) { New-Item -ItemType Directory $ImageDir -Force | Out-Null }
Write-Output "START $(Format-Time ([datetime]::UtcNow)) | chat $ChatId | since $(Format-Time $last)"

while ([datetime]::UtcNow -lt $stop) {
    try {
        $msgs = @((& $g "v1.0/chats/$ChatId/messages?`$top=20" -Raw).value) |
            Where-Object { $_.messageType -eq 'message' -and -not $_.deletedDateTime -and -not $seen[$_.id] -and (ConvertTo-Utc $_.createdDateTime) -gt $last } |
            Sort-Object { ConvertTo-Utc $_.createdDateTime }
        foreach ($m in $msgs) {
            $seen[$m.id] = $true
            $text = "$($m.body.content)"
            foreach ($u in [regex]::Matches($text, '\[image: (https://[^\]]+)\]')) {
                $img++; $f = Join-Path $ImageDir ('chat-watch-{0}-{1:000}.png' -f $PID, $img)   # process id: two watchers don't overwrite each other
                & $g $u.Groups[1].Value -OutFile $f | Out-Null
                $text = $text.Replace($u.Value, "[image saved: $f]")
            }
            $who = if ($m.from.user) { $m.from.user.displayName } elseif ($m.from.application) { $m.from.application.displayName } else { '?' }
            Write-Output ('CHAT {0} | {1}: {2}' -f (Format-Time (ConvertTo-Utc $m.createdDateTime)), $who, ($text -replace '\s+', ' '))
        }
    }
    catch { Write-Output "CHAT-ERROR $($_.Exception.Message -replace '\s+', ' ')" }
    Start-Sleep -Seconds $IntervalSeconds
}
Write-Output "END $(Format-Time ([datetime]::UtcNow))"
