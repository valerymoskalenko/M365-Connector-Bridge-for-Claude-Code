# Security

## Use responsibly

The bridge reads your own Microsoft 365 data through an Azure subscription that can be outside the target tenant. The target tenant's IT did not approve it and does not manage it as an app. That does not make it invisible: you sign in to Microsoft's connector apps with the target account, so the tenant's admins can probably see these sign-ins in their sign-in logs (not checked), and they can block the route (see "Other points"). Use it only with your own account, and check your organization's policies first.

A connection holds the target account's OAuth access and refresh tokens (not the password). Whoever can use the connection can read and send mail, read and post in Teams, and reach files **as the target account**, until the refresh token expires or is revoked. So the question is: **who can use the connection?**

## What does not give access

Knowing the connection's resource id or URL is not enough. A connection is not a public endpoint: every call goes through Azure Resource Manager with a Microsoft Entra ID token, and Azure checks the caller's role before the connector runs. Requests that Azure rejects are not even written to the Activity log.

## Azure roles that give access

A role counts at **any scope above** the connection: the connection, the resource group, the subscription, and every management group up to the tenant root.

| Built-in role | Can use the connection (act as the target account) | Can give access to others |
|---|---|---|
| **Owner** | ✅ | ✅ any role |
| **Contributor** | ✅ | - |
| **Logic App Contributor** | ✅ | - |
| **Logic Apps Standard Contributor** | ✅ | - |
| **Logic Apps Standard Developer** | ✅ | - |
| **User Access Administrator** | not directly, but can give itself Owner | ✅ any role |
| **Role Based Access Control Administrator** | not directly, but can give itself Owner | ✅ any role |
| Azure Resilience Management Drills Administrator, Drills Assets Administrator, Drills Target Resource Administrator, Goals Administrator | not directly | ✅ Contributor (only within the limits of a condition in the role) |

Also: a **Global Administrator** of the home tenant (an Entra ID role, not an Azure role) can raise itself to User Access Administrator at the tenant root.

How the table was made (17 Nov 2026): all 993 built-in roles from `az role definition list`, checked for `Microsoft.Web/connections/dynamicInvoke/action` (use) and `Microsoft.Authorization/roleAssignments/write` (give access), with `NotActions` and role conditions taken into account. About 20 more built-in roles can assign roles, but a condition limits them to roles that give no access to connections. **Custom roles** are not in the table: check them yourself.

Permissions behind the table:

| Path | Needs |
|---|---|
| `dynamicInvoke` (what this bridge uses) | `Microsoft.Web/connections/dynamicInvoke/action` on the connection |
| A Logic App that uses the connection | `Microsoft.Web/connections/Join/Action` on the connection, plus rights to create the Logic App |
| Reading or changing the connection | `Microsoft.Web/connections/*` |

Sources: [Azure permissions for Microsoft.Web](https://learn.microsoft.com/azure/role-based-access-control/permissions/web-and-mobile#microsoftweb), [built-in roles for Integration](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/integration). Microsoft's advice: give Contributor-level roles to trusted principals only, with least privilege ([Secure access and data in Azure Logic Apps](https://learn.microsoft.com/azure/logic-apps/set-up-security-permissions#secure-access-to-logic-app-operations-with-azure-rbac)).

## Never create these (they give access outside Azure roles)

- **A Logic App with a Request (HTTP) trigger** on these connections. Its trigger URL carries a key (`sig`), and "anyone that has a URI with valid key can access the associated resource" ([Learn](https://learn.microsoft.com/azure/logic-apps/set-up-security-permissions#access-for-inbound-calls-to-request-based-triggers)). Then a URL alone is enough.
- **Connection keys** (`listConnectionKeys`, used for Logic Apps Standard local development) and **consent links** (`listConsentLinks`).

The bridge needs none of these: it calls `dynamicInvoke` directly.

## Check who has access

```powershell
# every role that reaches the connection, including inherited ones
az role assignment list --scope <connection id> --include-inherited --query "[].{who:principalName,role:roleDefinitionName,scope:scope}" -o table

# who used the connection in the last 24 hours (the default limit is 50 events - raise it)
az monitor activity-log list --resource-id <connection id> --offset 1d --max-events 5000 `
  --query "[?operationName.value=='Microsoft.Web/connections/dynamicInvoke/action' && status.value=='Succeeded'].caller" -o tsv | Sort-Object | Group-Object | Select-Object Count, Name
```

Tested: each `dynamicInvoke` call appears in the Activity log with the caller (user name, or the object id of a managed identity: `az ad sp show --id <id> --query displayName`). The entry shows who called, not which mail was read.

## Reduce who has access

1. **Best: a subscription where only you hold roles**, in a tenant where you trust every admin (or are the only admin). API connection resources cost little or nothing on their own (estimate). Create the connections there and delete the old ones.
2. **If you must use a shared subscription:**
   - **Inherited roles can't be removed at the resource group.** Azure roles only add up; an inherited assignment can be removed only at the scope where it was assigned ([Learn](https://learn.microsoft.com/azure/role-based-access-control/role-assignments-remove#azure-portal)). Ask the admins of that scope.
   - Remove every direct assignment on the resource group and the connections that is not needed (old apps, test identities, extra accounts of your own).
   - Ask the admins to make standing Owner / Contributor / User Access Administrator roles at high scopes **eligible in Privileged Identity Management (PIM)** instead of permanent: activation then needs a reason and is logged.
   - **Deny assignment through a deployment stack (not tested yet).** A deny assignment is stronger than any role, even Owner. You can't create one directly, only with a [deployment stack](https://learn.microsoft.com/azure/azure-resource-manager/bicep/deployment-stacks#protect-managed-resources) that manages the connections, with `denySettingsMode = denyWriteAndDelete` and `excludedPrincipals` = you (up to 5 principals; a group counts as one). Open points: test on a separate connection whether it also blocks `dynamicInvoke/action`; an Owner of the stack's scope can still delete the stack. It does not make you the only one, but going around it becomes an explicit, logged change.
3. **V1 connections have no access policies** (`InvalidApiConnectionAccessPolicy`: only "V2" connections support them), so they can't limit callers here.

## Detect use by others

Create Activity log alerts (Azure Monitor) on the resource group:

- `Microsoft.Web/connections/dynamicInvoke/action` where the caller is not you (and not an identity you added on purpose);
- `Microsoft.Authorization/roleAssignments/write` (new role assignments);
- `Microsoft.Resources/deploymentStacks/delete`, if you use a deployment stack.

Limits ([Learn](https://learn.microsoft.com/azure/azure-monitor/fundamentals/activity-log)): entries are kept 90 days, appear 3-20 minutes after the event, and rejected requests are not logged.

## Emergency stop

- Delete the connections, or
- revoke all sessions of the target account (My Account → sign out everywhere, or an admin of the target tenant). The stored refresh token should then stop working, and the connection should show status `Error` until it is authorized again (expected behavior, not tested).

## Other points

- **Your computer:** the `az login` token cache gives the same access as your Azure role. Protect your user profile; `az logout` when you don't need the bridge.
- **The target tenant can block this route:** Azure Logic Apps has a [tenant isolation policy](https://learn.microsoft.com/azure/logic-apps/block-connections-across-tenants) that blocks connections to and from a tenant.
