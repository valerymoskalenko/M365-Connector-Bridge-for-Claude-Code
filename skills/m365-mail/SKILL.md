---
name: m365-mail
description: Read and draft mail and read the calendar of the target Microsoft 365 account through M365 Connector Bridge (Outlook API connection, script Invoke-M365Graph.ps1) - inbox, unread, search by person/subject/text, whole threads, Sent Items ("did I already answer?"), attachments and inline screenshots saved to a file, calendar for a date range, drafts / reply / reply-all drafts with the user's Outlook signature, inline screenshots and large attachments (one script, Save-M365Draft.ps1), an edit link that opens the draft, "did I change the draft by hand?", and sending only after the user's OK. Use when the user asks about mail or calendar of the account where the claude.ai Microsoft 365 connector is not available - "check my mail", "what did <person> send me", "find the email about X", "read the thread", "did I reply", "open the attachment", "what is in my calendar", "draft a reply", "update the draft", "did I edit the draft". Setup and errors: skill m365-bridge.
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
| Search (any folder) | `v1.0/me/messages?$search="<KQL>"&$top=25&$select=...` - KQL like `from:person@contoso.com`, `participants:<addr>`, `subject:invoice`, `"exact words"`. URL-encode the `$search` value (`[uri]::EscapeDataString('"from:x@y.com"')`). `$search` can't be combined with `$orderby`/`$filter` |
| One message, full text | `v1.0/me/messages/{id}?$select=subject,from,toRecipients,ccRecipients,receivedDateTime,body` |
| Whole thread | `v1.0/me/messages?$filter=conversationId eq '{id}'&$select=subject,from,toRecipients,sentDateTime,receivedDateTime,body` (escape `'` as `''`, URL-encode the id); sort by time yourself |
| Did I answer? | `v1.0/me/mailFolders/sentitems/messages?$filter=sentDateTime ge <utc>&$orderby=sentDateTime desc&$select=subject,toRecipients,sentDateTime,bodyPreview,conversationId`, then match the person / conversationId |
| Attachments list | `v1.0/me/messages/{id}/attachments?$select=id,name,contentType,size,isInline` |
| Save an attachment / inline screenshot | `& $g "v1.0/me/messages/{id}/attachments/{attId}" -OutFile <temp>\name.png` (then read the image) |
| Calendar range | `v1.0/me/calendar/calendarView?startDateTime=<utc>&endDateTime=<utc>&$top=100&$select=subject,start,end,organizer,attendees,isOnlineMeeting,onlineMeeting` - **not** `me/calendarView` (refused). Times are UTC; convert to the user's zone |
| Free/busy of people | POST `v1.0/me/calendar/getSchedule` (read-only, but needs `-Method POST -AllowWrite`; say so to the user) |
| Folders | `v1.0/me/mailFolders?$top=50&$select=id,displayName,unreadItemCount,totalItemCount` |
| Many pages | add `-All -MaxPages 5` (the result is then the list of items itself, no `.value`) |

Example - last 10 emails from a person, then the full thread of the newest:

```powershell
$q = [uri]::EscapeDataString('"from:person@contoso.com"')
$hits = (& $g "v1.0/me/messages?`$search=$q&`$top=10&`$select=id,subject,receivedDateTime,conversationId" -Raw).value
$cid = [uri]::EscapeDataString($hits[0].conversationId.Replace("'", "''"))
$thread = (& $g "v1.0/me/messages?`$filter=conversationId eq '$cid'&`$select=from,sentDateTime,body" -Raw).value | Sort-Object sentDateTime
```

- `$search` lags for brand-new mail (a minute or more). For "did it arrive?" list `mailFolders/inbox/messages` and `mailFolders/junkemail/messages` with `$filter=receivedDateTime ge <utc>`.
- **The attachment list is empty, but the mail shows file names:** the files are OneDrive / SharePoint links in the body. Get them from the HTML body (`?$select=body -Html`, `href` values). The Outlook connection can't open them (`shares/`, `drives/` → HTTP 400 "Allowed values: me,users ... messages,mailFolders,events"). Say so and ask the user for the files.

## Writing (only after the user's OK)

**Stop at the draft.** Show To, Cc, which thread (new / reply / reply-all), the full text, the edit link, and anything new you found while preparing it (a newer message from the person, for example). Send only when the user says "send" for that draft. "Write <person> this", "reply to her", "send it by email" are requests to prepare, not to send, unless the user explicitly says to send without showing it.

**Text first, draft second.** "Write <person> …" = show the text in the chat. Create the draft when the user asks for a draft.

### One script for every draft

Don't write a new script per email. Every new draft, reply draft and update goes through `Save-M365Draft.ps1`. Per email you write only the body: an HTML fragment file (no `<html>`/`<body>`, no closing line such as "Best regards" - the user's signature adds it). Keep the file next to its screenshots in a temp or work folder, not in a repo.

```powershell
$s = '${CLAUDE_PLUGIN_ROOT}/scripts/Save-M365Draft.ps1'
& $s -To pat@contoso.com -Subject '...' -BodyFile .\body.html -Images .\a.png, .\b.png       # new draft
& $s -ReplyTo <messageId> -ReplyAll -BodyFile .\reply.html                                  # reply-all draft in a thread
& $s -DraftId <id> -BodyFile .\body.html -Cc @()                                             # update the SAME draft
```

- Inline image: `<img src="cid:<file name>" width="650">` in the body, the file in `-Images`. The script stops if an image is not referenced.
- `-Attachments` for files. Files over about 2.8 MB go through an upload session automatically (a request through the connector may not be larger than 4 MB).
- Signature: taken from the newest Sent Items message that has one (`Get-M365Signature.ps1`, cached in `~/.m365-bridge/signature-cache`). `-NoSignature` leaves it out. Graph drafts never get the Outlook signature on their own.
- Reply drafts: your text and the signature go above the quoted thread. On an update, only your part is replaced and the thread stays. If the draft is a reply and the script can't find where the quoted thread starts, it stops and changes nothing; `-ReplaceWholeBody` replaces the whole body anyway (ask the user first: the thread is then gone).
- Attachments: the script removes or replaces only what it added itself (its inline images, the signature images, a file with the same name). Images of the quoted thread always stay.
- If a step fails after the draft was created, a warning shows the DraftId. Fix the problem and run again with `-DraftId <id>`; don't make a second draft.
- It reads the draft back and prints To, Cc, signature check, attachments, the DraftId and the **edit link** (`-Open` opens it; `-EdgeProfile <address>` opens it in the Edge profile signed in as the target account).
- Call it with `&` from PowerShell: `pwsh -File` and bash can't pass arrays (`-Cc @()`, two `-Images`).
- **Reply-all to a mail that was sent to the user's other address** puts that other address into To. Pass `-To` / `-Cc` yourself, and add back people the sender dropped. For a mail forwarded from another mailbox, use a plain reply (no `-ReplyAll`) and set `-Cc` to the original Cc.

### Edit link

The draft's `webLink` opens it **read-only**. Give the user the edit link from `Get-M365DraftLink.ps1` (Save-M365Draft prints it): `https://outlook.cloud.microsoft/mail/<account>/deeplink/compose/<id>?ItemID=<id>&exvsurl=1&login_hint=<account>`. In the path the id has `/` → `-`, `+` → `_`, `=` → `%3D` (a plain `=` opens read-only). `/mail/<account>/` and `login_hint` make the link open the target mailbox even when the browser tab is signed in with another account (without them Outlook shows "(No subject) - This message might have been moved or deleted").

