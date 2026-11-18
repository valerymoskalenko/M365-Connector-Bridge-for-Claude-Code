---
name: m365-teams
description: Read Teams chats of the target Microsoft 365 account through M365 Connector Bridge (Teams API connection, script Invoke-M365Graph.ps1) - newest chats, the 1:1 / group / meeting chat with a person, the whole conversation around a topic, unanswered messages, pasted screenshots saved to a file, whether a meeting took place or was recorded, watching a chat live (Watch-M365Chat.ps1) - and posting only after the user's OK, with a check for new messages right before each post (Send-M365ChatMessage.ps1). Use when the user asks about Teams chats of the account where the claude.ai Microsoft 365 connector is not available - "check my Teams", "what did <person> write me", "read the chat with <person>", "open the screenshot from that chat", "who wrote me today", "watch this chat every minute", "answer him in Teams". Setup and errors: skill m365-bridge.
---

# Teams chats of the target account

Script: `${CLAUDE_PLUGIN_ROOT}/scripts/Invoke-M365Graph.ps1`. Setup, path rules, errors: skill **m365-bridge**.

```powershell
$g = '${CLAUDE_PLUGIN_ROOT}/scripts/Invoke-M365Graph.ps1'
```

Message bodies come as **text**; pasted images appear as `[image: https://graph.microsoft.com/.../hostedContents/.../$value]` - download with `-OutFile` and read the file. Emoji become their alt text, links stay as `text (url)`. Add `-Html` for the raw HTML.

## Recipes

