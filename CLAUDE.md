# M365 Connector Bridge for Claude Code

Goal: give local Claude Code Microsoft 365 abilities - mail, calendar, Teams, people, SharePoint/OneDrive - for a work account where the claude.ai **Microsoft 365 connector** is not available, with the **same tool names** as that connector, so existing skills work for both accounts.

Route: Azure **API connections** (Logic Apps managed connectors) authorized by the account owner, called from a local script through ARM `dynamicInvoke`. No admin consent, no app registration, no device-code sign-in needed in the target tenant.

## Read first

0. `CLAUDE.local.md` and `connections.json` (if present) - personal context: accounts, tenants, subscription, connection ids, open items. Local only, never committed.
1. `README.md` - how it works, connections, the scripts.
2. `docs/findings.md` - path rules and limits found in testing (don't rediscover them).
3. `docs/m365-connector-comparison.md` - what the claude.ai connector can do vs this bridge.
4. `docs/mcp-server-plan.md` - the next step (local MCP server with the connector's tool names).
5. `docs/connector-operations.md` - useful operations of each connector.

## State

- All 5 connector types authorized and tested (read). Writes tested: drafts, send mail, OneDrive create/delete, Teams new chat + post (a new chat gives 405 for ~4 min, retry). Results: `docs/findings.md`, `docs/m365-connector-comparison.md`.
- Script: `scripts\Invoke-M365Graph.ps1`.
- MCP server: not started.
- Known gaps in `Invoke-M365Graph.ps1`: only the Outlook + Teams connections; sets `ContentType` only when there is a body, so `me/messages/{id}/send` fails (needs the header). Add the Users / SharePoint / OneDrive connections and the 405 retry for new Teams chats when building the MCP server.

## Rules

- **Read-only by default.** Sending mail, posting in Teams, deleting or copying files only after the account owner approved that exact action. "Write an email" = show the text in chat first.
- Never commit or push without the owner's OK. Never save mail/chat content into this repo (tests print counts and sizes only).
- **This repo is public.** No tenant, company or person names, account emails, subscription or tenant IDs, resource group names or local paths in committed files. They go to `CLAUDE.local.md` / `connections.json` (both git-ignored). Use the terms "target account / target tenant" and "home tenant" (README "Terms").
- Plain English in docs, no idioms. Label estimates as estimates.
