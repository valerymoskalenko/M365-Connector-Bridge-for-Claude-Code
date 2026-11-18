# M365 Connector Bridge for Claude Code

Work with your Microsoft 365 **mail, calendar, Teams chats, people and files** from Claude Code, for an account where the claude.ai Microsoft 365 connector is not available - for example, when the tenant gives no admin consent for mail and chat apps, blocks device-code sign-in, or does not allow the connector app.

It needs no app registration and no admin consent in that tenant. Instead it uses Azure **API connections** (the managed connectors of Logic Apps) that you authorize once with your own account.

## How it works

```mermaid
%%{init: {"theme": "base", "flowchart": {"wrappingWidth": 280, "nodeSpacing": 40, "rankSpacing": 60}, "themeVariables": {"fontFamily": "Segoe UI, -apple-system, Helvetica, Arial, sans-serif", "fontSize": "15px", "primaryTextColor": "#1F2937", "lineColor": "#64748B", "edgeLabelBackground": "#FFFFFF"}}}%%
flowchart LR
    subgraph PC["💻 1 · Your computer"]
        CC("<b>Claude Code</b><br/>skills:<br/>m365-mail<br/>m365-teams<br/>m365-files<br/>m365-bridge")
        S("<b>PowerShell scripts</b><br/>az login · home tenant")
        CC --> S
    end

    subgraph AZ["☁️ 2 · Azure subscription"]
        subgraph RG["Resource group"]
            C("<b>Logic Apps API connections</b><br/>Outlook<br/>Teams<br/>Users<br/>SharePoint<br/>OneDrive<br/><i>hold your sign-in token</i>")
        end
    end

    subgraph M365["📬 3 · Microsoft 365"]
        G("<b>Microsoft Graph</b><br/>mail<br/>calendar<br/>Teams<br/>files<br/><i>target tenant, as your account</i>")
    end

    S == "dynamicInvoke" ==> C
    C == "Graph request" ==> G

    classDef claude fill:#FFFFFF,stroke:#D97757,stroke-width:2px,color:#1F2937
    classDef azure fill:#FFFFFF,stroke:#0078D4,stroke-width:2px,color:#1F2937
    classDef m365 fill:#FFFFFF,stroke:#6B4FD8,stroke-width:2px,color:#1F2937
    class CC,S claude
    class C azure
    class G m365
    style PC fill:#FDF3EE,stroke:#D97757,stroke-width:1px,color:#7A3A1F
    style AZ fill:#EEF5FC,stroke:#0078D4,stroke-width:1px,color:#0B3D6B
    style RG fill:#DCEBFA,stroke:#5A9BD8,stroke-width:1px,stroke-dasharray:4 3,color:#0B3D6B
    style M365 fill:#F3F0FD,stroke:#6B4FD8,stroke-width:1px,color:#3B2A8A
    linkStyle default stroke:#64748B,stroke-width:2px
```

1. **Your computer:** you ask Claude Code; a skill runs a small PowerShell script, signed in to Azure with `az login`.
2. **Azure subscription:** the script calls an API connection through Azure Resource Manager (`dynamicInvoke`). Azure roles decide who may do that.
3. **Microsoft 365:** the connection calls Microsoft Graph with the token you stored when you authorized it, so Graph sees your account.

Technical details: [docs/how-it-works.md](docs/how-it-works.md).

## What you can ask

- "Check my mail from today. Anything I haven't answered?"
- "Find the thread with Pat about the invoice and summarize it."
- "Draft a reply-all: we agree, start on Monday." (stays a draft until you say "send")
- "What did Sam write me in Teams? Open the screenshot he pasted."
- "What is in my calendar next week?"
- "Find the onboarding checklist on SharePoint and tell me what changed this month." (only files your account can open)

## Install and set up

```text
claude plugin install m365-bridge --marketplace valerymoskalenko/M365-Connector-Bridge-for-Claude-Code
```

Then ask Claude **"set up the M365 bridge"**. Setup takes about 15 minutes, once: [docs/setup.md](docs/setup.md).

| Skill | For |
|---|---|
| `m365-bridge` | setup, how it works, errors, safety rules |
| `m365-mail` | inbox, search, threads, Sent Items, attachments, calendar, drafts |
| `m365-teams` | chats, a chat with a person, pasted images, watching a chat, meeting check |
| `m365-files` | SharePoint and OneDrive: search, site libraries, folders, a file or sharing link as text, download (read-only) |

## Safe by default

- **Read-only.** Nothing is changed without your OK for that exact action.
- **Drafts, not sends.** "Write an email" or "answer him in Teams" gives you the text or a draft first; it is sent or posted only when you say "send".
- **Who else can use your connections?** Everyone with Owner, Contributor or Logic App Contributor on them, also inherited from the subscription or management groups. Knowing the URL alone gives no access. Check and reduce it: [docs/security.md](docs/security.md).

Use the bridge only with your own account, and check your organization's policies first.

## Documentation

| Document | What is in it |
|---|---|
| [docs/setup.md](docs/setup.md) | install, config file, create and authorize the connections, test, move |
| [docs/how-it-works.md](docs/how-it-works.md) | `dynamicInvoke`, connector operations, request and response format |
| [docs/scripts.md](docs/scripts.md) | `Invoke-M365Graph.ps1`, `Invoke-M365SharePoint.ps1` and the helper scripts (drafts, signature, chat watcher, file search and reading) |
| [docs/security.md](docs/security.md) | which Azure roles give access, how to check, reduce and detect it, emergency stop |
| [docs/findings.md](docs/findings.md) | what was tested, path rules and limits of each connector |
| [docs/m365-connector-comparison.md](docs/m365-connector-comparison.md) | the claude.ai Microsoft 365 connector compared with this bridge |
| [docs/connector-operations.md](docs/connector-operations.md) | useful operations of each connector (Outlook, Teams, Users, SharePoint, OneDrive) |
| [docs/mcp-server-plan.md](docs/mcp-server-plan.md) | an idea: a local MCP server with the connector's tool names (not decided) |

## Terms

- **Target account / target tenant** - the Microsoft 365 account and tenant you want to work with, where the claude.ai connector is not available.
- **Home tenant** - the tenant of the Azure subscription that holds the connections. `az login` uses an account of this tenant. It can be the **same tenant as the target tenant**, or a **separate tenant**, for example a personal one. A separate tenant where you are the only admin is also the safest choice: see [docs/security.md](docs/security.md).

## License

MIT - see [LICENSE](LICENSE).
