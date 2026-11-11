---
name: m365-teams
description: Read Teams chats of the target Microsoft 365 account through M365 Connector Bridge (Teams API connection, script Invoke-M365Graph.ps1) - newest chats, the 1:1 / group / meeting chat with a person, the whole conversation around a topic, unanswered messages, pasted screenshots saved to a file, whether a meeting took place - and posting only after the user's OK. Use when the user asks about Teams chats of the account where the claude.ai Microsoft 365 connector is not available - "check my Teams", "what did <person> write me", "read the chat with <person>", "open the screenshot from that chat", "who wrote me today", "answer him in Teams". Setup and errors: skill m365-bridge.
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

Skip messages whose `messageType` is not `message` (system events) and messages with `deletedDateTime`. The user's own messages: `from.user.id` = their id (find it in `members` where `email` = the target account).

Example - the chat with a person, both sides, oldest first, images saved:

```powershell
$chats = (& $g 'v1.0/me/chats?$expand=members,lastMessagePreview&$orderby=lastMessagePreview/createdDateTime desc&$top=50' -Raw).value
$chat = $chats | Where-Object { $_.members.email -contains 'person@example.com' } | Sort-Object { $_.chatType -ne 'oneOnOne' } | Select-Object -First 1
$msgs = (& $g "v1.0/chats/$($chat.id)/messages?`$top=50" -Raw).value | Where-Object { $_.messageType -eq 'message' -and -not $_.deletedDateTime } | Sort-Object createdDateTime
$i = 0; foreach ($m in $msgs) { foreach ($u in [regex]::Matches($m.body.content, '\[image: (https://[^\]]+)\]')) { $i++; & $g $u.Groups[1].Value -OutFile "<temp>\chat-$i.png" } }
```

Read the whole conversation around the topic, not only the messages that contain a keyword.

## Was a meeting held?

The meeting chat (topic = meeting title) holds system messages. Read them with `-Html` and look at `eventDetail.'@odata.type'`: `callStartedEventMessageDetail`, `callEndedEventMessageDetail` (`callDuration`, `callParticipants`), `callRecordingEventMessageDetail`, `callTranscriptEventMessageDetail`. That proves the call took place; the recording and transcript files themselves are not reachable here (see Limits).

## Limits

- **1:1 chats with external (federated) accounts are not listed** by Graph. Group and meeting chats with external members are.
- No chat-message search API: list the chats and filter the messages yourself.
- No people search and no `me/joinedTeams` through this connection (refused). Channels need a team id from elsewhere: `v1.0/teams/{teamId}/channels/{channelId}/messages` (not tested).
- Files shared in a chat (OneDrive / SharePoint links) can't be fetched through this connection. Ask the user to download them, or use the OneDrive / SharePoint connections (`docs/connector-operations.md`).
- Meeting transcripts: `me/onlineMeetings/{id}/transcripts` returns 403 `GraphAccessToTranscriptsDisabled` when the tenant has turned that off.
- `pinnedMessages` returned 404 on a 1:1 chat.

## Posting (only after the user's OK)

Show the chat, the full text and anything new in the chat first. "Write <person> this" or "answer her in Teams" means prepare, not post. Post only when the user says "send" for that exact text, unless they explicitly said to post without showing it. Right before posting, read the last messages again: the user may have already answered.

- Post: `& $g "v1.0/chats/{chatId}/messages" -Method POST -AllowWrite -Body @{ body = @{ contentType = 'html'; content = '<p>...</p>' } }` → 201. Read it back with `?$top=2`.
- New 1:1 chat: the Teams connector operation `POST /beta/chats` with body `{ "members": "<email>" }` (through `dynamicInvoke`, see `docs/connector-operations.md`). A post to a **new** chat returns 405 for about 3-4 minutes: retry with back-off for up to 5 minutes.
- Note to self: `v1.0/me/chats/48:notes/messages`.
