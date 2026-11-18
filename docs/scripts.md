# Scripts

The skills call these scripts from the plugin folder. They need PowerShell 7 (`pwsh`), Azure CLI and `connections.json` ([setup.md](setup.md)).

## Invoke-M365Graph.ps1 - the main script

Microsoft Graph through the Outlook (`mail`), Teams (`teams`) or Office 365 Users (`users`) connection.

```powershell
.\scripts\Invoke-M365Graph.ps1 'v1.0/me/mailFolders/inbox/messages?$top=10&$select=subject,from,receivedDateTime'
.\scripts\Invoke-M365Graph.ps1 'v1.0/me/chats?$expand=members,lastMessagePreview&$orderby=lastMessagePreview/createdDateTime desc&$top=20'
.\scripts\Invoke-M365Graph.ps1 '<hostedContents url>' -OutFile C:\temp\image.png
```

| Parameter | Meaning |
|---|---|
| `-Path` (first) | Graph path `v1.0/me/...` or a full URL (nextLink, hostedContents) |
| `-Connection` | `auto` (default: chats/teams → teams; drive, insights, followedSites, people, manager, directReports → users; else mail), `mail`, `teams`, `users` |
| `-All` / `-MaxPages` | follow `@odata.nextLink` and return the list of items (default 10 pages) |
| `-OutFile` | save binary content (pasted image, attachment) |
| `-Html` | keep HTML. Default: mail bodies come as text; Teams HTML becomes text with `[image: <url>]` for pasted images |
| `-Raw` | PowerShell objects instead of JSON |
| `-Method`, `-Body`, `-AllowWrite` | writes. **Read-only unless `-AllowWrite`**, which the skills pass only after the account owner approved that exact action |

Retries, up to 3 times: HTTP 429 for every method; HTTP 5xx and network failures only for reads. A write that fails with 5xx or a network error may already be done, so it is never repeated automatically: check, then run it again.

## Invoke-M365SharePoint.ps1 - SharePoint and OneDrive files

SharePoint REST through the SharePoint (`sharepoint`) connection. **GET only.** Covers SharePoint search, the OneDrive API under `_api/v2.0/` (every site and every OneDrive the account can open) and classic `_api/web/...`.

```powershell
.\scripts\Invoke-M365SharePoint.ps1 "_api/search/query?querytext='budget filetype:xlsx'&rowlimit=10"
.\scripts\Invoke-M365SharePoint.ps1 '_api/v2.0/drives?$select=id,name' -Site https://contoso.sharepoint.com/sites/Marketing
```

| Parameter | Meaning |
|---|---|
| `-Uri` (first) | `_api/...`, or a full `https://<site>/_api/...` URL (nextLink) |
| `-Site` | the site the request goes to. Default: `sharepointRoot` from `connections.json` (found once through `users` if missing) |
| `-All` / `-MaxPages` | follow `@odata.nextLink` |
| `-Raw` | PowerShell objects instead of JSON |

The two scripts below call it. Retries: 429, 5xx and network failures, up to 3 times (all calls are reads).

| Script | Purpose |
|---|---|
| `Search-M365Files.ps1` | search files or folders (KQL) in all sites and OneDrives the account can open; filters `-Site`, `-FileType`, `-ModifiedAfter`, `-Folders`; sort by relevance, date or size; paging |
| `Get-M365File.ps1` | by URL (file, folder, library, sharing link, Office web link): details, folder list, `-Libraries` of a site, download (`-OutFile` / `-OutDir`), `-Text` (markitdown: Word, Excel, PowerPoint, PDF, .msg, .rtf, HTML; old .doc / .ppt through local Word / PowerPoint), `-Pages` (PDF pages as PNG). Downloads through the item's short-lived download URL, which it never prints |
| `Convert-PdfToPng.py` | renders PDF pages to PNG with PyMuPDF (used by `Get-M365File.ps1 -Pages`), for PDFs made of pictures |

```powershell
.\scripts\Search-M365Files.ps1 'onboarding' -FileType docx,pdf -SortBy Modified
.\scripts\Get-M365File.ps1 'https://contoso.sharepoint.com/sites/HR/Shared Documents/Onboarding.docx' -Text
```

## Helper scripts

| Script | Purpose |
|---|---|
| `Save-M365Draft.ps1` | one script for every mail draft: new, reply / reply-all, update of the same draft; adds the Outlook signature, inline images and attachments (large files through an upload session); prints the edit link. Keeps the quoted thread and its images on an update. **Never sends** |
| `Get-M365Signature.ps1` | the user's current Outlook signature, from the newest sent message that has one |
| `Get-M365DraftLink.ps1` | the Outlook on the web link that opens a draft in edit mode, pinned to the target mailbox |
| `Compare-DraftText.py` | compares a draft's text with the HTML it was made from: was the draft edited by hand? |
| `Watch-M365Chat.ps1` | watches one Teams chat and prints one line per new message (for Claude Code's Monitor tool) |
| `Send-M365ChatMessage.ps1` | posts one message to a Teams chat: stops if the chat has a message newer than the last one the user reviewed, posts, reads the message back. Running it again does not post twice |
| `New-M365Connection.ps1` | creates one connection and prints its authorize link ([setup.md](setup.md)) |

```powershell
& .\scripts\Save-M365Draft.ps1 -To pat@contoso.com -Subject 'Status' -BodyFile .\body.html -Images .\step1.png
```

If your own skills use a copy of a script, keep both in sync.
