---
name: m365-mail
description: Read and draft mail and read the calendar of the target Microsoft 365 account through M365 Connector Bridge (Outlook API connection, script Invoke-M365Graph.ps1) - inbox, unread, search by person/subject/text, whole threads, Sent Items ("did I already answer?"), attachments and inline screenshots saved to a file, calendar for a date range, drafts / reply / reply-all drafts, and sending only after the user's OK. Use when the user asks about mail or calendar of the account where the claude.ai Microsoft 365 connector is not available - "check my mail", "what did <person> send me", "find the email about X", "read the thread", "did I reply", "open the attachment", "what is in my calendar", "draft a reply". Setup and errors: skill m365-bridge.
---

# Mail and calendar of the target account

Script: `${CLAUDE_PLUGIN_ROOT}/scripts/Invoke-M365Graph.ps1`. Setup, path rules, errors: skill **m365-bridge**.

```powershell
$g = '${CLAUDE_PLUGIN_ROOT}/scripts/Invoke-M365Graph.ps1'
```

Bodies come as **plain text** by default (add `-Html` for HTML, e.g. to find `cid:` inline images). Use `-Raw` in PowerShell and print only what answers the question.

## Recipes

| Need | Path |
|---|---|
| Newest inbox mail | `v1.0/me/mailFolders/inbox/messages?$top=20&$select=id,subject,from,receivedDateTime,isRead,hasAttachments,bodyPreview,conversationId` |
| Unread | `...inbox/messages?$filter=isRead eq false&$top=50&$select=...` |
| Since a time | `...inbox/messages?$filter=receivedDateTime ge 2026-01-31T00:00:00Z&$orderby=receivedDateTime desc&$select=...` |
| Search (any folder) | `v1.0/me/messages?$search="<KQL>"&$top=25&$select=...` - KQL like `from:person@example.com`, `participants:<addr>`, `subject:invoice`, `"exact words"`. URL-encode the `$search` value (`[uri]::EscapeDataString('"from:x@y.com"')`). `$search` can't be combined with `$orderby`/`$filter` |
| One message, full text | `v1.0/me/messages/{id}?$select=subject,from,toRecipients,ccRecipients,receivedDateTime,body` |
| Whole thread | `v1.0/me/messages?$filter=conversationId eq '{id}'&$select=subject,from,toRecipients,sentDateTime,receivedDateTime,body` (escape `'` as `''`, URL-encode the id); sort by time yourself |
| Did I answer? | `v1.0/me/mailFolders/sentitems/messages?$filter=sentDateTime ge <utc>&$orderby=sentDateTime desc&$select=subject,toRecipients,sentDateTime,bodyPreview,conversationId`, then match the person / conversationId |
| Attachments list | `v1.0/me/messages/{id}/attachments?$select=id,name,contentType,size,isInline` |
| Save an attachment / inline screenshot | `& $g "v1.0/me/messages/{id}/attachments/{attId}" -OutFile <temp>\name.png` (then read the image) |
| Calendar range | `v1.0/me/calendar/calendarView?startDateTime=<utc>&endDateTime=<utc>&$top=100&$select=subject,start,end,organizer,attendees,isOnlineMeeting,onlineMeeting` - **not** `me/calendarView` (refused). Times are UTC; convert to the user's zone |
| Free/busy of people | POST `v1.0/me/calendar/getSchedule` (read-only, but needs `-Method POST -AllowWrite`; say so to the user) |
| Folders | `v1.0/me/mailFolders?$top=50&$select=id,displayName,unreadItemCount,totalItemCount` |
| Many pages | add `-All -MaxPages 5` |

Example - last 10 emails from a person, then the full thread of the newest:

```powershell
$q = [uri]::EscapeDataString('"from:person@example.com"')
$hits = (& $g "v1.0/me/messages?`$search=$q&`$top=10&`$select=id,subject,receivedDateTime,conversationId" -Raw).value
$cid = [uri]::EscapeDataString($hits[0].conversationId.Replace("'", "''"))
$thread = (& $g "v1.0/me/messages?`$filter=conversationId eq '$cid'&`$select=from,sentDateTime,body" -Raw).value | Sort-Object sentDateTime
```

`$search` lags for brand-new mail (a minute or more). For "did it arrive?" list `mailFolders/inbox/messages` and `mailFolders/junkemail/messages` with `$filter=receivedDateTime ge <utc>`.

## Writing (only after the user's OK)

**Stop at the draft.** Show To, Cc, which thread (new / reply / reply-all), the full text, and anything new you found while preparing it (a newer message from the person, for example). Send only when the user says "send" for that draft. "Write <person> this", "reply to her", "send it by email" are requests to prepare, not to send, unless the user explicitly says to send without showing it.

- New draft: `& $g 'v1.0/me/messages' -Method POST -AllowWrite -Body @{ subject = '...'; body = @{ contentType = 'HTML'; content = '...' }; toRecipients = @(@{ emailAddress = @{ address = '...' } }) }`. The response has an empty `from`; that's normal.
- Inline screenshot: in the same POST add `attachments = @(@{ '@odata.type' = '#microsoft.graph.fileAttachment'; name = 'x.png'; contentType = 'image/png'; isInline = $true; contentId = 'shot1'; contentBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($png)) })` and put `<img src="cid:shot1" width="900">` in the HTML. A normal file: same without `isInline`/`contentId`.
- Reply / reply-all draft: `& $g "v1.0/me/messages/{id}/createReply" -Method POST -AllowWrite -Body @{}` (or `createReplyAll`; `@{ comment = '...' }` adds plain text).
- **Adding your HTML to a reply draft:** read the draft body WITH `-Html`. Without it the body comes as plain text with no `<body>` tag, and PATCHing that back as HTML flattens the whole quoted thread into one paragraph. Stop if `<body` is missing. Insert your text right after `<body…>`, then PATCH `v1.0/me/messages/{draftId}` with `@{ body = @{ contentType = 'HTML'; content = $html } }`.
- Graph drafts get no Outlook signature. Add one to the HTML yourself if the user wants it.
- Fix a draft in place (PATCH the same id) rather than delete and recreate, so any link the user has stays valid.
- Read back after writing: `v1.0/me/messages/{id}?$select=subject,toRecipients,ccRecipients,isDraft` and `/attachments?$select=name,size,isInline`. Print addresses with `ForEach-Object { $_.emailAddress.address }`.
- Link for the user: the draft's `webLink` opens it read-only in Outlook on the web; the user can open it from the Drafts folder to edit.
- **Send** (only after "send"): `& $g "v1.0/me/messages/{id}/send" -Method POST -AllowWrite` → 202. `me/sendMail` is refused by the connector: always create the message first, then `/send`.
- Delete a draft: `& $g "v1.0/me/messages/{id}" -Method DELETE -AllowWrite` (goes to Recoverable Items, not Deleted Items).
