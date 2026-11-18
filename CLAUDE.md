# M365 Connector Bridge for Claude Code

Goal: give local Claude Code Microsoft 365 abilities - mail, calendar, Teams, people, SharePoint/OneDrive - for a work account where the claude.ai **Microsoft 365 connector** is not available, with the **same tool names** as that connector, so existing skills work for both accounts.

Route: Azure **API connections** (Logic Apps managed connectors) authorized by the account owner, called from a local script through ARM `dynamicInvoke`. No admin consent, no app registration, no device-code sign-in needed in the target tenant.

## Read first

0. `CLAUDE.local.md` and `connections.json` (if present) - personal context: accounts, tenants, subscription, connection ids, open items. Local only, never committed.
1. `README.md` - overview, diagram, install, links to `docs/` (setup, how-it-works, scripts, security).
2. `docs/findings.md` - path rules and limits found in testing (don't rediscover them).
3. `docs/m365-connector-comparison.md` - what the claude.ai connector can do vs this bridge.
4. `docs/security.md` - who can use the connections, how to check and reduce access.
5. `docs/mcp-server-plan.md` - a possible local MCP server with the connector's tool names. Not decided yet whether it is needed (skills may work better).
6. `docs/connector-operations.md` - useful operations of each connector.

## State

- All 5 connector types authorized and tested (read). Writes tested: drafts (also `Save-M365Draft.ps1`: new, update, reply-all, upload session), send mail, OneDrive create/delete, Teams new chat + post (a new chat gives 405 for ~4 min, retry). Results: `docs/findings.md`, `docs/m365-connector-comparison.md`.
- Scripts: `scripts\Invoke-M365Graph.ps1` (Graph via `mail` / `teams` / `users`), `scripts\Invoke-M365SharePoint.ps1` (SharePoint REST, GET only, incl. `_api/v2.0` OneDrive API; config key `sharepointRoot`). Files (skill `m365-files`, read-only, tested 18 Nov): `Search-M365Files.ps1`, `Get-M365File.ps1` (download via `@content.downloadUrl`, text via Python `markitdown`). Config lookup: `$env:M365_BRIDGE_CONFIG`, `~/.m365-bridge/connections.json`, repo root.
- Helper scripts: `Save-M365Draft.ps1` (all drafts), `Get-M365Signature.ps1`, `Get-M365DraftLink.ps1`, `Compare-DraftText.py`, `Watch-M365Chat.ps1`, `Send-M365ChatMessage.ps1` (all chat posts: check, post, read back; tested on the note-to-self chat, `-NewChat` only with a simulated 405).
- Writes are never repeated automatically on HTTP 5xx or a network failure (only on 429): a write may already be done. Keep that rule in new scripts.
- The repo is a Claude Code plugin + marketplace (`.claude-plugin/`): skills `m365-bridge`, `m365-mail`, `m365-teams`, `m365-files` in `skills/`, referencing files as `${CLAUDE_PLUGIN_ROOT}/...`. Validate with `claude plugin validate .` before a push (two warnings about `CLAUDE.md` / `CLAUDE.local.md` at the plugin root are expected). Plugin version: `version` in `.claude-plugin/plugin.json` (1.1.0); raise it with each release. Icon: `.claude-plugin/icon.png`, rendered from `assets/icon-source.svg` (1024 x 1024, headless Edge screenshot with a transparent background).
- MCP server: not started.
- Known gaps: the OneDrive connection is not used by any script (own-file PDF conversion only); mail attachments are not converted to text yet (`Get-M365File.ps1` has the markitdown step to reuse); a real sharing link (`/:w:/s/...`) is not tested yet (files up to 134 MB, .doc / .ppt via local Office and PDF pages as PNG are tested). The 405 retry for new Teams chats is in `Send-M365ChatMessage.ps1 -NewChat`.

## Rules

- **Read-only by default.** Sending mail, posting in Teams, deleting or copying files only after the account owner approved that exact action. "Write an email" = show the text in chat first.
- Never commit or push without the owner's OK. Never save mail/chat content into this repo (tests print counts and sizes only).
- **This repo is public.** No tenant, company or person names, account emails, subscription or tenant IDs, resource group names or local paths in committed files. They go to `CLAUDE.local.md` / `connections.json` (both git-ignored). Use the terms "target account / target tenant" and "home tenant" (README "Terms"). The only exception: the owner's name in the `author` field of `.claude-plugin/plugin.json`.
- **File and script names** never contain a company name. Use `M365` (as in `Save-M365Draft.ps1`) or "tenant"; examples use Contoso (`contoso.com`), Microsoft's demo company.
- Plain English in docs, no idioms. Label estimates as estimates.
