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

- Graph in the target tenant does **not list 1:1 chats with external (federated) accounts** (a 1:1 chat between the owner's home account and the target account was invisible). Group and meeting chats with external members are listed.
- No Microsoft Search API (`search/query`) through any connector → no `chat_message_search` equivalent; scan recent chats instead. Files are covered by SharePoint REST search.
- Meeting transcripts: Graph access is disabled for the whole target tenant (`GraphAccessToTranscriptsDisabled`), so no route can read them.
- Power Automate is not an option for a push design: Azure Blob Storage connector is **Premium**; a standard Microsoft 365 Power Automate licence has standard connectors only.
- Token lifetime = what the target tenant's Conditional Access allows; if it asks for a new sign-in, the connection status becomes Error and the owner authorizes it again.
- ARM throttling and connector throttling apply (Outlook connector ~300 calls / 60 s per connection). Each call ~0.5–2 s.
- Target tenant data is read through an Azure subscription in the home tenant. Nothing is stored there, but the route is outside the target tenant IT's view.

## Performance

Local script, cold az token: first call ~2 s; a full test run of 8 operations took 23 s.
