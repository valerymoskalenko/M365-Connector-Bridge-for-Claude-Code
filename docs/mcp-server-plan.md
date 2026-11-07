# Plan: local MCP server "m365-bridge"

Status: plan only (7 Nov 2026).

## Goal

A local stdio MCP server for Claude Code that exposes **the same tool names and parameters** as the claude.ai Microsoft 365 connector, backed by the API connections of the target account. Then any skill written for `mcp__claude_ai_Microsoft_365__<tool>` works for the target account by switching the prefix to `mcp__m365-bridge__<tool>`.

Estimate (not measured): 4–6 hours for the read tools + drafts, plus testing.

## Steps

1. **Capture the real connector contract**: in a session where the Microsoft 365 connector is authorized, list its tools with full input schemas (ToolSearch "select:mcp__claude_ai_Microsoft_365__..."), save them to `docs/m365-connector-tools.json`. Don't guess the schemas.
2. **Connections** in their own resource group, all five authorized by the account owner.
3. **Server**: .NET 10 console app with the official C# MCP SDK (NuGet `ModelContextProtocol`), stdio transport. Auth: `AzureCliCredential` → ARM token. One `ConnectorClient` (dynamicInvoke, retries on 429/5xx, path rewrites from `docs/findings.md`).
4. **Tools, in this order**:
   1. `outlook_email_search`, `read_resource` (mail + chat message URIs), `outlook_calendar_search`, `teams_list_chats`
   2. `search_people` (Office 365 Users), `chat_message_search` (scan newest chats; say "scanned N chats since <date>" in the result)
   3. `sharepoint_search` (SharePoint REST `/_api/search/query`), `read_resource` for files (OneDrive ConvertFile → PDF → text, or download + local conversion)
   4. Writes, each with the same guard as the connector: `outlook_create_draft`, `outlook_create_reply_draft`, `outlook_create_reply_all_draft`, `outlook_update_draft`, `outlook_delete_draft`, `outlook_send_draft`, `outlook_send_mail`, `teams_send_chat_message`, `outlook_create_event`, `outlook_find_available_time`
5. **Register**: `claude mcp add m365-bridge -- dotnet run --project <path>` (user scope), or a published exe.
6. **Tests**: unit tests for path rewrites and response parsing; live tests gated by an env var that print counts only.
7. **Skills**: point the mail and Teams skills to the MCP tools; keep the script as a fallback.

## Open questions

- Should the server also cover the home tenant (app-only) for tenant-neutral tools, or the target account only?
