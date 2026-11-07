# claude.ai Microsoft 365 connector vs this bridge

The tool list of the claude.ai Microsoft 365 connector was collected from skills that use it (tools that were really used). It may be incomplete - check the live tool list when the connector is authorized in a session.

Updated 7 Nov 2026 (evening), after all five connections were authorized and tested (`docs/findings.md`).

| Operation | Microsoft 365 connector | This bridge | Connection | Status |
|---|---|---|---|---|
| Search mail | `outlook_email_search` | Graph `$search` KQL + filters | Outlook | ✅ |
| Read mail / thread | `read_resource` | Graph, whole thread by conversationId, headers | Outlook | ✅ |
| Attachments | `read_resource` (documents as text) | download; convert to text locally | Outlook | ✅ download / text = to build |
| Calendar | `outlook_calendar_search` | `me/calendar/calendarView` | Outlook | ✅ |
| Free time | `outlook_find_available_time` | `me/findMeetingTimes`, `me/calendar/getSchedule` | Users / Outlook | ✅ |
| Create event | `outlook_create_event` | Graph POST `me/events` | Outlook | ⚠️ write, not tested |
| Drafts: new, reply, reply-all, update, delete | `outlook_create_draft`, `outlook_create_reply_draft`, `outlook_create_reply_all_draft`, `outlook_update_draft`, `outlook_delete_draft` | Graph `me/messages`, `createReply`, `createReplyAll`, PATCH, DELETE | Outlook | ✅ new, update, delete tested (reply = same API) |
| Send | `outlook_send_draft`, `outlook_send_mail` | Graph draft + `send` (needs ContentType header) | Outlook | ✅ tested (email to a colleague) |
| List chats | `teams_list_chats` | with members + last message | Teams | ✅ |
| Read chat | `read_resource` | + pasted images downloaded (the connector can't) | Teams | ✅ |
| Search all chats | `chat_message_search` | no Search API; scan the newest ~50 chats | Teams | ⚠️ partial |
| Post in Teams | `teams_send_chat_message` | connector "Post message", Graph `me/chats/{id}/messages`; create chat with `/beta/chats` | Teams | ✅ tested (new 1:1 chat with a colleague; 405 for ~4 min after creating a chat - retry) |
| People search | `search_people` | Search for users V2, Graph `users?$filter`, `me/people?$search` | Users | ✅ |
| Profile, manager | (part of `search_people`) | `users/{upn}`, `/manager`, relevant people | Users | ✅ |
| SharePoint / OneDrive search | `sharepoint_search` | SharePoint REST `_api/search/query` (whole tenant incl. OneDrive) | SharePoint | ✅ |
| Read files | `read_resource` | SharePoint file by path, OneDrive file by id, Graph `me/drive/items/{id}/content` | SharePoint / OneDrive / Users | ✅ binary; text = convert locally |
| Convert file to PDF | - | OneDrive `convert?type=PDF` | OneDrive | ✅ extra |
| Shared with me, recent files, joined teams | - | Graph `me/drive/sharedWithMe`, `me/drive/recent`, `me/joinedTeams` | Users | ✅ extra |
| Copy / delete files | `sharepoint_copy_item`, `sharepoint_delete_item` | SharePoint CopyFileAsync / REST DELETE | SharePoint | ⚠️ write, not tested |
| Meeting transcripts | 403 also from the home tenant for meetings hosted in the target tenant | 403 `GraphAccessToTranscriptsDisabled` (tenant setting) | Teams | ❌ blocked by the target tenant |

Summary: every read operation of the connector has a working equivalent except cross-chat search (partial) and transcripts (blocked by the tenant). Writes tested: drafts, send mail, OneDrive create/delete, Teams chat creation and posting. A new 1:1 chat rejects posts with 405 for a few minutes - retry. Not tested: events, file copy.

## Other differences

| | Microsoft 365 connector | This bridge |
|---|---|---|
| Form | MCP tools | PowerShell script called by skills (MCP server = next step) |
| Where | claude.ai, Desktop, Code - any device | The machine with az login only |
| Auth | Anthropic app consented in the home tenant | Tokens stored in 5 Azure connections, refreshed by Microsoft |
| Durability | Official, permanent | `dynamicInvoke` is portal-internal and not documented for production use |
| Search quality | Microsoft Search index (with lag) | Exact Graph queries for mail/chats; SharePoint search index for files |
| Speed | - | ~0.5–2.5 s per call |
