# M365 Connector Bridge for Claude Code

Microsoft 365 mail, calendar, Teams chats, people and files in Claude Code when the claude.ai Microsoft 365 connector is not available in your tenant.

Read (and, after approval, write) as the **target account** from local Claude Code.

## Terms

- **Target account / target tenant** - the Microsoft 365 account and tenant you want to work with, where the claude.ai connector is not available (no admin consent for mail/chat apps, device-code sign-in blocked, or the connector app not allowed).
- **Home tenant** - the tenant of the Azure subscription that holds the connections. Local `az login` uses an account of this tenant.

## How it works

```
local az login (home tenant account)
  -> POST https://management.azure.com/<connection id>/dynamicInvoke?api-version=2016-06-01
       body: { "request": { "method": "POST", "path": "<connector operation path>", "headers": {...}, "body": ... } }
     -> the connector runs the operation with the token stored in the connection
        -> Microsoft Graph / SharePoint as the target account
```

- A **connection** (`Microsoft.Web/connections`) is a standalone Azure resource that stores the OAuth token. No Logic App is needed; one was used only for the first test (deleted).
- `dynamicInvoke` is the action the Azure portal uses to fill dropdowns in the Logic Apps designer. It is **not documented for production use** and may change.
- Generic operations: Outlook `/codeless/httprequest` (Graph), Teams `/httprequest` (Graph), Office 365 Users `/codeless/httprequest` (Graph, almost any `me/...` or `users/...` path), SharePoint `/datasets/{site, URL-encoded twice}/httprequest` (SharePoint REST). Each connector only allows some Graph paths (`docs/findings.md`).
- Response: `{ "response": { "statusCode": "OK", "headers": {...}, "body": ... } }`. Binary content comes as `{ "$content-type": "...", "$content": "<base64>" }`.

## Configuration

Copy `connections.example.json` to `connections.json` (git-ignored) and fill in the subscription, resource group and connection ids. The scripts read it from the folder above `scripts\`.

## Connections

Five connections in one resource group of the home subscription.

| Config key | Connector (managed API) | For | Status 7 Nov 2026 |
|---|---|---|---|
| `mail` | Office 365 Outlook (`office365`) | mail, attachments, calendar | ✅ authorized, tested |
| `teams` | Microsoft Teams (`teams`) | chats, messages, pasted images | ✅ authorized, tested |
| `users` | Office 365 Users (`office365users`) | people search, profiles, manager; **also Graph for OneDrive, shared files, joined teams, free time** | ✅ authorized, tested |
| `sharepoint` | SharePoint (`sharepointonline`) | site files, SharePoint REST, tenant-wide search | ✅ authorized, tested |
| `onedrive` | OneDrive for Business (`onedriveforbusiness`) | own files, convert to PDF | ✅ authorized, tested |

**Create:** `scripts\New-M365Connection.ps1 -Api <api>` (defaults from `connections.json`, name `m365bridge-<api>`). It prints the portal link for authorization.

**Authorize (account owner):** Azure portal signed in to the home tenant → connection → **Edit API connection** → **Authorize** → "Use another account" → the target account → MFA → **Save**. URL pattern:
`https://portal.azure.com/#@<home tenant id>/resource<connection id>/edit`

Check: `az resource show --ids <connection id> --query "{status:properties.overallStatus,user:properties.authenticatedUser.name}"`.

**Move to another resource group:** `scripts\New-M365Connection.ps1 -Api <api> -ResourceGroup <new rg>` for each API, the owner authorizes, then update `connections.json` (and any copy used by your skills). A connection cannot keep its token across a move; it must be authorized again.

## Script

`scripts\Invoke-M365Graph.ps1` - Graph through the Outlook or Teams connection. If your skills use their own copy of the script, keep both in sync until the MCP server replaces it.

```powershell
.\scripts\Invoke-M365Graph.ps1 'v1.0/me/mailFolders/inbox/messages?$top=10&$select=subject,from,receivedDateTime'
.\scripts\Invoke-M365Graph.ps1 'v1.0/me/chats?$expand=members,lastMessagePreview&$orderby=lastMessagePreview/createdDateTime desc&$top=20'
.\scripts\Invoke-M365Graph.ps1 '<hostedContents url>' -OutFile C:\temp\image.png
```

Read-only unless `-AllowWrite` (only after the account owner approved the action). Mail bodies come as text; Teams HTML becomes text with `[image: <url>]` for pasted images.

## Use responsibly

This route reads your own Microsoft 365 data through an Azure subscription outside the target tenant, so the target tenant's IT does not see or manage it as an app. Use it only with your own account, check your organization's policies first, and keep access to the resource group that holds the connections tight: anyone with Contributor on a connection can act as the target account.

## Next step

A local MCP server with the same tool names as the claude.ai Microsoft 365 connector: `docs/mcp-server-plan.md`.