### Updating a draft: rules

- **Fix a draft in place** (same id), so the edit link the user has stays valid. Making a new draft each round leaves old copies in Drafts: if it happened, say which draft is current and offer to delete the others.
- **Once the user has opened the draft, Outlook on the web autosaves it within minutes and rewrites its HTML** (adds `class="elementToProof"`, puts headings as `<b>` inside `<p>`, reorders inline styles). A regex written for your own HTML then no longer matches. To swap one section, match on the visible text with optional tags (for example `<p[^>]*>\s*(<b>)?Heading(</b>)?\s*</p>`) and stop if it is not found. After the change, tell the user to close the old compose window without saving and open the link again: its next autosave can bring the old text back.
- When the user says they edited the draft by hand or will send it themselves, stop changing it.
- **Was the draft edited by hand?** Read the draft as text (without `-Html`), cut it at the signature, save it as UTF-8 and run `py -I ${CLAUDE_PLUGIN_ROOT}/scripts/Compare-DraftText.py <draft.txt> <body.html>` (`python3` on macOS / Linux). "DIFF LINES: 0" = untouched, update it in place. Otherwise make the next version from the user's text, or give the changes as text only.
- **After the user says "I sent it":** take the newest Sent Items message with that subject and run the same compare. The differences are the user's own last edits.
- **Long replies:** keep the text in a file made by a small generator script (helpers for paragraphs, headings, lists, tables with inline styles). A wording change = edit the generator and generate again, not hand-edit the HTML.

### Raw Graph calls (what the script does)

- New draft: `& $g 'v1.0/me/messages' -Method POST -AllowWrite -Body @{ subject = '...'; body = @{ contentType = 'HTML'; content = '...' }; toRecipients = @(@{ emailAddress = @{ address = '...' } }) }`. The response has an empty `from`; that's normal. An empty Cc must reach Graph as `[]`, not `null` (else HTTP 400 RequestBodyRead).
- Inline screenshot: `attachments = @(@{ '@odata.type' = '#microsoft.graph.fileAttachment'; name = 'x.png'; contentType = 'image/png'; isInline = $true; contentId = 'x.png'; contentBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($png)) })` and `<img src="cid:x.png">` in the HTML. A normal file: same without `isInline`/`contentId`.
- Large file: `POST v1.0/me/messages/{id}/attachments/createUploadSession` with `@{ AttachmentItem = @{ attachmentType = 'file'; name; size; contentType } }`, then PUT the bytes straight to the returned `uploadUrl` (no auth header, `Content-Range: bytes a-b/total`, parts under 4 MB).
- Reply / reply-all draft: `& $g "v1.0/me/messages/{id}/createReply" -Method POST -AllowWrite -Body @{}` (or `createReplyAll`).
- **Adding your HTML to a reply draft:** read the draft body WITH `-Html`. Without it the body comes as plain text with no `<body>` tag, and PATCHing that back as HTML flattens the whole quoted thread into one paragraph. Stop if `<body` is missing.
- Read back: `v1.0/me/messages/{id}?$select=subject,toRecipients,ccRecipients,isDraft` and `/attachments?$select=name,size,isInline`. Print addresses with `ForEach-Object { $_.emailAddress.address }`.

### Send and delete

- **Send** (only after "send"): `& $g "v1.0/me/messages/{id}/send" -Method POST -AllowWrite` → 202. `me/sendMail` is refused by the connector: always create the message first, then `/send`.
- **Delete drafts** only on the user's word. First show a table per draft (created / modified, what it is, what it has that the sent email lacks), then re-check `isDraft` and the subject and `& $g "v1.0/me/messages/{id}" -Method DELETE -AllowWrite`. Deleted drafts go to **Recoverable Items** (Outlook "Recover deleted items"), not to Deleted Items: say that.
