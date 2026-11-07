# Useful operations per connector

From the managed API swaggers (`GET /subscriptions/<sub>/providers/Microsoft.Web/locations/westeurope/managedApis/<api>?api-version=2016-06-01&export=true`), 7 Nov 2026. Call them through `dynamicInvoke` with `request.path` = the path below without `/{connectionId}`.

## office365 (Office 365 Outlook)

| Operation | Path |
|---|---|
| Send an HTTP request (Graph) | POST `/codeless/httprequest` - headers `Uri`, `Method`, `ContentType`, `CustomHeader1..5` ("Name: value"), body = request body |
| Get emails (V3) | GET `/v3/Mail?folderPath=Inbox&top=10&fetchOnlyUnread=false&includeAttachments=false` |
| Get email (V2) | GET `/v2/Mail/{messageId}` |
| Draft an email message | POST `/Draft` |
| Send a Draft message | POST `/Draft/Send/{messageId}` |
| Send an email (V2) | POST `/v2/Mail` |
| Reply to email (V3) | POST `/v3/Mail/ReplyTo/{messageId}` |
| Forward an email (V2) | POST `/codeless/v1.0/me/messages/{message_id}/forward` |
| Export email (V2) (.eml) | GET `/codeless/beta/me/messages/{messageId}/$value` |
| Triggers | `/v3/Mail/OnNewEmail` (batch), flagged, mentioning me |

Tested through `/codeless/httprequest` (7 Nov 2026): draft POST `me/messages`, PATCH, DELETE, send POST `me/messages/{id}/send` (**set `ContentType: application/json` even with no body**, else 400), `me/calendar/getSchedule` (POST, read). Refused by this connector: `me/findMeetingTimes`, `me/sendMail` (object not allowed) - use the Office 365 Users connection for `findMeetingTimes`.

## teams (Microsoft Teams)

| Operation | Path |
|---|---|
| Send a Microsoft Graph HTTP request | POST `/httprequest` - same headers as above |
| List chats | GET `/flowbot/actions/listchats/chattypes/{all\|group\|meeting\|oneOnOne}/topic/{all\|isDefined\|notDefined}/expandmembers/false` |
| Get messages in a chat | GET `/beta/chats/{chatId}/messages` |
| Get message details | POST `/beta/teams/messages/{messageId}/messageType/groupchat` body `{ "recipient": "<chatId>" }` |
| Post message in a chat or channel | POST `/beta/teams/conversation/message/poster/User/location/Group%20chat` body `{ "recipient": "<chatId>", "messageBody": "<html>" }` |
| Post a message to myself | POST `/v1.0/chats/48:notes/messages` |
| Create a chat | POST `/beta/chats` body `{ "members": "<email>[;<email>]" }` (one email = 1:1 chat; returns `{ "id": ... }`) |
| Send message (Graph, tested) | POST `/httprequest` with `Uri` = `https://graph.microsoft.com/v1.0/me/chats/{chatId}/messages`, body `{ "body": { "contentType": "html", "content": "..." } }` → 201. A new chat returns 405 for ~3–4 min - retry |
| Trigger "When a new chat message is added" | webhook, any chat the target account is in; output only conversationId + messageId |

## office365users (Office 365 Users)

| Operation | Path |
|---|---|
| Send an HTTP request (Graph) | POST `/codeless/httprequest` |
| Search for users (V2) | GET `/v2/users?searchTerm=...&top=10` |
| Get user profile (V2) | GET `/codeless/v1.0/users/{id}` |
| Get manager (V2) | GET `/codeless/v1.0/users/{id}/manager` |
| Get relevant people | GET `/users/{userId}/relevantpeople` |
| Get my profile (V2) | GET `/codeless/v1.0/me` - returns 401; use `/codeless/v1.0/users/{upn}` |

`/codeless/httprequest` here has **no object allow-list**: any Graph path starting with `me` or `users` works within the token scopes (files, drive search, sharedWithMe, recent, joinedTeams, people, `findMeetingTimes`, mail). No Chat scopes - chats go through the Teams connection.

## sharepointonline (SharePoint)

`{dataset}` = the site URL, URL-encoded **twice** (once → 404). Body of httprequest: `{ "method": "GET", "uri": "_api/...", "headers": {...}, "body": "<string>" }`.

| Operation | Path |
|---|---|
| Send an HTTP request to SharePoint (REST) | POST `/datasets/{dataset}/httprequest` - e.g. `/_api/search/query?querytext='...'` |
| List folder | GET `/datasets/{dataset}/foldersV2/{id}` |
| Get file metadata / content (by id or path) | GET `/datasets/{dataset}/files/{id}`, `/files/{id}/content`, `/GetFileByPath`, `/GetFileContentByPath` |
| Copy file / folder | POST `/datasets/{dataset}/copyFileAsync`, `/copyFolderAsync` |

## onedriveforbusiness (OneDrive for Business)

| Operation | Path |
|---|---|
| List root folder | GET `/datasets/default/folders` (`foldersV2/root` → 400) |
| List files in folder | GET `/datasets/default/foldersV2/{id}` |
| Get file metadata / content (by id or path) | GET `/datasets/default/files/{id}`, `/files/{id}/content`, `/GetFileByPath`, `/GetFileContentByPath` |
| Convert file (to PDF etc.) | GET `/datasets/default/files/{id}/convert?type=PDF`, `/ConvertFileByPath` |
| Create file (tested) | POST `/datasets/default/files?folderPath=/&name=<name>` body = file content → returns `Id` |
| Delete file (tested) | DELETE `/datasets/default/files/{id}` (URL-encode the id; file goes to the recycle bin) |
| Search (`folders/{id}/search`, `findFile`) | 404 - use SharePoint search or Graph `me/drive/root/search(q='...')` via Office 365 Users |
