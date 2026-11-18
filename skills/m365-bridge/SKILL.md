---
name: m365-bridge
description: Base skill of M365 Connector Bridge - reach a Microsoft 365 account (mail, calendar, Teams chats) from local Claude Code when the claude.ai Microsoft 365 connector is not available in that tenant, through Azure API connections and ARM dynamicInvoke (script Invoke-M365Graph.ps1). Setup (create and authorize the connections, connections.json), how it works, connector path rules, errors, re-authorize, safety rules. Use when the user wants to set up the bridge, when Invoke-M365Graph.ps1 fails, "re-authorize the connection", "move the connections", or before the first use of m365-mail / m365-teams in a session. For mail and calendar recipes see m365-mail, for Teams see m365-teams.
---

# M365 Connector Bridge - setup and rules

Use this route for a Microsoft 365 account where the claude.ai Microsoft 365 connector is not available (no admin consent for mail/chat apps, device-code sign-in blocked, or the connector app not allowed). It reads the account's data **as that account**, on demand. Nothing is copied or stored outside Microsoft 365.

Terms: **target account / target tenant** = the Microsoft 365 account you want to work with. **Home tenant** = the tenant of the Azure subscription that holds the connections; local `az login` uses an account of this tenant (it can be the same tenant).

## How it works

```
local az login (home tenant account)
  -> POST https://management.azure.com/<connection id>/dynamicInvoke?api-version=2016-06-01
     -> connector operation "Send an HTTP request"   (Outlook: /codeless/httprequest, Teams: /httprequest)
        -> https://graph.microsoft.com/... signed in as the target account
```

A connection (`Microsoft.Web/connections`, the same resource Logic Apps use) stores the target account's OAuth token. `dynamicInvoke` is the action the Azure portal uses in the Logic Apps designer. It is **not documented for production use** and may change.

## Files

Paths are relative to the plugin root, `${CLAUDE_PLUGIN_ROOT}` (a repo clone works the same way):

| File | Purpose |
|---|---|
| `scripts/Invoke-M365Graph.ps1` | Graph through the Outlook (`mail`) or Teams (`teams`) connection |
| `scripts/New-M365Connection.ps1` | create one connection and print its authorize link |
| `scripts/Save-M365Draft.ps1` | every mail draft: new, reply / reply-all, update in place, signature, inline images, large attachments (skill m365-mail) |
| `scripts/Get-M365Signature.ps1` | the user's current Outlook signature, taken from Sent Items |
| `scripts/Get-M365DraftLink.ps1` | the link that opens a draft in edit mode |
| `scripts/Compare-DraftText.py` | was a draft edited by hand? (draft text vs. the HTML it was made from) |
| `scripts/Watch-M365Chat.ps1` | watch one Teams chat, one line per new message (skill m365-teams) |
| `scripts/Send-M365ChatMessage.ps1` | post one Teams chat message: check for new messages, post, read back (skill m365-teams) |
| `connections.example.json` | template for the config |
| `docs/security.md` | who can use the connections (Azure roles table), checks, how to reduce access, emergency stop |
| `docs/findings.md`, `docs/connector-operations.md` | tested paths, limits, other connector operations (Office 365 Users, SharePoint, OneDrive) |

Config: `connections.json`, looked up in this order: `$env:M365_BRIDGE_CONFIG`, `~/.m365-bridge/connections.json`, the plugin root. Keep it in `~/.m365-bridge/` so plugin updates don't remove it. It holds subscription and connection ids: never commit it, never paste it into public places.

## Setup (once, about 15 minutes)

Needs: PowerShell 7 (`pwsh`), Azure CLI, an Azure subscription where the user can create resources.

