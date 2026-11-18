# Setup

About 15 minutes, once. Terms: see [README](../README.md#terms).

## What you need

- Claude Code 2.1.275 or later (it updates itself by default)
- PowerShell 7 (`pwsh`) and Azure CLI (`az`)
- An Azure subscription in the home tenant where you can create resources. Read [security.md](security.md) first: everyone with Owner, Contributor or Logic App Contributor there can use your connections.
- The target account's sign-in (with MFA) - only you can do the authorize step

## 1. Install the plugin

```text
claude plugin install m365-bridge --marketplace valerymoskalenko/M365-Connector-Bridge-for-Claude-Code
```

Then you can also just ask Claude "set up the M365 bridge": the `m365-bridge` skill walks you through the steps below.

Updates: auto-update is off for third-party marketplaces. Turn it on in `/plugin` → Marketplaces, or run `claude plugin update m365-bridge@m365-connector-bridge`.

## 2. Config file

Copy `connections.example.json` to `~/.m365-bridge/connections.json` and fill in `subscriptionId`, `resourceGroup`, `location`, `homeTenantId` and `account` (the target account's address). Keep it in `~/.m365-bridge/` so plugin updates don't remove it.

The scripts look for the file in this order: `$env:M365_BRIDGE_CONFIG`, `~/.m365-bridge/connections.json`, the repo root (`connections.json` there is git-ignored). It holds subscription and connection ids: never commit it.

## 3. Create the connections

```powershell
az login                                   # home tenant account
az group create -n <rg> -l <region>        # or use an existing resource group
pwsh -File scripts/New-M365Connection.ps1 -Api office365
pwsh -File scripts/New-M365Connection.ps1 -Api teams
```

Each call creates one connection named `m365bridge-<api>` and prints its authorize link and id. Put the ids into `connections.json`.

| Config key | Connector (managed API) | For |
|---|---|---|
| `mail` | Office 365 Outlook (`office365`) | mail, attachments, calendar - **needed** |
| `teams` | Microsoft Teams (`teams`) | chats, messages, pasted images - **needed** |
| `users` | Office 365 Users (`office365users`) | people search, profiles, manager; also Graph for OneDrive, shared files, joined teams, free time - optional |
| `sharepoint` | SharePoint (`sharepointonline`) | site files, SharePoint REST, tenant-wide search - optional |
| `onedrive` | OneDrive for Business (`onedriveforbusiness`) | own files, convert to PDF - optional |

The scripts use `mail` and `teams` today. The optional connections are documented in [connector-operations.md](connector-operations.md).

## 4. Authorize (you, in the browser)

Azure portal signed in to the home tenant → the connection → **Edit API connection** → **Authorize** → "Use another account" → the target account → MFA → **Save**. The link pattern:
`https://portal.azure.com/#@<home tenant id>/resource<connection id>/edit`

Check: `az resource show --ids <connection id> --query "{status:properties.overallStatus,user:properties.authenticatedUser.name}"` → `Connected` and the target account.

## 5. Test (read-only)

```powershell
pwsh -File scripts/Invoke-M365Graph.ps1 'v1.0/me/mailFolders/inbox/messages?$top=1&$select=subject'
pwsh -File scripts/Invoke-M365Graph.ps1 'v1.0/me/chats?$top=1'
```

## Later

- **Authorize again** when a connection shows status `Error` or the script returns HTTP 401: the stored token expired or Conditional Access asks for a new sign-in. Repeat step 4.
- **Move to another resource group:** a connection can't keep its token across a move. Run `New-M365Connection.ps1 -Api <api> -ResourceGroup <new rg>` for each API, authorize, update `connections.json` (and any copy your own skills use), then delete the old connections.
