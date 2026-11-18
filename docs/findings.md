# Findings (tested 7 Nov 2026)

## What was proven

| Test | Result |
|---|---|
| Connections authorized with the target account (the target tenant's Conditional Access allowed the sign-in from the Azure portal popup) | ✅ |
| Logic App (Consumption) with the two connections: Get emails V3 + List chats | ✅ (Logic App then deleted) |
| ARM `dynamicInvoke` from a laptop (az login) and from an App Service managed identity (Contributor on the connection) | ✅ |
| Outlook "Send an HTTP request": inbox with `internetMessageHeaders`, `$select`, paging, `$search` (KQL), thread by `conversationId`, Sent Items, attachment JSON with `contentBytes` | ✅ |
| Outlook: `me/calendar/calendarView` | ✅ (50 events / 7 days) |
| Teams "Send an HTTP request": `me/chats?$expand=members,lastMessagePreview&$orderby=...`, `me/chats/{id}/messages` (also `$orderby=lastModifiedDateTime desc&$filter=lastModifiedDateTime gt ...`) | ✅ |
| Teams pasted image: `me/chats/{id}/messages/{mid}/hostedContents/{hc}/$value` | ✅ (PNG 101,958 bytes) |
| Home tenant, app-only (Chat.Read.All application): hostedContents download | ✅ (53,233 bytes) - for comparison |
| Draft to self through Outlook `/codeless/httprequest`: POST `me/messages` (201, isDraft) → found in Drafts → PATCH subject (200) → DELETE (204) → GET 404; not in Deleted Items (Graph DELETE goes to Recoverable Items). Approved by the account owner | ✅ ~1 s per call |
| Send mail to a colleague (approved by the account owner): POST `me/messages` (draft) → POST `me/messages/{id}/send` | ✅ 202 Accepted - **the send call needs header `ContentType: application/json` even with no body** (else 400 "Empty Content-Type provided") |
| OneDrive write: `POST /datasets/default/files?folderPath=/&name=...` (body = text) → read back → `DELETE /datasets/default/files/{id}` → 404 | ✅ ~1.5 s / 0.8 s (deleted file goes to the OneDrive recycle bin) |
| Teams: create 1:1 chat with connector `POST /beta/chats` body `{ "members": "<email>" }` | ✅ 201; chat id `19:<guid>_<guid>@unq.gbl.spaces` |
| Teams: post to own notes - connector `POST /v1.0/chats/48:notes/messages` and Graph `me/chats/48:notes/messages` | ✅ 201 both |
| Teams: post to a **new** 1:1 chat with a colleague (approved by the account owner) - Graph `me/chats/{raw id}/messages` | ✅ 201. The same call returned **405 MethodNotAllowed (empty message) for ~3–4 min after the chat was created**, also via the connector "Post message" (location `Group chat`). Not caused by the content: the same full HTML text posted fine to own notes. Rule: after `POST /beta/chats`, retry 405 on post with back-off for up to ~5 min. A POST with body `{}` returns 400 "Missing body content" - a safe way to check that the path is accepted without posting. Note: Graph GET `me/chats/{raw 1:1 id}` returns the chat list (id dropped); URL-encoded id returns the chat. Searched Microsoft Learn + web (7 Nov): no documented 405 cause found |
| Create event, file copy | ❌ not tested yet |

### Second round: Office 365 Users, SharePoint, OneDrive (7 Nov 2026, evening)

All three connections authorized by the account owner; status Connected as the target account. Times are one call each, including ARM.

| Test | Result |
|---|---|
| Users: `GET /v2/users?searchTerm=...&top=10` (Search for users V2) | ✅ ~0.9 s |
| Users: `GET /codeless/v1.0/users/{upn}` profile, `/users/{upn}/manager`, `/users/{upn}/relevantpeople` | ✅ |
| Users: `GET /codeless/v1.0/me` (Get my profile V2) | ❌ Unauthorized - use `users/{upn}` or Graph `me` through `/codeless/httprequest` |
| Users `/codeless/httprequest` → Graph `me`, `users?$filter=startswith(...)`, `me/people?$search=`, `users?$count=true` | ✅ |
| Users `/codeless/httprequest` → Graph `me/drive/root/children`, `me/drive/recent`, `me/drive/sharedWithMe`, `me/insights/used`, `me/followedSites`, `me/joinedTeams`, `me/memberOf`, `me/messages` | ✅ - no object allow-list on this connector |
| Users `/codeless/httprequest` → Graph `me/findMeetingTimes` (POST, read-only) | ✅ (Outlook connector refuses this path) |
| Users `/codeless/httprequest` → Graph `me/chats`, `me/onlineMeetings` | ❌ 403 - no Chat scopes in this token; use the Teams connection |
| Outlook `/codeless/httprequest` → `me/calendar/getSchedule` (POST, read-only) | ✅ |
| SharePoint `/datasets/{site}/httprequest` → `_api/search/query?querytext='<words>'` (whole tenant incl. OneDrive) | ✅ ~2 s - **site URL must be URL-encoded twice** (once gives 404 "not in a JSON format") |
| SharePoint: file found by search → `_api/web/GetFileByServerRelativeUrl('...')/$value` and `GET /datasets/{site}/GetFileContentByPath?path=` | ✅ 68,681 bytes |
| SharePoint: `GET /datasets` (sites list) | ✅ |
| OneDrive: `GET /datasets/default/folders` (root) | ✅ (`foldersV2/root` → 400 "Invalid fileId") |
| OneDrive: `GET /datasets/default/files/{id}/content` | ✅ .docx 145,382 bytes |
| OneDrive: `GET /datasets/default/files/{id}/convert?type=PDF` | ✅ PDF 346,603 bytes |
| OneDrive: `folders/root/search`, `findFile` | ❌ 404 - use SharePoint search or Graph `me/drive/root/search(q='...')` instead |
| Teams: `me/onlineMeetings?$filter=JoinWebUrl eq '...'` | ✅ meeting found |
| Teams: `me/onlineMeetings/{id}/transcripts` | ❌ 403 `GraphAccessToTranscriptsDisabled` - the target tenant turned off Graph access to transcripts |

Scopes in the Office 365 Users connection token (from a 403 message): `Application.ReadWrite.All, Calendars.ReadWrite, Calendars.ReadWrite.Shared, Contacts.ReadWrite, DelegatedPermissionGrant.ReadWrite.All, Edu*, Files.ReadWrite.All, Group.ReadWrite.All, IdentityUserFlow.ReadWrite.All, Mail.ReadWrite, Mail.ReadWrite.Shared, Mail.Send, Mail.Send.Shared, MailboxSettings.ReadWrite, People.Read(.All), Sites.Read.All, Tasks.ReadWrite, User.Read(.All), User.ReadWrite`. These are delegated: the real limit is what the target account may do. Still, anyone with Contributor on this connection can act as the target account with these scopes - keep access to the resource group tight.

### Third round: daily use (9-17 Nov 2026)

| Test | Result |
|---|---|
| Draft with an inline screenshot (190 KB PNG) and To + Cc in one POST `me/messages` | ✅ response shows `hasAttachments: false` (normal for inline) |
| Draft with a file attachment over ~2.9 MB in the POST (3.2 MB .xlsx) | ❌ `RequestContentTooLarge` - the connector request limit is 4 MB, base64 makes the file ~1.37 times larger |
| Same file: `POST me/messages/{id}/attachments/createUploadSession` through the Outlook connector, then PUT the bytes straight to `uploadUrl` (no auth header, `Content-Range`, 3 MB parts) | ✅ 200, then 201 |
| PATCH a draft with an empty Cc list sent as `null` | ❌ HTTP 400 RequestBodyRead - send `[]` |
| Reply draft: read the body without `-Html`, add HTML, PATCH | ❌ the connector returns plain text with no `<body>` tag; PATCHing it back flattens the quoted thread into one paragraph. Read with `-Html` |
| Signature: take `<div id="Signature">` from the newest sent message and add it to Graph drafts | ✅ - a quoted reply can contain another person's signature block; check the sender's name |
| Draft edit link `outlook.cloud.microsoft/mail/deeplink/compose/<id>?ItemID=<id>&exvsurl=1` | ✅ only with `=` written as `%3D` in the path (a plain `=` opens read-only). Without `/mail/<account>/` and `login_hint` a browser tab signed in with another account shows "This message might have been moved or deleted" |
| Outlook on the web autosave of an opened draft | rewrites the HTML (`class="elementToProof"`, headings as `<b>` in `<p>`, inline styles reordered); a later PATCH that relies on your own HTML no longer matches |
| Outlook connector: `shares/u!...`, `drives/...` (file links in a mail or chat) | ❌ 400 "Allowed values: me,users ... messages,mailFolders,events" |
| `$search` for a mail received 1 minute earlier | ❌ not found yet - list the inbox with `$filter=receivedDateTime ge ...` instead |
| Teams: `POST v1.0/chats` / `POST v1.0/me/chats` through "Send an HTTP request" (new chat with an external person) | ❌ 400 "Allowed values: teams,me,users" / 405. For a person inside the target tenant use the connector operation `POST /beta/chats`. A federated chat with a person of another organization can't be created through the bridge (see below): the user starts it in Teams |
| Teams: a 1:1 chat with a person of another organization | ✅ listed once it exists (only the chat between the owner's own two accounts was missing) |
| Teams: system messages of a recorded 1:1 call (`callRecordingEventMessageDetail`, `callTranscriptEventMessageDetail`) | ✅ readable with `-Html`; the recording / transcript files are not |
| `scripts/Save-M365Draft.ps1` end to end (17 Nov, drafts to self, then deleted): new draft with inline image + signature + 3.5 MB file | ✅ the file went through the upload session (3,670,177 bytes) |
| Same: update of the same draft (new body, other image, `-Cc @()`) | ✅ same id; old inline image removed, new one added, Cc empty |
| Same: reply-all draft (`-To` overridden), then body update | ✅ own text and signature above the quote; after the update the old text is gone and the quoted thread is unchanged (same length) |
| Plain-text body of a draft with an inline image | the image appears as `[cid:<name>]` (`Compare-DraftText.py` ignores it) |
| Activity log of a connection: `az monitor activity-log list --resource-id <connection id>` | ✅ every `Microsoft.Web/connections/dynamicInvoke/action` call is listed (Started + Succeeded) with the caller; a managed identity shows as its object id. Default limit 50 events: use `--max-events` |
| Access policies on the connections (`<connection id>/accessPolicies`) | ❌ 400 `InvalidApiConnectionAccessPolicy`: "Only 'V2' connections support access policies" (connections made by `New-M365Connection.ps1` are V1) |
| Connector `GatewayTimeout ... 'Microsoft.Web'` on a chat POST | happened; the message may or may not have been posted - read the chat before running it again. `Invoke-M365Graph.ps1` repeats HTTP 5xx only for reads (429 for every method) |
| Inline images of a mail: attachment name against the `cid:` in the body (12 inbox mails with images) | 31 of 63 inline attachments have a name that is not in the body (pasted images: name `image.png`, content id a GUID). Match on `contentId`, not on the name |
| `attachments?$select=id,name,isInline,microsoft.graph.fileAttachment/contentId` through the Outlook connector | ✅ gives the content id without downloading the file |
| `$expand=singleValueExtendedProperties($filter=id eq 'String 0x1042')` on a message ("in reply to") | ✅ set on a draft made by `createReply` / `createReplyAll`, not set on a new draft. `Save-M365Draft.ps1` uses it to know that a draft has a quoted thread |
| Body of a mail that is itself a reply written in Outlook on the web | holds its own `<div id="appendonsend">` (7 of 50 inbox mails). In a reply draft made by Graph this marker is inside the quote, after the `divRplyFwdMsg` header: the quote starts at whichever marker comes first |
| `Save-M365Draft.ps1` reply-all draft to a mail with 10 pasted images and an older `appendonsend`, then an update with a new text and another own image (17 Nov, To = self, deleted after) | ✅ all 10 images of the thread kept, 0 broken `cid:` references, no duplicate attachments, own text and own image replaced, one signature |
| Quoted thread before and after a PATCH of the draft body | same length; only the counters in `data-outlook-trace="F:n\|T:n"` of each `<img>` go up by one (Exchange does that on every save) |
| A file attachment of 0 bytes | ✅ accepted |
| `Send-M365ChatMessage.ps1` on the note-to-self chat `48:notes` (17 Nov) | ✅ check, post and read-back work (4 seconds). A second run of the same command stops (STOP, exit code 2, the own message is the new one): the text is in the chat exactly once |
| `Send-M365ChatMessage.ps1 -NewChat` (405 on a new chat) | tested only offline, with a simulated 405: tries again until the post succeeds; without the switch a 405 is not repeated. Chats started in Teams 1.5 and 2.5 minutes earlier gave no 405 |
| Teams connector `POST /beta/chats` for a person of another organization | ❌ the **federated chat** (with the person's real account in their own tenant) can't be created: the address and the object id from their tenant both give 400 `'user@odata.bind' field is missing in the request`. Graph itself can create it ([Create chat](https://learn.microsoft.com/graph/api/chat-post), example 7), but the connector refuses a raw `POST /chats` (row above). With the object id of the person's **guest object in the target tenant** the operation gives 201 - but that is a different chat, see the next row |
| 1:1 chats between the target account and one person of another organization, when each account is also a guest in the other tenant (17 Nov, the owner's two accounts): **three different chats** | (1) **Federated chat**, both real accounts: the members have different tenant ids, the id is `19:<target id>_<other id>@unq.gbl.spaces` and is the same in both tenants. 404 until the person sent the first message in Teams; then listed at once, readable, and `Send-M365ChatMessage.ps1` posted there (6 seconds; the message was read back from the other tenant, a second run stopped). (2) **Chat with the person's guest object in the target tenant**: member address = the external address, member tenant = the target tenant. The bridge can create it and post there, but the person sees it only after switching Teams to the target organization: a test post there went unseen. (3) **Chat with the target account's guest object in the other tenant**: lives in the other tenant, the bridge gets 403 |

## Connector path rules

The connectors validate the Graph URL before calling Graph. Error text: `URI path is not a valid Graph endpoint, path is neither absolute nor relative or resource/object is not supported for this connector. Invalid resource,Allowed values: ... Invalid Object,Allowed values: ...`

| Connector | First segment allowed | Objects allowed (from the error text) | Refused examples |
|---|---|---|---|
| Office 365 Outlook | `me`, `users` | `messages, mailFolders, events, calendar, calendars, outlook, inferenceClassification` | `me/calendarView` (use `me/calendar/calendarView`), `me` alone |
| Microsoft Teams | `teams`, `me`, `users` | `channels, chats, installedApps, messages, pinnedMessages, o…` (truncated) | `chats/{id}/...` (use `me/chats/{id}/...`), `me` alone, `users?$filter=`, `me/joinedTeams` |
| Office 365 Users | `me`, `users` | no object check | `sites/...`, `search/query` (first segment) |
| SharePoint (REST, not Graph) | any `_api/...` on the site in `{dataset}` | - | site URL encoded once → 404 |

Also:
- Only **segment** paths: Graph nextLinks like `mailFolders('inbox')` are refused → rewrite `/(\w+)\('([^']*)'\)` to `/$1/$2`.
- `me/chats/{id}/pinnedMessages?$expand=message` → 404 on a 1:1 chat.
- Teams connector's own operation "Post message in a chat or channel" (`/beta/teams/conversation/message/poster/User/location/Group%20chat`, body `{ "recipient": "<chat id>", "messageBody": "<html>" }`) also posts to a chat; it returned the same 405 for a new chat.
- Teams connector "Get message details" input schema for chats: body `{ "recipient": "<chat id>" }`, threadType `groupchat`.

## Limits

- **A person of another organization can have up to three 1:1 chats with the target account** (federated, guest object in the target tenant, guest object in the other tenant: see the test table). Post to the federated one: the chat whose external member has **another tenant id**. The bridge can't create that chat: the user or the other person sends the first message in Teams. Group and meeting chats with external members are listed.
- No Microsoft Search API (`search/query`) through any connector → no `chat_message_search` equivalent; scan recent chats instead. Files are covered by SharePoint REST search.
- Meeting transcripts: Graph access is disabled for the whole target tenant (`GraphAccessToTranscriptsDisabled`), so no route can read them.
- Power Automate is not an option for a push design: Azure Blob Storage connector is **Premium**; a standard Microsoft 365 Power Automate licence has standard connectors only.
- Token lifetime = what the target tenant's Conditional Access allows; if it asks for a new sign-in, the connection status becomes Error and the owner authorizes it again.
- ARM throttling and connector throttling apply (Outlook connector ~300 calls / 60 s per connection). Each call ~0.5–2 s.
- Target tenant data is read through an Azure subscription in the home tenant. Nothing is stored there, but the route is outside the target tenant IT's view.

## Performance

Local script, cold az token: first call ~2 s; a full test run of 8 operations took 23 s.