1. `az login` with the home tenant account. Pick or create a resource group: `az group create -n <rg> -l <region>`.
2. Copy `${CLAUDE_PLUGIN_ROOT}/connections.example.json` to `~/.m365-bridge/connections.json` and fill in `subscriptionId`, `resourceGroup`, `location`, `homeTenantId`, `account` (the target account's address).
3. Create the connections: `pwsh -File ${CLAUDE_PLUGIN_ROOT}/scripts/New-M365Connection.ps1 -Api office365` and `-Api teams` (optional: `office365users`, `sharepointonline`, `onedriveforbusiness`). Each prints an authorize link and the connection id.
4. **The user** opens each link: **Edit API connection** → **Authorize** → "Use another account" → the target account → MFA → **Save**. Claude can't do this step.
5. Put the ids into `connections.json` (`mail`, `teams`, ...).
6. Test (read-only): `pwsh -File ${CLAUDE_PLUGIN_ROOT}/scripts/Invoke-M365Graph.ps1 'v1.0/me/mailFolders/inbox/messages?$top=1&$select=subject'` and `'v1.0/me/chats?$top=1'`.

Check a connection: `az resource show --ids <connection id> --query "{status:properties.overallStatus,user:properties.authenticatedUser.name}"`.

**Move to another resource group:** a connection can't keep its token across a move. Create new ones there (step 3), authorize them (step 4), update `connections.json`, then delete the old ones.

## The script

`scripts/Invoke-M365Graph.ps1`. Run it with `pwsh -File` or `&` from PowerShell.

| Parameter | Meaning |
|---|---|
| `-Path` (1st) | Graph path `v1.0/me/...` or a full URL (nextLink, hostedContents) |
| `-Connection` | `auto` (default: chats/teams → teams, else mail), `mail`, `teams` |
| `-All` / `-MaxPages` | follow `@odata.nextLink`, return all items (default 10 pages) |
| `-OutFile` | save binary content (Teams pasted image, mail attachment) |
| `-Html` | keep HTML. Default: mail bodies come as **text**; Teams HTML → text, pasted images as `[image: <url>]` |
| `-Raw` | PowerShell objects instead of JSON |
| `-Method`, `-Body`, `-AllowWrite` | writes - see the rules below |

Output is JSON. Use `-Raw` in PowerShell and print **only what answers the question** (subjects, counts, the one thread asked about), not whole mailboxes.

With `-All` the result is the list of items itself (no `.value`). With `-Raw`, Graph times arrive as `[datetime]` in UTC: compare them in UTC (`.ToUniversalTime()`, `([datetimeoffset]'<text>').UtcDateTime`), never with `[datetime]'<text>Z'`, which becomes local time.

### PowerShell tips

- **Name helper functions Verb-Noun with a dash** (`Add-Para`, `New-Shot`). PowerShell resolves aliases before functions, so a short name such as `H` (Get-History), `R` (Invoke-History), `diff`, `sort` or `select` silently runs the built-in command instead ("Cannot bind parameter 'Id' ..."). Check a name with `Get-Command <name> -ErrorAction SilentlyContinue`: it must return nothing.
- Call scripts that take arrays (`-Cc @()`, several `-Images`) with `&` from PowerShell. `pwsh -File` and bash can't pass arrays.
- Python on Windows: `py -I -X utf8 <script>`. A non-ASCII character printed to a cp1252 console crashes the script otherwise.

## Rules (hard)

- **Read-only by default.** The script refuses anything but GET without `-AllowWrite`. Pass `-AllowWrite` only after the user approved that exact action in the chat.
- **Never send or post on your own.** "Write an email to X", "reply to her", "answer him in Teams" mean: prepare a draft and show To, Cc, the full text and anything new you found. Send or post only when the user says "send" for that text, unless they explicitly said to send without showing it.
- Don't save mail or chat content into a repo. Attachments and images go to a temp or scratchpad folder unless the user names a folder.
- Graph returns UTC. Show times in the user's time zone.

## Connector path rules (found in testing)

- Only segment paths: `mailFolders('inbox')` is refused → the script rewrites it to `mailFolders/inbox` (also in nextLinks).
- Outlook connection: first segment `me` or `users`; objects `messages, mailFolders, events, calendar, calendars, outlook, inferenceClassification`. **`me/calendarView` is refused** → use `me/calendar/calendarView`. `me/sendMail` and `me/findMeetingTimes` are refused.
- Teams connection: first segment `teams`, `me` or `users`. **`chats/{id}/...` is refused** → the script rewrites it to `me/chats/{id}/...`. Bare `me`, `users?$filter=...` and `me/joinedTeams` are refused.
- People search, OneDrive and SharePoint are not reachable through these two connections. Use the Office 365 Users / SharePoint / OneDrive connections (`docs/connector-operations.md`; the script doesn't call them yet).

## Errors

| Error | Meaning / fix |
|---|---|
| `No connections.json` | setup step 2 |
| `No Azure token` | `az login` with the home tenant account that can use the subscription |
| ARM 403 / AuthorizationFailed | the az account has no access to the subscription or the connection |
| `HTTP 400 ... URI path is not a valid Graph endpoint` | a path the connector does not allow - see the rules above |
| `A socket operation was attempted to an unreachable network` (or another network error) | local network failure. The script retries reads 3 times; a write is not retried - check whether it was done, then run it again |
| `GatewayTimeout ... 'Microsoft.Web'` or another HTTP 5xx | the connector or Graph failed. The script retries reads 3 times; a write is never retried, because it may already be done. For a write, first check whether it was done (read the draft / the newest chat messages), only then run it again. HTTP 429 is retried for reads and writes |
| `RequestContentTooLarge` | the request is over 4 MB (a file attachment over about 2.9 MB in base64). Use an upload session (`Save-M365Draft.ps1` does it) |
| `HTTP 401` / `InvalidAuthenticationToken` / connection status `Error` | the stored token expired or Conditional Access wants a new sign-in → the user authorizes the connection again (setup step 4) |
| `ResourceNotFound` on the connection | the connection or its resource group was deleted → setup step 3 |

## Security

Anyone who can use a connection acts as the target account (mail, Teams, files) until its refresh token expires or is revoked. Who that is, the read-only checks and the ways to reduce access are in `${CLAUDE_PLUGIN_ROOT}/docs/security.md`: read it before you answer "who can read my mail through the bridge?".

- A URL or resource id alone gives no access. Azure roles decide: Owner, Contributor and the Logic Apps contributor roles, at the connection or at any scope above it.
- **Never create** a Logic App with a Request (HTTP) trigger on these connections, connection keys (`listConnectionKeys`) or consent links: each one gives access outside Azure roles.
- **Never change** role assignments, deployment stacks, deny settings, alerts or the connections themselves on your own. Show the commands and wait for the user's OK for that exact change.
- Emergency stop (only on the user's word): delete the connections, or the user revokes all sessions of the target account.
- Use the bridge only with your own account and check your organization's policies first.