| Need | Path |
|---|---|
| Newest chats (with members' emails and the last message) | `v1.0/me/chats?$expand=members,lastMessagePreview&$orderby=lastMessagePreview/createdDateTime desc&$top=50` |
| Chat with a person | the call above, then filter `members.email` = the person's address (`chatType` `oneOnOne` first, then group/meeting) |
| Messages of a chat (newest first) | `v1.0/chats/{chatId}/messages?$top=50` (the script turns it into `me/chats/...`); older: follow `@odata.nextLink` or `-All -MaxPages 4` |
| Only since a time | `v1.0/chats/{chatId}/messages?$top=50&$orderby=lastModifiedDateTime desc&$filter=lastModifiedDateTime gt 2026-01-31T00:00:00Z` |
| One chat's details | `v1.0/chats/{chatId}?$expand=members` |
| Save a pasted image | `& $g '<the [image: ...] url>' -OutFile <temp>\chat-image.png` |

- Skip messages whose `messageType` is not `message` (system events) and messages with `deletedDateTime`. The user's own messages: `from.user.id` = their id (find it in `members` where `email` = the target account).
- With `-All` the result is the list itself (no `.value`), and times must be compared in UTC: see "The script" in skill m365-bridge. For a short chat, one call with `?$top=50 -Raw` and `.value` is enough.

Example - the chat with a person, both sides, oldest first, images saved:

```powershell
$chats = (& $g 'v1.0/me/chats?$expand=members,lastMessagePreview&$orderby=lastMessagePreview/createdDateTime desc&$top=50' -Raw).value
$chat = $chats | Where-Object { $_.members.email -contains 'person@contoso.com' } | Sort-Object { $_.chatType -ne 'oneOnOne' } | Select-Object -First 1
$msgs = (& $g "v1.0/chats/$($chat.id)/messages?`$top=50" -Raw).value | Where-Object { $_.messageType -eq 'message' -and -not $_.deletedDateTime } | Sort-Object createdDateTime
$i = 0; foreach ($m in $msgs) { foreach ($u in [regex]::Matches($m.body.content, '\[image: (https://[^\]]+)\]')) { $i++; & $g $u.Groups[1].Value -OutFile "<temp>\chat-$i.png" } }
```

Read the whole conversation around the topic, not only the messages that contain a keyword.

## Watch a chat live

"Read this chat every minute", "tell me when he answers": `scripts/Watch-M365Chat.ps1` (read-only). It prints `START`, one `CHAT <time> | <sender>: <text>` line per new message (pasted images saved to `-ImageDir`), `CHAT-ERROR` for a failed check, and `END` at `-StopUtc`. Use the time of the last message you already reviewed as `-Since`.

- **Under 30 minutes:** run it in the Monitor tool:
  `pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/Watch-M365Chat.ps1" -ChatId '<id>' -Since <utc> -ImageDir <temp> 2>&1 | grep --line-buffered -E "^(START|CHAT|END)"`
- **Hours:** Monitor stops after its time-out, and a re-arm would restart the script and repeat messages. Run the script in the background (Bash `run_in_background`) with `-StopUtc <utc> > <temp>/watch.log 2>&1`, then follow the file with Monitor: `tail -n 0 -F <temp>/watch.log | grep --line-buffered -E "^(START|CHAT|END)|Exception"`. On a Monitor time-out, re-arm the same command (`-n 0` shows only new lines). To stop: stop the Monitor and the background task, then end any leftover `pwsh` that runs the script.
- Report each new message in 1-3 lines and propose a reply; post only after "send". The user's own messages show up too (also the ones you posted for them): say which are which.
- The watcher's lines can lag behind the chat. When the user says "check the chat", read the chat directly.
- Non-Latin text (for example Cyrillic) can arrive as `????` in Monitor notifications. Read the new messages again with the recipe above, write them to a UTF-8 file and read the file.

## Was a meeting held? Was a call recorded?

The meeting chat (topic = meeting title), and a 1:1 chat after a call, hold system messages. Read them with `-Html` and look at `eventDetail.'@odata.type'`: `callStartedEventMessageDetail`, `callEndedEventMessageDetail` (`callDuration`, `callParticipants`), `callRecordingEventMessageDetail` (the final one has `callRecordingStatus` success, `callRecordingDuration`, `callRecordingUrl`), `callTranscriptEventMessageDetail`. That proves the call took place and was recorded. The files themselves are not reachable here (see Limits): ask the user to download the transcript (Teams > recording > Transcript > Download, .docx and .vtt). Parse the .vtt by merging the lines of the same `<v Speaker>` that follow each other, and write UTF-8 to a file. Quote content from it as "from the transcript the user provided".

## Limits

- **A person of another organization can have several 1:1 chats with the target account.** (1) The **federated** chat, both real accounts: the external member has another `tenantId`. This is the one the person sees in their normal Teams. (2) A chat with the person's **guest object in the target tenant**: same address, but the member's `tenantId` is the target tenant; the person sees it only after switching Teams to the target organization. (3) A chat in the person's own tenant with the target account's guest object: not visible here. If a message the user mentions is not in the list, it is probably in chat (3). **Before posting, look at the members' `tenantId` and use the federated chat**; if only chat (2) exists, tell the user where the message would land and let them decide.
- **Can't start a federated chat.** `POST v1.0/chats` → 400 "Allowed values: teams,me,users", `POST v1.0/me/chats` → 405, and the connector's `POST /beta/chats` gives 400 `'user@odata.bind' field is missing` for an external address. Ask the user (or the other person) to send the first message in Teams: the chat is then listed at once and you can post to it. For people inside the target tenant `POST /beta/chats` works (see "Posting").
- No chat-message search API: list the chats and filter the messages yourself.
- No people search and no `me/joinedTeams` through this connection (refused). Channels need a team id from elsewhere: `v1.0/teams/{teamId}/channels/{channelId}/messages` (not tested).
- Files shared in a chat (OneDrive / SharePoint links) can't be fetched through this connection (`shares/...` → 400). Ask the user to download them, or use the OneDrive / SharePoint connections (`docs/connector-operations.md`).
- Meeting transcripts: `me/onlineMeetings/{id}/transcripts` returns 403 `GraphAccessToTranscriptsDisabled` when the tenant has turned that off.
- `pinnedMessages` returned 404 on a 1:1 chat.

## Posting (only after the user's OK)

Show the chat, the full text and anything new in the chat first. "Write <person> this" or "answer her in Teams" means prepare, not post. Post only when the user says "send" for that exact text, unless they explicitly said to post without showing it.

- **One script for every post** (don't write a script per message):
  `& '${CLAUDE_PLUGIN_ROOT}/scripts/Send-M365ChatMessage.ps1' -ChatId '<id>' -Text '<text>' -ReviewedUtc <utc>`
  `-ReviewedUtc` = `createdDateTime` of the newest message the user saw when they approved the text (`$m.createdDateTime.ToString('o')`). For formatting use `-BodyFile <file with an HTML fragment>` instead of `-Text`; keep the file in a temp folder, not in a repo.
- **It checks before it posts.** If any message is newer than `-ReviewedUtc` (the person answered, or the user wrote themselves), it prints `STOP` and the new messages, ends with exit code 2 and posts nothing: show them, adjust the text if needed, and wait for a new "send". Otherwise it posts and prints `POSTED <time> | id <id>`. `-CheckOnly` does the check without posting.
- **Running it again never posts twice:** the message just posted is newer than `-ReviewedUtc`. So after an error or a `GatewayTimeout ... 'Microsoft.Web'` on the POST (the message may or may not be posted), run the same command again: `STOP` with your own text as the new message means it was posted. The main script never retries a write on HTTP 5xx.
- New 1:1 chat with a person **in the target tenant**: the Teams connector operation `POST /beta/chats` with body `{ "members": "<email>" }` (through `dynamicInvoke`, see `docs/connector-operations.md`). For an existing 1:1 chat it returns that chat. Don't pass the object id of an external person's guest object: that opens the guest-object chat, which the person does not see in their normal Teams (see Limits). A post to a chat **created through the connector** returned 405 for about 3-4 minutes: pass `-NewChat` and the script tries again for up to 5 minutes (tested only with a simulated 405).
- Note to self: chat id `48:notes`.
- Raw call (what the script does): `& $g "v1.0/chats/{chatId}/messages" -Method POST -AllowWrite -Body @{ body = @{ contentType = 'html'; content = '<p>...</p>' } }` → 201.
