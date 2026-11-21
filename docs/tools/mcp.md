---
title: MCP access
order: 6
description: Connect AI clients such as Claude, Cursor or Codex to Mythweaver's tools with a personal access token.
---

Mythweaver runs a Model Context Protocol (MCP) server, so outside AI clients such as Claude, Cursor or Codex can use the same tools as [Chat with Mythweaver](assistant.md): browsing and editing your characters, lore, prompts, chats and settings. Clients authenticate with a personal access token that acts as you.

## Before you start

You need the **Connect AI tools over MCP** permission (`mcp.use`). If an administrator has turned it off for your account, the **MCP access** section says *MCP access is turned off for this account by an administrator.* and lists your existing tokens only so you can revoke them. See [Users, groups and permissions](../administration/users-and-permissions.md).

## To create a token

1. Open your account settings at `/users/settings` and find **MCP access**.
2. Enter a **Token name** (up to 80 characters, unique among your tokens), for example the client's name.
3. Pick the **Access** level.
4. Click **Create token**. Because a token is a long-lived credential, you may be asked to confirm your password first (sudo mode; see [Your account](../account/index.md)).
5. Copy the secret that appears. It starts with `mwp_` and is shown only once: Mythweaver stores only a fingerprint of it. Click **Done** when you have saved it.

### Access levels

| Access | What the token can do |
|---|---|
| **Read only** | Only the reading tools: list, get and search. |
| **Full access** | Every MCP tool, including writes, with your permissions except site administration and moderation. |
| **Full access, including site administration** | Everything **Full access** has plus your administration and moderation permissions. Offered only if you are the owner or hold a site permission. |

> [!WARNING]
> Write tools run as soon as the client calls them. Unlike Chat with Mythweaver, there is no Approve/Reject step, so give write access only to clients you trust.

## To connect a client

Configure the client with:

- the endpoint: your server's address followed by `/mcp`, for example `https://mythweaver.example.com/mcp`;
- the header `Authorization: Bearer <token>`, with the secret you copied.

The endpoint speaks MCP's Streamable HTTP transport in stateless mode: clients send JSON-RPC requests with `POST` and get JSON replies. `GET` and `DELETE` return 405, since there is no server-to-client stream or session. A client that asks for a JSON configuration typically looks like this:

```json
{
  "mcpServers": {
    "mythweaver": {
      "type": "http",
      "url": "https://mythweaver.example.com/mcp",
      "headers": { "Authorization": "Bearer mwp_…" }
    }
  }
}
```

The exact format depends on the client; check its documentation.

## To see what a token has done

Each token in the list shows its access level, the last four characters of its secret, when it was created and when it was last used. Expand **Recent calls** to see its tool calls from the last 30 days (up to 20 per token), each marked as succeeded or failed.

## To revoke a token

Click **Revoke** next to the token and confirm. Clients using it stop working immediately. Revoking doesn't need sudo.

## How tokens are checked

- Every request re-checks your current permissions, so removing `mcp.use` from you stops all your tokens on their next call.
- A token never grants sudo, so actions that need you to confirm your password in the app can't be done over MCP.
- A suspended account, or a request from a banned device or network, is refused. Each request records its IP address and user agent among the account's sign-in fingerprints; see [Moderation](../administration/moderation.md).

| Response | Meaning |
|---|---|
| 401 *Missing or invalid MCP access token.* | No token, a mistyped one, or a revoked one. |
| 403 *MCP access is turned off for this account.* | You no longer hold `mcp.use`. |
| 403 *This account or network is blocked.* | The account, device or network is banned. |

## Available tools

MCP clients get the assistant's tool catalog, minus a few tools that only make sense inside a Mythweaver conversation or that need sudo: the API key form, reading a stored tool result, and moving lore books, connections or models to the site. A read-only token sees only the reading tools. The tools cover characters and their outfits, sprites and expressions; lore books, entries and pools; chats, participants, messages and injections; AI connections and models; prompts, blocks and outlets; settings, variables, scripts, memory settings, jobs, analytics, tags and search; and this documentation (list, search and read its pages). Each tool describes its own arguments to the client, and they act with exactly your permissions.
